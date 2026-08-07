-- Signed events are authoritative only after the exact delivery attempt has an
-- immutable HTTP-accepted outcome. SendGrid derives sg_message_id from the
-- Mail Send X-Message-ID, so the event ID must equal that value or start with
-- it followed by a dot. Events arriving before acceptance or for another
-- message are quarantined and cannot project delivery state.

alter table private.email_provider_event_quarantine
  drop constraint if exists email_provider_event_quarantine_reason_check;
alter table private.email_provider_event_quarantine
  add constraint email_provider_event_quarantine_reason_check
  check (
    reason in (
      'attempt_identity_missing',
      'attempt_job_mismatch',
      'attempt_not_accepted',
      'event_identity_collision',
      'event_message_mismatch',
      'http_message_mismatch',
      'occurred_at_out_of_bounds'
    )
  );

create or replace function private.quarantine_sendgrid_event_v2(
  p_reason text,
  p_email_job_id uuid,
  p_delivery_attempt_id uuid,
  p_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = private, extensions, pg_temp
as $$
declare
  fingerprint text;
begin
  if p_reason not in (
    'attempt_identity_missing',
    'attempt_job_mismatch',
    'attempt_not_accepted',
    'event_identity_collision',
    'event_message_mismatch',
    'http_message_mismatch',
    'occurred_at_out_of_bounds'
  ) then
    raise exception 'SENDGRID_QUARANTINE_REASON_INVALID'
      using errcode = '22023';
  end if;
  fingerprint := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          coalesce(p_email_job_id::text, ''),
          coalesce(p_delivery_attempt_id::text, ''),
          coalesce(p_event_id, ''),
          coalesce(p_provider_message_id, ''),
          coalesce(p_event_type, ''),
          coalesce(p_occurred_at::text, '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  insert into private.email_provider_event_quarantine(
    event_fingerprint,
    reason,
    email_job_id,
    delivery_attempt_id,
    occurred_at
  ) values (
    fingerprint,
    p_reason,
    p_email_job_id,
    p_delivery_attempt_id,
    p_occurred_at
  )
  on conflict (event_fingerprint, reason) do nothing;
end;
$$;

revoke all on function private.quarantine_sendgrid_event_v2(
  text, uuid, uuid, text, text, text, timestamptz
) from public, anon, authenticated, service_role;

create or replace function app.record_sendgrid_events_v4(p_events jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  event_item jsonb;
  accepted_events jsonb := '[]'::jsonb;
  downstream jsonb;
  delivery_attempt_id_text text;
  email_job_id_text text;
  normalized_message_id text;
  accepted_http_message_id text;
  existing_event_message_id text;
  pre_quarantined integer := 0;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'INVALID_SENDGRID_EVENTS' using errcode = '22023';
  end if;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    delivery_attempt_id_text :=
      nullif(btrim(event_item ->> 'delivery_attempt_id'), '');
    email_job_id_text :=
      nullif(btrim(event_item ->> 'email_job_id'), '');
    normalized_message_id :=
      nullif(btrim(event_item ->> 'provider_message_id'), '');
    accepted_http_message_id := null;
    existing_event_message_id := null;

    if delivery_attempt_id_text
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      and email_job_id_text
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      select outcome.provider_http_message_id
      into accepted_http_message_id
      from private.email_delivery_attempt_outcomes outcome
      where outcome.delivery_attempt_id =
          delivery_attempt_id_text::uuid
        and outcome.outcome in ('sent', 'recovered_sent')
        and outcome.provider_http_message_id is not null
      order by outcome.id desc
      limit 1;
      select binding.provider_message_id
      into existing_event_message_id
      from private.email_delivery_attempt_provider_messages binding
      where binding.delivery_attempt_id =
        delivery_attempt_id_text::uuid;

      if event_item ->> 'event_type' = 'bounced'
        and normalized_message_id is null
      then
        if accepted_http_message_id is null then
          perform private.quarantine_sendgrid_event_v2(
            'attempt_not_accepted',
            email_job_id_text::uuid,
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            null,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
        if existing_event_message_id is not null
          and private.sendgrid_message_matches_http_acceptance(
            accepted_http_message_id,
            existing_event_message_id
          )
        then
          normalized_message_id := existing_event_message_id;
        else
          normalized_message_id := accepted_http_message_id;
        end if;
        event_item := jsonb_set(
          event_item,
          '{provider_message_id}',
          to_jsonb(normalized_message_id),
          true
        );
      end if;

      if normalized_message_id is not null then
        if accepted_http_message_id is null then
          perform private.quarantine_sendgrid_event_v2(
            'attempt_not_accepted',
            email_job_id_text::uuid,
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            normalized_message_id,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
        if not private.sendgrid_message_matches_http_acceptance(
          accepted_http_message_id,
          normalized_message_id
        ) then
          perform private.quarantine_sendgrid_event_v2(
            'http_message_mismatch',
            email_job_id_text::uuid,
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            normalized_message_id,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
      end if;
    end if;

    accepted_events :=
      accepted_events || jsonb_build_array(event_item);
  end loop;

  downstream := app.record_sendgrid_events_v3(accepted_events);
  return jsonb_build_object(
    'recorded', (downstream ->> 'recorded')::integer,
    'ignored', (downstream ->> 'ignored')::integer,
    'quarantined',
      (downstream ->> 'quarantined')::integer + pre_quarantined
  );
end;
$$;

revoke all on function app.record_sendgrid_events_v3(jsonb)
from service_role;
revoke all on function app.record_sendgrid_events_v4(jsonb)
from public, anon, authenticated;
grant execute on function app.record_sendgrid_events_v4(jsonb)
to service_role;

alter table private.parent_otp_provider_event_quarantine
  drop constraint if exists
    parent_otp_provider_event_quarantine_reason_check;
alter table private.parent_otp_provider_event_quarantine
  add constraint parent_otp_provider_event_quarantine_reason_check
  check (
    reason in (
      'attempt_identity_missing',
      'attempt_not_accepted',
      'event_identity_collision',
      'event_message_mismatch',
      'http_message_mismatch',
      'occurred_at_out_of_bounds'
    )
  );

create or replace function private.quarantine_parent_otp_provider_event(
  p_reason text,
  p_delivery_attempt_id uuid,
  p_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = private, extensions, pg_temp
as $$
declare
  fingerprint text;
begin
  if p_reason not in (
    'attempt_identity_missing',
    'attempt_not_accepted',
    'event_identity_collision',
    'event_message_mismatch',
    'http_message_mismatch',
    'occurred_at_out_of_bounds'
  ) then
    raise exception 'PARENT_OTP_PROVIDER_QUARANTINE_REASON_INVALID'
      using errcode = '22023';
  end if;
  fingerprint := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          coalesce(p_delivery_attempt_id::text, ''),
          coalesce(p_event_id, ''),
          coalesce(p_provider_message_id, ''),
          coalesce(p_event_type, ''),
          coalesce(p_occurred_at::text, '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  insert into private.parent_otp_provider_event_quarantine(
    event_fingerprint,
    reason,
    delivery_attempt_id,
    occurred_at
  ) values (
    fingerprint,
    p_reason,
    p_delivery_attempt_id,
    p_occurred_at
  )
  on conflict (event_fingerprint, reason) do nothing;
end;
$$;

revoke all on function private.quarantine_parent_otp_provider_event(
  text, uuid, text, text, text, timestamptz
) from public, anon, authenticated, service_role;

create or replace function app.record_parent_otp_sendgrid_events_v3(
  p_events jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  event_item jsonb;
  accepted_events jsonb := '[]'::jsonb;
  downstream jsonb;
  delivery_attempt_id_text text;
  normalized_message_id text;
  accepted_http_message_id text;
  existing_event_message_id text;
  normalized_event_id text;
  pre_quarantined integer := 0;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'PARENT_OTP_PROVIDER_EVENTS_INVALID'
      using errcode = '22023';
  end if;

  for normalized_event_id in
    select distinct nullif(btrim(event_item.value ->> 'event_id'), '')
    from jsonb_array_elements(p_events) event_item(value)
    where nullif(btrim(event_item.value ->> 'event_id'), '') is not null
    order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'parent-otp-provider-event:' || normalized_event_id,
        0
      )
    );
  end loop;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    delivery_attempt_id_text :=
      nullif(btrim(event_item ->> 'delivery_attempt_id'), '');
    normalized_message_id :=
      nullif(btrim(event_item ->> 'provider_message_id'), '');
    accepted_http_message_id := null;
    existing_event_message_id := null;

    if delivery_attempt_id_text
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      select outcome.provider_http_message_id
      into accepted_http_message_id
      from private.parent_otp_delivery_outcomes outcome
      where outcome.delivery_attempt_id =
          delivery_attempt_id_text::uuid
        and outcome.outcome = 'accepted'
        and outcome.provider_http_message_id is not null;
      select binding.provider_message_id
      into existing_event_message_id
      from private.parent_otp_provider_message_bindings binding
      where binding.delivery_attempt_id =
        delivery_attempt_id_text::uuid;

      if event_item ->> 'event_type' = 'bounced'
        and normalized_message_id is null
      then
        if accepted_http_message_id is null then
          perform private.quarantine_parent_otp_provider_event(
            'attempt_not_accepted',
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            null,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
        if existing_event_message_id is not null
          and private.sendgrid_message_matches_http_acceptance(
            accepted_http_message_id,
            existing_event_message_id
          )
        then
          normalized_message_id := existing_event_message_id;
        else
          normalized_message_id := accepted_http_message_id;
        end if;
        event_item := jsonb_set(
          event_item,
          '{provider_message_id}',
          to_jsonb(normalized_message_id),
          true
        );
      end if;

      if normalized_message_id is not null then
        if accepted_http_message_id is null then
          perform private.quarantine_parent_otp_provider_event(
            'attempt_not_accepted',
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            normalized_message_id,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
        if not private.sendgrid_message_matches_http_acceptance(
          accepted_http_message_id,
          normalized_message_id
        ) then
          perform private.quarantine_parent_otp_provider_event(
            'http_message_mismatch',
            delivery_attempt_id_text::uuid,
            nullif(btrim(event_item ->> 'event_id'), ''),
            normalized_message_id,
            event_item ->> 'event_type',
            (event_item ->> 'occurred_at')::timestamptz
          );
          pre_quarantined := pre_quarantined + 1;
          continue;
        end if;
      end if;
    end if;

    accepted_events :=
      accepted_events || jsonb_build_array(event_item);
  end loop;

  downstream := app.record_parent_otp_sendgrid_events_v2(
    accepted_events
  );
  return jsonb_build_object(
    'recorded', (downstream ->> 'recorded')::integer,
    'ignored', (downstream ->> 'ignored')::integer,
    'quarantined',
      (downstream ->> 'quarantined')::integer + pre_quarantined
  );
end;
$$;

revoke all on function app.record_parent_otp_sendgrid_events_v2(jsonb)
from service_role;
revoke all on function app.record_parent_otp_sendgrid_events_v3(jsonb)
from public, anon, authenticated;
grant execute on function app.record_parent_otp_sendgrid_events_v3(jsonb)
to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260803241000_sendgrid_http_acceptance_binding',
  'passed',
  jsonb_build_object(
    'strategy',
      'require immutable HTTP acceptance before queue or OTP provider events',
    'accepted_email_attempts',
      (
        select count(distinct outcome.delivery_attempt_id)
        from private.email_delivery_attempt_outcomes outcome
        where outcome.outcome in ('sent', 'recovered_sent')
          and outcome.provider_http_message_id is not null
      ),
    'accepted_parent_otp_attempts',
      (
        select count(*)
        from private.parent_otp_delivery_outcomes outcome
        where outcome.outcome = 'accepted'
          and outcome.provider_http_message_id is not null
      )
  )
);

notify pgrst, 'reload schema';

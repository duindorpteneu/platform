-- SendGrid can omit sg_message_id from asynchronous bounce payloads. Only
-- recover that identity from the immutable HTTP-acceptance binding for the
-- exact delivery attempt. All other missing identities remain quarantined by
-- the existing recorders.

create or replace function app.record_sendgrid_events_v3(p_events jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  event_item jsonb;
  normalized_events jsonb := '[]'::jsonb;
  delivery_attempt_id_text text;
  email_job_id_text text;
  bound_message_id text;
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
    bound_message_id := null;

    if event_item ->> 'event_type' = 'bounced'
      and nullif(btrim(event_item ->> 'provider_message_id'), '') is null
      and delivery_attempt_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      and email_job_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      select binding.provider_message_id
      into bound_message_id
      from private.email_delivery_attempt_provider_messages binding
      join private.email_delivery_attempts attempt
        on attempt.id = binding.delivery_attempt_id
      where binding.delivery_attempt_id =
          delivery_attempt_id_text::uuid
        and attempt.email_job_id = email_job_id_text::uuid;

      if bound_message_id is not null then
        event_item := jsonb_set(
          event_item,
          '{provider_message_id}',
          to_jsonb(bound_message_id),
          true
        );
      end if;
    end if;

    normalized_events :=
      normalized_events || jsonb_build_array(event_item);
  end loop;

  return app.record_sendgrid_events_v2(normalized_events);
end;
$$;

revoke all on function app.record_sendgrid_events_v2(jsonb)
from service_role;
revoke all on function app.record_sendgrid_events_v3(jsonb)
from public, anon, authenticated;
grant execute on function app.record_sendgrid_events_v3(jsonb)
to service_role;

create or replace function app.record_parent_otp_sendgrid_events_v2(
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
  normalized_events jsonb := '[]'::jsonb;
  delivery_attempt_id_text text;
  bound_message_id text;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'PARENT_OTP_PROVIDER_EVENTS_INVALID'
      using errcode = '22023';
  end if;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    delivery_attempt_id_text :=
      nullif(btrim(event_item ->> 'delivery_attempt_id'), '');
    bound_message_id := null;

    if event_item ->> 'event_type' = 'bounced'
      and nullif(btrim(event_item ->> 'provider_message_id'), '') is null
      and delivery_attempt_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      select binding.provider_message_id
      into bound_message_id
      from private.parent_otp_provider_message_bindings binding
      where binding.delivery_attempt_id =
        delivery_attempt_id_text::uuid;

      if bound_message_id is not null then
        event_item := jsonb_set(
          event_item,
          '{provider_message_id}',
          to_jsonb(bound_message_id),
          true
        );
      end if;
    end if;

    normalized_events :=
      normalized_events || jsonb_build_array(event_item);
  end loop;

  return app.record_parent_otp_sendgrid_events_v1(normalized_events);
end;
$$;

revoke all on function app.record_parent_otp_sendgrid_events_v1(jsonb)
from service_role;
revoke all on function app.record_parent_otp_sendgrid_events_v2(jsonb)
from public, anon, authenticated;
grant execute on function app.record_parent_otp_sendgrid_events_v2(jsonb)
to service_role;

create table private.mail_test_delivery_provider_acceptances (
  delivery_id uuid primary key
    references private.mail_test_deliveries(id) on delete restrict,
  provider_http_message_id text not null unique check (
    length(btrim(provider_http_message_id)) between 3 and 240
  ),
  accepted_at timestamptz not null default statement_timestamp()
);

create table private.mail_test_delivery_provider_events (
  id bigint generated always as identity primary key,
  delivery_id uuid not null
    references private.mail_test_deliveries(id) on delete restrict,
  provider_event_id text not null unique check (
    length(btrim(provider_event_id)) between 1 and 240
  ),
  provider_message_id text not null check (
    length(btrim(provider_message_id)) between 1 and 240
  ),
  event_type text not null check (
    event_type in (
      'delivered',
      'bounced',
      'deferred',
      'dropped',
      'failed'
    )
  ),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default statement_timestamp()
);

create table private.mail_test_delivery_provider_quarantine (
  id bigint generated always as identity primary key,
  event_fingerprint text not null check (
    event_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  reason text not null check (
    reason in (
      'delivery_identity_missing',
      'delivery_not_accepted',
      'event_identity_collision',
      'occurred_at_out_of_bounds'
    )
  ),
  delivery_id uuid,
  occurred_at timestamptz,
  recorded_at timestamptz not null default statement_timestamp(),
  unique (event_fingerprint, reason)
);

alter table private.mail_test_delivery_provider_acceptances
  enable row level security;
alter table private.mail_test_delivery_provider_events
  enable row level security;
alter table private.mail_test_delivery_provider_quarantine
  enable row level security;
revoke all on
  private.mail_test_delivery_provider_acceptances,
  private.mail_test_delivery_provider_events,
  private.mail_test_delivery_provider_quarantine
from public, anon, authenticated, service_role;

create trigger mail_test_delivery_provider_acceptances_immutable
before update or delete
on private.mail_test_delivery_provider_acceptances
for each row execute function private.reject_mail_test_ledger_mutation();

create trigger mail_test_delivery_provider_events_immutable
before update or delete
on private.mail_test_delivery_provider_events
for each row execute function private.reject_mail_test_ledger_mutation();

create trigger mail_test_delivery_provider_quarantine_immutable
before update or delete
on private.mail_test_delivery_provider_quarantine
for each row execute function private.reject_mail_test_ledger_mutation();

create or replace function app.finalize_mail_test_delivery_v2(
  p_delivery_id uuid,
  p_outcome text,
  p_provider_http_message_id text default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  result jsonb;
  normalized_message_id text :=
    nullif(btrim(p_provider_http_message_id), '');
  bound_message_id text;
begin
  if (
    p_outcome = 'accepted'
    and (
      normalized_message_id is null
      or length(normalized_message_id) not between 3 and 240
    )
  ) or (
    p_outcome <> 'accepted'
    and normalized_message_id is not null
  ) then
    raise exception 'MAIL_TEST_PROVIDER_IDENTITY_INVALID'
      using errcode = '22023';
  end if;

  result := app.finalize_mail_test_delivery_v1(
    p_delivery_id,
    p_outcome,
    p_correlation_id
  );

  if p_outcome = 'accepted' then
    insert into private.mail_test_delivery_provider_acceptances(
      delivery_id,
      provider_http_message_id
    ) values (
      p_delivery_id,
      normalized_message_id
    )
    on conflict (delivery_id) do nothing;

    select acceptance.provider_http_message_id
    into bound_message_id
    from private.mail_test_delivery_provider_acceptances acceptance
    where acceptance.delivery_id = p_delivery_id;
    if bound_message_id is distinct from normalized_message_id then
      raise exception 'MAIL_TEST_PROVIDER_IDENTITY_CONFLICT'
        using errcode = '23505';
    end if;
  end if;

  return result;
end;
$$;

revoke all on function app.finalize_mail_test_delivery_v1(
  uuid, text, uuid
) from authenticated;
revoke all on function app.finalize_mail_test_delivery_v2(
  uuid, text, text, uuid
) from public, anon;
grant execute on function app.finalize_mail_test_delivery_v2(
  uuid, text, text, uuid
) to authenticated;

create or replace function private.quarantine_mail_test_provider_event(
  p_reason text,
  p_delivery_id uuid,
  p_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, private, extensions, pg_temp
as $$
declare
  fingerprint text;
begin
  if p_reason not in (
    'delivery_identity_missing',
    'delivery_not_accepted',
    'event_identity_collision',
    'occurred_at_out_of_bounds'
  ) then
    raise exception 'MAIL_TEST_PROVIDER_QUARANTINE_REASON_INVALID'
      using errcode = '22023';
  end if;
  fingerprint := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          coalesce(p_delivery_id::text, ''),
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
  insert into private.mail_test_delivery_provider_quarantine(
    event_fingerprint,
    reason,
    delivery_id,
    occurred_at
  ) values (
    fingerprint,
    p_reason,
    p_delivery_id,
    p_occurred_at
  )
  on conflict (event_fingerprint, reason) do nothing;
end;
$$;

revoke all on function private.quarantine_mail_test_provider_event(
  text, uuid, text, text, text, timestamptz
) from public, anon, authenticated, service_role;

create or replace function app.record_mail_test_sendgrid_events_v1(
  p_events jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  item record;
  existing private.mail_test_delivery_provider_events%rowtype;
  normalized_event_id text;
  normalized_message_id text;
  inserted_count integer := 0;
  ignored_count integer := 0;
  quarantined_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'MAIL_TEST_PROVIDER_EVENTS_INVALID'
      using errcode = '22023';
  end if;

  for item in
    select *
    from jsonb_to_recordset(p_events) as event_data(
      delivery_id uuid,
      event_id text,
      provider_message_id text,
      event_type text,
      occurred_at timestamptz
    )
  loop
    normalized_event_id := nullif(btrim(item.event_id), '');
    normalized_message_id :=
      nullif(btrim(item.provider_message_id), '');
    if item.delivery_id is null
      or normalized_event_id is null
      or length(normalized_event_id) > 240
      or normalized_message_id is null
      or length(normalized_message_id) > 240
      or item.occurred_at is null
      or item.event_type not in (
        'delivered',
        'bounced',
        'deferred',
        'dropped',
        'failed'
      )
    then
      perform private.quarantine_mail_test_provider_event(
        'delivery_identity_missing',
        item.delivery_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    if not exists(
      select 1
      from private.mail_test_delivery_provider_acceptances acceptance
      where acceptance.delivery_id = item.delivery_id
    ) then
      perform private.quarantine_mail_test_provider_event(
        'delivery_not_accepted',
        item.delivery_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    if item.occurred_at
        < (
          select delivery.created_at - interval '5 minutes'
          from private.mail_test_deliveries delivery
          where delivery.id = item.delivery_id
        )
      or item.occurred_at > statement_timestamp() + interval '5 minutes'
    then
      perform private.quarantine_mail_test_provider_event(
        'occurred_at_out_of_bounds',
        item.delivery_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    existing := null;
    select * into existing
    from private.mail_test_delivery_provider_events provider_event
    where provider_event.provider_event_id = normalized_event_id;
    if existing.id is not null then
      if existing.delivery_id = item.delivery_id
        and existing.provider_message_id = normalized_message_id
        and existing.event_type = item.event_type
        and existing.occurred_at = item.occurred_at
      then
        ignored_count := ignored_count + 1;
      else
        perform private.quarantine_mail_test_provider_event(
          'event_identity_collision',
          item.delivery_id,
          normalized_event_id,
          normalized_message_id,
          item.event_type,
          item.occurred_at
        );
        quarantined_count := quarantined_count + 1;
      end if;
      continue;
    end if;

    insert into private.mail_test_delivery_provider_events(
      delivery_id,
      provider_event_id,
      provider_message_id,
      event_type,
      occurred_at
    ) values (
      item.delivery_id,
      normalized_event_id,
      normalized_message_id,
      item.event_type,
      item.occurred_at
    )
    on conflict (provider_event_id) do nothing;
    get diagnostics affected = row_count;
    if affected = 0 then
      quarantined_count := quarantined_count + 1;
    else
      inserted_count := inserted_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'recorded', inserted_count,
    'ignored', ignored_count,
    'quarantined', quarantined_count
  );
end;
$$;

revoke all on function app.record_mail_test_sendgrid_events_v1(jsonb)
from public, anon, authenticated;
grant execute on function app.record_mail_test_sendgrid_events_v1(jsonb)
to service_role;

create or replace function app.get_mail_test_delivery_status_v1(
  p_delivery_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target private.mail_test_deliveries%rowtype;
begin
  select * into target
  from private.mail_test_deliveries delivery
  where delivery.id = p_delivery_id
    and delivery.actor_user_id = actor;
  if not found then
    raise exception 'MAIL_TEST_DELIVERY_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'deliveryId', target.id,
    'accepted', exists(
      select 1
      from private.mail_test_delivery_provider_acceptances acceptance
      where acceptance.delivery_id = target.id
    ),
    'eventCount', (
      select count(*)
      from private.mail_test_delivery_provider_events provider_event
      where provider_event.delivery_id = target.id
    ),
    'deliveredEventCount', (
      select count(*)
      from private.mail_test_delivery_provider_events provider_event
      where provider_event.delivery_id = target.id
        and provider_event.event_type = 'delivered'
    ),
    'failureEventCount', (
      select count(*)
      from private.mail_test_delivery_provider_events provider_event
      where provider_event.delivery_id = target.id
        and provider_event.event_type in (
          'bounced',
          'dropped',
          'failed'
        )
    )
  );
end;
$$;

revoke all on function app.get_mail_test_delivery_status_v1(uuid)
from public, anon;
grant execute on function app.get_mail_test_delivery_status_v1(uuid)
to authenticated;

create or replace function app.get_operational_health_v11(
  p_current_pepper_fingerprint text,
  p_current_key_version integer default 1,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, app, public, private, pg_temp
as $$
  select app.get_operational_health_v10(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  ) || jsonb_build_object(
    'emailControl',
    jsonb_build_object(
      'processingEnabled',
      coalesce(
        public.is_operational_feature_enabled('email_enabled'),
        false
      ),
      'testEventQuarantined',
      (
        select count(*)
        from private.mail_test_delivery_provider_quarantine quarantine
        where quarantine.recorded_at
          >= statement_timestamp() - interval '24 hours'
      )
    )
  );
$$;

revoke all on function app.get_operational_health_v10(
  text, integer, text, integer
) from service_role;
revoke all on function app.get_operational_health_v11(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v11(
  text, integer, text, integer
) to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260803238000_sendgrid_bounce_identity_hardening',
  'passed',
  jsonb_build_object(
    'strategy',
      'resolve missing bounce message identity from immutable attempt binding',
    'email_attempt_bindings',
      (select count(*)
       from private.email_delivery_attempt_provider_messages),
    'parent_otp_attempt_bindings',
      (select count(*)
       from private.parent_otp_provider_message_bindings)
  )
);

notify pgrst, 'reload schema';

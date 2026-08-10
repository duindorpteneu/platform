-- A package default is a product choice and must never be inferred from
-- publication order. SendGrid's Event Webhook message ID is derived from the
-- Mail Send X-Message-ID; bind acceptance evidence to that exact prefix before
-- an event can satisfy the staging delivery gate.

create or replace function app.publish_package_revision_v2(
  p_revision_id uuid,
  p_make_default boolean,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
begin
  perform private.require_admin_aal2();
  select revision.season_id
  into target_season_id
  from app.package_template_revisions revision
  where revision.id = p_revision_id;
  if target_season_id is null then
    raise exception 'PACKAGE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('package-season:' || target_season_id::text, 0)
  );
  if not coalesce(p_make_default, false)
    and not exists(
      select 1
      from app.package_template_revisions revision
      where revision.season_id = target_season_id
        and revision.active
        and revision.is_default
    )
  then
    raise exception 'PACKAGE_DEFAULT_EXPLICIT_REQUIRED'
      using errcode = '23514';
  end if;
  return app.publish_package_revision(
    p_revision_id,
    p_make_default,
    p_expected_hash,
    p_correlation_id
  );
end;
$$;

revoke all on function app.publish_package_revision_v2(
  uuid, boolean, text, uuid
) from public, anon;
grant execute on function app.publish_package_revision_v2(
  uuid, boolean, text, uuid
) to authenticated;

alter table private.mail_test_delivery_provider_quarantine
  drop constraint if exists
    mail_test_delivery_provider_quarantine_reason_check;
alter table private.mail_test_delivery_provider_quarantine
  add constraint mail_test_delivery_provider_quarantine_reason_check
  check (
    reason in (
      'delivery_identity_missing',
      'delivery_not_accepted',
      'event_identity_collision',
      'occurred_at_out_of_bounds',
      'provider_message_mismatch'
    )
  );

create or replace function private.sendgrid_message_matches_http_acceptance(
  p_http_message_id text,
  p_event_message_id text
)
returns boolean
language sql
immutable
strict
set search_path = pg_catalog, pg_temp
as $$
  select p_event_message_id = p_http_message_id
    or (
      length(p_event_message_id) > length(p_http_message_id)
      and left(p_event_message_id, length(p_http_message_id))
        = p_http_message_id
      and substr(
        p_event_message_id,
        length(p_http_message_id) + 1,
        1
      ) = '.'
    );
$$;

revoke all on function
  private.sendgrid_message_matches_http_acceptance(text, text)
from public, anon, authenticated, service_role;

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
    'occurred_at_out_of_bounds',
    'provider_message_mismatch'
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

create or replace function app.record_mail_test_sendgrid_events_v2(
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
  accepted_http_message_id text;
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

    accepted_http_message_id := null;
    select acceptance.provider_http_message_id
    into accepted_http_message_id
    from private.mail_test_delivery_provider_acceptances acceptance
    where acceptance.delivery_id = item.delivery_id;
    if accepted_http_message_id is null then
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

    if not private.sendgrid_message_matches_http_acceptance(
      accepted_http_message_id,
      normalized_message_id
    ) then
      perform private.quarantine_mail_test_provider_event(
        'provider_message_mismatch',
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
from service_role;
revoke all on function app.record_mail_test_sendgrid_events_v2(jsonb)
from public, anon, authenticated;
grant execute on function app.record_mail_test_sendgrid_events_v2(jsonb)
to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260803239000_explicit_package_default_sendgrid_identity',
  'passed',
  jsonb_build_object(
    'strategy',
      'require explicit first package default and bind test events to Mail Send acceptance',
    'package_seasons_without_default',
      (
        select count(distinct season.id)
        from app.seasons season
        where exists(
          select 1
          from app.package_template_revisions revision
          where revision.season_id = season.id
            and revision.active
        )
          and not exists(
            select 1
            from app.package_template_revisions revision
            where revision.season_id = season.id
              and revision.active
              and revision.is_default
          )
      ),
    'test_provider_acceptances',
      (select count(*)
       from private.mail_test_delivery_provider_acceptances)
  )
);

notify pgrst, 'reload schema';

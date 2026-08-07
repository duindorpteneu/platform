-- SendGrid can deliver a signed Event Webhook callback before the application
-- has durably finalized the corresponding Mail Send HTTP acceptance. Treat
-- that ordering as transient and retryable instead of permanently
-- quarantining an otherwise valid provider fact.

create or replace function app.assert_sendgrid_events_ready_v1(
  p_events jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  event_item jsonb;
  target text;
  email_job_id_text text;
  delivery_attempt_id_text text;
  delivery_id_text text;
  ready_count integer := 0;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'SENDGRID_EVENT_READINESS_INVALID'
      using errcode = '22023';
  end if;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    target := nullif(btrim(event_item ->> 'target'), '');
    email_job_id_text :=
      nullif(btrim(event_item ->> 'email_job_id'), '');
    delivery_attempt_id_text :=
      nullif(btrim(event_item ->> 'delivery_attempt_id'), '');
    delivery_id_text :=
      nullif(btrim(event_item ->> 'delivery_id'), '');

    if target = 'email_job' then
      if email_job_id_text is null
        or delivery_attempt_id_text is null
        or email_job_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        or delivery_attempt_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.email_delivery_attempts attempt
        where attempt.id = delivery_attempt_id_text::uuid
          and attempt.email_job_id = email_job_id_text::uuid
      )
        and not exists (
          select 1
          from private.email_delivery_attempt_outcomes outcome
          where outcome.delivery_attempt_id =
              delivery_attempt_id_text::uuid
            and outcome.outcome in (
              'authorization_denied',
              'sent',
              'retry',
              'failed',
              'recovered_sent',
              'recovered_retry',
              'legacy_retry',
              'legacy_sent',
              'legacy_failed',
              'legacy_superseded'
            )
        )
      then
        raise exception 'SENDGRID_EVENT_ACCEPTANCE_PENDING'
          using errcode = '40001';
      end if;
    elsif target = 'parent_otp' then
      if delivery_attempt_id_text is null
        or delivery_attempt_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.parent_otp_delivery_attempts attempt
        where attempt.id = delivery_attempt_id_text::uuid
      )
        and not exists (
          select 1
          from private.parent_otp_delivery_outcomes outcome
          where outcome.delivery_attempt_id =
            delivery_attempt_id_text::uuid
        )
      then
        raise exception 'SENDGRID_EVENT_ACCEPTANCE_PENDING'
          using errcode = '40001';
      end if;
    elsif target = 'mail_test' then
      if delivery_id_text is null
        or delivery_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.mail_test_deliveries delivery
        where delivery.id = delivery_id_text::uuid
      )
        and not exists (
          select 1
          from private.mail_test_delivery_outcomes outcome
          where outcome.delivery_id = delivery_id_text::uuid
        )
      then
        raise exception 'SENDGRID_EVENT_ACCEPTANCE_PENDING'
          using errcode = '40001';
      end if;
    else
      raise exception 'SENDGRID_EVENT_READINESS_INVALID'
        using errcode = '22023';
    end if;
    ready_count := ready_count + 1;
  end loop;

  return jsonb_build_object('ready', ready_count);
end;
$$;

revoke all on function app.assert_sendgrid_events_ready_v1(jsonb)
from public, anon, authenticated;
grant execute on function app.assert_sendgrid_events_ready_v1(jsonb)
to service_role;

-- Serialize test events and recover a missing sg_message_id for a bounce from
-- the immutable Mail Send HTTP acceptance. No other event type may omit it.
create or replace function app.record_mail_test_sendgrid_events_v4(
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
  normalized_event_id text;
  delivery_id_text text;
  accepted_http_message_id text;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'MAIL_TEST_PROVIDER_EVENTS_INVALID'
      using errcode = '22023';
  end if;

  for normalized_event_id in
    select distinct nullif(btrim(item.value ->> 'event_id'), '')
    from jsonb_array_elements(p_events) item(value)
    where nullif(btrim(item.value ->> 'event_id'), '') is not null
    order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'mail-test-provider-event:' || normalized_event_id,
        0
      )
    );
  end loop;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    delivery_id_text :=
      nullif(btrim(event_item ->> 'delivery_id'), '');
    if event_item ->> 'event_type' = 'bounced'
      and nullif(btrim(event_item ->> 'provider_message_id'), '') is null
      and delivery_id_text ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      select acceptance.provider_http_message_id
      into accepted_http_message_id
      from private.mail_test_delivery_provider_acceptances acceptance
      where acceptance.delivery_id = delivery_id_text::uuid;
      if accepted_http_message_id is null
        and exists (
          select 1
          from private.mail_test_deliveries delivery
          where delivery.id = delivery_id_text::uuid
        )
        and not exists (
          select 1
          from private.mail_test_delivery_outcomes outcome
          where outcome.delivery_id = delivery_id_text::uuid
        )
      then
        raise exception 'SENDGRID_EVENT_ACCEPTANCE_PENDING'
          using errcode = '40001';
      end if;
      if accepted_http_message_id is not null then
        event_item := jsonb_set(
          event_item,
          '{provider_message_id}',
          to_jsonb(accepted_http_message_id),
          true
        );
      end if;
    end if;
    normalized_events :=
      normalized_events || jsonb_build_array(event_item);
  end loop;

  return app.record_mail_test_sendgrid_events_v2(normalized_events);
end;
$$;

revoke all on function app.record_mail_test_sendgrid_events_v3(jsonb)
from service_role;
revoke all on function app.record_mail_test_sendgrid_events_v4(jsonb)
from public, anon, authenticated;
grant execute on function app.record_mail_test_sendgrid_events_v4(jsonb)
to service_role;

create or replace function app.get_mail_test_delivery_status_v2(
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
    'deferredEventCount', (
      select count(*)
      from private.mail_test_delivery_provider_events provider_event
      where provider_event.delivery_id = target.id
        and provider_event.event_type = 'deferred'
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
    ),
    'quarantinedEventCount', (
      select count(*)
      from private.mail_test_delivery_provider_quarantine quarantine
      where quarantine.delivery_id = target.id
    )
  );
end;
$$;

revoke all on function app.get_mail_test_delivery_status_v1(uuid)
from authenticated;
revoke all on function app.get_mail_test_delivery_status_v2(uuid)
from public, anon;
grant execute on function app.get_mail_test_delivery_status_v2(uuid)
to authenticated;

revoke all on function app.get_operational_health_v11(
  text, integer, text, integer
) from service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260803245000_sendgrid_event_readiness_and_test_status',
  'passed',
  jsonb_build_object(
    'strategy',
      'retry signed callbacks until immutable HTTP acceptance exists',
    'accepted_test_deliveries',
      (select count(*)
       from private.mail_test_delivery_provider_acceptances),
    'recorded_test_events',
      (select count(*)
       from private.mail_test_delivery_provider_events),
    'quarantined_test_events',
      (select count(*)
       from private.mail_test_delivery_provider_quarantine)
  )
);

notify pgrst, 'reload schema';

-- Serialize provider events by immutable event identity before the v2 recorder
-- performs its compare-and-insert flow. This makes identical retries resolve
-- as ignored and conflicting retries resolve as durable quarantine events.

create or replace function app.record_mail_test_sendgrid_events_v3(
  p_events jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  normalized_event_id text;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'MAIL_TEST_PROVIDER_EVENTS_INVALID'
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
        'mail-test-provider-event:' || normalized_event_id,
        0
      )
    );
  end loop;

  return app.record_mail_test_sendgrid_events_v2(p_events);
end;
$$;

revoke all on function app.record_mail_test_sendgrid_events_v2(jsonb)
from service_role;
revoke all on function app.record_mail_test_sendgrid_events_v3(jsonb)
from public, anon, authenticated;
grant execute on function app.record_mail_test_sendgrid_events_v3(jsonb)
to service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260803240000_mail_test_event_concurrency',
  'passed',
  jsonb_build_object(
    'strategy',
      'serialize immutable SendGrid test event identities before compare and insert',
    'existing_test_provider_events',
      (select count(*)
       from private.mail_test_delivery_provider_events),
    'existing_test_provider_quarantine',
      (select count(*)
       from private.mail_test_delivery_provider_quarantine)
  )
);

notify pgrst, 'reload schema';

-- The readiness check normally catches this ordering. Keep the final mail-test
-- recorder safe when acceptance disappears in the narrow interval between the
-- two RPCs, without using the retry-reserved SQLSTATE 40001.

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
        return jsonb_build_object(
          'recorded', 0,
          'ignored', 0,
          'quarantined', 0,
          'pending', true
        );
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

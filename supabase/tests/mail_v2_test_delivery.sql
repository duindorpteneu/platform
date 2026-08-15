begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e3300000-0000-4000-8000-000000000001', 'Testmailbeheerder', 'beheerder'),
  ('e3300000-0000-4000-8000-000000000002', 'Testmailcommissie', 'kledingcommissie');

select ok(
  not has_table_privilege(
    'authenticated',
    'private.mail_test_deliveries',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'browserrollen hebben geen directe testdelivery-ledgertoegang'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.mail_test_deliveries',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role heeft geen brede testdelivery-ledgertoegang'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.prepare_mail_test_delivery_v1(uuid,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated krijgt alleen het voorbereidings-RPC-contract'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.finalize_mail_test_delivery_v2(uuid,text,text,uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.finalize_mail_test_delivery_v1(uuid,text,uuid)',
    'EXECUTE'
  ),
  'alleen providergebonden finalisatie is extern bereikbaar'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.record_mail_test_sendgrid_events_v4(jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.assert_sendgrid_events_ready_v1(jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_mail_test_sendgrid_events_v3(jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_mail_test_sendgrid_events_v1(jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_mail_test_sendgrid_events_v2(jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'app.get_mail_test_delivery_status_v2(uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.get_mail_test_delivery_status_v1(uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.get_operational_health_v12(text,integer,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.get_operational_health_v11(text,integer,text,integer)',
    'EXECUTE'
  ),
  'service_role heeft alleen de nieuwste webhook- en healthgrens'
);

select is(
  (
    select enabled::text
    from app.release_feature_flags
    where key = 'mail_templates_v2'
  ),
  'false',
  'beheerderstestdelivery blijft vóór de operationele mailcutover beschikbaar'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e3300000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.prepare_mail_test_delivery_v1(
    'e3300000-0000-4000-8000-000000000010',
    'package_complete',
    repeat('a', 64),
    null
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 kan geen testmail voorbereiden'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e3300000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.prepare_mail_test_delivery_v1(
    'e3300000-0000-4000-8000-000000000010',
    'package_complete',
    repeat('a', 64),
    null
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan geen testmail voorbereiden'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e3300000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

create temporary table saved_test_template as
select app.save_mail_template_draft_v1(
  'package_complete',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'package_complete'
      and status = 'draft'
  ),
  'Testmail pakket compleet',
  'Voorbeeldpakket compleet voor {{member_first_name}}',
  'Fictieve controle voor seizoen {{season_name}}.',
  '{
    "type":"doc",
    "content":[
      {"type":"paragraph","content":[{"type":"text","text":"Fictieve testinhoud"}]},
      {"type":"protectedBlock","attrs":{"kind":"full_package"}}
    ]
  }'::jsonb,
  '<p>Fictieve testinhoud</p><table><tbody><tr><td>Voorbeeldproduct</td></tr></tbody></table>',
  'Fictieve testinhoud met het volledige voorbeeldpakket.',
  null
) result;
grant select on saved_test_template to authenticated;

create temporary table published_test_template as
select app.publish_mail_template_revision_v1(
  (select (result->>'revisionId')::uuid from saved_test_template),
  (select result->>'contentHash' from saved_test_template),
  null
) result;
grant select on published_test_template to authenticated;

reset role;
create temporary table test_delivery_baseline as
select
  (select count(*) from private.email_jobs) as email_jobs,
  (select count(*) from private.mail_v2_domain_events) as domain_events,
  (select count(*) from private.mail_reminder_runs) as reminder_runs;
grant select on test_delivery_baseline to authenticated;
set local role authenticated;

create temporary table prepared_test_delivery as
select app.prepare_mail_test_delivery_v1(
  'e3300000-0000-4000-8000-000000000011',
  'package_complete',
  (select result->>'contentHash' from published_test_template),
  'e3300000-0000-4000-8000-000000000012'
) result;
grant select on prepared_test_delivery to authenticated;

select is(
  (select result->>'status' from prepared_test_delivery),
  'prepared',
  'een gepubliceerde template wordt één keer voorbereid'
);
select is(
  (select result->>'reused' from prepared_test_delivery),
  'false',
  'de eerste voorbereiding is verzendbaar'
);
reset role;
select throws_ok(
  format(
    $sql$select app.assert_sendgrid_events_ready_v1(
      jsonb_build_array(
        jsonb_build_object(
          'target', 'mail_test',
          'delivery_id', %L
        )
      )
    )$sql$,
    (select result->>'deliveryId' from prepared_test_delivery)
  ),
  '40001',
  'SENDGRID_EVENT_ACCEPTANCE_PENDING',
  'signed testevent vóór HTTP-acceptatie is retrybaar'
);
select is(
  (
    select count(*)
    from private.mail_test_delivery_provider_quarantine quarantine
    where quarantine.delivery_id = (
      select (result->>'deliveryId')::uuid
      from prepared_test_delivery
    )
  ),
  0::bigint,
  'readiness-preflight maakt van een geldige vroege callback geen quarantaine'
);
set local role authenticated;
select is(
  (select result#>>'{template,source,templateKey}' from prepared_test_delivery),
  'package_complete',
  'de voorbereiding bindt de immutable gepubliceerde template'
);
select ok(
  (
    select result::text
      !~* 'testinbox|recipientEmail|providerMessage|emailJob'
    from prepared_test_delivery
  ),
  'de voorbereiding bevat geen ontvanger-, provider- of ledenjobgegevens'
);

select is(
  app.prepare_mail_test_delivery_v1(
    'e3300000-0000-4000-8000-000000000011',
    'package_complete',
    (select result->>'contentHash' from published_test_template),
    null
  )->>'reused',
  'true',
  'dezelfde request-ID wordt nooit opnieuw verzendbaar'
);

select throws_ok(
  $$select app.prepare_mail_test_delivery_v1(
    'e3300000-0000-4000-8000-000000000011',
    'package_complete',
    repeat('f', 64),
    null
  )$$,
  '23505',
  'MAIL_TEST_REQUEST_CONFLICT',
  'een request-ID kan niet aan andere template-inhoud worden hergebonden'
);

create temporary table finalized_test_delivery as
select app.finalize_mail_test_delivery_v2(
  (select (result->>'deliveryId')::uuid from prepared_test_delivery),
  'accepted',
  'test-http-provider-message-1',
  'e3300000-0000-4000-8000-000000000013'
) result;
grant select on finalized_test_delivery to authenticated;

select is(
  (select result->>'status' from finalized_test_delivery),
  'accepted',
  'provideracceptatie wordt één keer duurzaam vastgelegd'
);
select is(
  app.finalize_mail_test_delivery_v2(
    (select (result->>'deliveryId')::uuid from prepared_test_delivery),
    'accepted',
    'test-http-provider-message-1',
    null
  )->>'reused',
  'true',
  'dezelfde finale uitkomst is idempotent'
);
select throws_ok(
  $$select app.finalize_mail_test_delivery_v2(
    (select (result->>'deliveryId')::uuid from prepared_test_delivery),
    'delivery_uncertain',
    null,
    null
  )$$,
  '40001',
  'MAIL_TEST_OUTCOME_CONFLICT',
  'een finale uitkomst kan niet worden herschreven'
);

select is(
  app.prepare_mail_test_delivery_v1(
    'e3300000-0000-4000-8000-000000000011',
    'package_complete',
    (select result->>'contentHash' from published_test_template),
    null
  )->>'status',
  'accepted',
  'een herhaalde routeaanvraag ziet de finale status en verzendt niet opnieuw'
);
reset role;
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'mail_test',
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery)
      )
    )
  )->>'ready',
  '1',
  'na immutable HTTP-acceptatie mag de callback door'
);

create temporary table recorded_test_provider_event as
select app.record_mail_test_sendgrid_events_v4(
  jsonb_build_array(
    jsonb_build_object(
      'delivery_id',
      (select result->>'deliveryId' from prepared_test_delivery),
      'event_id',
      'test-delivery-provider-event-1',
      'provider_message_id',
      'test-http-provider-message-1.filter0001.42.0',
      'event_type',
      'delivered',
      'occurred_at',
      statement_timestamp()
    )
  )
) result;
select is(
  (select result->>'recorded' from recorded_test_provider_event),
  '1',
  'gesigneerd provider-event wordt aan exact de testdelivery gekoppeld'
);
select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery),
        'event_id',
        'test-delivery-provider-event-1',
        'provider_message_id',
        'test-http-provider-message-1.filter0001.42.0',
        'event_type',
        'delivered',
        'occurred_at',
        (
          select occurred_at
          from private.mail_test_delivery_provider_events
          where provider_event_id =
            'test-delivery-provider-event-1'
        )
      )
    )
  )->>'ignored',
  '1',
  'exacte testdelivery-webhookreplay is idempotent'
);

select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery),
        'event_id',
        'test-delivery-provider-event-cross-message',
        'provider_message_id',
        'other-http-message.filter0001.42.0',
        'event_type',
        'delivered',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'quarantined',
  '1',
  'event van een andere provider-message kan dezelfde delivery-ID niet groen maken'
);
select is(
  (select count(*)
   from private.mail_test_delivery_provider_events
   where provider_event_id =
     'test-delivery-provider-event-cross-message'),
  0::bigint,
  'cross-message-event wordt niet in de acceptatieledger opgenomen'
);
select is(
  (select count(*)
   from private.mail_test_delivery_provider_quarantine
   where reason = 'provider_message_mismatch'),
  1::bigint,
  'cross-message-event wordt PII-vrij als mismatch gequarantaineerd'
);
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'mail_test',
        'delivery_id',
        'e3300000-0000-4000-8000-000000000099'
      )
    )
  )->>'ready',
  '1',
  'een onbekende delivery-identiteit is permanent ongeldig en niet retrybaar'
);
select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        'e3300000-0000-4000-8000-000000000099',
        'event_id',
        'test-delivery-provider-unknown',
        'provider_message_id',
        'unknown-provider-message',
        'event_type',
        'delivered',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'quarantined',
  '1',
  'een onbekende delivery-identiteit stroomt door naar duurzame quarantaine'
);
insert into private.mail_test_deliveries(
  id,
  request_id,
  actor_user_id,
  template_key,
  template_revision_id,
  template_content_hash,
  branding_revision_id
)
select
  'e3300000-0000-4000-8000-000000000098',
  'e3300000-0000-4000-8000-000000000097',
  delivery.actor_user_id,
  delivery.template_key,
  delivery.template_revision_id,
  delivery.template_content_hash,
  delivery.branding_revision_id
from private.mail_test_deliveries delivery
where delivery.id = (
  select (result->>'deliveryId')::uuid
  from prepared_test_delivery
);
insert into private.mail_test_delivery_outcomes(
  delivery_id,
  outcome,
  finalized_by
) values (
  'e3300000-0000-4000-8000-000000000098',
  'provider_rejected',
  'e3300000-0000-4000-8000-000000000001'
);
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'mail_test',
        'delivery_id',
        'e3300000-0000-4000-8000-000000000098'
      )
    )
  )->>'ready',
  '1',
  'een definitief provider-afgewezen delivery is niet retrybaar'
);
select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        'e3300000-0000-4000-8000-000000000098',
        'event_id',
        'test-delivery-provider-rejected',
        'event_type',
        'bounced',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'quarantined',
  '1',
  'definitief afgewezen callbackbewijs stroomt door naar quarantaine'
);
select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery),
        'event_id',
        'test-delivery-provider-bounce-no-message',
        'event_type',
        'bounced',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'recorded',
  '1',
  'testdelivery-bounce zonder message-ID gebruikt exact de HTTP-acceptatie'
);
select is(
  (
    select provider_message_id
    from private.mail_test_delivery_provider_events
    where provider_event_id =
      'test-delivery-provider-bounce-no-message'
  ),
  'test-http-provider-message-1',
  'de herleide bounce bewaart uitsluitend de immutable HTTP-messagebinding'
);
select is(
  app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery),
        'event_id',
        'test-delivery-provider-deferred',
        'provider_message_id',
        'test-http-provider-message-1.filter0001.43.0',
        'event_type',
        'deferred',
        'occurred_at',
        statement_timestamp()
      ),
      jsonb_build_object(
        'delivery_id',
        (select result->>'deliveryId' from prepared_test_delivery),
        'event_id',
        'test-delivery-provider-dropped',
        'provider_message_id',
        'test-http-provider-message-1.filter0001.44.0',
        'event_type',
        'dropped',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'recorded',
  '2',
  'deferred en dropped worden afzonderlijk en immutable vastgelegd'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e3300000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_mail_test_delivery_status_v2(
    (select (result->>'deliveryId')::uuid
     from prepared_test_delivery)
  ) #>> '{deliveredEventCount}',
  '1',
  'beheerder kan zonder provider-ID de echte callbackstatus verifiëren'
);
select is(
  app.get_mail_test_delivery_status_v2(
    (select (result->>'deliveryId')::uuid
     from prepared_test_delivery)
  ) #>> '{deferredEventCount}',
  '1',
  'de teststatus telt tijdelijke provideruitstel apart'
);
select is(
  app.get_mail_test_delivery_status_v2(
    (select (result->>'deliveryId')::uuid
     from prepared_test_delivery)
  ) #>> '{failureEventCount}',
  '2',
  'bounce en drop tellen als definitieve providerfouten'
);
select is(
  app.get_mail_test_delivery_status_v2(
    (select (result->>'deliveryId')::uuid
     from prepared_test_delivery)
  ) #>> '{quarantinedEventCount}',
  '1',
  'teststatus maakt deliverygebonden quarantaine expliciet'
);
reset role;

select is(
  app.get_operational_health_v12(
    repeat('a', 64),
    1,
    null,
    null
  ) #>> '{emailControl,testEventQuarantined}',
  '3',
  'operationele health blokkeert op testdelivery-quarantaine zonder providerdata te tonen'
);

select is(
  (select count(*) from private.mail_test_deliveries
    where request_id = 'e3300000-0000-4000-8000-000000000011'),
  1::bigint,
  'de intent-ledger bevat exact één record per request-ID'
);
select is(
  (select count(*) from private.mail_test_delivery_outcomes
    where delivery_id = (
      select (result->>'deliveryId')::uuid from prepared_test_delivery
    )),
  1::bigint,
  'de outcome-ledger bevat exact één finale uitkomst'
);
select is(
  (select count(*) from private.email_jobs),
  (select email_jobs from test_delivery_baseline),
  'testdelivery maakt geen leden-emailjob'
);
select is(
  (select count(*) from private.mail_v2_domain_events),
  (select domain_events from test_delivery_baseline),
  'testdelivery maakt geen domeinevent'
);
select is(
  (select count(*) from private.mail_reminder_runs),
  (select reminder_runs from test_delivery_baseline),
  'testdelivery maakt geen herinneringsrun'
);
select is(
  (select count(*) from app.audit_logs
    where entity_type = 'mail_test_delivery'
      and entity_id = (
        select (result->>'deliveryId')::uuid
        from prepared_test_delivery
      )
      and action in (
        'email.test_delivery.prepared',
        'email.test_delivery.finalized'
      )
      and metadata::text !~* 'testinbox|@|subject|html|body|provider'),
  2::bigint,
  'audit bevat alleen veilige revisie- en uitkomstmetadata'
);

select throws_ok(
  $$update private.mail_test_deliveries
    set template_key = 'partial_pickup'
    where request_id = 'e3300000-0000-4000-8000-000000000011'$$,
  '23514',
  'MAIL_TEST_DELIVERY_IMMUTABLE',
  'de voorbereidingsledger is immutable'
);
select throws_ok(
  $$delete from private.mail_test_delivery_outcomes
    where delivery_id = (
      select (result->>'deliveryId')::uuid from prepared_test_delivery
    )$$,
  '23514',
  'MAIL_TEST_DELIVERY_IMMUTABLE',
  'de outcome-ledger is immutable'
);
select throws_ok(
  $$delete from private.mail_test_delivery_provider_events
    where provider_event_id =
      'test-delivery-provider-event-1'$$,
  '23514',
  'MAIL_TEST_DELIVERY_IMMUTABLE',
  'de provider-eventledger is immutable'
);

select * from finish();
rollback;
reset role;

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(
  auth_user_id,
  display_name,
  role
) values (
  '27900000-0000-4000-8000-000000000001',
  'OTP-beheerder',
  'beheerder'
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  '27910000-0000-4000-8000-000000000001',
  'OTP-001',
  'Olivier',
  'Eenmalig',
  'otp-parent@example.invalid',
  'JO11-1'
);
insert into private.parent_accounts(
  id,
  email_normalized
) values (
  '27920000-0000-4000-8000-000000000001',
  'otp-parent@example.invalid'
);
insert into private.parent_portal_grants(
  id,
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  granted_by,
  granted_at
)
select
  '27930000-0000-4000-8000-000000000001',
  member_season.id,
  'otp-parent@example.invalid',
  '27920000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  '27900000-0000-4000-8000-000000000001',
  statement_timestamp()
from app.member_seasons member_season
where member_season.member_id =
  '27910000-0000-4000-8000-000000000001';

select ok(
  not has_table_privilege(
    'service_role',
    'private.parent_otp_delivery_attempts',
    'SELECT'
  )
  and not has_table_privilege(
    'authenticated',
    'private.parent_otp_provider_events',
    'SELECT'
  )
  and not has_table_privilege(
    'anon',
    'private.parent_otp_delivery_outcomes',
    'SELECT'
  ),
  'OTP-afleverfeiten zijn voor alle API-rollen default-deny'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.prepare_parent_otp_delivery_v1(text,text,timestamptz)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.authorize_parent_otp_delivery_v1(uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.complete_parent_otp_delivery_v1(uuid,text,text,text)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.record_parent_otp_sendgrid_events_v3(jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.assert_sendgrid_events_ready_v1(jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_parent_otp_sendgrid_events_v2(jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_parent_otp_sendgrid_events_v1(jsonb)',
    'EXECUTE'
  ),
  'service_role heeft uitsluitend de smalle OTP-RPC-grens'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.get_operational_health_v13(text,integer,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.get_operational_health_v13(text,integer,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'app.get_operational_health_v13(text,integer,text,integer)',
    'EXECUTE'
  ),
  'de gecorrigeerde operationele health blijft service-only'
);
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'parent_otp',
        'delivery_attempt_id',
        '27940000-0000-4000-8000-000000000099'
      )
    )
  )->>'ready',
  '1',
  'onbekende OTP-identiteiten zijn permanent ongeldig en niet retrybaar'
);
select is(
  (
    select count(*)::integer
    from information_schema.columns column_row
    where column_row.table_schema = 'private'
      and column_row.table_name in (
        'parent_otp_delivery_attempts',
        'parent_otp_delivery_outcomes',
        'parent_otp_provider_message_bindings',
        'parent_otp_provider_events',
        'parent_otp_provider_event_quarantine'
      )
      and column_row.column_name ~
        '(email|code_hash|render|subject|html|text)'
  ),
  0,
  'de afleverledger heeft geen ontvanger, code(hash) of renderkolom'
);
select is(
  app.prepare_parent_otp_delivery_v1(
    'otp-parent@example.invalid',
    repeat('a', 64),
    statement_timestamp() + interval '10 minutes'
  )->>'status',
  'unavailable',
  'vóór het immutable cutoverwatermerk blijft de legacyadapter actief'
);
select is(
  (
    select count(*)::integer
    from private.parent_otp_challenges
    where parent_account_id =
      '27920000-0000-4000-8000-000000000001'
  ),
  0,
  'de v2-voorbereiding maakt vóór cutover geen dubbele challenge'
);

insert into private.release_cutovers(key)
values('mail_templates_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';
update app.app_settings
set email_enabled = true
where id = true;
select is(
  app.prepare_parent_otp_delivery_v1(
    'otp-parent@example.invalid',
    repeat('b', 64),
    statement_timestamp() + interval '10 minutes'
  )->>'status',
  'blocked',
  'een gestart cutover valt bij ontbrekende publicatie nooit terug'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"27900000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_login_otp as
select app.save_mail_template_draft_v1(
  'login_otp',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'login_otp'
      and status = 'draft'
  ),
  'Inlogcode OTP-v2 fixture',
  'Uw code voor {{club_name}}',
  'Gebruik de code binnen {{otp_expiry_minutes}} minuten.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Gebruik uw eenmalige code."}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"otp_code"}},
      {"type":"protectedBlock","attrs":{"kind":"otp_validity"}},
      {"type":"protectedBlock","attrs":{"kind":"otp_warning"}}
    ]
  }'::jsonb,
  '<p>Gebruik uw eenmalige code.</p>',
  'Gebruik uw eenmalige code.',
  null
) result;
create temporary table published_login_otp as
select app.publish_mail_template_revision_v1(
  (select (result->>'revisionId')::uuid from saved_login_otp),
  (select result->>'contentHash' from saved_login_otp),
  null
) result;
reset role;
select is(
  (select result->>'status' from published_login_otp),
  'published',
  'de beschermde LOGIN_OTP-template kan beheerd worden gepubliceerd'
);

select is(
  app.prepare_parent_otp_delivery_v1(
    'unknown-parent@example.invalid',
    repeat('c', 64),
    statement_timestamp() + interval '10 minutes'
  )->>'status',
  'ineligible',
  'een onbekende ontvanger krijgt intern alleen een neutrale suppressie'
);
select is(
  (
    select count(*)::integer
    from private.parent_otp_delivery_attempts
  ),
  0,
  'een onbekende ontvanger krijgt geen afleverpoging'
);

create temporary table prepared_otp as
select app.prepare_parent_otp_delivery_v1(
  'otp-parent@example.invalid',
  repeat('d', 64),
  statement_timestamp() + interval '10 minutes'
) result;
select is(
  (select result->>'status' from prepared_otp),
  'prepared',
  'een geautoriseerde ouder krijgt één v2-afleverpoging'
);
select is(
  (
    select result #>> '{template,templateKey}'
    from prepared_otp
  ),
  'login_otp',
  'de poging is exact aan LOGIN_OTP gebonden'
);
select is(
  (
    select count(*)::integer
    from private.parent_otp_delivery_attempts
  ),
  1,
  'de voorbereiding schrijft exact één immutable poging'
);
select ok(
  app.authorize_parent_otp_delivery_v1(
    (
      select (result->>'deliveryAttemptId')::uuid
      from prepared_otp
    )
  ),
  'send-time autorisatie hercontroleert challenge, toegang en mailpoort'
);
select throws_ok(
  format(
    $sql$select app.assert_sendgrid_events_ready_v1(
      jsonb_build_array(
        jsonb_build_object(
          'target', 'parent_otp',
          'delivery_attempt_id', %L
        )
      )
    )$sql$,
    (select result->>'deliveryAttemptId' from prepared_otp)
  ),
  '40001',
  'SENDGRID_EVENT_ACCEPTANCE_PENDING',
  'OTP-callback vóór HTTP-acceptatie wordt retrybaar geweigerd'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp),
        'event_id',
        'otp-provider-event-before-http-acceptance',
        'provider_message_id',
        'http-message-otp-1.filter0001.41.0',
        'event_type',
        'delivered',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'quarantined',
  '1',
  'OTP-provider-event vóór immutable HTTP-acceptatie projecteert nooit'
);
select ok(
  (
    select code_hash = repeat('d', 64)
      and used_at is null
    from private.parent_otp_challenges
    where id = (
      select attempt.challenge_id
      from private.parent_otp_delivery_attempts attempt
      where attempt.id = (
        select (result->>'deliveryAttemptId')::uuid
        from prepared_otp
      )
    )
  ),
  'alleen de bestaande beveiligde challenge bewaart de codehash'
);
select ok(
  coalesce((
    select string_agg(audit.metadata::text, E'\n')
    from app.audit_logs audit
    where audit.action like 'parent.otp.delivery.%'
  ), '') not like
    '%dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd%',
  'auditmetadata bevat geen OTP-codehash'
);
select is(
  app.complete_parent_otp_delivery_v1(
    (
      select (result->>'deliveryAttemptId')::uuid
      from prepared_otp
    ),
    'accepted',
    'http-message-otp-1',
    null
  )->>'reused',
  'false',
  'provideracceptatie schrijft de eerste completion'
);
select is(
  app.complete_parent_otp_delivery_v1(
    (
      select (result->>'deliveryAttemptId')::uuid
      from prepared_otp
    ),
    'accepted',
    'http-message-otp-1',
    null
  )->>'reused',
  'true',
  'exacte completion replay is idempotent'
);
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'parent_otp',
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp)
      )
    )
  )->>'ready',
  '1',
  'OTP-callback is gereed na immutable HTTP-acceptatie'
);
select throws_ok(
  format(
    $sql$select app.complete_parent_otp_delivery_v1(
      %L::uuid,
      'delivery_uncertain',
      null,
      'delivery_uncertain'
    )$sql$,
    (
      select result->>'deliveryAttemptId'
      from prepared_otp
    )
  ),
  '23505',
  'PARENT_OTP_DELIVERY_OUTCOME_CONFLICT',
  'een tegenstrijdige completion kan het resultaat niet herschrijven'
);
select throws_ok(
  format(
    $sql$update private.parent_otp_delivery_outcomes
      set outcome = 'delivery_uncertain'
      where delivery_attempt_id = %L::uuid$sql$,
    (
      select result->>'deliveryAttemptId'
      from prepared_otp
    )
  ),
  '23514',
  'PARENT_OTP_DELIVERY_LEDGER_IMMUTABLE',
  'normale updates op afleverfeiten zijn geblokkeerd'
);

insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at
)
select
  '27940000-0000-4000-8000-000000000098',
  attempt.parent_account_id,
  '27950000-0000-4000-8000-000000000098',
  attempt.template_revision_id,
  attempt.branding_revision_id,
  statement_timestamp() + interval '10 minutes'
from private.parent_otp_delivery_attempts attempt
where attempt.id = (
  select (result->>'deliveryAttemptId')::uuid
  from prepared_otp
);
insert into private.parent_otp_delivery_outcomes(
  delivery_attempt_id,
  outcome,
  error_code
) values (
  '27940000-0000-4000-8000-000000000098',
  'provider_rejected',
  'provider_rejected'
);
select is(
  (
    app.get_operational_health_v13(
      repeat('a', 64),
      1,
      null,
      null
    ) #>> '{parentOtpDelivery,sendFailuresRecent}'
  )::integer,
  1,
  'een recente providerafwijzing blijft releaseblokkerend'
);
insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at
)
select
  '27940000-0000-4000-8000-000000000097',
  attempt.parent_account_id,
  '27950000-0000-4000-8000-000000000097',
  attempt.template_revision_id,
  attempt.branding_revision_id,
  statement_timestamp() + interval '10 minutes'
from private.parent_otp_delivery_attempts attempt
where attempt.id = '27940000-0000-4000-8000-000000000098';
insert into private.parent_otp_delivery_outcomes(
  delivery_attempt_id,
  outcome,
  error_code
) values (
  '27940000-0000-4000-8000-000000000097',
  'configuration_error',
  'configuration_error'
);
select is(
  (
    app.get_operational_health_v12(
      repeat('a', 64),
      1,
      null,
      null
    ) #>> '{parentOtpDelivery,sendFailuresRecent}'
  )::integer,
  2,
  'de historische health telt de actuele configuratiefout nog als incident'
);
select is(
  (
    app.get_operational_health_v13(
      repeat('a', 64),
      1,
      null,
      null
    ) #>> '{parentOtpDelivery,sendFailuresRecent}'
  )::integer,
  1,
  'actuele runtimebinding vervangt historische configuratiefouten als readinesspoort'
);
select is(
  app.assert_sendgrid_events_ready_v1(
    jsonb_build_array(
      jsonb_build_object(
        'target',
        'parent_otp',
        'delivery_attempt_id',
        '27940000-0000-4000-8000-000000000098'
      )
    )
  )->>'ready',
  '1',
  'een definitief afgewezen OTP-delivery is niet retrybaar'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        '27940000-0000-4000-8000-000000000098',
        'event_id',
        'otp-provider-rejected-attempt',
        'provider_message_id',
        'otp-provider-rejected-message',
        'event_type',
        'delivered',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'quarantined',
  '1',
  'callback voor definitief afgewezen OTP-delivery wordt gequarantaineerd'
);

create temporary table provider_event as
select app.record_parent_otp_sendgrid_events_v3(
  jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id',
      (select result->>'deliveryAttemptId' from prepared_otp),
      'event_id',
      'otp-provider-event-1',
      'provider_message_id',
      'http-message-otp-1.filter0001.42.0',
      'event_type',
      'delivered',
      'occurred_at',
      statement_timestamp()
    )
  )
) result;
select is(
  (select result->>'recorded' from provider_event),
  '1',
  'een attempt-gebonden provider-event wordt vastgelegd'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp),
        'event_id',
        'otp-provider-bounce-without-message-id',
        'event_type',
        'bounced',
        'occurred_at',
        statement_timestamp()
      )
    )
  )->>'recorded',
  '1',
  'OTP-bounce zonder message-ID gebruikt alleen de geaccepteerde attemptbinding'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp),
        'event_id',
        'otp-provider-event-1',
        'provider_message_id',
        'http-message-otp-1.filter0001.42.0',
        'event_type',
        'delivered',
        'occurred_at',
        (
          select occurred_at
          from private.parent_otp_provider_events
          where provider_event_id = 'otp-provider-event-1'
        )
      )
    )
  )->>'ignored',
  '1',
  'exacte providerreplay is idempotent'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp),
        'event_id',
        'otp-provider-cross-message',
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
  'OTP-event van een ander HTTP-bericht projecteert nooit'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from prepared_otp),
        'event_id',
        'otp-provider-event-1',
        'provider_message_id',
        'http-message-otp-1.filter0001.42.0',
        'event_type',
        'bounced',
        'occurred_at',
        (
          select occurred_at
          from private.parent_otp_provider_events
          where provider_event_id = 'otp-provider-event-1'
        )
      )
    )
  )->>'quarantined',
  '1',
  'een tegenstrijdig provider-event gaat naar quarantaine'
);
select is(
  (
    select (
      app.get_operational_health_v9(
        repeat('a', 64),
        1,
        null,
        null
      ) #>> '{parentOtpDelivery,quarantinedEvents}'
    )::integer
  ),
  4,
  'providerquarantaine is releaseblokkerend zichtbaar in health'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_process_capabilities capability
    where capability.enabled
  ),
  19,
  'alle negentien mailcatalogusprocessen hebben een producent'
);

insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at,
  created_at
)
select
  '27940000-0000-4000-8000-000000000001',
  '27920000-0000-4000-8000-000000000001',
  '27950000-0000-4000-8000-000000000001',
  template_revision.id,
  branding.id,
  timestamptz '2026-01-01 00:10:00+00',
  timestamptz '2026-01-01 00:00:00+00'
from app.mail_template_revisions template_revision
cross join app.mail_branding_revisions branding
where template_revision.template_key = 'login_otp'
  and template_revision.status = 'published'
  and branding.status = 'published';
insert into private.parent_otp_delivery_outcomes(
  delivery_attempt_id,
  outcome,
  error_code,
  created_at
) values (
  '27940000-0000-4000-8000-000000000001',
  'provider_rejected',
  'provider_rejected',
  timestamptz '2026-01-01 00:01:00+00'
);
select cmp_ok(
  app.purge_parent_otp_delivery_history_v1(
    timestamptz '2026-08-03 12:00:00+00',
    90,
    500
  ),
  '>=',
  2,
  'expliciete operationele retentie verwijdert oude pogingfeiten'
);
select is(
  (
    select count(*)::integer
    from private.parent_otp_delivery_attempts
    where id = '27940000-0000-4000-8000-000000000001'
  ),
  0,
  'retentie verwijdert alleen de expliciet vervallen poging'
);

select * from finish();
rollback;

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('31a00000-0000-4000-8000-000000000001', 'OTP v3 beheerder', 'beheerder'),
  ('31a00000-0000-4000-8000-000000000002', 'OTP v3 commissie', 'kledingcommissie');

insert into app.members(
  id, relation_number, first_name, last_name, email, team
) values (
  '31a10000-0000-4000-8000-000000000001',
  'OTP-V3-001',
  'Veilige',
  'Ouderlogin',
  'ouder-v3@example.invalid',
  'JO14-1'
);
insert into private.parent_accounts(id, email_normalized) values (
  '31a20000-0000-4000-8000-000000000001',
  'ouder-v3@example.invalid'
);
insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source, granted_by, granted_at
)
select
  '31a30000-0000-4000-8000-000000000001',
  season.id,
  'ouder-v3@example.invalid',
  '31a20000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  '31a00000-0000-4000-8000-000000000001',
  statement_timestamp()
from app.member_seasons season
where season.member_id = '31a10000-0000-4000-8000-000000000001';

insert into private.release_cutovers(key)
values('mail_templates_v2') on conflict (key) do nothing;
update app.release_feature_flags set enabled = true
where key = 'mail_templates_v2';
update app.app_settings set email_enabled = true where id = true;

select ok(
  has_function_privilege(
    'service_role',
    'app.prepare_parent_otp_delivery_v3(text,uuid,text,boolean,uuid,uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.consume_parent_login_challenge_v3(uuid,text,text,text,timestamptz)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.prepare_parent_otp_delivery_v3(text,uuid,text,boolean,uuid,uuid)',
    'EXECUTE'
  ),
  'challengevoorbereiding en consumptie blijven service-only'
);

create temporary table first_prepare as
select app.prepare_parent_otp_delivery_v3(
  'ouder-v3@example.invalid',
  '31a40000-0000-4000-8000-000000000001',
  repeat('1', 64),
  false,
  null
) result;
select is((select result->>'status' from first_prepare), 'prepared',
  'de eerste aanvraag maakt een v3-challenge');
select is((select result->>'reused' from first_prepare), 'false',
  'de eerste aanvraag is geen resend');
select ok(
  not ((select result from first_prepare) ?| array[
    'code', 'codeHash', 'credential', 'directCredential', 'proof'
  ]),
  'de voorbereidings-RPC retourneert nooit een credential'
);

update private.rate_limit_events
set occurred_at = statement_timestamp() - interval '91 seconds'
where scope = 'otp_request'
  and key_hash = encode(
    extensions.digest('ouder-v3@example.invalid', 'sha256'),
    'hex'
  );
create temporary table resend_prepare as
select app.prepare_parent_otp_delivery_v3(
  'ouder-v3@example.invalid',
  '31a40000-0000-4000-8000-000000000002',
  repeat('2', 64),
  false,
  null
) result;
select is(
  (select result->>'challengeId' from resend_prepare),
  (select result->>'challengeId' from first_prepare),
  'resend gebruikt dezelfde challenge en dus dezelfde afgeleide credentials'
);
select is((select result->>'reused' from resend_prepare), 'true',
  'de resend wordt expliciet als hergebruik gemarkeerd');
select is(
  (select code_hash from private.parent_otp_challenges
    where id = '31a40000-0000-4000-8000-000000000001'),
  repeat('1', 64),
  'resend vervangt de bestaande verificatiehash niet'
);
select is(
  (select count(*) from private.parent_otp_delivery_attempts
    where challenge_id = '31a40000-0000-4000-8000-000000000001'),
  2::bigint,
  'iedere resend heeft wel een eigen immutable afleverpoging'
);

create temporary table cooled_reset as
select app.prepare_parent_otp_delivery_v3(
  'ouder-v3@example.invalid',
  '31a40000-0000-4000-8000-000000000003',
  repeat('3', 64),
  true,
  null,
  '31a40000-0000-4000-8000-000000000001'
) result;
select is((select result->>'status' from cooled_reset), 'cooldown',
  'een expliciete reset respecteert de publieke cooldown');
select is(
  (select count(*) from private.parent_otp_challenges
    where id = '31a40000-0000-4000-8000-000000000001'
      and closed_at is null and used_at is null),
  1::bigint,
  'een geblokkeerde reset invalideert de bruikbare challenge niet'
);

update private.rate_limit_events
set occurred_at = statement_timestamp() - interval '91 seconds'
where scope = 'otp_request'
  and key_hash = encode(
    extensions.digest('ouder-v3@example.invalid', 'sha256'),
    'hex'
  );
create temporary table reset_prepare as
select app.prepare_parent_otp_delivery_v3(
  'ouder-v3@example.invalid',
  '31a40000-0000-4000-8000-000000000003',
  repeat('3', 64),
  true,
  null,
  '31a40000-0000-4000-8000-000000000001'
) result;
select is((select result->>'status' from reset_prepare), 'prepared',
  'Nieuwe code maakt na de cooldown een vervangende challenge');
select is((select result->>'challengeId' from reset_prepare),
  '31a40000-0000-4000-8000-000000000003',
  'de expliciete reset gebruikt de voorgestelde nieuwe challenge');

create temporary table stale_reset as
select app.prepare_parent_otp_delivery_v3(
  'ouder-v3@example.invalid',
  '31a40000-0000-4000-8000-000000000009',
  repeat('9', 64),
  true,
  null,
  '31a40000-0000-4000-8000-000000000001'
) result;
select is((select result->>'status' from stale_reset), 'ineligible',
  'een stale cookie mag de nieuwere actieve challenge niet roteren');
select is(
  (select count(*) from private.parent_otp_challenges
    where id = '31a40000-0000-4000-8000-000000000003'
      and closed_at is null and used_at is null),
  1::bigint,
  'de nieuwere actieve challenge blijft na stale forceNew bruikbaar'
);
select is(
  (select count(*) from private.parent_otp_challenges
    where id = '31a40000-0000-4000-8000-000000000009'),
  0::bigint,
  'stale forceNew maakt ook geen willekeurige nieuwe credential'
);
select is(
  app.consume_parent_login_challenge_v3(
    '31a40000-0000-4000-8000-000000000003',
    'direct',
    null,
    repeat('4', 64),
    statement_timestamp() + interval '7 days'
  )->>'status',
  'verified',
  'de door de server geverifieerde directe credential consumeert atomair'
);
select is(
  app.consume_parent_login_challenge_v3(
    '31a40000-0000-4000-8000-000000000003',
    'code',
    repeat('3', 64),
    repeat('5', 64),
    statement_timestamp() + interval '7 days'
  )->>'status',
  'invalid',
  'de code kan na consumptie via de directe link niet worden hergebruikt'
);
select is(
  (select count(*) from private.parent_sessions
    where parent_account_id = '31a20000-0000-4000-8000-000000000001'),
  1::bigint,
  'race/replay kan maximaal één sessie uit dezelfde challenge opleveren'
);

create temporary table first_completion as
select app.complete_parent_otp_delivery_v2(
  (select (result->>'deliveryAttemptId')::uuid from reset_prepare),
  'accepted',
  'otp-v3-http-message',
  null,
  'sendgrid',
  'provider_accepted',
  '202',
  null,
  false
) result;
create temporary table replayed_completion as
select app.complete_parent_otp_delivery_v2(
  (select (result->>'deliveryAttemptId')::uuid from reset_prepare),
  'accepted',
  'otp-v3-http-message',
  null,
  'sendgrid',
  'provider_accepted',
  '202',
  null,
  false
) result;
select is((select result->>'reused' from replayed_completion), 'true',
  'providercompletion is exact replay-idempotent');
select is(
  (select count(*) from private.email_provider_sync_evidence
    where parent_otp_delivery_attempt_id =
      (select (result->>'deliveryAttemptId')::uuid from reset_prepare)),
  1::bigint,
  'een replay maakt geen dubbel providerbewijs'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from reset_prepare),
      'event_id', 'otp-v3-recipient-bounce',
      'provider_message_id', 'otp-v3-http-message',
      'event_type', 'bounced',
      'occurred_at', statement_timestamp()
    )
  ))->>'recorded',
  '1',
  'een expliciete bounce wordt aan de ontvanger gebonden'
);
select is(
  (select suppression.reason
   from private.email_recipient_suppressions suppression
   where suppression.source_parent_otp_attempt_id =
     (select (result->>'deliveryAttemptId')::uuid from reset_prepare)
     and suppression.lifted_at is null),
  'hard_bounce',
  'bewezen SendGrid hard-bounce opent wel recipientsuppressie'
);
select is(
  app.get_operational_health_v14(repeat('a', 64), 1, null, null)
    #>> '{parentOtpDelivery,providerFailuresRecent}',
  '0',
  'een ontvangerbounce maakt de globale providerhealth niet rood'
);
select is(
  app.record_parent_otp_sendgrid_events_v3(jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id',
        (select result->>'deliveryAttemptId' from reset_prepare),
      'event_id', 'otp-v3-systemic-drop',
      'provider_message_id', 'otp-v3-http-message',
      'event_type', 'dropped',
      'occurred_at', statement_timestamp() + interval '1 second'
    )
  ))->>'recorded',
  '1',
  'een niet als recipientbounce bewezen providerfout wordt vastgelegd'
);
select is(
  app.get_operational_health_v14(repeat('a', 64), 1, null, null)
    #>> '{parentOtpDelivery,providerFailuresRecent}',
  '1',
  'een systemische providerfout blijft globaal releaseblokkerend'
);

select ok(
  private.smtp_permanent_recipient_address_status('5.1.1')
  and not private.smtp_permanent_recipient_address_status('5.2.2')
  and not private.smtp_permanent_recipient_address_status('5.7.1')
  and not private.smtp_permanent_recipient_address_status('5.6.0')
  and not private.smtp_permanent_recipient_address_status(null),
  'alleen gestandaardiseerd permanent ontvangstadresbewijs is suppressiewaardig'
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
  '31a50000-0000-4000-8000-000000000001',
  '31a20000-0000-4000-8000-000000000001',
  '31a40000-0000-4000-8000-000000000099',
  template_revision.id,
  branding_revision.id,
  statement_timestamp() + interval '10 minutes'
from app.mail_template_revisions template_revision
cross join app.mail_branding_revisions branding_revision
where template_revision.template_key = 'login_otp'
  and template_revision.status = 'published'
  and branding_revision.status = 'published';

select throws_ok(
  $$select app.complete_parent_otp_delivery_v2(
    '31a50000-0000-4000-8000-000000000001',
    'provider_rejected', null, 'provider_rejected',
    'smtp', 'permanent_rejection', '550', '5.2.2', true
  )$$,
  '22023',
  'PARENT_OTP_PROVIDER_EVIDENCE_INVALID',
  'quota- of policyrejection kan niet als recipient failure worden opgeslagen'
);

select is(
  app.complete_parent_otp_delivery_v2(
    '31a50000-0000-4000-8000-000000000001',
    'provider_rejected', null, 'provider_rejected',
    'smtp', 'permanent_rejection', '550', '5.2.2', false
  )->>'status',
  'completed',
  'dezelfde permanente SMTP-reject blijft zonder recipientsuppressie bewijsbaar'
);

select is(
  (select count(*)
   from private.email_recipient_suppressions suppression
   where suppression.source_parent_otp_attempt_id =
     '31a50000-0000-4000-8000-000000000001'),
  0::bigint,
  'een mailbox-quotaresponse opent geen recipientsuppressie'
);

insert into app.members(
  id, relation_number, first_name, last_name, email, team
) values
  (
    '31a10000-0000-4000-8000-000000000002',
    'OTP-V3-002', 'Wachtende', 'Koppeling',
    'ouder-v3@example.invalid', 'JO15-1'
  ),
  (
    '31a10000-0000-4000-8000-000000000003',
    'OTP-V3-003', 'Historische', 'Koppeling',
    'ouder-v3@example.invalid', 'JO16-1'
  );

insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source
)
select
  '31a30000-0000-4000-8000-000000000002',
  season.id,
  'ouder-v3@example.invalid',
  '31a20000-0000-4000-8000-000000000001',
  'pending_account',
  'administrator'
from app.member_seasons season
where season.member_id = '31a10000-0000-4000-8000-000000000002';

insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source, granted_by, granted_at,
  revoked_by, revoked_at, revoked_reason
)
select
  '31a30000-0000-4000-8000-000000000003',
  season.id,
  'ouder-v3@example.invalid',
  '31a20000-0000-4000-8000-000000000001',
  'revoked',
  'administrator',
  '31a00000-0000-4000-8000-000000000001',
  statement_timestamp() - interval '1 day',
  '31a00000-0000-4000-8000-000000000001',
  statement_timestamp(),
  'Test: toegang ingetrokken'
from app.member_seasons season
where season.member_id = '31a10000-0000-4000-8000-000000000003';

insert into private.email_recipient_identities(email_normalized)
values('oud-ouder-v3@example.invalid');
insert into private.email_recipient_parent_bindings(
  recipient_identity_id, parent_account_id
)
select
  identity_row.id,
  '31a20000-0000-4000-8000-000000000001'
from private.email_recipient_identities identity_row
where identity_row.email_normalized = 'oud-ouder-v3@example.invalid';

create temporary table expected_otp_acceptance as
select outcome.created_at
from private.parent_otp_delivery_outcomes outcome
where outcome.outcome = 'accepted'
  and outcome.delivery_attempt_id =
    (select (result->>'deliveryAttemptId')::uuid from reset_prepare);
grant select on expected_otp_acceptance to authenticated;

select set_config(
  'request.jwt.claims',
  '{"sub":"31a00000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_parent_otp_support_v1(
    '31a20000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie krijgt geen OTP-supportbediening'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"31a00000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table support_snapshot as
select app.get_parent_otp_support_v1(
  '31a20000-0000-4000-8000-000000000001'
) result;
select is((select result->>'loginEmailMasked' from support_snapshot),
  'o*******@example.invalid',
  'OTP-support toont alleen een gemaskeerd adres');
select ok(
  not ((select result from support_snapshot) ?| array[
    'email', 'code', 'codeHash', 'credential', 'proof'
  ]),
  'OTP-support geeft geen credentials of volledig adres prijs'
);

create temporary table email_control_recipients as
select recipient.value
from jsonb_array_elements(
  app.get_email_control_center_v1()->'recipients'
) recipient(value);

select is(
  (select (value->>'lastProviderAcceptanceAt')::timestamptz
   from email_control_recipients
   where value->>'email' = 'ouder-v3@example.invalid'),
  (select created_at from expected_otp_acceptance),
  'alleen een accepted OTP-outcome bepaalt provideracceptatie'
);

select is(
  (select value->>'lastOtpOutcome'
   from email_control_recipients
   where value->>'email' = 'ouder-v3@example.invalid'),
  'provider_rejected',
  'de latere reject blijft wel de zichtbare laatste OTP-uitkomst'
);

select is(
  (select jsonb_array_length(value->'linkedChildren')
   from email_control_recipients
   where value->>'email' = 'ouder-v3@example.invalid'),
  1,
  'recipientprojectie toont alleen de actuele geautoriseerde actieve grant'
);

select is(
  (select value #>> '{linkedChildren,0,memberName}'
   from email_control_recipients
   where value->>'email' = 'ouder-v3@example.invalid'),
  'Veilige Ouderlogin',
  'pending en revoked grants verschijnen niet als gekoppeld kind'
);

select is(
  (select jsonb_array_length(value->'linkedChildren')
   from email_control_recipients
   where value->>'email' = 'oud-ouder-v3@example.invalid'),
  0,
  'een historische recipient-accountbinding projecteert geen huidige kinderen'
);

create temporary table support_reset as
select app.prepare_parent_otp_support_delivery_v1(
  '31a20000-0000-4000-8000-000000000001',
  'reset',
  '31a40000-0000-4000-8000-000000000004',
  repeat('6', 64),
  '31a60000-0000-4000-8000-000000000001'
) result;
create temporary table support_reset_replay as
select app.prepare_parent_otp_support_delivery_v1(
  '31a20000-0000-4000-8000-000000000001',
  'reset',
  '31a40000-0000-4000-8000-000000000005',
  repeat('7', 64),
  '31a60000-0000-4000-8000-000000000001'
) result;
select is(
  (select result->>'deliveryAttemptId' from support_reset_replay),
  (select result->>'deliveryAttemptId' from support_reset),
  'dezelfde support-request-ID hergebruikt exact dezelfde afleverpoging'
);
select is(
  (select result->>'supportRequestReused' from support_reset_replay),
  'true',
  'de supportreplay wordt expliciet als requesthergebruik gemarkeerd'
);
reset role;
select is(
  (select count(*) from private.parent_otp_support_events
    where request_id = '31a60000-0000-4000-8000-000000000001'),
  1::bigint,
  'een supportreplay maakt geen tweede supportevent'
);
set local role authenticated;
select throws_ok(
  $$select app.prepare_parent_otp_support_delivery_v1(
    '31a20000-0000-4000-8000-000000000001',
    'resend',
    '31a40000-0000-4000-8000-000000000006',
    repeat('8', 64),
    '31a60000-0000-4000-8000-000000000001'
  )$$,
  '23505',
  'PARENT_OTP_SUPPORT_IDEMPOTENCY_CONFLICT',
  'hergebruik van een request-ID voor andere inhoud wordt geweigerd'
);
reset role;

select ok(
  not exists(
    select 1
    from app.audit_logs log
    where log.action like 'parent.otp.%'
      and log.metadata::text ~* '(code_hash|directCredential|proof)'
  ),
  'auditmetadata bevat geen OTP-hash of directe credential'
);

select * from finish();
rollback;

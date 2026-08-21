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
    'app.prepare_parent_otp_delivery_v3(text,uuid,text,boolean,uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.consume_parent_login_challenge_v3(uuid,text,text,text,timestamptz)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'app.prepare_parent_otp_delivery_v3(text,uuid,text,boolean,uuid)',
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
  null
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
  null
) result;
select is((select result->>'status' from reset_prepare), 'prepared',
  'Nieuwe code maakt na de cooldown een vervangende challenge');
select is((select result->>'challengeId' from reset_prepare),
  '31a40000-0000-4000-8000-000000000003',
  'de expliciete reset gebruikt de voorgestelde nieuwe challenge');
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

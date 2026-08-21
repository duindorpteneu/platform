begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

select ok((
  select coalesce(
    rolconfig @> array['pgrst.db_schemas=public, graphql_public, app'],
    false
  )
  from pg_roles
  where rolname = 'authenticator'
), 'PostgREST exposeert exact public, graphql_public en app via de rolconfiguratie');

insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season
) values
  ('f1000000-0000-4000-8000-000000000001', 'SEC-001', 'Bekend', 'Actief', 'bekend@example.invalid', 'JO13-1', true),
  ('f1000000-0000-4000-8000-000000000002', 'SEC-002', 'Bekend', 'Inactief', 'inactief-sec@example.invalid', 'JO13-2', false),
  ('f1000000-0000-4000-8000-000000000003', 'SEC-003', 'Uurlimiet', 'Actief', 'uurlimiet@example.invalid', 'JO15-1', true),
  ('f1000000-0000-4000-8000-000000000004', 'SEC-004', 'Health', 'Lid', 'health@example.invalid', 'JO17-1', true);
insert into private.parent_accounts(id, email_normalized) values
  ('f9000000-0000-4000-8000-000000000001', 'bekend@example.invalid'),
  ('f9000000-0000-4000-8000-000000000003', 'uurlimiet@example.invalid');
insert into private.parent_portal_grants(
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  granted_by,
  granted_at
)
select member_season.id,
  member.email,
  case member.id
    when 'f1000000-0000-4000-8000-000000000001'
      then 'f9000000-0000-4000-8000-000000000001'::uuid
    else 'f9000000-0000-4000-8000-000000000003'::uuid
  end,
  'active',
  'administrator',
  'f0000000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_seasons member_season
join app.members member on member.id = member_season.member_id
where member.id in (
  'f1000000-0000-4000-8000-000000000001',
  'f1000000-0000-4000-8000-000000000003'
);

select ok(not has_table_privilege('authenticated', 'private.rate_limit_events', 'SELECT'),
  'rate-limit-events zijn default-deny');
select ok(not has_table_privilege('service_role', 'private.rate_limit_events', 'SELECT'),
  'service_role leest rate-events uitsluitend via smalle functies');
select ok(not has_function_privilege('authenticated',
  'app.consume_rate_limit(text,text,integer,integer)', 'EXECUTE'),
  'rate-limitconsumer is niet rechtstreeks beschikbaar voor authenticated');
select ok(has_function_privilege('service_role',
  'app.consume_rate_limit(text,text,integer,integer)', 'EXECUTE'),
  'rate-limitconsumer is service-only');

select ok((
  select bool_and(app.consume_rate_limit(
    scope,
    encode(extensions.digest('scope-fixture-' || scope, 'sha256'), 'hex'),
    2,
    60
  ))
  from unnest(array['otp_request','otp_verify','mollie_create','export','search']) scope
), 'exact de vijf canonieke rate-limit-scopes worden geaccepteerd');
select throws_ok($$select app.consume_rate_limit('qr_scan', repeat('a', 64), 1, 60)$$,
  '22023', 'INVALID_RATE_LIMIT_SCOPE', 'niet-allowlisted scope wordt geweigerd');
select throws_ok($$select app.consume_rate_limit('search', 'plaintext@example.invalid', 1, 60)$$,
  '22023', 'INVALID_RATE_LIMIT_KEY', 'plaintext rate-limitsleutel wordt geweigerd');
select throws_ok($$select app.consume_rate_limit('search', repeat('a', 64), 0, 60)$$,
  '22023', 'INVALID_RATE_LIMIT_BOUNDS', 'nul als limiet wordt geweigerd');
select throws_ok($$select app.consume_rate_limit('search', repeat('a', 64), 1, 86401)$$,
  '22023', 'INVALID_RATE_LIMIT_BOUNDS', 'onbegrensd rate-limitvenster wordt geweigerd');
select ok(app.consume_rate_limit('search', repeat('b', 64), 2, 60),
  'eerste verzoek binnen limiet wordt verbruikt');
select ok(app.consume_rate_limit('search', repeat('b', 64), 2, 60),
  'tweede verzoek binnen limiet wordt verbruikt');
select ok(not app.consume_rate_limit('search', repeat('b', 64), 2, 60),
  'derde verzoek boven limiet wordt atomair geweigerd');
select throws_ok($$insert into private.rate_limit_events(scope, key_hash)
  values('search', 'onveilig')$$,
  '23514', null, 'tabelconstraint weigert niet-gehashte sleutels');

create temporary table unknown_otp_result as
select public.create_parent_otp(
  'onbekend@example.invalid',
  repeat('1', 64),
  timezone('utc', now()) + interval '1 day'
) account_id;
select is((select account_id from unknown_otp_result), null::uuid,
  'onbekend e-mailadres krijgt generiek null');
select is((select count(*) from private.parent_accounts
  where email_normalized = 'onbekend@example.invalid'), 0::bigint,
  'onbekend e-mailadres maakt geen ouderaccount');
select is((select count(*) from private.parent_otp_challenges challenge
  join private.parent_accounts account on account.id = challenge.parent_account_id
  where account.email_normalized = 'onbekend@example.invalid'), 0::bigint,
  'onbekend e-mailadres maakt geen OTP-challenge');
select is((select count(*) from private.email_jobs
  where recipient_email = 'onbekend@example.invalid'), 0::bigint,
  'onbekend e-mailadres maakt geen duurzame mailmogelijkheid');
select ok(not exists(
  select 1 from private.rate_limit_events
  where key_hash like '%onbekend%'
), 'onbekende OTP-aanvraag bewaart uitsluitend de e-mailhash');

select is(public.create_parent_otp(
  'inactief-sec@example.invalid',
  repeat('2', 64),
  timezone('utc', now()) + interval '10 minutes'
), null::uuid, 'inactief lid krijgt generiek null');
select is((select count(*) from private.parent_accounts
  where email_normalized = 'inactief-sec@example.invalid'), 0::bigint,
  'inactief lid maakt geen ouderaccount');

create temporary table known_otp_result as
select public.create_parent_otp(
  '  BEKEND@example.invalid ',
  repeat('3', 64),
  timezone('utc', now()) + interval '1 day'
) account_id;
select isnt((select account_id from known_otp_result), null::uuid,
  'expliciet gegrant actief lid krijgt een OTP-challenge');
select is((
  select challenge.expires_at - challenge.created_at
  from private.parent_otp_challenges challenge
  where challenge.parent_account_id = (select account_id from known_otp_result)
  order by challenge.created_at desc limit 1
), interval '10 minutes', 'database forceert exact tien minuten OTP-geldigheid');
select is(public.create_parent_otp(
  'bekend@example.invalid',
  repeat('4', 64),
  timezone('utc', now()) + interval '10 minutes'
), null::uuid, 'OTP-cooldown blokkeert een onmiddellijke tweede aanvraag');
select is((select count(*) from private.parent_otp_challenges
  where parent_account_id = (select account_id from known_otp_result)), 1::bigint,
  'cooldown maakt geen tweede challenge');

update private.rate_limit_events
set occurred_at = timezone('utc', now()) - interval '60 seconds'
where scope = 'otp_request'
  and key_hash = encode(extensions.digest('bekend@example.invalid', 'sha256'), 'hex');
select is(public.create_parent_otp(
  'bekend@example.invalid',
  repeat('5', 64),
  timezone('utc', now()) + interval '10 minutes'
), (select account_id from known_otp_result),
  'exact na zestig seconden mag een nieuwe OTP worden gemaakt');
select is((select count(*) from private.parent_otp_challenges
  where parent_account_id = (select account_id from known_otp_result)), 2::bigint,
  'toegestane heraanvraag maakt exact één nieuwe challenge');
select is((select count(*) from private.parent_otp_challenges
  where parent_account_id = (select account_id from known_otp_result)
    and used_at is null), 1::bigint,
  'nieuwe OTP maakt de vorige challenge direct onbruikbaar');

insert into private.rate_limit_events(scope, key_hash, occurred_at)
select 'otp_request', encode(extensions.digest('uurlimiet@example.invalid', 'sha256'), 'hex'),
  timezone('utc', now()) - make_interval(mins => value * 2)
from generate_series(1, 5) value;
select is(public.create_parent_otp(
  'uurlimiet@example.invalid',
  repeat('6', 64),
  timezone('utc', now()) + interval '10 minutes'
), null::uuid, 'maximaal vijf OTP-aanvragen per uur wordt afgedwongen');
select is((select count(*) from private.parent_accounts
  where email_normalized = 'uurlimiet@example.invalid'), 1::bigint,
  'uurlimiet behoudt het vooraf door beheer geactiveerde account');
select is((select count(*) from private.parent_otp_challenges challenge
  join private.parent_accounts account on account.id = challenge.parent_account_id
  where account.email_normalized = 'uurlimiet@example.invalid'), 0::bigint,
  'uurlimiet creëert geen challenge bij blokkade');

select ok(not has_function_privilege('authenticated', 'app.revoke_parent_session(text)', 'EXECUTE'),
  'single-session revocation is niet beschikbaar voor authenticated');
select ok(not has_function_privilege('authenticated', 'app.revoke_all_parent_sessions(uuid)', 'EXECUTE'),
  'accountbrede revocation is niet beschikbaar voor authenticated');
select ok(has_function_privilege('service_role', 'app.revoke_parent_session(text)', 'EXECUTE'),
  'single-session revocation is service-only');
select ok(has_function_privilege('service_role', 'app.revoke_all_parent_sessions(uuid)', 'EXECUTE'),
  'accountbrede revocation is service-only');

insert into private.parent_accounts(id, email_normalized) values
  ('f9000000-0000-4000-8000-000000000010', 'sessions-a@example.invalid'),
  ('f9000000-0000-4000-8000-000000000020', 'sessions-b@example.invalid'),
  ('f9000000-0000-4000-8000-000000000030', 'retention@example.invalid');
insert into private.parent_sessions(
  id, parent_account_id, token_hash, expires_at, revoked_at
) values
  ('f9100000-0000-4000-8000-000000000001', 'f9000000-0000-4000-8000-000000000010', repeat('1', 64), timezone('utc', now()) + interval '1 day', null),
  ('f9100000-0000-4000-8000-000000000002', 'f9000000-0000-4000-8000-000000000010', repeat('2', 64), timezone('utc', now()) + interval '1 day', null),
  ('f9100000-0000-4000-8000-000000000003', 'f9000000-0000-4000-8000-000000000010', repeat('3', 64), timezone('utc', now()) - interval '1 hour', null),
  ('f9100000-0000-4000-8000-000000000004', 'f9000000-0000-4000-8000-000000000020', repeat('4', 64), timezone('utc', now()) + interval '1 day', null),
  ('f9100000-0000-4000-8000-000000000005', 'f9000000-0000-4000-8000-000000000020', repeat('5', 64), timezone('utc', now()) + interval '1 day', timezone('utc', now()) - interval '1 minute');

select throws_ok($$select app.revoke_parent_session('plaintext-token')$$,
  '22023', 'INVALID_PARENT_SESSION_TOKEN', 'logout weigert niet-gehashte sessietokens');
select is(app.revoke_parent_session(repeat('1', 64)), 1,
  'logout trekt exact één actieve sessie in');
select is(app.revoke_parent_session(repeat('1', 64)), 0,
  'herhaalde logout is idempotent');
select is(app.revoke_parent_session(repeat('3', 64)), 0,
  'verlopen sessie telt niet als actief');
select is(app.revoke_all_parent_sessions('f9000000-0000-4000-8000-000000000010'), 1,
  'incidentresponse trekt alle resterende actieve accountsessies in');
select is(app.revoke_all_parent_sessions('f9000000-0000-4000-8000-000000000010'), 0,
  'accountbrede herhaling is idempotent');
select is(app.revoke_all_parent_sessions('f9000000-0000-4000-8000-000000000020'), 1,
  'accountbrede revocation negeert reeds ingetrokken sessies');
select is(app.revoke_all_parent_sessions('f9000000-0000-4000-8000-000000000099'), 0,
  'onbekend ouderaccount retourneert neutraal nul');
select throws_ok($$select app.revoke_all_parent_sessions(null)$$,
  '22023', 'INVALID_PARENT_ACCOUNT', 'null ouderaccount wordt geweigerd');

insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'f4000000-0000-4000-8000-000000000001',
  'f1000000-0000-4000-8000-000000000004',
  active_season_id,
  12500
from app.app_settings where id = true;
insert into app.payments(
  id, order_id, method, status, amount_cents, idempotency_key, reconciliation_issue
) values (
  'f6000000-0000-4000-8000-000000000001',
  'f4000000-0000-4000-8000-000000000001',
  'mollie',
  'pending',
  12500,
  'security-retention-payment',
  'fixture reconciliation issue'
);
insert into private.payment_events(
  payment_id, event_type, provider_payload_redacted, processed_at, idempotency_key
) values (
  'f6000000-0000-4000-8000-000000000001',
  'mismatch',
  '{"status":"manual_review"}',
  timezone('utc', now()) - interval '1 hour',
  'security-retention-payment-event'
);
insert into app.audit_logs(action, entity_type, entity_id, metadata)
values('payment.fixture.retained', 'payment', 'f6000000-0000-4000-8000-000000000001', '{}');
insert into app.fulfilments(id, order_id, actor_user_id, location)
values(
  'f8000000-0000-4000-8000-000000000001',
  'f4000000-0000-4000-8000-000000000001',
  'f0000000-0000-4000-8000-000000000001',
  'Retentiefixture'
);

create temporary table health_job_ids(slot integer primary key, job_id uuid);
insert into health_job_ids(slot, job_id)
select value, private.enqueue_order_email(
  'f4000000-0000-4000-8000-000000000001',
  'payment_received',
  'security-health-email-job-' || value
)
from generate_series(1, 5) value;
update private.email_jobs
set status = case (select slot from health_job_ids where job_id = private.email_jobs.id)
    when 1 then 'queued'
    when 2 then 'retry'
    when 3 then 'processing'
    when 4 then 'processing'
    when 5 then 'failed'
  end,
  attempts = case when (select slot from health_job_ids where job_id = private.email_jobs.id) = 1 then 0 else 1 end,
  claim_token = case when (select slot from health_job_ids where job_id = private.email_jobs.id) in (3, 4)
    then gen_random_uuid() else null end,
  claimed_at = case (select slot from health_job_ids where job_id = private.email_jobs.id)
    when 3 then timezone('utc', now()) - interval '16 minutes'
    when 4 then timezone('utc', now()) - interval '14 minutes'
    else null
  end,
  completed_at = case when (select slot from health_job_ids where job_id = private.email_jobs.id) = 5
    then timezone('utc', now()) else null end
where id in (select job_id from health_job_ids);
update private.email_jobs
set provider_message_id = 'sg-security-health'
where id = (select job_id from health_job_ids where slot = 1);

insert into app.email_events(
  email_job_id, provider_event_id, provider_message_id, event_type, occurred_at
) values
  ((select job_id from health_job_ids where slot = 1), 'sg-retention-old', 'sg-security-health', 'failed',
    timezone('utc', now()) - interval '12 months' - interval '1 second'),
  ((select job_id from health_job_ids where slot = 1), 'sg-retention-boundary', 'sg-security-health', 'bounced',
    timezone('utc', now()) - interval '12 months'),
  ((select job_id from health_job_ids where slot = 1), 'sg-retention-recent', 'sg-security-health', 'delivered',
    timezone('utc', now()) - interval '1 day');

select ok(not has_function_privilege('authenticated', 'app.get_operational_health()', 'EXECUTE'),
  'operationele health is niet beschikbaar voor authenticated');
select ok(has_function_privilege('service_role', 'app.get_operational_health()', 'EXECUTE'),
  'operationele health is service-only');
create temporary table operational_health_result as
select app.get_operational_health() result;
select is((select result #>> '{emailJobs,queued}' from operational_health_result), '1',
  'health telt queued e-mailjobs');
select is((select result #>> '{emailJobs,retry}' from operational_health_result), '1',
  'health telt retry e-mailjobs');
select is((select result #>> '{emailJobs,processingStale}' from operational_health_result), '1',
  'health markeert processing ouder dan vijftien minuten als stale');
select is((select result #>> '{emailJobs,failed}' from operational_health_result), '1',
  'health telt permanent mislukte e-mailjobs');
select is((select result->>'reconciliationIssues' from operational_health_result), '1',
  'health telt betaalreconciliatieproblemen zonder details');
select is((select result->>'recentWebhookFailures' from operational_health_result), '1',
  'health telt recente webhookmismatches zonder provider-ID');
select ok((select result->>'dbTime' from operational_health_result)
  ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
  'health bevat uitsluitend een ISO-databasetijd');
select is(
  (select array_agg(key order by key) from operational_health_result,
    lateral jsonb_object_keys(result) key),
  array['dbTime','emailJobs','recentWebhookFailures','reconciliationIssues']::text[],
  'health heeft exact de niet-PII top-level counts'
);
select ok((select result::text from operational_health_result)
  !~ '(health@example|tr_|sg-security|provider|token|payload|reconciliation issue)',
  'health bevat geen PII, provider-ID, secret of issue-tekst');

insert into private.parent_otp_challenges(
  parent_account_id, code_hash, expires_at, used_at, created_at,
  closed_at, close_reason
) values
  ('f9000000-0000-4000-8000-000000000030', repeat('7', 64), timezone('utc', now()) + interval '1 day',
    timezone('utc', now()) - interval '24 hours' - interval '1 second', timezone('utc', now()) - interval '2 days',
    null, null),
  ('f9000000-0000-4000-8000-000000000030', repeat('8', 64), timezone('utc', now()) + interval '1 day',
    timezone('utc', now()) - interval '24 hours', timezone('utc', now()) - interval '2 days',
    null, null),
  ('f9000000-0000-4000-8000-000000000030', repeat('9', 64), timezone('utc', now()) - interval '24 hours' - interval '1 second',
    null, timezone('utc', now()) - interval '2 days', timezone('utc', now()) - interval '24 hours' - interval '1 second', 'expired'),
  ('f9000000-0000-4000-8000-000000000030', repeat('a', 64), timezone('utc', now()) - interval '24 hours',
    null, timezone('utc', now()) - interval '2 days', timezone('utc', now()) - interval '24 hours', 'expired'),
  ('f9000000-0000-4000-8000-000000000030', repeat('b', 64), timezone('utc', now()) - interval '23 hours',
    null, timezone('utc', now()) - interval '2 days', timezone('utc', now()) - interval '23 hours', 'expired');

insert into private.rate_limit_events(scope, key_hash, occurred_at) values
  ('search', repeat('c', 64), timezone('utc', now()) - interval '30 days' - interval '1 second'),
  ('search', repeat('d', 64), timezone('utc', now()) - interval '30 days');

insert into private.parent_sessions(
  parent_account_id, token_hash, expires_at, revoked_at
) values
  ('f9000000-0000-4000-8000-000000000030', repeat('6', 64), timezone('utc', now()) - interval '30 days' - interval '1 second', null),
  ('f9000000-0000-4000-8000-000000000030', repeat('7', 64), timezone('utc', now()) - interval '30 days', null),
  ('f9000000-0000-4000-8000-000000000030', repeat('8', 64), timezone('utc', now()) + interval '1 day',
    timezone('utc', now()) - interval '30 days' - interval '1 second'),
  ('f9000000-0000-4000-8000-000000000030', repeat('9', 64), timezone('utc', now()) + interval '1 day',
    timezone('utc', now()) - interval '30 days'),
  ('f9000000-0000-4000-8000-000000000030', repeat('a', 64), timezone('utc', now()) - interval '29 days', null);

create temporary table retained_before as
select
  (select count(*) from app.payments) payment_count,
  (select count(*) from private.payment_events) payment_event_count,
  (select count(*) from app.audit_logs) audit_count,
  (select count(*) from app.fulfilments) fulfilment_count;
create temporary table cleanup_result as
select app.cleanup_expired_security_data(timezone('utc', now())) result;

select is((select (result->>'otpChallenges')::integer from cleanup_result), 4,
  'cleanup verwijdert gebruikte of verlopen OTPs uiterlijk op 24 uur');
select is((select (result->>'rateLimitEvents')::integer from cleanup_result), 1,
  'cleanup verwijdert rate-events strikt ouder dan 30 dagen');
select is((select (result->>'parentSessions')::integer from cleanup_result), 4,
  'cleanup verwijdert sessies uiterlijk 30 dagen na expiry of revocation');
select is((select (result->>'emailEvents')::integer from cleanup_result), 1,
  'cleanup verwijdert provider-events ouder dan twaalf maanden');
select is((select count(*) from private.parent_otp_challenges
  where parent_account_id = 'f9000000-0000-4000-8000-000000000030'), 1::bigint,
  'recente verlopen OTP blijft binnen retentiegrens');
select ok(exists(select 1 from private.rate_limit_events where key_hash = repeat('d', 64)),
  'rate-event exact op dertig dagen blijft behouden');
select ok(not exists(select 1 from private.parent_sessions where token_hash in (repeat('7', 64), repeat('9', 64))),
  'sessie exact op dertig dagen wordt uiterlijk op de grens verwijderd');
select ok(exists(select 1 from app.email_events where provider_event_id = 'sg-retention-boundary'),
  'e-mailevent exact op twaalf maanden blijft behouden');

select is((select count(*) from app.payments),
  (select payment_count from retained_before), 'cleanup verwijdert geen financiële betalingen');
select is((select count(*) from private.payment_events),
  (select payment_event_count from retained_before), 'cleanup verwijdert geen payment-eventledger');
select is((select count(*) from app.audit_logs),
  (select audit_count from retained_before), 'cleanup verwijdert geen auditlog');
select is((select count(*) from app.fulfilments),
  (select fulfilment_count from retained_before), 'cleanup verwijdert geen uitgiftehistorie');

select ok(not has_function_privilege('authenticated',
  'app.cleanup_expired_security_data(timestamptz)', 'EXECUTE'),
  'retentiecleanup is niet beschikbaar voor authenticated');
select ok(has_function_privilege('service_role',
  'app.cleanup_expired_security_data(timestamptz)', 'EXECUTE'),
  'retentiecleanup is service-only');

select * from finish();
rollback;

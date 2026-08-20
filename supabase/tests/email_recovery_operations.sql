begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('a0000000-0000-4000-8000-000000000001', 'Recovery beheerder', 'beheerder'),
  ('a0000000-0000-4000-8000-000000000002', 'Recovery commissie', 'kledingcommissie'),
  ('a0000000-0000-4000-8000-000000000003', 'Recovery uitgifte', 'uitgifte');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('a1000000-0000-4000-8000-000000000001', 'Recoveryseizoen', 100, 'open');
insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season) values
  ('a2000000-0000-4000-8000-000000000001', 'REC-001', 'Fictief', 'Recoverylid', 'recovery@example.invalid', 'TEST', true);
insert into app.member_orders(id, member_id, season_id, amount_due_cents) values
  ('a3000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 100);

insert into private.email_jobs(
  id, kind, recipient_email, template_key, template_id, order_id, idempotency_key, payload
)
select job_id, 'transactional', 'recovery@example.invalid', 'payment_received', template.id,
  'a3000000-0000-4000-8000-000000000001', 'recovery-operation-' || slot, '{}'::jsonb
from app.email_templates template
cross join (values
  (1, 'a4000000-0000-4000-8000-000000000001'::uuid),
  (2, 'a4000000-0000-4000-8000-000000000002'::uuid),
  (3, 'a4000000-0000-4000-8000-000000000003'::uuid),
  (4, 'a4000000-0000-4000-8000-000000000004'::uuid),
  (5, 'a4000000-0000-4000-8000-000000000005'::uuid)
) jobs(slot, job_id)
where template.template_key = 'payment_received';

update private.email_jobs set
  status = 'processing', attempts = 1,
  claim_token = 'a5000000-0000-4000-8000-000000000001',
  claimed_at = timezone('utc', now()) - interval '16 minutes',
  updated_at = '2026-07-21T09:00:00Z'
where id = 'a4000000-0000-4000-8000-000000000001';
update private.email_jobs set
  status = 'delivery_uncertain', attempts = 1, uncertain_at = timezone('utc', now()),
  last_error = 'delivery_uncertain', updated_at = '2026-07-21T09:01:00Z'
where id = 'a4000000-0000-4000-8000-000000000002';
update private.email_jobs set
  status = 'delivery_uncertain', attempts = 1, uncertain_at = timezone('utc', now()),
  last_error = 'delivery_uncertain', updated_at = '2026-07-21T09:02:00Z'
where id = 'a4000000-0000-4000-8000-000000000003';
update private.email_jobs set
  status = 'processing', attempts = 1,
  claim_token = 'a5000000-0000-4000-8000-000000000004',
  claimed_at = timezone('utc', now()) - interval '14 minutes',
  updated_at = '2026-07-21T09:03:00Z'
where id = 'a4000000-0000-4000-8000-000000000004';
update private.email_jobs set
  status = 'processing', attempts = 1,
  claim_token = 'a5000000-0000-4000-8000-000000000005',
  claimed_at = timezone('utc', now()) - interval '16 minutes',
  updated_at = '2026-07-21T09:04:00Z'
where id = 'a4000000-0000-4000-8000-000000000005';

insert into private.email_delivery_attempts(
  id,
  email_job_id,
  attempt_number,
  claim_token,
  claimed_at
)
select
  attempt_id,
  job.id,
  1,
  coalesce(job.claim_token, fallback_claim_token),
  coalesce(job.claimed_at, job.updated_at)
from private.email_jobs job
join (
  values
    (
      'a8000000-0000-4000-8000-000000000001'::uuid,
      'a4000000-0000-4000-8000-000000000001'::uuid,
      'a5000000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'a8000000-0000-4000-8000-000000000002'::uuid,
      'a4000000-0000-4000-8000-000000000002'::uuid,
      'a5000000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'a8000000-0000-4000-8000-000000000003'::uuid,
      'a4000000-0000-4000-8000-000000000003'::uuid,
      'a5000000-0000-4000-8000-000000000003'::uuid
    ),
    (
      'a8000000-0000-4000-8000-000000000004'::uuid,
      'a4000000-0000-4000-8000-000000000004'::uuid,
      'a5000000-0000-4000-8000-000000000004'::uuid
    ),
    (
      'a8000000-0000-4000-8000-000000000005'::uuid,
      'a4000000-0000-4000-8000-000000000005'::uuid,
      'a5000000-0000-4000-8000-000000000005'::uuid
    )
) input(attempt_id, job_id, fallback_claim_token)
  on input.job_id = job.id;
update private.email_jobs job
set current_delivery_attempt_id = attempt.id
from private.email_delivery_attempts attempt
where attempt.email_job_id = job.id;

select ok(not has_function_privilege('anon',
  'app.recover_stale_email_job_v2(uuid,timestamptz,text,text,text,text,boolean,uuid)', 'EXECUTE'),
  'anon kan e-mailrecovery niet uitvoeren');
select ok(has_function_privilege('authenticated',
  'app.recover_stale_email_job_v2(uuid,timestamptz,text,text,text,text,boolean,uuid)', 'EXECUTE'),
  'authenticated bereikt uitsluitend de intern AAL2-beveiligde recoveryfunctie');
select ok(not has_function_privilege('authenticated', 'app.start_operation_run(text,uuid)', 'EXECUTE'),
  'operation-run start is service-only');
select ok(has_function_privilege('service_role', 'app.start_operation_run(text,uuid)', 'EXECUTE'),
  'service role kan operation-runs starten');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok($$select app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000001', '2026-07-21T09:00:00Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-AAL1', null, true, null
)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'beheerder zonder AAL2 kan niet herstellen');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok($$select app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000001', '2026-07-21T09:00:00Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-COMMISSION', null, true, null
)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'kledingcommissie kan niet herstellen');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select ok(not (app.get_email_workspace() ? 'recoveryAllowed'),
  'rollbackworkspace behoudt exact het oude top-level contract');
select is((select item->>'status' from jsonb_array_elements(app.get_email_workspace()->'jobs') item
  where item->>'id' = 'a4000000-0000-4000-8000-000000000002'), 'failed',
  'rollbackworkspace projecteert uncertain veilig als failed');
select is((select item->>'status' from jsonb_array_elements(app.get_email_workspace_v2()->'jobs') item
  where item->>'id' = 'a4000000-0000-4000-8000-000000000002'), 'delivery_uncertain',
  'v2-workspace toont de expliciete onzekere status');
select throws_ok($$select app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000004', '2026-07-21T09:03:00Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-FRESH', null, true, null
)$$, '23514', 'EMAIL_JOB_NOT_RECOVERABLE', 'fresh processing-job is niet herstelbaar');
select throws_ok($$select app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000001', '2026-07-21T08:59:59Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-STALE', null, true, null
)$$, '40001', 'EMAIL_JOB_RECOVERY_CONFLICT', 'optimistic concurrency blokkeert stale herstelinput');
select throws_ok($$select app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000001', '2026-07-21T09:00:00Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-NOATTEST', null, false, null
)$$, '22023', 'INVALID_EMAIL_RETRY_EVIDENCE', 'retry vereist expliciete niet-acceptatie-attestatie');

select is(app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000001', '2026-07-21T09:00:00Z',
  'retry_proven_not_accepted', 'provider_confirmed_not_accepted', 'ticket/SG-NOT-ACCEPTED', null, true,
  'a6000000-0000-4000-8000-000000000001'
)->>'status', 'retry', 'bewezen niet-geaccepteerde stale job wordt één keer opnieuw ingepland');
reset role;
select is((select status from private.email_jobs where id = 'a4000000-0000-4000-8000-000000000001'), 'retry',
  'herstelde retry is niet automatisch verzonden');
select is(app.complete_email_job(
  'a4000000-0000-4000-8000-000000000004', 'a5000000-0000-4000-8000-000000000004',
  'retry', null, 'provider_error'
)->>'status', 'delivery_uncertain', 'oude workeruitkomst wordt tijdens rollback fail-closed geparkeerd');
select is(app.record_sendgrid_events(jsonb_build_array(jsonb_build_object(
  'email_job_id', 'a4000000-0000-4000-8000-000000000004',
  'event_id', 'event-rollback-delivered', 'provider_message_id', 'sg-event-message-4',
  'event_type', 'delivered', 'occurred_at', '2026-07-21T09:04:30Z'
)))->>'recorded', '1', 'signed event reconcileert ook de rollbackcompatibiliteitsstatus');
select is((select count(*) from app.audit_logs where action = 'email.job.recovered.retry'
  and entity_id = 'a4000000-0000-4000-8000-000000000001'), 1::bigint, 'retryrecovery is append-only geaudit');
select ok((select metadata::text from app.audit_logs where action = 'email.job.recovered.retry'
  and entity_id = 'a4000000-0000-4000-8000-000000000001') !~ '(example.invalid|ticket/|sg-)',
  'recoveryaudit bevat geen ontvanger of providerbewijs');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select is(app.recover_stale_email_job_v2(
  'a4000000-0000-4000-8000-000000000003', '2026-07-21T09:02:00Z',
  'confirm_sent', 'provider_confirmed_accepted', 'ticket/SG-ACCEPTED', 'sg-http-message-3', false,
  'a6000000-0000-4000-8000-000000000003'
)->>'status', 'sent', 'provideracceptatie wordt zonder herverzending bevestigd');
reset role;
select is((select provider_message_id from private.email_jobs where id = 'a4000000-0000-4000-8000-000000000003'),
  'sg-http-message-3', 'bevestigde provideridentiteit wordt privé bewaard');
select is((select count(*) from app.audit_logs where action = 'email.job.recovered.sent'
  and entity_id = 'a4000000-0000-4000-8000-000000000003'), 1::bigint, 'sent-recovery is eenmaal geaudit');

select is(app.record_sendgrid_events(jsonb_build_array(jsonb_build_object(
  'email_job_id', 'a4000000-0000-4000-8000-000000000002',
  'event_id', 'event-uncertain-delivered', 'provider_message_id', 'sg-event-message-2',
  'event_type', 'delivered', 'occurred_at', '2026-07-21T09:05:00Z'
)))->>'recorded', '1', 'signed provider-event reconcileert uncertain zonder resend');
select is((select status from private.email_jobs where id = 'a4000000-0000-4000-8000-000000000002'), 'sent',
  'webhookreconciliatie rondt de onzekere job af');
select is(app.record_sendgrid_events(jsonb_build_array(jsonb_build_object(
  'email_job_id', 'a4000000-0000-4000-8000-000000000002',
  'event_id', 'event-uncertain-delivered', 'provider_message_id', 'sg-event-message-2',
  'event_type', 'delivered', 'occurred_at', '2026-07-21T09:05:00Z'
)))->>'recorded', '0', 'webhookreplay blijft idempotent');

select is(app.record_sendgrid_events(jsonb_build_array(jsonb_build_object(
  'email_job_id', 'a4000000-0000-4000-8000-000000000005',
  'event_id', 'event-processing-delivered', 'provider_message_id', 'sg-event-message-5',
  'event_type', 'delivered', 'occurred_at', '2026-07-21T09:06:00Z'
)))->>'recorded', '1', 'signed event mag processing provideracceptatie bewijzen');
select is(app.complete_email_job(
  'a4000000-0000-4000-8000-000000000005', 'a5000000-0000-4000-8000-000000000005',
  'sent', 'sg-http-message-5', null
)->>'status', 'sent', 'webhook/completion-race eindigt idempotent sent');
select is((select count(*) from app.email_events where email_job_id = 'a4000000-0000-4000-8000-000000000005'),
  1::bigint, 'race creëert exact één providerevent');

set local role service_role;
select lives_ok($$select app.start_operation_run('email_worker', 'a7000000-0000-4000-8000-000000000001')$$,
  'service start e-mailworkerrun');
select lives_ok($$select app.finish_operation_run('a7000000-0000-4000-8000-000000000001', 'succeeded', 2, null)$$,
  'service voltooit e-mailworkerrun');
select is(
  app.finish_operation_run(
    'a7000000-0000-4000-8000-000000000001',
    'succeeded',
    2,
    null
  ),
  null::jsonb,
  'dubbele runfinalisatie retourneert null zonder retrybare SQLSTATE'
);
select lives_ok($$select app.start_operation_run('retention', 'a7000000-0000-4000-8000-000000000002')$$,
  'service start retentierun');
select lives_ok($$select app.finish_operation_run('a7000000-0000-4000-8000-000000000002', 'succeeded', 0, null)$$,
  'service voltooit retentierun');
reset role;
insert into private.operation_runs(id, operation, status, started_at)
values('a7000000-0000-4000-8000-000000000003', 'email_worker', 'running', timezone('utc', now()) - interval '3 minutes');
update app.app_settings set email_enabled = true where id = true;

create temporary table recovery_health as select app.get_operational_health_v2() result;
select is((select result #>> '{emailJobs,deliveryUncertain}' from recovery_health), '0',
  'health telt geen al gereconcilieerde uncertain jobs');
select is((select result #>> '{operations,emailWorker,lastStatus}' from recovery_health), 'succeeded',
  'health toont de laatste voltooide workerrun');
select is((select result #>> '{operations,emailWorker,runningStale}' from recovery_health), 'true',
  'health detecteert ook een oudere vastgelopen workerrun');
select is((select result->>'recentDeliveryFailures' from recovery_health), '0',
  'health houdt afleverfouten als niet-PII telling bij');
select is(
  app.get_operational_health_v13(
    repeat('a', 64),
    1,
    null,
    null
  ) #>> '{operations,emailWorker,runningStale}',
  'false',
  'releasehealth herkent een vastgelopen run als een latere run slaagt'
);
insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  template_id,
  order_id,
  idempotency_key,
  payload,
  status,
  attempts,
  completed_at,
  updated_at
)
select
  'a4000000-0000-4000-8000-000000000006',
  'transactional',
  'recovery@example.invalid',
  'payment_received',
  template.id,
  'a3000000-0000-4000-8000-000000000001',
  'recovery-operation-6',
  '{}'::jsonb,
  'failed',
  1,
  statement_timestamp(),
  statement_timestamp()
from app.email_templates template
where template.template_key = 'payment_received';
insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  template_id,
  order_id,
  idempotency_key,
  payload,
  status,
  attempts,
  completed_at,
  last_error,
  updated_at
)
select
  safe_job.id,
  'transactional',
  'safe-terminal@example.invalid',
  'payment_received',
  template.id,
  'a3000000-0000-4000-8000-000000000001',
  'recovery-operation-' || safe_job.slot,
  '{}'::jsonb,
  'failed',
  0,
  statement_timestamp(),
  safe_job.reason,
  statement_timestamp()
from app.email_templates template
cross join (
  values
    ('a4000000-0000-4000-8000-000000000007'::uuid, '7', 'access_inactive_before_send'),
    ('a4000000-0000-4000-8000-000000000008'::uuid, '8', 'access_revoked_before_send'),
    ('a4000000-0000-4000-8000-000000000009'::uuid, '9', 'eligibility_changed_before_send'),
    ('a4000000-0000-4000-8000-000000000010'::uuid, '10', 'mail_v2_paused'),
    ('a4000000-0000-4000-8000-000000000011'::uuid, '11', 'superseded_by_back_in_stock')
) safe_job(id, slot, reason)
where template.template_key = 'payment_received';
update private.email_jobs
set status = 'queued',
    completed_at = null,
    last_error = null,
    updated_at = statement_timestamp()
where id = 'a4000000-0000-4000-8000-000000000008';
update private.email_jobs
set status = 'failed',
    completed_at = statement_timestamp(),
    last_error = 'access_revoked_before_send',
    updated_at = statement_timestamp()
where id = 'a4000000-0000-4000-8000-000000000008';
select is(
  (
    select count(*)
    from app.action_items item
    where item.type = 'email_failure'
      and item.object_id = 'a4000000-0000-4000-8000-000000000008'
  ),
  0::bigint,
  'bewuste toegangsintrekking voor verzending opent geen intern mailincident'
);
select is(
  (
    app.get_operational_health_v13(
      repeat('a', 64),
      1,
      null,
      null
    ) #>> '{emailJobs,failed}'
  )::integer,
  1,
  'health negeert alle benoemde pre-send stops maar blokkeert een echte nieuwe mailfailure'
);
select ok((select result::text from recovery_health) !~ '(example.invalid|sg-event|ticket/|payload|token)',
  'operationele health bevat geen PII, providerbewijs of secret');

insert into private.operation_runs(id, operation, status, started_at, finished_at, processed_count)
values(
  'a7000000-0000-4000-8000-000000000004', 'retention', 'succeeded',
  timezone('utc', now()) - interval '91 days', timezone('utc', now()) - interval '91 days', 0
);
select lives_ok($$select app.cleanup_expired_security_data(timezone('utc', now()))$$,
  'retentiejob ruimt ook de begrensde operation-runledger op');
select is((select count(*) from private.operation_runs where id = 'a7000000-0000-4000-8000-000000000004'), 0::bigint,
  'retentie verwijdert alleen oude voltooide operation-runs');
select is((select count(*) from private.operation_runs where id = 'a7000000-0000-4000-8000-000000000003'), 1::bigint,
  'retentie verwijdert een vastgelopen run niet als bewijs');

select * from finish();
rollback;

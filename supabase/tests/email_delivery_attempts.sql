begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  '277a0000-0000-4000-8000-000000000001',
  'Attemptbeheerder',
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
  '277a1000-0000-4000-8000-000000000001',
  'ATTEMPT-001',
  'Test',
  'Attempt',
  'attempt@example.invalid',
  'TEST'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  '277a2000-0000-4000-8000-000000000001',
  '277a1000-0000-4000-8000-000000000001',
  settings.active_season_id,
  100
from app.app_settings settings
where settings.id = true;

insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  template_id,
  order_id,
  idempotency_key,
  payload
)
select
  job_id,
  'transactional',
  'attempt@example.invalid',
  'payment_received',
  template.id,
  '277a2000-0000-4000-8000-000000000001',
  'delivery-attempt-test-' || slot,
  '{}'::jsonb
from app.email_templates template
cross join (
  values
    (1, '277a3000-0000-4000-8000-000000000001'::uuid),
    (2, '277a3000-0000-4000-8000-000000000002'::uuid)
) jobs(slot, job_id)
where template.template_key = 'payment_received';
insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', statement_timestamp() - interval '1 hour')
on conflict (key) do update
set activated_at = excluded.activated_at;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

select ok(
  not has_table_privilege(
    'service_role',
    'private.email_delivery_attempts',
    'SELECT'
  )
  and not has_table_privilege(
    'authenticated',
    'private.email_provider_event_quarantine',
    'SELECT'
  ),
  'attempt- en quarantainedata zijn voor API-rollen default-deny'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.claim_email_jobs_v4(uuid,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.claim_email_jobs_v3(uuid,integer)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.record_sendgrid_events_v2(jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.get_operational_health_v7(text,integer,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'app.record_sendgrid_events(jsonb)',
    'EXECUTE'
  ),
  'alleen attempt-gebonden worker- en webhook-RPCs zijn extern bereikbaar'
);

create temporary table first_claim as
select app.claim_email_jobs_v4(
  '277a4000-0000-4000-8000-000000000001',
  1
) result;
select is(
  (select result #>> '{jobs,0,id}' from first_claim),
  '277a3000-0000-4000-8000-000000000001',
  'v4 claimt de oudste job'
);
select is(
  (
    select result #>> '{jobs,0,deliveryAttemptId}'
    from first_claim
  ),
  (
    select current_delivery_attempt_id::text
    from private.email_jobs
    where id = '277a3000-0000-4000-8000-000000000001'
  ),
  'claimantwoord en private job wijzen naar dezelfde poging'
);
select is(
  (
    select count(*)::integer
    from private.email_delivery_attempts
    where email_job_id =
      '277a3000-0000-4000-8000-000000000001'
  ),
  1,
  'eerste claim creëert exact één immutable poging'
);
select ok(
  app.authorize_claimed_email_job_v4(
    '277a3000-0000-4000-8000-000000000001',
    '277a4000-0000-4000-8000-000000000001',
    (
      select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
      from first_claim
    )
  ),
  'send-time autorisatie is ook aan de poging gebonden'
);
select is(
  app.complete_email_job_v2(
    '277a3000-0000-4000-8000-000000000001',
    '277a4000-0000-4000-8000-000000000001',
    (
      select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
      from first_claim
    ),
    'sent',
    'http-message-attempt-1',
    null
  )->>'status',
  'sent',
  'HTTP-acceptatie voltooit exact de geclaimde poging'
);

create temporary table first_event_result as
select app.record_sendgrid_events_v2(jsonb_build_array(
  jsonb_build_object(
    'email_job_id',
    '277a3000-0000-4000-8000-000000000001',
    'delivery_attempt_id',
    (
      select result #>> '{jobs,0,deliveryAttemptId}'
      from first_claim
    ),
    'event_id',
    'provider-event-delivered-1',
    'provider_message_id',
    'event-message-attempt-1',
    'event_type',
    'delivered',
    'occurred_at',
    (
      select attempt.claimed_at + interval '1 second'
      from private.email_delivery_attempts attempt
      where attempt.id = (
        select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
        from first_claim
      )
    )
  )
)) result;
select is(
  (select result->>'recorded' from first_event_result),
  '1',
  'signed event accepteert een eigen event-message-ID naast het HTTP-ID'
);
select is(
  (
    select provider_message_id
    from private.email_jobs
    where id = '277a3000-0000-4000-8000-000000000001'
  ),
  'http-message-attempt-1',
  'provider-event overschrijft de HTTP-provideridentiteit niet'
);
select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-delivered-1',
      'provider_message_id',
      'event-message-attempt-1',
      'event_type',
      'delivered',
      'occurred_at',
      (
        select attempt.claimed_at + interval '1 second'
        from private.email_delivery_attempts attempt
        where attempt.id = (
          select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
          from first_claim
        )
      )
    )
  ))->>'ignored',
  '1',
  'exact dezelfde providerreplay is idempotent'
);
select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-delivered-1',
      'provider_message_id',
      'event-message-attempt-1',
      'event_type',
      'bounced',
      'occurred_at',
      statement_timestamp() + interval '1 second'
    )
  ))->>'quarantined',
  '1',
  'provider-event-ID-collisie wordt zichtbaar in quarantaine gezet'
);
select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-message-conflict',
      'provider_message_id',
      'different-event-message',
      'event_type',
      'delivered',
      'occurred_at',
      statement_timestamp() + interval '2 seconds'
    )
  ))->>'quarantined',
  '1',
  'een tweede providerberichtidentiteit binnen dezelfde poging projecteert niet'
);

select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-older-bounce',
      'provider_message_id',
      'event-message-attempt-1',
      'event_type',
      'bounced',
      'occurred_at',
      statement_timestamp()
    )
  ))->>'recorded',
  '1',
  'een ouder maar geldig event blijft in het immutable journaal'
);
select is(
  (
    select delivery_status
    from private.email_jobs
    where id = '277a3000-0000-4000-8000-000000000001'
  ),
  'delivered',
  'aankomstvolgorde kan de nieuwere providerstatus niet terugdraaien'
);

select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-newer-bounce',
      'provider_message_id',
      'event-message-attempt-1',
      'event_type',
      'bounced',
      'occurred_at',
      statement_timestamp() + interval '2 seconds'
    )
  ))->>'recorded',
  '1',
  'een werkelijk nieuwere bounce wordt geprojecteerd'
);
select is(
  (
    select delivery_status
    from private.email_jobs
    where id = '277a3000-0000-4000-8000-000000000001'
  ),
  'bounced',
  'nieuwste providerstatus bepaalt de jobprojectie'
);
select is(
  (
    select count(*)::integer
    from app.action_items
    where type = 'email_failure'
      and object_id = '277a3000-0000-4000-8000-000000000001'
      and status in ('open', 'in_progress')
  ),
  1,
  'definitieve bounce opent één beheeractie'
);

select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000001',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from first_claim
      ),
      'event_id',
      'provider-event-newer-delivered',
      'provider_message_id',
      'event-message-attempt-1',
      'event_type',
      'delivered',
      'occurred_at',
      statement_timestamp() + interval '3 seconds'
    )
  ))->>'recorded',
  '1',
  'nieuwer afleverbewijs herstelt de actuele projectie'
);
select is(
  (
    select count(*)::integer
    from app.action_items
    where type = 'email_failure'
      and object_id = '277a3000-0000-4000-8000-000000000001'
      and status in ('open', 'in_progress')
  ),
  0,
  'herstelde providerstatus lost de beheeractie automatisch op'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'internal_email_failure'
      and episode.scope_id =
        '277a3000-0000-4000-8000-000000000001'
      and episode.status = 'open'
  ),
  0,
  'herstelde providerstatus sluit ook de interne faalepisode'
);

create temporary table second_claim as
select app.claim_email_jobs_v4(
  '277a4000-0000-4000-8000-000000000002',
  1
) result;
select ok(
  app.authorize_claimed_email_job_v4(
    '277a3000-0000-4000-8000-000000000002',
    '277a4000-0000-4000-8000-000000000002',
    (
      select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
      from second_claim
    )
  ),
  'tweede job is attempt-gebonden geautoriseerd'
);
select is(
  app.complete_email_job_v2(
    '277a3000-0000-4000-8000-000000000002',
    '277a4000-0000-4000-8000-000000000002',
    (
      select (result #>> '{jobs,0,deliveryAttemptId}')::uuid
      from second_claim
    ),
    'delivery_uncertain',
    null,
    'delivery_uncertain'
  )->>'status',
  'delivery_uncertain',
  'onzekere HTTP-uitkomst wordt nooit automatisch herhaald'
);
create temporary table second_recovery_state as
select updated_at
from private.email_jobs
where id = '277a3000-0000-4000-8000-000000000002';
grant select on second_recovery_state to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"277a0000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.get_email_workspace_v4()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 krijgt de operationele workspace niet'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"277a0000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.get_email_workspace_v4()->>'recoveryAllowed',
  'true',
  'alleen AAL2-beheerder krijgt herstelbediening'
);
select is(
  app.recover_stale_email_job_v2(
    '277a3000-0000-4000-8000-000000000002',
    (
      select updated_at
      from second_recovery_state
    ),
    'retry_proven_not_accepted',
    'provider_confirmed_not_accepted',
    'ticket/ATTEMPT-RETRY',
    null,
    true,
    '277a5000-0000-4000-8000-000000000001'
  )->>'status',
  'retry',
  'AAL2-recovery maakt alleen bewezen niet-acceptatie opnieuw beschikbaar'
);
reset role;

update private.email_jobs
set available_at = timezone('utc', now())
where id = '277a3000-0000-4000-8000-000000000002';
create temporary table third_claim as
select app.claim_email_jobs_v4(
  '277a4000-0000-4000-8000-000000000003',
  1
) result;
select is(
  (
    select count(*)::integer
    from private.email_delivery_attempts
    where email_job_id =
      '277a3000-0000-4000-8000-000000000002'
  ),
  2,
  'bewezen retry krijgt een nieuwe pogingidentiteit'
);
select is(
  app.record_sendgrid_events_v2(jsonb_build_array(
    jsonb_build_object(
      'email_job_id',
      '277a3000-0000-4000-8000-000000000002',
      'delivery_attempt_id',
      (
        select result #>> '{jobs,0,deliveryAttemptId}'
        from second_claim
      ),
      'event_id',
      'provider-event-old-attempt',
      'provider_message_id',
      'event-message-old-attempt',
      'event_type',
      'delivered',
      'occurred_at',
      statement_timestamp() + interval '1 second'
    )
  ))->>'recorded',
  '1',
  'laat event van een eerdere poging blijft bewaard'
);
select is(
  (
    select status
    from private.email_jobs
    where id = '277a3000-0000-4000-8000-000000000002'
  ),
  'processing',
  'laat event van eerdere poging kan de huidige poging niet voltooien'
);
select throws_ok(
  $$update private.email_delivery_attempts
    set attempt_number = 5
    where email_job_id =
      '277a3000-0000-4000-8000-000000000002'$$,
  '23514',
  'EMAIL_DELIVERY_LEDGER_IMMUTABLE',
  'pogingidentiteit is append-only'
);
select is(
  (
    select status
    from private.migration_reconciliations
    where migration_key =
      '20260802277000_email_delivery_attempts'
  ),
  'passed',
  'attemptbackfill heeft een structureel reconciliatiebewijs'
);
select is(
  app.get_operational_health_v7(
    repeat('a', 64),
    1,
    null,
    null
  ) #>> '{emailDeliveryAttempts,quarantinedEvents}',
  '2',
  'operationele health maakt alle gequarantaineerde provider-events zichtbaar'
);
select is(
  app.get_operational_health_v7(
    repeat('a', 64),
    1,
    null,
    null
  ) #>> '{emailDeliveryAttempts,unboundLegacyEvents}',
  '0',
  'operationele health bewijst dat provider-events aan een poging zijn gebonden'
);
select is(
  app.get_operational_health_v7(
    repeat('a', 64),
    1,
    null,
    null
  ) #>> '{emailDeliveryAttempts,processingWithoutCurrentAttempt}',
  '0',
  'operationele health bewijst dat verwerkende jobs een actuele poging hebben'
);

select * from finish();
rollback;

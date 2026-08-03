begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  'd7100000-0000-4000-8000-000000000001',
  'Domeinmail beheerder',
  'beheerder'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"d7100000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_invite as
select app.save_mail_template_draft_v1(
  'portal_access_invite',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'portal_access_invite'
      and status = 'draft'
  ),
  'Portaaltoegang uitnodiging',
  'Toegang tot {{club_name}}',
  'Open zelf het veilige tenueportaal.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[{"type":"text","text":"Uw portaaltoegang is geactiveerd."}]
      },
      {"type":"protectedBlock","attrs":{"kind":"portal_route"}}
    ]
  }'::jsonb,
  '<p>Uw portaaltoegang is geactiveerd.</p>',
  'Uw portaaltoegang is geactiveerd. Open zelf het tenueportaal.',
  null
) result;
select lives_ok(
  format(
    $sql$select app.publish_mail_template_revision_v1(
      %L::uuid,
      %L,
      null
    )$sql$,
    (
      select id
      from app.mail_template_revisions
      where template_key = 'portal_access_invite'
        and status = 'draft'
    ),
    (select result->>'contentHash' from saved_invite)
  ),
  'de uitnodigingtemplate kan voor de domeinprojectie worden gepubliceerd'
);
reset role;

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', timezone('utc', now()) - interval '1 hour')
on conflict (key) do update set activated_at = excluded.activated_at;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values
  (
    'd7110000-0000-4000-8000-000000000001',
    'DOMAIN-MAIL-1',
    'Sophie',
    'Domeinmail',
    'gezin-domeinmail@example.invalid',
    'JO11-1'
  ),
  (
    'd7110000-0000-4000-8000-000000000002',
    'DOMAIN-MAIL-2',
    'Milan',
    'Domeinmail',
    'gezin-domeinmail@example.invalid',
    'JO13-1'
  );

insert into private.parent_accounts(id, email_normalized)
values(
  'd7120000-0000-4000-8000-000000000001',
  'gezin-domeinmail@example.invalid'
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
  'd7130000-0000-4000-8000-000000000001'::uuid,
  member_season.id,
  'gezin-domeinmail@example.invalid',
  'd7120000-0000-4000-8000-000000000001'::uuid,
  'active'::app.parent_grant_status,
  'administrator',
  'd7100000-0000-4000-8000-000000000001'::uuid,
  timezone('utc', now())
from app.member_seasons member_season
where member_season.member_id =
  'd7110000-0000-4000-8000-000000000001'
union all
select
  'd7130000-0000-4000-8000-000000000002'::uuid,
  member_season.id,
  'gezin-domeinmail@example.invalid',
  'd7120000-0000-4000-8000-000000000001'::uuid,
  'active'::app.parent_grant_status,
  'administrator',
  'd7100000-0000-4000-8000-000000000001'::uuid,
  timezone('utc', now())
from app.member_seasons member_season
where member_season.member_id =
  'd7110000-0000-4000-8000-000000000002';

insert into private.parent_access_batches(
  id,
  batch_key,
  operation,
  season_id,
  selection_hash,
  selected_count,
  actor_user_id
)
select
  'd7140000-0000-4000-8000-000000000001',
  'd7140000-0000-4000-8000-000000000002',
  'activate',
  settings.active_season_id,
  repeat('a', 64),
  2,
  'd7100000-0000-4000-8000-000000000001'
from app.app_settings settings
where settings.id = true;

insert into private.parent_access_batch_items(
  batch_id,
  member_season_id,
  grant_id,
  outcome
)
select
  'd7140000-0000-4000-8000-000000000001',
  grant_row.member_season_id,
  grant_row.id,
  'activated'
from private.parent_portal_grants grant_row
where grant_row.id in (
  'd7130000-0000-4000-8000-000000000001',
  'd7130000-0000-4000-8000-000000000002'
);

select ok(
  private.mail_v2_payload_keys_are_safe(
    '{"memberFirstName":"Sophie","orderId":"d7150000-0000-4000-8000-000000000001"}'
  ),
  'veilige camelCase-projectiesleutels zijn toegestaan'
);
select ok(
  not private.mail_v2_payload_keys_are_safe(
    '{"recipientEmail":"ouder@example.invalid"}'
  ),
  'camelCase e-mailvelden worden geweigerd'
);
select ok(
  not private.mail_v2_payload_keys_are_safe(
    '{"nested":{"dateOfBirth":"2012-01-01","relationNumber":"DSV-1"}}'
  ),
  'geneste DOB- en relatienummervelden worden geweigerd'
);
select ok(
  not private.mail_v2_payload_keys_are_safe(
    '{"memberNote":"geheim","qrToken":"niet-opslaan"}'
  ),
  'notities en QR-tokenvelden worden geweigerd'
);

select ok(
  has_function_privilege(
    'service_role',
    'app.claim_mail_v2_domain_projections_v1(uuid,integer)',
    'EXECUTE'
  ),
  'alleen de serviceworker kan generieke projecties claimen'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.claim_mail_v2_domain_projections_v1(uuid,integer)',
    'EXECUTE'
  ),
  'browserrollen kunnen generieke projecties niet claimen'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.mail_v2_domain_events',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'de serviceworker heeft geen brede eventtabelrechten'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.mail_v2_projection_batches',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'de serviceworker heeft geen brede projectietabelrechten'
);

select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.template_key = 'portal_access_invite'
      and event.cohort_id =
        'd7140000-0000-4000-8000-000000000001'
  ),
  2,
  'de activatie produceert één immutable event per geselecteerd kind'
);

select throws_ok(
  format(
    $sql$select private.enqueue_mail_v2_member_event(
      'portal_access_invite',
      %L::uuid,
      %L::uuid,
      'parent_access_batch',
      %L::uuid,
      %L::uuid,
      %L
    )$sql$,
    event.parent_account_id,
    event.member_season_id,
    event.source_id,
    'd7140000-0000-4000-8000-000000000099',
    event.idempotency_key
  ),
  '40001',
  'MAIL_V2_EVENT_IDEMPOTENCY_CONFLICT',
  'dezelfde idempotentiesleutel kan niet naar andere context wijzen'
)
from private.mail_v2_domain_events event
where event.template_key = 'portal_access_invite'
order by event.id
limit 1;

set local role service_role;
create temporary table first_domain_claim as
select app.claim_mail_v2_domain_projections_v1(
  'd7150000-0000-4000-8000-000000000001',
  10
) result;
reset role;

select is(
  jsonb_array_length(
    (select result->'groups' from first_domain_claim)
  ),
  1,
  'één ouder, seizoen, proces en cohort vormt één mailgroep'
);
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from first_domain_claim)
  ),
  2,
  'beide kinderen worden in dezelfde activatiemail geconsolideerd'
);
select ok(
  (
    select result::text !~* (
      '"(dateOfBirth|date_of_birth|relationNumber|relation_number|'
      || 'recipientEmail|recipient_email|token|secret|otp|qr)"'
      || '[[:space:]]*:'
    )
    from first_domain_claim
  ),
  'de claim bevat geen DOB, relatienummer, adres of geheim'
);

create temporary table first_render_input as
select
  (result#>>'{groups,0,groupId}')::uuid group_id,
  result#>>'{groups,0,eligibilityRevision}' eligibility_revision,
  (result#>>'{groups,0,template,id}')::uuid template_revision_id,
  (result#>>'{groups,0,branding,id}')::uuid branding_revision_id,
  'Toegang tot Duindorp SV'::text subject,
  'Open zelf het veilige tenueportaal.'::text preheader,
  '<p>Uw portaaltoegang is veilig geactiveerd.</p>'::text html,
  'Uw portaaltoegang is veilig geactiveerd.'::text body_text
from first_domain_claim;

alter table first_render_input add column render_hash text;
update first_render_input input
set render_hash = private.mail_v2_render_hash(
  input.group_id,
  input.eligibility_revision,
  input.template_revision_id,
  input.branding_revision_id,
  input.subject,
  input.preheader,
  input.html,
  input.body_text
);
grant select on first_render_input to service_role;

set local role service_role;
create temporary table first_finalize as
select app.finalize_mail_v2_domain_projection_v1(
  input.group_id,
  'd7150000-0000-4000-8000-000000000001',
  input.eligibility_revision,
  input.subject,
  input.preheader,
  input.html,
  input.body_text,
  input.render_hash
) result
from first_render_input input;
create temporary table first_job_claim as
select app.claim_email_jobs_v4(
  'd7150000-0000-4000-8000-000000000002',
  25
) result;
reset role;

select is(
  (select result->>'status' from first_finalize),
  'queued',
  'de gevalideerde projectie wordt één immutable job'
);
select is(
  (select result#>>'{jobs,0,contextKind}' from first_job_claim),
  'mail_v2',
  'de worker claimt de generieke immutable snapshotcontext'
);

update private.parent_portal_grants
set status = 'revoked',
    revoked_at = timezone('utc', now()),
    revoked_reason = 'Test intrekking vóór verzending',
    updated_at = timezone('utc', now())
where id = 'd7130000-0000-4000-8000-000000000002';

set local role service_role;
create temporary table first_authorization as
select app.authorize_claimed_email_job_v4(
  (select (result#>>'{jobs,0,id}')::uuid from first_job_claim),
  'd7150000-0000-4000-8000-000000000002',
  (
    select (result#>>'{jobs,0,deliveryAttemptId}')::uuid
    from first_job_claim
  )
) allowed;
reset role;

select is(
  (select allowed from first_authorization),
  false,
  'een ingetrokken gezinsgrant blokkeert de oude snapshot voor verzending'
);
select is(
  (
    select status
    from private.email_jobs
    where id = (select (result#>>'{jobs,0,id}')::uuid from first_job_claim)
  ),
  'failed',
  'de oude job wordt terminal geparkeerd zonder providerverkeer'
);
select is(
  (
    select status
    from private.mail_v2_projection_batches
    where id = (select group_id from first_render_input)
  ),
  'leased',
  'de gezinsbatch wordt voor de nog geldige subset opnieuw geleased'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    join private.mail_v2_domain_events event
      on event.id = suppression.event_id
    where event.cohort_id =
      'd7140000-0000-4000-8000-000000000001'
  ),
  0,
  'een gedeeltelijke intrekking onderdrukt de hele gezinsbatch niet'
);

set local role service_role;
create temporary table subset_domain_claim as
select app.claim_mail_v2_domain_projections_v1(
  'd7150000-0000-4000-8000-000000000003',
  10
) result;
reset role;
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from subset_domain_claim)
  ),
  1,
  'herprojectie bevat alleen het nog geautoriseerde kind'
);

create temporary table subset_render_input as
select
  (result#>>'{groups,0,groupId}')::uuid group_id,
  result#>>'{groups,0,eligibilityRevision}' eligibility_revision,
  (result#>>'{groups,0,template,id}')::uuid template_revision_id,
  (result#>>'{groups,0,branding,id}')::uuid branding_revision_id,
  'Toegang tot Duindorp SV'::text subject,
  'Open zelf het veilige tenueportaal.'::text preheader,
  '<p>Uw portaaltoegang is veilig geactiveerd.</p>'::text html,
  'Uw portaaltoegang is veilig geactiveerd.'::text body_text
from subset_domain_claim;
alter table subset_render_input add column render_hash text;
update subset_render_input input
set render_hash = private.mail_v2_render_hash(
  input.group_id,
  input.eligibility_revision,
  input.template_revision_id,
  input.branding_revision_id,
  input.subject,
  input.preheader,
  input.html,
  input.body_text
);
grant select on subset_render_input to service_role;

set local role service_role;
create temporary table subset_finalize as
select app.finalize_mail_v2_domain_projection_v1(
  input.group_id,
  'd7150000-0000-4000-8000-000000000003',
  input.eligibility_revision,
  input.subject,
  input.preheader,
  input.html,
  input.body_text,
  input.render_hash
) result
from subset_render_input input;
create temporary table subset_job_claim as
select app.claim_email_jobs_v4(
  'd7150000-0000-4000-8000-000000000004',
  25
) result;
reset role;

update app.release_feature_flags
set enabled = false
where key = 'mail_templates_v2';

set local role service_role;
create temporary table paused_authorization as
select app.authorize_claimed_email_job_v4(
  (select (result#>>'{jobs,0,id}')::uuid from subset_job_claim),
  'd7150000-0000-4000-8000-000000000004',
  (
    select (result#>>'{jobs,0,deliveryAttemptId}')::uuid
    from subset_job_claim
  )
) allowed;
reset role;

select is(
  (select allowed from paused_authorization),
  false,
  'pauzeren na claim blokkeert providerverkeer'
);
select is(
  (
    select status
    from private.email_jobs
    where id = (select (result#>>'{jobs,0,id}')::uuid from subset_job_claim)
  ),
  'queued',
  'een gepauzeerde job blijft hervatbaar'
);
select is(
  (
    select attempts
    from private.email_jobs
    where id = (select (result#>>'{jobs,0,id}')::uuid from subset_job_claim)
  ),
  0,
  'een pauze verbruikt geen verzendpoging'
);

insert into private.parent_access_batches(
  id,
  batch_key,
  operation,
  season_id,
  selection_hash,
  selected_count,
  actor_user_id
)
select
  'd7140000-0000-4000-8000-000000000010',
  'd7140000-0000-4000-8000-000000000011',
  'activate',
  settings.active_season_id,
  repeat('b', 64),
  1,
  'd7100000-0000-4000-8000-000000000001'
from app.app_settings settings
where settings.id = true;
insert into private.parent_access_batch_items(
  batch_id,
  member_season_id,
  grant_id,
  outcome
)
select
  'd7140000-0000-4000-8000-000000000010',
  grant_row.member_season_id,
  grant_row.id,
  'activated'
from private.parent_portal_grants grant_row
where grant_row.id = 'd7130000-0000-4000-8000-000000000001';
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.cohort_id =
      'd7140000-0000-4000-8000-000000000010'
  ),
  1,
  'een producent bewaart events tijdens een tijdelijke mailpauze'
);

update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';
set local role service_role;
create temporary table resumed_job_claim as
select app.claim_email_jobs_v4(
  'd7150000-0000-4000-8000-000000000005',
  25
) result;
create temporary table resumed_authorization as
select app.authorize_claimed_email_job_v4(
  (select (result#>>'{jobs,0,id}')::uuid from resumed_job_claim),
  'd7150000-0000-4000-8000-000000000005',
  (
    select (result#>>'{jobs,0,deliveryAttemptId}')::uuid
    from resumed_job_claim
  )
) allowed;
reset role;
select is(
  (select allowed from resumed_authorization),
  true,
  'na hervatten kan exact dezelfde geldige snapshot alsnog worden verzonden'
);

set local role service_role;
create temporary table recovery_domain_claim as
select app.claim_mail_v2_domain_projections_v1(
  'd7150000-0000-4000-8000-000000000006',
  10
) result;
grant select on recovery_domain_claim to authenticated;
reset role;

select set_config('app.mail_v2_projection_internal', 'on', true);
update private.mail_v2_projection_batches
set lease_expires_at = clock_timestamp() + interval '100 milliseconds'
where id = (
  select (result#>>'{groups,0,groupId}')::uuid
  from recovery_domain_claim
);
select set_config('app.mail_v2_projection_internal', 'off', true);
select pg_sleep(0.15);

set local role service_role;
select throws_ok(
  format(
    $sql$select app.fail_mail_v2_domain_projection_v1(
      %L::uuid,
      'd7150000-0000-4000-8000-000000000006'::uuid,
      'render_invalid'
    )$sql$,
    (select result#>>'{groups,0,groupId}' from recovery_domain_claim)
  ),
  '40001',
  'MAIL_V2_DOMAIN_LEASE_CONFLICT',
  'een na transactiestart verlopen domeinlease kan niet meer worden afgerond'
);
reset role;
select set_config('app.mail_v2_projection_internal', 'on', true);
update private.mail_v2_projection_batches
set lease_expires_at = timezone('utc', now()) - interval '1 second'
where id = (
  select (result#>>'{groups,0,groupId}')::uuid
  from recovery_domain_claim
);
select set_config('app.mail_v2_projection_internal', 'off', true);
set local role service_role;
create temporary table recovery_domain_reclaim as
select app.claim_mail_v2_domain_projections_v1(
  'd7150000-0000-4000-8000-000000000009',
  10
) result;
select throws_ok(
  format(
    $sql$select app.fail_mail_v2_domain_projection_v1(
      %L::uuid,
      'd7150000-0000-4000-8000-000000000006'::uuid,
      'render_invalid'
    )$sql$,
    (select result#>>'{groups,0,groupId}' from recovery_domain_claim)
  ),
  '40001',
  'MAIL_V2_DOMAIN_LEASE_CONFLICT',
  'een oude worker kan een opnieuw geclaimde domeinprojectie niet muteren'
);
create temporary table recovery_failure as
select app.fail_mail_v2_domain_projection_v1(
  (select (result#>>'{groups,0,groupId}')::uuid
   from recovery_domain_reclaim),
  'd7150000-0000-4000-8000-000000000009',
  'render_invalid'
) result;
reset role;

select is(
  (select result#>>'{groups,0,groupId}' from recovery_domain_reclaim),
  (select result#>>'{groups,0,groupId}' from recovery_domain_claim),
  'een verlopen domeinlease wordt als dezelfde immutable batch hergeclaimd'
);

select is(
  (select result->>'status' from recovery_failure),
  'suppressed',
  'een deterministische rendererfout wordt veilig geparkeerd'
);
select ok(
  exists(
    select 1
    from app.action_items item
    where item.type = 'mail_projection_failed'
      and item.object_id = (
        select (result#>>'{groups,0,groupId}')::uuid
        from recovery_domain_claim
      )
      and item.status = 'open'
  ),
  'een geparkeerde projectie opent één beheeractie'
);

set local role authenticated;
create temporary table recovery_retry as
select app.retry_mail_v2_domain_projection_v1(
  (select (result#>>'{groups,0,groupId}')::uuid
   from recovery_domain_claim),
  0,
  'Template gecorrigeerd en opnieuw gecontroleerd',
  'd7150000-0000-4000-8000-000000000007'
) result;
reset role;

select is(
  (select result->>'status' from recovery_retry),
  'leased',
  'beheerder kan een herstelbare projectiefout opnieuw vrijgeven'
);
select is(
  (select result->>'retryCount' from recovery_retry),
  '1',
  'herprojectie is expliciet en begrensd geteld'
);
select ok(
  exists(
    select 1
    from app.action_items item
    where item.type = 'mail_projection_failed'
      and item.object_id = (
        select (result#>>'{groups,0,groupId}')::uuid
        from recovery_domain_claim
      )
      and item.status = 'resolved'
      and item.resolution_source = 'system'
  ),
  'de herstelactie wordt na geaudite retry aantoonbaar gesloten'
);

set local role service_role;
create temporary table recovered_domain_claim as
select app.claim_mail_v2_domain_projections_v1(
  'd7150000-0000-4000-8000-000000000008',
  10
) result;
reset role;
select is(
  (select result#>>'{groups,0,groupId}' from recovered_domain_claim),
  (select result#>>'{groups,0,groupId}' from recovery_domain_claim),
  'retry hergebruikt dezelfde immutable eventbinding zonder duplicaat'
);

select * from finish();
rollback;

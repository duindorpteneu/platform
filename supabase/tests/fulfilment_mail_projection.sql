begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  'e6900000-0000-4000-8000-000000000001',
  'Mailprojectie beheerder',
  'beheerder'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e6900000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

create temporary table saved_partial as
select app.save_mail_template_draft_v1(
  'partial_pickup',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'partial_pickup'
      and status = 'draft'
  ),
  'Deelafhaling',
  'Deel afgehaald voor {{member_first_name}}',
  'Bekijk wat nu is afgehaald en wat nog volgt.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Beste ouder van "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"picked_up_items"}},
      {"type":"protectedBlock","attrs":{"kind":"remaining_items"}}
    ]
  }'::jsonb,
  '<p>Beste ouder</p><table><tbody><tr><td>Afgehaald</td></tr></tbody></table>',
  'Beste ouder. Bekijk wat is afgehaald en wat nog volgt.',
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
      where template_key = 'partial_pickup'
        and status = 'draft'
    ),
    (select result->>'contentHash' from saved_partial)
  ),
  'deelafhalingtemplate kan voor de projectietest worden gepubliceerd'
);

create temporary table saved_complete as
select app.save_mail_template_draft_v1(
  'package_complete',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'package_complete'
      and status = 'draft'
  ),
  'Pakket compleet',
  'Pakket compleet voor {{member_first_name}}',
  'Alle pakketregels zijn afgehaald.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Beste ouder van "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"full_package"}}
    ]
  }'::jsonb,
  '<p>Beste ouder</p><table><tbody><tr><td>Volledig pakket</td></tr></tbody></table>',
  'Beste ouder. Het pakket is volledig afgehaald.',
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
      where template_key = 'package_complete'
        and status = 'draft'
    ),
    (select result->>'contentHash' from saved_complete)
  ),
  'eindbevestigingtemplate kan voor de projectietest worden gepubliceerd'
);
reset role;

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', timezone('utc', now()) - interval '1 hour')
on conflict (key) do update
set activated_at = excluded.activated_at;
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
    'e6910000-0000-4000-8000-000000000001',
    'MAIL-PROJ-001',
    'Sophie',
    'Projectie',
    'gezin-projectie@example.invalid',
    'JO11-1'
  ),
  (
    'e6910000-0000-4000-8000-000000000002',
    'MAIL-PROJ-002',
    'Milan',
    'Projectie',
    'gezin-projectie@example.invalid',
    'JO13-1'
  );

insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  'e6920000-0000-4000-8000-000000000001'::uuid,
  'e6910000-0000-4000-8000-000000000001'::uuid,
  settings.active_season_id,
  12500
from app.app_settings settings
where settings.id = true
union all
select
  'e6920000-0000-4000-8000-000000000002'::uuid,
  'e6910000-0000-4000-8000-000000000002'::uuid,
  settings.active_season_id,
  12500
from app.app_settings settings
where settings.id = true;

insert into private.parent_accounts(id, email_normalized)
values(
  'e6930000-0000-4000-8000-000000000001',
  'gezin-projectie@example.invalid'
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
  'e6940000-0000-4000-8000-000000000001'::uuid,
  orders.member_season_id,
  'gezin-projectie@example.invalid',
  'e6930000-0000-4000-8000-000000000001'::uuid,
  'active'::app.parent_grant_status,
  'administrator',
  'e6900000-0000-4000-8000-000000000001'::uuid,
  timezone('utc', now())
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001'
union all
select
  'e6940000-0000-4000-8000-000000000002'::uuid,
  orders.member_season_id,
  'gezin-projectie@example.invalid',
  'e6930000-0000-4000-8000-000000000001'::uuid,
  'active'::app.parent_grant_status,
  'administrator',
  'e6900000-0000-4000-8000-000000000001'::uuid,
  timezone('utc', now())
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000002';

insert into app.fulfilments(
  id,
  order_id,
  actor_user_id,
  location,
  member_season_id,
  season_id
)
select
  'e6950000-0000-4000-8000-000000000001'::uuid,
  orders.id,
  'e6900000-0000-4000-8000-000000000001'::uuid,
  'Free-Kick Sport',
  orders.member_season_id,
  orders.season_id
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001'
union all
select
  'e6950000-0000-4000-8000-000000000002'::uuid,
  orders.id,
  'e6900000-0000-4000-8000-000000000001'::uuid,
  'Free-Kick Sport',
  orders.member_season_id,
  orders.season_id
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000002';

insert into private.fulfilment_notification_events(
  id,
  fulfilment_id,
  order_id,
  member_season_id,
  season_id,
  event_type,
  idempotency_key,
  payload_snapshot
)
select
  'e6960000-0000-4000-8000-000000000001'::uuid,
  'e6950000-0000-4000-8000-000000000001'::uuid,
  orders.id,
  orders.member_season_id,
  orders.season_id,
  'partial_pickup',
  repeat('1', 64),
  '{
    "fulfilmentId":"e6950000-0000-4000-8000-000000000001",
    "issued":[{"product":"Shirt","size":"152","quantity":1}],
    "remaining":[{"product":"Broek","size":"152","quantity":1,"status":"backorder"}],
    "package":[
      {"product":"Shirt","size":"152","quantity":1,"status":"picked_up"},
      {"product":"Broek","size":"152","quantity":1,"status":"backorder"}
    ]
  }'::jsonb
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001'
union all
select
  'e6960000-0000-4000-8000-000000000002'::uuid,
  'e6950000-0000-4000-8000-000000000002'::uuid,
  orders.id,
  orders.member_season_id,
  orders.season_id,
  'partial_pickup',
  repeat('2', 64),
  '{
    "fulfilmentId":"e6950000-0000-4000-8000-000000000002",
    "issued":[{"product":"Keepersshirt","size":"164","quantity":1}],
    "remaining":[{"product":"Kousen","size":"39-42","quantity":1,"status":"ready_for_pickup"}],
    "package":[
      {"product":"Keepersshirt","size":"164","quantity":1,"status":"picked_up"},
      {"product":"Kousen","size":"39-42","quantity":1,"status":"ready_for_pickup"}
    ]
  }'::jsonb
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000002';

select ok(
  has_function_privilege(
    'service_role',
    'app.claim_fulfilment_mail_projections_v1(uuid,integer)',
    'EXECUTE'
  ),
  'alleen de serviceworker heeft het projectieclaimcontract'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.claim_fulfilment_mail_projections_v1(uuid,integer)',
    'EXECUTE'
  ),
  'browserrollen kunnen geen mailprojecties claimen'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.fulfilment_mail_projection_batches',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role heeft geen brede toegang tot projectietabellen'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.fulfilment_mail_supersessions',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role kan het immutable supersessionledger niet rechtstreeks wijzigen'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.finalize_fulfilment_mail_projection_v1(uuid,uuid,text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'anon kan geen gerenderde fulfilmentmail finaliseren'
);
select ok(
  not has_function_privilege(
    'service_role',
    'app.retry_fulfilment_mail_projection_v1(uuid,text,uuid)',
    'EXECUTE'
  ),
  'de serviceworker kan een beheerderherstel niet zelf starten'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.get_email_worker_preflight_v1(text,text,text)',
    'EXECUTE'
  ),
  'browserrollen kunnen senderconfiguratie noch queued drift opvragen'
);

set local role service_role;
create temporary table valid_worker_preflight as
select app.get_email_worker_preflight_v1(
  'Kledingcommissie Duindorp SV',
  'kleding@duindorpsv.nl',
  'kleding@duindorpsv.nl'
) result;
create temporary table invalid_worker_preflight as
select app.get_email_worker_preflight_v1(
  'Afwijkende afzender',
  'ander@duindorpsv.nl',
  'ander@duindorpsv.nl'
) result;
reset role;
select is(
  (select result->>'ready' from valid_worker_preflight),
  'true',
  'de workerpreflight accepteert exact de gepubliceerde senderconfiguratie'
);
select is(
  (select result->>'ready' from invalid_worker_preflight),
  'false',
  'senderdrift faalt gesloten vóór projectie of claim'
);

set local role service_role;
create temporary table first_projection_claim as
select app.claim_fulfilment_mail_projections_v1(
  'e6970000-0000-4000-8000-000000000001',
  10
) result;
reset role;

select is(
  jsonb_array_length(
    (select result->'groups' from first_projection_claim)
  ),
  1,
  'één ouder, seizoen en type wordt één geconsolideerde mailgroep'
);
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from first_projection_claim)
  ),
  2,
  'beide kinderen zitten in dezelfde geconsolideerde groep'
);
select is(
  (select result#>>'{groups,0,eventType}' from first_projection_claim),
  'partial_pickup',
  'deelafhaling projecteert exact op PARTIAL_PICKUP'
);
select ok(
  (
    select result::text !~*
      'date_of_birth|geboortedatum|relation_number|token_hash|locator'
    from first_projection_claim
  ),
  'projectiecontext bevat geen DOB, relatienummer of geheim'
);
select ok(
  not exists(
    select 1
    from private.fulfilment_notification_events event
    join app.member_orders orders on orders.id = event.order_id
    where event.id in (
      'e6960000-0000-4000-8000-000000000001',
      'e6960000-0000-4000-8000-000000000002'
    )
      and event.package_snapshot_id <> orders.active_package_snapshot_id
  ),
  'ieder immutable uitgifte-event bindt de pakketmomentopname bij eventcreatie'
);

set local role service_role;
create temporary table concurrent_projection_claim as
select app.claim_fulfilment_mail_projections_v1(
  'e6970000-0000-4000-8000-000000000002',
  10
) result;
reset role;
select is(
  jsonb_array_length(
    (select result->'groups' from concurrent_projection_claim)
  ),
  0,
  'een tweede worker kan dezelfde geleasede events niet claimen'
);

create temporary table projection_render as
select
  (result#>>'{groups,0,groupId}')::uuid group_id,
  result#>>'{groups,0,eligibilityRevision}' eligibility_revision,
  (result#>>'{groups,0,template,id}')::uuid template_revision_id,
  (result#>>'{groups,0,branding,id}')::uuid branding_revision_id,
  'Deelafhaling voor Sophie en Milan'::text subject,
  'Bekijk wat is afgehaald en wat nog volgt.'::text preheader,
  '<p>Veilig gerenderde deelafhaling</p>'::text html,
  'Veilig gerenderde deelafhaling'::text body_text
from first_projection_claim;

alter table projection_render add column render_hash text;
update projection_render
set render_hash = private.mail_v2_render_hash(
  group_id,
  eligibility_revision,
  template_revision_id,
  branding_revision_id,
  subject,
  preheader,
  html,
  body_text
);
grant select on projection_render to service_role, authenticated;

set local role service_role;
select throws_ok(
  format(
    $sql$select app.finalize_fulfilment_mail_projection_v1(
      %L::uuid,
      'e6970000-0000-4000-8000-000000000001'::uuid,
      %L,
      %L,
      %L,
      %L,
      %L,
      %L
    )$sql$,
    render.group_id,
    render.eligibility_revision,
    render.subject,
    render.preheader,
    '<img src="javascript:alert(1)">',
    render.body_text,
    repeat('0', 64)
  ),
  '22023',
  'MAIL_PROJECTION_FINALIZE_INVALID',
  'databasefinalisatie weigert uitvoerbare HTML ook met een passende hash'
)
from projection_render render;

create temporary table finalized_projection as
select app.finalize_fulfilment_mail_projection_v1(
  render.group_id,
  'e6970000-0000-4000-8000-000000000001',
  render.eligibility_revision,
  render.subject,
  render.preheader,
  render.html,
  render.body_text,
  render.render_hash
) result
from projection_render render;
reset role;

select is(
  (select result->>'status' from finalized_projection),
  'queued',
  'geldige render wordt atomair gequeue-d'
);
select is(
  (
    select count(*)
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  1::bigint,
  'exact één duurzame job bestaat voor twee uitgifte-events'
);
select ok(
  (
    select
      job.template_id is null
      and job.template_version is null
      and job.subject_source_snapshot is null
      and job.mail_template_revision_id is not null
      and job.mail_branding_revision_id is not null
      and job.from_name_snapshot = 'Kledingcommissie Duindorp SV'
      and job.from_email_snapshot = 'kleding@duindorpsv.nl'
      and job.reply_to_email_snapshot = 'kleding@duindorpsv.nl'
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  'mail-v2 gebruikt alleen immutable render- en sender-snapshots'
);
select ok(
  (
    select
      job.payload ? 'eventCount'
      and not job.payload ?| array[
        'email',
        'name',
        'memberName',
        'dateOfBirth',
        'relationNumber'
      ]
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  'jobpayload bevat alleen veilige projectiemetadata'
);

set local role service_role;
create temporary table repeated_finalize as
select app.finalize_fulfilment_mail_projection_v1(
  render.group_id,
  'e6970000-0000-4000-8000-000000000001',
  render.eligibility_revision,
  render.subject,
  render.preheader,
  render.html,
  render.body_text,
  render.render_hash
) result
from projection_render render;
reset role;
select is(
  (select result->>'reused' from repeated_finalize),
  'true',
  'finalize is idempotent na een verloren workerresponse'
);
select is(
  (
    select count(*)
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  1::bigint,
  'idempotente finalize maakt geen tweede mailjob'
);

set local role service_role;
create temporary table legacy_claim as
select app.claim_email_jobs_v2(
  'e6980000-0000-4000-8000-000000000001',
  25
) result;
reset role;
select is(
  jsonb_array_length((select result->'jobs' from legacy_claim)),
  0,
  'rollbackworker v2 ziet geen mail-v2 rendersnapshot'
);

set local role service_role;
create temporary table v3_claim as
select app.claim_email_jobs_v3(
  'e6980000-0000-4000-8000-000000000002',
  25
) result;
reset role;
select is(
  jsonb_array_length((select result->'jobs' from v3_claim)),
  1,
  'v3-worker claimt de geconsolideerde rendersnapshot'
);
select is(
  (select result#>>'{jobs,0,contextKind}' from v3_claim),
  'fulfilment',
  'v3-claim is expliciet gediscrimineerd als fulfilment'
);
select is(
  (select result#>>'{jobs,0,eventCount}' from v3_claim),
  '2',
  'v3-claim behoudt het geconsolideerde eventaantal'
);
select ok(
  (
    select
      not (result#>'{jobs,0}' ? 'payload')
      and not (result#>'{jobs,0}' ? 'orderId')
      and result::text !~*
        'mail-proj|date_of_birth|relation_number|memberSeasonId'
    from v3_claim
  ),
  'de sendclaim bevat alleen renderoutput en geen bronpayload of lid-identifiers'
);

set local role service_role;
select is(
  app.authorize_claimed_email_job_v2(
    (select (result#>>'{jobs,0,id}')::uuid from v3_claim),
    'e6980000-0000-4000-8000-000000000002'
  ),
  true,
  'actieve grants autoriseren de geconsolideerde sendclaim'
);
reset role;

update private.parent_portal_grants
set status = 'revoked',
    revoked_by = 'e6900000-0000-4000-8000-000000000001',
    revoked_at = timezone('utc', now()),
    revoked_reason = 'Toegang ingetrokken vóór verzending'
where id = 'e6940000-0000-4000-8000-000000000002';

set local role service_role;
select is(
  app.authorize_claimed_email_job_v2(
    (select (result#>>'{jobs,0,id}')::uuid from v3_claim),
    'e6980000-0000-4000-8000-000000000002'
  ),
  false,
  'ingetrokken toegang onderdrukt de volledige immutable gezinsmail'
);
reset role;

select is(
  (
    select status
    from private.email_jobs
    where context_kind = 'fulfilment'
  ),
  'failed',
  'onderdrukte sendclaim kan niet meer naar SendGrid'
);
select is(
  (
    select status
    from private.fulfilment_mail_projection_batches
  ),
  'leased',
  'een gewijzigde gezinsdoelgroep wordt automatisch opnieuw geleased'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'mail_projection_failed'
      and status = 'open'
  ),
  0::bigint,
  'een gedeeltelijke grantintrekking opent geen foutactie voor geldige kinderen'
);
select ok(
  not exists(
    select 1
    from app.action_items item
    where item.type = 'mail_projection_failed'
      and item.safe_context::text ~*
        'sophie|milan|example.invalid|date_of_birth'
  ),
  'een eventuele projectieactie kan nooit ontvanger- of leden-PII bevatten'
);
select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'mail_v2.fulfilment.queued'
      and audit.metadata::text ~*
        'sophie|milan|example.invalid|date_of_birth'
  ),
  'projectieaudit bevat geen ontvanger- of leden-PII'
);

select throws_ok(
  $$update private.email_jobs
    set rendered_subject_snapshot = 'Stille wijziging'
    where context_kind = 'fulfilment'$$,
  '23514',
  'EMAIL_JOB_SNAPSHOT_IMMUTABLE',
  'rendersnapshot is na enqueue onveranderlijk'
);
select throws_ok(
  $$update private.fulfilment_notification_events
    set payload_snapshot = '{}'::jsonb
    where id = 'e6960000-0000-4000-8000-000000000001'$$,
  '23514',
  'QR_EVENT_IMMUTABLE',
  'bron-event blijft onveranderlijk'
);

set local role service_role;
create temporary table subset_claim as
select app.claim_fulfilment_mail_projections_v1(
  'e6970000-0000-4000-8000-000000000003',
  10
) result;
reset role;
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from subset_claim)
  ),
  1,
  'na intrekking wordt alleen het nog bevoegde kind opnieuw geprojecteerd'
);
select ok(
  (
    select result::text !~* 'milan'
    from subset_claim
  ),
  'de opnieuw gerenderde gezinsmail bevat het ingetrokken kind niet'
);

create temporary table subset_render as
select
  (result#>>'{groups,0,groupId}')::uuid group_id,
  result#>>'{groups,0,eligibilityRevision}' eligibility_revision,
  (result#>>'{groups,0,template,id}')::uuid template_revision_id,
  (result#>>'{groups,0,branding,id}')::uuid branding_revision_id,
  'Deelafhaling voor Sophie'::text subject,
  'Bekijk wat is afgehaald en wat nog volgt.'::text preheader,
  '<p>Veilige gerenderde deelafhaling voor één actief kind</p>'::text html,
  'Veilige gerenderde deelafhaling voor één actief kind'::text body_text
from subset_claim;
alter table subset_render add column render_hash text;
update subset_render
set render_hash = private.mail_v2_render_hash(
  group_id,
  eligibility_revision,
  template_revision_id,
  branding_revision_id,
  subject,
  preheader,
  html,
  body_text
);
grant select on subset_render to service_role, authenticated;

set local role service_role;
create temporary table subset_finalize as
select app.finalize_fulfilment_mail_projection_v1(
  render.group_id,
  'e6970000-0000-4000-8000-000000000003',
  render.eligibility_revision,
  render.subject,
  render.preheader,
  render.html,
  render.body_text,
  render.render_hash
) result
from subset_render render;
reset role;
select is(
  (select result->>'status' from subset_finalize),
  'queued',
  'de geldige subset wordt opnieuw als immutable job gequeue-d'
);

set local role service_role;
create temporary table subset_send_claim as
select app.claim_email_jobs_v3(
  'e6980000-0000-4000-8000-000000000003',
  25
) result;
select is(
  app.authorize_claimed_email_job_v2(
    (select (result#>>'{jobs,0,id}')::uuid from subset_send_claim),
    'e6980000-0000-4000-8000-000000000003'
  ),
  true,
  'de herberekende subset slaagt de laatste send-autorisatie'
);
reset role;

update private.parent_portal_grants
set status = 'revoked',
    revoked_by = 'e6900000-0000-4000-8000-000000000001',
    revoked_at = timezone('utc', now()),
    revoked_reason = 'Ook laatste toegang ingetrokken vóór verzending'
where id = 'e6940000-0000-4000-8000-000000000001';

set local role service_role;
select is(
  app.authorize_claimed_email_job_v2(
    (select (result#>>'{jobs,0,id}')::uuid from subset_send_claim),
    'e6980000-0000-4000-8000-000000000003'
  ),
  false,
  'zonder enige geldige grant wordt de job definitief onderdrukt'
);
reset role;
select is(
  (
    select status
    from private.fulfilment_mail_projection_batches
  ),
  'suppressed',
  'nul geldige ontvangers bewaart een niet-destructieve suppressiestatus'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'mail_projection_failed'
      and status = 'open'
  ),
  1::bigint,
  'volledige doelgroepsuppressie opent exact één beheeractiepunt'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e6900000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.retry_fulfilment_mail_projection_v1(
      %L::uuid,
      'Herstel na tijdelijke grantintrekking',
      null
    )$sql$,
    (select group_id from projection_render)
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 kan een onderdrukte mail niet herstarten'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e6900000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.retry_fulfilment_mail_projection_v1(
      %L::uuid,
      'Herstel terwijl een grant nog ingetrokken is',
      null
    )$sql$,
    (select group_id from projection_render)
  ),
  '23514',
  'MAIL_PROJECTION_RETRY_RECONCILIATION_REQUIRED',
  'herstel blijft geblokkeerd zolang geen enkele grant geldig is'
);
reset role;

update private.parent_portal_grants
set status = 'active',
    revoked_by = null,
    revoked_at = null,
    revoked_reason = null
where id = 'e6940000-0000-4000-8000-000000000001';

select set_config(
  'request.jwt.claims',
  '{"sub":"e6900000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table recovered_projection as
select app.retry_fulfilment_mail_projection_v1(
  (select group_id from projection_render),
  'Grant hersteld en doelgroep opnieuw gecontroleerd',
  'e6990000-0000-4000-8000-000000000001'
) result;
select is(
  (select result->>'status' from recovered_projection),
  'leased',
  'AAL2-beheerder kan een aantoonbaar herstelde projectie opnieuw vrijgeven'
);
select is(
  (select result->>'retryCount' from recovered_projection),
  '2',
  'herstel verhoogt de duurzame retryteller exact één keer'
);
select is(
  (
    select app.retry_fulfilment_mail_projection_v1(
      (select group_id from projection_render),
      'Idempotente herhaling van herstel',
      null
    )->>'reused'
  ),
  'true',
  'een verloren herstelresponse maakt geen tweede retry'
);
reset role;

select is(
  (
    select status
    from app.action_items
    where type = 'mail_projection_failed'
      and object_id = (select group_id from projection_render)
  ),
  'resolved',
  'geslaagd beheerderherstel sluit het bijbehorende actiepunt'
);
select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'mail_v2.fulfilment.retry_requested'
      and (
        audit.metadata ? 'reason'
        or audit.metadata::text ~*
          'grant hersteld|sophie|milan|example.invalid'
      )
  ),
  'herstelaudit bevat uitsluitend reden-digest, lengte en retrytelling'
);

set local role service_role;
create temporary table recovered_claim as
select app.claim_fulfilment_mail_projections_v1(
  'e6970000-0000-4000-8000-000000000005',
  10
) result;
reset role;
select is(
  jsonb_array_length((select result->'groups' from recovered_claim)),
  1,
  'de worker kan een verlopen herstelleased batch exact één keer herclaimen'
);

set local role service_role;
create temporary table recovered_finalize as
select app.finalize_fulfilment_mail_projection_v1(
  render.group_id,
  'e6970000-0000-4000-8000-000000000005',
  (select result#>>'{groups,0,eligibilityRevision}' from recovered_claim),
  render.subject,
  render.preheader,
  render.html,
  render.body_text,
  render.render_hash
) result
from subset_render render;
reset role;
select is(
  (select result->>'status' from recovered_finalize),
  'queued',
  'herstelde projectie kan opnieuw atomair worden gequeue-d'
);
select is(
  (
    select count(*)
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  3::bigint,
  'herstelde projectie bewaart de mislukte job en maakt één nieuwe retryjob'
);
select is(
  (
    select count(distinct job.idempotency_key)
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
  ),
  3::bigint,
  'retryteller maakt de hersteljob idempotent zonder historie te overschrijven'
);

insert into app.fulfilments(
  id,
  order_id,
  actor_user_id,
  location,
  member_season_id,
  season_id
)
select
  'e6950000-0000-4000-8000-000000000003'::uuid,
  orders.id,
  'e6900000-0000-4000-8000-000000000001'::uuid,
  'Free-Kick Sport',
  orders.member_season_id,
  orders.season_id
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001';

insert into app.fulfilments(
  id,
  order_id,
  actor_user_id,
  location,
  member_season_id,
  season_id
)
select
  'e6950000-0000-4000-8000-000000000004'::uuid,
  orders.id,
  'e6900000-0000-4000-8000-000000000001'::uuid,
  'Free-Kick Sport',
  orders.member_season_id,
  orders.season_id
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001';

insert into private.fulfilment_notification_events(
  id,
  fulfilment_id,
  order_id,
  member_season_id,
  season_id,
  event_type,
  idempotency_key,
  payload_snapshot
)
select
  'e6960000-0000-4000-8000-000000000004'::uuid,
  'e6950000-0000-4000-8000-000000000004'::uuid,
  orders.id,
  orders.member_season_id,
  orders.season_id,
  'partial_pickup',
  repeat('4', 64),
  '{
    "fulfilmentId":"e6950000-0000-4000-8000-000000000004",
    "issued":[{"product":"Tussenlevering","size":"152","quantity":1}],
    "remaining":[{"product":"Broek","size":"152","quantity":1,"status":"ready_for_pickup"}],
    "package":[
      {"product":"Shirt","size":"152","quantity":1,"status":"picked_up"},
      {"product":"Broek","size":"152","quantity":1,"status":"ready_for_pickup"}
    ]
  }'::jsonb
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001';

insert into private.fulfilment_notification_events(
  id,
  fulfilment_id,
  order_id,
  member_season_id,
  season_id,
  event_type,
  idempotency_key,
  payload_snapshot
)
select
  'e6960000-0000-4000-8000-000000000003'::uuid,
  'e6950000-0000-4000-8000-000000000003'::uuid,
  orders.id,
  orders.member_season_id,
  orders.season_id,
  'package_complete',
  repeat('3', 64),
  '{
    "fulfilmentId":"e6950000-0000-4000-8000-000000000003",
    "issued":[{"product":"Broek","size":"152","quantity":1}],
    "remaining":[],
    "package":[
      {"product":"Shirt","size":"152","quantity":1,"status":"picked_up"},
      {"product":"Broek","size":"152","quantity":1,"status":"picked_up"}
    ]
  }'::jsonb
from app.member_orders orders
where orders.id = 'e6920000-0000-4000-8000-000000000001';

set local role service_role;
create temporary table complete_claim as
select app.claim_fulfilment_mail_projections_v1(
  'e6970000-0000-4000-8000-000000000004',
  10
) result;
reset role;
select is(
  jsonb_array_length((select result->'groups' from complete_claim)),
  1,
  'een finale afhaling verdringt een nog niet gequeue-de deelmelding'
);
select is(
  (select result#>>'{groups,0,eventType}' from complete_claim),
  'package_complete',
  'de laatste afhaling projecteert uitsluitend op PACKAGE_COMPLETE'
);
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from complete_claim)
  ),
  1,
  'de eindbevestiging bevat het volledige pakket van precies het betrokken lid'
);
select is(
  (
    select batch.event_count
    from private.fulfilment_mail_projection_batches batch
    where batch.id = (
      select (result#>>'{groups,0,groupId}')::uuid
      from complete_claim
    )
  ),
  1,
  'de completionbatch telt alleen het ene gerenderde finale event'
);
select is(
  (
    select count(*)
    from private.fulfilment_mail_supersessions supersession
    where supersession.event_id =
      'e6960000-0000-4000-8000-000000000004'
      and supersession.superseding_event_id =
        'e6960000-0000-4000-8000-000000000003'
      and supersession.projection_batch_id = (
        select (result#>>'{groups,0,groupId}')::uuid
        from complete_claim
      )
  ),
  1::bigint,
  'het verdrongen deel-event staat apart en immutable in het supersessionledger'
);
select is(
  (
    select result#>>'{groups,0,events,0,eventId}'
    from complete_claim
  ),
  'e6960000-0000-4000-8000-000000000003',
  'alleen het finale event wordt gerenderd'
);

create temporary table complete_render as
select
  (result#>>'{groups,0,groupId}')::uuid group_id,
  result#>>'{groups,0,eligibilityRevision}' eligibility_revision,
  (result#>>'{groups,0,template,id}')::uuid template_revision_id,
  (result#>>'{groups,0,branding,id}')::uuid branding_revision_id,
  'Pakket compleet voor Sophie'::text subject,
  'Alle pakketregels zijn afgehaald.'::text preheader,
  '<p>Veilig gerenderde eindbevestiging</p>'::text html,
  'Veilig gerenderde eindbevestiging'::text body_text
from complete_claim;
alter table complete_render add column render_hash text;
update complete_render
set render_hash = private.mail_v2_render_hash(
  group_id,
  eligibility_revision,
  template_revision_id,
  branding_revision_id,
  subject,
  preheader,
  html,
  body_text
);
grant select on complete_render to service_role;

set local role service_role;
create temporary table complete_finalize as
select app.finalize_fulfilment_mail_projection_v1(
  render.group_id,
  'e6970000-0000-4000-8000-000000000004',
  render.eligibility_revision,
  render.subject,
  render.preheader,
  render.html,
  render.body_text,
  render.render_hash
) result
from complete_render render;
reset role;
select is(
  (select result->>'status' from complete_finalize),
  'queued',
  'de eindbevestiging wordt als één immutable job vastgelegd'
);
select is(
  (
    select count(*)
    from private.email_jobs job
    where job.context_kind = 'fulfilment'
      and job.template_key = 'package_complete'
      and job.status = 'queued'
  ),
  1::bigint,
  'laatste afhaling maakt één eindmail en geen extra deelmail'
);

select * from finish();
rollback;
reset role;

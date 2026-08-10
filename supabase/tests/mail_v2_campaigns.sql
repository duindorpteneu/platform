begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  (
    'c7400000-0000-4000-8000-000000000001',
    'Campagnebeheerder',
    'beheerder'
  ),
  (
    'c7400000-0000-4000-8000-000000000002',
    'Campagnecommissie',
    'kledingcommissie'
  ),
  (
    'c7400000-0000-4000-8000-000000000003',
    'Campagne-uitgifte',
    'uitgifte'
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_payment_request as
select app.save_mail_template_draft_v1(
  'payment_request',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'payment_request'
      and status = 'draft'
  ),
  'Betaalverzoek pakket',
  'Betaalverzoek voor {{member_first_name}}',
  'Betaal {{package_amount}} via {{payment_url}}.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Betaal "},
          {"type":"shortcode","attrs":{"key":"package_amount"}},
          {"type":"text","text":" voor "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}},
          {"type":"text","text":" via "},
          {"type":"shortcode","attrs":{"key":"payment_url"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"payment_summary"}},
      {"type":"protectedBlock","attrs":{"kind":"payment_action"}}
    ]
  }'::jsonb,
  '<p>Betaal het vaste pakketbedrag via het veilige portaal.</p>',
  'Betaal het vaste pakketbedrag via het veilige portaal.',
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
      where template_key = 'payment_request'
        and status = 'draft'
    ),
    (select result->>'contentHash' from saved_payment_request)
  ),
  'de betaalverzoektemplate kan gepubliceerd worden'
);
reset role;

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', timezone('utc', now()) - interval '1 hour')
on conflict (key) do update set activated_at = excluded.activated_at;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

insert into app.articles(id, name, code, sort_order, active)
values(
  'c7410000-0000-4000-8000-000000000001',
  'Campagneshirt',
  'CAMP-SHIRT',
  740,
  true
);
insert into app.article_seasons(article_id, season_id)
select
  'c7410000-0000-4000-8000-000000000001',
  settings.active_season_id
from app.app_settings settings
where settings.id = true;
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values (
  'c7420000-0000-4000-8000-000000000001',
  'c7410000-0000-4000-8000-000000000001',
  'M',
  'CAMP-M',
  1,
  true
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values
  (
    'c7430000-0000-4000-8000-000000000001',
    'CAMP-001',
    'Sophie',
    'Campagne',
    'campagne-gezin@example.invalid',
    'JO11-1'
  ),
  (
    'c7430000-0000-4000-8000-000000000002',
    'CAMP-002',
    'Milan',
    'Campagne',
    'campagne-gezin@example.invalid',
    'JO13-1'
  );
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  'c7440000-0000-4000-8000-000000000001'::uuid,
  'c7430000-0000-4000-8000-000000000001'::uuid,
  settings.active_season_id,
  10000
from app.app_settings settings
where settings.id = true
union all
select
  'c7440000-0000-4000-8000-000000000002'::uuid,
  'c7430000-0000-4000-8000-000000000002'::uuid,
  settings.active_season_id,
  12500
from app.app_settings settings
where settings.id = true;
insert into app.order_lines(
  id,
  order_id,
  article_variant_id
) values
  (
    'c7450000-0000-4000-8000-000000000001',
    'c7440000-0000-4000-8000-000000000001',
    'c7420000-0000-4000-8000-000000000001'
  ),
  (
    'c7450000-0000-4000-8000-000000000002',
    'c7440000-0000-4000-8000-000000000002',
    'c7420000-0000-4000-8000-000000000001'
  );

insert into private.parent_accounts(id, email_normalized)
values(
  'c7460000-0000-4000-8000-000000000001',
  'campagne-gezin@example.invalid'
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
  case member_season.member_id
    when 'c7430000-0000-4000-8000-000000000001'
    then 'c7470000-0000-4000-8000-000000000001'::uuid
    else 'c7470000-0000-4000-8000-000000000002'::uuid
  end,
  member_season.id,
  'campagne-gezin@example.invalid',
  'c7460000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'c7400000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_seasons member_season
where member_season.member_id in (
  'c7430000-0000-4000-8000-000000000001',
  'c7430000-0000-4000-8000-000000000002'
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values
  (
    'c7430000-0000-4000-8000-000000000003',
    'CAMP-003',
    'Lars',
    'Drift',
    'campagne-drift@example.invalid',
    'JO15-1'
  ),
  (
    'c7430000-0000-4000-8000-000000000004',
    'CAMP-004',
    'Noa',
    'Portaal',
    'campagne-portaal@example.invalid',
    'JO9-1'
  );
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  'c7440000-0000-4000-8000-000000000003',
  'c7430000-0000-4000-8000-000000000003',
  settings.active_season_id,
  9900
from app.app_settings settings
where settings.id = true;
insert into app.order_lines(id, order_id, article_variant_id)
values(
  'c7450000-0000-4000-8000-000000000003',
  'c7440000-0000-4000-8000-000000000003',
  'c7420000-0000-4000-8000-000000000001'
);
insert into private.parent_accounts(id, email_normalized) values
  (
    'c7460000-0000-4000-8000-000000000002',
    'campagne-drift@example.invalid'
  ),
  (
    'c7460000-0000-4000-8000-000000000003',
    'campagne-portaal@example.invalid'
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
  case member_season.member_id
    when 'c7430000-0000-4000-8000-000000000003'
    then 'c7470000-0000-4000-8000-000000000003'::uuid
    else 'c7470000-0000-4000-8000-000000000004'::uuid
  end,
  member_season.id,
  case member_season.member_id
    when 'c7430000-0000-4000-8000-000000000003'
    then 'campagne-drift@example.invalid'
    else 'campagne-portaal@example.invalid'
  end,
  case member_season.member_id
    when 'c7430000-0000-4000-8000-000000000003'
    then 'c7460000-0000-4000-8000-000000000002'::uuid
    else 'c7460000-0000-4000-8000-000000000003'::uuid
  end,
  'active',
  'administrator',
  'c7400000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_seasons member_season
where member_season.member_id in (
  'c7430000-0000-4000-8000-000000000003',
  'c7430000-0000-4000-8000-000000000004'
);

insert into app.seasons(
  id,
  name,
  starts_on,
  ends_on,
  default_amount_cents,
  status,
  opened_at
)
values(
  'c74a0000-0000-4000-8000-000000000001',
  '2027/2028',
  date '2027-07-01',
  date '2028-06-30',
  15000,
  'open',
  timezone('utc', now())
);
insert into app.article_seasons(article_id, season_id)
values(
  'c7410000-0000-4000-8000-000000000001',
  'c74a0000-0000-4000-8000-000000000001'
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  'c7430000-0000-4000-8000-000000000005',
  'CAMP-005',
  'Sara',
  'Nieuwseizoen',
  'campagne-seizoen@example.invalid',
  'MO17-1'
);
insert into app.member_seasons(
  id,
  member_id,
  season_id,
  team_name,
  participation_status,
  reconciliation_status
) values (
  'c74a0000-0000-4000-8000-000000000002',
  'c7430000-0000-4000-8000-000000000005',
  'c74a0000-0000-4000-8000-000000000001',
  'MO17-1',
  'active',
  'resolved'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
) values (
  'c74a0000-0000-4000-8000-000000000003',
  'c7430000-0000-4000-8000-000000000005',
  'c74a0000-0000-4000-8000-000000000001',
  15000
);
insert into app.order_lines(id, order_id, article_variant_id)
values(
  'c74a0000-0000-4000-8000-000000000004',
  'c74a0000-0000-4000-8000-000000000003',
  'c7420000-0000-4000-8000-000000000001'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000002","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_v2_campaign_workspace_v1()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'ook het doelgroepoverzicht vereist actuele MFA'
);
select throws_ok(
  $$select app.preview_mail_v2_campaign_v1(
    'payment_request',
    array['c7440000-0000-4000-8000-000000000001'::uuid],
    'c7480000-0000-4000-8000-000000000010'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'campagnepreflight vereist actuele MFA'
);
reset role;

select set_config('request.jwt.claims', '{}', true);
set local role anon;
select throws_ok(
  $$select app.get_mail_v2_campaign_workspace_v1()$$,
  '42501',
  'permission denied for schema app',
  'een anonieme gebruiker krijgt geen campagneworkspace'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_v2_campaign_workspace_v1()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte krijgt geen campagne- of ontvangerworkspace'
);
select throws_ok(
  $$select app.preview_mail_v2_campaign_v1(
    'payment_request',
    array['c7440000-0000-4000-8000-000000000001'::uuid],
    'c7480000-0000-4000-8000-000000000021'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan geen campagnepreflight starten'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_mail_v2_campaign_workspace_v1()->'portalTargets',
  '[]'::jsonb,
  'kledingcommissie krijgt geen toegangsdoelgroepen'
);
select ok(
  app.get_mail_v2_campaign_workspace_v1()->'allowedTemplates'
    ? 'payment_reminder',
  'een reminder met complete planner-capability is operationeel beschikbaar'
);
select throws_ok(
  $$select app.preview_mail_v2_campaign_v1(
    'portal_access_reminder',
    array['c7440000-0000-4000-8000-000000000001'::uuid],
    'c7480000-0000-4000-8000-000000000001'
  )$$,
  '22023',
  'MAIL_V2_CAMPAIGN_INPUT_INVALID',
  'kledingcommissie kan geen toegangsherinnering starten'
);
create temporary table family_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array[
    'c7440000-0000-4000-8000-000000000001'::uuid,
    'c7440000-0000-4000-8000-000000000002'::uuid
  ],
  'c7480000-0000-4000-8000-000000000002'
) result;
grant select on family_preview to service_role;

select is(
  (select result->>'eligibleTargetCount' from family_preview),
  '2',
  'beide onbetaalde pakketten zijn geschikt'
);
select is(
  (select result->>'eligibleEventCount' from family_preview),
  '2',
  'ieder pakket levert één immutable event'
);
select is(
  (select result->>'parentGroupCount' from family_preview),
  '1',
  'gedeeld ouderaccount vormt één geconsolideerde mailgroep'
);
select ok(
  (
    select result->'previewGroup'->'events'->0->'payload'->>'memberFirstName'
      in ('Sophie', 'Milan')
    from family_preview
  ),
  'preflight bevat één echte, geautoriseerde representatieve gezinsrender'
);
select is(
  (
    select jsonb_array_length(result#>'{previewGroup,events}')
    from family_preview
  ),
  2,
  'het gedeelde ouderaccount toont beide geselecteerde kinderen in de preview'
);
select ok(
  (
    select (result->'previewGroup')::text
      !~* 'campagne-gezin|date.?of.?birth|relation.?number'
    from family_preview
  ),
  'de exacte preview bevat geen ontvangeradres, DOB of relatienummer'
);

create temporary table family_confirm as
select app.confirm_mail_v2_campaign_v1(
  (select (result->>'preflightId')::uuid from family_preview),
  (select result->>'eligibilityRevision' from family_preview),
  'c7480000-0000-4000-8000-000000000003',
  'c7480000-0000-4000-8000-000000000004'
) result;
select is(
  (select result->>'eventCount' from family_confirm),
  '2',
  'confirm hercontroleert en schrijft beide events'
);
reset role;
select is(
  (
    select count(distinct event.cohort_id)::integer
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_campaign'
      and event.source_id =
        (select (result->>'runId')::uuid from family_confirm)
  ),
  1,
  'de hele run gebruikt exact één cohort'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_campaign'
      and event.source_id =
        (select (result->>'runId')::uuid from family_confirm)
  ),
  2,
  'eventproductie is exact en niet per ontvangeradres gedupliceerd'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_projection_batches batch
    join private.mail_v2_campaign_preflights preflight
      on preflight.id =
        (select (result->>'preflightId')::uuid from family_preview)
    where batch.cohort_id =
        (select (result->>'runId')::uuid from family_confirm)
      and batch.template_revision_id = preflight.template_revision_id
      and batch.branding_revision_id = preflight.branding_revision_id
  ),
  1,
  'de geconsolideerde groep is aan exact de bekeken contentrevisies gebonden'
);
set local role authenticated;
select is(
  (
    select app.confirm_mail_v2_campaign_v1(
      (select (result->>'preflightId')::uuid from family_preview),
      (select result->>'eligibilityRevision' from family_preview),
      'c7480000-0000-4000-8000-000000000003',
      null
    )->>'reused'
  ),
  'true',
  'dezelfde confirm-request is idempotent'
);
select is(
  (
    select app.confirm_mail_v2_campaign_v1(
      (select (result->>'preflightId')::uuid from family_preview),
      (select result->>'eligibilityRevision' from family_preview),
      'c7480000-0000-4000-8000-000000000012',
      null
    )->>'reused'
  ),
  'true',
  'een tweede confirm-request voor dezelfde preflight hergebruikt de run'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from family_preview),
    (select result->>'eligibilityRevision' from family_preview),
    'c7480000-0000-4000-8000-000000000003'
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'een andere actor kan een bestaand confirm-requestresultaat niet uitlezen'
);
reset role;

set local role service_role;
create temporary table family_projection as
select app.claim_mail_v2_domain_projections_v1(
  'c7480000-0000-4000-8000-000000000005',
  10
) result;
reset role;
select is(
  jsonb_array_length(
    (select result#>'{groups,0,events}' from family_projection)
  ),
  2,
  'de projector consolideert beide kinderen in één jobinput'
);
select is(
  (
    select result#>>'{groups,0,template,id}'
    from family_projection
  ),
  (
    select preflight.template_revision_id::text
    from private.mail_v2_campaign_preflights preflight
    where preflight.id =
      (select (result->>'preflightId')::uuid from family_preview)
  ),
  'de worker ontvangt exact de template uit de campagnepreflight'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table content_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['c7440000-0000-4000-8000-000000000003'::uuid],
  'c7480000-0000-4000-8000-000000000009'
) result;
create temporary table replacement_draft as
select app.save_mail_template_draft_v1(
  'payment_request',
  null,
  'Betaalverzoek pakket revisie twee',
  'Nieuw betaalverzoek voor {{member_first_name}}',
  'Betaal {{package_amount}} veilig via {{payment_url}}.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Betaal "},
          {"type":"shortcode","attrs":{"key":"package_amount"}},
          {"type":"text","text":" voor "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}},
          {"type":"text","text":" veilig via "},
          {"type":"shortcode","attrs":{"key":"payment_url"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"payment_summary"}},
      {"type":"protectedBlock","attrs":{"kind":"payment_action"}}
    ]
  }'::jsonb,
  '<p>Betaal het vaste pakketbedrag veilig via het portaal.</p>',
  'Betaal het vaste pakketbedrag veilig via het portaal.',
  null
) result;
select lives_ok(
  format(
    $sql$select app.publish_mail_template_revision_v1(
      %L::uuid,
      %L,
      null
    )$sql$,
    (select result->>'revisionId' from replacement_draft),
    (select result->>'contentHash' from replacement_draft)
  ),
  'een beheerder kan na de preflight een nieuwe revisie publiceren'
);
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from content_preview),
    (select result->>'eligibilityRevision' from content_preview),
    'c7480000-0000-4000-8000-000000000011'
  ),
  '40001',
  'MAIL_V2_CAMPAIGN_CONTENT_CHANGED',
  'publicatiedrift tussen preview en confirm faalt gesloten'
);
reset role;

set local role authenticated;
create temporary table amount_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['c7440000-0000-4000-8000-000000000003'::uuid],
  'c7480000-0000-4000-8000-000000000015'
) result;
reset role;
update app.member_orders
set amount_due_cents = 10100
where id = 'c7440000-0000-4000-8000-000000000003';
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from amount_preview),
    (select result->>'eligibilityRevision' from amount_preview),
    'c7480000-0000-4000-8000-000000000016'
  ),
  '40001',
  'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED',
  'bedrag- en pakketsnapshotdrift tussen preview en confirm faalt gesloten'
);
create temporary table identity_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['c7440000-0000-4000-8000-000000000003'::uuid],
  'c7480000-0000-4000-8000-000000000017'
) result;
reset role;
update app.members
set first_name = 'Lars gewijzigd'
where id = 'c7430000-0000-4000-8000-000000000003';
update app.member_seasons
set team_name = 'JO15-2'
where member_id = 'c7430000-0000-4000-8000-000000000003'
  and season_id = (
    select season_id
    from app.member_orders
    where id = 'c7440000-0000-4000-8000-000000000003'
  );
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from identity_preview),
    (select result->>'eligibilityRevision' from identity_preview),
    'c7480000-0000-4000-8000-000000000018'
  ),
  '40001',
  'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED',
  'naam- en teamdrift tussen preview en confirm faalt gesloten'
);
reset role;

insert into app.articles(id, name, code, sort_order, active) values
  (
    'c7410000-0000-4000-8000-000000000002',
    'Conflictbroek',
    'CAMP-BROEK',
    741,
    true
  ),
  (
    'c7410000-0000-4000-8000-000000000003',
    'Campagnekousen',
    'CAMP-KOUS',
    742,
    true
  );
insert into app.article_seasons(article_id, season_id)
select article_id, settings.active_season_id
from (
  values
    ('c7410000-0000-4000-8000-000000000002'::uuid),
    ('c7410000-0000-4000-8000-000000000003'::uuid)
) article(article_id)
cross join app.app_settings settings
where settings.id = true;
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values
  (
    'c7420000-0000-4000-8000-000000000002',
    'c7410000-0000-4000-8000-000000000002',
    '152',
    'CAMP-BROEK-152',
    1,
    true
  ),
  (
    'c7420000-0000-4000-8000-000000000003',
    'c7410000-0000-4000-8000-000000000003',
    '39-42',
    'CAMP-KOUS-39-42',
    1,
    true
  );
insert into app.order_lines(id, order_id, article_variant_id) values
  (
    'c7450000-0000-4000-8000-000000000004',
    'c7440000-0000-4000-8000-000000000002',
    'c7420000-0000-4000-8000-000000000002'
  ),
  (
    'c7450000-0000-4000-8000-000000000005',
    'c7440000-0000-4000-8000-000000000002',
    'c7420000-0000-4000-8000-000000000003'
  );
update app.member_article_sizes size_profile
set article_variant_id = null,
    selection_status = 'conflict',
    selection_source = 'import',
    raw_value = 'XXXL',
    confirmed_at = null,
    updated_at = timezone('utc', now())
where size_profile.member_id = 'c7430000-0000-4000-8000-000000000002'
  and size_profile.article_id =
    'c7410000-0000-4000-8000-000000000002';
insert into app.inventory_movements(
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  source_type,
  reason_code,
  idempotency_key
)
select
  settings.active_season_id,
  movement.article_id,
  movement.variant_id,
  'opening_balance',
  2,
  'mail_campaign_test',
  movement.reason_code,
  movement.idempotency_key
from (
  values
    (
      'c7410000-0000-4000-8000-000000000001'::uuid,
      'c7420000-0000-4000-8000-000000000001'::uuid,
      'mail_campaign.available_shirt',
      repeat('b', 64)
    ),
    (
      'c7410000-0000-4000-8000-000000000002'::uuid,
      'c7420000-0000-4000-8000-000000000002'::uuid,
      'mail_campaign.available_invalid_trouser',
      repeat('c', 64)
    )
) movement(article_id, variant_id, reason_code, idempotency_key)
cross join app.app_settings settings
where settings.id = true;
select is(
  private.mail_v2_order_line_size_is_valid(
    'c7450000-0000-4000-8000-000000000004'
  ),
  false,
  'een geïmporteerd maatconflict is niet allocatie- of mailgeldig'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_campaign_candidates(
      'available_payment_required',
      (select active_season_id from app.app_settings where id = true),
      array['c7440000-0000-4000-8000-000000000002'::uuid]
    ) candidate
    where candidate.outcome = 'eligible'
  ),
  1,
  'beschikbare voorraad met ten minste één geldige maat maakt de order geschikt'
);
select is(
  jsonb_array_length(
    private.mail_v2_member_payload(
      'available_payment_required',
      'c7460000-0000-4000-8000-000000000001',
      (
        select member_season_id
        from app.member_orders
        where id = 'c7440000-0000-4000-8000-000000000002'
      ),
      'c7480000-0000-4000-8000-000000000019',
      null
    )->'lines'
  ),
  1,
  'de voorraadmail bevat uitsluitend regels met een exact geldige maat'
);
select ok(
  private.mail_v2_member_payload(
    'available_payment_required',
    'c7460000-0000-4000-8000-000000000001',
    (
      select member_season_id
      from app.member_orders
      where id = 'c7440000-0000-4000-8000-000000000002'
    ),
    'c7480000-0000-4000-8000-000000000019',
    null
  )::text !~ 'Conflictbroek',
  'een product met maatconflict lekt niet mee in de voorraadmail'
);

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at,
  reconciliation_issue
) values (
  'c7490000-0000-4000-8000-000000000001',
  'c7440000-0000-4000-8000-000000000001',
  'cash',
  'paid',
  10000,
  'campaign-payment-conflict-0001',
  timezone('utc', now()),
  'Handmatige reconciliatie vereist'
);

set local role authenticated;
create temporary table conflict_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['c7440000-0000-4000-8000-000000000001'::uuid],
  'c7480000-0000-4000-8000-000000000006'
) result;
select is(
  (select result->>'blockedTargetCount' from conflict_preview),
  '1',
  'een betaalreconciliatieconflict blokkeert een nieuw betaalverzoek'
);
select is(
  (select result->>'eligibleEventCount' from conflict_preview),
  '0',
  'een betaalconflict produceert geen event'
);

create temporary table stale_preview as
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['c7440000-0000-4000-8000-000000000003'::uuid],
  'c7480000-0000-4000-8000-000000000007'
) result;
reset role;
update private.parent_portal_grants
set status = 'revoked',
    revoked_at = timezone('utc', now()),
    revoked_reason = 'Regressietest',
    updated_at = timezone('utc', now())
where id = 'c7470000-0000-4000-8000-000000000003';

set local role authenticated;
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from stale_preview),
    (select result->>'eligibilityRevision' from stale_preview),
    'c7480000-0000-4000-8000-000000000008'
  ),
  '40001',
  'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED',
  'toegangsintrekking tussen preview en confirm faalt gesloten'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"c7400000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_portal_reminder as
select app.save_mail_template_draft_v1(
  'portal_access_reminder',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'portal_access_reminder'
      and status = 'draft'
  ),
  'Herinnering portaaltoegang',
  'Uw toegang tot {{club_name}} staat klaar',
  'Open zelf het portaal via {{portal_url}}.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Uw toegang tot "},
          {"type":"shortcode","attrs":{"key":"club_name"}},
          {"type":"text","text":" staat klaar via "},
          {"type":"shortcode","attrs":{"key":"portal_url"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"portal_route"}}
    ]
  }'::jsonb,
  '<p>Open zelf het portaal en vraag daar pas een inlogcode aan.</p>',
  'Open zelf het portaal en vraag daar pas een inlogcode aan.',
  null
) result;
select lives_ok(
  format(
    $sql$select app.publish_mail_template_revision_v1(
      %L::uuid,
      %L,
      null
    )$sql$,
    (select result->>'revisionId' from saved_portal_reminder),
    (select result->>'contentHash' from saved_portal_reminder)
  ),
  'de portaalherinnering kan met verplichte route veilig worden gepubliceerd'
);
reset role;
insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
) values ('portal_access_reminder', 1)
on conflict (template_key) do update
set enabled = true,
    producer_version = excluded.producer_version;
update private.parent_accounts account
set last_login_at = grant_row.granted_at - interval '1 day'
from private.parent_portal_grants grant_row
where account.id = 'c7460000-0000-4000-8000-000000000003'
  and grant_row.id = 'c7470000-0000-4000-8000-000000000004';

set local role authenticated;
select ok(
  app.get_mail_v2_campaign_workspace_v1()->'allowedTemplates'
    ? 'portal_access_reminder',
  'beheerder ziet de portaalherinnering pas na capabilityregistratie'
);
select is(
  (
    select count(*)::integer
    from jsonb_array_elements(
      app.get_mail_v2_campaign_workspace_v1()->'orderTargets'
    ) target
    where target->>'orderId' =
      'c74a0000-0000-4000-8000-000000000003'
      and target->>'season' = '2027/2028'
  ),
  1,
  'de v2-workspace toont ook een open niet-globaal actief seizoen'
);
select is(
  (
    select count(*)::integer
    from jsonb_array_elements(
      app.get_mail_v2_campaign_workspace_v1()->'portalTargets'
    ) target
    where target->>'memberName' = 'Noa Portaal'
  ),
  1,
  'de v2-workspace bevat een orderloos lid-seizoen als portaaldoel'
);
create temporary table portal_preview as
select app.preview_mail_v2_campaign_v1(
  'portal_access_reminder',
  array[(
    select member_season.id
    from app.member_seasons member_season
    where member_season.member_id =
      'c7430000-0000-4000-8000-000000000004'
  )],
  'c7480000-0000-4000-8000-000000000013'
) result;
select is(
  (select result->>'eligibleTargetCount' from portal_preview),
  '1',
  'een login vóór de grant stopt een nieuwe kindgrant-herinnering niet'
);
select ok(
  (
    select not (result#>'{previewGroup,events,0,payload}' ? 'orderId')
      and not (result#>'{previewGroup,events,0,payload}' ? 'amountCents')
    from portal_preview
  ),
  'een orderloze portaalherinnering heeft geen order- of betaalpayload'
);
reset role;
update private.parent_accounts
set last_login_at = timezone('utc', now())
where id = 'c7460000-0000-4000-8000-000000000003';
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.confirm_mail_v2_campaign_v1(
      %L::uuid,
      %L,
      %L::uuid,
      null
    )$sql$,
    (select result->>'preflightId' from portal_preview),
    (select result->>'eligibilityRevision' from portal_preview),
    'c7480000-0000-4000-8000-000000000014'
  ),
  '40001',
  'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED',
  'een login na de grant stopt de portaalherinnering bij confirm'
);
reset role;

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  refunded_at
) values (
  'c7490000-0000-4000-8000-000000000002',
  'c7440000-0000-4000-8000-000000000002',
  'mollie',
  'refunded',
  12500,
  'campaign-refunded-0002',
  timezone('utc', now())
);
select is(
  private.mail_v2_payment_state(
    'c7440000-0000-4000-8000-000000000002'
  ),
  'review',
  'een uitsluitend terugbetaalde order blijft uit betaalcampagnes'
);
insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  'c7490000-0000-4000-8000-000000000003',
  'c7440000-0000-4000-8000-000000000002',
  'cash',
  'paid',
  12500,
  'campaign-repaid-0003',
  timezone('utc', now())
);
select is(
  private.mail_v2_payment_state(
    'c7440000-0000-4000-8000-000000000002'
  ),
  'paid',
  'een latere geldige betaling heeft voorrang op een historische refund'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_campaign_candidates(
      'out_of_stock',
      (select active_season_id from app.app_settings where id = true),
      array['c7440000-0000-4000-8000-000000000002'::uuid]
    ) candidate
    where candidate.outcome = 'eligible'
      and candidate.order_line_id =
        'c7450000-0000-4000-8000-000000000005'
  ),
  1,
  'een betaalde maatgeldige nulvoorraadregel is selecteerbaar'
);
select is(
  jsonb_array_length(
    private.mail_v2_member_payload(
      'out_of_stock',
      'c7460000-0000-4000-8000-000000000001',
      (
        select member_season_id
        from app.member_orders
        where id = 'c7440000-0000-4000-8000-000000000002'
      ),
      'c7480000-0000-4000-8000-000000000020',
      'c7450000-0000-4000-8000-000000000005'
    )->'lines'
  ),
  1,
  'de niet-leverbaarmail bindt aan exact de geselecteerde maatgeldige regel'
);
alter table app.member_article_sizes disable trigger user;
update app.member_article_sizes size_profile
set selection_status = 'change_requested',
    requested_raw_value = 'Andere maat nodig',
    requested_member_note = 'Geldige synthetische regressietoestand',
    requested_at = timezone('utc', now()),
    requested_by_parent_account_id =
      'c7460000-0000-4000-8000-000000000001',
    updated_at = timezone('utc', now())
where size_profile.member_id = 'c7430000-0000-4000-8000-000000000002'
  and size_profile.article_id =
    'c7410000-0000-4000-8000-000000000003';
alter table app.member_article_sizes enable trigger user;
select is(
  (
    select count(*)::integer
    from private.mail_v2_campaign_candidates(
      'out_of_stock',
      (select active_season_id from app.app_settings where id = true),
      array['c7440000-0000-4000-8000-000000000002'::uuid]
    ) candidate
    where candidate.outcome = 'eligible'
  ),
  0,
  'een wijzigingsverzoek blokkeert ook een nulvoorraadmail'
);
insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  'c7490000-0000-4000-8000-000000000004',
  'c7440000-0000-4000-8000-000000000003',
  'mollie',
  'duplicate_paid',
  10100,
  'campaign-duplicate-0004',
  timezone('utc', now())
);
select is(
  private.mail_v2_payment_state(
    'c7440000-0000-4000-8000-000000000003'
  ),
  'review',
  'een dubbele betaling blijft altijd een blokkend betaalconflict'
);

select ok(
  not has_table_privilege(
    'service_role',
    'private.mail_v2_campaign_preflights',
    'SELECT,INSERT,UPDATE,DELETE'
  )
  and not has_table_privilege(
    'authenticated',
    'private.mail_v2_campaign_runs',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'campagnefeiten zijn uitsluitend via gecontroleerde RPCs bereikbaar'
);
select is(
  (
    select count(*)::integer
    from app.audit_logs audit
    where audit.action = 'mail_v2.campaign.confirmed'
      and audit.metadata::text
        ~* 'campagne-gezin|sophie|milan|date.?of.?birth|relation'
  ),
  0,
  'campagneaudit bevat geen ontvanger, naam, DOB of relatienummer'
);

update private.mail_v2_campaign_preflights
set created_at = timezone('utc', now()) - interval '26 hours 5 minutes',
    expires_at = timezone('utc', now()) - interval '26 hours'
where id = (select (result->>'preflightId')::uuid from family_preview);
set local role service_role;
create temporary table purged_preflights as
select app.purge_mail_v2_campaign_preflights_v1(
  timezone('utc', now()),
  24,
  500
) result;
reset role;
select is(
  (select result from purged_preflights),
  1,
  'de retentiejob verwijdert de verlopen preflight en previewsnapshot'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_campaign_preflights preflight
    where preflight.id =
      (select (result->>'preflightId')::uuid from family_preview)
  ),
  0,
  'de kortlevende preflight is na retentie verdwenen'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_campaign_runs run
    where run.id = (select (result->>'runId')::uuid from family_confirm)
  ),
  1,
  'de immutable campagnerun blijft na preflightretentie bestaan'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.source_id =
      (select (result->>'runId')::uuid from family_confirm)
  ),
  2,
  'domeinevents blijven na preflightretentie volledig intact'
);
select is(
  (
    select count(*)::integer
    from app.audit_logs audit
    where audit.action = 'mail_v2.campaign.confirmed'
      and audit.entity_id =
        (select (result->>'runId')::uuid from family_confirm)
  ),
  1,
  'de auditfact blijft na preflightretentie volledig intact'
);

select * from finish();
rollback;

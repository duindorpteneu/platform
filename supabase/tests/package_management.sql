begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('fb000000-0000-4000-8000-000000000001', 'Pakketbeheerder', 'beheerder'),
  ('fb000000-0000-4000-8000-000000000002', 'Pakketcommissie', 'kledingcommissie');

insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values (
  'fb100000-0000-4000-8000-000000000001',
  '2042/2043 pakketten',
  '2042-07-01',
  '2043-06-30',
  10000,
  'open',
  timezone('utc', now())
);
update app.app_settings
set active_season_id = 'fb100000-0000-4000-8000-000000000001'
where id = true;

insert into app.articles(id, name, code, icon_type, sort_order) values
  ('fb200000-0000-4000-8000-000000000001', 'Pakketshirt', 'PK-SHIRT', 'shirt', 10),
  ('fb200000-0000-4000-8000-000000000002', 'Pakketbroek', 'PK-BROEK', 'circle-dot', 20),
  ('fb200000-0000-4000-8000-000000000003', 'Product zonder maat', 'PK-LEEG', 'package', 30);
insert into app.article_variants(id, article_id, size, sort_order) values
  ('fb300000-0000-4000-8000-000000000001', 'fb200000-0000-4000-8000-000000000001', '152', 10),
  ('fb300000-0000-4000-8000-000000000002', 'fb200000-0000-4000-8000-000000000002', '152', 10);
insert into app.article_seasons(article_id, season_id) values
  ('fb200000-0000-4000-8000-000000000001', 'fb100000-0000-4000-8000-000000000001'),
  ('fb200000-0000-4000-8000-000000000002', 'fb100000-0000-4000-8000-000000000001'),
  ('fb200000-0000-4000-8000-000000000003', 'fb100000-0000-4000-8000-000000000001');

select set_config(
  'request.jwt.claims',
  '{"sub":"fb000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_package_workspace()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan pakketprijzen niet beheren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"fb000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_package_workspace()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan pakketprijs/default niet beheren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"fb000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

select is(
  jsonb_array_length(app.get_package_workspace()->'templates'),
  0,
  'workspace start zonder gegokte pakketfixtures'
);
select is(
  jsonb_array_length(app.get_package_workspace()->'articles'),
  3,
  'workspace toont de door beheer aangemaakte producten'
);

create temporary table first_draft as
select app.upsert_package_draft(
  null,
  null,
  'fb100000-0000-4000-8000-000000000001',
  'speler',
  'Speler',
  'Eerste zelf beheerde pakket',
  12500,
  '[
    {"articleId":"fb200000-0000-4000-8000-000000000001","quantity":1,"sortOrder":10},
    {"articleId":"fb200000-0000-4000-8000-000000000002","quantity":1,"sortOrder":20}
  ]'::jsonb,
  null,
  'fbf00000-0000-4000-8000-000000000001'
) result;

select is(
  (select result->>'created' from first_draft),
  'true',
  'beheerder maakt een draft zonder maten in de template'
);
select is(
  (select (result->>'itemCount')::integer from first_draft),
  2,
  'draft bevat beide productcomponenten'
);
select is(
  (select price_cents from app.package_template_revisions
    where id = (select (result->>'revisionId')::uuid from first_draft)),
  12500,
  'pakketprijs staat exact in eurocenten'
);
select is(
  (select count(*) from app.package_template_items
    where revision_id = (select (result->>'revisionId')::uuid from first_draft)),
  2::bigint,
  'templateitems bevatten geen gekozen maat maar wel aantallen'
);
select matches(
  (select result->>'contentHash' from first_draft),
  '^[0-9a-f]{64}$',
  'iedere revisie krijgt een veilige optimistic-concurrencyhash'
);
select throws_ok(
  format(
    $$select app.upsert_package_draft(
      %L::uuid, %L::uuid, 'fb100000-0000-4000-8000-000000000001',
      'speler', 'Verouderde wijziging', '', 12500,
      '[{"articleId":"fb200000-0000-4000-8000-000000000001","quantity":1,"sortOrder":10}]'::jsonb,
      %L, null
    )$$,
    (select result->>'templateId' from first_draft),
    (select result->>'revisionId' from first_draft),
    repeat('0', 64)
  ),
  '40001',
  'PACKAGE_DRAFT_STALE',
  'een verouderde beheerwrite wordt vóór wijziging geblokkeerd'
);

create temporary table first_update as
select app.upsert_package_draft(
  (select (result->>'templateId')::uuid from first_draft),
  (select (result->>'revisionId')::uuid from first_draft),
  'fb100000-0000-4000-8000-000000000001',
  'speler',
  'Speler tenue',
  'Bijgewerkte draft',
  12900,
  '[{"articleId":"fb200000-0000-4000-8000-000000000001","quantity":2,"sortOrder":10}]'::jsonb,
  (select result->>'contentHash' from first_draft),
  'fbf00000-0000-4000-8000-000000000002'
) result;
select is(
  (select result->>'created' from first_update),
  'false',
  'draft is vóór publicatie gecontroleerd wijzigbaar'
);
select is(
  (select price_cents from app.package_template_revisions
    where id = (select (result->>'revisionId')::uuid from first_draft)),
  12900,
  'draftprijs is bijgewerkt'
);

select throws_ok(
  $$select app.upsert_package_draft(
    null, null, 'fb100000-0000-4000-8000-000000000001',
    'ongeldig', 'Ongeldig', '', 100,
    '[{"articleId":"fb200000-0000-4000-8000-000000000003","quantity":1,"sortOrder":10}]'::jsonb,
    null,
    null
  )$$,
  '23514',
  'PACKAGE_PRODUCT_NOT_AVAILABLE',
  'product zonder actieve maattabel kan niet in een pakket'
);

create temporary table first_publish as
select app.publish_package_revision_v2(
  (select (result->>'revisionId')::uuid from first_draft),
  false,
  (select result->>'contentHash' from first_update),
  'fbf00000-0000-4000-8000-000000000003'
) result;
select is(
  (select result->>'default' from first_publish),
  'true',
  'eerste gepubliceerde pakket wordt veilig de seizoensdefault'
);
select is(
  (select count(*) from app.package_template_revisions
    where season_id = 'fb100000-0000-4000-8000-000000000001'
      and active and is_default),
  1::bigint,
  'exact één actieve standaardrevisie bestaat'
);

select throws_ok(
  format(
    $$select app.upsert_package_draft(
      %L::uuid, %L::uuid, 'fb100000-0000-4000-8000-000000000001',
      'speler', 'Stille wijziging', '', 1,
      '[{"articleId":"fb200000-0000-4000-8000-000000000001","quantity":1,"sortOrder":10}]'::jsonb,
      %L,
      null
    )$$,
    (select result->>'templateId' from first_draft),
    (select result->>'revisionId' from first_draft),
    (select result->>'contentHash' from first_publish)
  ),
  '23514',
  'PACKAGE_DRAFT_NOT_EDITABLE',
  'gepubliceerde revisie kan niet stil worden herschreven'
);

create temporary table second_revision as
select app.clone_package_revision(
  (select (result->>'templateId')::uuid from first_draft),
  (select (result->>'revisionId')::uuid from first_publish),
  (select result->>'contentHash' from first_publish),
  'fbf00000-0000-4000-8000-000000000004'
) result;
select is(
  (select (result->>'revisionNumber')::integer from second_revision),
  2,
  'nieuwe wijziging krijgt een volgende revisie'
);
select is(
  (select count(*) from app.package_template_items
    where revision_id = (select (result->>'revisionId')::uuid from second_revision)),
  1::bigint,
  'nieuwe revisie kopieert de laatste gepubliceerde inhoud'
);

create temporary table second_update as
select app.upsert_package_draft(
  (select (result->>'templateId')::uuid from second_revision),
  (select (result->>'revisionId')::uuid from second_revision),
  'fb100000-0000-4000-8000-000000000001',
  'speler',
  'Speler tenue v2',
  'Tweede revisie',
  13000,
  '[
    {"articleId":"fb200000-0000-4000-8000-000000000001","quantity":1,"sortOrder":10},
    {"articleId":"fb200000-0000-4000-8000-000000000002","quantity":1,"sortOrder":20}
  ]'::jsonb,
  (select result->>'contentHash' from second_revision),
  null
) result;
select is(
  (select result->>'created' from second_update),
  'false',
  'nieuwe draftrevisie kan worden aangepast'
);
create temporary table second_publish as
select app.publish_package_revision_v2(
  (select (result->>'revisionId')::uuid from second_revision),
  false,
  (select result->>'contentHash' from second_update),
  null
) result;
select is(
  (select result->>'active' from second_publish),
  'true',
  'tweede revisie publiceert transactioneel'
);
select is(
  (select count(*) from app.package_template_revisions
    where template_id = (select (result->>'templateId')::uuid from first_draft)
      and active),
  1::bigint,
  'slechts één revisie per template is actief'
);
select is(
  (select revision_number from app.package_template_revisions
    where template_id = (select (result->>'templateId')::uuid from first_draft)
      and active and is_default),
  2,
  'default volgt de nieuwe revisie van dezelfde template'
);

create temporary table optional_draft as
select app.upsert_package_draft(
  null,
  null,
  'fb100000-0000-4000-8000-000000000001',
  'training',
  'Training',
  'Niet-standaard pakketkeuze',
  9900,
  '[{"articleId":"fb200000-0000-4000-8000-000000000001","quantity":1,"sortOrder":10}]'::jsonb,
  null,
  null
) result;
create temporary table optional_publish as
select app.publish_package_revision_v2(
  (select (result->>'revisionId')::uuid from optional_draft),
  false,
  (select result->>'contentHash' from optional_draft),
  null
) result;
select is(
  (select result->>'default' from optional_publish),
  'false',
  'een tweede template kan bewust niet-standaard worden gepubliceerd'
);
select is(
  (select name from app.package_template_revisions
    where season_id = 'fb100000-0000-4000-8000-000000000001'
      and active and is_default),
  'Speler tenue v2',
  'niet-standaard publicatie behoudt de bestaande seizoensdefault'
);
select is(
  (select count(*) from app.package_template_revisions
    where season_id = 'fb100000-0000-4000-8000-000000000001'
      and active and is_default),
  1::bigint,
  'niet-standaard publicatie bewaart exact één actieve default'
);

create temporary table keeper_draft as
select app.upsert_package_draft(
  null,
  null,
  'fb100000-0000-4000-8000-000000000001',
  'keeper',
  'Keeper',
  'Tweede pakketkeuze',
  14500,
  '[{"articleId":"fb200000-0000-4000-8000-000000000002","quantity":1,"sortOrder":10}]'::jsonb,
  null,
  null
) result;
create temporary table keeper_publish as
select app.publish_package_revision_v2(
  (select (result->>'revisionId')::uuid from keeper_draft),
  true,
  (select result->>'contentHash' from keeper_draft),
  null
) result;
select is(
  (select result->>'default' from keeper_publish),
  'true',
  'beheerder kan een andere template expliciet standaard maken'
);
select is(
  (select name from app.package_template_revisions
    where season_id = 'fb100000-0000-4000-8000-000000000001'
      and active and is_default),
  'Keeper',
  'gekozen pakket is de enige seizoensdefault'
);
select is(
  (select count(*) from app.package_template_revisions
    where season_id = 'fb100000-0000-4000-8000-000000000001'
      and active and is_default),
  1::bigint,
  'defaultwissel behoudt de exact-één-invariant'
);
select throws_ok(
  $$select app.upsert_catalog_article(
    'fb200000-0000-4000-8000-000000000002',
    'Pakketbroek',
    'PK-BROEK',
    'circle-dot',
    false,
    20,
    array['fb100000-0000-4000-8000-000000000001']::uuid[]
  )$$,
  '23514',
  'PACKAGE_PRODUCT_STILL_IN_USE',
  'een product in een actieve pakketrevisie kan niet worden gedeactiveerd'
);
select throws_ok(
  $$select app.upsert_catalog_variant(
    'fb200000-0000-4000-8000-000000000002',
    'fb300000-0000-4000-8000-000000000002',
    '152',
    null,
    false,
    10
  )$$,
  '23514',
  'PACKAGE_LAST_ACTIVE_VARIANT_REQUIRED',
  'de laatste actieve maat van een aangeboden pakketproduct blijft beschermd'
);
select ok(
  exists(
    select 1
    from pg_constraint
    where conname = 'package_template_items_article_season_fkey'
      and convalidated
  ),
  'product en pakketrevisie zijn met een gevalideerde seizoen-FK verbonden'
);
select is(
  app.audit_category('package.revision.published'),
  'orders',
  'pakketaudit valt expliciet onder bestellingen'
);

select lives_ok(
  format(
    $$select app.archive_package_revision(%L::uuid, 'Niet langer aangeboden', %L, null)$$,
    (select id::text from app.package_template_revisions
      where template_id = (select (result->>'templateId')::uuid from first_draft)
        and active),
    (
      select revision->>'contentHash'
      from jsonb_array_elements(app.get_package_workspace()->'templates') template
      cross join lateral jsonb_array_elements(template->'revisions') revision
      where template->>'id' = (select result->>'templateId' from first_draft)
        and (revision->>'active')::boolean
    )
  ),
  'niet-standaard pakket kan geaudit worden gearchiveerd'
);
select throws_ok(
  format(
    $$select app.archive_package_revision(%L::uuid, 'Onveilig zonder vervanger', %L, null)$$,
    (select result->>'revisionId' from keeper_draft),
    (select result->>'contentHash' from keeper_publish)
  ),
  '23514',
  'PACKAGE_DEFAULT_REPLACEMENT_REQUIRED',
  'standaardpakket kan niet zonder vervanger worden gearchiveerd'
);

select ok(
  (select count(*) from app.audit_logs
    where action like 'package.%' and actor_user_id = 'fb000000-0000-4000-8000-000000000001') >= 7,
  'drafts, revisies, publicatie en archivering zijn geaudit'
);
select is(
  jsonb_array_length(app.get_package_workspace()->'templates'),
  3,
  'workspace toont alle door beheer aangemaakte templates'
);

reset role;
select ok(
  not has_table_privilege('authenticated', 'app.package_template_revisions', 'UPDATE'),
  'authenticated kan pakketrevisies niet buiten de RPC wijzigen'
);

select * from finish();
rollback;

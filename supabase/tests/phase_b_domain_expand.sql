begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select has_table('app', 'member_seasons', 'expliciete lid-seizoentabel bestaat');
select has_table('private', 'member_sensitive_identity', 'DOB staat in een afgeschermde tabel');
select has_table('app', 'member_external_identities', 'externe lididentiteiten bestaan');
select has_table('private', 'parent_portal_grants', 'seizoensgebonden oudergrants bestaan');
select has_table('app', 'package_templates', 'stabiele pakkettemplates bestaan');
select has_table('app', 'package_template_revisions', 'pakketrevisies bestaan');
select has_table('app', 'package_template_items', 'pakketcomponenten bestaan');
select has_table('app', 'order_package_snapshots', 'commerciële ordersnapshots bestaan');
select has_table('app', 'order_package_snapshot_items', 'inhoudsnapshots bestaan');
select has_column('app', 'members', 'gender', 'geslacht is een expliciet lidattribuut');
select hasnt_column('app', 'members', 'date_of_birth', 'DOB lekt niet naar de brede ledentabel');
select has_column('app', 'member_orders', 'member_season_id', 'order verwijst naar lid-seizoen');
select has_column('app', 'member_orders', 'active_package_snapshot_id', 'order verwijst naar actieve immutable snapshot');
select has_column('app', 'order_lines', 'product_name_snapshot', 'bestelregel bewaart productnaamsnapshot');
select has_column('app', 'fulfilment_lines', 'size_snapshot', 'uitgifteregel bewaart maatsnapshot');

select is(
  (select count(*) from app.release_feature_flags),
  8::bigint,
  'alle expandfeatureflags zijn expliciet geregistreerd'
);
select is(
  (select count(*) from app.release_feature_flags where enabled),
  0::bigint,
  'alle expandfeatureflags staan standaard uit'
);
select ok(
  not has_table_privilege('authenticated', 'private.member_sensitive_identity', 'SELECT'),
  'authenticated kan de DOB-tabel niet rechtstreeks lezen'
);
select ok(
  not has_table_privilege('service_role', 'private.member_sensitive_identity', 'SELECT'),
  'service role krijgt geen brede DOB-tabelread'
);
select ok(
  not has_table_privilege('authenticated', 'app.package_template_revisions', 'INSERT'),
  'pakketmutaties lopen niet rechtstreeks via de tabel'
);
select ok(
  not has_table_privilege('authenticated', 'app.order_package_snapshots', 'UPDATE'),
  'ordersnapshots zijn niet rechtstreeks wijzigbaar'
);

insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values (
  'fa100000-0000-4000-8000-000000000001',
  '2040/2041 fase B',
  '2040-07-01',
  '2041-06-30',
  9999,
  'open',
  timezone('utc', now())
), (
  'fa100000-0000-4000-8000-000000000002',
  '2039/2040 fase B historie',
  '2039-07-01',
  '2040-06-30',
  8999,
  'archived',
  timezone('utc', now()) - interval '1 year'
);

update app.app_settings
set active_season_id = 'fa100000-0000-4000-8000-000000000001'
where id = true;

insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season, gender
) values (
  'fa200000-0000-4000-8000-000000000001',
  'PHASEB-001',
  'Robin',
  'Voorbeeld',
  'gezin-phase-b@example.invalid',
  'JO13-1',
  true,
  'female'
), (
  'fa200000-0000-4000-8000-000000000002',
  'PHASEB-002',
  'Sam',
  'Voorbeeld',
  'gezin-phase-b@example.invalid',
  'JO15-1',
  true,
  'male'
), (
  'fa200000-0000-4000-8000-000000000003',
  'PHASEB-003',
  'Alex',
  'Pakket',
  'pakket-phase-b@example.invalid',
  'MO17-1',
  true,
  'unknown'
);

select is(
  (select count(*) from private.member_sensitive_identity where member_id in (
    'fa200000-0000-4000-8000-000000000001',
    'fa200000-0000-4000-8000-000000000002',
    'fa200000-0000-4000-8000-000000000003'
  )),
  3::bigint,
  'ieder nieuw lid krijgt een lege gevoelige-identiteitsrij'
);
select is(
  (select count(*) from app.member_external_identities where member_id in (
    'fa200000-0000-4000-8000-000000000001',
    'fa200000-0000-4000-8000-000000000002',
    'fa200000-0000-4000-8000-000000000003'
  ) and issuer = 'sportlink'),
  3::bigint,
  'Sportlink-relatienummers worden exacte externe identiteiten'
);
select is(
  (select participation_status::text from app.member_seasons
    where member_id = 'fa200000-0000-4000-8000-000000000001'
      and season_id = 'fa100000-0000-4000-8000-000000000001'),
  'active',
  'actueel lid-seizoen is opgelost en actief'
);
select is(
  (select team_name from app.member_seasons
    where member_id = 'fa200000-0000-4000-8000-000000000001'
      and season_id = 'fa100000-0000-4000-8000-000000000001'),
  'JO13-1',
  'actueel team wordt uitsluitend naar het actuele seizoen geprojecteerd'
);

select throws_ok(
  $$insert into app.members(
    id, relation_number, first_name, last_name, email, team
  ) values (
    'fa200000-0000-4000-8000-000000000099',
    'phaseb-001',
    'Dubbel',
    'Extern',
    'dubbel-phase-b@example.invalid',
    'TEST'
  )$$,
  '23505',
  'MEMBER_EXTERNAL_IDENTITY_CONFLICT',
  'genormaliseerde externe-ID-collision wordt blokkerend, niet gegokt'
);

update private.member_sensitive_identity
set date_of_birth = date '2012-03-04'
where member_id = 'fa200000-0000-4000-8000-000000000001';

insert into app.member_orders(
  id, member_id, season_id, amount_due_cents
) values (
  'fa300000-0000-4000-8000-000000000001',
  'fa200000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000002',
  12500
), (
  'fa300000-0000-4000-8000-000000000002',
  'fa200000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001',
  13500
);

select is(
  (select reconciliation_status::text from app.member_seasons
    where member_id = 'fa200000-0000-4000-8000-000000000001'
      and season_id = 'fa100000-0000-4000-8000-000000000002'),
  'legacy_unknown',
  'historisch lid-seizoen blijft expliciet onbekend'
);
select is(
  (select team_name from app.member_seasons
    where member_id = 'fa200000-0000-4000-8000-000000000001'
      and season_id = 'fa100000-0000-4000-8000-000000000002'),
  null,
  'actueel team wordt niet naar historie gegokt'
);
select is(
  (select package_name from app.order_package_snapshots
    where id = (select active_package_snapshot_id from app.member_orders
      where id = 'fa300000-0000-4000-8000-000000000001')),
  'Legacy tenue',
  'losse legacyorder krijgt exact de neutrale pakketnaam'
);
select is(
  (select package_price_cents from app.order_package_snapshots
    where id = (select active_package_snapshot_id from app.member_orders
      where id = 'fa300000-0000-4000-8000-000000000001')),
  12500,
  'legacyprijs komt exact van de order en niet van het seizoensdefault'
);
select is(
  (select package_revision_id from app.member_orders
    where id = 'fa300000-0000-4000-8000-000000000001'),
  null,
  'legacyorder krijgt geen gegokte pakkettemplate'
);

insert into app.articles(id, name, code, icon_type, sort_order)
values(
  'fa400000-0000-4000-8000-000000000001',
  'Fase B broek',
  'FB-BROEK',
  'circle-dot',
  501
);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values(
  'fa500000-0000-4000-8000-000000000001',
  'fa400000-0000-4000-8000-000000000001',
  '152',
  'FB-BROEK-152',
  1
), (
  'fa500000-0000-4000-8000-000000000002',
  'fa400000-0000-4000-8000-000000000001',
  '164',
  'FB-BROEK-164',
  2
);
insert into app.article_seasons(article_id, season_id) values
  ('fa400000-0000-4000-8000-000000000001', 'fa100000-0000-4000-8000-000000000001'),
  ('fa400000-0000-4000-8000-000000000001', 'fa100000-0000-4000-8000-000000000002');

insert into app.order_lines(
  id, order_id, article_variant_id, quantity
) values (
  'fa600000-0000-4000-8000-000000000001',
  'fa300000-0000-4000-8000-000000000001',
  'fa500000-0000-4000-8000-000000000001',
  1
);

select is(
  (select product_name_snapshot from app.order_lines
    where id = 'fa600000-0000-4000-8000-000000000001'),
  'Fase B broek',
  'bestelregel legt de productnaam vast'
);
select is(
  (select product_code_snapshot from app.order_lines
    where id = 'fa600000-0000-4000-8000-000000000001'),
  'FB-BROEK',
  'bestelregel legt de productcode vast'
);
select is(
  (select count(*) from app.order_package_snapshot_items item
    join app.member_orders orders on orders.active_package_snapshot_id = item.snapshot_id
    where orders.id = 'fa300000-0000-4000-8000-000000000001'),
  1::bigint,
  'actieve legacysnapshot bevat de actuele bestelregel'
);

update app.articles
set name = 'Hernoemde broek'
where id = 'fa400000-0000-4000-8000-000000000001';
select is(
  (select product_name_snapshot from app.order_lines
    where id = 'fa600000-0000-4000-8000-000000000001'),
  'Fase B broek',
  'catalogusrename herschrijft historische productnaam niet'
);

update app.member_orders
set amount_due_cents = 12600
where id = 'fa300000-0000-4000-8000-000000000001';
select is(
  (select package_price_cents from app.order_package_snapshots
    where id = (select active_package_snapshot_id from app.member_orders
      where id = 'fa300000-0000-4000-8000-000000000001')),
  12600,
  'onbetaalde legacyprijswijziging maakt een nieuwe correcte snapshot'
);
select ok(
  exists(
    select 1 from app.order_package_snapshots
    where order_id = 'fa300000-0000-4000-8000-000000000001'
      and package_price_cents = 12500
  ),
  'voorgaande commerciële snapshot blijft historisch intact'
);

insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value
) values (
  'fa200000-0000-4000-8000-000000000002',
  'fa100000-0000-4000-8000-000000000001',
  'fa400000-0000-4000-8000-000000000001',
  null,
  'conflict',
  'import',
  'XXXL'
);
select is(
  (select raw_value from app.member_article_sizes
    where member_id = 'fa200000-0000-4000-8000-000000000002'
      and season_id = 'fa100000-0000-4000-8000-000000000001'
      and article_id = 'fa400000-0000-4000-8000-000000000001'),
  'XXXL',
  'Anders-conflict bewaart de ruwe waarde zonder fictieve variant'
);
select throws_ok(
  $$update app.member_article_sizes
    set selection_source = 'parent', member_note = null
    where member_id = 'fa200000-0000-4000-8000-000000000002'
      and season_id = 'fa100000-0000-4000-8000-000000000001'
      and article_id = 'fa400000-0000-4000-8000-000000000001'$$,
  '23514',
  'new row for relation "member_article_sizes" violates check constraint "member_article_sizes_selection_check"',
  'zelfgekozen Anders vereist een toelichting'
);

create table pg_temp.phase_b_ids(
  template_id uuid,
  revision_id uuid,
  item_id uuid
);
insert into app.package_templates(id, season_id, template_key)
values(
  'fa700000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001',
  'testpakket'
);
insert into app.package_template_revisions(
  id, template_id, season_id, revision_number, name, description, price_cents
) values (
  'fa710000-0000-4000-8000-000000000001',
  'fa700000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001',
  1,
  'Testpakket',
  'Pakket zonder voorgeselecteerde maten',
  14900
);
insert into app.package_template_items(
  id, revision_id, season_id, article_id, quantity, product_name_snapshot, product_code_snapshot
) values (
  'fa720000-0000-4000-8000-000000000001',
  'fa710000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001',
  'fa400000-0000-4000-8000-000000000001',
  1,
  'Hernoemde broek',
  'FB-BROEK'
);
update app.package_template_revisions
set status = 'published',
    active = true,
    is_default = true,
    published_at = timezone('utc', now())
where id = 'fa710000-0000-4000-8000-000000000001';

select throws_ok(
  $$update app.package_template_revisions
    set name = 'Stille naamswijziging'
    where id = 'fa710000-0000-4000-8000-000000000001'$$,
  '23514',
  'PUBLISHED_PACKAGE_REVISION_IMMUTABLE',
  'gepubliceerde commerciële inhoud is immutable'
);
select throws_ok(
  $$update app.package_template_items
    set quantity = 2
    where id = 'fa720000-0000-4000-8000-000000000001'$$,
  '23514',
  'PUBLISHED_PACKAGE_ITEMS_IMMUTABLE',
  'gepubliceerde pakketcomponenten zijn immutable'
);

insert into app.member_orders(
  id, member_id, season_id, amount_due_cents, package_revision_id
) values (
  'fa300000-0000-4000-8000-000000000003',
  'fa200000-0000-4000-8000-000000000003',
  'fa100000-0000-4000-8000-000000000001',
  14900,
  'fa710000-0000-4000-8000-000000000001'
);
select is(
  (select package_name from app.order_package_snapshots
    where id = (select active_package_snapshot_id from app.member_orders
      where id = 'fa300000-0000-4000-8000-000000000003')),
  'Testpakket',
  'templateorder bewaart de pakketnaam'
);
select is(
  (select count(*) from app.order_package_snapshot_items item
    join app.member_orders orders on orders.active_package_snapshot_id = item.snapshot_id
    where orders.id = 'fa300000-0000-4000-8000-000000000003'),
  1::bigint,
  'templateorder kopieert de immutable inhoud'
);
select throws_ok(
  $$update app.member_orders
    set amount_due_cents = 14901
    where id = 'fa300000-0000-4000-8000-000000000003'$$,
  '23514',
  'PACKAGE_PRICE_MISMATCH',
  'templateprijs kan niet van de gepubliceerde revisie afwijken'
);

insert into private.parent_accounts(id, email_normalized)
values(
  'fa800000-0000-4000-8000-000000000001',
  'gezin-phase-b@example.invalid'
);
insert into private.parent_sessions(
  parent_account_id, token_hash, expires_at
) values (
  'fa800000-0000-4000-8000-000000000001',
  repeat('f', 64),
  timezone('utc', now()) + interval '1 hour'
);
insert into private.parent_member_links(
  id, parent_account_id, member_id
) values (
  'fa810000-0000-4000-8000-000000000001',
  'fa800000-0000-4000-8000-000000000001',
  'fa200000-0000-4000-8000-000000000001'
);

select is(
  (select status::text from private.parent_portal_grants
    where legacy_link_id = 'fa810000-0000-4000-8000-000000000001'),
  'review_required',
  'legacy ouderkoppeling wordt nooit stil een actieve grant'
);
select is(
  (select count(*) from private.parent_portal_grants grant_row
    join app.member_seasons member_season on member_season.id = grant_row.member_season_id
    where member_season.member_id = 'fa200000-0000-4000-8000-000000000002'),
  0::bigint,
  'gedeeld e-mailadres verleent het tweede kind geen toegang'
);
select is(
  (select count(*) from public.get_parent_members(repeat('f', 64))),
  1::bigint,
  'legacycompatibiliteit retourneert exact het actieve lid-seizoen'
);
select is(
  (select date_of_birth from public.get_parent_members(repeat('f', 64))),
  date '2012-03-04',
  'geautoriseerde ouder ziet DOB van het gekoppelde eigen lid'
);
select is(
  (select gender from public.get_parent_members(repeat('f', 64))),
  'female',
  'geautoriseerde ouder ziet geregistreerd geslacht'
);
select throws_ok(
  $$select public.link_parent_member(
    repeat('f', 64),
    'fa200000-0000-4000-8000-000000000002'
  )$$,
  '42501',
  'PORTAL_ACCESS_ADMIN_REQUIRED',
  'ouder kan gedeeld e-mailadres niet gebruiken om zelf toegang uit te breiden'
);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('fa900000-0000-4000-8000-000000000001', 'Fase B beheerder', 'beheerder'),
  ('fa900000-0000-4000-8000-000000000002', 'Fase B commissie', 'kledingcommissie'),
  ('fa900000-0000-4000-8000-000000000003', 'Fase B uitgifte', 'uitgifte');

select set_config(
  'request.jwt.claims',
  '{"sub":"fa900000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_member_detail_v3('fa200000-0000-4000-8000-000000000001')->>'dateOfBirth',
  '2012-03-04',
  'beheerder met AAL2 ziet DOB'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"fa900000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_member_detail_v3('fa200000-0000-4000-8000-000000000001')->>'dateOfBirth',
  null,
  'kledingcommissie ontvangt geen DOB'
);
select is(
  app.get_member_detail_v3('fa200000-0000-4000-8000-000000000001')->>'gender',
  'female',
  'kledingcommissie kan het operationele geslachtsattribuut lezen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"fa900000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_member_detail_v3('fa200000-0000-4000-8000-000000000001')$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan de brede leden-/DOB-detail-RPC niet gebruiken'
);
reset role;

select is(
  (select metrics->>'orders' from private.migration_reconciliations
    where migration_key = '20260802180000_phase_b_domain_expand'),
  '0',
  'clean-installreconciliatie is vóór seed zonder bedrijfsorders geslaagd'
);

select * from finish();
rollback;

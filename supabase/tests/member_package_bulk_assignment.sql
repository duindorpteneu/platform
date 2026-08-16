begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role, active) values
  ('ac000000-0000-4000-8000-000000000001', 'Bulkbeheerder', 'beheerder', true),
  ('ac000000-0000-4000-8000-000000000002', 'Bulkcommissie', 'kledingcommissie', true);
insert into app.seasons(id, name, starts_on, ends_on, default_amount_cents, status, opened_at)
values('ac100000-0000-4000-8000-000000000001', '2048/2049 bulkpakket', '2048-07-01', '2049-06-30', 12000, 'open', timezone('utc', now()));
update app.app_settings set active_season_id = 'ac100000-0000-4000-8000-000000000001' where id = true;
update app.release_feature_flags set enabled = true where key in ('member_seasons_v2', 'package_orders_v2');

insert into app.articles(id, name, code, icon_type, sort_order) values
  ('ac200000-0000-4000-8000-000000000001', 'Bulkshirt', 'BULK-SHIRT', 'shirt', 10),
  ('ac200000-0000-4000-8000-000000000002', 'Bulkbroek', 'BULK-BROEK', 'circle-dot', 20);
insert into app.article_variants(id, article_id, size, sku, sort_order) values
  ('ac300000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000001', '152', 'BS-152', 10),
  ('ac300000-0000-4000-8000-000000000002', 'ac200000-0000-4000-8000-000000000002', '152', 'BB-152', 10);
insert into app.article_seasons(article_id, season_id) values
  ('ac200000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001'),
  ('ac200000-0000-4000-8000-000000000002', 'ac100000-0000-4000-8000-000000000001');

insert into app.package_templates(id, season_id, template_key, created_by)
values('ac400000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'speler-bulk', 'ac000000-0000-4000-8000-000000000001');
insert into app.package_template_revisions(id, template_id, season_id, revision_number, name, description, price_cents, status, active, is_default, created_by, published_by, published_at)
values('ac410000-0000-4000-8000-000000000001', 'ac400000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 1, 'Speler bulk', 'Bulkpakket', 12000, 'draft', false, false, 'ac000000-0000-4000-8000-000000000001', null, null);
insert into app.package_template_items(id, revision_id, season_id, article_id, quantity, product_name_snapshot, product_code_snapshot, sort_order) values
  ('ac420000-0000-4000-8000-000000000001', 'ac410000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000001', 1, 'Bulkshirt', 'BULK-SHIRT', 10),
  ('ac420000-0000-4000-8000-000000000002', 'ac410000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000002', 2, 'Bulkbroek', 'BULK-BROEK', 20);
update app.package_template_revisions
set status = 'published', active = true, is_default = true,
    published_by = 'ac000000-0000-4000-8000-000000000001',
    published_at = timezone('utc', now())
where id = 'ac410000-0000-4000-8000-000000000001';

insert into app.members(id, relation_number, first_name, last_name, team, active_for_season) values
  ('ac500000-0000-4000-8000-000000000001', 'BULK-1', 'Ada', 'Actief', 'JO15-1', true),
  ('ac500000-0000-4000-8000-000000000002', 'BULK-2', 'Bo', 'Onbevestigd', 'JO15-1', true),
  ('ac500000-0000-4000-8000-000000000003', 'BULK-3', 'Cas', 'Leeg', 'JO15-1', true),
  ('ac500000-0000-4000-8000-000000000004', 'BULK-4', 'Do', 'Inactief', 'JO15-1', false);

insert into app.member_article_sizes(member_id, season_id, article_id, article_variant_id, selection_status, selection_source, confirmed_at) values
  ('ac500000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000001', 'ac300000-0000-4000-8000-000000000001', 'confirmed', 'parent', timezone('utc', now())),
  ('ac500000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000002', 'ac300000-0000-4000-8000-000000000002', 'confirmed', 'parent', timezone('utc', now())),
  ('ac500000-0000-4000-8000-000000000002', 'ac100000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000001', 'ac300000-0000-4000-8000-000000000001', 'imported_unconfirmed', 'import', null);

select set_config('request.jwt.claims', '{"sub":"ac000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select app.preview_member_package_bulk_v1('assign', 'all_active', array[]::uuid[], 'ac410000-0000-4000-8000-000000000001')$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan commerciële pakketten niet in bulk beheren'
);

select set_config('request.jwt.claims', '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
create temporary table assignment_preview as
select app.preview_member_package_bulk_v1(
  'assign', 'all_active', array[]::uuid[], 'ac410000-0000-4000-8000-000000000001'
) result;
select is((select (result->>'matchedCount')::integer from assignment_preview), 3, 'alle actieve leden worden server-side geselecteerd');
select is((select (result->>'eligibleCount')::integer from assignment_preview), 3, 'drie actieve leden zijn pakketgeschikt');
select is((select (result->>'linkedSizeCount')::integer from assignment_preview), 2, 'alleen bevestigde geldige maten tellen als koppelbaar');
select is((select (result->>'missingSizeCount')::integer from assignment_preview), 4, 'onbevestigde en ontbrekende maten blijven expliciet open');

create temporary table assignment_result as
select app.apply_member_package_bulk_v1(
  'assign', 'all_active', array[]::uuid[], 'ac410000-0000-4000-8000-000000000001',
  'ac100000-0000-4000-8000-000000000001',
  (select result->>'revision' from assignment_preview),
  'Pakket toewijzen aan alle actieve leden',
  'ac600000-0000-4000-8000-000000000001',
  'ac610000-0000-4000-8000-000000000001'
) result;
select is((select (result->>'changedCount')::integer from assignment_result), 3, 'bulktoewijzing wijzigt de volledige geschikte set atomair');
select is((select count(*) from app.member_orders where season_id = 'ac100000-0000-4000-8000-000000000001'), 3::bigint, 'exact één seizoensorder per actief lid is gemaakt');
select is((select count(*) from app.order_lines where status <> 'cancelled'), 2::bigint, 'alleen bevestigde maten materialiseren logistieke regels');
select is((select quantity from app.order_lines where article_id = 'ac200000-0000-4000-8000-000000000002'), 2, 'pakketquantity blijft aan de bevestigde broekmaat gekoppeld');
select is((select count(*) from app.order_package_snapshots), 3::bigint, 'iedere commerciële order bewaart een eigen pakketsnapshot');
select is((select count(*) from app.order_package_snapshot_items), 6::bigint, 'pakketinhoud wordt per order immutable vastgelegd');
select is((select result->>'reused' from assignment_result), 'false', 'eerste bulkverzoek is niet hergebruikt');
select is(
  app.apply_member_package_bulk_v1(
    'assign', 'all_active', array[]::uuid[], 'ac410000-0000-4000-8000-000000000001',
    'ac100000-0000-4000-8000-000000000001',
    (select result->>'revision' from assignment_preview),
    'Pakket toewijzen aan alle actieve leden',
    'ac600000-0000-4000-8000-000000000001',
    'ac610000-0000-4000-8000-000000000001'
  )->>'reused',
  'true', 'retry retourneert duurzaam hetzelfde resultaat'
);

create temporary table removal_preview as
select app.preview_member_package_bulk_v1(
  'remove', 'all_active', array[]::uuid[], null
) result;
select is((select (result->>'eligibleCount')::integer from removal_preview), 3, 'onbetaalde ongereserveerde pakketten zijn veilig intrekbaar');
create temporary table removal_result as
select app.apply_member_package_bulk_v1(
  'remove', 'all_active', array[]::uuid[], null,
  'ac100000-0000-4000-8000-000000000001',
  (select result->>'revision' from removal_preview),
  'Pakketten ingetrokken vóór betaling',
  'ac600000-0000-4000-8000-000000000002',
  'ac610000-0000-4000-8000-000000000002'
) result;
select is((select count(*) from app.member_orders where package_assignment_state = 'withdrawn'), 3::bigint, 'verwijderen is een expliciete soft withdrawal');
select is((select count(*) from app.order_lines where status <> 'cancelled'), 0::bigint, 'open logistieke regels worden ingetrokken');
select is((select count(*) from app.order_package_snapshots), 3::bigint, 'commerciële snapshots blijven na verwijderen intact');
reset role;
select throws_ok(
  $$insert into app.payments(order_id, method, status, amount_cents, idempotency_key)
    select id, 'mollie', 'open', amount_due_cents, 'withdrawn-payment'
    from app.member_orders where member_id = 'ac500000-0000-4000-8000-000000000001'$$,
  '23514', 'PACKAGE_ASSIGNMENT_WITHDRAWN',
  'een ingetrokken pakket kan geen nieuwe betaling krijgen'
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select is(
  app.get_member_list_v2(null, null, null, null, null, null, null, 50, 0)
    #>> '{members,0,order}',
  null,
  'ledenprojectie presenteert een ingetrokken pakket als geen actieve order'
);

create temporary table reassign_target as
select id from app.member_seasons
where member_id = 'ac500000-0000-4000-8000-000000000001'
  and season_id = 'ac100000-0000-4000-8000-000000000001';
create temporary table reassign_preview as
select app.preview_member_package_bulk_v1(
  'assign', 'selected', array[(select id from reassign_target)],
  'ac410000-0000-4000-8000-000000000001'
) result;
select lives_ok(
  format(
    $$select app.apply_member_package_bulk_v1(
      'assign', 'selected', array[%L::uuid],
      'ac410000-0000-4000-8000-000000000001',
      'ac100000-0000-4000-8000-000000000001', %L,
      'Pakket opnieuw veilig toewijzen',
      'ac600000-0000-4000-8000-000000000003',
      'ac610000-0000-4000-8000-000000000003'
    )$$,
    (select id from reassign_target),
    (select result->>'revision' from reassign_preview)
  ),
  'een ingetrokken pakket kan op dezelfde seizoensorder worden heractiveerd'
);
select is((select package_assignment_state from app.member_orders where member_id = 'ac500000-0000-4000-8000-000000000001'), 'active', 'hertoewijzing activeert de bestaande order');
select is((select count(*) from app.order_lines line join app.member_orders orders on orders.id = line.order_id where orders.member_id = 'ac500000-0000-4000-8000-000000000001' and line.status <> 'cancelled'), 2::bigint, 'hertoewijzing koppelt opnieuw de bevestigde maten');
select is((select count(*) from app.audit_logs where action = 'package_order.reactivated'), 1::bigint, 'hertoewijzing is afzonderlijk geaudit');

reset role;
select ok(not has_table_privilege('authenticated', 'private.member_package_bulk_requests', 'SELECT'), 'requestledger is niet rechtstreeks leesbaar');
select ok(not has_function_privilege('anon', 'app.apply_member_package_bulk_v1(text,text,uuid[],uuid,uuid,text,text,uuid,uuid)', 'EXECUTE'), 'anon kan de bulkmutatie niet uitvoeren');
select ok(not has_function_privilege('service_role', 'app.apply_member_package_bulk_v1(text,text,uuid[],uuid,uuid,text,text,uuid,uuid)', 'EXECUTE'), 'service-role kan de beheerder niet nabootsen');
select is((select count(*) from app.audit_logs where action = 'package_order.bulk_assigned'), 2::bigint, 'iedere geslaagde bulktoewijzing heeft precies één samenvattende audit');
select is((select count(*) from app.audit_logs where action = 'package_order.bulk_removed'), 1::bigint, 'bulkverwijdering heeft één samenvattende audit');

select * from finish();
rollback;

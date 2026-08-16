begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('f1600000-0000-4000-8000-000000000001', 'Profielbeheerder', 'beheerder'),
  ('f1600000-0000-4000-8000-000000000002', 'Profielcommissie', 'kledingcommissie'),
  ('f1600000-0000-4000-8000-000000000003', 'Profieluitgifte', 'uitgifte');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('f1610000-0000-4000-8000-000000000001', '2051/2052 profiel', 10000, 'open'),
  ('f1610000-0000-4000-8000-000000000002', '2050/2051 historie', 9000, 'archived');
update app.app_settings set active_season_id = 'f1610000-0000-4000-8000-000000000001' where id = true;
insert into app.members(
  id, relation_number, first_name, insertion, last_name, email, team,
  active_for_season, gender
) values (
  'f1620000-0000-4000-8000-000000000001', 'PROF-001', 'Noor', null,
  'Oud', 'oud@example.invalid', 'JO13-1', true, 'unknown'
);
update app.member_seasons
set id = 'f1630000-0000-4000-8000-000000000001'
where member_id = 'f1620000-0000-4000-8000-000000000001'
  and season_id = 'f1610000-0000-4000-8000-000000000001';
update private.member_sensitive_identity
set date_of_birth = date '2014-01-02'
where member_id = 'f1620000-0000-4000-8000-000000000001';
insert into app.member_seasons(
  id, member_id, season_id, team_name, participation_status,
  reconciliation_status
) values (
  'f1630000-0000-4000-8000-000000000002',
  'f1620000-0000-4000-8000-000000000001',
  'f1610000-0000-4000-8000-000000000002',
  'JO12-4', 'inactive', 'resolved'
) on conflict(member_id, season_id) do update
set id = excluded.id, team_name = excluded.team_name,
    participation_status = excluded.participation_status,
    reconciliation_status = excluded.reconciliation_status;

insert into app.articles(id, name, code, icon_type, sort_order) values
  ('f1640000-0000-4000-8000-000000000001', 'Profielshirt', 'PROF-SHIRT', 'shirt', 1),
  ('f1640000-0000-4000-8000-000000000002', 'Profielbroek', 'PROF-BROEK', 'circle-dot', 2);
insert into app.article_variants(id, article_id, size, sku, sort_order) values
  ('f1650000-0000-4000-8000-000000000001', 'f1640000-0000-4000-8000-000000000001', '152', 'PS-152', 1),
  ('f1650000-0000-4000-8000-000000000002', 'f1640000-0000-4000-8000-000000000001', '164', 'PS-164', 2),
  ('f1650000-0000-4000-8000-000000000003', 'f1640000-0000-4000-8000-000000000002', '152', 'PB-152', 1),
  ('f1650000-0000-4000-8000-000000000004', 'f1640000-0000-4000-8000-000000000002', '164', 'PB-164', 2);
insert into app.article_seasons(article_id, season_id) values
  ('f1640000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000001'),
  ('f1640000-0000-4000-8000-000000000002', 'f1610000-0000-4000-8000-000000000001');

select ok(
  not exists(
    select 1
    from jsonb_array_elements(
      private.member_size_profile_json_v3(
        'f1630000-0000-4000-8000-000000000001'
      )->'articles'
    ) article
    where jsonb_typeof(article->'issued') <> 'boolean'
       or jsonb_typeof(article->'editable') <> 'boolean'
  ),
  'maatprofiel geeft ook zonder bestelregel expliciete booleans terug'
);

select ok(
  not has_table_privilege('authenticated', 'app.members', 'UPDATE'),
  'leden kunnen niet rechtstreeks buiten de geaudite RPC worden gewijzigd'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.update_member_profile_v1(uuid,uuid,text,text,text,text,date,app.gender_code,text,text,text,uuid,uuid)',
    'EXECUTE'
  ),
  'anon kan de profielmutatie niet uitvoeren'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok(
  $$select app.update_member_profile_v1(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    'Noor', null, 'Nieuw', null, null, 'female', 'JO13-2',
    repeat('a', 64), 'Correctie',
    'f1660000-0000-4000-8000-000000000001', null
  )$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan persoonsgegevens niet wijzigen'
);
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok(
  $$select app.update_member_profile_v1(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    'Noor', null, 'Nieuw', null, null, 'female', 'JO13-2',
    repeat('a', 64), 'Correctie',
    'f1660000-0000-4000-8000-000000000002', null
  )$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan persoonsgegevens niet wijzigen'
);

select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000001","aal":"aal2"}', true);
create temporary table initial_detail as
select app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') result;
select lives_ok(
  $$select app.update_member_profile_v1(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '  Noor  ', ' van ', ' Dijk ', ' OUDER@EXAMPLE.INVALID ',
    date '2014-02-03', 'female', ' JO13-2 ',
    (select result->>'profileRevision' from initial_detail),
    'Correctie op verzoek',
    'f1660000-0000-4000-8000-000000000003',
    'f1660000-0000-4000-8000-000000000004'
  )$$,
  'beheerder kan profiel en actief team atomair wijzigen'
);
reset role;

select is(
  (select concat_ws('|', first_name, insertion, last_name, email, gender::text, team)
   from app.members where id = 'f1620000-0000-4000-8000-000000000001'),
  'Noor|van|Dijk|ouder@example.invalid|female|JO13-2',
  'naam, e-mail, geslacht en legacy-team zijn genormaliseerd'
);
select is(
  (select date_of_birth from private.member_sensitive_identity
   where member_id = 'f1620000-0000-4000-8000-000000000001'),
  date '2014-02-03',
  'DOB wordt uitsluitend in private identity bijgewerkt'
);
select is(
  (select team_name from app.member_seasons
   where member_id = 'f1620000-0000-4000-8000-000000000001'
     and season_id = 'f1610000-0000-4000-8000-000000000001'),
  'JO13-2',
  'alleen het actieve lid-seizoen krijgt het nieuwe team'
);
select is(
  (select team_name from app.member_seasons
   where id = 'f1630000-0000-4000-8000-000000000002'),
  'JO12-4',
  'historisch team blijft intact'
);
select ok(
  (select metadata::text !~* 'ouder@example|2014-02-03|Noor|Dijk|JO13-2'
   from app.audit_logs
   where action = 'member.profile.updated'
     and entity_id = 'f1620000-0000-4000-8000-000000000001'
   order by id desc limit 1),
  'auditmetadata bevat geen gewijzigde persoonsgegevens'
);
select is(
  (select metadata->>'portalAccessUnchanged' from app.audit_logs
   where action = 'member.profile.updated'
     and entity_id = 'f1620000-0000-4000-8000-000000000001'
   order by id desc limit 1),
  'true',
  'audit maakt expliciet dat oudertoegang apart blijft'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select is(
  app.update_member_profile_v1(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '  Noor  ', ' van ', ' Dijk ', ' OUDER@EXAMPLE.INVALID ',
    date '2014-02-03', 'female', ' JO13-2 ',
    (select result->>'profileRevision' from initial_detail),
    'Correctie op verzoek',
    'f1660000-0000-4000-8000-000000000003',
    'f1660000-0000-4000-8000-000000000004'
  )->>'reused',
  'true',
  'dezelfde profielrequest is idempotent'
);
select throws_ok(
  $$select app.update_member_profile_v1(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    'Noor', 'van', 'Anders', 'ouder@example.invalid',
    date '2014-02-03', 'female', 'JO13-2',
    (select result->>'profileRevision' from initial_detail),
    'Andere inhoud',
    'f1660000-0000-4000-8000-000000000003', null
  )$$,
  '40001', 'MEMBER_PROFILE_REQUEST_REUSED',
  'dezelfde request-ID kan niet voor andere inhoud worden hergebruikt'
);

create temporary table first_size_profile as
select app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') #> '{sizeProfile}' result;
select lives_ok(
  $$select app.set_member_article_sizes_v2(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '[{"articleId":"f1640000-0000-4000-8000-000000000001","variantId":"f1650000-0000-4000-8000-000000000001","releaseReserved":false}]',
    (select result->>'revision' from first_size_profile),
    'Eerste maatvastlegging',
    'f1660000-0000-4000-8000-000000000005', null
  )$$,
  'beheer kan een voorbereidende maat bevestigen'
);
select is(
  app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001')
    #>> '{sizeProfile,articles,0,selectionSource}',
  'staff',
  'maatbron wordt als beheer vastgelegd'
);
reset role;

insert into app.member_orders(
  id, member_id, season_id, member_season_id, amount_due_cents
) values (
  'f1670000-0000-4000-8000-000000000001',
  'f1620000-0000-4000-8000-000000000001',
  'f1610000-0000-4000-8000-000000000001',
  'f1630000-0000-4000-8000-000000000001', 10000
);
insert into app.order_lines(
  id, order_id, article_variant_id, quantity
) values (
  'f1680000-0000-4000-8000-000000000001',
  'f1670000-0000-4000-8000-000000000001',
  'f1650000-0000-4000-8000-000000000001', 1
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select lives_ok(
  $$select app.set_member_article_sizes_v2(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '[{"articleId":"f1640000-0000-4000-8000-000000000001","variantId":"f1650000-0000-4000-8000-000000000002","releaseReserved":false}]',
    (app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'),
    'Nieuwe maat na passen',
    'f1660000-0000-4000-8000-000000000006', null
  )$$,
  'kledingcommissie kan een niet-gereserveerde bestelmaat wijzigen'
);
reset role;
select is(
  (select article_variant_id::text from app.order_lines
   where id = 'f1680000-0000-4000-8000-000000000001'),
  'f1650000-0000-4000-8000-000000000002',
  'bestelregel en maatprojectie wijzigen transactioneel mee'
);

update app.order_lines set status = 'picked_up'
where id = 'f1680000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select throws_ok(
  $$select app.set_member_article_sizes_v2(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '[{"articleId":"f1640000-0000-4000-8000-000000000001","variantId":"f1650000-0000-4000-8000-000000000001","releaseReserved":false}]',
    (app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'),
    'Poging na uitgifte',
    'f1660000-0000-4000-8000-000000000007', null
  )$$,
  '23514', 'MEMBER_SIZE_ISSUED_LOCKED',
  'uitgegeven maat blijft onveranderlijk'
);

reset role;
insert into app.order_lines(
  id, order_id, article_variant_id, quantity
) values (
  'f1680000-0000-4000-8000-000000000002',
  'f1670000-0000-4000-8000-000000000001',
  'f1650000-0000-4000-8000-000000000003', 1
);
insert into app.inventory_allocations(
  id, season_id, member_id, member_season_id, order_id, order_line_id,
  article_id, article_variant_id, quantity, status, reconciliation_status,
  allocation_mode, product_name_snapshot, size_snapshot, allocated_at,
  allocated_by
) values (
  'f1690000-0000-4000-8000-000000000001',
  'f1610000-0000-4000-8000-000000000001',
  'f1620000-0000-4000-8000-000000000001',
  'f1630000-0000-4000-8000-000000000001',
  'f1670000-0000-4000-8000-000000000001',
  'f1680000-0000-4000-8000-000000000002',
  'f1640000-0000-4000-8000-000000000002',
  'f1650000-0000-4000-8000-000000000003',
  1, 'reserved', 'review_required', 'legacy_preserved',
  'Profielbroek', '152', timezone('utc', now()),
  'f1600000-0000-4000-8000-000000000001'
);
insert into app.inventory_movements(
  season_id, article_id, article_variant_id, movement_type, on_hand_delta,
  source_type, source_id, reason_code, idempotency_key, safe_context
) values (
  'f1610000-0000-4000-8000-000000000001',
  'f1640000-0000-4000-8000-000000000002',
  'f1650000-0000-4000-8000-000000000003',
  'opening_balance', 1, 'member_size_test',
  'f1690000-0000-4000-8000-000000000001',
  'inventory.opening_balance', repeat('1', 64), '{}'::jsonb
);
insert into app.inventory_movements(
  season_id, article_id, article_variant_id, movement_type, reserved_delta,
  allocation_id, source_type, source_id, reason_code, idempotency_key,
  safe_context
) values (
  'f1610000-0000-4000-8000-000000000001',
  'f1640000-0000-4000-8000-000000000002',
  'f1650000-0000-4000-8000-000000000003',
  'allocation_reserved', 1,
  'f1690000-0000-4000-8000-000000000001', 'member_size_test',
  'f1690000-0000-4000-8000-000000000001',
  'inventory.allocation_reserved', repeat('2', 64), '{}'::jsonb
);
update app.order_lines set status = 'ready_for_pickup'
where id = 'f1680000-0000-4000-8000-000000000002';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok(
  $$select app.set_member_article_sizes_v2(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '[{"articleId":"f1640000-0000-4000-8000-000000000002","variantId":"f1650000-0000-4000-8000-000000000004","releaseReserved":true}]',
    (app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'),
    'Reservering vrijgeven',
    'f1660000-0000-4000-8000-000000000008', null
  )$$,
  '23514', 'MEMBER_SIZE_RELEASE_CONFIRMATION_REQUIRED',
  'kledingcommissie kan geen reservering vrijgeven'
);
select set_config('request.jwt.claims', '{"sub":"f1600000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok(
  $$select app.set_member_article_sizes_v2(
    'f1620000-0000-4000-8000-000000000001',
    'f1630000-0000-4000-8000-000000000001',
    '[{"articleId":"f1640000-0000-4000-8000-000000000002","variantId":"f1650000-0000-4000-8000-000000000004","releaseReserved":true}]',
    (app.get_member_detail_v6('f1620000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'),
    'Reservering vrijgeven',
    'f1660000-0000-4000-8000-000000000009', null
  )$$,
  'beheerder kan exact de gewijzigde maatreservering journaled vrijgeven'
);
reset role;
select is(
  (select status::text from app.inventory_allocations
   where id = 'f1690000-0000-4000-8000-000000000001'),
  'released',
  'oude voorraadallocatie is vrijgegeven'
);
select is(
  (select coalesce(sum(reserved_delta), 0)::integer from app.inventory_movements
   where article_variant_id = 'f1650000-0000-4000-8000-000000000003'),
  0,
  'voorraadjournaal houdt geen reservering op de oude maat over'
);
select is(
  (select count(*)::integer from app.order_lines
   where order_id = 'f1670000-0000-4000-8000-000000000001'
     and article_id = 'f1640000-0000-4000-8000-000000000002'
     and article_variant_id = 'f1650000-0000-4000-8000-000000000004'
     and status = 'backorder'),
  1,
  'nieuwe maat krijgt één nieuwe wachtende bestelregel'
);

select * from finish();
rollback;

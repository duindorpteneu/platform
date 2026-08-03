begin;
select plan(26);

insert into app.seasons(id, name, default_amount_cents, status) values
  ('e1000000-0000-4000-8000-000000000001', 'Maatseizoen', 9900, 'open'),
  ('e1000000-0000-4000-8000-000000000002', 'Oud maatseizoen', 8900, 'archived');
update app.app_settings set active_season_id = 'e1000000-0000-4000-8000-000000000001' where id;
insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e0000000-0000-4000-8000-000000000001', 'Matencommissie', 'kledingcommissie'),
  ('e0000000-0000-4000-8000-000000000002', 'Matenuitgifte', 'uitgifte');
insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season) values
  ('e2000000-0000-4000-8000-000000000001', 'MAAT-001', 'Mila', 'Maat', 'mila@example.invalid', 'JO13-1', true),
  ('e2000000-0000-4000-8000-000000000002', 'MAAT-002', 'Iris', 'Inactief', 'iris@example.invalid', 'JO13-1', false);
insert into app.articles(id, name, code, icon_type, sort_order) values
  ('e3000000-0000-4000-8000-000000000001', 'Maatshirt', 'MAAT-SHIRT', 'shirt', 1),
  ('e3000000-0000-4000-8000-000000000002', 'Maatbroek', 'MAAT-BROEK', 'circle-dot', 2);
insert into app.article_variants(id, article_id, size, sku, sort_order) values
  ('e4000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '152', 'MS-152', 1),
  ('e4000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000001', '164', 'MS-164', 2),
  ('e4000000-0000-4000-8000-000000000003', 'e3000000-0000-4000-8000-000000000002', '152', 'MB-152', 1);
insert into app.article_seasons(article_id, season_id) values
  ('e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001'),
  ('e3000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001');

select has_table('app', 'member_article_sizes', 'maatprofieltabel bestaat');
select ok(not has_table_privilege('authenticated', 'app.member_article_sizes', 'INSERT'), 'authenticated heeft geen directe schrijfrechten');
select ok(not has_function_privilege('anon', 'app.set_member_article_sizes(uuid,uuid,jsonb,text,uuid)', 'EXECUTE'), 'anon kan de mutatie-RPC niet uitvoeren');
select ok(
  exists(
    select 1
    from pg_trigger trigger_row
    where trigger_row.tgrelid = 'app.member_article_sizes'::regclass
      and trigger_row.tgname = 'member_article_sizes_00_lock_member'
      and not trigger_row.tgisinternal
  )
  and not exists(
    select 1
    from pg_trigger trigger_row
    where trigger_row.tgrelid = 'app.member_article_sizes'::regclass
      and trigger_row.tgname < 'member_article_sizes_00_lock_member'
      and not trigger_row.tgisinternal
  ),
  'de member-advisorylocktrigger is aantoonbaar de eerste gebruikstrigger'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok($$select app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001')$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'AAL1 kan maten niet lezen');
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok($$select app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001')$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifte kan maten niet lezen');
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok($$select app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001')$$, 'kledingcommissie kan maatprofiel openen');
select is(jsonb_array_length(app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #> '{sizeProfile,articles}'), 2, 'profiel toont gekoppelde seizoensartikelen');
select ok((app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}') ~ '^[0-9a-f]{64}$', 'profiel bevat concurrencyrevisie');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  null::jsonb, repeat('a', 64), null
)$$, '22023', 'MEMBER_SIZES_INVALID', 'SQL NULL is geen geldige matenlijst');

create temporary table first_profile as
select app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #> '{sizeProfile}' profile;
select lives_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  '[{"articleId":"e3000000-0000-4000-8000-000000000001","variantId":"e4000000-0000-4000-8000-000000000001"}]'::jsonb,
  (select profile->>'revision' from first_profile), 'e5000000-0000-4000-8000-000000000001'
)$$, 'maat kan individueel worden opgeslagen');
select is(app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,articles,0,selectedVariantId}', 'e4000000-0000-4000-8000-000000000001', 'gekozen variant staat seizoensgebonden opgeslagen');
select is((select count(*)::integer from app.audit_logs where action = 'member.sizes.updated' and correlation_id = 'e5000000-0000-4000-8000-000000000001'), 1, 'maatwijziging wordt eenmaal geaudit');
select is(app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,articles,0,selectedVariantId}', 'e4000000-0000-4000-8000-000000000001', 'detail retourneert de opgeslagen maat');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', '[]'::jsonb,
  (select profile->>'revision' from first_profile), null
)$$, '40001', 'MEMBER_SIZES_CONFLICT', 'verouderde revisie wordt geblokkeerd');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  '[{"articleId":"e3000000-0000-4000-8000-000000000001","variantId":"e4000000-0000-4000-8000-000000000003"}]'::jsonb,
  (app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'), null
)$$, '22023', 'MEMBER_SIZE_VARIANT_INVALID', 'variant van ander artikel wordt geweigerd');

reset role;
select throws_ok($$update app.article_variants set size = '153' where id = 'e4000000-0000-4000-8000-000000000001'$$, '23514', 'PROFILE_VARIANT_IDENTITY_IMMUTABLE', 'maatlabel met profielgebruik is immutable');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  '[{"articleId":"e3000000-0000-4000-8000-000000000001","variantId":null}]'::jsonb,
  (app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'), null
)$$, 'niet-bestelde maat kan worden gewist');
select is((
  select count(*)::integer
  from jsonb_array_elements(
    app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001')
      #> '{sizeProfile,articles}'
  ) article
  where article.value->>'selectedVariantId' is not null
), 0, 'wissen verwijdert alleen het voorbereidende profiel');

reset role;
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
values('e6000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 9900);
insert into app.order_lines(order_id, article_variant_id, quantity)
values('e6000000-0000-4000-8000-000000000001', 'e4000000-0000-4000-8000-000000000001', 1);
select is((select article_variant_id::text from app.member_article_sizes where member_id = 'e2000000-0000-4000-8000-000000000001'), 'e4000000-0000-4000-8000-000000000001', 'bestelregel synchroniseert het maatprofiel');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select ok((app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,articles,0,ordered}')::boolean, 'bestelde maat staat als besteld in detail');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  '[{"articleId":"e3000000-0000-4000-8000-000000000001","variantId":"e4000000-0000-4000-8000-000000000002"}]'::jsonb,
  (app.get_member_detail_v2('e2000000-0000-4000-8000-000000000001') #>> '{sizeProfile,revision}'), null
)$$, '23514', 'MEMBER_SIZE_ORDER_LINE_IMMUTABLE', 'maatprofiel kan een bestelregel niet wijzigen');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '[]'::jsonb,
  repeat('a', 64), null
)$$, '23514', 'MEMBER_NOT_ACTIVE', 'inactief lid kan geen nieuwe maten krijgen');
select throws_ok($$select app.set_member_article_sizes(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000002', '[]'::jsonb,
  repeat('a', 64), null
)$$, '23514', 'SEASON_NOT_OPEN', 'gearchiveerd of niet-actief seizoen is geblokkeerd');
select throws_ok($$insert into app.member_article_sizes(member_id, season_id, article_id, article_variant_id) values(
  'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001',
  'e3000000-0000-4000-8000-000000000002', 'e4000000-0000-4000-8000-000000000003'
)$$, '42501', 'permission denied for table member_article_sizes', 'directe tabelmutatie is geblokkeerd');
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok(
  $$select count(*) from app.member_article_sizes$$,
  '42501',
  'permission denied for table member_article_sizes',
  'uitgifte kan de maatprofieltabel niet rechtstreeks lezen'
);

reset role;
select * from finish();
rollback;

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('a1000000-0000-4000-8000-000000000001', 'Aliasbeheer', 'beheerder'),
  ('a1000000-0000-4000-8000-000000000002', 'Aliascommissie', 'kledingcommissie'),
  ('a1000000-0000-4000-8000-000000000003', 'Aliasuitgifte', 'uitgifte');

insert into app.seasons(id, name, default_amount_cents, status) values
  ('a1100000-0000-4000-8000-000000000001', '2043/2044 aliassen', 10000, 'open');
update app.app_settings
set active_season_id = 'a1100000-0000-4000-8000-000000000001'
where id = true;

insert into app.articles(id, name, code, icon_type, sort_order) values
  ('a1200000-0000-4000-8000-000000000001', 'Aliasbroek', 'ALIAS-BROEK', 'circle-dot', 10),
  ('a1200000-0000-4000-8000-000000000002', 'Legacy conflictproduct', 'ALIAS-LEGACY', 'shirt', 20);
insert into app.article_seasons(article_id, season_id) values
  ('a1200000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000001'),
  ('a1200000-0000-4000-8000-000000000002', 'a1100000-0000-4000-8000-000000000001');

select has_table('app', 'article_variant_aliases', 'expliciete maatalias-tabel bestaat');
select ok(
  not has_table_privilege('authenticated', 'app.article_variant_aliases', 'INSERT'),
  'authenticated kan aliassen niet rechtstreeks schrijven'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.upsert_catalog_variant_v2(uuid,uuid,text,text,text[],boolean,integer)',
    'EXECUTE'
  ),
  'anon kan de aliasmutatie niet uitvoeren'
);
select is(
  private.normalize_size_match(E'  xxl\u00a0 '),
  'XXL',
  'Unicode whitespace, NFKC en case worden veilig genormaliseerd'
);
select is(
  private.normalize_size_match('２ｘｌ'),
  '2XL',
  'compatibiliteits-Unicode normaliseert zonder fuzzy matching'
);
select is(
  private.normalize_size_match(U&'\1680XXL\1680'),
  'XXL',
  'Unicode-randspaties worden na normalisatie verwijderd'
);
select ok(
  (
    select bool_and(private.contains_unsafe_size_format(candidate.value))
    from (
      values
        (U&'XX\00ADL'),
        (U&'XX\0600L'),
        (U&'XX\0605L'),
        (U&'XX\061CL'),
        (U&'XX\06DDL'),
        (U&'XX\070FL'),
        (U&'XX\0890L'),
        (U&'XX\08E2L'),
        (U&'XX\180EL'),
        (U&'XX\200BL'),
        (U&'XX\202AL'),
        (U&'XX\2060L'),
        (U&'XX\206FL'),
        (U&'XX\FE0FL'),
        (U&'XX\FEFFL'),
        (U&'XX\FFF9L'),
        (convert_from(decode('f09182bd', 'hex'), 'UTF8')),
        (convert_from(decode('f091838d', 'hex'), 'UTF8')),
        (convert_from(decode('f09390b0', 'hex'), 'UTF8')),
        (convert_from(decode('f09bb2a0', 'hex'), 'UTF8')),
        (convert_from(decode('f09d85b3', 'hex'), 'UTF8')),
        (convert_from(decode('f3a08081', 'hex'), 'UTF8')),
        (convert_from(decode('f3a080a0', 'hex'), 'UTF8'))
    ) candidate(value)
  ),
  'alle Unicode Cf-bereiken en extra onzichtbare opmaak gelden als onveilig'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    'XXL',
    '2XL',
    array['Extra Extra Large'],
    true,
    10
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan geen importmatchsleutels beheren'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
create temporary table alias_variant as
select app.upsert_catalog_variant_v2(
  'a1200000-0000-4000-8000-000000000001',
  null,
  'XXL',
  '2XL',
  array['Extra Extra Large', 'XX-Large'],
  true,
  10
) variant_id;

create temporary table redundant_alias_variant as
select app.upsert_catalog_variant_v2(
  'a1200000-0000-4000-8000-000000000001',
  null,
  '116',
  'M-116',
  array['１１６', 'm-116', 'Jeugd 116'],
  true,
  15
) variant_id;

select is(
  (select count(*) from app.article_variant_aliases
    where article_variant_id = (select variant_id from redundant_alias_variant)),
  1::bigint,
  'eigen maatlabel en leverancierscode zijn redundante aliassen en blokkeren de eerste variant niet'
);
select is(
  (select alias from app.article_variant_aliases
    where article_variant_id = (select variant_id from redundant_alias_variant)),
  'Jeugd 116',
  'alleen de aanvullende exacte importalias wordt opgeslagen'
);
select is(
  (
    select (metadata->>'alias_count')::integer
    from app.audit_logs
    where action = 'catalog.variant.match_keys.updated'
      and entity_id = (select variant_id from redundant_alias_variant)
    order by id desc
    limit 1
  ),
  1,
  'audittelling bevat alleen werkelijk opgeslagen aliassen'
);
select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    '128',
    null,
    array['Jeugdmaat', 'Ｊｅｕｇｄｍａａｔ'],
    true,
    16
  )$$,
  '23505',
  'VARIANT_MATCH_KEY_EXISTS',
  'twee niet-redundante aliassen blijven na normalisatie ongeldig'
);
select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    'Jeugd 116',
    null,
    array[]::text[],
    true,
    17
  )$$,
  '23505',
  'VARIANT_MATCH_KEY_EXISTS',
  'een matchsleutel van een andere variant blijft geblokkeerd'
);

select is(
  (select count(*) from app.article_variant_aliases
    where article_variant_id = (select variant_id from alias_variant)),
  2::bigint,
  'kledingcommissie slaat expliciete aliases transactioneel op'
);
select is(
  (
    select alias_normalized
    from app.article_variant_aliases
    where article_variant_id = (select variant_id from alias_variant)
      and alias = 'Extra Extra Large'
  ),
  'EXTRA EXTRA LARGE',
  'alias bewaart de exacte veilige matchkey'
);
select is(
  app.get_catalog_order_workspace_v2()
    #>> '{articles,0,variants,0,aliases,0}',
  'Extra Extra Large',
  'catalogusworkspace toont aliassen beheerbaar terug'
);

select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    'Anders…',
    null,
    array[]::text[],
    true,
    20
  )$$,
  '23514',
  'OTHER_IS_NOT_A_VARIANT',
  'Anders kan nooit een voorraadvariant worden'
);
select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    'XL',
    null,
    array['Anders'],
    true,
    20
  )$$,
  '23514',
  'OTHER_IS_NOT_A_VARIANT',
  'Anders kan ook geen alias worden'
);
select throws_ok(
  $$select app.upsert_catalog_variant_v2(
    'a1200000-0000-4000-8000-000000000001',
    null,
    'extra   extra large',
    null,
    array[]::text[],
    true,
    20
  )$$,
  '23505',
  'VARIANT_MATCH_KEY_EXISTS',
  'een genormaliseerd label kan niet botsen met een alias'
);
select throws_ok(
  $$select app.upsert_catalog_variant(
    'a1200000-0000-4000-8000-000000000001',
    null,
    '２ＸＬ',
    null,
    true,
    20
  )$$,
  '23505',
  'VARIANT_MATCH_KEY_EXISTS',
  'ook de legacy-RPC kan geen Unicode-equivalente maat invoegen'
);
select lives_ok(
  format(
    $$select app.upsert_catalog_variant_v2(
      'a1200000-0000-4000-8000-000000000001',
      %L::uuid,
      'Extra Extra Large',
      '2XL',
      array['XXL'],
      true,
      10
    )$$,
    (select variant_id from alias_variant)
  ),
  'een bestaande alias kan binnen één transactie veilig tot label worden gepromoveerd'
);
select is(
  (
    select count(*)::integer
    from app.audit_logs
    where action = 'catalog.variant.match_keys.updated'
      and entity_id = (select variant_id from alias_variant)
      and (metadata->>'alias_count')::integer in (1, 2)
  ),
  2,
  'beide aliasmutaties bewaren uitsluitend hun telling'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where action = 'catalog.variant.match_keys.updated'
      and entity_id = (select variant_id from alias_variant)
      and metadata::text ~* 'extra extra large|xx-large'
  ),
  'audit bevat geen aliaswaarden'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
select is(
  (select count(*) from app.article_variant_aliases),
  0::bigint,
  'uitgifte kan aliassen niet rechtstreeks lezen'
);
select throws_ok(
  $$select app.get_catalog_order_workspace_v2()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte krijgt de catalogusmatchworkspace niet'
);
reset role;

-- Simuleer een aantoonbaar legacyconflict dat vóór deze migration had kunnen
-- bestaan. De v2-workspace rapporteert dit als blokkend; matching gokt niet.
alter table app.article_variants disable trigger article_variants_guard_match_keys;
insert into app.article_variants(id, article_id, size, sort_order) values
  ('a1300000-0000-4000-8000-000000000001', 'a1200000-0000-4000-8000-000000000002', 'M', 10),
  ('a1300000-0000-4000-8000-000000000002', 'a1200000-0000-4000-8000-000000000002', 'ｍ', 20),
  ('a1300000-0000-4000-8000-000000000003', 'a1200000-0000-4000-8000-000000000002', 'Anders…', 30),
  ('a1300000-0000-4000-8000-000000000004', 'a1200000-0000-4000-8000-000000000002', U&'XL\061C', 40);
alter table app.article_variants enable trigger article_variants_guard_match_keys;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (
    select jsonb_array_length(article->'matchConflicts')
    from jsonb_array_elements(app.get_catalog_order_workspace_v2()->'articles') article
    where article->>'id' = 'a1200000-0000-4000-8000-000000000002'
  ),
  3,
  'bestaande ambiguïteit, Anders en verborgen opmaak worden als conflict gerapporteerd'
);
select is(
  (
    select count(*)::integer
    from jsonb_array_elements(app.get_catalog_order_workspace_v2()->'articles') article
    cross join jsonb_array_elements(article->'matchConflicts') conflict
    where article->>'id' = 'a1200000-0000-4000-8000-000000000002'
      and conflict->>'reason' in ('ambiguous', 'invalid_other', 'unsafe_format')
  ),
  3,
  'ieder legacyconflict heeft een expliciete veilige redencode'
);
select throws_ok(
  $$insert into app.article_variant_aliases(
    article_id,
    article_variant_id,
    alias,
    alias_normalized
  ) values (
    'a1200000-0000-4000-8000-000000000001',
    (select variant_id from alias_variant),
    'Direct',
    'DIRECT'
  )$$,
  '42501',
  'permission denied for table article_variant_aliases',
  'zelfs geauthenticeerde kledingrollen muteren de aliastabel niet direct'
);

select * from finish();
rollback;

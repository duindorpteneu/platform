begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('b0000000-0000-4000-8000-000000000001', 'Preset eigenaar', 'beheerder'),
  ('b0000000-0000-4000-8000-000000000002', 'Andere commissie', 'kledingcommissie'),
  ('b0000000-0000-4000-8000-000000000003', 'Preset uitgifte', 'uitgifte');

insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    'Presetseizoen',
    '2026-07-01',
    '2027-06-30',
    12500,
    'open',
    timezone('utc', now())
  ),
  (
    'b1000000-0000-4000-8000-000000000002',
    'Ander presetseizoen',
    '2027-07-01',
    '2028-06-30',
    13000,
    'open',
    timezone('utc', now())
  );
update app.app_settings
set active_season_id = 'b1000000-0000-4000-8000-000000000001'
where id = true;

insert into app.articles(id, name, code, icon_type, sort_order)
values(
  'b2000000-0000-4000-8000-000000000001',
  'Presetshirt',
  'PRESET-SHIRT',
  'shirt',
  701
);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values(
  'b3000000-0000-4000-8000-000000000001',
  'b2000000-0000-4000-8000-000000000001',
  'M',
  'PRESET-M',
  1
);
insert into app.article_seasons(article_id, season_id)
values(
  'b2000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000001'
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season
) values(
  'b4000000-0000-4000-8000-000000000001',
  'PRESET-001',
  'Preset',
  'Lid',
  'preset-lid@example.invalid',
  'JO11-1',
  true
);

select ok(
  has_table_privilege('authenticated', 'app.staff_saved_views', 'SELECT'),
  'authenticated krijgt uitsluitend owner-gefilterde leestabeltoegang'
);
select ok(
  not has_table_privilege('authenticated', 'app.staff_saved_views', 'INSERT')
  and not has_table_privilege('authenticated', 'app.staff_saved_views', 'UPDATE')
  and not has_table_privilege('authenticated', 'app.staff_saved_views', 'DELETE'),
  'schrijven kan uitsluitend via de gevalideerde RPCs'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.get_member_saved_views(uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'app.save_member_saved_view(uuid,uuid,text,smallint,jsonb)',
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'app.apply_member_saved_view(uuid,uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'app.delete_member_saved_view(uuid,uuid)',
    'EXECUTE'
  ),
  'authenticated bereikt alleen de smalle saved-view RPC-contracten'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.get_member_saved_views(uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'app.save_member_saved_view(uuid,uuid,text,smallint,jsonb)',
    'EXECUTE'
  ),
  'anon kan opgeslagen personeelsweergaven niet enumereren of schrijven'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan geen personeelsweergaven enumereren'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan geen personeelsweergaven enumereren'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

create temporary table owner_saved_view as
select app.save_member_saved_view(
  null,
  'b1000000-0000-4000-8000-000000000001',
  ' JO11 openstaand ',
  1::smallint,
  jsonb_build_object(
    'team', 'JO11-1',
    'articleId', 'b2000000-0000-4000-8000-000000000001',
    'size', 'M',
    'lineStatus', 'backorder'
  )
) result;
grant select on owner_saved_view to authenticated;

select is(
  (select result->>'name' from owner_saved_view),
  'JO11 openstaand',
  'naam wordt server-side genormaliseerd'
);
select is(
  jsonb_array_length(app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  )->'views'),
  1,
  'eigenaar ziet de eigen seizoensweergave'
);
select is(
  app.apply_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000001'
  )->'filters',
  jsonb_build_object(
    'team', 'JO11-1',
    'articleId', 'b2000000-0000-4000-8000-000000000001',
    'size', 'M',
    'lineStatus', 'backorder'
  ),
  'apply retourneert uitsluitend het volledig opnieuw gevalideerde filterobject'
);
select throws_ok(
  $$select app.save_member_saved_view(
    null,
    'b1000000-0000-4000-8000-000000000001',
    'Onveilige zoektekst',
    1::smallint,
    '{"search":"Preset Lid"}'::jsonb
  )$$,
  '22023',
  'SAVED_VIEW_INVALID',
  'vrije zoektekst kan niet duurzaam als preset worden opgeslagen'
);
select throws_ok(
  $$select app.save_member_saved_view(
    null,
    'b1000000-0000-4000-8000-000000000001',
    'Onbekend team',
    1::smallint,
    '{"team":"JO99-9"}'::jsonb
  )$$,
  '23514',
  'SAVED_VIEW_FILTERS_STALE',
  'een op voorhand stale filter wordt niet opgeslagen'
);
select throws_ok(
  $$select app.apply_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000002'
  )$$,
  'P0002',
  'SAVED_VIEW_NOT_FOUND',
  'apply is exact aan eigenaar én seizoen gebonden'
);

select is(
  (select count(*) from app.staff_saved_views),
  1::bigint,
  'owner-RLS toont alleen de eigen rij'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from app.staff_saved_views),
  0::bigint,
  'andere kledingmedewerker ziet via RLS geen view van de eigenaar'
);
select is(
  jsonb_array_length(app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  )->'views'),
  0,
  'ownerfilter geldt ook binnen de security-definer lijst-RPC'
);
select throws_ok(
  $$select app.apply_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  'P0002',
  'SAVED_VIEW_NOT_FOUND',
  'andere kledingmedewerker kan de view niet toepassen'
);
select throws_ok(
  $$select app.delete_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  'P0002',
  'SAVED_VIEW_NOT_FOUND',
  'andere kledingmedewerker kan de view niet verwijderen'
);

reset role;
update app.member_seasons
set team_name = 'JO13-2'
where member_id = 'b4000000-0000-4000-8000-000000000001'
  and season_id = 'b1000000-0000-4000-8000-000000000001';

select set_config(
  'request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  ) #>> '{views,0,valid}',
  'false',
  'verwijderde teamcontext markeert de volledige preset als stale'
);
select is(
  app.get_member_saved_views(
    'b1000000-0000-4000-8000-000000000001'
  ) #>> '{views,0,invalidReason}',
  'filters_stale',
  'stale preset krijgt een expliciete veilige reden'
);
select throws_ok(
  $$select app.apply_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  '23514',
  'SAVED_VIEW_STALE',
  'stale preset faalt volledig en kan filters nooit verbreden'
);

select lives_ok(
  $$select app.delete_member_saved_view(
    (select (result->>'id')::uuid from owner_saved_view),
    'b1000000-0000-4000-8000-000000000001'
  )$$,
  'eigenaar kan ook een stale preset gecontroleerd verwijderen'
);

reset role;
select ok(not exists(
  select 1
  from app.audit_logs audit
  where audit.entity_type = 'staff_saved_view'
    and (
      audit.metadata ?| array['name', 'filters', 'search']
      or audit.metadata::text like '%JO11-1%'
      or audit.metadata::text like '%Preset Lid%'
    )
), 'saved-view audit bevat geen naam, filters, zoektekst of PII');
select is(
  (select count(*) from app.audit_logs
   where entity_type = 'staff_saved_view'
     and action in (
       'member_saved_view.created',
       'member_saved_view.deleted'
     )),
  2::bigint,
  'aanmaak en verwijdering zijn auditbaar'
);

select throws_ok(
  $$insert into app.staff_saved_views(
    owner_user_id,
    scope,
    season_id,
    name,
    schema_version,
    filters
  ) values (
    'b0000000-0000-4000-8000-000000000001',
    'members',
    'b1000000-0000-4000-8000-000000000001',
    'Onveilig',
    1,
    '{"unknown":"value"}'::jsonb
  )$$,
  '23514',
  null,
  'databaseconstraint weigert onbekende filters onafhankelijk van de RPC'
);

select * from finish();
rollback;

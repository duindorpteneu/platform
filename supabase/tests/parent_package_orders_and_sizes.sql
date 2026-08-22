begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role, active)
values
  ('ea000000-0000-4000-8000-000000000001', 'Pakketbeheerder', 'beheerder', true),
  ('ea000000-0000-4000-8000-000000000002', 'Pakketcommissie', 'kledingcommissie', true),
  ('ea000000-0000-4000-8000-000000000003', 'Pakketuitgifte', 'uitgifte', true);

insert into app.seasons(
  id,
  name,
  starts_on,
  ends_on,
  default_amount_cents,
  status
)
values(
  'ea100000-0000-4000-8000-000000000001',
  '2044/2045 pakketportaal',
  '2044-07-01',
  '2045-06-30',
  12500,
  'open'
);
update app.app_settings
set active_season_id = 'ea100000-0000-4000-8000-000000000001'
where id = true;
update app.release_feature_flags
set enabled = true
where key in ('member_seasons_v2', 'package_orders_v2', 'parent_access_grants_v2');

insert into app.articles(id, name, code, icon_type, sort_order)
values
  ('ea200000-0000-4000-8000-000000000001', 'Portaalshirt', 'PORT-SHIRT', 'shirt', 10),
  ('ea200000-0000-4000-8000-000000000002', 'Portaalbroek', 'PORT-BROEK', 'circle-dot', 20);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values
  ('ea300000-0000-4000-8000-000000000001', 'ea200000-0000-4000-8000-000000000001', '152', 'PORT-SHIRT-152', 10),
  ('ea300000-0000-4000-8000-000000000002', 'ea200000-0000-4000-8000-000000000001', '164', 'PORT-SHIRT-164', 20),
  ('ea300000-0000-4000-8000-000000000003', 'ea200000-0000-4000-8000-000000000002', '152', 'PORT-BROEK-152', 10);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
)
values(
  'ea300000-0000-4000-8000-000000000004',
  'ea200000-0000-4000-8000-000000000002',
  '164',
  'PORT-BROEK-164-INACTIEF',
  20,
  false
);
insert into app.article_seasons(article_id, season_id)
values
  ('ea200000-0000-4000-8000-000000000001', 'ea100000-0000-4000-8000-000000000001'),
  ('ea200000-0000-4000-8000-000000000002', 'ea100000-0000-4000-8000-000000000001');

insert into app.package_templates(id, season_id, template_key, created_by)
values
  ('ea400000-0000-4000-8000-000000000001', 'ea100000-0000-4000-8000-000000000001', 'speler', 'ea000000-0000-4000-8000-000000000001'),
  ('ea400000-0000-4000-8000-000000000002', 'ea100000-0000-4000-8000-000000000001', 'keeper', 'ea000000-0000-4000-8000-000000000001');
insert into app.package_template_revisions(
  id,
  template_id,
  season_id,
  revision_number,
  name,
  description,
  price_cents,
  status,
  active,
  is_default,
  created_by,
  published_by,
  published_at
)
values
  (
    'ea410000-0000-4000-8000-000000000001',
    'ea400000-0000-4000-8000-000000000001',
    'ea100000-0000-4000-8000-000000000001',
    1,
    'Speler',
    'Compleet spelerspakket',
    12500,
    'draft',
    false,
    false,
    'ea000000-0000-4000-8000-000000000001',
    null,
    null
  ),
  (
    'ea410000-0000-4000-8000-000000000002',
    'ea400000-0000-4000-8000-000000000002',
    'ea100000-0000-4000-8000-000000000001',
    1,
    'Keeper',
    'Compleet keeperspakket',
    14500,
    'draft',
    false,
    false,
    'ea000000-0000-4000-8000-000000000001',
    null,
    null
  );
insert into app.package_template_items(
  id,
  revision_id,
  article_id,
  quantity,
  product_name_snapshot,
  product_code_snapshot,
  sort_order,
  season_id
)
values
  (
    'ea420000-0000-4000-8000-000000000001',
    'ea410000-0000-4000-8000-000000000001',
    'ea200000-0000-4000-8000-000000000001',
    1,
    'Portaalshirt',
    'PORT-SHIRT',
    10,
    'ea100000-0000-4000-8000-000000000001'
  ),
  (
    'ea420000-0000-4000-8000-000000000002',
    'ea410000-0000-4000-8000-000000000001',
    'ea200000-0000-4000-8000-000000000002',
    1,
    'Portaalbroek',
    'PORT-BROEK',
    20,
    'ea100000-0000-4000-8000-000000000001'
  ),
  (
    'ea420000-0000-4000-8000-000000000003',
    'ea410000-0000-4000-8000-000000000002',
    'ea200000-0000-4000-8000-000000000001',
    2,
    'Portaalshirt',
    'PORT-SHIRT',
    10,
    'ea100000-0000-4000-8000-000000000001'
  );
update app.package_template_revisions
set status = 'published',
    active = true,
    is_default = id = 'ea410000-0000-4000-8000-000000000001',
    published_by = 'ea000000-0000-4000-8000-000000000001',
    published_at = timezone('utc', now())
where id in (
  'ea410000-0000-4000-8000-000000000001',
  'ea410000-0000-4000-8000-000000000002'
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  gender
)
values(
  'ea500000-0000-4000-8000-000000000001',
  'PAKKET-001',
  'Noa',
  'Pakket',
  'noa-pakket@example.invalid',
  'JO13-1',
  'female'
);
update private.member_sensitive_identity
set date_of_birth = '2013-05-17'
where member_id = 'ea500000-0000-4000-8000-000000000001';
select is(
  (
    select id
    from app.member_seasons
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and season_id = 'ea100000-0000-4000-8000-000000000001'
  ),
  (
    select id
    from app.member_seasons
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and season_id = 'ea100000-0000-4000-8000-000000000001'
  ),
  'membertrigger materialiseert de actuele lid-seizoenrelatie'
);

insert into private.parent_accounts(id, email_normalized)
values(
  'ea600000-0000-4000-8000-000000000001',
  'ouder-pakket@example.invalid'
);
insert into private.parent_sessions(
  parent_account_id,
  token_hash,
  expires_at
)
values(
  'ea600000-0000-4000-8000-000000000001',
  repeat('a', 64),
  timezone('utc', now()) + interval '1 hour'
);
insert into private.parent_portal_grants(
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  granted_by,
  granted_at
)
select
  member_season.id,
  'ouder-pakket@example.invalid',
  'ea600000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'ea000000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_seasons member_season
where member_season.member_id = 'ea500000-0000-4000-8000-000000000001'
  and member_season.season_id = 'ea100000-0000-4000-8000-000000000001';

insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source
)
values(
  'ea500000-0000-4000-8000-000000000001',
  'ea100000-0000-4000-8000-000000000001',
  'ea200000-0000-4000-8000-000000000001',
  'ea300000-0000-4000-8000-000000000001',
  'imported_unconfirmed',
  'import'
);

select is(
  public.get_parent_package_workspace_v2(repeat('a', 64))->>'enabled',
  'true',
  'ouderworkspace volgt de pakketfeatureflag'
);
select is(
  jsonb_array_length(
    public.get_parent_package_workspace_v2(repeat('a', 64))->'members'
  ),
  1,
  'alleen expliciet verleende lid-seizoenen zijn zichtbaar'
);
select is(
  public.get_parent_package_workspace_v2(repeat('a', 64))
    #>> '{members,0,dateOfBirth}',
  '2013-05-17',
  'ouder met grant ziet de geboortedatum van het eigen lid'
);
select is(
  jsonb_array_length(
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #> '{members,0,availablePackages}'
  ),
  2,
  'ouder ziet uitsluitend actieve gepubliceerde pakketten van dit seizoen'
);
select is(
  jsonb_array_length(
    public.get_parent_package_workspace_v3(repeat('a', 64))
      #> '{members,0,availablePackages,0,items}'
  ),
  2,
  'pakketkeuze toont vooraf de commerciële pakketinhoud'
);
select is(
  jsonb_array_length(
    public.get_parent_package_workspace_v4(repeat('a', 64))
      #> '{members,0,availablePackages,0,items}'
  ),
  2,
  'ouderworkspace v4 behoudt pakketinhoud en voegt alleen veilige QR-identiteit toe'
);
select is(
  public.get_parent_package_workspace_v5(repeat('a', 64))
    #>> '{members,0,availablePackages,0,items,0,iconType}',
  'shirt',
  'ouderworkspace toont het beheerbare canonieke artikelicoon'
);
select matches(
  public.get_parent_package_workspace_v2(repeat('a', 64))
    #>> '{members,0,revision}',
  '^[0-9a-f]{64}$',
  'lid-seizoenworkspace heeft ook zonder order een revisie'
);
select throws_ok(
  $$select public.get_parent_package_workspace_v2(repeat('b', 64))$$,
  '42501',
  'PARENT_SESSION_REQUIRED',
  'ongeldige oudersessie geeft geen identiteit of pakketdata prijs'
);

select set_config(
  'test.package.member_season',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,memberSeasonId}'
  ),
  true
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.select_parent_package_v3(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    'ea410000-0000-4000-8000-000000000001',
    current_setting('test.package.revision'),
    'eaf20000-0000-4000-8000-000000000001',
    'eaf00000-0000-4000-8000-000000000001'
  )$$,
  'ouder kiest transactioneel een gepubliceerd pakket'
);
select is(
  (
    public.select_parent_package_v3(
      repeat('a', 64),
      current_setting('test.package.member_season')::uuid,
      'ea410000-0000-4000-8000-000000000001',
      current_setting('test.package.revision'),
      'eaf20000-0000-4000-8000-000000000001',
      null
    )->>'reused'
  ),
  'true',
  'pakketkeuze hergebruikt dezelfde request-ID en resultaatssnapshot'
);
select is(
  (
    select count(*)
    from private.parent_package_selection_requests selection_request
    where selection_request.request_id =
      'eaf20000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'pakketkeuze schrijft exact één duurzame ouderactor en request'
);
select is(
  (
    select amount_due_cents
    from app.member_orders
    where member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  12500,
  'pakketprijs wordt server-side uit de revisie overgenomen'
);
select is(
  (
    select snapshot.package_name
    from app.member_orders orders
    join app.order_package_snapshots snapshot
      on snapshot.id = orders.active_package_snapshot_id
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  'Speler',
  'order bewaart de immutable pakketnaamsnapshot'
);
select is(
  (
    select count(*)
    from app.member_orders orders
    join app.order_package_snapshot_items item
      on item.snapshot_id = orders.active_package_snapshot_id
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  2::bigint,
  'de commerciële snapshot bevat beide pakketproducten zonder gekozen maat'
);
select is(
  (
    select count(*)
    from app.member_orders orders
    join app.order_lines line on line.order_id = orders.id
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  0::bigint,
  'pakketkeuze alleen maakt nog geen logistieke regels'
);

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select is(
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,order,sizesConfirmed}'
  ),
  'false',
  'een ontbrekende maatregel maakt het pakket aantoonbaar incompleet'
);
insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value
)
values(
  'ea500000-0000-4000-8000-000000000001',
  'ea100000-0000-4000-8000-000000000001',
  'ea200000-0000-4000-8000-000000000002',
  null,
  'conflict',
  'import',
  'XXXL'
);
select is(
  (
    select history.raw_value
    from app.member_size_selection_history history
    where history.member_season_id =
        current_setting('test.package.member_season')::uuid
      and history.article_id =
        'ea200000-0000-4000-8000-000000000002'
    order by history.recorded_at desc, history.id desc
    limit 1
  ),
  'XXXL',
  'ruwe onbekende importmaat wordt append-only vastgelegd'
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"EA200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000010',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_SELECTION_INVALID',
  'UUID-hoofdletters kunnen een ontbrekend pakketproduct niet maskeren'
);
update app.article_variants
set active = false
where id = 'ea300000-0000-4000-8000-000000000001';
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000012',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_VARIANT_INVALID',
  'inactieve geïmporteerde suggestie kan niet als bevestigde maat promoveren'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000001',
    'eaf00000-0000-4000-8000-000000000002'
  )$$,
  'ouder bevestigt alle pakketmaten in één transactie'
);
select is(
  (
    select count(*)
    from app.package_size_confirmation_items confirmation_item
    join app.package_size_confirmations confirmation
      on confirmation.id = confirmation_item.confirmation_id
    where confirmation.request_id =
      'eaf10000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'confirmationledger bewaart ieder gekozen pakketproduct immutable'
);
select is(
  (
    select confirmation.schema_version::text || ':' ||
      (confirmation.result_snapshot->>'reused')
    from app.package_size_confirmations confirmation
    where confirmation.request_id =
      'eaf10000-0000-4000-8000-000000000001'
  ),
  '2:false',
  'eerste bevestiging bewaart een stabiele veilige resultaatsnapshot'
);
select is(
  (
    select selection_status::text
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'confirmed',
  'geïmporteerde geldige maat wordt pas door ouderbevestiging bevestigd'
);
select ok(
  exists(
    select 1
    from app.member_size_selection_history history
    where history.member_season_id =
        current_setting('test.package.member_season')::uuid
      and history.article_id =
        'ea200000-0000-4000-8000-000000000001'
      and history.selection_status = 'confirmed'
      and history.client_request_id =
        'eaf10000-0000-4000-8000-000000000001'
      and history.correlation_id =
        'eaf00000-0000-4000-8000-000000000002'
      and history.actor_parent_account_id =
        'ea600000-0000-4000-8000-000000000001'
      and history.actor_user_id is null
  ),
  'ouderbevestiging bewaart request, correlatie en duurzame ouderactor'
);
select is(
  (
    select selection_status::text || ':' || selection_source::text
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000002'
  ),
  'conflict:parent',
  'Anders blijft een expliciet ouderconflict en wordt geen variant'
);
select ok(
  exists(
    select 1
    from app.member_size_selection_history history
    where history.member_season_id =
        current_setting('test.package.member_season')::uuid
      and history.article_id =
        'ea200000-0000-4000-8000-000000000002'
      and history.selection_status = 'conflict'
      and history.selection_source = 'import'
      and history.raw_value = 'XXXL'
  ),
  'ouderbevestiging overschrijft de ruwe importconflicthistorie niet'
);
select is(
  (
    select count(*)
    from app.member_orders orders
    join app.order_lines line
      on line.order_id = orders.id
      and line.status <> 'cancelled'
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  1::bigint,
  'alleen de maatgeldige component krijgt een logistieke orderregel'
);
select ok(
  exists(
    select 1
    from app.action_items item
    where item.type = 'size_other'
      and item.status = 'open'
      and item.object_type = 'package_order_item'
  ),
  'Anders opent één gededupliceerd operationeel actiepunt'
);
select ok(
  private.package_sizes_complete(
    (
      select id
      from app.member_orders
      where member_season_id =
        current_setting('test.package.member_season')::uuid
    ),
    (
      select active_package_snapshot_id
      from app.member_orders
      where member_season_id =
        current_setting('test.package.member_season')::uuid
    )
  ),
  'bevestigd Anders stopt pakketbrede ledenherinneringen'
);
select ok(
  not exists(
    select 1
    from app.audit_logs audit
    where audit.action like 'package_sizes.%'
      and (
        audit.metadata::text ilike '%buiten de beschikbare%'
        or audit.metadata::text like '%2013-05-17%'
      )
  ),
  'audit bevat geen DOB of vrije oudernotitie'
);

select is(
  (
    public.confirm_parent_package_sizes_v5(
      repeat('a', 64),
      current_setting('test.package.member_season')::uuid,
      '[
        {
          "articleId":"ea200000-0000-4000-8000-000000000001",
          "kind":"variant",
          "variantId":"ea300000-0000-4000-8000-000000000001",
          "note":null
        },
        {
          "articleId":"ea200000-0000-4000-8000-000000000002",
          "kind":"other",
          "variantId":null,
          "note":"Broek valt buiten de beschikbare maattabel"
        }
      ]'::jsonb,
      current_setting('test.package.revision'),
      'eaf10000-0000-4000-8000-000000000001',
      null
    )->>'reused'
  ),
  'true',
  'retry met dezelfde request-ID geeft hetzelfde confirmationresultaat'
);
select is(
  (
    select count(*)
    from app.package_size_confirmations
    where request_id = 'eaf10000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'idempotente retry schrijft exact één confirmationevent'
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000002",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Andere inhoud"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000001',
    null
  )$$,
  '23505',
  'PACKAGE_SIZE_IDEMPOTENCY_CONFLICT',
  'hergebruikte request-ID met andere inhoud wordt geblokkeerd'
);
update app.order_lines line
set status = 'cancelled',
    updated_at = timezone('utc', now())
from app.member_orders orders
where line.order_id = orders.id
  and orders.member_season_id =
    current_setting('test.package.member_season')::uuid
  and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  and line.status = 'backorder';
update app.article_variants
set active = false
where id = 'ea300000-0000-4000-8000-000000000001';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000012',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_VARIANT_INVALID',
  'inactieve bevestigde maat zonder actieve logistieke regel is geen historische echo'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000011',
    null
  )$$,
  'gelijke bevestigde maat herstelt een ontbrekende logistieke regel'
);
select is(
  (
    select count(*)::integer
    from app.member_orders orders
    join app.order_lines line
      on line.order_id = orders.id
      and line.article_id = 'ea200000-0000-4000-8000-000000000001'
      and line.status <> 'cancelled'
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
  ),
  1,
  'bevestigde maat heeft na herstel exact één actieve logistieke regel'
);

insert into app.payments(
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
)
select
  orders.id,
  'cash',
  'paid',
  orders.amount_due_cents,
  'parent-package-paid-001',
  timezone('utc', now())
from app.member_orders orders
where orders.member_season_id =
  current_setting('test.package.member_season')::uuid;

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000002",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000002',
    null
  )$$,
  'betaalde maar nog niet gereserveerde pakketmaat kan gecontroleerd wijzigen'
);
select is(
  (
    select line.size_snapshot
    from app.member_orders orders
    join app.order_lines line
      on line.order_id = orders.id
      and line.status <> 'cancelled'
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
      and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  '164',
  'betaalde pre-allocatiemutatie actualiseert de logistieke maatsnapshot'
);
select is(
  (
    select line.product_name_snapshot
    from app.member_orders orders
    join app.order_lines line
      on line.order_id = orders.id
      and line.status <> 'cancelled'
    where orders.member_season_id =
      current_setting('test.package.member_season')::uuid
      and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'Portaalshirt',
  'productnaam blijft uit de commerciële pakketsnapshot afkomstig'
);

insert into app.delivery_receipts(
  id,
  received_on,
  supplier,
  packing_slip_reference,
  actor_user_id
)
values(
  'ea700000-0000-4000-8000-000000000001',
  current_date,
  'Pakkettestleverancier',
  'PAKKET-TEST',
  'ea000000-0000-4000-8000-000000000002'
);
insert into app.delivery_receipt_lines(
  id,
  receipt_id,
  article_variant_id,
  received_quantity
)
values(
  'ea710000-0000-4000-8000-000000000001',
  'ea700000-0000-4000-8000-000000000001',
  'ea300000-0000-4000-8000-000000000002',
  1
);
insert into app.inventory_reservations(
  id,
  receipt_line_id,
  order_line_id,
  quantity,
  actor_user_id
)
select
  'ea720000-0000-4000-8000-000000000001',
  'ea710000-0000-4000-8000-000000000001',
  line.id,
  1,
  'ea000000-0000-4000-8000-000000000002'
from app.member_orders orders
join app.order_lines line
  on line.order_id = orders.id
  and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  and line.status <> 'cancelled'
where orders.member_season_id =
  current_setting('test.package.member_season')::uuid;
update app.order_lines line
set status = 'ready_for_pickup'
from app.member_orders orders
where line.order_id = orders.id
  and orders.member_season_id =
    current_setting('test.package.member_season')::uuid
  and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  and line.status <> 'cancelled';

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000003',
    'eaf00000-0000-4000-8000-000000000003'
  )$$,
  'wijziging na reservering wordt als actiepunt vastgelegd'
);
select is(
  (
    select article_variant_id
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'ea300000-0000-4000-8000-000000000002'::uuid,
  'harde reservering behoudt de werkelijk gereserveerde variant'
);
select is(
  (
    select requested_article_variant_id
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'ea300000-0000-4000-8000-000000000001'::uuid,
  'gevraagde nieuwe variant staat afzonderlijk van de harde allocatie'
);
select is(
  (
    select selection_status::text
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'change_requested',
  'maatwijziging na reservering heeft een eigen statusas'
);
select ok(
  exists(
    select 1
    from app.action_items item
    where item.type = 'size_change_after_reservation'
      and item.status = 'open'
  ),
  'reserveringswijziging opent één operationeel actiepunt'
);
select ok(
  exists(
    select 1
    from app.package_size_change_requests request
    where request.order_line_id = (
        select reservation.order_line_id
        from app.inventory_reservations reservation
        where reservation.id = 'ea720000-0000-4000-8000-000000000001'
      )
      and request.current_variant_id =
        'ea300000-0000-4000-8000-000000000002'
      and request.requested_variant_id =
        'ea300000-0000-4000-8000-000000000001'
      and request.status = 'requested'
  ),
  'gereserveerde maatwijziging krijgt een duurzaam historisch verzoek'
);
select set_config(
  'test.package.change_request',
  (
    select request.id::text
    from app.package_size_change_requests request
    where request.order_line_id = (
      select reservation.order_line_id
      from app.inventory_reservations reservation
      where reservation.id = 'ea720000-0000-4000-8000-000000000001'
    )
      and request.status = 'requested'
  ),
  true
);
select is(
  (
    select request.correlation_id::text || ':' ||
      request.client_request_id::text
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'eaf00000-0000-4000-8000-000000000003:eaf10000-0000-4000-8000-000000000003',
  'duurzaam maatverzoek bewaart correlatie en client-request-id'
);
select ok(
  exists(
    select 1
    from app.member_size_selection_history history
    where history.size_change_request_id =
        current_setting('test.package.change_request')::uuid
      and history.client_request_id =
        'eaf10000-0000-4000-8000-000000000003'
      and history.correlation_id =
        'eaf00000-0000-4000-8000-000000000003'
      and history.selection_status = 'change_requested'
  ),
  'maatprojectie verwijst naar hetzelfde immutable wijzigingsverzoek'
);
update app.article_variants
set active = false
where id = 'ea300000-0000-4000-8000-000000000001';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000013',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_VARIANT_INVALID',
  'een inmiddels inactief aangevraagd doel is ook bij identieke retry geen historische echo'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';
select is(
  (
    select request.status
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'requested',
  'afgewezen inactieve retry verandert het open verzoek niet'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  jsonb_array_length(
    app.get_catalog_order_workspace_v4()
      ->'packageSizeChangeRequests'
  ),
  1,
  'beheerderworkspace toont het open gereserveerde maatverzoek'
);
select ok(
  app.get_catalog_order_workspace_v4()::text not like '%parentAccountId%',
  'beheerderprojectie lekt geen technische ouderidentificator'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  jsonb_array_length(
    app.get_catalog_order_workspace_v4()
      ->'packageSizeChangeRequests'
  ),
  0,
  'kledingcommissie krijgt geen oudernotities of wijzigingsverzoeken'
);
select ok(
  app.get_catalog_order_workspace_v4()::text
    not like '%Broek valt buiten de beschikbare maattabel%',
  'kledingcommissieprojectie bevat de vrije oudernotitie niet'
);
reset role;
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select lives_ok(
  format(
    $$select app.resolve_package_size_change_v3(
      %L::uuid,
      'approve',
      'ea300000-0000-4000-8000-000000000001',
      'Geldige aangevraagde maat goedgekeurd',
      %L,
      'eaf00000-0000-4000-8000-000000000004'
    )$$,
    current_setting('test.package.change_request'),
    current_setting('test.package.revision')
  ),
  'alleen beheerder met MFA keurt een gereserveerde maatwijziging goed'
);
select is(
  (
    app.resolve_package_size_change_v3(
      current_setting('test.package.change_request')::uuid,
      'approve',
      'ea300000-0000-4000-8000-000000000001',
      'Geldige aangevraagde maat goedgekeurd',
      current_setting('test.package.revision'),
      null
    )->>'reused'
  ),
  'true',
  'gelijke resolverretry hergebruikt de terminale beslissing'
);
reset role;
select ok(
  exists(
    select 1
    from app.member_size_selection_history history
    where history.size_change_request_id =
        current_setting('test.package.change_request')::uuid
      and history.correlation_id =
        'eaf00000-0000-4000-8000-000000000004'
      and history.actor_user_id =
        'ea000000-0000-4000-8000-000000000001'
      and history.selection_status = 'confirmed'
  ),
  'beheerbesluit bewaart wijzigingsverzoek, correlatie en medewerkeractor'
);

select is(
  (
    select reservation.status::text
    from app.inventory_reservations reservation
    where reservation.id = 'ea720000-0000-4000-8000-000000000001'
  ),
  'released',
  'goedkeuring geeft exact de oude reservering vrij'
);
select is(
  (
    select line.status::text || ':' || line.article_variant_id::text
    from app.order_lines line
    where line.id = (
      select request.order_line_id
      from app.package_size_change_requests request
      where request.id =
        current_setting('test.package.change_request')::uuid
    )
  ),
  'cancelled:ea300000-0000-4000-8000-000000000002',
  'oude logistieke regel en variant blijven historisch intact'
);
select is(
  (
    select line.status::text || ':' || line.article_variant_id::text
    from app.order_lines line
    join app.package_size_change_requests request
      on request.replacement_order_line_id = line.id
    where request.id = current_setting('test.package.change_request')::uuid
  ),
  'backorder:ea300000-0000-4000-8000-000000000001',
  'goedkeuring maakt een nieuwe ongealloceerde logistieke regel'
);
select is(
  (
    select request.status
    from app.package_size_change_requests request
    where request.id = current_setting('test.package.change_request')::uuid
  ),
  'approved',
  'immutable wijzigingsverzoek bewaart de goedkeuring'
);

insert into app.delivery_receipt_lines(
  id,
  receipt_id,
  article_variant_id,
  received_quantity
)
values(
  'ea710000-0000-4000-8000-000000000002',
  'ea700000-0000-4000-8000-000000000001',
  'ea300000-0000-4000-8000-000000000001',
  1
);
insert into app.inventory_reservations(
  id,
  receipt_line_id,
  order_line_id,
  quantity,
  actor_user_id
)
select
  'ea720000-0000-4000-8000-000000000002',
  'ea710000-0000-4000-8000-000000000002',
  line.id,
  1,
  'ea000000-0000-4000-8000-000000000002'
from app.member_orders orders
join app.order_lines line
  on line.order_id = orders.id
  and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  and line.status = 'backorder'
where orders.member_season_id =
  current_setting('test.package.member_season')::uuid;
update app.order_lines line
set status = 'ready_for_pickup'
from app.inventory_reservations reservation
where reservation.id = 'ea720000-0000-4000-8000-000000000002'
  and line.id = reservation.order_line_id;

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"other",
        "variantId":null,
        "note":"Shirt valt buiten de beschikbare maattabel"
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000005',
    null
  )$$,
  'een volgende gereserveerde wijziging opent een nieuwe episode'
);
select set_config(
  'test.package.change_request',
  (
    select request.id::text
    from app.package_size_change_requests request
    where request.order_line_id = (
      select reservation.order_line_id
      from app.inventory_reservations reservation
      where reservation.id = 'ea720000-0000-4000-8000-000000000002'
    )
      and request.status = 'requested'
  ),
  true
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $$select app.resolve_package_size_change_v3(
      %L::uuid,
      'reject',
      null,
      'Commissie mag niet beslissen',
      %L,
      null
    )$$,
    current_setting('test.package.change_request'),
    current_setting('test.package.revision')
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan een reserveringswijziging niet beslissen'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select lives_ok(
  format(
    $$select app.resolve_package_size_change_v3(
      %L::uuid,
      'reject',
      null,
      'Werkelijk gereserveerde maat blijft gelden',
      %L,
      null
    )$$,
    current_setting('test.package.change_request'),
    current_setting('test.package.revision')
  ),
  'beheerder wijst een wijziging met verplichte reden af'
);
reset role;
select is(
  (
    select reservation.status::text
    from app.inventory_reservations reservation
    where reservation.id = 'ea720000-0000-4000-8000-000000000002'
  ),
  'reserved',
  'afwijzing verandert de harde reservering niet'
);
select is(
  (
    select size_profile.selection_status::text || ':' ||
      size_profile.article_variant_id::text
    from app.member_article_sizes size_profile
    where size_profile.member_season_id =
      current_setting('test.package.member_season')::uuid
      and size_profile.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  'confirmed:ea300000-0000-4000-8000-000000000001',
  'afwijzing herstelt de actuele projectie naar de gereserveerde maat'
);

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"other",
        "variantId":null,
        "note":"Shirt valt buiten de beschikbare maattabel"
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000006',
    null
  )$$,
  'ouder kan na afwijzing opnieuw een geauditeerd verzoek indienen'
);
select set_config(
  'test.package.change_request',
  (
    select request.id::text
    from app.package_size_change_requests request
    where request.order_line_id = (
      select reservation.order_line_id
      from app.inventory_reservations reservation
      where reservation.id = 'ea720000-0000-4000-8000-000000000002'
    )
      and request.status = 'requested'
  ),
  true
);
select set_config(
  'test.package.change_requested_at',
  (
    select request.requested_at::text
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  true
);
select set_config(
  'test.package.size_updated_at',
  (
    select size_profile.updated_at::text
    from app.member_article_sizes size_profile
    where size_profile.member_season_id =
      current_setting('test.package.member_season')::uuid
      and size_profile.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  true
);
select set_config(
  'test.package.size_history_count',
  (
    select count(*)::text
    from app.member_size_selection_history history
    where history.member_season_id =
      current_setting('test.package.member_season')::uuid
      and history.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  true
);
select set_config(
  'test.package.change_action_updated_at',
  (
    select item.updated_at::text
    from app.action_items item
    where item.type = 'size_change_after_reservation'
      and item.season_id = 'ea100000-0000-4000-8000-000000000001'
      and item.status = 'open'
    order by item.created_at desc
    limit 1
  ),
  true
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select is(
  (
    public.confirm_parent_package_sizes_v5(
      repeat('a', 64),
      current_setting('test.package.member_season')::uuid,
      '[
        {
          "articleId":"ea200000-0000-4000-8000-000000000001",
          "kind":"other",
          "variantId":null,
          "note":"Shirt valt buiten de beschikbare maattabel"
        },
        {
          "articleId":"ea200000-0000-4000-8000-000000000002",
          "kind":"other",
          "variantId":null,
          "note":"Broek valt buiten de beschikbare maattabel"
        }
      ]'::jsonb,
      current_setting('test.package.revision'),
      'eaf10000-0000-4000-8000-000000000008',
      null
    )->>'changeRequestCount'
  ),
  '1',
  'dezelfde open maatwijziging met een nieuwe request-id is een semantische no-op'
);
select is(
  (
    select count(*)::integer
    from app.package_size_change_requests request
    where request.order_line_id = (
      select reservation.order_line_id
      from app.inventory_reservations reservation
      where reservation.id = 'ea720000-0000-4000-8000-000000000002'
    )
      and request.status = 'requested'
  ),
  1,
  'een semantische retry maakt geen tweede open wijzigingsepisode'
);
select is(
  (
    select request.id
    from app.package_size_change_requests request
    where request.order_line_id = (
      select reservation.order_line_id
      from app.inventory_reservations reservation
      where reservation.id = 'ea720000-0000-4000-8000-000000000002'
    )
      and request.status = 'requested'
  ),
  current_setting('test.package.change_request')::uuid,
  'een semantische retry behoudt de oorspronkelijke requestidentiteit'
);
select is(
  (
    select request.requested_at::text
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  current_setting('test.package.change_requested_at'),
  'een semantische retry reset de FIFO- en SLA-tijd niet'
);
select is(
  (
    select size_profile.updated_at::text
    from app.member_article_sizes size_profile
    where size_profile.member_season_id =
      current_setting('test.package.member_season')::uuid
      and size_profile.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  current_setting('test.package.size_updated_at'),
  'semantische Anders-retry verandert de maatprojectietijd niet'
);
select is(
  (
    select count(*)::text
    from app.member_size_selection_history history
    where history.member_season_id =
      current_setting('test.package.member_season')::uuid
      and history.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  current_setting('test.package.size_history_count'),
  'semantische Anders-retry schrijft geen fictieve maathistorie'
);
select is(
  (
    select item.updated_at::text
    from app.action_items item
    where item.type = 'size_change_after_reservation'
      and item.season_id = 'ea100000-0000-4000-8000-000000000001'
      and item.status = 'open'
    order by item.created_at desc
    limit 1
  ),
  current_setting('test.package.change_action_updated_at'),
  'semantische Anders-retry heropent of verschuift het actiepunt niet'
);
update app.inventory_reservations
set status = 'fulfilled'
where id = 'ea720000-0000-4000-8000-000000000002';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000014',
    null
  )$$,
  '23514',
  'PACKAGE_SIZE_CHANGE_STATE_INVALID',
  'een fulfilled reservering kan niet via ouderintrekking worden teruggedraaid'
);
update app.inventory_reservations
set status = 'released'
where id = 'ea720000-0000-4000-8000-000000000002';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000015',
    null
  )$$,
  '23514',
  'PACKAGE_SIZE_CHANGE_STATE_INVALID',
  'een released reservering kan niet via ouderintrekking worden teruggedraaid'
);
update app.inventory_reservations
set status = 'reserved'
where id = 'ea720000-0000-4000-8000-000000000002';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000004",
        "note":null
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000016',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_VARIANT_INVALID',
  'ongeldig later pakketitem rolt een voorlopige withdrawal volledig terug'
);
select is(
  (
    select request.status
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'requested',
  'mislukte pakketbevestiging behoudt het open wijzigingsverzoek'
);
select is(
  (
    select size_profile.selection_status::text || ':' ||
      coalesce(size_profile.requested_raw_value, '')
    from app.member_article_sizes size_profile
    where size_profile.member_season_id =
      current_setting('test.package.member_season')::uuid
      and size_profile.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  'change_requested:Anders…',
  'mislukte pakketbevestiging behoudt de gevraagde Anders-projectie'
);
select is(
  (
    select reservation.status::text
    from app.inventory_reservations reservation
    where reservation.id = 'ea720000-0000-4000-8000-000000000002'
  ),
  'reserved',
  'mislukte pakketbevestiging behoudt de harde reservering'
);
select ok(
  not exists(
    select 1
    from app.package_size_confirmations confirmation
    where confirmation.request_id =
      'eaf10000-0000-4000-8000-000000000016'
  ),
  'mislukte pakketbevestiging schrijft geen confirmationreceipt'
);
select throws_ok(
  $$update app.order_lines line
    set status = 'picked_up'
    from app.inventory_reservations reservation
    where reservation.id = 'ea720000-0000-4000-8000-000000000002'
      and line.id = reservation.order_line_id$$,
  '23514',
  'PACKAGE_SIZE_CHANGE_PENDING',
  'een open maatwijzigingsverzoek blokkeert uitgifte'
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
update app.article_variants
set active = false
where id = 'ea300000-0000-4000-8000-000000000001';
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000007',
    null
  )$$,
  'ouder kan een verzoek intrekken met de inmiddels inactieve gereserveerde maat'
);
select is(
  (
    public.confirm_parent_package_sizes_v5(
      repeat('a', 64),
      current_setting('test.package.member_season')::uuid,
      '[
        {
          "articleId":"ea200000-0000-4000-8000-000000000001",
          "kind":"variant",
          "variantId":"ea300000-0000-4000-8000-000000000001",
          "note":null
        },
        {
          "articleId":"ea200000-0000-4000-8000-000000000002",
          "kind":"other",
          "variantId":null,
          "note":"Broek valt buiten de beschikbare maattabel"
        }
      ]'::jsonb,
      current_setting('test.package.revision'),
      'eaf10000-0000-4000-8000-000000000007',
      null
    )->>'reused'
  ),
  'true',
  'retry van een ingetrokken verzoek geeft dezelfde resultaatsnapshot'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';
select is(
  (
    select request.status
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'withdrawn',
  'ingetrokken ouderverzoek blijft als terminal historisch feit bestaan'
);
select is(
  (
    select request.withdrawn_by_parent_account_id
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'ea600000-0000-4000-8000-000000000001'::uuid,
  'ingetrokken verzoek bewaart de duurzame ouderactor'
);
select is(
  (
    select reservation.status::text
    from app.inventory_reservations reservation
    where reservation.id = 'ea720000-0000-4000-8000-000000000002'
  ),
  'reserved',
  'intrekken behoudt de werkelijke harde reservering'
);
select is(
  (
    select size_profile.selection_status::text || ':' ||
      size_profile.article_variant_id::text
    from app.member_article_sizes size_profile
    where size_profile.member_season_id =
      current_setting('test.package.member_season')::uuid
      and size_profile.article_id =
        'ea200000-0000-4000-8000-000000000001'
  ),
  'confirmed:ea300000-0000-4000-8000-000000000001',
  'intrekken herstelt de projectie naar de gereserveerde maat'
);
select ok(
  exists(
    select 1
    from app.audit_logs audit
    where audit.action = 'order.package_size_change.withdrawn'
      and audit.entity_id =
        current_setting('test.package.change_request')::uuid
  ),
  'intrekken schrijft één controleerbaar auditevent'
);

select throws_ok(
  $$select public.select_parent_package_v2(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    'ea410000-0000-4000-8000-000000000002',
    current_setting('test.package.revision'),
    null
  )$$,
  '40001',
  'PACKAGE_SELECTION_CONFLICT',
  'stale pakketwissel wordt vóór bedrijfsvalidatie geweigerd'
);
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.select_parent_package_v2(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    'ea410000-0000-4000-8000-000000000002',
    current_setting('test.package.revision'),
    null
  )$$,
  '23514',
  'PACKAGE_SWITCH_REQUIRES_ADMIN_WORKFLOW',
  'betaling of reservering blokkeert een gewone pakketwissel'
);

insert into app.fulfilments(
  id,
  order_id,
  actor_user_id,
  location
)
select
  'ea730000-0000-4000-8000-000000000001',
  orders.id,
  'ea000000-0000-4000-8000-000000000002',
  'Pakkettestbalie'
from app.member_orders orders
where orders.member_season_id =
  current_setting('test.package.member_season')::uuid;
insert into app.fulfilment_lines(
  fulfilment_id,
  order_line_id,
  reservation_id,
  quantity
)
select
  'ea730000-0000-4000-8000-000000000001',
  reservation.order_line_id,
  reservation.id,
  reservation.quantity
from app.inventory_reservations reservation
where reservation.id = 'ea720000-0000-4000-8000-000000000002';
update app.order_lines line
set status = 'picked_up'
from app.member_orders orders
where line.order_id = orders.id
  and orders.member_season_id =
    current_setting('test.package.member_season')::uuid
  and line.article_id = 'ea200000-0000-4000-8000-000000000001'
  and line.status <> 'cancelled';

select is(
  (
    select selection_status::text
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'locked',
  'uitgifte vergrendelt de werkelijk uitgegeven maat'
);
select ok(
  not exists(
    select 1
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
      and (
        requested_article_variant_id is not null
        or requested_raw_value is not null
        or requested_member_note is not null
      )
  ),
  'uitgifte sluit de mutabele projectie van het wijzigingsverzoek'
);
select is(
  (
    select request.status
    from app.package_size_change_requests request
    where request.id =
      current_setting('test.package.change_request')::uuid
  ),
  'withdrawn',
  'uitgifte bewaart de eerdere ouderintrekking historisch'
);

select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
update app.article_variants
set active = false
where id = 'ea300000-0000-4000-8000-000000000001';
select lives_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"other",
        "variantId":null,
        "note":"Broek valt buiten de beschikbare maattabel"
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000004',
    null
  )$$,
  'inactieve gelijkblijvende locked maat blokkeert andere pakketcomponenten niet'
);
select is(
  (
    select selection_status::text
    from app.member_article_sizes
    where member_id = 'ea500000-0000-4000-8000-000000000001'
      and article_id = 'ea200000-0000-4000-8000-000000000001'
  ),
  'locked',
  'pakketbrede herbevestiging kan de uitgegeven component niet ontgrendelen'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';
select set_config(
  'test.package.revision',
  (
    public.get_parent_package_workspace_v2(repeat('a', 64))
      #>> '{members,0,revision}'
  ),
  true
);
select throws_ok(
  $$select public.confirm_parent_package_sizes_v5(
    repeat('a', 64),
    current_setting('test.package.member_season')::uuid,
    '[
      {
        "articleId":"ea200000-0000-4000-8000-000000000001",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000001",
        "note":null
      },
      {
        "articleId":"ea200000-0000-4000-8000-000000000002",
        "kind":"variant",
        "variantId":"ea300000-0000-4000-8000-000000000004",
        "note":null
      }
    ]'::jsonb,
    current_setting('test.package.revision'),
    'eaf10000-0000-4000-8000-000000000009',
    null
  )$$,
  '22023',
  'PACKAGE_SIZE_VARIANT_INVALID',
  'een andere inactieve variant kan niet als nieuwe maat worden gekozen'
);
update app.article_variants
set active = true
where id = 'ea300000-0000-4000-8000-000000000001';

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  gender
)
values(
  'ea500000-0000-4000-8000-000000000002',
  'PAKKET-002',
  'Mika',
  'Beheerkeuze',
  'mika-pakket@example.invalid',
  'JO15-1',
  'male'
);
select set_config(
  'test.package.staff_member_season',
  (
    select member_season.id::text
    from app.member_seasons member_season
    where member_season.member_id =
      'ea500000-0000-4000-8000-000000000002'
      and member_season.season_id =
        'ea100000-0000-4000-8000-000000000001'
  ),
  true
);
select set_config(
  'test.package.staff_revision',
  private.package_workspace_revision(
    current_setting('test.package.staff_member_season')::uuid
  ),
  true
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  (
    app.select_member_package_v3(
      current_setting('test.package.staff_member_season')::uuid,
      'ea410000-0000-4000-8000-000000000001',
      current_setting('test.package.staff_revision'),
      'Speler gekozen na controle met het lid',
      'eaf20000-0000-4000-8000-000000000001',
      'eaf30000-0000-4000-8000-000000000001'
    )->>'reused'
  ),
  'false',
  'eerste medewerker-pakketkeuze legt een nieuw duurzaam resultaat vast'
);
select is(
  (
    app.select_member_package_v3(
      current_setting('test.package.staff_member_season')::uuid,
      'ea410000-0000-4000-8000-000000000001',
      current_setting('test.package.staff_revision'),
      'Speler gekozen na controle met het lid',
      'eaf20000-0000-4000-8000-000000000001',
      'eaf30000-0000-4000-8000-000000000099'
    )->>'reused'
  ),
  'true',
  'retry met dezelfde medewerker-request-id hergebruikt de resultaatsnapshot'
);
select throws_ok(
  $$select app.select_member_package_v3(
    current_setting('test.package.staff_member_season')::uuid,
    'ea410000-0000-4000-8000-000000000002',
    current_setting('test.package.staff_revision'),
    'Keeper gekozen met botsende request-id',
    'eaf20000-0000-4000-8000-000000000001',
    null
  )$$,
  '23505',
  'PACKAGE_SELECTION_IDEMPOTENCY_CONFLICT',
  'dezelfde medewerker-request-id kan niet voor andere inhoud worden hergebruikt'
);
reset role;
select is(
  (
    select count(*)::integer
    from private.staff_package_selection_requests request
    where request.request_id =
      'eaf20000-0000-4000-8000-000000000001'
  ),
  1,
  'medewerker-pakketkeuze heeft exact één append-only ledgerrecord'
);
select is(
  (
    select audit.metadata->>'reason'
    from app.audit_logs audit
    where audit.action = 'package_order.selected'
      and audit.entity_id = (
        select orders.id
        from app.member_orders orders
        where orders.member_season_id =
          current_setting('test.package.staff_member_season')::uuid
      )
  ),
  'Speler gekozen na controle met het lid',
  'audit bewaart de verplichte beheerreden'
);

insert into app.payments(
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
)
select
  orders.id,
  'cash',
  'paid',
  orders.amount_due_cents,
  'package-change-paid-001',
  timezone('utc', now())
from app.member_orders orders
where orders.member_season_id =
  current_setting('test.package.staff_member_season')::uuid;

savepoint package_finance_v2_equal_price;
insert into app.package_templates(id,season_id,template_key,created_by)
values('ea400000-0000-4000-8000-000000000004','ea100000-0000-4000-8000-000000000001',
  'keeper-gelijke-prijs','ea000000-0000-4000-8000-000000000001');
insert into app.package_template_revisions(id,template_id,season_id,revision_number,name,
  description,price_cents,status,active,is_default,created_by,published_by,published_at)
values('ea410000-0000-4000-8000-000000000004','ea400000-0000-4000-8000-000000000004',
  'ea100000-0000-4000-8000-000000000001',1,'Keeper gelijk','Keeperpakket gelijke prijs',
  12500,'draft',false,false,'ea000000-0000-4000-8000-000000000001',null,null);
insert into app.package_template_items(id,revision_id,article_id,quantity,
  product_name_snapshot,product_code_snapshot,sort_order,season_id)
select case item.sort_order when 10 then 'ea420000-0000-4000-8000-000000000021'::uuid
    else 'ea420000-0000-4000-8000-000000000022'::uuid end,
  'ea410000-0000-4000-8000-000000000004'::uuid,item.article_id,item.quantity,
  item.product_name_snapshot,item.product_code_snapshot,item.sort_order,item.season_id
from app.package_template_items item
where item.revision_id='ea410000-0000-4000-8000-000000000002';
update app.package_template_revisions set status='published',active=true,
  published_by='ea000000-0000-4000-8000-000000000001',published_at=timezone('utc',now())
where id='ea410000-0000-4000-8000-000000000004';
select set_config('request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
set local role authenticated;
select set_config('test.package.finance_v2_equal',app.preflight_package_change_v2(
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid),
  'ea410000-0000-4000-8000-000000000004','Gelijk geprijsd keeperpakket corrigeren',
  'eaf40000-0000-4000-8000-000000000013',null)::text,true);
select is(current_setting('test.package.finance_v2_equal')::jsonb->>'creditAppliedCents','12500',
  'gelijk geprijsd pakket gebruikt exact de bestaande betaling als tegoed');
select is(current_setting('test.package.finance_v2_equal')::jsonb->>'additionalDueCents','0',
  'gelijk geprijsd pakket vraagt geen nieuwe betaling');
select is(current_setting('test.package.finance_v2_equal')::jsonb->>'refundDueCents','0',
  'gelijk geprijsd pakket maakt geen refundverplichting');
select set_config('test.package.finance_v2_equal_applied',app.apply_package_change_v2(
  'eaf40000-0000-4000-8000-000000000013',
  current_setting('test.package.finance_v2_equal')::jsonb->>'revision',
  'SWITCH_PACKAGE',null)::text,true);
reset role;
select is((select count(*)::integer from app.package_credit_allocations allocation
  where allocation.adjustment_id=(current_setting('test.package.finance_v2_equal_applied')::jsonb
    #>>'{result,adjustmentId}')::uuid),1,
  'gelijk geprijsde correctie legt exact één creditallocatie vast');
select is((select count(*)::integer from app.package_refunds refund
  where refund.adjustment_id=(current_setting('test.package.finance_v2_equal_applied')::jsonb
    #>>'{result,adjustmentId}')::uuid),0,
  'gelijk geprijsde correctie fabriceert geen refund');
select is((select count(*)::integer from app.payments payment where payment.order_id=
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid)),1,
  'gelijk geprijsde correctie maakt geen tweede betaling');
select is((select payment.amount_cents from app.payments payment
  where payment.idempotency_key='package-change-paid-001'),12500,
  'gelijk geprijsde correctie behoudt het historische betaalbedrag');

update app.payments set status='refunded',refunded_at=timezone('utc',now())
where idempotency_key='package-change-paid-001';
select set_config('request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
set local role authenticated;
select set_config('test.package.finance_v2_unhealthy_credit',app.preflight_package_change_v2(
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid),
  'ea410000-0000-4000-8000-000000000002','Ongezonde historische bron blokkeren',
  'eaf40000-0000-4000-8000-000000000014',null)::text,true);
select is(current_setting('test.package.finance_v2_unhealthy_credit')::jsonb->>'status','blocked',
  'een niet langer betaalde carried-creditbron blokkeert de preflight');
select is(current_setting('test.package.finance_v2_unhealthy_credit')::jsonb->>'creditAppliedCents','0',
  'een refunded historische bron wordt niet opnieuw als tegoed gedragen');
select is(current_setting('test.package.finance_v2_unhealthy_credit')::jsonb->>'blockedByReconciliation','true',
  'preflight maakt de ongezonde carried-creditbron expliciet zichtbaar als reconciliatieblokker');
select throws_ok(format($sql$select app.apply_package_change_v2(
  'eaf40000-0000-4000-8000-000000000014',%L,'SWITCH_PACKAGE',null)$sql$,
  current_setting('test.package.finance_v2_unhealthy_credit')::jsonb->>'revision'),
  '23514','PACKAGE_CHANGE_BLOCKED',
  'apply kan een preflight met ongezonde carried-creditbron niet omzeilen');
reset role;
rollback to savepoint package_finance_v2_equal_price;

savepoint package_finance_v2_more_expensive;
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select set_config(
  'test.package.finance_v2',
  app.preflight_package_change_v2(
    (select orders.id from app.member_orders orders where orders.member_season_id=
      current_setting('test.package.staff_member_season')::uuid),
    'ea410000-0000-4000-8000-000000000002',
    'Keeperpakket met alleen het prijsverschil',
    'eaf40000-0000-4000-8000-000000000011',
    'eaf30000-0000-4000-8000-000000000011'
  )::text,
  true
);
select is(current_setting('test.package.finance_v2')::jsonb->>'creditAppliedCents','12500',
  'v2 gebruikt de historische betaling als expliciet pakkettegoed');
select is(current_setting('test.package.finance_v2')::jsonb->>'additionalDueCents','2000',
  'v2 brengt uitsluitend het prijsverschil van het duurdere pakket in rekening');
select is(current_setting('test.package.finance_v2')::jsonb->>'refundDueCents','0',
  'v2 maakt bij een duurder pakket geen refundverplichting');
select lives_ok(format($sql$select app.apply_package_change_v2(
  'eaf40000-0000-4000-8000-000000000011',%L,'SWITCH_PACKAGE',
  'eaf30000-0000-4000-8000-000000000011')$sql$,
  current_setting('test.package.finance_v2')::jsonb->>'revision'),
  'v2 past een betaalde pakketcorrectie atomair toe');
reset role;
select is((select balance.remaining_due_cents from private.order_financial_balance(
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid)) balance),2000,
  'de canonieke actieve balans bevat na de correctie alleen 20 euro verschil');
select ok(not private.order_has_effective_paid_payment(
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid)),
  'een historische betaling maakt een duurdere pakketcorrectie niet volledig betaald');
select is((select payment.amount_cents from app.payments payment
  where payment.idempotency_key='package-change-paid-001'),12500,
  'de oorspronkelijke betaling en het oorspronkelijke bedrag blijven ongewijzigd');
rollback to savepoint package_finance_v2_more_expensive;

savepoint package_finance_v2_cheaper;
insert into app.package_templates(id,season_id,template_key,created_by)
values('ea400000-0000-4000-8000-000000000003','ea100000-0000-4000-8000-000000000001',
  'keeper-goedkoper','ea000000-0000-4000-8000-000000000001');
insert into app.package_template_revisions(id,template_id,season_id,revision_number,name,
  description,price_cents,status,active,is_default,created_by,published_by,published_at)
values('ea410000-0000-4000-8000-000000000003','ea400000-0000-4000-8000-000000000003',
  'ea100000-0000-4000-8000-000000000001',1,'Keeper compact','Keeperpakket goedkoper',
  10000,'draft',false,false,'ea000000-0000-4000-8000-000000000001',null,null);
insert into app.package_template_items(id,revision_id,article_id,quantity,
  product_name_snapshot,product_code_snapshot,sort_order,season_id)
select case item.sort_order when 10 then 'ea420000-0000-4000-8000-000000000011'::uuid
    else 'ea420000-0000-4000-8000-000000000012'::uuid end,
  'ea410000-0000-4000-8000-000000000003'::uuid,item.article_id,item.quantity,
  item.product_name_snapshot,item.product_code_snapshot,item.sort_order,item.season_id
from app.package_template_items item
where item.revision_id='ea410000-0000-4000-8000-000000000002';
update app.package_template_revisions set status='published',active=true,
  published_by='ea000000-0000-4000-8000-000000000001',published_at=timezone('utc',now())
where id='ea410000-0000-4000-8000-000000000003';
select set_config('request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
set local role authenticated;
select set_config('test.package.finance_v2_cheaper',app.preflight_package_change_v2(
  (select orders.id from app.member_orders orders where orders.member_season_id=
    current_setting('test.package.staff_member_season')::uuid),
  'ea410000-0000-4000-8000-000000000003','Goedkoper keeperpakket corrigeren',
  'eaf40000-0000-4000-8000-000000000012',null)::text,true);
select is(current_setting('test.package.finance_v2_cheaper')::jsonb->>'creditAppliedCents','10000',
  'goedkoper pakket gebruikt niet meer tegoed dan de nieuwe pakketprijs');
select is(current_setting('test.package.finance_v2_cheaper')::jsonb->>'refundDueCents','2500',
  'goedkoper pakket maakt exact het verschil als refund verschuldigd');
select set_config('test.package.finance_v2_cheaper_applied',app.apply_package_change_v2(
  'eaf40000-0000-4000-8000-000000000012',
  current_setting('test.package.finance_v2_cheaper')::jsonb->>'revision',
  'SWITCH_PACKAGE',null)::text,true);
reset role;
select is((select refund.status from app.package_refunds refund where refund.adjustment_id=
  (current_setting('test.package.finance_v2_cheaper_applied')::jsonb#>>'{result,adjustmentId}')::uuid),
  'manual_due','een kasbetaling wordt een zichtbare handmatige refundverplichting');
select set_config('request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
set local role authenticated;
select throws_ok(format($sql$select app.record_manual_payment_refund_v2(
  %L::uuid,%L::uuid,2500,'Extern terugbetaald','x','eaf50000-0000-4000-8000-000000000001',null)$sql$,
  current_setting('test.package.finance_v2_cheaper_applied')::jsonb#>>'{result,refunds,0,refundId}',
  current_setting('test.package.finance_v2_cheaper_applied')::jsonb#>>'{result,refunds,0,paymentId}'),
  '22023','INVALID_MANUAL_PAYMENT_REFUND','handmatige refund vereist een bruikbare bewijsreferentie');
select is((app.record_manual_payment_refund_v2(
  (current_setting('test.package.finance_v2_cheaper_applied')::jsonb#>>'{result,refunds,0,refundId}')::uuid,
  (current_setting('test.package.finance_v2_cheaper_applied')::jsonb#>>'{result,refunds,0,paymentId}')::uuid,
  2500,'Extern aan ouder terugbetaald','Kasbon K-2044-001',
  'eaf50000-0000-4000-8000-000000000001',null)->>'status'),
  'manual_completed','bewijs resolveert alleen de handmatige refundverplichting');
reset role;
select is((select payment.status::text from app.payments payment
  where payment.idempotency_key='package-change-paid-001'),'paid',
  'handmatige deelrefund herschrijft de historische betaling niet');
rollback to savepoint package_finance_v2_cheaper;

select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$
    select app.preflight_package_change_v1(
      (
        select orders.id
        from app.member_orders orders
        where orders.member_season_id =
          current_setting('test.package.staff_member_season')::uuid
      ),
      'ea410000-0000-4000-8000-000000000002',
      repeat('x', 481),
      'eaf40000-0000-4000-8000-000000000099',
      null
    )
  $$,
  '22023',
  'PACKAGE_CHANGE_INPUT_INVALID',
  'pakketwisselreden blijft inclusief voorraadprefix binnen de journaalgrens'
);
select is(
  (
    app.preflight_package_change_v1(
      (
        select orders.id
        from app.member_orders orders
        where orders.member_season_id =
          current_setting('test.package.staff_member_season')::uuid
      ),
      'ea410000-0000-4000-8000-000000000002',
      'Keeperpakket na betaalcorrectie',
      'eaf40000-0000-4000-8000-000000000001',
      null
    )->>'requiresExternalRefund'
  ),
  'true',
  'betaald pakket vereist aantoonbare externe betaaloplossing'
);
reset role;
select is(
  (
    select status::text
    from app.package_change_requests
    where id = 'eaf40000-0000-4000-8000-000000000001'
  ),
  'blocked',
  'betaalde pakketwijziging blijft duurzaam geblokkeerd'
);

update app.payments
set status = 'refunded',
    refunded_at = timezone('utc', now())
where idempotency_key = 'package-change-paid-001'
  and order_id = (
    select orders.id
    from app.member_orders orders
    where orders.member_season_id =
      current_setting('test.package.staff_member_season')::uuid
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select set_config(
  'test.package.change_ready',
  app.preflight_package_change_v1(
    (
      select orders.id
      from app.member_orders orders
      where orders.member_season_id =
        current_setting('test.package.staff_member_season')::uuid
    ),
    'ea410000-0000-4000-8000-000000000002',
    'Keeperpakket na betaalcorrectie',
    'eaf40000-0000-4000-8000-000000000002',
    null
  )::text,
  true
);
select is(
  current_setting('test.package.change_ready')::jsonb->>'canApply',
  'true',
  'gereconcilieerde refund maakt pakketwissel uitvoerbaar'
);
select is(
  (
    app.apply_package_change_v1(
      'eaf40000-0000-4000-8000-000000000002',
      current_setting('test.package.change_ready')::jsonb->>'revision',
      'SWITCH_PACKAGE',
      null
    ) #>> '{result,refundCreated}'
  ),
  'false',
  'pakketworkflow maakt nooit zelfstandig een refund'
);
select is(
  (
    app.apply_package_change_v1(
      'eaf40000-0000-4000-8000-000000000002',
      current_setting('test.package.change_ready')::jsonb->>'revision',
      'SWITCH_PACKAGE',
      null
    )->>'reused'
  ),
  'true',
  'pakketwissel is veilig idempotent bij een retry'
);
reset role;
select is(
  (
    select orders.package_revision_id
    from app.member_orders orders
    where orders.member_season_id =
      current_setting('test.package.staff_member_season')::uuid
  ),
  'ea410000-0000-4000-8000-000000000002'::uuid,
  'order gebruikt na workflow de gekozen keeperrevisie'
);
select ok(
  (
    select payment.package_snapshot_id
      <> orders.active_package_snapshot_id
    from app.payments payment
    join app.member_orders orders on orders.id = payment.order_id
    where payment.idempotency_key = 'package-change-paid-001'
  ),
  'oude betaling blijft aan de historische pakketsnapshot gebonden'
);
select is(
  (
    select audit.metadata->>'refundCreated'
    from app.audit_logs audit
    where audit.action = 'package_change.applied'
      and audit.entity_id = 'eaf40000-0000-4000-8000-000000000002'
  ),
  'false',
  'audit maakt expliciet dat geen automatische refund is aangemaakt'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $$select app.select_member_package_v3(
      %L::uuid,
      'ea410000-0000-4000-8000-000000000002',
      %L,
      'Commissie mag dit niet',
      'eaf20000-0000-4000-8000-000000000002',
      null
    )$$,
    current_setting('test.package.member_season'),
    current_setting('test.package.revision')
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan pakketten niet namens leden wisselen'
);
reset role;

select ok(
  not has_function_privilege(
    'authenticated',
    'app.select_member_package_v2(uuid,uuid,text,text,uuid)',
    'execute'
  ),
  'medewerkers kunnen de niet-idempotente pakketkeuzeversie niet uitvoeren'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.select_member_package_v3(uuid,uuid,text,text,uuid,uuid)',
    'execute'
  ),
  'alleen het finale idempotente medewerkercontract is gepubliceerd'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.preflight_package_change_v1(uuid,uuid,text,uuid,uuid)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'app.apply_package_change_v1(uuid,text,text,uuid)',
    'execute'
  ),
  'beheerflow is uitsluitend via MFA-gecontroleerde RPCs gepubliceerd'
);
select ok(
  not has_function_privilege(
    'service_role',
    'app.preflight_package_change_v1(uuid,uuid,text,uuid,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'app.apply_package_change_v1(uuid,text,text,uuid)',
    'execute'
  ),
  'service-role kan de beheer-MFA pakketcorrectie niet nabootsen'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.package_change_requests',
    'select'
  )
  and not has_table_privilege(
    'authenticated',
    'app.package_change_requests',
    'update'
  ),
  'pakketcorrectieledger is niet rechtstreeks leesbaar of wijzigbaar'
);
select ok(
  not has_function_privilege(
    'service_role',
    'app.select_member_package_v3(uuid,uuid,text,text,uuid,uuid)',
    'execute'
  ),
  'service-role kan de medewerker-MFA-mutatie niet nabootsen'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.get_parent_package_workspace_v2(text)',
    'execute'
  ),
  'medewerker-JWT kan het ouderworkspacecontract niet aanroepen'
);
select ok(
  not has_function_privilege(
    'service_role',
    'public.get_parent_package_workspace(text)',
    'execute'
  ),
  'service-role kan het verouderde ouderworkspacecontract niet aanroepen'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)',
    'execute'
  ),
  'medewerker-JWT kan geen ouderbevestiging nabootsen'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.package_size_confirmations',
    'insert'
  ),
  'confirmationledger is buiten de RPC append-only'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.member_article_sizes',
    'select'
  ),
  'maatprojectie met oudervelden is niet rechtstreeks leesbaar'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.package_size_change_requests',
    'select'
  ),
  'wijzigingsverzoeken zijn alleen via een rolgesneden RPC leesbaar'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.member_size_selection_history',
    'select'
  ),
  'maathistorie met vrije notities is niet rechtstreeks leesbaar'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.package_size_confirmations',
    'select'
  ),
  'ouderactor in confirmationledger is niet rechtstreeks leesbaar'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.package_size_confirmation_items',
    'select'
  ),
  'confirmationitems zijn niet rechtstreeks leesbaar'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.get_catalog_order_workspace_v4()',
    'execute'
  ),
  'anon kan de beheerworkspace niet uitvoeren'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.get_parent_package_workspace_v5(text)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'public.get_parent_package_workspace_v5(text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.get_parent_package_workspace_v5(text)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'public.get_parent_package_workspace_v4(text)',
    'execute'
  ),
  'alleen ouderworkspace v5 is uitsluitend via de serveradapter bereikbaar'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_catalog_order_workspace_v4()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan de beheerworkspace niet openen'
);
reset role;

select * from finish();
rollback;

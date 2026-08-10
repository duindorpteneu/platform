begin;

do $lock$
begin
  perform pg_advisory_xact_lock(hashtextextended('duindorp:mollie-acceptance-fixture', 0));
end
$lock$;

create temporary table mollie_acceptance_input (
  paid_member_id uuid not null,
  mismatch_member_id uuid not null,
  paid_order_id uuid not null,
  mismatch_order_id uuid not null,
  readiness_article_id uuid not null,
  readiness_variant_id uuid not null,
  readiness_order_line_id uuid not null,
  readiness_qr_request_id uuid not null,
  paid_relation text not null,
  mismatch_relation text not null,
  fixture_email text not null
) on commit drop;

insert into mollie_acceptance_input values (
  :'paid_member_id'::uuid,
  :'mismatch_member_id'::uuid,
  :'paid_order_id'::uuid,
  :'mismatch_order_id'::uuid,
  :'readiness_article_id'::uuid,
  :'readiness_variant_id'::uuid,
  :'readiness_order_line_id'::uuid,
  :'readiness_qr_request_id'::uuid,
  :'paid_relation',
  :'mismatch_relation',
  :'fixture_email'
);

do $fixture$
declare
  fixture_input mollie_acceptance_input%rowtype;
  fixture_season_id uuid;
  fixture_member_season_id uuid;
  fixture_marker text;
begin
  select * into strict fixture_input from mollie_acceptance_input;
  fixture_marker := regexp_replace(
    fixture_input.paid_relation,
    '^MOLLIE-(.+)-P$',
    '\1'
  );

  if fixture_input.paid_member_id = fixture_input.mismatch_member_id
    or fixture_input.paid_order_id = fixture_input.mismatch_order_id
    or cardinality(array[
      fixture_input.paid_member_id,
      fixture_input.mismatch_member_id,
      fixture_input.paid_order_id,
      fixture_input.mismatch_order_id,
      fixture_input.readiness_article_id,
      fixture_input.readiness_variant_id,
      fixture_input.readiness_order_line_id,
      fixture_input.readiness_qr_request_id
    ]) <> (
      select count(distinct identifier)
      from unnest(array[
        fixture_input.paid_member_id,
        fixture_input.mismatch_member_id,
        fixture_input.paid_order_id,
        fixture_input.mismatch_order_id,
        fixture_input.readiness_article_id,
        fixture_input.readiness_variant_id,
        fixture_input.readiness_order_line_id,
        fixture_input.readiness_qr_request_id
      ]) identifier
    )
    or fixture_input.paid_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-P$'
    or fixture_input.mismatch_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-M$'
    or fixture_input.fixture_email !~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(fixture_input.mismatch_relation, '^MOLLIE-(.+)-M$', '\1')
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(fixture_input.fixture_email, '^mollie-acceptance\+(.+)@example\.invalid$', '\1')
  then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select season.id into fixture_season_id
  from app.app_settings settings
  join app.seasons season
    on season.id = settings.active_season_id
   and season.status = 'open'
  where settings.id = true
    and settings.mollie_enabled = true
  for key share of settings, season;
  if fixture_season_id is null then
    raise exception 'STAGING_MOLLIE_CONFIGURATION_REQUIRED' using errcode = '23514';
  end if;

  if exists (
      select 1 from app.members member
      where member.id = fixture_input.paid_member_id
        and member.relation_number = fixture_input.paid_relation
        and member.email = fixture_input.fixture_email
    ) and exists (
      select 1 from app.members member
      where member.id = fixture_input.mismatch_member_id
        and member.relation_number = fixture_input.mismatch_relation
        and member.email = fixture_input.fixture_email
    ) and exists (
      select 1 from app.member_orders orders
      where orders.id = fixture_input.paid_order_id
        and orders.member_id = fixture_input.paid_member_id
        and orders.season_id = fixture_season_id
        and orders.amount_due_cents = 100
    ) and exists (
      select 1 from app.member_orders orders
      where orders.id = fixture_input.mismatch_order_id
        and orders.member_id = fixture_input.mismatch_member_id
        and orders.season_id = fixture_season_id
        and orders.amount_due_cents = 100
    ) and exists (
      select 1
      from app.articles article
      join app.article_seasons article_season
        on article_season.article_id = article.id
       and article_season.season_id = fixture_season_id
      join app.article_variants variant
        on variant.id = fixture_input.readiness_variant_id
       and variant.article_id = article.id
      where article.id = fixture_input.readiness_article_id
        and article.name = 'Mollie acceptance ' || fixture_marker
        and article.code = 'MOL-' || upper(substr(
          replace(fixture_input.readiness_article_id::text, '-', ''),
          1,
          12
        ))
        and variant.size = 'TEST-' || fixture_marker
    ) and exists (
      select 1
      from app.order_lines line
      where line.id = fixture_input.readiness_order_line_id
        and line.order_id = fixture_input.paid_order_id
        and line.article_id = fixture_input.readiness_article_id
        and line.article_variant_id = fixture_input.readiness_variant_id
        and line.quantity = 1
        and line.status = 'backorder'
    ) and exists (
      select 1
      from app.member_article_sizes size_choice
      join app.member_orders orders
        on orders.id = fixture_input.paid_order_id
       and orders.member_id = size_choice.member_id
       and orders.season_id = size_choice.season_id
       and orders.member_season_id = size_choice.member_season_id
      where size_choice.article_id = fixture_input.readiness_article_id
        and size_choice.article_variant_id = fixture_input.readiness_variant_id
        and size_choice.selection_status = 'confirmed'
        and size_choice.confirmed_at is not null
    )
  then
    return;
  end if;

  if exists (
    select 1 from app.members member
    where member.id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
      or member.relation_number in (fixture_input.paid_relation, fixture_input.mismatch_relation)
  ) or exists (
    select 1 from app.member_orders orders
    where orders.id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or exists (
    select 1 from app.articles article
    where article.id = fixture_input.readiness_article_id
      or lower(btrim(article.name)) = lower('Mollie acceptance ' || fixture_marker)
      or upper(btrim(article.code)) = upper('MOL-' || substr(
        replace(fixture_input.readiness_article_id::text, '-', ''),
        1,
        12
      ))
  ) or exists (
    select 1 from app.article_variants variant
    where variant.id = fixture_input.readiness_variant_id
  ) or exists (
    select 1 from app.order_lines line
    where line.id = fixture_input.readiness_order_line_id
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_FIXTURE_EXISTS' using errcode = '23505';
  end if;

  insert into app.members (
    id, relation_number, first_name, last_name, email, team, active_for_season
  ) values
    (
      fixture_input.paid_member_id,
      fixture_input.paid_relation,
      'Mollie',
      'Acceptance Paid',
      fixture_input.fixture_email,
      'MOLLIE-ACCEPTANCE',
      true
    ),
    (
      fixture_input.mismatch_member_id,
      fixture_input.mismatch_relation,
      'Mollie',
      'Acceptance Mismatch',
      fixture_input.fixture_email,
      'MOLLIE-ACCEPTANCE',
      true
    );

  insert into app.member_orders (id, member_id, season_id, amount_due_cents)
  values
    (fixture_input.paid_order_id, fixture_input.paid_member_id, fixture_season_id, 100),
    (fixture_input.mismatch_order_id, fixture_input.mismatch_member_id, fixture_season_id, 100);

  select member_season.id into strict fixture_member_season_id
  from app.member_seasons member_season
  where member_season.member_id = fixture_input.paid_member_id
    and member_season.season_id = fixture_season_id;

  insert into app.articles(id, name, code, icon_type, sort_order, active)
  values (
    fixture_input.readiness_article_id,
    'Mollie acceptance ' || fixture_marker,
    'MOL-' || upper(substr(
      replace(fixture_input.readiness_article_id::text, '-', ''),
      1,
      12
    )),
    'package',
    10000,
    true
  );
  insert into app.article_seasons(article_id, season_id)
  values(fixture_input.readiness_article_id, fixture_season_id);
  insert into app.article_variants(
    id,
    article_id,
    size,
    sku,
    sort_order,
    active
  ) values (
    fixture_input.readiness_variant_id,
    fixture_input.readiness_article_id,
    'TEST-' || fixture_marker,
    null,
    10000,
    true
  );
  insert into app.order_lines(
    id,
    order_id,
    article_variant_id,
    quantity
  ) values (
    fixture_input.readiness_order_line_id,
    fixture_input.paid_order_id,
    fixture_input.readiness_variant_id,
    1
  );
  if not exists (
    select 1
    from app.member_article_sizes size_choice
    where size_choice.member_id = fixture_input.paid_member_id
      and size_choice.season_id = fixture_season_id
      and size_choice.member_season_id = fixture_member_season_id
      and size_choice.article_id = fixture_input.readiness_article_id
      and size_choice.article_variant_id = fixture_input.readiness_variant_id
      and size_choice.selection_status = 'confirmed'
      and size_choice.confirmed_at is not null
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_SIZE_FIXTURE_INVALID'
      using errcode = '23514';
  end if;
end
$fixture$;

select jsonb_build_object('prepared', true);
commit;

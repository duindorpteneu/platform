-- Phase B expand migration.
--
-- This migration is deliberately additive. Existing member, order, payment,
-- inventory and fulfilment columns remain the compatibility source while the
-- feature flags below are disabled. No package or catalog business fixtures are
-- created and legacy orders are never classified as player/keeper packages.

do $$ begin
  create type app.gender_code as enum ('male', 'female', 'other', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.member_season_status as enum ('active', 'inactive', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.member_season_reconciliation as enum ('resolved', 'legacy_unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.size_selection_status as enum (
    'imported_unconfirmed',
    'confirmed',
    'conflict',
    'change_requested',
    'locked'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.size_selection_source as enum ('legacy', 'import', 'parent', 'staff', 'order');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.package_revision_status as enum ('draft', 'published', 'archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.parent_grant_status as enum ('pending_account', 'review_required', 'active', 'revoked');
exception when duplicate_object then null; end $$;

create table app.release_feature_flags (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{2,63}$'),
  enabled boolean not null default false,
  description text not null check (length(trim(description)) between 1 and 240),
  updated_by uuid,
  updated_at timestamptz not null default timezone('utc', now())
);

insert into app.release_feature_flags(key, description) values
  ('member_seasons_v2', 'Explicit member-season reads and writes'),
  ('package_orders_v2', 'Package template and immutable package-order workflow'),
  ('dynamic_import_v2', 'Mapped and retained dynamic Sportlink import'),
  ('parent_access_grants_v2', 'Administrator-managed member-season portal grants'),
  ('allocation_qr_v2', 'Allocation-gated QR exchange and issuance'),
  ('mail_templates_v2', 'Versioned TipTap mail templates and reminders'),
  ('scanner_pwa_v2', 'Network-only installable scanner surface'),
  ('legacy_card_payment', 'Legacy manual card registration compatibility')
on conflict (key) do nothing;

alter table app.release_feature_flags enable row level security;

create policy "operations can read release flags" on app.release_feature_flags
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke all on table app.release_feature_flags from public, anon, authenticated;
grant select on table app.release_feature_flags to authenticated;

alter table app.members
  add column gender app.gender_code not null default 'unknown';

create table private.member_sensitive_identity (
  member_id uuid primary key references app.members(id) on delete cascade,
  date_of_birth date,
  source_import_batch_id uuid references app.import_batches(id) on delete set null,
  updated_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint member_sensitive_identity_date_check
    check (date_of_birth is null or date_of_birth between date '1900-01-01' and current_date)
);

insert into private.member_sensitive_identity(member_id)
select id from app.members
on conflict (member_id) do nothing;

alter table private.member_sensitive_identity enable row level security;
revoke all on table private.member_sensitive_identity from public, anon, authenticated, service_role;

create table app.member_external_identities (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.members(id) on delete cascade,
  issuer text not null check (issuer ~ '^[a-z][a-z0-9_-]{1,39}$'),
  external_id text not null check (length(trim(external_id)) between 1 and 120),
  external_id_normalized text not null check (
    length(trim(external_id_normalized)) between 1 and 120
    and external_id_normalized = upper(trim(external_id_normalized))
  ),
  is_primary boolean not null default true,
  verified_at timestamptz not null default timezone('utc', now()),
  source_import_batch_id uuid references app.import_batches(id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (issuer, external_id_normalized)
);

create unique index member_external_identities_one_primary_idx
  on app.member_external_identities(member_id, issuer) where is_primary;

insert into app.member_external_identities(
  member_id,
  issuer,
  external_id,
  external_id_normalized,
  source_import_batch_id
)
select member.id, 'sportlink', member.relation_number, upper(trim(member.relation_number)),
  member.imported_from_batch_id
from app.members member
join (
  select upper(trim(relation_number)) normalized
  from app.members
  group by upper(trim(relation_number))
  having count(*) = 1
) unambiguous on unambiguous.normalized = upper(trim(member.relation_number));

alter table app.member_external_identities enable row level security;
create policy "clothing staff can read external identities" on app.member_external_identities
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
revoke all on table app.member_external_identities from public, anon, authenticated;
grant select on table app.member_external_identities to authenticated;

create table app.member_seasons (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.members(id) on delete cascade
    deferrable initially deferred,
  season_id uuid not null references app.seasons(id) on delete restrict,
  team_name text,
  participation_status app.member_season_status not null default 'unknown',
  reconciliation_status app.member_season_reconciliation not null default 'legacy_unknown',
  source_import_batch_id uuid references app.import_batches(id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (member_id, season_id),
  unique (id, member_id, season_id),
  constraint member_seasons_team_check
    check (team_name is null or length(trim(team_name)) between 1 and 120),
  constraint member_seasons_resolved_check
    check (
      reconciliation_status = 'legacy_unknown'
      or (team_name is not null and participation_status <> 'unknown')
    )
);

with pairs as (
  select member.id member_id, settings.active_season_id season_id, true is_current
  from app.members member
  cross join app.app_settings settings
  where settings.id = true and settings.active_season_id is not null
  union
  select orders.member_id, orders.season_id, false from app.member_orders orders
  union
  select sizes.member_id, sizes.season_id, false from app.member_article_sizes sizes
),
collapsed as (
  select member_id, season_id, bool_or(is_current) is_current
  from pairs
  group by member_id, season_id
)
insert into app.member_seasons(
  member_id,
  season_id,
  team_name,
  participation_status,
  reconciliation_status,
  source_import_batch_id
)
select member.id, collapsed.season_id,
  case when collapsed.is_current then member.team else null end,
  case
    when not collapsed.is_current then 'unknown'::app.member_season_status
    when member.active_for_season then 'active'::app.member_season_status
    else 'inactive'::app.member_season_status
  end,
  case
    when collapsed.is_current then 'resolved'::app.member_season_reconciliation
    else 'legacy_unknown'::app.member_season_reconciliation
  end,
  case when collapsed.is_current then member.imported_from_batch_id else null end
from collapsed
join app.members member on member.id = collapsed.member_id;

do $$
begin
  execute 'set constraints all immediate';
end;
$$;

create index member_seasons_season_status_idx
  on app.member_seasons(season_id, participation_status, member_id);

alter table app.member_seasons enable row level security;
create policy "clothing staff can read member seasons" on app.member_seasons
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
revoke all on table app.member_seasons from public, anon, authenticated;
grant select on table app.member_seasons to authenticated;

alter table app.member_orders
  add column member_season_id uuid,
  add column package_revision_id uuid,
  add column active_package_snapshot_id uuid;

alter table app.member_article_sizes
  add column member_season_id uuid,
  add column selection_status app.size_selection_status not null default 'confirmed',
  add column selection_source app.size_selection_source not null default 'legacy',
  add column raw_value text,
  add column member_note text,
  add column confirmed_at timestamptz,
  add column confirmed_by uuid;

update app.member_orders orders
set member_season_id = member_season.id
from app.member_seasons member_season
where member_season.member_id = orders.member_id
  and member_season.season_id = orders.season_id;

update app.member_article_sizes sizes
set member_season_id = member_season.id,
    confirmed_at = coalesce(sizes.updated_at, sizes.created_at)
from app.member_seasons member_season
where member_season.member_id = sizes.member_id
  and member_season.season_id = sizes.season_id;

alter table app.member_orders
  alter column member_season_id set not null,
  add constraint member_orders_member_season_fkey
    foreign key (member_season_id, member_id, season_id)
    references app.member_seasons(id, member_id, season_id)
    on delete restrict
    deferrable initially immediate
    not valid;

alter table app.member_orders validate constraint member_orders_member_season_fkey;

alter table app.member_article_sizes
  alter column member_season_id set not null,
  alter column article_variant_id drop not null,
  add constraint member_article_sizes_member_season_fkey
    foreign key (member_season_id, member_id, season_id)
    references app.member_seasons(id, member_id, season_id)
    on delete restrict
    deferrable initially immediate
    not valid,
  add constraint member_article_sizes_selection_check check (
    (
      selection_status in ('imported_unconfirmed', 'confirmed', 'change_requested', 'locked')
      and article_variant_id is not null
      and raw_value is null
    )
    or (
      selection_status = 'conflict'
      and article_variant_id is null
      and raw_value is not null
      and length(trim(raw_value)) between 1 and 160
      and (selection_source <> 'parent' or length(trim(coalesce(member_note, ''))) between 1 and 500)
    )
  ) not valid;

alter table app.member_article_sizes
  validate constraint member_article_sizes_member_season_fkey;
alter table app.member_article_sizes
  validate constraint member_article_sizes_selection_check;

create table app.package_templates (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references app.seasons(id) on delete restrict,
  template_key text not null check (template_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  created_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  unique (season_id, template_key),
  unique (id, season_id)
);

create table app.package_template_revisions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null,
  season_id uuid not null,
  revision_number integer not null check (revision_number > 0),
  name text not null check (length(trim(name)) between 1 and 120),
  description text not null default '' check (length(description) <= 2000),
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'EUR' check (currency = 'EUR'),
  status app.package_revision_status not null default 'draft',
  active boolean not null default false,
  is_default boolean not null default false,
  created_by uuid,
  published_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  published_at timestamptz,
  foreign key (template_id, season_id)
    references app.package_templates(id, season_id) on delete restrict,
  unique (template_id, revision_number),
  unique (id, season_id),
  constraint package_revision_lifecycle_check check (
    (status = 'draft' and not active and not is_default and published_at is null)
    or (status = 'published' and published_at is not null and (not is_default or active))
    or (status = 'archived' and not active and not is_default and published_at is not null)
  )
);

create unique index package_template_revisions_one_active_idx
  on app.package_template_revisions(template_id) where active;
create unique index package_template_revisions_one_default_idx
  on app.package_template_revisions(season_id) where active and is_default;

create table app.package_template_items (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references app.package_template_revisions(id) on delete restrict,
  article_id uuid not null references app.articles(id) on delete restrict,
  quantity integer not null check (quantity between 1 and 25),
  product_name_snapshot text not null check (length(trim(product_name_snapshot)) between 1 and 120),
  product_code_snapshot text not null check (length(trim(product_code_snapshot)) between 1 and 24),
  sort_order integer not null default 0 check (sort_order between 0 and 10000),
  created_at timestamptz not null default timezone('utc', now()),
  unique (revision_id, article_id),
  unique (id, article_id)
);

create table app.order_package_snapshots (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  sequence integer not null check (sequence > 0),
  template_revision_id uuid,
  package_name text not null check (length(trim(package_name)) between 1 and 120),
  package_description text not null default '' check (length(package_description) <= 2000),
  package_price_cents integer not null check (package_price_cents >= 0),
  currency text not null default 'EUR' check (currency = 'EUR'),
  revision_label text not null check (length(trim(revision_label)) between 1 and 80),
  snapshot_origin text not null check (snapshot_origin in ('legacy', 'template', 'admin_change')),
  reason text,
  created_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  foreign key (order_id) references app.member_orders(id) on delete cascade
    deferrable initially deferred,
  foreign key (template_revision_id) references app.package_template_revisions(id) on delete restrict,
  unique (order_id, sequence),
  unique (id, order_id)
);

create table app.order_package_snapshot_items (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references app.order_package_snapshots(id) on delete cascade,
  template_item_id uuid references app.package_template_items(id) on delete restrict,
  order_line_id uuid,
  article_id uuid not null references app.articles(id) on delete restrict,
  article_variant_id uuid,
  quantity integer not null check (quantity between 1 and 25),
  product_name_snapshot text not null check (length(trim(product_name_snapshot)) between 1 and 120),
  product_code_snapshot text not null check (length(trim(product_code_snapshot)) between 1 and 24),
  variant_label_snapshot text,
  size_snapshot text,
  sort_order integer not null default 0 check (sort_order between 0 and 10000),
  created_at timestamptz not null default timezone('utc', now()),
  unique (snapshot_id, article_id),
  unique (snapshot_id, order_line_id)
);

alter table app.order_lines
  add column package_template_item_id uuid,
  add column product_name_snapshot text,
  add column product_code_snapshot text;

update app.order_lines line
set product_name_snapshot = article.name,
    product_code_snapshot = article.code
from app.articles article
where article.id = line.article_id;

alter table app.order_lines
  alter column product_name_snapshot set not null,
  alter column product_code_snapshot set not null,
  add constraint order_lines_package_item_article_fkey
    foreign key (package_template_item_id, article_id)
    references app.package_template_items(id, article_id)
    on delete restrict
    not valid;

alter table app.order_lines validate constraint order_lines_package_item_article_fkey;

insert into app.order_package_snapshots(
  id,
  order_id,
  member_season_id,
  sequence,
  package_name,
  package_price_cents,
  currency,
  revision_label,
  snapshot_origin,
  reason
)
select gen_random_uuid(), orders.id, orders.member_season_id, 1, 'Legacy tenue',
  orders.amount_due_cents, 'EUR', 'legacy-v1', 'legacy',
  'Forward-only backfill van de bestaande losse bestelling'
from app.member_orders orders;

insert into app.order_package_snapshot_items(
  snapshot_id,
  order_line_id,
  article_id,
  article_variant_id,
  quantity,
  product_name_snapshot,
  product_code_snapshot,
  variant_label_snapshot,
  size_snapshot,
  sort_order
)
select snapshot.id, line.id, line.article_id, line.article_variant_id, line.quantity,
  line.product_name_snapshot, line.product_code_snapshot, line.size_snapshot,
  line.size_snapshot, article.sort_order
from app.order_package_snapshots snapshot
join app.order_lines line on line.order_id = snapshot.order_id and line.status <> 'cancelled'
join app.articles article on article.id = line.article_id
where snapshot.sequence = 1;

update app.member_orders orders
set active_package_snapshot_id = snapshot.id
from app.order_package_snapshots snapshot
where snapshot.order_id = orders.id and snapshot.sequence = 1;

do $$
begin
  execute 'set constraints all immediate';
end;
$$;

alter table app.member_orders
  alter column active_package_snapshot_id set not null,
  add constraint member_orders_package_revision_fkey
    foreign key (package_revision_id, season_id)
    references app.package_template_revisions(id, season_id)
    on delete restrict
    not valid,
  add constraint member_orders_active_snapshot_fkey
    foreign key (active_package_snapshot_id, id)
    references app.order_package_snapshots(id, order_id)
    on delete restrict
    deferrable initially deferred
    not valid;

alter table app.member_orders validate constraint member_orders_package_revision_fkey;
alter table app.member_orders validate constraint member_orders_active_snapshot_fkey;

alter table app.fulfilment_lines
  add column product_name_snapshot text,
  add column article_variant_id_snapshot uuid,
  add column size_snapshot text;

update app.fulfilment_lines fulfilment_line
set product_name_snapshot = order_line.product_name_snapshot,
    article_variant_id_snapshot = order_line.article_variant_id,
    size_snapshot = order_line.size_snapshot
from app.order_lines order_line
where order_line.id = fulfilment_line.order_line_id;

alter table app.fulfilment_lines
  alter column product_name_snapshot set not null,
  alter column article_variant_id_snapshot set not null,
  alter column size_snapshot set not null;

create table private.parent_portal_grants (
  id uuid primary key default gen_random_uuid(),
  member_season_id uuid not null references app.member_seasons(id) on delete cascade,
  email_normalized text not null check (
    email_normalized = lower(trim(email_normalized))
    and length(email_normalized) between 3 and 254
  ),
  parent_account_id uuid references private.parent_accounts(id) on delete restrict,
  status app.parent_grant_status not null,
  source text not null check (source in ('legacy_review', 'administrator')),
  legacy_link_id uuid unique references private.parent_member_links(id) on delete set null,
  granted_by uuid,
  granted_at timestamptz,
  revoked_by uuid,
  revoked_at timestamptz,
  revoked_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint parent_portal_grants_lifecycle_check check (
    (status = 'active' and parent_account_id is not null and granted_by is not null and granted_at is not null
      and revoked_at is null and revoked_reason is null)
    or (status in ('pending_account', 'review_required') and revoked_at is null and revoked_reason is null)
    or (status = 'revoked' and revoked_at is not null and length(trim(revoked_reason)) between 1 and 500)
  )
);

create unique index parent_portal_grants_open_email_idx
  on private.parent_portal_grants(member_season_id, email_normalized)
  where status in ('pending_account', 'review_required', 'active');

insert into private.parent_portal_grants(
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  legacy_link_id
)
select member_season.id, account.email_normalized, account.id, 'review_required',
  'legacy_review', link.id
from private.parent_member_links link
join private.parent_accounts account on account.id = link.parent_account_id
join app.app_settings settings on settings.id = true
join app.member_seasons member_season
  on member_season.member_id = link.member_id
  and member_season.season_id = settings.active_season_id
where link.unlinked_at is null
on conflict (legacy_link_id) do nothing;

alter table private.parent_portal_grants enable row level security;
revoke all on table private.parent_portal_grants from public, anon, authenticated, service_role;

alter table app.package_templates enable row level security;
alter table app.package_template_revisions enable row level security;
alter table app.package_template_items enable row level security;
alter table app.order_package_snapshots enable row level security;
alter table app.order_package_snapshot_items enable row level security;

create policy "clothing staff can read package templates" on app.package_templates
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "clothing staff can read package revisions" on app.package_template_revisions
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "clothing staff can read package template items" on app.package_template_items
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "clothing staff can read order package snapshots" on app.order_package_snapshots
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "clothing staff can read order package items" on app.order_package_snapshot_items
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke all on table app.package_templates from public, anon, authenticated;
revoke all on table app.package_template_revisions from public, anon, authenticated;
revoke all on table app.package_template_items from public, anon, authenticated;
revoke all on table app.order_package_snapshots from public, anon, authenticated;
revoke all on table app.order_package_snapshot_items from public, anon, authenticated;
grant select on table app.package_templates to authenticated;
grant select on table app.package_template_revisions to authenticated;
grant select on table app.package_template_items to authenticated;
grant select on table app.order_package_snapshots to authenticated;
grant select on table app.order_package_snapshot_items to authenticated;

create or replace function private.ensure_member_season(
  p_member_id uuid,
  p_season_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result uuid;
  active_season uuid;
  target_member app.members%rowtype;
  is_current boolean;
begin
  select id into result
  from app.member_seasons
  where member_id = p_member_id and season_id = p_season_id;
  if result is not null then return result; end if;

  select active_season_id into active_season
  from app.app_settings where id = true;
  is_current := active_season is not distinct from p_season_id;

  select * into target_member from app.members where id = p_member_id;

  insert into app.member_seasons(
    member_id,
    season_id,
    team_name,
    participation_status,
    reconciliation_status,
    source_import_batch_id
  )
  values(
    p_member_id,
    p_season_id,
    case when found and is_current then target_member.team else null end,
    case
      when not found or not is_current then 'unknown'::app.member_season_status
      when target_member.active_for_season then 'active'::app.member_season_status
      else 'inactive'::app.member_season_status
    end,
    case
      when found and is_current then 'resolved'::app.member_season_reconciliation
      else 'legacy_unknown'::app.member_season_reconciliation
    end,
    case when found and is_current then target_member.imported_from_batch_id else null end
  )
  on conflict (member_id, season_id) do update
  set team_name = case
        when excluded.reconciliation_status = 'resolved' then excluded.team_name
        else app.member_seasons.team_name
      end,
      participation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.participation_status
        else app.member_seasons.participation_status
      end,
      reconciliation_status = case
        when excluded.reconciliation_status = 'resolved' then excluded.reconciliation_status
        else app.member_seasons.reconciliation_status
      end,
      source_import_batch_id = coalesce(excluded.source_import_batch_id, app.member_seasons.source_import_batch_id),
      updated_at = timezone('utc', now())
  returning id into result;
  return result;
end;
$$;

create or replace function app.sync_member_phase_b_compatibility()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare active_season uuid;
begin
  insert into private.member_sensitive_identity(member_id)
  values(new.id)
  on conflict (member_id) do nothing;

  insert into app.member_external_identities(
    member_id,
    issuer,
    external_id,
    external_id_normalized,
    source_import_batch_id
  )
  values(
    new.id,
    'sportlink',
    new.relation_number,
    upper(trim(new.relation_number)),
    new.imported_from_batch_id
  )
  on conflict (issuer, external_id_normalized) do update
  set external_id = excluded.external_id,
      source_import_batch_id = excluded.source_import_batch_id
  where app.member_external_identities.member_id = excluded.member_id;

  if not found then
    raise exception 'MEMBER_EXTERNAL_IDENTITY_CONFLICT' using errcode = '23505';
  end if;

  select active_season_id into active_season
  from app.app_settings where id = true;
  if active_season is not null then
    perform private.ensure_member_season(new.id, active_season);
  end if;
  return new;
end;
$$;

create trigger members_phase_b_compatibility
after insert or update of relation_number, team, active_for_season, imported_from_batch_id on app.members
for each row execute function app.sync_member_phase_b_compatibility();

create or replace function app.fill_member_season_reference()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  new.member_season_id := coalesce(
    new.member_season_id,
    private.ensure_member_season(new.member_id, new.season_id)
  );
  return new;
end;
$$;

create trigger member_orders_fill_member_season
before insert or update of member_id, season_id, member_season_id on app.member_orders
for each row execute function app.fill_member_season_reference();

create or replace function app.fill_size_member_season_reference()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  new.member_season_id := coalesce(
    new.member_season_id,
    private.ensure_member_season(new.member_id, new.season_id)
  );
  return new;
end;
$$;

create trigger member_article_sizes_fill_member_season
before insert or update of member_id, season_id, member_season_id on app.member_article_sizes
for each row execute function app.fill_size_member_season_reference();

create or replace function app.sync_member_size_from_order_line()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_season_id uuid;
  target_member_season_id uuid;
  existing_size app.member_article_sizes%rowtype;
begin
  if new.status = 'cancelled' then return new; end if;

  select orders.member_id, orders.season_id, orders.member_season_id
  into target_member_id, target_season_id, target_member_season_id
  from app.member_orders orders
  where orders.id = new.order_id;

  if not exists(
    select 1 from app.article_seasons link
    where link.article_id = new.article_id and link.season_id = target_season_id
  ) then
    return new;
  end if;

  select * into existing_size
  from app.member_article_sizes
  where member_id = target_member_id
    and season_id = target_season_id
    and article_id = new.article_id
  for update;

  if found and existing_size.article_variant_id is distinct from new.article_variant_id
    and existing_size.selection_status in ('confirmed', 'change_requested', 'locked')
  then
    raise exception 'CONFIRMED_SIZE_CHANGE_REQUIRES_WORKFLOW' using errcode = '23514';
  end if;
  if found and existing_size.selection_status = 'conflict' then
    raise exception 'SIZE_CONFLICT_MUST_BE_RESOLVED' using errcode = '23514';
  end if;

  insert into app.member_article_sizes(
    member_id,
    season_id,
    member_season_id,
    article_id,
    article_variant_id,
    selection_status,
    selection_source,
    confirmed_at,
    created_by,
    updated_by
  )
  values(
    target_member_id,
    target_season_id,
    target_member_season_id,
    new.article_id,
    new.article_variant_id,
    'confirmed',
    'order',
    timezone('utc', now()),
    auth.uid(),
    auth.uid()
  )
  on conflict(member_id, season_id, article_id) do update
  set article_variant_id = excluded.article_variant_id,
      selection_status = 'confirmed',
      selection_source = 'order',
      raw_value = null,
      member_note = null,
      confirmed_at = excluded.confirmed_at,
      confirmed_by = auth.uid(),
      updated_by = auth.uid(),
      updated_at = timezone('utc', now())
  where app.member_article_sizes.selection_status = 'imported_unconfirmed'
    or app.member_article_sizes.article_variant_id = excluded.article_variant_id;
  return new;
end;
$$;

create or replace function app.protect_package_revision_content()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if old.status <> 'draft' and (
    new.template_id is distinct from old.template_id
    or new.season_id is distinct from old.season_id
    or new.revision_number is distinct from old.revision_number
    or new.name is distinct from old.name
    or new.description is distinct from old.description
    or new.price_cents is distinct from old.price_cents
    or new.currency is distinct from old.currency
  ) then
    raise exception 'PUBLISHED_PACKAGE_REVISION_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger package_revisions_protect_content
before update on app.package_template_revisions
for each row execute function app.protect_package_revision_content();

create or replace function app.protect_published_package_items()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare revision_status app.package_revision_status;
begin
  select status into revision_status
  from app.package_template_revisions
  where id = case when tg_op = 'DELETE' then old.revision_id else new.revision_id end;
  if revision_status <> 'draft' then
    raise exception 'PUBLISHED_PACKAGE_ITEMS_IMMUTABLE' using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger package_items_protect_published
before insert or update or delete on app.package_template_items
for each row execute function app.protect_published_package_items();

create or replace function app.sync_order_line_article()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare
  resolved_article_id uuid;
  resolved_size text;
  resolved_name text;
  resolved_code text;
begin
  select variant.article_id, variant.size, article.name, article.code
  into resolved_article_id, resolved_size, resolved_name, resolved_code
  from app.article_variants variant
  join app.articles article on article.id = variant.article_id
  where variant.id = new.article_variant_id;

  if resolved_article_id is null then
    raise exception 'ARTICLE_VARIANT_NOT_FOUND' using errcode = '23503';
  end if;
  if new.article_id is not null and new.article_id <> resolved_article_id then
    raise exception 'ORDER_LINE_ARTICLE_VARIANT_MISMATCH' using errcode = '23514';
  end if;

  new.article_id := resolved_article_id;
  if tg_op = 'INSERT'
    or new.article_variant_id is distinct from old.article_variant_id
    or new.size_snapshot is null
  then
    new.size_snapshot := resolved_size;
    new.product_name_snapshot := resolved_name;
    new.product_code_snapshot := resolved_code;
  else
    new.product_name_snapshot := coalesce(new.product_name_snapshot, old.product_name_snapshot);
    new.product_code_snapshot := coalesce(new.product_code_snapshot, old.product_code_snapshot);
  end if;
  return new;
end;
$$;

drop trigger if exists order_lines_sync_article on app.order_lines;
create trigger order_lines_sync_article
before insert or update of article_variant_id, article_id on app.order_lines
for each row execute function app.sync_order_line_article();

create or replace function private.next_package_snapshot_sequence(p_order_id uuid)
returns integer
language sql
security definer
set search_path = app, private, pg_temp
as $$
  select coalesce(max(sequence), 0) + 1
  from app.order_package_snapshots
  where order_id = p_order_id;
$$;

create or replace function private.create_order_package_snapshot(
  p_order_id uuid,
  p_member_season_id uuid,
  p_season_id uuid,
  p_amount_due_cents integer,
  p_package_revision_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result uuid := gen_random_uuid();
  next_sequence integer;
  revision app.package_template_revisions%rowtype;
begin
  next_sequence := private.next_package_snapshot_sequence(p_order_id);

  if p_package_revision_id is null then
    insert into app.order_package_snapshots(
      id,
      order_id,
      member_season_id,
      sequence,
      package_name,
      package_price_cents,
      currency,
      revision_label,
      snapshot_origin,
      reason,
      created_by
    )
    values(
      result,
      p_order_id,
      p_member_season_id,
      next_sequence,
      'Legacy tenue',
      p_amount_due_cents,
      'EUR',
      'legacy-v1',
      'legacy',
      p_reason,
      auth.uid()
    );
  else
    select * into revision
    from app.package_template_revisions
    where id = p_package_revision_id
      and season_id = p_season_id
      and status = 'published'
      and active = true;
    if not found then
      raise exception 'PACKAGE_REVISION_NOT_AVAILABLE' using errcode = '23514';
    end if;
    if revision.price_cents <> p_amount_due_cents then
      raise exception 'PACKAGE_PRICE_MISMATCH' using errcode = '23514';
    end if;

    insert into app.order_package_snapshots(
      id,
      order_id,
      member_season_id,
      sequence,
      template_revision_id,
      package_name,
      package_description,
      package_price_cents,
      currency,
      revision_label,
      snapshot_origin,
      reason,
      created_by
    )
    values(
      result,
      p_order_id,
      p_member_season_id,
      next_sequence,
      revision.id,
      revision.name,
      revision.description,
      revision.price_cents,
      revision.currency,
      'revision-' || revision.revision_number::text,
      'template',
      p_reason,
      auth.uid()
    );

    insert into app.order_package_snapshot_items(
      snapshot_id,
      template_item_id,
      article_id,
      quantity,
      product_name_snapshot,
      product_code_snapshot,
      sort_order
    )
    select result, item.id, item.article_id, item.quantity,
      item.product_name_snapshot, item.product_code_snapshot, item.sort_order
    from app.package_template_items item
    where item.revision_id = revision.id;
  end if;

  return result;
end;
$$;

create or replace function app.prepare_order_package_snapshot()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot_id uuid;
begin
  if tg_op = 'INSERT' then
    snapshot_id := private.create_order_package_snapshot(
      new.id,
      new.member_season_id,
      new.season_id,
      new.amount_due_cents,
      new.package_revision_id,
      case when new.package_revision_id is null
        then 'Compatibilitysnapshot bij legacy orderaanmaak'
        else 'Pakketsnapshot bij orderaanmaak'
      end
    );
    new.active_package_snapshot_id := snapshot_id;
    return new;
  end if;

  if new.package_revision_id is distinct from old.package_revision_id
    or new.amount_due_cents is distinct from old.amount_due_cents
  then
    if exists (
      select 1 from app.payments
      where order_id = old.id and status in ('paid', 'refunded', 'duplicate_paid')
    ) or exists (
      select 1 from app.inventory_reservations reservation
      join app.order_lines line on line.id = reservation.order_line_id
      where line.order_id = old.id and reservation.status in ('reserved', 'fulfilled')
    ) then
      raise exception 'PACKAGE_ORDER_CHANGE_REQUIRES_ADMIN_WORKFLOW' using errcode = '23514';
    end if;

    snapshot_id := private.create_order_package_snapshot(
      new.id,
      new.member_season_id,
      new.season_id,
      new.amount_due_cents,
      new.package_revision_id,
      'Nieuwe commerciële snapshot na wijziging vóór betaling/reservering'
    );

    if new.package_revision_id is null then
      insert into app.order_package_snapshot_items(
        snapshot_id,
        order_line_id,
        article_id,
        article_variant_id,
        quantity,
        product_name_snapshot,
        product_code_snapshot,
        variant_label_snapshot,
        size_snapshot,
        sort_order
      )
      select snapshot_id, line.id, line.article_id, line.article_variant_id, line.quantity,
        line.product_name_snapshot, line.product_code_snapshot, line.size_snapshot,
        line.size_snapshot, article.sort_order
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = new.id and line.status <> 'cancelled';
    end if;
    new.active_package_snapshot_id := snapshot_id;
  elsif new.active_package_snapshot_id is distinct from old.active_package_snapshot_id
    and current_setting('app.package_snapshot_internal', true) is distinct from 'on'
  then
    raise exception 'ACTIVE_PACKAGE_SNAPSHOT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger member_orders_prepare_package_snapshot
before insert or update of amount_due_cents, package_revision_id, active_package_snapshot_id on app.member_orders
for each row execute function app.prepare_order_package_snapshot();

create or replace function app.refresh_legacy_package_snapshot_from_lines()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order_id uuid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
  target_order app.member_orders%rowtype;
  snapshot_id uuid;
begin
  select * into target_order
  from app.member_orders
  where id = target_order_id
  for update;
  if not found or target_order.package_revision_id is not null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  snapshot_id := private.create_order_package_snapshot(
    target_order.id,
    target_order.member_season_id,
    target_order.season_id,
    target_order.amount_due_cents,
    null,
    'Nieuwe legacy snapshot na wijziging van bestelregels'
  );

  insert into app.order_package_snapshot_items(
    snapshot_id,
    order_line_id,
    article_id,
    article_variant_id,
    quantity,
    product_name_snapshot,
    product_code_snapshot,
    variant_label_snapshot,
    size_snapshot,
    sort_order
  )
  select snapshot_id, line.id, line.article_id, line.article_variant_id, line.quantity,
    line.product_name_snapshot, line.product_code_snapshot, line.size_snapshot,
    line.size_snapshot, article.sort_order
  from app.order_lines line
  join app.articles article on article.id = line.article_id
  where line.order_id = target_order.id and line.status <> 'cancelled';

  perform set_config('app.package_snapshot_internal', 'on', true);
  update app.member_orders
  set active_package_snapshot_id = snapshot_id
  where id = target_order.id;
  perform set_config('app.package_snapshot_internal', 'off', true);
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger zz_order_lines_refresh_package_snapshot
after insert or update of article_variant_id, article_id, quantity, status or delete on app.order_lines
for each row execute function app.refresh_legacy_package_snapshot_from_lines();

create or replace function app.fill_fulfilment_line_snapshots()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
begin
  select line.product_name_snapshot, line.article_variant_id, line.size_snapshot
  into new.product_name_snapshot, new.article_variant_id_snapshot, new.size_snapshot
  from app.order_lines line
  where line.id = new.order_line_id;
  if new.product_name_snapshot is null then
    raise exception 'FULFILMENT_ORDER_LINE_NOT_FOUND' using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger fulfilment_lines_fill_snapshots
before insert on app.fulfilment_lines
for each row execute function app.fill_fulfilment_line_snapshots();

create or replace function app.sync_legacy_parent_grant()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  member_season uuid;
  account_email text;
  active_season uuid;
begin
  if new.unlinked_at is not null then
    update private.parent_portal_grants
    set status = 'revoked',
        revoked_at = coalesce(revoked_at, timezone('utc', now())),
        revoked_reason = coalesce(revoked_reason, 'Legacykoppeling ingetrokken'),
        updated_at = timezone('utc', now())
    where legacy_link_id = new.id and status <> 'revoked';
    return new;
  end if;

  select settings.active_season_id into active_season
  from app.app_settings settings where settings.id = true;
  if active_season is null then return new; end if;

  select id into member_season
  from app.member_seasons
  where member_id = new.member_id and season_id = active_season;
  select email_normalized into account_email
  from private.parent_accounts where id = new.parent_account_id;
  if member_season is null or account_email is null then return new; end if;

  insert into private.parent_portal_grants(
    member_season_id,
    email_normalized,
    parent_account_id,
    status,
    source,
    legacy_link_id
  )
  values(member_season, account_email, new.parent_account_id, 'review_required', 'legacy_review', new.id)
  on conflict (legacy_link_id) do update
  set email_normalized = excluded.email_normalized,
      parent_account_id = excluded.parent_account_id,
      status = 'review_required',
      revoked_at = null,
      revoked_reason = null,
      updated_at = timezone('utc', now());
  return new;
end;
$$;

create trigger parent_member_links_sync_review_grant
after insert or update of unlinked_at, parent_account_id, member_id on private.parent_member_links
for each row execute function app.sync_legacy_parent_grant();

create or replace function app.get_member_detail_v3(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  target_role app.staff_role;
begin
  result := app.get_member_detail_v2(p_member_id);
  target_role := app.staff_role();
  return result || jsonb_build_object(
    'gender', (select member.gender::text from app.members member where member.id = p_member_id),
    'dateOfBirth', case when target_role = 'beheerder' then (
      select identity.date_of_birth
      from private.member_sensitive_identity identity
      where identity.member_id = p_member_id
    ) else null end,
    'memberSeasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', member_season.id,
        'seasonId', member_season.season_id,
        'seasonName', season.name,
        'team', member_season.team_name,
        'participationStatus', member_season.participation_status::text,
        'reconciliationStatus', member_season.reconciliation_status::text
      ) order by season.starts_on desc nulls last, season.name desc)
      from app.member_seasons member_season
      join app.seasons season on season.id = member_season.season_id
      where member_season.member_id = p_member_id
    ), '[]'::jsonb)
  );
end;
$$;

drop function if exists public.get_parent_members(text);
create function public.get_parent_members(p_token_hash text)
returns table (
  member_id uuid,
  relation_number text,
  first_name text,
  insertion text,
  last_name text,
  team text,
  order_id uuid,
  amount_due_cents integer,
  payment_status text,
  order_status text,
  article_lines jsonb,
  qr_version integer,
  date_of_birth date,
  gender text,
  season_id uuid,
  season_name text
)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select member.id, member.relation_number, member.first_name, member.insertion, member.last_name,
    member_season.team_name,
    orders.id, orders.amount_due_cents,
    coalesce((
      select payment.status::text
      from app.payments payment
      where payment.order_id = orders.id
      order by case payment.status
        when 'paid' then 1
        when 'refunded' then 2
        when 'duplicate_paid' then 3
        else 4
      end, payment.created_at desc
      limit 1
    ), 'open'),
    orders.order_status,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id,
        'article', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', line.status::text
      ) order by article.sort_order, line.size_snapshot)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status <> 'cancelled'
    ), '[]'::jsonb),
    (select token.version
      from private.qr_tokens token
      where token.order_id = orders.id and token.active = true
      limit 1),
    identity.date_of_birth,
    member.gender::text,
    member_season.season_id,
    season.name
  from private.parent_sessions session
  join private.parent_member_links link
    on link.parent_account_id = session.parent_account_id and link.unlinked_at is null
  join app.app_settings settings on settings.id = true
  join app.member_seasons member_season
    on member_season.member_id = link.member_id
    and member_season.season_id = settings.active_season_id
    and member_season.participation_status = 'active'
  join app.members member on member.id = member_season.member_id
  join app.seasons season on season.id = member_season.season_id
  left join private.member_sensitive_identity identity on identity.member_id = member.id
  left join app.member_orders orders
    on orders.member_season_id = member_season.id
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now());
$$;

create or replace function public.get_parent_candidates(p_token_hash text)
returns table (
  member_id uuid,
  relation_number text,
  first_name text,
  insertion text,
  last_name text,
  team text
)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select member.id, member.relation_number, member.first_name, member.insertion,
    member.last_name, member_season.team_name
  from private.parent_sessions session
  join private.parent_portal_grants grant_row
    on grant_row.parent_account_id = session.parent_account_id
    and grant_row.status = 'active'
  join app.member_seasons member_season on member_season.id = grant_row.member_season_id
  join app.members member on member.id = member_season.member_id
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and false;
$$;

create or replace function public.link_parent_member(p_token_hash text, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  if not exists(
    select 1 from public.get_parent_session(p_token_hash)
  ) then
    raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501';
  end if;
  raise exception 'PORTAL_ACCESS_ADMIN_REQUIRED' using errcode = '42501';
end;
$$;

create or replace function public.unlink_parent_member(p_token_hash text, p_link_id uuid)
returns boolean
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
begin
  if not exists(
    select 1 from public.get_parent_session(p_token_hash)
  ) then
    raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501';
  end if;
  raise exception 'PORTAL_ACCESS_ADMIN_REQUIRED' using errcode = '42501';
end;
$$;

revoke all on function private.ensure_member_season(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app.sync_member_phase_b_compatibility() from public, anon, authenticated;
revoke all on function app.fill_member_season_reference() from public, anon, authenticated;
revoke all on function app.fill_size_member_season_reference() from public, anon, authenticated;
revoke all on function app.protect_package_revision_content() from public, anon, authenticated;
revoke all on function app.protect_published_package_items() from public, anon, authenticated;
revoke all on function private.next_package_snapshot_sequence(uuid) from public, anon, authenticated, service_role;
revoke all on function private.create_order_package_snapshot(uuid,uuid,uuid,integer,uuid,text)
  from public, anon, authenticated, service_role;
revoke all on function app.prepare_order_package_snapshot() from public, anon, authenticated;
revoke all on function app.refresh_legacy_package_snapshot_from_lines() from public, anon, authenticated;
revoke all on function app.fill_fulfilment_line_snapshots() from public, anon, authenticated;
revoke all on function app.sync_legacy_parent_grant() from public, anon, authenticated;
revoke all on function app.get_member_detail_v3(uuid) from public, anon;
revoke all on function public.get_parent_members(text) from public, anon, authenticated;
revoke all on function public.get_parent_candidates(text) from public, anon, authenticated;
revoke all on function public.link_parent_member(text, uuid) from public, anon, authenticated;
revoke all on function public.unlink_parent_member(text, uuid) from public, anon, authenticated;
grant execute on function app.get_member_detail_v3(uuid) to authenticated;
grant execute on function public.get_parent_members(text) to service_role;
grant execute on function public.get_parent_candidates(text) to service_role;
grant execute on function public.link_parent_member(text, uuid) to service_role;
grant execute on function public.unlink_parent_member(text, uuid) to service_role;

create table private.migration_reconciliations (
  migration_key text primary key,
  status text not null check (status in ('passed', 'failed')),
  metrics jsonb not null,
  reconciled_at timestamptz not null default timezone('utc', now())
);
alter table private.migration_reconciliations enable row level security;
revoke all on table private.migration_reconciliations from public, anon, authenticated, service_role;

do $$
declare
  order_count bigint;
  line_count bigint;
  member_count bigint;
  missing_order_links bigint;
  missing_size_links bigint;
  missing_order_snapshots bigint;
  mismatched_prices bigint;
  missing_line_snapshots bigint;
begin
  select count(*) into member_count from app.members;
  select count(*) into order_count from app.member_orders;
  select count(*) into line_count from app.order_lines where status <> 'cancelled';
  select count(*) into missing_order_links
  from app.member_orders orders
  left join app.member_seasons member_season
    on member_season.id = orders.member_season_id
    and member_season.member_id = orders.member_id
    and member_season.season_id = orders.season_id
  where member_season.id is null;
  select count(*) into missing_size_links
  from app.member_article_sizes sizes
  left join app.member_seasons member_season
    on member_season.id = sizes.member_season_id
    and member_season.member_id = sizes.member_id
    and member_season.season_id = sizes.season_id
  where member_season.id is null;
  select count(*) into missing_order_snapshots
  from app.member_orders orders
  left join app.order_package_snapshots snapshot
    on snapshot.id = orders.active_package_snapshot_id
    and snapshot.order_id = orders.id
  where snapshot.id is null;
  select count(*) into mismatched_prices
  from app.member_orders orders
  join app.order_package_snapshots snapshot on snapshot.id = orders.active_package_snapshot_id
  where snapshot.package_price_cents <> orders.amount_due_cents
    or snapshot.currency <> 'EUR';
  select count(*) into missing_line_snapshots
  from app.order_lines line
  where line.product_name_snapshot is null or line.product_code_snapshot is null;

  if missing_order_links <> 0 or missing_size_links <> 0
    or missing_order_snapshots <> 0 or mismatched_prices <> 0
    or missing_line_snapshots <> 0
    or (select count(*) from private.member_sensitive_identity) <> member_count
    or (select count(*) from app.order_package_snapshot_items item
        join app.order_package_snapshots snapshot on snapshot.id = item.snapshot_id
        join app.member_orders orders on orders.active_package_snapshot_id = snapshot.id
        where item.order_line_id is not null) <> line_count
  then
    raise exception 'PHASE_B_EXPAND_RECONCILIATION_FAILED' using errcode = '23514';
  end if;

  insert into private.migration_reconciliations(migration_key, status, metrics)
  values(
    '20260802180000_phase_b_domain_expand',
    'passed',
    jsonb_build_object(
      'members', member_count,
      'orders', order_count,
      'activeOrderLines', line_count,
      'memberSeasons', (select count(*) from app.member_seasons),
      'legacyPackageSnapshots', order_count,
      'unresolvedHistoricalMemberSeasons', (
        select count(*) from app.member_seasons
        where reconciliation_status = 'legacy_unknown'
      )
    )
  );
end;
$$;

select pg_notify('pgrst', 'reload schema');

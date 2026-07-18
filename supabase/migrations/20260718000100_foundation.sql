create schema if not exists app;
create schema if not exists private;

create extension if not exists pgcrypto;

do $$ begin
  create type app.staff_role as enum ('beheerder', 'kledingcommissie', 'uitgifte');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.season_status as enum ('open', 'archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.import_status as enum ('preview', 'committed', 'failed');
exception when duplicate_object then null; end $$;

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create table if not exists app.app_settings (
  id boolean primary key default true check (id),
  club_name text not null default 'Duindorp SV',
  contact_email text,
  pickup_location text,
  active_season_id uuid,
  mollie_enabled boolean not null default false,
  email_enabled boolean not null default false,
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  starts_on date,
  ends_on date,
  default_amount_cents integer not null check (default_amount_cents >= 0),
  status app.season_status not null default 'open',
  opened_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

alter table app.app_settings
  drop constraint if exists app_settings_active_season_id_fkey;
alter table app.app_settings
  add constraint app_settings_active_season_id_fkey
  foreign key (active_season_id) references app.seasons(id) on delete set null;

create table if not exists app.staff_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  display_name text not null,
  role app.staff_role not null,
  active boolean not null default true,
  last_login_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create or replace function app.is_staff_member()
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select exists (
    select 1 from app.staff_profiles
    where auth_user_id = auth.uid() and active = true
  );
$$;

create or replace function app.staff_role()
returns app.staff_role
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select role from app.staff_profiles
  where auth_user_id = auth.uid() and active = true
  limit 1;
$$;

create table if not exists app.import_batches (
  id uuid primary key default gen_random_uuid(),
  file_name text not null,
  checksum text not null,
  mapping jsonb not null default '{}'::jsonb,
  actor_user_id uuid not null,
  row_counts jsonb not null default '{}'::jsonb,
  status app.import_status not null default 'preview',
  created_at timestamptz not null default timezone('utc', now()),
  committed_at timestamptz
);

create table if not exists app.members (
  id uuid primary key default gen_random_uuid(),
  relation_number text not null unique,
  first_name text not null,
  insertion text,
  last_name text not null,
  email text not null,
  team text not null,
  active_for_season boolean not null default true,
  imported_from_batch_id uuid references app.import_batches(id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index if not exists members_email_idx on app.members (lower(email));
create index if not exists members_team_idx on app.members (team);

create table if not exists app.articles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.article_variants (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references app.articles(id) on delete restrict,
  size text not null,
  sku text,
  active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  unique (article_id, size)
);

create trigger seasons_touch_updated_at before update on app.seasons
for each row execute function app.touch_updated_at();
create trigger staff_profiles_touch_updated_at before update on app.staff_profiles
for each row execute function app.touch_updated_at();
create trigger members_touch_updated_at before update on app.members
for each row execute function app.touch_updated_at();
create trigger articles_touch_updated_at before update on app.articles
for each row execute function app.touch_updated_at();

alter table app.app_settings enable row level security;
alter table app.seasons enable row level security;
alter table app.staff_profiles enable row level security;
alter table app.import_batches enable row level security;
alter table app.members enable row level security;
alter table app.articles enable row level security;
alter table app.article_variants enable row level security;

create policy "staff can read settings" on app.app_settings
for select using (app.is_staff_member());
create policy "admins can manage settings" on app.app_settings
for all using (app.staff_role() = 'beheerder') with check (app.staff_role() = 'beheerder');

create policy "staff can read seasons" on app.seasons
for select using (app.is_staff_member());
create policy "admins can manage seasons" on app.seasons
for all using (app.staff_role() = 'beheerder') with check (app.staff_role() = 'beheerder');

create policy "staff can read own profile" on app.staff_profiles
for select using (auth_user_id = auth.uid() or app.is_staff_member());
create policy "admins manage profiles" on app.staff_profiles
for all using (app.staff_role() = 'beheerder') with check (app.staff_role() = 'beheerder');

create policy "staff can read imports" on app.import_batches
for select using (app.is_staff_member());
create policy "operations can create imports" on app.import_batches
for insert with check (app.staff_role() in ('beheerder', 'kledingcommissie') and actor_user_id = auth.uid());

create policy "staff can read members" on app.members
for select using (app.is_staff_member());
create policy "operations can manage members" on app.members
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "staff can read articles" on app.articles
for select using (app.is_staff_member());
create policy "operations can manage articles" on app.articles
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "staff can read variants" on app.article_variants
for select using (app.is_staff_member());
create policy "operations can manage variants" on app.article_variants
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

grant usage on schema app to authenticated;
grant select, insert, update, delete on all tables in schema app to authenticated;
revoke all on schema private from anon, authenticated;

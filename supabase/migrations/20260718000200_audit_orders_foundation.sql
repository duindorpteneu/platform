do $$ begin
  create type app.order_line_status as enum ('backorder', 'ready_for_pickup', 'picked_up');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_status as enum ('open', 'pending', 'paid', 'failed', 'canceled', 'expired', 'refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.payment_method as enum ('mollie', 'cash', 'card');
exception when duplicate_object then null; end $$;

create table if not exists app.member_orders (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.members(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  amount_due_cents integer not null check (amount_due_cents >= 0),
  order_status text not null default 'Nog niet betaald',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (member_id, season_id)
);

create table if not exists app.order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  article_variant_id uuid not null references app.article_variants(id) on delete restrict,
  quantity integer not null default 1 check (quantity > 0),
  status app.order_line_status not null default 'backorder',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  method app.payment_method not null,
  status app.payment_status not null default 'open',
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null default 'EUR' check (currency = 'EUR'),
  provider_payment_id text unique,
  idempotency_key text not null unique,
  paid_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists payments_one_paid_order_idx
  on app.payments(order_id) where status = 'paid';

create table if not exists app.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists member_orders_status_idx on app.member_orders (order_status);
create index if not exists order_lines_status_idx on app.order_lines (status);
create index if not exists audit_logs_created_at_idx on app.audit_logs (created_at desc);

create trigger member_orders_touch_updated_at before update on app.member_orders
for each row execute function app.touch_updated_at();
create trigger order_lines_touch_updated_at before update on app.order_lines
for each row execute function app.touch_updated_at();
create trigger payments_touch_updated_at before update on app.payments
for each row execute function app.touch_updated_at();

alter table app.member_orders enable row level security;
alter table app.order_lines enable row level security;
alter table app.payments enable row level security;
alter table app.audit_logs enable row level security;

create policy "staff can read orders" on app.member_orders
for select using (app.is_staff_member());
create policy "operations can manage orders" on app.member_orders
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "staff can read order lines" on app.order_lines
for select using (app.is_staff_member());
create policy "operations can manage order lines" on app.order_lines
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "staff can read payments" on app.payments
for select using (app.is_staff_member());
create policy "operations can manage payments" on app.payments
for all using (app.staff_role() in ('beheerder', 'kledingcommissie'))
with check (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read audit" on app.audit_logs
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "staff can append audit" on app.audit_logs
for insert with check (app.is_staff_member() and actor_user_id = auth.uid());

revoke update, delete on app.audit_logs from authenticated;

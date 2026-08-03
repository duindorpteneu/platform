-- Generic mail-v2 domain events and automatic producers.
--
-- Events contain only the minimum private render snapshot. Recipient addresses,
-- DOB, relation numbers, OTP values, QR secrets and free-form member notes are
-- deliberately excluded. Projection and delivery are introduced by a later
-- forward migration so producer transactions never need provider access.

alter table app.package_size_confirmations
  add column package_snapshot_id uuid;

update app.package_size_confirmations confirmation
set package_snapshot_id = (
  select min(item.snapshot_id::text)::uuid
  from app.package_size_confirmation_items confirmation_item
  join app.order_package_snapshot_items item
    on item.id = confirmation_item.snapshot_item_id
  where confirmation_item.confirmation_id = confirmation.id
)
where confirmation.package_snapshot_id is null
  and 1 = (
    select count(distinct item.snapshot_id)
    from app.package_size_confirmation_items confirmation_item
    join app.order_package_snapshot_items item
      on item.id = confirmation_item.snapshot_item_id
    where confirmation_item.confirmation_id = confirmation.id
  );

alter table app.package_size_confirmations
  add constraint package_size_confirmations_snapshot_order_fkey
    foreign key (package_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id)
    on delete restrict
    not valid;

alter table app.package_size_confirmations
  validate constraint package_size_confirmations_snapshot_order_fkey;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
)
select
  '20260802271000_mail_v2_confirmation_snapshots',
  case when count(*) = 0 then 'passed' else 'failed' end,
  jsonb_build_object(
    'unresolvedConfirmationSnapshots',
    count(*)
  )
from app.package_size_confirmations confirmation
where confirmation.package_snapshot_id is null
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = timezone('utc', now());

create or replace function private.bind_package_size_confirmation_snapshot()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  expected_snapshot_id uuid;
begin
  select orders.active_package_snapshot_id into expected_snapshot_id
  from app.member_orders orders
  where orders.id = new.order_id
    and orders.member_season_id = new.member_season_id;
  if expected_snapshot_id is null then
    raise exception 'PACKAGE_CONFIRMATION_SNAPSHOT_REQUIRED'
      using errcode = '23514';
  end if;
  if new.package_snapshot_id is not null
    and new.package_snapshot_id <> expected_snapshot_id
  then
    raise exception 'PACKAGE_CONFIRMATION_SNAPSHOT_MISMATCH'
      using errcode = '23514';
  end if;
  new.package_snapshot_id := expected_snapshot_id;
  return new;
end;
$$;

create trigger package_size_confirmations_bind_snapshot
before insert on app.package_size_confirmations
for each row execute function
  private.bind_package_size_confirmation_snapshot();

create or replace function private.protect_package_confirmation_snapshot()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if new.package_snapshot_id is distinct from old.package_snapshot_id then
    raise exception 'PACKAGE_CONFIRMATION_SNAPSHOT_IMMUTABLE'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger package_size_confirmations_snapshot_immutable
before update on app.package_size_confirmations
for each row execute function
  private.protect_package_confirmation_snapshot();

revoke all on function private.bind_package_size_confirmation_snapshot()
from public, anon, authenticated, service_role;
revoke all on function private.protect_package_confirmation_snapshot()
from public, anon, authenticated, service_role;

alter table app.package_size_confirmation_items
  add column size_label_snapshot text;

do $$
begin
  if exists(
    select 1
    from app.package_size_confirmation_items confirmation_item
    left join app.article_variants variant
      on variant.id = confirmation_item.selected_variant_id
      and variant.article_id = confirmation_item.article_id
    where confirmation_item.selection_kind = 'variant'
      and variant.id is null
  ) then
    raise exception 'PACKAGE_CONFIRMATION_VARIANT_HISTORY_UNRESOLVED'
      using errcode = '23514';
  end if;
end;
$$;

alter table app.package_size_confirmation_items
  disable trigger package_size_confirmation_items_immutable;
update app.package_size_confirmation_items confirmation_item
set size_label_snapshot = case
  when confirmation_item.selection_kind = 'other' then 'Anders…'
  else (
    select variant.size
    from app.article_variants variant
    where variant.id = confirmation_item.selected_variant_id
      and variant.article_id = confirmation_item.article_id
  )
end
where confirmation_item.size_label_snapshot is null;
alter table app.package_size_confirmation_items
  enable trigger package_size_confirmation_items_immutable;

alter table app.package_size_confirmation_items
  alter column size_label_snapshot set not null,
  add constraint package_size_confirmation_items_label_snapshot_check check (
    length(btrim(size_label_snapshot)) between 1 and 80
    and size_label_snapshot !~ '[[:cntrl:]]'
    and size_label_snapshot !~* '(token|secret|otp|email)'
  ) not valid;

alter table app.package_size_confirmation_items
  validate constraint package_size_confirmation_items_label_snapshot_check;

create or replace function private.bind_package_confirmation_size_label()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  selected_label text;
  confirmation_snapshot_id uuid;
  item_snapshot_id uuid;
begin
  select confirmation.package_snapshot_id into confirmation_snapshot_id
  from app.package_size_confirmations confirmation
  where confirmation.id = new.confirmation_id;
  select snapshot_item.snapshot_id into item_snapshot_id
  from app.order_package_snapshot_items snapshot_item
  where snapshot_item.id = new.snapshot_item_id;
  if confirmation_snapshot_id is null
    or item_snapshot_id is null
    or confirmation_snapshot_id <> item_snapshot_id
  then
    raise exception 'PACKAGE_CONFIRMATION_ITEM_SNAPSHOT_MISMATCH'
      using errcode = '23514';
  end if;
  if new.selection_kind = 'other' then
    selected_label := 'Anders…';
  else
    select variant.size into selected_label
    from app.article_variants variant
    where variant.id = new.selected_variant_id
      and variant.article_id = new.article_id;
  end if;
  if selected_label is null then
    raise exception 'PACKAGE_CONFIRMATION_SIZE_LABEL_REQUIRED'
      using errcode = '23514';
  end if;
  if new.size_label_snapshot is not null
    and new.size_label_snapshot <> selected_label
  then
    raise exception 'PACKAGE_CONFIRMATION_SIZE_LABEL_MISMATCH'
      using errcode = '23514';
  end if;
  new.size_label_snapshot := selected_label;
  return new;
end;
$$;

create trigger package_size_confirmation_items_bind_label
before insert on app.package_size_confirmation_items
for each row execute function
  private.bind_package_confirmation_size_label();

revoke all on function private.bind_package_confirmation_size_label()
from public, anon, authenticated, service_role;

do $$
begin
  if exists(
    select 1
    from app.package_size_confirmation_items confirmation_item
    join app.package_size_confirmations confirmation
      on confirmation.id = confirmation_item.confirmation_id
    join app.order_package_snapshot_items snapshot_item
      on snapshot_item.id = confirmation_item.snapshot_item_id
    where confirmation.package_snapshot_id is not null
      and confirmation.package_snapshot_id <> snapshot_item.snapshot_id
  ) then
    raise exception 'PACKAGE_CONFIRMATION_ITEM_HISTORY_MISMATCH'
      using errcode = '23514';
  end if;
end;
$$;

create or replace function private.mail_templates_v2_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from app.release_feature_flags flag
    join private.release_cutovers cutover on cutover.key = flag.key
    where flag.key = 'mail_templates_v2'
      and flag.enabled
  );
$$;

revoke all on function private.mail_templates_v2_enabled()
from public, anon, authenticated, service_role;

create or replace function private.mail_templates_v2_cutover_started()
returns boolean
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select exists(
    select 1
    from private.release_cutovers cutover
    where cutover.key = 'mail_templates_v2'
  );
$$;

revoke all on function private.mail_templates_v2_cutover_started()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_payload_keys_are_safe(
  p_payload jsonb
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  with recursive values_to_scan(value) as (
    select p_payload
    union all
    select child.value
    from values_to_scan parent
    cross join lateral (
      select object_value value
      from jsonb_each(
        case
          when jsonb_typeof(parent.value) = 'object'
          then parent.value
          else '{}'::jsonb
        end
      ) object_child(object_key, object_value)
      union all
      select array_value
      from jsonb_array_elements(
        case
          when jsonb_typeof(parent.value) = 'array'
          then parent.value
          else '[]'::jsonb
        end
      ) array_child(array_value)
    ) child
  ),
  object_keys as (
    select object_key
    from values_to_scan node
    cross join lateral jsonb_object_keys(
      case
        when jsonb_typeof(node.value) = 'object'
        then node.value
        else '{}'::jsonb
      end
    ) keys(object_key)
  )
  select p_payload is not null
    and jsonb_typeof(p_payload) = 'object'
    and octet_length(p_payload::text) between 2 and 50000
    and not exists(
      select 1
      from object_keys
      where lower(regexp_replace(
        object_key,
        '[^a-zA-Z0-9]',
        '',
        'g'
      )) ~ (
        'email|dateofbirth|dob|relationnumber|token|secret|'
        || 'otp|qr|rawvalue|membernote|othernote|password'
      )
    );
$$;

revoke all on function private.mail_v2_payload_keys_are_safe(jsonb)
from public, anon, authenticated, service_role;

create table private.mail_v2_domain_events (
  id uuid primary key default gen_random_uuid(),
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  parent_account_id uuid
    references private.parent_accounts(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  member_season_id uuid
    references app.member_seasons(id) on delete restrict,
  order_id uuid references app.member_orders(id) on delete restrict,
  order_line_id uuid references app.order_lines(id) on delete restrict,
  source_type text not null check (
    source_type ~ '^[a-z][a-z0-9_]{1,63}$'
  ),
  source_id uuid not null,
  cohort_id uuid,
  idempotency_key text not null unique check (
    length(idempotency_key) between 12 and 300
    and idempotency_key ~ '^[a-z0-9:_-]+$'
  ),
  payload_snapshot jsonb not null check (
    private.mail_v2_payload_keys_are_safe(payload_snapshot)
  ),
  created_at timestamptz not null default timezone('utc', now()),
  constraint mail_v2_domain_events_context_check check (
    (
      template_key = 'internal_email_failure'
      and parent_account_id is null
      and member_season_id is null
      and order_id is null
      and order_line_id is null
    )
    or (
      template_key not in (
        'internal_email_failure',
        'login_otp',
        'partial_pickup',
        'package_complete'
      )
      and parent_account_id is not null
      and member_season_id is not null
    )
  )
);

create index mail_v2_domain_events_projection_idx
  on private.mail_v2_domain_events(
    template_key,
    season_id,
    parent_account_id,
    created_at,
    id
  );
create index mail_v2_domain_events_member_idx
  on private.mail_v2_domain_events(
    member_season_id,
    template_key,
    created_at desc
  )
  where member_season_id is not null;
create index mail_v2_domain_events_order_idx
  on private.mail_v2_domain_events(
    order_id,
    template_key,
    created_at desc
  )
  where order_id is not null;
create index mail_v2_domain_events_line_idx
  on private.mail_v2_domain_events(
    order_line_id,
    template_key,
    created_at desc
  )
  where order_line_id is not null;

alter table private.mail_v2_domain_events enable row level security;
revoke all on private.mail_v2_domain_events
from public, anon, authenticated, service_role;

create or replace function private.reject_mail_v2_domain_event_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'MAIL_V2_DOMAIN_EVENT_IMMUTABLE' using errcode = '55000';
end;
$$;

create trigger mail_v2_domain_events_immutable
before update or delete on private.mail_v2_domain_events
for each row execute function
  private.reject_mail_v2_domain_event_mutation();

revoke all on function private.reject_mail_v2_domain_event_mutation()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_size_segment(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with target as (
    select orders.id, orders.member_season_id,
      orders.active_package_snapshot_id
    from app.member_orders orders
    where orders.id = p_order_id
      and orders.active_package_snapshot_id is not null
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = orders.id
          and line.status <> 'cancelled'
      )
  ),
  state as (
    select
      count(*)::integer item_count,
      count(*) filter (
        where size_profile.member_season_id is null
          or (
            size_profile.selection_status = 'conflict'
            and not (
              size_profile.selection_source = 'parent'
              and size_profile.confirmed_at is not null
              and length(btrim(coalesce(size_profile.member_note, '')))
                between 1 and 500
            )
          )
      )::integer fill_count,
      count(*) filter (
        where size_profile.selection_status = 'imported_unconfirmed'
      )::integer review_count
    from target
    join app.order_package_snapshot_items item
      on item.snapshot_id = target.active_package_snapshot_id
    left join app.member_article_sizes size_profile
      on size_profile.member_season_id = target.member_season_id
      and size_profile.article_id = item.article_id
  )
  select case
    when item_count = 0 then 'blocked'
    when fill_count > 0 then 'fill'
    when review_count > 0 then 'review'
    else 'complete'
  end
  from state;
$$;

revoke all on function private.mail_v2_size_segment(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_member_payload(
  p_template_key text,
  p_parent_account_id uuid,
  p_member_season_id uuid,
  p_source_id uuid,
  p_order_line_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  line_payload jsonb := '[]'::jsonb;
begin
  select
    member_season.id member_season_id,
    member_season.season_id,
    member_season.team_name,
    member.first_name,
    concat_ws(
      ' ',
      member.first_name,
      member.insertion,
      member.last_name
    ) full_name,
    season.name season_name,
    orders.id order_id,
    orders.amount_due_cents,
    orders.active_package_snapshot_id,
    package_snapshot.package_name
  into target
  from app.member_seasons member_season
  join app.members member on member.id = member_season.member_id
  join app.seasons season on season.id = member_season.season_id
  left join lateral (
    select candidate.*
    from app.member_orders candidate
    where candidate.member_season_id = member_season.id
      and candidate.active_package_snapshot_id is not null
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = candidate.id
          and line.status <> 'cancelled'
      )
    order by candidate.created_at desc, candidate.id
    limit 1
  ) orders on true
  left join app.order_package_snapshots package_snapshot
    on package_snapshot.id = orders.active_package_snapshot_id
    and package_snapshot.order_id = orders.id
  where member_season.id = p_member_season_id;
  if not found then
    raise exception 'MAIL_V2_MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_template_key in (
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder'
  ) then
    if target.order_id is null then
      raise exception 'MAIL_V2_PACKAGE_ORDER_REQUIRED' using errcode = '23514';
    end if;
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', item.product_name_snapshot,
        'size', case
          when size_profile.selection_status = 'conflict' then 'Anders…'
          else coalesce(variant.size, 'Nog te kiezen')
        end,
        'quantity', item.quantity,
        'status', case size_profile.selection_status
          when 'imported_unconfirmed' then 'Nog controleren'
          when 'confirmed' then 'Bevestigd'
          when 'locked' then 'Gereserveerd'
          when 'change_requested' then 'Wijziging aangevraagd'
          when 'conflict' then 'Beheeractie nodig'
          else 'Nog in te vullen'
        end
      )
      order by item.sort_order, item.id
    ), '[]'::jsonb) into line_payload
    from app.order_package_snapshot_items item
    left join app.member_article_sizes size_profile
      on size_profile.member_season_id = target.member_season_id
      and size_profile.article_id = item.article_id
    left join app.article_variants variant
      on variant.id = size_profile.article_variant_id
    where item.snapshot_id = target.active_package_snapshot_id;
  elsif p_template_key = 'size_confirmed' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', confirmation_item.product_name_snapshot,
        'size', confirmation_item.size_label_snapshot,
        'quantity', confirmation_item.quantity_snapshot,
        'status', 'Bevestigd'
      )
      order by confirmation_item.created_at, confirmation_item.id
    ), '[]'::jsonb) into line_payload
    from app.package_size_confirmation_items confirmation_item
    join app.package_size_confirmations confirmation
      on confirmation.id = confirmation_item.confirmation_id
    join app.order_package_snapshot_items snapshot_item
      on snapshot_item.id = confirmation_item.snapshot_item_id
      and snapshot_item.snapshot_id = confirmation.package_snapshot_id
    where confirmation_item.confirmation_id = p_source_id;
  elsif p_template_key in (
    'payment_received_waiting_stock',
    'out_of_stock'
  ) then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', 'Wacht op voorraad'
      )
      order by line.created_at, line.id
    ), '[]'::jsonb) into line_payload
    from app.order_lines line
    where line.order_id = target.order_id
      and line.status = 'backorder'
      and (
        p_order_line_id is null
        or line.id = p_order_line_id
      )
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  elsif p_template_key = 'available_payment_required' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', 'Beschikbaar, niet gereserveerd'
      )
      order by line.created_at, line.id
    ), '[]'::jsonb) into line_payload
    from app.order_lines line
    join lateral private.inventory_balance(
      target.season_id,
      line.article_variant_id
    ) balance on true
    where line.order_id = target.order_id
      and line.status = 'backorder'
      and (
        p_order_line_id is null
        or line.id = p_order_line_id
      )
      and line.article_variant_id is not null
      and balance.available > 0
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  elsif p_template_key in (
    'pickup_ready',
    'pickup_reminder',
    'back_in_stock'
  ) then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', allocation.product_name_snapshot,
        'size', allocation.size_snapshot,
        'quantity', allocation.quantity,
        'status', 'Af te halen'
      )
      order by allocation.allocated_at, allocation.id
    ), '[]'::jsonb) into line_payload
    from app.inventory_allocations allocation
    where allocation.order_id = target.order_id
      and allocation.status = 'reserved'
      and (
        p_order_line_id is null
        or allocation.order_line_id = p_order_line_id
      );
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'memberSeasonId', target.member_season_id,
    'memberFirstName', target.first_name,
    'memberFullName', target.full_name,
    'teamName', coalesce(target.team_name, 'Niet opgegeven'),
    'seasonName', target.season_name,
    'orderId', target.order_id,
    'packageName', coalesce(target.package_name, 'Kledingpakket'),
    'amountCents', target.amount_due_cents,
    'currency', 'EUR',
    'lines', line_payload
  ));
end;
$$;

revoke all on function private.mail_v2_member_payload(
  text, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.enqueue_mail_v2_member_event(
  p_template_key text,
  p_parent_account_id uuid,
  p_member_season_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_cohort_id uuid,
  p_idempotency_key text,
  p_order_line_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_season app.member_seasons%rowtype;
  target_order_id uuid;
  created_id uuid;
  expected_payload jsonb;
  existing_event private.mail_v2_domain_events%rowtype;
begin
  if p_template_key not in (
    'portal_access_invite',
    'portal_access_reminder',
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder',
    'size_confirmed',
    'payment_request',
    'payment_reminder',
    'payment_received_waiting_stock',
    'available_payment_required',
    'pickup_ready',
    'pickup_reminder',
    'out_of_stock',
    'back_in_stock'
  )
    or p_parent_account_id is null
    or p_member_season_id is null
    or p_source_id is null
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
    or length(p_idempotency_key) not between 12 and 300
    or p_idempotency_key !~ '^[a-z0-9:_-]+$'
  then
    raise exception 'MAIL_V2_EVENT_INPUT_INVALID' using errcode = '22023';
  end if;
  select * into target_member_season
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if not found then
    raise exception 'MAIL_V2_MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists(
    select 1
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = p_member_season_id
      and grant_row.parent_account_id = p_parent_account_id
      and grant_row.status = 'active'
  ) then
    raise exception 'MAIL_V2_PARENT_BINDING_INVALID' using errcode = '23514';
  end if;
  select orders.id into target_order_id
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
    and orders.active_package_snapshot_id is not null
    and exists(
      select 1
      from app.order_lines line
      where line.order_id = orders.id
        and line.status <> 'cancelled'
    )
  order by orders.created_at desc, orders.id
  limit 1;
  if p_template_key not in (
    'portal_access_invite',
    'portal_access_reminder'
  ) and target_order_id is null then
    raise exception 'MAIL_V2_PACKAGE_ORDER_REQUIRED' using errcode = '23514';
  end if;
  if p_order_line_id is not null and not exists(
    select 1
    from app.order_lines line
    where line.id = p_order_line_id
      and line.order_id = target_order_id
  ) then
    raise exception 'MAIL_V2_ORDER_LINE_BINDING_INVALID'
      using errcode = '23514';
  end if;

  expected_payload := private.mail_v2_member_payload(
    p_template_key,
    p_parent_account_id,
    p_member_season_id,
    p_source_id,
    p_order_line_id
  );
  insert into private.mail_v2_domain_events(
    template_key,
    parent_account_id,
    season_id,
    member_season_id,
    order_id,
    order_line_id,
    source_type,
    source_id,
    cohort_id,
    idempotency_key,
    payload_snapshot
  ) values (
    p_template_key,
    p_parent_account_id,
    target_member_season.season_id,
    p_member_season_id,
    target_order_id,
    p_order_line_id,
    p_source_type,
    p_source_id,
    p_cohort_id,
    p_idempotency_key,
    expected_payload
  )
  on conflict (idempotency_key) do nothing
  returning id into created_id;
  if created_id is null then
    select * into existing_event
    from private.mail_v2_domain_events event
    where event.idempotency_key = p_idempotency_key;
    if not found
      or existing_event.template_key <> p_template_key
      or existing_event.parent_account_id <> p_parent_account_id
      or existing_event.season_id <> target_member_season.season_id
      or existing_event.member_season_id <> p_member_season_id
      or existing_event.order_id is distinct from target_order_id
      or existing_event.order_line_id is distinct from p_order_line_id
      or existing_event.source_type <> p_source_type
      or existing_event.source_id <> p_source_id
      or existing_event.cohort_id is distinct from p_cohort_id
      or existing_event.payload_snapshot <> expected_payload
    then
      raise exception 'MAIL_V2_EVENT_IDEMPOTENCY_CONFLICT'
        using errcode = '40001';
    end if;
    created_id := existing_event.id;
  end if;
  return created_id;
end;
$$;

revoke all on function private.enqueue_mail_v2_member_event(
  text, uuid, uuid, text, uuid, uuid, text, uuid
) from public, anon, authenticated, service_role;

create or replace function private.produce_portal_access_invite_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_grant private.parent_portal_grants%rowtype;
begin
  if new.outcome <> 'activated'
    or not private.mail_templates_v2_cutover_started()
  then
    return new;
  end if;
  select * into target_grant
  from private.parent_portal_grants grant_row
  where grant_row.id = new.grant_id;
  if not found or target_grant.parent_account_id is null then
    return new;
  end if;
  perform private.enqueue_mail_v2_member_event(
    'portal_access_invite',
    target_grant.parent_account_id,
    new.member_season_id,
    'parent_access_batch',
    new.batch_id,
    new.batch_id,
    concat_ws(
      ':',
      'portal-access-invite-v2',
      new.batch_id,
      target_grant.parent_account_id,
      new.member_season_id
    )
  );
  return new;
end;
$$;

create trigger parent_access_batch_items_mail_v2
after insert on private.parent_access_batch_items
for each row execute function private.produce_portal_access_invite_v2();

revoke all on function private.produce_portal_access_invite_v2()
from public, anon, authenticated, service_role;

create or replace function private.produce_size_confirmed_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_grant record;
begin
  if not private.mail_templates_v2_cutover_started() then
    return new;
  end if;
  for target_grant in
    select grant_row.parent_account_id
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = new.member_season_id
      and grant_row.status = 'active'
      and grant_row.parent_account_id is not null
  loop
    perform private.enqueue_mail_v2_member_event(
      'size_confirmed',
      target_grant.parent_account_id,
      new.member_season_id,
      'package_size_confirmation',
      new.id,
      new.id,
      concat_ws(
        ':',
        'size-confirmed-v2',
        new.id,
        target_grant.parent_account_id
      )
    );
  end loop;
  return new;
end;
$$;

create constraint trigger package_size_confirmations_mail_v2
after insert on app.package_size_confirmations
deferrable initially deferred
for each row execute function private.produce_size_confirmed_v2();

revoke all on function private.produce_size_confirmed_v2()
from public, anon, authenticated, service_role;

create or replace function private.produce_payment_received_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  target_grant record;
begin
  if new.status <> 'paid'
    or (
      tg_op = 'UPDATE'
      and old.status = 'paid'
      and old.reconciliation_issue is null
    )
    or new.reconciliation_issue is not null
    or not private.mail_templates_v2_cutover_started()
  then
    return new;
  end if;
  select * into target_order
  from app.member_orders orders
  where orders.id = new.order_id;
  if not found or target_order.member_season_id is null then
    return new;
  end if;
  for target_grant in
    select grant_row.parent_account_id
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = target_order.member_season_id
      and grant_row.status = 'active'
      and grant_row.parent_account_id is not null
  loop
    perform private.enqueue_mail_v2_member_event(
      'payment_received_waiting_stock',
      target_grant.parent_account_id,
      target_order.member_season_id,
      'payment',
      new.id,
      new.id,
      concat_ws(
        ':',
        'payment-waiting-stock-v2',
        new.id,
        target_grant.parent_account_id
      )
    );
  end loop;
  return new;
end;
$$;

create trigger payments_mail_v2
after insert or update of status, reconciliation_issue on app.payments
for each row execute function private.produce_payment_received_v2();

revoke all on function private.produce_payment_received_v2()
from public, anon, authenticated, service_role;

create or replace function private.produce_pickup_ready_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_allocation app.inventory_allocations%rowtype;
  target_grant record;
begin
  if new.event_type <> 'reserved'
    or new.next_status <> 'reserved'
    or not private.mail_templates_v2_cutover_started()
  then
    return new;
  end if;
  select * into target_allocation
  from app.inventory_allocations allocation
  where allocation.id = new.allocation_id;
  if not found then
    return new;
  end if;
  for target_grant in
    select grant_row.parent_account_id
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = target_allocation.member_season_id
      and grant_row.status = 'active'
      and grant_row.parent_account_id is not null
  loop
    perform private.enqueue_mail_v2_member_event(
      'pickup_ready',
      target_grant.parent_account_id,
      target_allocation.member_season_id,
      'inventory_allocation_event',
      new.id,
      coalesce(
        new.source_id,
        case
          when new.source_type = 'allocation_queue' then (
            substr(md5('allocation-queue:' || txid_current()::text), 1, 8)
            || '-' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 9, 4)
            || '-4' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 14, 3)
            || '-8' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 18, 3)
            || '-' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 21, 12)
          )::uuid
          else new.id
        end
      ),
      concat_ws(
        ':',
        'pickup-ready-v2',
        new.id,
        target_grant.parent_account_id
      ),
      target_allocation.order_line_id
    );
  end loop;
  return new;
end;
$$;

create trigger inventory_allocation_events_mail_v2
after insert on app.inventory_allocation_events
for each row execute function private.produce_pickup_ready_v2();

revoke all on function private.produce_pickup_ready_v2()
from public, anon, authenticated, service_role;

create or replace function private.produce_internal_email_failure_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_season_id uuid;
  reason text;
  action_key text;
begin
  if not private.mail_templates_v2_cutover_started()
    or new.template_key = 'internal_email_failure'
    or not (
      (
        new.status = 'failed'
        and old.status is distinct from new.status
        and coalesce(new.last_error, '') not in (
          'access_inactive_before_send',
          'eligibility_changed_before_send',
          'mail_v2_paused'
        )
      )
      or (
        new.delivery_status in ('bounced', 'dropped', 'failed')
        and old.delivery_status is distinct from new.delivery_status
      )
    )
  then
    return new;
  end if;
  target_season_id := coalesce(
    new.season_id,
    (
      select orders.season_id
      from app.member_orders orders
      where orders.id = new.order_id
    ),
    (
      select batch.season_id
      from private.parent_access_batches batch
      where batch.id = new.parent_access_batch_id
    )
  );
  if target_season_id is null then
    return new;
  end if;
  reason := case
    when new.delivery_status in ('bounced', 'dropped', 'failed')
      then 'provider_' || new.delivery_status
    else coalesce(new.last_error, 'terminal_failure')
  end;
  if reason !~ '^[a-z0-9][a-z0-9._-]{1,63}$' then
    reason := 'terminal_failure';
  end if;
  action_key := encode(
    extensions.digest(
      convert_to('email-failure-v2:' || new.id::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'email_failure',
    target_season_id,
    'email_job',
    new.id,
    'email_job',
    new.id,
    action_key,
    'critical',
    'admin_only',
    'email.' || reason,
    jsonb_build_object('jobId', new.id, 'reason', reason),
    timezone('utc', now()) + interval '4 hours'
  );
  insert into private.mail_v2_domain_events(
    template_key,
    parent_account_id,
    season_id,
    member_season_id,
    order_id,
    order_line_id,
    source_type,
    source_id,
    cohort_id,
    idempotency_key,
    payload_snapshot
  ) values (
    'internal_email_failure',
    null,
    target_season_id,
    null,
    null,
    null,
    'email_job',
    new.id,
    new.id,
    'internal-email-failure-v2:' || new.id::text,
    jsonb_build_object('jobId', new.id, 'reason', reason)
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger email_jobs_mail_v2_failure
after update of status, delivery_status on private.email_jobs
for each row execute function private.produce_internal_email_failure_v2();

revoke all on function private.produce_internal_email_failure_v2()
from public, anon, authenticated, service_role;

create or replace function private.suppress_legacy_mail_after_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if private.mail_templates_v2_cutover_started()
    and (
      (
        new.context_kind = 'portal_access'
        and new.template_key = 'portal_access_invite'
      )
      or (
        new.context_kind = 'order'
        and new.template_key in (
          'payment_received',
          'payment_request',
          'payment_reminder',
          'ready_for_pickup'
        )
      )
    )
  then
    return null;
  end if;
  return new;
end;
$$;

create trigger a_email_jobs_suppress_legacy_after_mail_v2
before insert on private.email_jobs
for each row execute function private.suppress_legacy_mail_after_v2();

revoke all on function private.suppress_legacy_mail_after_v2()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

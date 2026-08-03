-- Mail-v2 manual campaigns. A campaign preview is short-lived, actor-bound
-- and PII-free outside the existing authorised member workspace. Confirmation
-- repeats the same target query and only appends immutable domain events.

create or replace function private.mail_v2_campaign_preview_group_is_safe(
  p_group jsonb
)
returns boolean
language sql
immutable
set search_path = private, pg_catalog, pg_temp
as $$
  select p_group is not null
    and jsonb_typeof(p_group) = 'object'
    and octet_length(p_group::text) between 2 and 500000
    and jsonb_typeof(p_group->'events') = 'array'
    and jsonb_array_length(p_group->'events') between 1 and 100
    and not exists(
      select 1
      from jsonb_array_elements(p_group->'events') event
      where not private.mail_v2_payload_keys_are_safe(event->'payload')
    );
$$;

revoke all on function private.mail_v2_campaign_preview_group_is_safe(jsonb)
from public, anon, authenticated, service_role;

create table private.mail_v2_campaign_preflights (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  template_revision_id uuid not null
    references app.mail_template_revisions(id) on delete restrict,
  branding_revision_id uuid not null
    references app.mail_branding_revisions(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  selection_hash text not null check (
    selection_hash ~ '^[0-9a-f]{64}$'
  ),
  eligibility_revision text not null check (
    eligibility_revision ~ '^[0-9a-f]{64}$'
  ),
  selected_target_count integer not null check (
    selected_target_count between 1 and 2000
  ),
  eligible_target_count integer not null check (
    eligible_target_count between 0 and selected_target_count
  ),
  eligible_event_count integer not null check (
    eligible_event_count between 0 and 200000
  ),
  skipped_target_count integer not null check (
    skipped_target_count between 0 and selected_target_count
  ),
  blocked_target_count integer not null check (
    blocked_target_count between 0 and selected_target_count
  ),
  parent_group_count integer not null check (
    parent_group_count between 0 and 2000
  ),
  preview_group_snapshot jsonb check (
    preview_group_snapshot is null
    or private.mail_v2_campaign_preview_group_is_safe(
      preview_group_snapshot
    )
  ),
  expires_at timestamptz not null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (actor_user_id, request_id),
  constraint mail_v2_campaign_preflight_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '10 minutes'
  ),
  constraint mail_v2_campaign_preflight_partition_check check (
    (
      eligibility_revision = repeat('0', 64)
      and eligible_target_count = 0
      and skipped_target_count = 0
      and blocked_target_count = 0
    )
    or (
      eligibility_revision <> repeat('0', 64)
      and eligible_target_count
        + skipped_target_count
        + blocked_target_count = selected_target_count
    )
  )
);

create table private.mail_v2_campaign_preflight_items (
  id uuid primary key default gen_random_uuid(),
  preflight_id uuid not null
    references private.mail_v2_campaign_preflights(id) on delete restrict,
  target_kind text not null check (
    target_kind in ('order', 'member_season')
  ),
  target_id uuid not null,
  order_id uuid references app.member_orders(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  parent_account_id uuid
    references private.parent_accounts(id) on delete restrict,
  order_line_id uuid references app.order_lines(id) on delete restrict,
  outcome text not null check (
    outcome in ('eligible', 'skipped', 'blocked')
  ),
  reason_code text not null check (
    reason_code ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  created_at timestamptz not null default timezone('utc', now()),
  unique (
    preflight_id,
    target_kind,
    target_id,
    parent_account_id,
    order_line_id,
    outcome
  ),
  constraint mail_v2_campaign_item_binding_check check (
    (
      target_kind = 'order'
      and order_id = target_id
    )
    or (
      target_kind = 'member_season'
      and member_season_id = target_id
      and order_id is null
    )
  ),
  constraint mail_v2_campaign_item_eligibility_check check (
    (outcome = 'eligible' and parent_account_id is not null)
    or outcome in ('skipped', 'blocked')
  )
);

create table private.mail_v2_campaign_runs (
  id uuid primary key default gen_random_uuid(),
  preflight_id uuid not null unique,
  confirmation_request_id uuid not null unique,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  cohort_id uuid not null unique,
  eligibility_revision text not null check (
    eligibility_revision ~ '^[0-9a-f]{64}$'
  ),
  event_count integer not null check (event_count between 1 and 200000),
  parent_group_count integer not null check (
    parent_group_count between 1 and 2000
  ),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'email',
      'recipient',
      'name',
      'memberName',
      'dateOfBirth',
      'relationNumber',
      'token',
      'qr'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now())
);

create index mail_v2_campaign_preflights_expiry_idx
  on private.mail_v2_campaign_preflights(expires_at, created_at);
create index mail_v2_campaign_items_preflight_idx
  on private.mail_v2_campaign_preflight_items(
    preflight_id,
    outcome,
    target_kind,
    target_id
  );
create index mail_v2_campaign_runs_created_idx
  on private.mail_v2_campaign_runs(created_at desc);

alter table private.mail_v2_campaign_preflights enable row level security;
alter table private.mail_v2_campaign_preflight_items enable row level security;
alter table private.mail_v2_campaign_runs enable row level security;
revoke all on
  private.mail_v2_campaign_preflights,
  private.mail_v2_campaign_preflight_items,
  private.mail_v2_campaign_runs
from public, anon, authenticated, service_role;

create or replace function private.reject_mail_v2_campaign_fact_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  if tg_table_name = 'mail_v2_campaign_preflight_items'
    and tg_op = 'DELETE'
    and current_setting('app.mail_v2_campaign_retention', true) = 'on'
  then
    return old;
  end if;
  raise exception 'MAIL_V2_CAMPAIGN_FACT_IMMUTABLE' using errcode = '55000';
end;
$$;

create trigger mail_v2_campaign_items_immutable
before update or delete on private.mail_v2_campaign_preflight_items
for each row execute function private.reject_mail_v2_campaign_fact_mutation();
create trigger mail_v2_campaign_runs_immutable
before update or delete on private.mail_v2_campaign_runs
for each row execute function private.reject_mail_v2_campaign_fact_mutation();

revoke all on function private.reject_mail_v2_campaign_fact_mutation()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_campaign_role_allowed(
  p_template_key text,
  p_role app.staff_role
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when p_role = 'beheerder' then p_template_key in (
      'portal_access_reminder',
      'size_fill_request',
      'size_fill_reminder',
      'size_review_request',
      'size_review_reminder',
      'payment_request',
      'payment_reminder',
      'available_payment_required',
      'pickup_reminder',
      'out_of_stock'
    )
    when p_role = 'kledingcommissie' then p_template_key in (
      'size_fill_request',
      'size_fill_reminder',
      'size_review_request',
      'size_review_reminder',
      'payment_request',
      'payment_reminder',
      'available_payment_required',
      'pickup_reminder',
      'out_of_stock'
    )
    else false
  end;
$$;

revoke all on function private.mail_v2_campaign_role_allowed(
  text, app.staff_role
) from public, anon, authenticated, service_role;

create or replace function private.lock_mail_v2_campaign_state(
  p_template_key text,
  p_target_ids uuid[],
  p_lock_episode boolean default false
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  member_season_ids uuid[];
  order_ids uuid[];
  target_id uuid;
begin
  if p_template_key = 'portal_access_reminder' then
    member_season_ids := p_target_ids;
    order_ids := array[]::uuid[];
  else
    select
      coalesce(
        array_agg(orders.member_season_id order by orders.member_season_id),
        array[]::uuid[]
      ),
      coalesce(
        array_agg(orders.id order by orders.id),
        array[]::uuid[]
      )
    into member_season_ids, order_ids
    from app.member_orders orders
    where orders.id = any(p_target_ids);
  end if;

  -- Campaigns never wait while taking their state barrier. Existing writers
  -- use different valid lock orders (payment row -> inventory, inventory ->
  -- order line -> member, and member -> inventory). A fail-fast retry is the
  -- only ordering that cannot complete a cycle with all three.
  for target_id in
    select distinct member_season.member_id
    from app.member_seasons member_season
    where member_season.id = any(member_season_ids)
    order by member_season.member_id
  loop
    if not pg_try_advisory_xact_lock(
      hashtextextended('dynamic-import-member:' || target_id::text, 0)
    ) then
      raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
        using errcode = '40001';
    end if;
  end loop;
  for target_id in
    select distinct selected_id
    from unnest(member_season_ids) selected_id
    order by selected_id
  loop
    if not pg_try_advisory_xact_lock(
      hashtextextended(
        'dynamic-import-member-season:' || target_id::text,
        0
      )
    ) then
      raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
        using errcode = '40001';
    end if;
  end loop;
  if p_lock_episode then
    for target_id in
      select distinct selected_id
      from unnest(p_target_ids) selected_id
      order by selected_id
    loop
      if not pg_try_advisory_xact_lock(
        hashtextextended(
          'mail-v2-campaign-episode:'
            || p_template_key
            || ':'
            || target_id::text,
          0
        )
      ) then
        raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
          using errcode = '40001';
      end if;
    end loop;
  end if;

  if not pg_try_advisory_xact_lock_shared(
    hashtextextended('parent-access-grants-global', 0)
  ) then
    raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
      using errcode = '40001';
  end if;
  if not pg_try_advisory_xact_lock_shared(
    hashtextextended('duindorp-inventory-v2-global', 0)
  ) then
    raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
      using errcode = '40001';
  end if;

  -- NOWAIT row locks close direct-row and login races without waiting behind a
  -- writer that may already be queued on one of the advisory barriers above.
  begin
    perform 1
    from app.members member
    join app.member_seasons member_season
      on member_season.member_id = member.id
    where member_season.id = any(member_season_ids)
    order by member.id
    for update of member nowait;
    perform 1
    from app.member_seasons member_season
    where member_season.id = any(member_season_ids)
    order by member_season.id
    for update nowait;
    perform 1
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = any(member_season_ids)
    order by grant_row.id
    for update nowait;
    perform 1
    from private.parent_accounts account
    where account.id in (
      select grant_row.parent_account_id
      from private.parent_portal_grants grant_row
      where grant_row.member_season_id = any(member_season_ids)
        and grant_row.parent_account_id is not null
    )
    order by account.id
    for update nowait;
    perform 1
    from app.member_orders orders
    where orders.id = any(order_ids)
    order by orders.id
    for update nowait;
    perform 1
    from app.order_lines line
    where line.order_id = any(order_ids)
    order by line.id
    for update nowait;
    perform 1
    from app.member_article_sizes size_profile
    where size_profile.member_season_id = any(member_season_ids)
    order by
      size_profile.member_id,
      size_profile.season_id,
      size_profile.article_id
    for update nowait;
    perform 1
    from app.payments payment
    where payment.order_id = any(order_ids)
    order by payment.id
    for update nowait;
    perform 1
    from app.inventory_allocations allocation
    where allocation.order_id = any(order_ids)
    order by allocation.id
    for update nowait;
  exception
    when lock_not_available then
      raise exception 'MAIL_V2_CAMPAIGN_STATE_BUSY'
        using errcode = '40001';
  end;
end;
$$;

revoke all on function private.lock_mail_v2_campaign_state(
  text, uuid[], boolean
) from public, anon, authenticated, service_role;

create or replace function private.mail_v2_campaign_current_episode_exists(
  p_template_key text,
  p_parent_account_id uuid,
  p_order_id uuid,
  p_order_line_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    where event.template_key = p_template_key
      and event.parent_account_id = p_parent_account_id
      and event.order_id = p_order_id
      and event.order_line_id is not distinct from p_order_line_id
      and private.mail_v2_event_state(event.id) in ('eligible', 'pending')
  );
$$;

revoke all on function private.mail_v2_campaign_current_episode_exists(
  text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.mail_v2_payment_state(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select case
    when exists(
      select 1
      from app.payments payment
      where payment.order_id = p_order_id
        and (
          payment.reconciliation_issue is not null
          or payment.status = 'duplicate_paid'
        )
    ) then 'review'
    when exists(
      select 1
      from app.payments payment
      where payment.order_id = p_order_id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
    ) then 'paid'
    when exists(
      select 1
      from app.payments payment
      where payment.order_id = p_order_id
        and payment.status = 'refunded'
    ) then 'review'
    else 'unpaid'
  end;
$$;

create or replace function private.mail_v2_order_line_size_is_valid(
  p_order_line_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select exists(
    select 1
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join app.member_article_sizes size_profile
      on size_profile.member_season_id = orders.member_season_id
      and size_profile.article_id = line.article_id
      and size_profile.article_variant_id = line.article_variant_id
      and size_profile.selection_status in ('confirmed', 'locked')
      and size_profile.confirmed_at is not null
    where line.id = p_order_line_id
      and line.status = 'backorder'
      and line.article_variant_id is not null
  );
$$;

revoke all on function private.mail_v2_payment_state(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_order_line_size_is_valid(uuid)
from public, anon, authenticated, service_role;

alter function private.mail_v2_member_payload(
  text, uuid, uuid, uuid, uuid
) rename to mail_v2_member_payload_v2;

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
  payload jsonb;
  payload_lines jsonb;
  target_order_id uuid;
  target_season_id uuid;
begin
  payload := private.mail_v2_member_payload_v2(
    p_template_key,
    p_parent_account_id,
    p_member_season_id,
    p_source_id,
    p_order_line_id
  );
  if p_template_key not in (
    'payment_received_waiting_stock',
    'available_payment_required',
    'out_of_stock'
  ) then
    return payload;
  end if;
  target_order_id := nullif(payload->>'orderId', '')::uuid;
  select member_season.season_id into target_season_id
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;

  if p_template_key = 'available_payment_required' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', 'Beschikbaar, niet gereserveerd'
      )
      order by line.created_at, line.id
    ), '[]'::jsonb)
    into payload_lines
    from app.order_lines line
    join lateral private.inventory_balance(
      target_season_id,
      line.article_variant_id
    ) balance on true
    where line.order_id = target_order_id
      and line.status = 'backorder'
      and (p_order_line_id is null or line.id = p_order_line_id)
      and private.mail_v2_order_line_size_is_valid(line.id)
      and balance.available > 0
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  elsif p_template_key = 'out_of_stock' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', 'Wacht op voorraad'
      )
      order by line.created_at, line.id
    ), '[]'::jsonb)
    into payload_lines
    from app.order_lines line
    join lateral private.inventory_balance(
      target_season_id,
      line.article_variant_id
    ) balance on true
    where line.order_id = target_order_id
      and line.status = 'backorder'
      and p_order_line_id is not null
      and line.id = p_order_line_id
      and private.mail_v2_order_line_size_is_valid(line.id)
      and balance.available = 0
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  else
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product', line.product_name_snapshot,
        'size', line.size_snapshot,
        'quantity', line.quantity,
        'status', 'Wacht op voorraad'
      )
      order by line.created_at, line.id
    ), '[]'::jsonb)
    into payload_lines
    from app.order_lines line
    where line.order_id = target_order_id
      and line.status = 'backorder'
      and (p_order_line_id is null or line.id = p_order_line_id)
      and private.mail_v2_order_line_size_is_valid(line.id)
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      );
  end if;
  return jsonb_set(payload, '{lines}', payload_lines, true);
end;
$$;

revoke all on function private.mail_v2_member_payload_v2(
  text, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_member_payload(
  text, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

alter function private.mail_v2_event_state(uuid)
rename to mail_v2_event_state_v2;

create or replace function private.mail_v2_event_state(
  p_event_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  base_state text;
  payment_state text;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return 'terminal';
  end if;
  if not exists(
    select 1
    from app.seasons season
    where season.id = target.season_id
      and season.status = 'open'
  ) then
    return 'terminal';
  end if;

  if target.template_key = 'portal_access_reminder' then
    if exists(
      select 1
      from private.parent_portal_grants grant_row
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.season_id = target.season_id
        and member_season.participation_status = 'active'
      join private.parent_accounts account
        on account.id = grant_row.parent_account_id
      where grant_row.member_season_id = target.member_season_id
        and grant_row.parent_account_id = target.parent_account_id
        and grant_row.status = 'active'
        and (
          account.last_login_at is null
          or account.last_login_at < grant_row.granted_at
        )
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if target.order_id is not null then
    payment_state := private.mail_v2_payment_state(target.order_id);
    if payment_state = 'review'
      and target.template_key in (
        'payment_request',
        'payment_reminder',
        'available_payment_required',
        'payment_received_waiting_stock',
        'out_of_stock',
        'pickup_ready',
        'pickup_reminder',
        'back_in_stock'
      )
    then
      return 'pending';
    end if;
  end if;

  base_state := private.mail_v2_event_state_v2(p_event_id);
  if base_state = 'eligible'
    and target.template_key = 'available_payment_required'
    and not exists(
      select 1
      from app.order_lines line
      join lateral private.inventory_balance(
        target.season_id,
        line.article_variant_id
      ) balance on true
      where line.order_id = target.order_id
        and line.status = 'backorder'
        and balance.available > 0
        and private.mail_v2_order_line_size_is_valid(line.id)
        and not exists(
          select 1
          from app.inventory_allocations allocation
          where allocation.order_line_id = line.id
            and allocation.status in ('reserved', 'fulfilled')
        )
    )
  then
    return 'pending';
  end if;
  if base_state = 'eligible'
    and target.template_key = 'out_of_stock'
    and (
      target.order_line_id is null
      or not private.mail_v2_order_line_size_is_valid(target.order_line_id)
    )
  then
    return 'pending';
  end if;
  if base_state = 'eligible'
    and target.template_key = 'payment_received_waiting_stock'
    and not exists(
      select 1
      from app.order_lines line
      where line.order_id = target.order_id
        and line.status = 'backorder'
        and private.mail_v2_order_line_size_is_valid(line.id)
        and not exists(
          select 1
          from app.inventory_allocations allocation
          where allocation.order_line_id = line.id
            and allocation.status in ('reserved', 'fulfilled')
        )
    )
  then
    return 'pending';
  end if;
  return base_state;
end;
$$;

revoke all on function private.mail_v2_event_state_v2(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_campaign_candidates(
  p_template_key text,
  p_season_id uuid,
  p_target_ids uuid[]
)
returns table(
  target_kind text,
  target_id uuid,
  order_id uuid,
  member_season_id uuid,
  parent_account_id uuid,
  order_line_id uuid,
  outcome text,
  reason_code text
)
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  candidate record;
  target_line record;
  size_segment text;
  payment_state text;
  matched_line_count integer;
begin
  if p_template_key not in (
    'portal_access_reminder',
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder',
    'payment_request',
    'payment_reminder',
    'available_payment_required',
    'pickup_reminder',
    'out_of_stock'
  ) or p_season_id is null then
    raise exception 'MAIL_V2_CAMPAIGN_TEMPLATE_INVALID'
      using errcode = '22023';
  end if;

  if p_template_key = 'portal_access_reminder' then
    for candidate in
      select
        member_season.id member_season_id,
        member_season.participation_status,
        season.status season_status,
        grant_row.parent_account_id,
        grant_row.granted_at,
        account.last_login_at
      from app.member_seasons member_season
      join app.seasons season on season.id = member_season.season_id
      left join private.parent_portal_grants grant_row
        on grant_row.member_season_id = member_season.id
        and grant_row.status = 'active'
      left join private.parent_accounts account
        on account.id = grant_row.parent_account_id
      where member_season.id = any(p_target_ids)
        and member_season.season_id = p_season_id
      order by member_season.id
    loop
      target_kind := 'member_season';
      target_id := candidate.member_season_id;
      order_id := null;
      member_season_id := candidate.member_season_id;
      parent_account_id := candidate.parent_account_id;
      order_line_id := null;
      if candidate.participation_status <> 'active'
        or candidate.season_status <> 'open'
      then
        outcome := 'skipped';
        reason_code := 'member_season_inactive';
      elsif candidate.parent_account_id is null then
        outcome := 'blocked';
        reason_code := 'portal_access_missing';
      elsif candidate.last_login_at is null
        or candidate.last_login_at < candidate.granted_at
      then
        outcome := 'eligible';
        reason_code := 'portal_not_used_since_grant';
      else
        outcome := 'skipped';
        reason_code := 'portal_used_since_grant';
      end if;
      return next;
    end loop;
    return;
  end if;

  for candidate in
    select
      orders.id order_id,
      orders.member_season_id,
      orders.active_package_snapshot_id,
      member_season.participation_status,
      season.status season_status,
      grant_row.parent_account_id
    from app.member_orders orders
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.season_id = orders.season_id
    join app.seasons season on season.id = member_season.season_id
    left join private.parent_portal_grants grant_row
      on grant_row.member_season_id = member_season.id
      and grant_row.status = 'active'
    where orders.id = any(p_target_ids)
      and orders.season_id = p_season_id
    order by orders.id, grant_row.parent_account_id
  loop
    target_kind := 'order';
    target_id := candidate.order_id;
    order_id := candidate.order_id;
    member_season_id := candidate.member_season_id;
    parent_account_id := candidate.parent_account_id;
    order_line_id := null;

    if candidate.participation_status <> 'active'
      or candidate.season_status <> 'open'
      or candidate.active_package_snapshot_id is null
      or not exists(
        select 1
        from app.order_lines line
        where line.order_id = candidate.order_id
          and line.status <> 'cancelled'
      )
    then
      outcome := 'skipped';
      reason_code := 'order_inactive';
      return next;
      continue;
    end if;
    if candidate.parent_account_id is null then
      outcome := 'blocked';
      reason_code := 'portal_access_missing';
      return next;
      continue;
    end if;

    if p_template_key in (
      'size_fill_request',
      'size_fill_reminder',
      'size_review_request',
      'size_review_reminder'
    ) then
      size_segment := private.mail_v2_size_segment(candidate.order_id);
      if p_template_key in ('size_fill_request', 'size_fill_reminder') then
        outcome := case when size_segment = 'fill'
          then 'eligible' else 'skipped' end;
        reason_code := case when size_segment = 'fill'
          then 'size_fill_required'
          when size_segment = 'complete' then 'sizes_complete'
          else 'size_review_only' end;
      else
        outcome := case when size_segment = 'review'
          then 'eligible' else 'skipped' end;
        reason_code := case when size_segment = 'review'
          then 'size_review_required'
          when size_segment = 'complete' then 'sizes_complete'
          else 'size_fill_required' end;
      end if;
      if outcome = 'eligible'
        and p_template_key in ('size_fill_request', 'size_review_request')
        and private.mail_v2_campaign_current_episode_exists(
          p_template_key,
          candidate.parent_account_id,
          candidate.order_id
        )
      then
        outcome := 'skipped';
        reason_code := 'current_episode_already_notified';
      end if;
      return next;
      continue;
    end if;

    payment_state := private.mail_v2_payment_state(candidate.order_id);
    if payment_state = 'review' then
      outcome := 'blocked';
      reason_code := 'payment_reconciliation_required';
      return next;
      continue;
    end if;

    if p_template_key in ('payment_request', 'payment_reminder') then
      outcome := case when payment_state = 'paid'
        then 'skipped' else 'eligible' end;
      reason_code := case when payment_state = 'paid'
        then 'payment_already_received' else 'payment_required' end;
      if outcome = 'eligible'
        and p_template_key = 'payment_request'
        and private.mail_v2_campaign_current_episode_exists(
          p_template_key,
          candidate.parent_account_id,
          candidate.order_id
        )
      then
        outcome := 'skipped';
        reason_code := 'current_episode_already_notified';
      end if;
      return next;
      continue;
    end if;

    if p_template_key = 'available_payment_required' then
      if payment_state = 'paid' then
        outcome := 'skipped';
        reason_code := 'payment_already_received';
      elsif exists(
        select 1
        from app.order_lines line
        join lateral private.inventory_balance(
          p_season_id,
          line.article_variant_id
        ) balance on true
        where line.order_id = candidate.order_id
          and line.status = 'backorder'
          and line.article_variant_id is not null
          and private.mail_v2_order_line_size_is_valid(line.id)
          and balance.available > 0
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
      ) then
        outcome := 'eligible';
        reason_code := 'stock_available_payment_required';
        if private.mail_v2_campaign_current_episode_exists(
          p_template_key,
          candidate.parent_account_id,
          candidate.order_id
        ) then
          outcome := 'skipped';
          reason_code := 'current_episode_already_notified';
        end if;
      else
        outcome := 'skipped';
        reason_code := 'no_unreserved_stock';
      end if;
      return next;
      continue;
    end if;

    if p_template_key = 'pickup_reminder' then
      if payment_state <> 'paid' then
        outcome := 'blocked';
        reason_code := 'payment_required';
      elsif not private.order_qr_usable(candidate.order_id) then
        outcome := 'skipped';
        reason_code := 'pickup_qr_not_ready';
      elsif not private.mail_v2_pickup_ready_sent(
        candidate.parent_account_id,
        candidate.order_id
      ) then
        outcome := 'skipped';
        reason_code := 'pickup_ready_not_sent';
      elsif exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_id = candidate.order_id
          and allocation.status = 'reserved'
      ) then
        outcome := 'eligible';
        reason_code := 'pickup_still_ready';
      else
        outcome := 'skipped';
        reason_code := 'pickup_no_longer_ready';
      end if;
      return next;
      continue;
    end if;

    if p_template_key = 'out_of_stock' then
      if payment_state <> 'paid' then
        outcome := 'blocked';
        reason_code := 'payment_required';
        return next;
        continue;
      end if;
      matched_line_count := 0;
      for target_line in
        select line.id
        from app.order_lines line
        join lateral private.inventory_balance(
          p_season_id,
          line.article_variant_id
        ) balance on true
        where line.order_id = candidate.order_id
          and line.status = 'backorder'
          and line.article_variant_id is not null
          and private.mail_v2_order_line_size_is_valid(line.id)
          and balance.available = 0
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
        order by line.id
      loop
        matched_line_count := matched_line_count + 1;
        order_line_id := target_line.id;
        if private.mail_v2_campaign_current_episode_exists(
          p_template_key,
          candidate.parent_account_id,
          candidate.order_id,
          target_line.id
        ) then
          outcome := 'skipped';
          reason_code := 'current_episode_already_notified';
        else
          outcome := 'eligible';
          reason_code := 'paid_waiting_zero_stock';
        end if;
        return next;
      end loop;
      if matched_line_count = 0 then
        order_line_id := null;
        outcome := 'skipped';
        reason_code := 'no_zero_stock_waiting_line';
        return next;
      end if;
    end if;
  end loop;
end;
$$;

revoke all on function private.mail_v2_campaign_candidates(
  text, uuid, uuid[]
) from public, anon, authenticated, service_role;

create or replace function private.mail_v2_campaign_preflight_json(
  p_preflight_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'preflightId',
    preflight.id,
    'templateKey',
    preflight.template_key,
    'seasonId',
    preflight.season_id,
    'eligibilityRevision',
    preflight.eligibility_revision,
    'selectedTargetCount',
    preflight.selected_target_count,
    'eligibleTargetCount',
    preflight.eligible_target_count,
    'eligibleEventCount',
    preflight.eligible_event_count,
    'skippedTargetCount',
    preflight.skipped_target_count,
    'blockedTargetCount',
    preflight.blocked_target_count,
    'parentGroupCount',
    preflight.parent_group_count,
    'expiresAt',
    preflight.expires_at,
    'previewGroup',
    case when preflight.eligible_event_count = 0 then null else
      jsonb_build_object(
        'groupId', preflight.id,
        'templateKey', preflight.template_key,
        'eligibilityRevision', preflight.eligibility_revision,
        'template', jsonb_build_object(
          'id', revision.id,
          'templateKey', revision.template_key,
          'subjectSource', revision.subject_source,
          'preheaderSource', revision.preheader_source,
          'bodyTipTap', revision.body_tiptap,
          'contentHash', revision.content_hash,
          'allowedShortcodes', template.allowed_shortcode_keys,
          'allowedProtectedNodes', template.allowed_protected_nodes,
          'requiredProtectedNodes', template.required_protected_nodes
        ),
        'branding', jsonb_build_object(
          'id', branding.id,
          'clubName', branding.club_name,
          'logoAssetPath', branding.logo_asset_path,
          'fromName', branding.from_name,
          'fromEmail', branding.from_email,
          'replyToEmail', branding.reply_to_email,
          'contactEmail', branding.contact_email,
          'clubAddressLine', branding.club_address_line,
          'clubPostalCode', branding.club_postal_code,
          'clubCity', branding.club_city,
          'pickupName', branding.pickup_name,
          'pickupAddressLine', branding.pickup_address_line,
          'pickupPostalCode', branding.pickup_postal_code,
          'pickupCity', branding.pickup_city,
          'privacyUrl', branding.privacy_url,
          'primaryColor', branding.primary_color,
          'secondaryColor', branding.secondary_color,
          'accentColor', branding.accent_color,
          'footerText', branding.footer_text,
          'contrastValidated', branding.contrast_validated,
          'contentHash', branding.content_hash
        ),
        'events', (
          select jsonb_agg(
            jsonb_build_object(
              'eventId', item.id,
              'payload', private.mail_v2_member_payload(
                preflight.template_key,
                item.parent_account_id,
                item.member_season_id,
                preflight.id,
                item.order_line_id
              )
            )
            order by item.target_id, item.order_line_id, item.id
          )
          from private.mail_v2_campaign_preflight_items item
          where item.preflight_id = preflight.id
            and item.outcome = 'eligible'
            and item.parent_account_id = (
              select first_item.parent_account_id
              from private.mail_v2_campaign_preflight_items first_item
              where first_item.preflight_id = preflight.id
                and first_item.outcome = 'eligible'
              order by first_item.parent_account_id
              limit 1
            )
        )
      )
    end
  )
  from private.mail_v2_campaign_preflights preflight
  join app.mail_template_revisions revision
    on revision.id = preflight.template_revision_id
  join app.mail_templates template
    on template.template_key = revision.template_key
  join app.mail_branding_revisions branding
    on branding.id = preflight.branding_revision_id
  where preflight.id = p_preflight_id;
$$;

revoke all on function private.mail_v2_campaign_preflight_json(uuid)
from public, anon, authenticated, service_role;

alter function private.mail_v2_campaign_preflight_json(uuid)
rename to mail_v2_campaign_preflight_json_live_v1;

create or replace function private.mail_v2_campaign_preflight_json(
  p_preflight_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select jsonb_build_object(
    'preflightId',
    preflight.id,
    'templateKey',
    preflight.template_key,
    'seasonId',
    preflight.season_id,
    'eligibilityRevision',
    preflight.eligibility_revision,
    'selectedTargetCount',
    preflight.selected_target_count,
    'eligibleTargetCount',
    preflight.eligible_target_count,
    'eligibleEventCount',
    preflight.eligible_event_count,
    'skippedTargetCount',
    preflight.skipped_target_count,
    'blockedTargetCount',
    preflight.blocked_target_count,
    'parentGroupCount',
    preflight.parent_group_count,
    'expiresAt',
    preflight.expires_at,
    'previewGroup',
    preflight.preview_group_snapshot
  )
  from private.mail_v2_campaign_preflights preflight
  where preflight.id = p_preflight_id;
$$;

revoke all on function private.mail_v2_campaign_preflight_json_live_v1(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_campaign_preflight_json(uuid)
from public, anon, authenticated, service_role;

create or replace function app.preview_mail_v2_campaign_v1(
  p_template_key text,
  p_target_ids uuid[],
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  actor_role app.staff_role := app.staff_role();
  selected_count integer;
  selected_season_id uuid;
  selection_hash text;
  existing private.mail_v2_campaign_preflights%rowtype;
  created_preflight_id uuid;
  candidate record;
  state_material text;
  state_hash text;
  eligible_targets integer;
  eligible_events integer;
  skipped_targets integer;
  blocked_targets integer;
  parent_groups integer;
  selected_template_revision_id uuid;
  selected_template_content_hash text;
  selected_branding_revision_id uuid;
  selected_branding_content_hash text;
  preview_group jsonb;
begin
  selected_count := coalesce(array_length(p_target_ids, 1), 0);
  if p_request_id is null
    or selected_count not between 1 and 2000
    or selected_count <> (
      select count(distinct selected_id)
      from unnest(p_target_ids) selected_id
    )
    or not private.mail_v2_campaign_role_allowed(
      p_template_key,
      actor_role
    )
    or not exists(
      select 1
      from private.mail_v2_process_capabilities capability
      where capability.template_key = p_template_key
        and capability.enabled
    )
  then
    raise exception 'MAIL_V2_CAMPAIGN_INPUT_INVALID' using errcode = '22023';
  end if;
  if not private.mail_templates_v2_cutover_started() then
    raise exception 'MAIL_V2_CAMPAIGN_CUTOVER_REQUIRED'
      using errcode = '55000';
  end if;
  select revision.id, revision.content_hash
  into selected_template_revision_id, selected_template_content_hash
  from app.mail_template_revisions revision
  where revision.template_key = p_template_key
    and revision.status = 'published'
    and revision.sanitized_html_source is not null
  for share;
  select branding.id, branding.content_hash
  into selected_branding_revision_id, selected_branding_content_hash
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated
  for share;
  if selected_template_revision_id is null
    or selected_branding_revision_id is null
  then
    raise exception 'MAIL_V2_CAMPAIGN_NOT_READY' using errcode = '55000';
  end if;
  if p_template_key = 'portal_access_reminder' then
    if (
      select count(distinct member_season.season_id)
      from app.member_seasons member_season
      where member_season.id = any(p_target_ids)
    ) <> 1 or (
      select count(*)
      from app.member_seasons member_season
      where member_season.id = any(p_target_ids)
    ) <> selected_count then
      raise exception 'MAIL_V2_CAMPAIGN_SELECTION_INVALID'
        using errcode = '23514';
    end if;
    select min(member_season.season_id::text)::uuid into selected_season_id
    from app.member_seasons member_season
    where member_season.id = any(p_target_ids);
  else
    if (
      select count(distinct orders.season_id)
      from app.member_orders orders
      where orders.id = any(p_target_ids)
    ) <> 1 or (
      select count(*)
      from app.member_orders orders
      where orders.id = any(p_target_ids)
    ) <> selected_count then
      raise exception 'MAIL_V2_CAMPAIGN_SELECTION_INVALID'
        using errcode = '23514';
    end if;
    select min(orders.season_id::text)::uuid into selected_season_id
    from app.member_orders orders
    where orders.id = any(p_target_ids);
  end if;
  perform private.lock_mail_v2_campaign_state(
    p_template_key,
    p_target_ids,
    false
  );
  selection_hash := encode(
    extensions.digest(
      convert_to(
        p_template_key || E'\n' || (
          select string_agg(selected_id::text, E'\n' order by selected_id)
          from unnest(p_target_ids) selected_id
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('mail-v2-campaign-preview:' || p_request_id::text, 0)
  );
  select * into existing
  from private.mail_v2_campaign_preflights preflight
  where preflight.actor_user_id = actor
    and preflight.request_id = p_request_id;
  if found then
    if existing.template_key <> p_template_key
      or existing.selection_hash <> selection_hash
    then
      raise exception 'MAIL_V2_CAMPAIGN_REQUEST_CONFLICT'
        using errcode = '23505';
    end if;
    return private.mail_v2_campaign_preflight_json(existing.id)
      || jsonb_build_object('reused', true);
  end if;

  created_preflight_id := gen_random_uuid();
  insert into private.mail_v2_campaign_preflights(
    id,
    request_id,
    actor_user_id,
    template_key,
    template_revision_id,
    branding_revision_id,
    season_id,
    selection_hash,
    eligibility_revision,
    selected_target_count,
    eligible_target_count,
    eligible_event_count,
    skipped_target_count,
    blocked_target_count,
    parent_group_count,
    expires_at
  ) values (
    created_preflight_id,
    p_request_id,
    actor,
    p_template_key,
    selected_template_revision_id,
    selected_branding_revision_id,
    selected_season_id,
    selection_hash,
    repeat('0', 64),
    selected_count,
    0,
    0,
    0,
    0,
    0,
    timezone('utc', now()) + interval '10 minutes'
  );

  for candidate in
    select *
    from private.mail_v2_campaign_candidates(
      p_template_key,
      selected_season_id,
      p_target_ids
    )
  loop
    insert into private.mail_v2_campaign_preflight_items(
      preflight_id,
      target_kind,
      target_id,
      order_id,
      member_season_id,
      parent_account_id,
      order_line_id,
      outcome,
      reason_code
    ) values (
      created_preflight_id,
      candidate.target_kind,
      candidate.target_id,
      candidate.order_id,
      candidate.member_season_id,
      candidate.parent_account_id,
      candidate.order_line_id,
      candidate.outcome,
      candidate.reason_code
    );
  end loop;

  if exists(
    select 1
    from private.mail_v2_campaign_preflight_items item
    where item.preflight_id = created_preflight_id
      and item.outcome = 'eligible'
    group by item.parent_account_id
    having count(*) > 100
  ) then
    raise exception 'MAIL_V2_CAMPAIGN_PARENT_GROUP_LIMIT'
      using errcode = '54000';
  end if;
  select
    coalesce(string_agg(
      concat_ws(
        ':',
        item.target_kind,
        item.target_id::text,
        coalesce(item.parent_account_id::text, 'none'),
        coalesce(item.order_line_id::text, 'none'),
        item.outcome,
        item.reason_code,
        case when item.outcome = 'eligible' then encode(
          extensions.digest(
            convert_to(
              private.mail_v2_member_payload(
                p_template_key,
                item.parent_account_id,
                item.member_season_id,
                created_preflight_id,
                item.order_line_id
              )::text,
              'UTF8'
            ),
            'sha256'
          ),
          'hex'
        ) else 'not-eligible' end
      ),
      E'\n'
      order by
        item.target_kind,
        item.target_id,
        item.parent_account_id,
        item.order_line_id,
        item.outcome
    ), '')
  into state_material
  from private.mail_v2_campaign_preflight_items item
  where item.preflight_id = created_preflight_id;
  state_hash := encode(
    extensions.digest(convert_to(
      concat_ws(
        E'\n',
        selected_template_revision_id::text,
        selected_template_content_hash,
        selected_branding_revision_id::text,
        selected_branding_content_hash,
        state_material
      ),
      'UTF8'
    ), 'sha256'),
    'hex'
  );
  with target_outcome as (
    select
      item.target_id,
      case
        when bool_or(item.outcome = 'eligible') then 'eligible'
        when bool_or(item.outcome = 'blocked') then 'blocked'
        else 'skipped'
      end outcome
    from private.mail_v2_campaign_preflight_items item
    where item.preflight_id = created_preflight_id
    group by item.target_id
  )
  select
    count(*) filter (where target_outcome.outcome = 'eligible'),
    (
      select count(*)
      from private.mail_v2_campaign_preflight_items item
      where item.preflight_id = created_preflight_id
        and item.outcome = 'eligible'
    ),
    count(*) filter (where target_outcome.outcome = 'skipped'),
    count(*) filter (where target_outcome.outcome = 'blocked'),
    (
      select count(distinct item.parent_account_id)
      from private.mail_v2_campaign_preflight_items item
      where item.preflight_id = created_preflight_id
        and item.outcome = 'eligible'
    )
  into
    eligible_targets,
    eligible_events,
    skipped_targets,
    blocked_targets,
    parent_groups
  from target_outcome;
  update private.mail_v2_campaign_preflights
  set eligibility_revision = state_hash,
      eligible_target_count = eligible_targets,
      eligible_event_count = eligible_events,
      skipped_target_count = skipped_targets,
      blocked_target_count = blocked_targets,
      parent_group_count = parent_groups
  where id = created_preflight_id;
  if eligible_events > 0 then
    preview_group := private.mail_v2_campaign_preflight_json_live_v1(
      created_preflight_id
    )->'previewGroup';
    if not private.mail_v2_campaign_preview_group_is_safe(preview_group) then
      raise exception 'MAIL_V2_CAMPAIGN_PREVIEW_INVALID'
        using errcode = '23514';
    end if;
    update private.mail_v2_campaign_preflights
    set preview_group_snapshot = preview_group
    where id = created_preflight_id;
  end if;
  return private.mail_v2_campaign_preflight_json(created_preflight_id)
    || jsonb_build_object('reused', false);
end;
$$;

revoke all on function app.preview_mail_v2_campaign_v1(
  text, uuid[], uuid
) from public, anon;
grant execute on function app.preview_mail_v2_campaign_v1(
  text, uuid[], uuid
) to authenticated;

create or replace function private.mail_v2_campaign_result_json(
  p_run_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select run.result_snapshot
  from private.mail_v2_campaign_runs run
  where run.id = p_run_id;
$$;

revoke all on function private.mail_v2_campaign_result_json(uuid)
from public, anon, authenticated, service_role;

create or replace function app.confirm_mail_v2_campaign_v1(
  p_preflight_id uuid,
  p_expected_revision text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  actor_role app.staff_role := app.staff_role();
  preflight private.mail_v2_campaign_preflights%rowtype;
  prior private.mail_v2_campaign_runs%rowtype;
  selected_target_ids uuid[];
  candidate record;
  state_material text;
  current_revision text;
  run_id uuid := gen_random_uuid();
  event_id uuid;
  event_count integer := 0;
  projection_group record;
  projection_batch_id uuid;
  result jsonb;
begin
  if p_preflight_id is null
    or p_request_id is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
  then
    raise exception 'MAIL_V2_CAMPAIGN_CONFIRM_INVALID'
      using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-v2-campaign-confirm:' || p_request_id::text, 0)
  );
  select * into prior
  from private.mail_v2_campaign_runs run
  where run.confirmation_request_id = p_request_id;
  if found then
    if prior.actor_user_id <> actor
      or not private.mail_v2_campaign_role_allowed(
        prior.template_key,
        actor_role
      )
    then
      raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
    end if;
    if prior.preflight_id <> p_preflight_id
      or prior.eligibility_revision <> p_expected_revision
    then
      raise exception 'MAIL_V2_CAMPAIGN_CONFIRM_CONFLICT'
        using errcode = '23505';
    end if;
    return private.mail_v2_campaign_result_json(prior.id)
      || jsonb_build_object('reused', true);
  end if;
  select * into preflight
  from private.mail_v2_campaign_preflights candidate_preflight
  where candidate_preflight.id = p_preflight_id
  for update;
  if not found then
    raise exception 'MAIL_V2_CAMPAIGN_PREFLIGHT_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if preflight.actor_user_id <> actor
    or not private.mail_v2_campaign_role_allowed(
      preflight.template_key,
      actor_role
    )
    or not exists(
      select 1
      from private.mail_v2_process_capabilities capability
      where capability.template_key = preflight.template_key
        and capability.enabled
    )
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if preflight.expires_at <= timezone('utc', now()) then
    raise exception 'MAIL_V2_CAMPAIGN_PREFLIGHT_EXPIRED'
      using errcode = '55000';
  end if;
  if preflight.eligibility_revision <> p_expected_revision then
    raise exception 'MAIL_V2_CAMPAIGN_PREFLIGHT_STALE'
      using errcode = '40001';
  end if;
  select * into prior
  from private.mail_v2_campaign_runs run
  where run.preflight_id = preflight.id;
  if found then
    if prior.actor_user_id <> actor
      or prior.eligibility_revision <> p_expected_revision
    then
      raise exception 'MAIL_V2_CAMPAIGN_CONFIRM_CONFLICT'
        using errcode = '23505';
    end if;
    return private.mail_v2_campaign_result_json(prior.id)
      || jsonb_build_object('reused', true);
  end if;
  if preflight.eligible_event_count < 1 then
    raise exception 'MAIL_V2_CAMPAIGN_EMPTY' using errcode = '23514';
  end if;
  perform 1
  from app.mail_template_revisions revision
  join app.mail_branding_revisions branding
    on branding.id = preflight.branding_revision_id
    and branding.status = 'published'
    and branding.contrast_validated
  where revision.id = preflight.template_revision_id
    and revision.template_key = preflight.template_key
    and revision.status = 'published'
  for share of revision, branding;
  if not found then
    raise exception 'MAIL_V2_CAMPAIGN_CONTENT_CHANGED'
      using errcode = '40001';
  end if;
  select array_agg(distinct item.target_id order by item.target_id)
  into selected_target_ids
  from private.mail_v2_campaign_preflight_items item
  where item.preflight_id = preflight.id;
  perform private.lock_mail_v2_campaign_state(
    preflight.template_key,
    selected_target_ids,
    true
  );
  select coalesce(string_agg(
    concat_ws(
      ':',
      current_target.target_kind,
      current_target.target_id::text,
      coalesce(current_target.parent_account_id::text, 'none'),
      coalesce(current_target.order_line_id::text, 'none'),
      current_target.outcome,
      current_target.reason_code,
      case when current_target.outcome = 'eligible' then encode(
        extensions.digest(
          convert_to(
            private.mail_v2_member_payload(
              preflight.template_key,
              current_target.parent_account_id,
              current_target.member_season_id,
              preflight.id,
              current_target.order_line_id
            )::text,
            'UTF8'
          ),
          'sha256'
        ),
        'hex'
      ) else 'not-eligible' end
    ),
    E'\n'
    order by
      current_target.target_kind,
      current_target.target_id,
      current_target.parent_account_id,
      current_target.order_line_id,
      current_target.outcome
  ), '')
  into state_material
  from private.mail_v2_campaign_candidates(
    preflight.template_key,
    preflight.season_id,
    selected_target_ids
  ) current_target;
  current_revision := encode(
    extensions.digest(convert_to(
      concat_ws(
        E'\n',
        preflight.template_revision_id::text,
        (
          select revision.content_hash
          from app.mail_template_revisions revision
          where revision.id = preflight.template_revision_id
        ),
        preflight.branding_revision_id::text,
        (
          select branding.content_hash
          from app.mail_branding_revisions branding
          where branding.id = preflight.branding_revision_id
        ),
        state_material
      ),
      'UTF8'
    ), 'sha256'),
    'hex'
  );
  if current_revision <> preflight.eligibility_revision then
    raise exception 'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED'
      using errcode = '40001';
  end if;

  for candidate in
    select *
    from private.mail_v2_campaign_candidates(
      preflight.template_key,
      preflight.season_id,
      selected_target_ids
    )
    where outcome = 'eligible'
  loop
    event_id := private.enqueue_mail_v2_member_event(
      preflight.template_key,
      candidate.parent_account_id,
      candidate.member_season_id,
      'mail_campaign',
      run_id,
      run_id,
      concat_ws(
        ':',
        'mail-campaign-v2',
        run_id,
        candidate.parent_account_id,
        candidate.target_kind,
        candidate.target_id,
        coalesce(candidate.order_line_id::text, 'target')
      ),
      candidate.order_line_id
    );
    if private.mail_v2_event_state(event_id) <> 'eligible' then
      raise exception 'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED'
        using errcode = '40001';
    end if;
    event_count := event_count + 1;
  end loop;
  if event_count <> preflight.eligible_event_count then
    raise exception 'MAIL_V2_CAMPAIGN_EVENT_COUNT_CHANGED'
      using errcode = '40001';
  end if;

  -- Bind every confirmed family group to exactly the content revisions shown
  -- in the preflight. The normal projector then claims these expired leases,
  -- revalidates the recipients and renders an immutable job snapshot.
  perform set_config('app.mail_v2_projection_internal', 'on', true);
  for projection_group in
    select
      event.parent_account_id,
      count(*)::integer event_count
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_campaign'
      and event.source_id = run_id
      and event.cohort_id = run_id
    group by event.parent_account_id
    order by event.parent_account_id
  loop
    projection_batch_id := gen_random_uuid();
    insert into private.mail_v2_projection_batches(
      id,
      parent_account_id,
      season_id,
      template_key,
      cohort_id,
      template_revision_id,
      branding_revision_id,
      status,
      lease_token,
      lease_expires_at,
      event_count
    ) values (
      projection_batch_id,
      projection_group.parent_account_id,
      preflight.season_id,
      preflight.template_key,
      run_id,
      preflight.template_revision_id,
      preflight.branding_revision_id,
      'leased',
      gen_random_uuid(),
      timezone('utc', now()),
      projection_group.event_count
    );
    insert into private.mail_v2_projections(
      event_id,
      projection_batch_id
    )
    select event.id, projection_batch_id
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_campaign'
      and event.source_id = run_id
      and event.cohort_id = run_id
      and event.parent_account_id = projection_group.parent_account_id
    order by event.created_at, event.id;
  end loop;

  result := jsonb_build_object(
    'runId',
    run_id,
    'templateKey',
    preflight.template_key,
    'eventCount',
    event_count,
    'parentGroupCount',
    preflight.parent_group_count,
    'reused',
    false
  );
  insert into private.mail_v2_campaign_runs(
    id,
    preflight_id,
    confirmation_request_id,
    actor_user_id,
    template_key,
    season_id,
    cohort_id,
    eligibility_revision,
    event_count,
    parent_group_count,
    result_snapshot
  ) values (
    run_id,
    preflight.id,
    p_request_id,
    actor,
    preflight.template_key,
    preflight.season_id,
    run_id,
    preflight.eligibility_revision,
    event_count,
    preflight.parent_group_count,
    result
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_v2.campaign.confirmed',
    'mail_v2_campaign_run',
    run_id,
    jsonb_build_object(
      'templateKey',
      preflight.template_key,
      'seasonId',
      preflight.season_id,
      'selectedTargetCount',
      preflight.selected_target_count,
      'eligibleTargetCount',
      preflight.eligible_target_count,
      'eventCount',
      event_count,
      'parentGroupCount',
      preflight.parent_group_count,
      'eligibilityRevision',
      preflight.eligibility_revision
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.confirm_mail_v2_campaign_v1(
  uuid, text, uuid, uuid
) from public, anon;
grant execute on function app.confirm_mail_v2_campaign_v1(
  uuid, text, uuid, uuid
) to authenticated;

create or replace function app.get_mail_v2_campaign_workspace_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  actor_role app.staff_role := app.staff_role();
begin
  if actor is null or actor_role not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'cutoverStarted',
    private.mail_templates_v2_cutover_started(),
    'featureEnabled',
    private.mail_templates_v2_enabled(),
    'allowedTemplates',
    coalesce((
      select jsonb_agg(template.template_key order by template.template_key)
      from app.mail_templates template
      where template.active
        and exists(
          select 1
          from private.mail_v2_process_capabilities capability
          where capability.template_key = template.template_key
            and capability.enabled
        )
        and private.mail_v2_campaign_role_allowed(
          template.template_key,
          actor_role
        )
    ), '[]'::jsonb),
    'orderTargets',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderId', target.order_id,
        'memberSeasonId', target.member_season_id,
        'seasonId', target.season_id,
        'memberName', target.member_name,
        'relationNumber', target.relation_number,
        'team', target.team_name,
        'season', target.season_name,
        'amountDueCents', target.amount_due_cents
      ) order by target.season_name, target.member_name, target.order_id)
      from (
        select
          orders.id order_id,
          member_season.id member_season_id,
          season.id season_id,
          concat_ws(
            ' ',
            member.first_name,
            nullif(member.insertion, ''),
            member.last_name
          ) member_name,
          member.relation_number,
          coalesce(member_season.team_name, 'Niet opgegeven') team_name,
          season.name season_name,
          orders.amount_due_cents
        from app.member_orders orders
        join app.member_seasons member_season
          on member_season.id = orders.member_season_id
          and member_season.season_id = orders.season_id
          and member_season.participation_status = 'active'
        join app.members member on member.id = member_season.member_id
        join app.seasons season
          on season.id = member_season.season_id
          and season.status = 'open'
        where orders.active_package_snapshot_id is not null
          and exists(
            select 1
            from app.order_lines line
            where line.order_id = orders.id
              and line.status <> 'cancelled'
          )
        order by season.name, member_name, orders.id
        limit 20000
      ) target
    ), '[]'::jsonb),
    'portalTargets',
    case when actor_role = 'beheerder' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberSeasonId', target.member_season_id,
        'memberName', target.member_name,
        'team', target.team_name,
        'season', target.season_name,
        'reminderEligible', target.reminder_eligible
      ) order by target.member_name, target.member_season_id)
      from (
        select
          member_season.id member_season_id,
          concat_ws(
            ' ',
            member.first_name,
            nullif(member.insertion, ''),
            member.last_name
          ) member_name,
          coalesce(member_season.team_name, 'Niet opgegeven') team_name,
          season.name season_name,
          bool_or(
            account.last_login_at is null
            or account.last_login_at < grant_row.granted_at
          ) reminder_eligible
        from app.member_seasons member_season
        join app.members member on member.id = member_season.member_id
        join app.seasons season on season.id = member_season.season_id
        join private.parent_portal_grants grant_row
          on grant_row.member_season_id = member_season.id
          and grant_row.status = 'active'
        join private.parent_accounts account
          on account.id = grant_row.parent_account_id
        where member_season.participation_status = 'active'
          and season.status = 'open'
        group by
          member_season.id,
          member.first_name,
          member.insertion,
          member.last_name,
          member_season.team_name,
          season.name
        order by member_name, member_season.id
        limit 20000
      ) target
    ), '[]'::jsonb) else '[]'::jsonb end,
    'recentRuns',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'runId',
        recent.id,
        'templateKey',
        recent.template_key,
        'eventCount',
        recent.event_count,
        'parentGroupCount',
        recent.parent_group_count,
        'createdAt',
        recent.created_at
      ) order by recent.created_at desc, recent.id desc)
      from (
        select run.*
        from private.mail_v2_campaign_runs run
        where run.actor_user_id = actor
          or actor_role = 'beheerder'
        order by run.created_at desc, run.id desc
        limit 25
      ) recent
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_mail_v2_campaign_workspace_v1()
from public, anon;
grant execute on function app.get_mail_v2_campaign_workspace_v1()
to authenticated;

create or replace function app.purge_mail_v2_campaign_preflights_v1(
  p_now timestamptz,
  p_retention_hours integer default 24,
  p_limit integer default 500
)
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  deleted_count integer;
begin
  if p_now is null
    or p_retention_hours not between 1 and 168
    or p_limit not between 1 and 5000
  then
    raise exception 'MAIL_V2_CAMPAIGN_RETENTION_INVALID'
      using errcode = '22023';
  end if;
  perform set_config('app.mail_v2_campaign_retention', 'on', true);
  with expired as (
    select preflight.id
    from private.mail_v2_campaign_preflights preflight
    where preflight.expires_at <=
      p_now - make_interval(hours => p_retention_hours)
    order by preflight.expires_at, preflight.id
    for update skip locked
    limit p_limit
  ),
  deleted_items as (
    delete from private.mail_v2_campaign_preflight_items item
    where item.preflight_id in (select expired.id from expired)
    returning item.preflight_id
  )
  delete from private.mail_v2_campaign_preflights preflight
  where preflight.id in (select expired.id from expired);
  get diagnostics deleted_count = row_count;
  perform set_config('app.mail_v2_campaign_retention', 'off', true);
  return deleted_count;
end;
$$;

revoke all on function app.purge_mail_v2_campaign_preflights_v1(
  timestamptz, integer, integer
) from public, anon, authenticated;
grant execute on function app.purge_mail_v2_campaign_preflights_v1(
  timestamptz, integer, integer
) to service_role;

insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
) values
  ('portal_access_invite', 1),
  ('size_fill_request', 1),
  ('size_review_request', 1),
  ('size_confirmed', 1),
  ('payment_request', 1),
  ('payment_received_waiting_stock', 1),
  ('available_payment_required', 1),
  ('pickup_ready', 1),
  ('out_of_stock', 1),
  ('back_in_stock', 1),
  ('internal_email_failure', 1)
on conflict (template_key) do update
set producer_version = excluded.producer_version,
    enabled = true,
    registered_at = timezone('utc', now());

comment on function app.preview_mail_v2_campaign_v1(
  text, uuid[], uuid
) is
  'Actor-bound ten-minute preflight with current eligibility and published template preview.';
comment on function app.confirm_mail_v2_campaign_v1(
  uuid, text, uuid, uuid
) is
  'Revalidates campaign state and appends one consolidated event cohort without provider side effects.';

select pg_notify('pgrst', 'reload schema');

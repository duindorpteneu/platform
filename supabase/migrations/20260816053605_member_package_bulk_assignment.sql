-- Bulk package assignment for the current open season.
--
-- A package remains the commercial order snapshot. Confirmed member sizes are
-- projected into component order lines; an absent/conflicting size never
-- creates a guessed variant. Removal is a soft withdrawal: every commercial
-- snapshot stays intact and downstream mutations are fail-closed.

alter table app.member_orders
  add column package_assignment_state text not null default 'active',
  add column package_withdrawn_at timestamptz,
  add column package_withdrawn_by uuid,
  add column package_withdrawal_reason text,
  add constraint member_orders_package_assignment_state_check check (
    (
      package_assignment_state = 'active'
      and package_withdrawn_at is null
      and package_withdrawn_by is null
      and package_withdrawal_reason is null
    )
    or (
      package_assignment_state = 'withdrawn'
      and package_revision_id is not null
      and package_withdrawn_at is not null
      and package_withdrawn_by is not null
      and length(btrim(package_withdrawal_reason)) between 3 and 500
    )
  ) not valid;

alter table app.member_orders
  validate constraint member_orders_package_assignment_state_check;

create or replace function private.guard_package_assignment_state()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if new.package_assignment_state is distinct from old.package_assignment_state
    and current_setting('app.package_assignment_internal', true)
      is distinct from 'on'
  then
    raise exception 'PACKAGE_ASSIGNMENT_STATE_PROTECTED' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger member_orders_guard_package_assignment_state
before update of
  package_assignment_state,
  package_withdrawn_at,
  package_withdrawn_by,
  package_withdrawal_reason
on app.member_orders
for each row execute function private.guard_package_assignment_state();

create or replace function private.require_active_package_assignment()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
declare
  target_order_id uuid;
begin
  if tg_table_name in ('payments', 'order_lines', 'inventory_allocations') then
    target_order_id := new.order_id;
  elsif tg_table_name = 'inventory_reservations' then
    select line.order_id into target_order_id
    from app.order_lines line where line.id = new.order_line_id;
  end if;
  if target_order_id is not null and exists(
    select 1 from app.member_orders orders
    where orders.id = target_order_id
      and orders.package_assignment_state = 'withdrawn'
  ) then
    raise exception 'PACKAGE_ASSIGNMENT_WITHDRAWN' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger payments_require_active_package_assignment
before insert or update of order_id on app.payments
for each row execute function private.require_active_package_assignment();
create trigger order_lines_require_active_package_assignment
before insert or update of order_id, status on app.order_lines
for each row
when (new.status <> 'cancelled')
execute function private.require_active_package_assignment();
create trigger inventory_reservations_require_active_package_assignment
before insert or update of order_line_id, status on app.inventory_reservations
for each row execute function private.require_active_package_assignment();
create trigger inventory_allocations_require_active_package_assignment
before insert or update of order_id, order_line_id, status on app.inventory_allocations
for each row execute function private.require_active_package_assignment();

-- Every existing selector (parent, individual staff and this bulk flow) must
-- reactivate a safely withdrawn order instead of returning a false no-op.
do $migration$
declare
  function_source text;
  found_needle text := $needle$
  if found then
    previous_revision_id := target_order.package_revision_id;
$needle$;
  found_replacement text := $replacement$
  if found then
    previous_revision_id := target_order.package_revision_id;
    if target_order.package_assignment_state = 'withdrawn' then
      if not private.package_order_can_switch(target_order.id) then
        raise exception 'PACKAGE_REACTIVATION_REQUIRES_ADMIN_WORKFLOW'
          using errcode = '23514';
      end if;
      perform set_config('app.package_assignment_internal', 'on', true);
      update app.member_orders
      set package_assignment_state = 'active',
          package_withdrawn_at = null,
          package_withdrawn_by = null,
          package_withdrawal_reason = null,
          updated_at = timezone('utc', now())
      where id = target_order.id
      returning * into target_order;
      perform set_config('app.package_assignment_internal', 'off', true);
      changed := true;
    end if;
$replacement$;
  same_needle text := $needle$
    if target_order.package_revision_id = revision.id
      and target_order.amount_due_cents = revision.price_cents
    then
$needle$;
  same_replacement text := $replacement$
    if target_order.package_revision_id = revision.id
      and target_order.amount_due_cents = revision.price_cents
      and not changed
    then
$replacement$;
  action_needle text := $needle$
    case
      when previous_revision_id is null then 'package_order.selected'
      else 'package_order.switched'
    end,
$needle$;
  action_replacement text := $replacement$
    case
      when previous_revision_id is null then 'package_order.selected'
      when previous_revision_id = revision.id and changed
        then 'package_order.reactivated'
      else 'package_order.switched'
    end,
$replacement$;
begin
  function_source := pg_get_functiondef(
    'private.apply_member_package_selection(uuid,uuid,text,uuid,uuid,text,uuid)'::regprocedure
  );
  if (length(function_source) - length(replace(function_source, found_needle, '')))
      / length(found_needle) <> 1
    or (length(function_source) - length(replace(function_source, same_needle, '')))
      / length(same_needle) <> 1
    or (length(function_source) - length(replace(function_source, action_needle, '')))
      / length(action_needle) <> 1
  then
    raise exception 'PACKAGE_ASSIGNMENT_REACTIVATION_PATCH_AMBIGUOUS';
  end if;
  execute replace(replace(replace(
    function_source,
    found_needle, found_replacement
  ), same_needle, same_replacement), action_needle, action_replacement);
end;
$migration$;

create table private.member_package_bulk_requests (
  request_id uuid primary key,
  staff_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  package_revision_id uuid
    references app.package_template_revisions(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (jsonb_typeof(result_snapshot) = 'object'),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.member_package_bulk_requests enable row level security;
revoke all on table private.member_package_bulk_requests
from public, anon, authenticated, service_role;

create or replace function private.protect_member_package_bulk_request()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'MEMBER_PACKAGE_BULK_REQUEST_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger member_package_bulk_requests_immutable
before update or delete on private.member_package_bulk_requests
for each row execute function private.protect_member_package_bulk_request();

create or replace function private.member_package_bulk_preview(
  p_action text,
  p_scope text,
  p_member_season_ids uuid[],
  p_package_revision_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  active_season_id uuid;
  normalized_ids uuid[];
  requested_count integer;
  package_state jsonb := 'null'::jsonb;
  target_state jsonb := '[]'::jsonb;
  revision_hash text;
  eligible_count integer := 0;
  unchanged_count integer := 0;
  blocked_count integer := 0;
  linked_count integer := 0;
  missing_count integer := 0;
begin
  normalized_ids := coalesce((
    select array_agg(distinct item order by item)
    from unnest(coalesce(p_member_season_ids, array[]::uuid[])) item
  ), array[]::uuid[]);
  if p_action not in ('assign', 'remove')
    or p_scope not in ('selected', 'all_active')
    or (p_scope = 'selected' and cardinality(normalized_ids) not between 1 and 50)
    or (p_scope = 'all_active' and cardinality(normalized_ids) <> 0)
    or (p_action = 'assign' and p_package_revision_id is null)
    or (p_action = 'remove' and p_package_revision_id is not null)
  then
    raise exception 'MEMBER_PACKAGE_BULK_INVALID' using errcode = '22023';
  end if;
  if cardinality(normalized_ids) <> cardinality(coalesce(p_member_season_ids, array[]::uuid[])) then
    raise exception 'MEMBER_PACKAGE_BULK_DUPLICATE_TARGET'
      using errcode = '22023';
  end if;
  if not private.package_orders_v2_enabled() then
    raise exception 'PACKAGE_ORDER_FEATURE_DISABLED' using errcode = '42501';
  end if;

  select settings.active_season_id
  into active_season_id
  from app.app_settings settings
  join app.seasons season
    on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true;
  if active_season_id is null then
    raise exception 'ACTIVE_OPEN_SEASON_REQUIRED' using errcode = '23514';
  end if;

  if p_action = 'assign' then
    select jsonb_build_object(
      'revisionId', revision.id,
      'seasonId', revision.season_id,
      'revisionNumber', revision.revision_number,
      'name', revision.name,
      'priceCents', revision.price_cents,
      'currency', revision.currency,
      'updatedState', concat_ws(':', revision.status, revision.active, revision.is_default),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', item.id,
          'articleId', item.article_id,
          'quantity', item.quantity,
          'name', item.product_name_snapshot,
          'code', item.product_code_snapshot,
          'sortOrder', item.sort_order
        ) order by item.sort_order, item.id)
        from app.package_template_items item
        where item.revision_id = revision.id
      ), '[]'::jsonb)
    )
    into package_state
    from app.package_template_revisions revision
    where revision.id = p_package_revision_id
      and revision.season_id = active_season_id
      and revision.status = 'published'
      and revision.active;
    if package_state is null
      or jsonb_array_length(package_state->'items') = 0
    then
      raise exception 'PACKAGE_REVISION_NOT_AVAILABLE' using errcode = '23514';
    end if;
  end if;

  requested_count := case
    when p_scope = 'selected' then cardinality(normalized_ids)
    else (
      select count(*)::integer
      from app.member_seasons member_season
      where member_season.season_id = active_season_id
        and member_season.participation_status = 'active'
        and member_season.reconciliation_status = 'resolved'
    )
  end;

  with targets as (
    select member_season.*
    from app.member_seasons member_season
    where member_season.season_id = active_season_id
      and member_season.participation_status = 'active'
      and member_season.reconciliation_status = 'resolved'
      and (
        p_scope = 'all_active'
        or member_season.id = any(normalized_ids)
      )
  ), states as (
    select
      target.id member_season_id,
      target.member_id,
      target.updated_at member_season_updated_at,
      orders.id order_id,
      orders.package_revision_id current_package_revision_id,
      orders.active_package_snapshot_id,
      orders.package_assignment_state,
      orders.amount_due_cents,
      orders.order_status,
      orders.updated_at order_updated_at,
      case when orders.id is null then true
        else private.package_order_can_switch(orders.id)
      end can_change,
      coalesce(size_counts.linked_count, 0) linked_count,
      coalesce(size_counts.missing_count, 0) missing_count,
      coalesce(line_state.value, '') line_state,
      coalesce(payment_state.value, '') payment_state,
      coalesce(allocation_state.value, '') allocation_state
    from targets target
    left join app.member_orders orders
      on orders.member_season_id = target.id
    left join lateral (
      select
        count(*) filter (where
          size_profile.selection_status in ('confirmed', 'locked')
          and size_profile.article_variant_id is not null
          and variant.id is not null
        )::integer linked_count,
        count(*) filter (where not (
          size_profile.selection_status in ('confirmed', 'locked')
          and size_profile.article_variant_id is not null
          and variant.id is not null
        ))::integer missing_count
      from app.package_template_items item
      left join app.member_article_sizes size_profile
        on size_profile.member_season_id = target.id
        and size_profile.article_id = item.article_id
      left join app.article_variants variant
        on variant.id = size_profile.article_variant_id
        and variant.article_id = item.article_id
        and variant.active
      left join app.article_seasons article_season
        on article_season.article_id = item.article_id
        and article_season.season_id = active_season_id
      where item.revision_id = p_package_revision_id
        and article_season.article_id is not null
    ) size_counts on p_action = 'assign'
    left join lateral (
      select string_agg(concat_ws(':', line.id, line.article_id,
        line.article_variant_id, line.quantity, line.status,
        line.package_template_item_id, line.updated_at), ',' order by line.id) value
      from app.order_lines line where line.order_id = orders.id
    ) line_state on true
    left join lateral (
      select string_agg(concat_ws(':', payment.id, payment.status,
        payment.amount_cents, payment.updated_at), ',' order by payment.id) value
      from app.payments payment where payment.order_id = orders.id
    ) payment_state on true
    left join lateral (
      select string_agg(concat_ws(':', reservation.id, reservation.status,
        reservation.order_line_id, reservation.updated_at), ',' order by reservation.id) value
      from app.inventory_reservations reservation
      join app.order_lines line on line.id = reservation.order_line_id
      where line.order_id = orders.id
    ) allocation_state on true
  ), classified as (
    select states.*,
      case
        when p_action = 'remove'
          and (current_package_revision_id is null
            or package_assignment_state = 'withdrawn')
          then 'unchanged'
        when p_action = 'remove' and can_change then 'eligible'
        when p_action = 'remove' then 'blocked'
        when order_id is null then 'eligible'
        when package_assignment_state = 'withdrawn' and can_change
          then 'eligible'
        when package_assignment_state = 'withdrawn' then 'blocked'
        when current_package_revision_id is distinct from p_package_revision_id
          and can_change then 'eligible'
        when current_package_revision_id is distinct from p_package_revision_id
          then 'blocked'
        when can_change and exists(
          select 1
          from app.package_template_items item
          join app.member_article_sizes size_profile
            on size_profile.member_season_id = states.member_season_id
            and size_profile.article_id = item.article_id
            and size_profile.selection_status in ('confirmed', 'locked')
          join app.article_variants variant
            on variant.id = size_profile.article_variant_id
            and variant.article_id = item.article_id
            and variant.active
          where item.revision_id = p_package_revision_id
            and not exists(
              select 1 from app.order_lines line
              where line.order_id = states.order_id
                and line.article_id = item.article_id
                and line.article_variant_id = size_profile.article_variant_id
                and line.quantity = item.quantity
                and line.status <> 'cancelled'
            )
        ) then 'eligible'
        else 'unchanged'
      end disposition
    from states
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'memberSeasonId', classified.member_season_id,
      'memberId', classified.member_id,
      'memberSeasonUpdatedAt', classified.member_season_updated_at,
      'orderId', classified.order_id,
      'currentPackageRevisionId', classified.current_package_revision_id,
      'activePackageSnapshotId', classified.active_package_snapshot_id,
      'packageAssignmentState', classified.package_assignment_state,
      'amountDueCents', classified.amount_due_cents,
      'orderStatus', classified.order_status,
      'orderUpdatedAt', classified.order_updated_at,
      'canChange', classified.can_change,
      'linkedCount', classified.linked_count,
      'missingCount', classified.missing_count,
      'lineState', classified.line_state,
      'paymentState', classified.payment_state,
      'allocationState', classified.allocation_state,
      'disposition', classified.disposition
    ) order by classified.member_season_id), '[]'::jsonb),
    count(*) filter (where classified.disposition = 'eligible')::integer,
    count(*) filter (where classified.disposition = 'unchanged')::integer,
    count(*) filter (where classified.disposition = 'blocked')::integer,
    coalesce(sum(classified.linked_count) filter (where classified.disposition = 'eligible'), 0)::integer,
    coalesce(sum(classified.missing_count) filter (where classified.disposition = 'eligible'), 0)::integer
  into target_state, eligible_count, unchanged_count, blocked_count,
    linked_count, missing_count
  from classified;

  revision_hash := encode(extensions.digest(jsonb_build_object(
    'contract', 'member-package-bulk-v1',
    'action', p_action,
    'scope', p_scope,
    'memberSeasonIds', to_jsonb(normalized_ids),
    'seasonId', active_season_id,
    'package', package_state,
    'targets', target_state
  )::text, 'sha256'), 'hex');

  return jsonb_build_object(
    'action', p_action,
    'scope', p_scope,
    'seasonId', active_season_id,
    'packageRevisionId', p_package_revision_id,
    'requestedCount', requested_count,
    'matchedCount', jsonb_array_length(target_state),
    'eligibleCount', eligible_count,
    'unchangedCount', unchanged_count,
    'blockedCount', blocked_count,
    'inactiveOrInvalidCount', greatest(
      requested_count - jsonb_array_length(target_state), 0
    ),
    'linkedSizeCount', linked_count,
    'missingSizeCount', missing_count,
    'revision', revision_hash,
    'targets', target_state
  );
end;
$$;

revoke all on function private.member_package_bulk_preview(
  text, text, uuid[], uuid
) from public, anon, authenticated, service_role;

create or replace function app.get_member_package_bulk_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  active_season_id uuid;
begin
  select settings.active_season_id into active_season_id
  from app.app_settings settings
  join app.seasons season
    on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true;
  return jsonb_build_object(
    'enabled', private.package_orders_v2_enabled(),
    'seasonId', active_season_id,
    'packages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'revisionId', revision.id,
        'name', revision.name,
        'priceCents', revision.price_cents,
        'currency', revision.currency,
        'revisionNumber', revision.revision_number,
        'default', revision.is_default,
        'itemCount', (
          select count(*)::integer from app.package_template_items item
          where item.revision_id = revision.id
        )
      ) order by revision.is_default desc, revision.name, revision.revision_number desc)
      from app.package_template_revisions revision
      where revision.season_id = active_season_id
        and revision.status = 'published'
        and revision.active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.preview_member_package_bulk_v1(
  p_action text,
  p_scope text,
  p_member_season_ids uuid[] default array[]::uuid[],
  p_package_revision_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  result jsonb;
begin
  result := private.member_package_bulk_preview(
    p_action, p_scope, p_member_season_ids, p_package_revision_id
  );
  return result - 'targets';
end;
$$;

create or replace function app.apply_member_package_bulk_v1(
  p_action text,
  p_scope text,
  p_member_season_ids uuid[],
  p_package_revision_id uuid,
  p_expected_season_id uuid,
  p_expected_revision text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  normalized_reason text := btrim(coalesce(p_reason, ''));
  normalized_ids uuid[];
  computed_hash text;
  existing private.member_package_bulk_requests%rowtype;
  preview jsonb;
  target jsonb;
  target_member_season_id uuid;
  target_order app.member_orders%rowtype;
  snapshot_item app.order_package_snapshot_items%rowtype;
  confirmed_size_row app.member_article_sizes%rowtype;
  component record;
  active_line app.order_lines%rowtype;
  changed_count integer := 0;
  linked_count integer := 0;
  result jsonb;
begin
  normalized_ids := coalesce((
    select array_agg(distinct item order by item)
    from unnest(coalesce(p_member_season_ids, array[]::uuid[])) item
  ), array[]::uuid[]);
  if p_request_id is null
    or p_expected_season_id is null
    or coalesce(p_expected_revision, '') !~ '^[0-9a-f]{64}$'
    or length(normalized_reason) not between 3 and 500
  then
    raise exception 'MEMBER_PACKAGE_BULK_INVALID' using errcode = '22023';
  end if;
  computed_hash := encode(extensions.digest(jsonb_build_object(
    'action', p_action,
    'scope', p_scope,
    'memberSeasonIds', to_jsonb(normalized_ids),
    'packageRevisionId', p_package_revision_id,
    'seasonId', p_expected_season_id,
    'revision', p_expected_revision,
    'reason', normalized_reason
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended('member-package-bulk-request:' || p_request_id::text, 0)
  );
  select * into existing
  from private.member_package_bulk_requests request
  where request.request_id = p_request_id
  for update;
  if found then
    if existing.staff_user_id <> actor
      or existing.request_hash <> computed_hash
    then
      raise exception 'MEMBER_PACKAGE_BULK_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('member-package-bulk-season:' || p_expected_season_id::text, 0)
  );
  perform 1 from app.member_seasons member_season
  where member_season.season_id = p_expected_season_id
    and (
      p_scope = 'all_active'
      or member_season.id = any(normalized_ids)
    )
  order by member_season.id for update;
  perform 1 from app.member_orders orders
  where orders.season_id = p_expected_season_id
    and (
      p_scope = 'all_active'
      or orders.member_season_id = any(normalized_ids)
    )
  order by orders.member_season_id for update;
  perform 1 from app.member_article_sizes size_profile
  where size_profile.season_id = p_expected_season_id
    and (
      p_scope = 'all_active'
      or size_profile.member_season_id = any(normalized_ids)
    )
  order by size_profile.member_season_id, size_profile.article_id for update;

  preview := private.member_package_bulk_preview(
    p_action, p_scope, normalized_ids, p_package_revision_id
  );
  if preview->>'seasonId' is distinct from p_expected_season_id::text
    or preview->>'revision' is distinct from p_expected_revision
  then
    raise exception 'MEMBER_PACKAGE_BULK_STALE' using errcode = '40001';
  end if;

  for target in
    select entry.value
    from jsonb_array_elements(preview->'targets') entry(value)
    where entry.value->>'disposition' = 'eligible'
    order by entry.value->>'memberSeasonId'
  loop
    target_member_season_id := (target->>'memberSeasonId')::uuid;
    if p_action = 'assign' then
      perform private.apply_member_package_selection(
        target_member_season_id,
        p_package_revision_id,
        private.package_workspace_revision(target_member_season_id),
        actor,
        null,
        normalized_reason,
        p_correlation_id
      );
      select * into target_order
      from app.member_orders orders
      where orders.member_season_id = target_member_season_id
      for update;

      perform set_config('app.package_size_internal', 'on', true);
      for component in
        select package_item, confirmed_size
        from app.order_package_snapshot_items package_item
        join app.member_article_sizes confirmed_size
          on confirmed_size.member_season_id = target_member_season_id
          and confirmed_size.article_id = package_item.article_id
          and confirmed_size.selection_status in ('confirmed', 'locked')
        join app.article_variants variant
          on variant.id = confirmed_size.article_variant_id
          and variant.article_id = package_item.article_id
          and variant.active
        join app.article_seasons article_season
          on article_season.article_id = package_item.article_id
          and article_season.season_id = p_expected_season_id
        where package_item.snapshot_id = target_order.active_package_snapshot_id
        order by package_item.sort_order, package_item.id
      loop
        snapshot_item := component.package_item;
        confirmed_size_row := component.confirmed_size;
        active_line := null;
        select * into active_line
        from app.order_lines line
        where line.order_id = target_order.id
          and line.article_id = snapshot_item.article_id
          and line.status <> 'cancelled'
        order by line.created_at desc, line.id desc
        limit 1
        for update;
        if active_line.id is null then
          insert into app.order_lines(
            order_id, article_variant_id, quantity, package_template_item_id
          ) values (
            target_order.id,
            confirmed_size_row.article_variant_id,
            snapshot_item.quantity,
            snapshot_item.template_item_id
          );
        elsif active_line.article_variant_id is distinct from confirmed_size_row.article_variant_id
          or active_line.quantity is distinct from snapshot_item.quantity
          or active_line.package_template_item_id is distinct from snapshot_item.template_item_id
        then
          update app.order_lines
          set article_variant_id = confirmed_size_row.article_variant_id,
              quantity = snapshot_item.quantity,
              package_template_item_id = snapshot_item.template_item_id,
              updated_at = timezone('utc', now())
          where id = active_line.id;
        end if;
        linked_count := linked_count + 1;
      end loop;
      perform set_config('app.package_size_internal', 'off', true);
      perform app.refresh_order_status(target_order.id);
    else
      select * into target_order
      from app.member_orders orders
      where orders.member_season_id = target_member_season_id
      for update;
      update app.order_lines
      set status = 'cancelled', updated_at = timezone('utc', now())
      where order_id = target_order.id and status = 'backorder';
      perform set_config('app.package_assignment_internal', 'on', true);
      update app.member_orders
      set package_assignment_state = 'withdrawn',
          package_withdrawn_at = timezone('utc', now()),
          package_withdrawn_by = actor,
          package_withdrawal_reason = normalized_reason,
          order_status = 'Nog niet betaald',
          updated_at = timezone('utc', now())
      where id = target_order.id;
      perform set_config('app.package_assignment_internal', 'off', true);
      insert into app.audit_logs(
        actor_user_id, action, entity_type, entity_id, metadata, correlation_id
      ) values (
        actor,
        'package_order.removed',
        'member_order',
        target_order.id,
        jsonb_build_object(
          'memberSeasonId', target_member_season_id,
          'previousPackageRevisionId', target_order.package_revision_id,
          'previousPackageSnapshotId', target_order.active_package_snapshot_id,
          'reason', normalized_reason
        ),
        p_correlation_id
      );
    end if;
    changed_count := changed_count + 1;
  end loop;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values (
    actor,
    case when p_action = 'assign'
      then 'package_order.bulk_assigned'
      else 'package_order.bulk_removed'
    end,
    'season',
    p_expected_season_id,
    jsonb_build_object(
      'scope', p_scope,
      'requestedCount', (preview->>'requestedCount')::integer,
      'matchedCount', (preview->>'matchedCount')::integer,
      'changedCount', changed_count,
      'blockedCount', (preview->>'blockedCount')::integer,
      'unchangedCount', (preview->>'unchangedCount')::integer,
      'linkedSizeCount', linked_count,
      'missingSizeCount', (preview->>'missingSizeCount')::integer,
      'packageRevisionId', p_package_revision_id,
      'reason', normalized_reason
    ),
    p_correlation_id
  );

  result := (preview - 'targets' - 'revision') || jsonb_build_object(
    'committed', true,
    'changedCount', changed_count,
    'linkedSizeCount', linked_count,
    'reused', false
  );
  insert into private.member_package_bulk_requests(
    request_id, staff_user_id, season_id, package_revision_id,
    request_hash, result_snapshot, correlation_id
  ) values (
    p_request_id, actor, p_expected_season_id, p_package_revision_id,
    computed_hash, result, p_correlation_id
  );
  return result;
end;
$$;

revoke all on function private.protect_member_package_bulk_request()
from public, anon, authenticated, service_role;
revoke all on function app.get_member_package_bulk_options()
from public, anon, service_role;
revoke all on function app.preview_member_package_bulk_v1(
  text, text, uuid[], uuid
) from public, anon, service_role;
revoke all on function app.apply_member_package_bulk_v1(
  text, text, uuid[], uuid, uuid, text, text, uuid, uuid
) from public, anon, service_role;
grant execute on function app.get_member_package_bulk_options()
to authenticated;
grant execute on function app.preview_member_package_bulk_v1(
  text, text, uuid[], uuid
) to authenticated;
grant execute on function app.apply_member_package_bulk_v1(
  text, text, uuid[], uuid, uuid, text, text, uuid, uuid
) to authenticated;

create or replace function app.get_member_list_v2(
  p_search text default null,
  p_team text default null,
  p_payment_filter text default null,
  p_order_status text default null,
  p_article_id uuid default null,
  p_size text default null,
  p_line_status app.order_line_status default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with workspace as (
    select app.get_member_list(
      p_search, p_team, p_payment_filter, p_order_status,
      p_article_id, p_size, p_line_status, p_limit, p_offset
    ) result
  )
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        case when exists(
          select 1 from app.member_orders orders
          where orders.member_season_id = (member.value->>'memberSeasonId')::uuid
            and orders.package_assignment_state = 'withdrawn'
        ) then jsonb_set(member.value, '{order}', 'null'::jsonb, true)
        else member.value end
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from workspace;
$$;

create or replace function app.get_member_detail_v4(p_member_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with detail as (select app.get_member_detail_v3(p_member_id) result)
  select case when exists(
    select 1 from app.member_orders orders
    where orders.id = nullif(detail.result #>> '{order,id}', '')::uuid
      and orders.package_assignment_state = 'withdrawn'
  ) then jsonb_set(detail.result, '{order}', 'null'::jsonb, true)
  else detail.result end
  from detail;
$$;

create or replace function app.get_catalog_order_workspace_v5()
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with workspace as (select app.get_catalog_order_workspace_v4() result)
  select jsonb_set(
    workspace.result,
    '{packageOrders}',
    coalesce((
      select jsonb_agg(
        case when exists(
          select 1 from app.member_orders orders
          where orders.member_season_id =
              (package_order.value->>'memberSeasonId')::uuid
            and orders.package_assignment_state = 'withdrawn'
        ) then package_order.value || jsonb_build_object(
          'orderId', null,
          'packageRevisionId', null,
          'packageName', null,
          'canSwitchPackage', true
        ) else package_order.value end
        order by package_order.ordinality
      )
      from jsonb_array_elements(workspace.result->'packageOrders')
        with ordinality package_order(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from workspace;
$$;

create or replace function public.get_parent_package_workspace_v6(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, public, pg_temp
as $$
  with workspace as (
    select public.get_parent_package_workspace_v5(p_token_hash) result
  )
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        case when exists(
          select 1 from app.member_orders orders
          where orders.member_season_id =
              (member.value->>'memberSeasonId')::uuid
            and orders.package_assignment_state = 'withdrawn'
        ) then jsonb_set(member.value, '{order}', 'null'::jsonb, true)
        else member.value end
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from workspace;
$$;

revoke all on function app.get_member_list_v2(
  text, text, text, text, uuid, text, app.order_line_status, integer, integer
) from public, anon;
revoke all on function app.get_member_detail_v4(uuid) from public, anon;
revoke all on function app.get_catalog_order_workspace_v5()
from public, anon;
revoke all on function public.get_parent_package_workspace_v6(text)
from public, anon, authenticated;
grant execute on function app.get_member_list_v2(
  text, text, text, text, uuid, text, app.order_line_status, integer, integer
) to authenticated;
grant execute on function app.get_member_detail_v4(uuid) to authenticated;
grant execute on function app.get_catalog_order_workspace_v5()
to authenticated;
grant execute on function public.get_parent_package_workspace_v6(text)
to service_role;

revoke all on function private.guard_package_assignment_state()
from public, anon, authenticated, service_role;
revoke all on function private.require_active_package_assignment()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

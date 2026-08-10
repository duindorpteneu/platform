-- Package selection and package-wide size confirmation.
--
-- The commercial package snapshot is created before its logistical order
-- lines. A size confirmation creates or updates only unreserved lines. Once a
-- line is reserved, a different selection becomes an explicit action item.

create or replace function private.package_orders_v2_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select flag.enabled
    from app.release_feature_flags flag
    where flag.key = 'package_orders_v2'
  ), false);
$$;

revoke all on function private.package_orders_v2_enabled()
from public, anon, authenticated, service_role;

alter table app.member_article_sizes
  add column requested_article_variant_id uuid,
  add column requested_raw_value text,
  add column requested_member_note text,
  add column requested_at timestamptz,
  add column confirmed_by_parent_account_id uuid,
  add column requested_by_parent_account_id uuid,
  add constraint member_article_sizes_requested_variant_fkey
    foreign key (requested_article_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict
    not valid,
  add constraint member_article_sizes_confirmed_parent_fkey
    foreign key (confirmed_by_parent_account_id)
    references private.parent_accounts(id)
    on delete restrict
    not valid,
  add constraint member_article_sizes_requested_parent_fkey
    foreign key (requested_by_parent_account_id)
    references private.parent_accounts(id)
    on delete restrict
    not valid;

alter table app.member_article_sizes
  drop constraint member_article_sizes_selection_check;

alter table app.member_article_sizes
  add constraint member_article_sizes_selection_check check (
    (
      selection_status in ('imported_unconfirmed', 'confirmed', 'locked')
      and article_variant_id is not null
      and raw_value is null
      and requested_article_variant_id is null
      and requested_raw_value is null
      and requested_member_note is null
      and requested_at is null
      and requested_by_parent_account_id is null
    )
    or (
      selection_status = 'conflict'
      and article_variant_id is null
      and raw_value is not null
      and length(btrim(raw_value)) between 1 and 160
      and (
        selection_source <> 'parent'
        or (
          confirmed_at is not null
          and confirmed_by_parent_account_id is not null
          and length(btrim(coalesce(member_note, ''))) between 1 and 500
        )
      )
      and requested_article_variant_id is null
      and requested_raw_value is null
      and requested_member_note is null
      and requested_at is null
      and requested_by_parent_account_id is null
    )
    or (
      selection_status = 'change_requested'
      and article_variant_id is not null
      and raw_value is null
      and requested_at is not null
      and requested_by_parent_account_id is not null
      and (
        (
          requested_article_variant_id is not null
          and requested_raw_value is null
          and requested_member_note is null
        )
        or (
          requested_article_variant_id is null
          and requested_raw_value is not null
          and length(btrim(requested_raw_value)) between 1 and 160
          and length(btrim(coalesce(requested_member_note, ''))) between 1 and 500
        )
      )
    )
  ) not valid;

alter table app.member_article_sizes
  validate constraint member_article_sizes_requested_variant_fkey;
alter table app.member_article_sizes
  validate constraint member_article_sizes_confirmed_parent_fkey;
alter table app.member_article_sizes
  validate constraint member_article_sizes_requested_parent_fkey;
alter table app.member_article_sizes
  validate constraint member_article_sizes_selection_check;

alter table app.action_items
  add column resolved_automatically boolean not null default false;

alter table app.action_items
  drop constraint action_items_resolution_check;

alter table app.action_items
  add constraint action_items_resolution_check check (
    (
      status in ('open', 'in_progress')
      and resolved_at is null
      and resolved_by is null
      and not resolved_automatically
      and resolution_reason is null
    )
    or (
      status in ('resolved', 'dismissed')
      and resolved_at is not null
      and (resolved_by is not null or resolved_automatically)
      and not (resolved_by is not null and resolved_automatically)
      and length(btrim(resolution_reason)) between 3 and 500
    )
  );

create table app.package_size_confirmations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  revision integer not null check (revision > 0),
  source text not null check (source in ('parent', 'staff')),
  parent_account_id uuid references private.parent_accounts(id) on delete restrict,
  staff_user_id uuid,
  selected_count integer not null check (selected_count >= 0),
  conflict_count integer not null check (conflict_count >= 0),
  change_request_count integer not null check (change_request_count >= 0),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  unique (order_id, revision),
  constraint package_size_confirmations_actor_check check (
    (source = 'parent' and parent_account_id is not null and staff_user_id is null)
    or (source = 'staff' and staff_user_id is not null and parent_account_id is null)
  ),
  constraint package_size_confirmations_counts_check check (
    conflict_count + change_request_count <= selected_count
  )
);

create index package_size_confirmations_member_season_idx
  on app.package_size_confirmations(member_season_id, created_at desc);

alter table app.package_size_confirmations enable row level security;
create policy "clothing staff can read package size confirmations"
on app.package_size_confirmations
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);
revoke all on table app.package_size_confirmations
from public, anon, authenticated, service_role;
grant select on table app.package_size_confirmations to authenticated;

create or replace function private.auto_resolve_action_item(
  p_type text,
  p_season_id uuid,
  p_dedupe_key text,
  p_reason text
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_id uuid;
begin
  if p_type is null
    or p_season_id is null
    or p_dedupe_key !~ '^[0-9a-f]{64}$'
    or length(btrim(coalesce(p_reason, ''))) not between 3 and 500
  then
    raise exception 'ACTION_ITEM_AUTO_RESOLVE_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'action-item:' || p_type || ':' || p_season_id::text || ':' || p_dedupe_key,
      0
    )
  );
  update app.action_items item
  set status = 'resolved',
      resolved_at = timezone('utc', now()),
      resolved_by = null,
      resolved_automatically = true,
      resolution_reason = btrim(p_reason)
  where item.type = p_type
    and item.season_id = p_season_id
    and item.dedupe_key = p_dedupe_key
    and item.status in ('open', 'in_progress')
  returning item.id into target_id;
  if target_id is null then
    return false;
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    null,
    'action_item.auto_resolved',
    'action_item',
    target_id,
    jsonb_build_object('reasonCode', 'condition_restored')
  );
  return true;
end;
$$;

revoke all on function private.auto_resolve_action_item(text, uuid, text, text)
from public, anon, authenticated, service_role;

create or replace function private.order_effective_payment_status(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select payment.status::text
    from app.payments payment
    where payment.order_id = p_order_id
    order by case payment.status
      when 'paid' then 1
      when 'duplicate_paid' then 2
      when 'refunded' then 3
      when 'pending' then 4
      when 'open' then 5
      else 6
    end, payment.created_at desc, payment.id
    limit 1
  ), 'open');
$$;

create or replace function private.package_order_can_switch(
  p_order_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select not exists(
    select 1
    from app.payments payment
    where payment.order_id = p_order_id
      and payment.status in ('open', 'pending', 'paid', 'refunded', 'duplicate_paid')
  )
  and not exists(
    select 1
    from app.order_lines line
    where line.order_id = p_order_id
      and line.status in ('ready_for_pickup', 'picked_up')
  )
  and not exists(
    select 1
    from app.inventory_reservations reservation
    join app.order_lines line on line.id = reservation.order_line_id
    where line.order_id = p_order_id
      and reservation.status in ('reserved', 'fulfilled')
  )
  and not exists(
    select 1
    from app.fulfilments fulfilment
    join app.fulfilment_lines fulfilment_line
      on fulfilment_line.fulfilment_id = fulfilment.id
      and fulfilment_line.reversed_at is null
    where fulfilment.order_id = p_order_id
  );
$$;

revoke all on function private.order_effective_payment_status(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.package_order_can_switch(uuid)
from public, anon, authenticated, service_role;

create or replace function private.parent_account_for_member_season(
  p_token_hash text,
  p_member_season_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select session.parent_account_id
  from private.parent_sessions session
  join lateral private.parent_authorized_member_seasons(
    session.parent_account_id
  ) authorized on authorized.member_season_id = p_member_season_id
  where p_token_hash ~ '^[0-9a-f]{64}$'
    and session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
  limit 1;
$$;

revoke all on function private.parent_account_for_member_season(text, uuid)
from public, anon, authenticated, service_role;

create or replace function private.package_workspace_revision(
  p_member_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws(
    '|',
    'parent-package-workspace-v1',
    p_member_season_id::text,
    coalesce((
      select concat_ws(':',
        member_season.season_id,
        member_season.participation_status,
        member_season.reconciliation_status,
        member_season.updated_at
      )
      from app.member_seasons member_season
      where member_season.id = p_member_season_id
    ), ''),
    coalesce((
      select concat_ws(':',
        orders.id,
        orders.package_revision_id,
        orders.active_package_snapshot_id,
        orders.amount_due_cents,
        orders.updated_at
      )
      from app.member_orders orders
      where orders.member_season_id = p_member_season_id
    ), ''),
    coalesce((
      select string_agg(concat_ws(':',
        revision.id,
        revision.revision_number,
        revision.active,
        revision.is_default
      ), ',' order by revision.id)
      from app.member_seasons member_season
      join app.package_template_revisions revision
        on revision.season_id = member_season.season_id
        and revision.status = 'published'
        and revision.active
      where member_season.id = p_member_season_id
    ), ''),
    coalesce((
      select string_agg(concat_ws(':',
        size_profile.article_id,
        size_profile.article_variant_id,
        size_profile.selection_status,
        size_profile.selection_source,
        size_profile.raw_value,
        size_profile.member_note,
        size_profile.confirmed_at,
        size_profile.requested_article_variant_id,
        size_profile.requested_raw_value,
        size_profile.requested_member_note,
        size_profile.requested_at,
        size_profile.updated_at
      ), ',' order by size_profile.article_id)
      from app.member_article_sizes size_profile
      where size_profile.member_season_id = p_member_season_id
    ), ''),
    coalesce((
      select string_agg(concat_ws(':',
        line.id,
        line.article_id,
        line.article_variant_id,
        line.quantity,
        line.status,
        line.updated_at,
        coalesce(reservation.status::text, '')
      ), ',' order by line.article_id, line.id)
      from app.member_orders orders
      join app.order_lines line
        on line.order_id = orders.id
        and line.status <> 'cancelled'
      left join app.inventory_reservations reservation
        on reservation.order_line_id = line.id
        and reservation.status in ('reserved', 'fulfilled')
      where orders.member_season_id = p_member_season_id
    ), ''),
    coalesce((
      select string_agg(concat_ws(':',
        payment.id,
        payment.status,
        payment.amount_cents,
        payment.updated_at
      ), ',' order by payment.id)
      from app.member_orders orders
      join app.payments payment on payment.order_id = orders.id
      where orders.member_season_id = p_member_season_id
    ), '')
  ), 'sha256'), 'hex');
$$;

revoke all on function private.package_workspace_revision(uuid)
from public, anon, authenticated, service_role;

create or replace function private.package_sizes_complete(
  p_order_id uuid,
  p_snapshot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select not exists(
    select 1
    from app.order_package_snapshot_items snapshot_item
    left join app.member_orders orders on orders.id = p_order_id
    left join app.member_article_sizes size_profile
      on size_profile.member_season_id = orders.member_season_id
      and size_profile.article_id = snapshot_item.article_id
    where snapshot_item.snapshot_id = p_snapshot_id
      and not (
        size_profile.selection_status in ('confirmed', 'locked', 'change_requested')
        or (
          size_profile.selection_status = 'conflict'
          and size_profile.selection_source = 'parent'
          and size_profile.confirmed_at is not null
          and length(btrim(coalesce(size_profile.member_note, ''))) between 1 and 500
        )
      )
  );
$$;

revoke all on function private.package_sizes_complete(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function public.get_parent_package_workspace(
  p_token_hash text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  account_id uuid;
  enabled boolean := private.package_orders_v2_enabled();
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501';
  end if;
  select session.parent_account_id into account_id
  from private.parent_sessions session
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and private.parent_account_has_portal_access(session.parent_account_id)
  limit 1;
  if account_id is null then
    raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'enabled', enabled,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', member.id,
        'memberSeasonId', member_season.id,
        'relationNumber', member.relation_number,
        'firstName', member.first_name,
        'insertion', member.insertion,
        'lastName', member.last_name,
        'team', member_season.team_name,
        'dateOfBirth', identity.date_of_birth,
        'gender', member.gender::text,
        'seasonId', member_season.season_id,
        'seasonName', season.name,
        'availablePackages', case when enabled then coalesce((
          select jsonb_agg(jsonb_build_object(
            'revisionId', revision.id,
            'name', revision.name,
            'description', revision.description,
            'priceCents', revision.price_cents,
            'currency', revision.currency,
            'revisionNumber', revision.revision_number,
            'isDefault', revision.is_default
          ) order by revision.is_default desc, lower(revision.name), revision.revision_number desc)
          from app.package_template_revisions revision
          where revision.season_id = member_season.season_id
            and revision.status = 'published'
            and revision.active
        ), '[]'::jsonb) else '[]'::jsonb end,
        'order', case when orders.id is null then null else jsonb_build_object(
          'id', orders.id,
          'amountDueCents', orders.amount_due_cents,
          'paymentStatus', private.order_effective_payment_status(orders.id),
          'orderStatus', orders.order_status,
          'qrVersion', (
            select token.version
            from private.qr_tokens token
            where token.order_id = orders.id and token.active
            order by token.version desc
            limit 1
          ),
          'packageRevisionId', orders.package_revision_id,
          'packageName', snapshot.package_name,
          'packageDescription', snapshot.package_description,
          'packagePriceCents', snapshot.package_price_cents,
          'currency', snapshot.currency,
          'revisionLabel', snapshot.revision_label,
          'legacy', orders.package_revision_id is null,
          'canSwitchPackage', enabled and private.package_order_can_switch(orders.id),
          'sizesConfirmed', private.package_sizes_complete(
            orders.id,
            orders.active_package_snapshot_id
          ),
          'revision', private.package_workspace_revision(member_season.id),
          'articleLines', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', line.id,
              'article', line.product_name_snapshot,
              'size', line.size_snapshot,
              'quantity', line.quantity,
              'status', line.status::text
            ) order by line.product_name_snapshot, line.size_snapshot, line.id)
            from app.order_lines line
            where line.order_id = orders.id
              and line.status <> 'cancelled'
          ), '[]'::jsonb),
          'items', coalesce((
            select jsonb_agg(jsonb_build_object(
              'snapshotItemId', snapshot_item.id,
              'articleId', snapshot_item.article_id,
              'name', snapshot_item.product_name_snapshot,
              'code', snapshot_item.product_code_snapshot,
              'quantity', snapshot_item.quantity,
              'selectedVariantId', size_profile.article_variant_id,
              'selectionStatus', size_profile.selection_status::text,
              'selectionSource', size_profile.selection_source::text,
              'rawValue', case
                when size_profile.selection_status = 'conflict'
                  then size_profile.raw_value
                else null
              end,
              'memberNote', case
                when size_profile.selection_source = 'parent'
                  then size_profile.member_note
                else null
              end,
              'confirmedAt', size_profile.confirmed_at,
              'requestedVariantId', size_profile.requested_article_variant_id,
              'requestedRawValue', size_profile.requested_raw_value,
              'requestedMemberNote', size_profile.requested_member_note,
              'lineStatus', order_line.status::text,
              'hasReservation', exists(
                select 1
                from app.inventory_reservations reservation
                where reservation.order_line_id = order_line.id
                  and reservation.status in ('reserved', 'fulfilled')
              ),
              'issued', order_line.status = 'picked_up'
                or exists(
                  select 1
                  from app.fulfilment_lines fulfilment_line
                  where fulfilment_line.order_line_id = order_line.id
                    and fulfilment_line.reversed_at is null
                ),
              'variants', coalesce((
                select jsonb_agg(jsonb_build_object(
                  'id', variant.id,
                  'label', variant.size,
                  'active', variant.active
                ) order by variant.sort_order, lower(variant.size), variant.id)
                from app.article_variants variant
                where variant.article_id = snapshot_item.article_id
                  and (
                    variant.active
                    or variant.id = size_profile.article_variant_id
                    or variant.id = size_profile.requested_article_variant_id
                  )
              ), '[]'::jsonb)
            ) order by snapshot_item.sort_order, lower(snapshot_item.product_name_snapshot), snapshot_item.id)
            from app.order_package_snapshot_items snapshot_item
            left join app.member_article_sizes size_profile
              on size_profile.member_season_id = member_season.id
              and size_profile.article_id = snapshot_item.article_id
            left join lateral (
              select line.*
              from app.order_lines line
              where line.order_id = orders.id
                and line.article_id = snapshot_item.article_id
                and line.status <> 'cancelled'
              order by line.created_at desc, line.id desc
              limit 1
            ) order_line on true
            where snapshot_item.snapshot_id = orders.active_package_snapshot_id
          ), '[]'::jsonb)
        ) end
      ) order by season.starts_on desc nulls last, lower(member.last_name), lower(member.first_name))
      from private.parent_authorized_member_seasons(account_id) authorized
      join app.member_seasons member_season
        on member_season.id = authorized.member_season_id
      join app.members member on member.id = member_season.member_id
      join app.seasons season on season.id = member_season.season_id
      left join private.member_sensitive_identity identity
        on identity.member_id = member.id
      left join app.member_orders orders
        on orders.member_season_id = member_season.id
      left join app.order_package_snapshots snapshot
        on snapshot.id = orders.active_package_snapshot_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function private.apply_member_package_selection(
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_staff_user_id uuid,
  p_parent_account_id uuid,
  p_reason text,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  member_season app.member_seasons%rowtype;
  revision app.package_template_revisions%rowtype;
  target_order app.member_orders%rowtype;
  changed boolean := false;
  previous_revision_id uuid;
begin
  if not private.package_orders_v2_enabled() then
    raise exception 'PACKAGE_ORDER_FEATURE_DISABLED' using errcode = '42501';
  end if;
  if p_member_season_id is null
    or p_package_revision_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or ((p_staff_user_id is null) = (p_parent_account_id is null))
    or length(btrim(coalesce(p_reason, ''))) not between 3 and 500
  then
    raise exception 'PACKAGE_SELECTION_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || p_member_season_id::text,
      0
    )
  );
  select * into member_season
  from app.member_seasons
  where id = p_member_season_id
  for update;
  if not found then
    raise exception 'MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  if member_season.participation_status <> 'active'
    or member_season.reconciliation_status <> 'resolved'
    or not exists(
      select 1
      from app.seasons season
      where season.id = member_season.season_id
        and season.status = 'open'
    )
  then
    raise exception 'MEMBER_SEASON_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  if private.package_workspace_revision(p_member_season_id)
    <> p_expected_revision
  then
    raise exception 'PACKAGE_SELECTION_CONFLICT' using errcode = '40001';
  end if;

  select * into revision
  from app.package_template_revisions package_revision
  where package_revision.id = p_package_revision_id
    and package_revision.season_id = member_season.season_id
    and package_revision.status = 'published'
    and package_revision.active
  for share;
  if not found then
    raise exception 'PACKAGE_REVISION_NOT_AVAILABLE' using errcode = '23514';
  end if;

  select * into target_order
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
  for update;
  if found then
    previous_revision_id := target_order.package_revision_id;
    if target_order.package_revision_id = revision.id
      and target_order.amount_due_cents = revision.price_cents
    then
      return jsonb_build_object(
        'memberSeasonId', p_member_season_id,
        'orderId', target_order.id,
        'packageRevisionId', revision.id,
        'changed', false,
        'revision', private.package_workspace_revision(p_member_season_id)
      );
    end if;
    if not private.package_order_can_switch(target_order.id) then
      raise exception 'PACKAGE_SWITCH_REQUIRES_ADMIN_WORKFLOW' using errcode = '23514';
    end if;

    update app.member_orders
    set package_revision_id = revision.id,
        amount_due_cents = revision.price_cents
    where id = target_order.id
    returning * into target_order;

    update app.order_lines line
    set status = 'cancelled',
        updated_at = timezone('utc', now())
    where line.order_id = target_order.id
      and line.status = 'backorder';
    changed := true;
  else
    insert into app.member_orders(
      member_id,
      season_id,
      member_season_id,
      amount_due_cents,
      package_revision_id
    )
    values(
      member_season.member_id,
      member_season.season_id,
      member_season.id,
      revision.price_cents,
      revision.id
    )
    returning * into target_order;
    changed := true;
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  values(
    p_staff_user_id,
    case
      when previous_revision_id is null then 'package_order.selected'
      else 'package_order.switched'
    end,
    'member_order',
    target_order.id,
    jsonb_build_object(
      'memberSeasonId', p_member_season_id,
      'previousPackageRevisionId', previous_revision_id,
      'packageRevisionId', revision.id,
      'packagePriceCents', revision.price_cents,
      'source', case when p_parent_account_id is null then 'staff' else 'parent' end
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'memberSeasonId', p_member_season_id,
    'orderId', target_order.id,
    'packageRevisionId', revision.id,
    'changed', changed,
    'revision', private.package_workspace_revision(p_member_season_id)
  );
end;
$$;

revoke all on function private.apply_member_package_selection(
  uuid, uuid, text, uuid, uuid, text, uuid
) from public, anon, authenticated, service_role;

create or replace function public.select_parent_package(
  p_token_hash text,
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  account_id uuid;
begin
  account_id := private.parent_account_for_member_season(
    p_token_hash,
    p_member_season_id
  );
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;
  return private.apply_member_package_selection(
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    null,
    account_id,
    'Pakketkeuze door ouder',
    p_correlation_id
  );
end;
$$;

create or replace function app.select_member_package(
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
begin
  return private.apply_member_package_selection(
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    actor,
    null,
    p_reason,
    p_correlation_id
  );
end;
$$;

create or replace function app.guard_paid_order_line_identity()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare
  target_order_id uuid;
  line_id uuid;
  identity_changed boolean;
  package_revision uuid;
begin
  target_order_id := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
  line_id := case when tg_op = 'INSERT' then null else old.id end;
  identity_changed := tg_op in ('INSERT', 'DELETE')
    or (
      tg_op = 'UPDATE'
      and (
        new.order_id is distinct from old.order_id
        or new.article_variant_id is distinct from old.article_variant_id
        or new.article_id is distinct from old.article_id
        or new.quantity is distinct from old.quantity
        or new.size_snapshot is distinct from old.size_snapshot
      )
    );

  if identity_changed and exists(
    select 1
    from app.payments payment
    where payment.order_id = target_order_id
      and payment.status = 'paid'
  ) then
    select orders.package_revision_id into package_revision
    from app.member_orders orders
    where orders.id = target_order_id;
    if current_setting('app.package_size_internal', true) is distinct from 'on'
      or package_revision is null
      or (
        line_id is not null
        and (
          exists(
            select 1
            from app.inventory_reservations reservation
            where reservation.order_line_id = line_id
              and reservation.status in ('reserved', 'fulfilled')
          )
          or exists(
            select 1
            from app.fulfilment_lines fulfilment_line
            where fulfilment_line.order_line_id = line_id
              and fulfilment_line.reversed_at is null
          )
        )
      )
    then
      raise exception 'PAID_ORDER_IMMUTABLE' using errcode = '23514';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

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
  select variant.article_id, variant.size
  into resolved_article_id, resolved_size
  from app.article_variants variant
  where variant.id = new.article_variant_id;
  if resolved_article_id is null then
    raise exception 'ARTICLE_VARIANT_NOT_FOUND' using errcode = '23503';
  end if;
  if new.article_id is not null and new.article_id <> resolved_article_id then
    raise exception 'ORDER_LINE_ARTICLE_VARIANT_MISMATCH' using errcode = '23514';
  end if;

  if new.package_template_item_id is not null then
    select snapshot_item.product_name_snapshot,
      snapshot_item.product_code_snapshot
    into resolved_name, resolved_code
    from app.member_orders orders
    join app.order_package_snapshot_items snapshot_item
      on snapshot_item.snapshot_id = orders.active_package_snapshot_id
      and snapshot_item.template_item_id = new.package_template_item_id
      and snapshot_item.article_id = resolved_article_id
    where orders.id = new.order_id;
    if resolved_name is null then
      raise exception 'PACKAGE_ORDER_ITEM_NOT_FOUND' using errcode = '23503';
    end if;
  else
    select article.name, article.code
    into resolved_name, resolved_code
    from app.articles article
    where article.id = resolved_article_id;
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
    new.product_name_snapshot := coalesce(
      new.product_name_snapshot,
      old.product_name_snapshot
    );
    new.product_code_snapshot := coalesce(
      new.product_code_snapshot,
      old.product_code_snapshot
    );
  end if;
  return new;
end;
$$;

create or replace function public.confirm_parent_package_sizes(
  p_token_hash text,
  p_member_season_id uuid,
  p_selections jsonb,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  account_id uuid;
  member_season app.member_seasons%rowtype;
  target_order app.member_orders%rowtype;
  snapshot_item app.order_package_snapshot_items%rowtype;
  size_profile app.member_article_sizes%rowtype;
  order_line app.order_lines%rowtype;
  item jsonb;
  selected_article_id uuid;
  selected_variant_id uuid;
  selected_kind text;
  selected_note text;
  selected_count integer := 0;
  conflict_count integer := 0;
  change_request_count integer := 0;
  confirmation_revision integer;
  confirmation_id uuid;
  has_reservation boolean;
  has_issuance boolean;
  differs boolean;
  conflict_key text;
  change_key text;
begin
  if not private.package_orders_v2_enabled() then
    raise exception 'PACKAGE_ORDER_FEATURE_DISABLED' using errcode = '42501';
  end if;
  if p_member_season_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_selections is null
    or jsonb_typeof(p_selections) <> 'array'
    or jsonb_array_length(p_selections) not between 1 and 25
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
  end if;

  account_id := private.parent_account_for_member_season(
    p_token_hash,
    p_member_season_id
  );
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || p_member_season_id::text,
      0
    )
  );
  select * into member_season
  from app.member_seasons
  where id = p_member_season_id
  for update;
  if not found
    or member_season.participation_status <> 'active'
    or member_season.reconciliation_status <> 'resolved'
    or not exists(
      select 1
      from app.seasons season
      where season.id = member_season.season_id
        and season.status = 'open'
    )
  then
    raise exception 'MEMBER_SEASON_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  select * into target_order
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
  for update;
  if not found or target_order.package_revision_id is null then
    raise exception 'PACKAGE_ORDER_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || member_season.member_id::text,
      0
    )
  );
  perform 1
  from app.member_article_sizes current_size
  where current_size.member_season_id = p_member_season_id
  order by current_size.article_id
  for update;
  perform 1
  from app.order_lines current_line
  where current_line.order_id = target_order.id
  order by current_line.article_id, current_line.id
  for update;

  if private.package_workspace_revision(p_member_season_id)
    <> p_expected_revision
  then
    raise exception 'PACKAGE_SIZE_SELECTION_CONFLICT' using errcode = '40001';
  end if;
  if (
    select count(distinct selection->>'articleId')
    from jsonb_array_elements(p_selections) selection
  ) <> jsonb_array_length(p_selections)
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
  end if;
  if (
    select count(*)
    from app.order_package_snapshot_items required_item
    where required_item.snapshot_id = target_order.active_package_snapshot_id
  ) <> jsonb_array_length(p_selections)
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INCOMPLETE' using errcode = '22023';
  end if;

  perform set_config('app.package_size_internal', 'on', true);
  for item in
    select selection.value
    from jsonb_array_elements(p_selections) selection(value)
    order by selection.value->>'articleId'
  loop
    if jsonb_typeof(item) <> 'object'
      or (select count(*) from jsonb_object_keys(item)) <> 4
      or not (
        item ? 'articleId'
        and item ? 'kind'
        and item ? 'variantId'
        and item ? 'note'
      )
      or (item->>'articleId') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      or item->>'kind' not in ('variant', 'other')
    then
      raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
    end if;

    selected_article_id := (item->>'articleId')::uuid;
    selected_kind := item->>'kind';
    selected_variant_id := case
      when item->'variantId' = 'null'::jsonb then null
      else nullif(item->>'variantId', '')::uuid
    end;
    selected_note := case
      when item->'note' = 'null'::jsonb then null
      else nullif(btrim(item->>'note'), '')
    end;
    if (
      selected_kind = 'variant'
      and (
        selected_variant_id is null
        or selected_note is not null
      )
    ) or (
      selected_kind = 'other'
      and (
        selected_variant_id is not null
        or length(coalesce(selected_note, '')) not between 1 and 500
      )
    ) then
      raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
    end if;

    select * into snapshot_item
    from app.order_package_snapshot_items required_item
    where required_item.snapshot_id = target_order.active_package_snapshot_id
      and required_item.article_id = selected_article_id;
    if not found then
      raise exception 'PACKAGE_SIZE_ARTICLE_INVALID' using errcode = '22023';
    end if;
    if selected_kind = 'variant' and not exists(
      select 1
      from app.article_variants variant
      join app.article_seasons link
        on link.article_id = variant.article_id
        and link.season_id = member_season.season_id
      where variant.id = selected_variant_id
        and variant.article_id = selected_article_id
        and variant.active
    ) then
      raise exception 'PACKAGE_SIZE_VARIANT_INVALID' using errcode = '22023';
    end if;

    select * into size_profile
    from app.member_article_sizes current_size
    where current_size.member_season_id = p_member_season_id
      and current_size.article_id = selected_article_id
    for update;
    select * into order_line
    from app.order_lines current_line
    where current_line.order_id = target_order.id
      and current_line.article_id = selected_article_id
      and current_line.status <> 'cancelled'
    order by current_line.created_at desc, current_line.id desc
    limit 1
    for update;

    has_reservation := order_line.id is not null and exists(
      select 1
      from app.inventory_reservations reservation
      where reservation.order_line_id = order_line.id
        and reservation.status in ('reserved', 'fulfilled')
    );
    has_issuance := order_line.id is not null and (
      order_line.status = 'picked_up'
      or exists(
        select 1
        from app.fulfilment_lines fulfilment_line
        where fulfilment_line.order_line_id = order_line.id
          and fulfilment_line.reversed_at is null
      )
    );
    differs := case
      when selected_kind = 'variant' then
        size_profile.article_variant_id is distinct from selected_variant_id
        or size_profile.selection_status = 'conflict'
        or (
          size_profile.selection_status = 'change_requested'
          and size_profile.requested_article_variant_id
            is distinct from selected_variant_id
        )
      else
        size_profile.selection_status is distinct from 'conflict'
        or size_profile.selection_source is distinct from 'parent'
        or size_profile.raw_value is distinct from 'Anders…'
        or size_profile.member_note is distinct from selected_note
    end;

    if has_issuance and differs then
      raise exception 'PACKAGE_SIZE_ISSUED_LOCKED' using errcode = '23514';
    end if;

    conflict_key := encode(extensions.digest(
      'size-other:' || p_member_season_id::text || ':' || selected_article_id::text,
      'sha256'
    ), 'hex');
    change_key := encode(extensions.digest(
      'size-change-reserved:' || p_member_season_id::text || ':' || selected_article_id::text,
      'sha256'
    ), 'hex');

    if has_reservation and differs then
      if order_line.article_variant_id is null then
        raise exception 'PACKAGE_RESERVED_SIZE_STATE_INVALID' using errcode = '23514';
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
        confirmed_by_parent_account_id,
        requested_article_variant_id,
        requested_raw_value,
        requested_member_note,
        requested_at,
        requested_by_parent_account_id,
        created_by,
        updated_by
      )
      values(
        member_season.member_id,
        member_season.season_id,
        member_season.id,
        selected_article_id,
        order_line.article_variant_id,
        'change_requested',
        'parent',
        coalesce(size_profile.confirmed_at, timezone('utc', now())),
        account_id,
        case when selected_kind = 'variant' then selected_variant_id else null end,
        case when selected_kind = 'other' then 'Anders…' else null end,
        case when selected_kind = 'other' then selected_note else null end,
        timezone('utc', now()),
        account_id,
        null,
        null
      )
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = excluded.article_variant_id,
          selection_status = 'change_requested',
          selection_source = 'parent',
          raw_value = null,
          member_note = null,
          requested_article_variant_id = excluded.requested_article_variant_id,
          requested_raw_value = excluded.requested_raw_value,
          requested_member_note = excluded.requested_member_note,
          requested_at = excluded.requested_at,
          requested_by_parent_account_id = excluded.requested_by_parent_account_id,
          updated_at = timezone('utc', now());
      perform private.open_action_item(
        'size_change_after_reservation',
        member_season.season_id,
        'package_order_item',
        snapshot_item.id,
        'parent_size_confirmation',
        target_order.id,
        change_key,
        'warning',
        'operations',
        'parent_requested_reserved_size_change',
        jsonb_build_object(
          'memberSeasonId', member_season.id,
          'orderItemId', snapshot_item.id,
          'articleId', selected_article_id,
          'variantId', coalesce(selected_variant_id, order_line.article_variant_id),
          'blocked', true
        ),
        null
      );
      change_request_count := change_request_count + 1;
    elsif selected_kind = 'variant' then
      insert into app.member_article_sizes(
        member_id,
        season_id,
        member_season_id,
        article_id,
        article_variant_id,
        selection_status,
        selection_source,
        raw_value,
        member_note,
        confirmed_at,
        confirmed_by,
        confirmed_by_parent_account_id,
        requested_article_variant_id,
        requested_raw_value,
        requested_member_note,
        requested_at,
        requested_by_parent_account_id,
        created_by,
        updated_by
      )
      values(
        member_season.member_id,
        member_season.season_id,
        member_season.id,
        selected_article_id,
        selected_variant_id,
        'confirmed',
        'parent',
        null,
        null,
        timezone('utc', now()),
        null,
        account_id,
        null,
        null,
        null,
        null,
        null,
        null,
        null
      )
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = excluded.article_variant_id,
          selection_status = 'confirmed',
          selection_source = 'parent',
          raw_value = null,
          member_note = null,
          confirmed_at = excluded.confirmed_at,
          confirmed_by = null,
          confirmed_by_parent_account_id = account_id,
          requested_article_variant_id = null,
          requested_raw_value = null,
          requested_member_note = null,
          requested_at = null,
          requested_by_parent_account_id = null,
          updated_at = timezone('utc', now());

      if order_line.id is null then
        insert into app.order_lines(
          order_id,
          article_variant_id,
          quantity,
          package_template_item_id
        )
        values(
          target_order.id,
          selected_variant_id,
          snapshot_item.quantity,
          snapshot_item.template_item_id
        );
      elsif order_line.article_variant_id is distinct from selected_variant_id
        or order_line.quantity is distinct from snapshot_item.quantity
      then
        update app.order_lines
        set article_variant_id = selected_variant_id,
            quantity = snapshot_item.quantity,
            package_template_item_id = snapshot_item.template_item_id,
            updated_at = timezone('utc', now())
        where id = order_line.id;
      end if;

      perform private.auto_resolve_action_item(
        'size_other',
        member_season.season_id,
        conflict_key,
        'Automatisch opgelost doordat een geldige maat is bevestigd'
      );
      perform private.auto_resolve_action_item(
        'size_change_after_reservation',
        member_season.season_id,
        change_key,
        'Automatisch opgelost doordat de bestaande maat is bevestigd'
      );
    else
      insert into app.member_article_sizes(
        member_id,
        season_id,
        member_season_id,
        article_id,
        article_variant_id,
        selection_status,
        selection_source,
        raw_value,
        member_note,
        confirmed_at,
        confirmed_by,
        confirmed_by_parent_account_id,
        requested_article_variant_id,
        requested_raw_value,
        requested_member_note,
        requested_at,
        requested_by_parent_account_id,
        created_by,
        updated_by
      )
      values(
        member_season.member_id,
        member_season.season_id,
        member_season.id,
        selected_article_id,
        null,
        'conflict',
        'parent',
        'Anders…',
        selected_note,
        timezone('utc', now()),
        null,
        account_id,
        null,
        null,
        null,
        null,
        null,
        null,
        null
      )
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = null,
          selection_status = 'conflict',
          selection_source = 'parent',
          raw_value = 'Anders…',
          member_note = excluded.member_note,
          confirmed_at = excluded.confirmed_at,
          confirmed_by = null,
          confirmed_by_parent_account_id = account_id,
          requested_article_variant_id = null,
          requested_raw_value = null,
          requested_member_note = null,
          requested_at = null,
          requested_by_parent_account_id = null,
          updated_at = timezone('utc', now());
      if order_line.id is not null and order_line.status = 'backorder' then
        update app.order_lines
        set status = 'cancelled',
            updated_at = timezone('utc', now())
        where id = order_line.id;
      end if;
      perform private.open_action_item(
        'size_other',
        member_season.season_id,
        'package_order_item',
        snapshot_item.id,
        'parent_size_confirmation',
        target_order.id,
        conflict_key,
        'warning',
        'operations',
        'parent_confirmed_other_size',
        jsonb_build_object(
          'memberSeasonId', member_season.id,
          'orderItemId', snapshot_item.id,
          'articleId', selected_article_id,
          'blocked', true
        ),
        null
      );
      conflict_count := conflict_count + 1;
    end if;
    selected_count := selected_count + 1;
  end loop;
  perform set_config('app.package_size_internal', 'off', true);

  select coalesce(max(confirmation.revision), 0) + 1
  into confirmation_revision
  from app.package_size_confirmations confirmation
  where confirmation.order_id = target_order.id;
  insert into app.package_size_confirmations(
    order_id,
    member_season_id,
    revision,
    source,
    parent_account_id,
    selected_count,
    conflict_count,
    change_request_count,
    correlation_id
  )
  values(
    target_order.id,
    member_season.id,
    confirmation_revision,
    'parent',
    account_id,
    selected_count,
    conflict_count,
    change_request_count,
    p_correlation_id
  )
  returning id into confirmation_id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  values(
    null,
    case
      when change_request_count > 0 then 'package_sizes.change_requested'
      else 'package_sizes.confirmed'
    end,
    'member_order',
    target_order.id,
    jsonb_build_object(
      'memberSeasonId', member_season.id,
      'confirmationId', confirmation_id,
      'selectedCount', selected_count,
      'conflictCount', conflict_count,
      'changeRequestCount', change_request_count,
      'source', 'parent'
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'memberSeasonId', member_season.id,
    'orderId', target_order.id,
    'confirmationId', confirmation_id,
    'selectedCount', selected_count,
    'conflictCount', conflict_count,
    'changeRequestCount', change_request_count,
    'sizesConfirmed', private.package_sizes_complete(
      target_order.id,
      target_order.active_package_snapshot_id
    ),
    'revision', private.package_workspace_revision(member_season.id)
  );
end;
$$;

create or replace function app.get_catalog_order_workspace_v3()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb;
  active_season uuid;
  enabled boolean := private.package_orders_v2_enabled();
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  workspace := app.get_catalog_order_workspace_v2();
  active_season := nullif(workspace->'activeSeason'->>'id', '')::uuid;
  return workspace || jsonb_build_object(
    'packageFeatureEnabled', enabled,
    'packageRevisions', case when enabled and active_season is not null then coalesce((
      select jsonb_agg(jsonb_build_object(
        'revisionId', revision.id,
        'name', revision.name,
        'priceCents', revision.price_cents,
        'currency', revision.currency,
        'revisionNumber', revision.revision_number,
        'isDefault', revision.is_default
      ) order by revision.is_default desc, lower(revision.name), revision.revision_number desc)
      from app.package_template_revisions revision
      where revision.season_id = active_season
        and revision.status = 'published'
        and revision.active
    ), '[]'::jsonb) else '[]'::jsonb end,
    'packageOrders', case when active_season is not null then coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', member_season.member_id,
        'memberSeasonId', member_season.id,
        'orderId', orders.id,
        'packageRevisionId', orders.package_revision_id,
        'packageName', snapshot.package_name,
        'canSwitchPackage', case
          when orders.id is null then enabled
          else enabled and private.package_order_can_switch(orders.id)
        end,
        'revision', private.package_workspace_revision(member_season.id)
      ) order by member_season.member_id)
      from app.member_seasons member_season
      left join app.member_orders orders
        on orders.member_season_id = member_season.id
      left join app.order_package_snapshots snapshot
        on snapshot.id = orders.active_package_snapshot_id
      where member_season.season_id = active_season
        and member_season.participation_status = 'active'
    ), '[]'::jsonb) else '[]'::jsonb end
  );
end;
$$;

revoke all on function public.get_parent_package_workspace(text)
from public, anon, authenticated;
revoke all on function public.select_parent_package(
  text, uuid, uuid, text, uuid
) from public, anon, authenticated;
revoke all on function app.select_member_package(
  uuid, uuid, text, text, uuid
) from public, anon;
revoke all on function public.confirm_parent_package_sizes(
  text, uuid, jsonb, text, uuid
) from public, anon, authenticated;
revoke all on function app.get_catalog_order_workspace_v3()
from public, anon;

grant execute on function public.get_parent_package_workspace(text)
to service_role;
grant execute on function public.select_parent_package(
  text, uuid, uuid, text, uuid
) to service_role;
grant execute on function app.select_member_package(
  uuid, uuid, text, text, uuid
) to authenticated;
grant execute on function public.confirm_parent_package_sizes(
  text, uuid, jsonb, text, uuid
) to service_role;
grant execute on function app.get_catalog_order_workspace_v3()
to authenticated;

notify pgrst, 'reload schema';

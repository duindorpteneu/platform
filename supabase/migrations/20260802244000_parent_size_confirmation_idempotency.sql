alter table app.package_size_confirmations
  add column request_id uuid,
  add column request_hash text,
  add constraint package_size_confirmations_request_hash_check check (
    (request_id is null and request_hash is null)
    or (
      request_id is not null
      and request_hash ~ '^[0-9a-f]{64}$'
    )
  ) not valid;

alter table app.package_size_confirmations
  validate constraint package_size_confirmations_request_hash_check;

create unique index package_size_confirmations_order_request_idx
  on app.package_size_confirmations(order_id, request_id)
  where request_id is not null;

create or replace function public.confirm_parent_package_sizes_v2(
  p_token_hash text,
  p_member_season_id uuid,
  p_selections jsonb,
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
  account_id uuid;
  target_order app.member_orders%rowtype;
  existing app.package_size_confirmations%rowtype;
  computed_hash text;
  result jsonb;
begin
  if p_request_id is null
    or p_selections is null
    or p_expected_revision is null
  then
    raise exception 'PACKAGE_SIZE_REQUEST_INVALID' using errcode = '22023';
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
      'package-size-request:' || p_request_id::text,
      0
    )
  );
  select * into target_order
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
  for update;
  if not found then
    raise exception 'PACKAGE_ORDER_REQUIRED' using errcode = '23514';
  end if;
  computed_hash := encode(extensions.digest(
    p_member_season_id::text || ':' ||
    p_expected_revision || ':' ||
    p_selections::text,
    'sha256'
  ), 'hex');

  select * into existing
  from app.package_size_confirmations confirmation
  where confirmation.order_id = target_order.id
    and confirmation.request_id = p_request_id
  for update;
  if found then
    if existing.request_hash is distinct from computed_hash
      or existing.parent_account_id is distinct from account_id
    then
      raise exception 'PACKAGE_SIZE_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'memberSeasonId', existing.member_season_id,
      'orderId', existing.order_id,
      'confirmationId', existing.id,
      'selectedCount', existing.selected_count,
      'conflictCount', existing.conflict_count,
      'changeRequestCount', existing.change_request_count,
      'sizesConfirmed', private.package_sizes_complete(
        existing.order_id,
        target_order.active_package_snapshot_id
      ),
      'revision', private.package_workspace_revision(existing.member_season_id),
      'reused', true
    );
  end if;

  result := public.confirm_parent_package_sizes(
    p_token_hash,
    p_member_season_id,
    p_selections,
    p_expected_revision,
    p_correlation_id
  );
  update app.package_size_confirmations
  set request_id = p_request_id,
      request_hash = computed_hash
  where id = (result->>'confirmationId')::uuid;
  return result || jsonb_build_object('reused', false);
end;
$$;

revoke execute on function public.confirm_parent_package_sizes(
  text, uuid, jsonb, text, uuid
) from service_role;
revoke all on function public.confirm_parent_package_sizes_v2(
  text, uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.confirm_parent_package_sizes_v2(
  text, uuid, jsonb, text, uuid, uuid
) to service_role;

notify pgrst, 'reload schema';

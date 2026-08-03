-- Tighten the final state proof around pending changes and withdrawal.
-- Fulfilled stock is no longer mutable, and semantic identity comes from the
-- immutable request plus the current projection rather than the caller.
create or replace function private.parent_package_variant_selectable(
  p_member_season_id uuid,
  p_season_id uuid,
  p_order_id uuid,
  p_article_id uuid,
  p_variant_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  variant_is_active boolean;
  historical_echo boolean;
begin
  if p_member_season_id is null
    or p_season_id is null
    or p_order_id is null
    or p_article_id is null
    or p_variant_id is null
  then
    return false;
  end if;

  select variant.active
  into variant_is_active
  from app.article_variants variant
  join app.article_seasons link
    on link.article_id = variant.article_id
    and link.season_id = p_season_id
  where variant.id = p_variant_id
    and variant.article_id = p_article_id
  for share of variant, link;
  if not found then
    return false;
  end if;
  if variant_is_active then
    return true;
  end if;

  select exists(
    select 1
    from app.member_article_sizes size_profile
    join app.order_lines line
      on line.order_id = p_order_id
      and line.article_id = p_article_id
      and line.article_variant_id = p_variant_id
      and line.status <> 'cancelled'
    where size_profile.member_season_id = p_member_season_id
      and size_profile.article_id = p_article_id
      and size_profile.article_variant_id = p_variant_id
      and (
        size_profile.selection_status = 'confirmed'
        or (
          size_profile.selection_status = 'change_requested'
          and exists(
            select 1
            from app.inventory_reservations reservation
            where reservation.order_line_id = line.id
              and reservation.status = 'reserved'
          )
        )
        or (
          size_profile.selection_status = 'locked'
          and (
            line.status = 'picked_up'
            or exists(
              select 1
              from app.fulfilment_lines fulfilment_line
              where fulfilment_line.order_line_id = line.id
                and fulfilment_line.reversed_at is null
            )
          )
        )
      )
  )
  into historical_echo;
  return historical_echo;
end;
$$;

do $migration$
declare
  function_source text;
  needle text;
  replacement text;
begin
  function_source := pg_get_functiondef(
    'private.capture_package_size_change_request()'::regprocedure
  );
  needle := $needle$
begin
  perform set_config('app.size_change_request_id', '', true);
  if new.selection_status <> 'change_requested' then
    return new;
  end if;
$needle$;
  replacement := $replacement$
begin
  if new.selection_status <> 'change_requested' then
    return new;
  end if;
  perform set_config('app.size_change_request_id', '', true);
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_CAPTURE_CONTEXT_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'public.confirm_parent_package_sizes(text,uuid,jsonb,text,uuid)'::regprocedure
  );
  needle := $needle$
      if not has_reservation
        or not exists(
$needle$;
  replacement := $replacement$
      if not has_reservation
        or size_profile.article_variant_id
          is distinct from order_line.article_variant_id
        or not exists(
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_REQUEST_CURRENT_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  needle := $needle$
            and request.current_variant_id = order_line.article_variant_id
            and request.parent_account_id = account_id
            and request.status = 'requested'
$needle$;
  replacement := $replacement$
            and request.current_variant_id = order_line.article_variant_id
            and request.parent_account_id =
              size_profile.requested_by_parent_account_id
            and request.requested_at = size_profile.requested_at
            and request.status = 'requested'
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_REQUEST_IDENTITY_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)'::regprocedure
  );
  needle := $needle$
      where request.member_season_id = p_member_season_id
        and request.article_id = target_article_id
        and request.status = 'requested'
      returning * into withdrawn_request;
$needle$;
  replacement := $replacement$
      where request.member_season_id = p_member_season_id
        and request.article_id = target_article_id
        and request.current_variant_id = target_variant_id
        and request.parent_account_id =
          target_size.requested_by_parent_account_id
        and request.requested_at = target_size.requested_at
        and request.requested_variant_id
          is not distinct from target_size.requested_article_variant_id
        and request.requested_raw_value
          is not distinct from target_size.requested_raw_value
        and request.requested_member_note
          is not distinct from target_size.requested_member_note
        and request.status = 'requested'
        and exists(
          select 1
          from app.inventory_reservations reservation
          where reservation.order_line_id = request.order_line_id
            and reservation.status = 'reserved'
        )
      returning * into withdrawn_request;
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_WITHDRAW_STATE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

revoke all on function private.parent_package_variant_selectable(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

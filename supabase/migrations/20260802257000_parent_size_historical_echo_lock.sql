-- Serialize package confirmation with catalog changes and allow an inactive
-- variant only as a proven echo of the current logistical history. A merely
-- imported suggestion or requested target is not historical proof.
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

  perform pg_advisory_xact_lock(
    hashtextextended('catalog-variant:' || p_article_id::text, 0)
  );
  select variant.active
  into variant_is_active
  from app.article_variants variant
  join app.article_seasons link
    on link.article_id = variant.article_id
    and link.season_id = p_season_id
  where variant.id = p_variant_id
    and variant.article_id = p_article_id
  for key share of variant, link;
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
              and reservation.status in ('reserved', 'fulfilled')
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
    'public.confirm_parent_package_sizes(text,uuid,jsonb,text,uuid)'::regprocedure
  );

  needle := $needle$
    if selected_kind = 'variant' and not exists(
      select 1
      from app.article_variants variant
      join app.article_seasons link
        on link.article_id = variant.article_id
        and link.season_id = member_season.season_id
      where variant.id = selected_variant_id
        and variant.article_id = selected_article_id
        and (
          variant.active
          or exists(
            select 1
            from app.member_article_sizes existing_size
            where existing_size.member_season_id = p_member_season_id
              and existing_size.article_id = selected_article_id
              and (
                existing_size.article_variant_id = selected_variant_id
                or (
                  existing_size.selection_status = 'change_requested'
                  and existing_size.requested_article_variant_id =
                    selected_variant_id
                )
              )
          )
        )
    ) then
$needle$;
  replacement := $replacement$
    if selected_kind = 'variant'
      and not private.parent_package_variant_selectable(
        p_member_season_id,
        member_season.season_id,
        target_order.id,
        selected_article_id,
        selected_variant_id
      )
    then
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_HISTORICAL_ECHO_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  needle := $needle$
    elsif not differs
      and size_profile.selection_status in (
        'confirmed',
        'locked',
        'change_requested'
      )
    then
      if size_profile.selection_status = 'change_requested' then
        change_request_count := change_request_count + 1;
      elsif selected_kind = 'other' then
        conflict_count := conflict_count + 1;
      end if;
$needle$;
  replacement := $replacement$
    elsif size_profile.selection_status = 'change_requested'
      and not differs
    then
      if not has_reservation
        or not exists(
          select 1
          from app.package_size_change_requests request
          where request.member_season_id = p_member_season_id
            and request.order_id = target_order.id
            and request.order_line_id = order_line.id
            and request.article_id = selected_article_id
            and request.current_variant_id = order_line.article_variant_id
            and request.parent_account_id = account_id
            and request.status = 'requested'
            and (
              (
                selected_kind = 'variant'
                and request.requested_variant_id = selected_variant_id
                and request.requested_raw_value is null
                and request.requested_member_note is null
              )
              or (
                selected_kind = 'other'
                and request.requested_variant_id is null
                and request.requested_raw_value = 'Anders…'
                and request.requested_member_note = selected_note
              )
            )
        )
      then
        raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
          using errcode = '23514';
      end if;
      change_request_count := change_request_count + 1;
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_REQUEST_NOOP_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

revoke all on function private.parent_package_variant_selectable(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

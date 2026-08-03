-- Dynamic import owns catalog advisory locks before taking member locks.
-- Package confirmation already owns the member locks, so taking the catalog
-- advisory lock here would invert that order. A deterministic SHARE row lock
-- is sufficient and also conflicts with UPDATE of variant.active.
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

revoke all on function private.parent_package_variant_selectable(
  uuid, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

-- Order-line lifecycle updates must not overwrite an explicit package-size
-- change request. The actual reserved variant remains authoritative until an
-- administrator resolves the request in a controlled workflow.

create or replace function app.sync_member_size_from_order_line()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_season_id uuid;
  target_member_season_id uuid;
  existing_size app.member_article_sizes%rowtype;
begin
  if new.status = 'cancelled' then
    return new;
  end if;

  select orders.member_id, orders.season_id, orders.member_season_id
  into target_member_id, target_season_id, target_member_season_id
  from app.member_orders orders
  where orders.id = new.order_id;

  if not exists(
    select 1
    from app.article_seasons link
    where link.article_id = new.article_id
      and link.season_id = target_season_id
  ) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );

  select *
  into existing_size
  from app.member_article_sizes size_profile
  where size_profile.member_id = target_member_id
    and size_profile.season_id = target_season_id
    and size_profile.article_id = new.article_id
  for update;

  if found
    and existing_size.article_variant_id is distinct from new.article_variant_id
    and existing_size.selection_status in (
      'confirmed',
      'change_requested',
      'locked'
    )
  then
    raise exception 'CONFIRMED_SIZE_CHANGE_REQUIRES_WORKFLOW'
      using errcode = '23514';
  end if;

  if found and existing_size.selection_status = 'conflict' then
    raise exception 'SIZE_CONFLICT_MUST_BE_RESOLVED'
      using errcode = '23514';
  end if;

  if found
    and existing_size.selection_status in (
      'confirmed',
      'change_requested',
      'locked'
    )
    and existing_size.article_variant_id = new.article_variant_id
  then
    return new;
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
    created_by,
    updated_by
  )
  values(
    target_member_id,
    target_season_id,
    target_member_season_id,
    new.article_id,
    new.article_variant_id,
    'confirmed',
    'order',
    timezone('utc', now()),
    auth.uid(),
    auth.uid()
  )
  on conflict(member_id, season_id, article_id) do update
  set article_variant_id = excluded.article_variant_id,
      selection_status = 'confirmed',
      selection_source = 'order',
      raw_value = null,
      member_note = null,
      confirmed_at = excluded.confirmed_at,
      confirmed_by = auth.uid(),
      confirmed_by_parent_account_id = null,
      requested_article_variant_id = null,
      requested_raw_value = null,
      requested_member_note = null,
      requested_at = null,
      requested_by_parent_account_id = null,
      updated_by = auth.uid(),
      updated_at = timezone('utc', now())
  where app.member_article_sizes.selection_status = 'imported_unconfirmed';

  return new;
end;
$$;

revoke all on function app.sync_member_size_from_order_line()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- Issuance locks a component, not every still-open component in the package.
-- A package-wide confirmation must echo locked variants unchanged while other
-- components may still be corrected.

create or replace function private.preserve_locked_package_size()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if old.selection_status = 'locked' then
    if new.article_variant_id is distinct from old.article_variant_id
      or new.selection_status not in ('confirmed', 'locked')
    then
      raise exception 'PACKAGE_SIZE_ISSUED_LOCKED' using errcode = '23514';
    end if;
    new.selection_status := 'locked';
    new.selection_source := old.selection_source;
    new.raw_value := old.raw_value;
    new.member_note := old.member_note;
    new.confirmed_at := old.confirmed_at;
    new.confirmed_by := old.confirmed_by;
    new.confirmed_by_parent_account_id :=
      old.confirmed_by_parent_account_id;
    new.requested_article_variant_id := null;
    new.requested_raw_value := null;
    new.requested_member_note := null;
    new.requested_at := null;
    new.requested_by_parent_account_id := null;
  end if;
  return new;
end;
$$;

create trigger member_article_sizes_preserve_locked_component
before update of
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
  requested_by_parent_account_id
on app.member_article_sizes
for each row execute function private.preserve_locked_package_size();

create or replace function public.confirm_parent_package_sizes_v3(
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
set search_path = app, private, pg_temp
as $$
declare
  account_id uuid;
  target_member_id uuid;
  target_order_id uuid;
  existing_confirmation_id uuid;
begin
  if p_member_season_id is null
    or p_request_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_selections is null
    or jsonb_typeof(p_selections) <> 'array'
    or jsonb_array_length(p_selections) not between 1 and 25
    or exists(
      select 1
      from jsonb_array_elements(p_selections) selection
      where jsonb_typeof(selection.value) <> 'object'
        or coalesce(selection.value->>'articleId', '') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        or coalesce(selection.value->>'kind', '') not in (
          'variant',
          'other'
        )
        or (
          selection.value->>'kind' = 'variant'
          and coalesce(selection.value->>'variantId', '') !~
            '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        )
    )
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
  select member_season.member_id
  into target_member_id
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if target_member_id is null then
    raise exception 'MEMBER_SEASON_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || p_member_season_id::text,
      0
    )
  );
  perform 1
  from app.member_seasons member_season
  where member_season.id = p_member_season_id
  for update;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'package-size-request:' || p_request_id::text,
      0
    )
  );
  select orders.id
  into target_order_id
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
  for update;
  if target_order_id is null then
    raise exception 'PACKAGE_ORDER_REQUIRED' using errcode = '23514';
  end if;

  select confirmation.id
  into existing_confirmation_id
  from app.package_size_confirmations confirmation
  where confirmation.order_id = target_order_id
    and confirmation.request_id = p_request_id;

  if (
    select count(distinct (selection.value->>'articleId')::uuid)
    from jsonb_array_elements(p_selections) selection
  ) <> jsonb_array_length(p_selections)
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
  end if;

  if existing_confirmation_id is null and exists(
    select 1
    from app.member_article_sizes size_profile
    join jsonb_array_elements(p_selections) selection(value)
      on (selection.value->>'articleId')::uuid = size_profile.article_id
    where size_profile.member_season_id = p_member_season_id
      and size_profile.selection_status = 'locked'
      and (
        selection.value->>'kind' <> 'variant'
        or nullif(selection.value->>'variantId', '')::uuid
          is distinct from size_profile.article_variant_id
      )
  ) then
    raise exception 'PACKAGE_SIZE_ISSUED_LOCKED' using errcode = '23514';
  end if;

  return public.confirm_parent_package_sizes_v2(
    p_token_hash,
    p_member_season_id,
    p_selections,
    p_expected_revision,
    p_request_id,
    p_correlation_id
  );
end;
$$;

revoke all on function private.preserve_locked_package_size()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

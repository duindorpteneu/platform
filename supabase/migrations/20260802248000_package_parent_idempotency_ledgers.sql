-- Durable per-item size confirmation facts, stable idempotent responses and
-- idempotent parent package selection.

alter table app.member_orders
  add constraint member_orders_id_member_season_unique
    unique (id, member_season_id);

alter table app.package_size_confirmations
  add column schema_version integer not null default 1
    check (schema_version in (1, 2)),
  add column result_snapshot jsonb,
  add constraint package_size_confirmation_result_check check (
    result_snapshot is null or jsonb_typeof(result_snapshot) = 'object'
  ) not valid,
  add constraint package_size_confirmation_order_season_fkey
    foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id)
    on delete restrict
    not valid;

alter table app.package_size_confirmations
  validate constraint package_size_confirmation_result_check;
alter table app.package_size_confirmations
  validate constraint package_size_confirmation_order_season_fkey;

create unique index package_size_confirmations_parent_request_idx
  on app.package_size_confirmations(parent_account_id, request_id)
  where parent_account_id is not null and request_id is not null;

create table app.package_size_confirmation_items (
  id uuid primary key default gen_random_uuid(),
  confirmation_id uuid not null
    references app.package_size_confirmations(id) on delete restrict,
  snapshot_item_id uuid not null
    references app.order_package_snapshot_items(id) on delete restrict,
  article_id uuid not null
    references app.articles(id) on delete restrict,
  selection_kind text not null check (
    selection_kind in ('variant', 'other')
  ),
  selected_variant_id uuid,
  other_note text,
  quantity_snapshot integer not null check (
    quantity_snapshot between 1 and 25
  ),
  product_name_snapshot text not null check (
    length(btrim(product_name_snapshot)) between 1 and 120
  ),
  product_code_snapshot text not null check (
    length(btrim(product_code_snapshot)) between 1 and 120
  ),
  created_at timestamptz not null default timezone('utc', now()),
  constraint package_size_confirmation_item_variant_fkey
    foreign key (selected_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  constraint package_size_confirmation_item_payload_check check (
    (
      selection_kind = 'variant'
      and selected_variant_id is not null
      and other_note is null
    )
    or (
      selection_kind = 'other'
      and selected_variant_id is null
      and length(btrim(coalesce(other_note, ''))) between 1 and 500
    )
  ),
  unique (confirmation_id, article_id),
  unique (confirmation_id, snapshot_item_id)
);

alter table app.package_size_confirmation_items enable row level security;
create policy "clothing staff can read package size confirmation items"
on app.package_size_confirmation_items
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);
revoke all on table app.package_size_confirmation_items
from public, anon, authenticated, service_role;
grant select on table app.package_size_confirmation_items to authenticated;

create or replace function app.protect_package_size_confirmation_item()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  raise exception 'PACKAGE_SIZE_CONFIRMATION_ITEM_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger package_size_confirmation_items_immutable
before update or delete on app.package_size_confirmation_items
for each row execute function app.protect_package_size_confirmation_item();

create or replace function private.preserve_reserved_size_provenance()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if old.article_variant_id is not distinct from new.article_variant_id
    and (
      (
        new.selection_status = 'change_requested'
        and old.selection_status in ('confirmed', 'change_requested', 'locked')
      )
      or (
        old.selection_status = 'change_requested'
        and new.selection_status = 'confirmed'
      )
    )
  then
    new.selection_source := old.selection_source;
    new.confirmed_at := old.confirmed_at;
    new.confirmed_by := old.confirmed_by;
    new.confirmed_by_parent_account_id :=
      old.confirmed_by_parent_account_id;
  end if;
  return new;
end;
$$;

create trigger member_article_sizes_preserve_reserved_provenance
before update of
  article_variant_id,
  selection_status,
  selection_source,
  confirmed_at,
  confirmed_by,
  confirmed_by_parent_account_id
on app.member_article_sizes
for each row execute function private.preserve_reserved_size_provenance();

create or replace function public.confirm_parent_package_sizes_v4(
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
  result jsonb;
  confirmation app.package_size_confirmations%rowtype;
  stable_result jsonb;
  inserted_count integer;
begin
  account_id := private.parent_account_for_member_season(
    p_token_hash,
    p_member_season_id
  );
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;

  result := public.confirm_parent_package_sizes_v3(
    p_token_hash,
    p_member_season_id,
    p_selections,
    p_expected_revision,
    p_request_id,
    p_correlation_id
  );
  select *
  into confirmation
  from app.package_size_confirmations current_confirmation
  where current_confirmation.id = (result->>'confirmationId')::uuid
  for update;
  if not found
    or confirmation.parent_account_id <> account_id
    or confirmation.member_season_id <> p_member_season_id
    or confirmation.request_id <> p_request_id
  then
    raise exception 'PACKAGE_SIZE_CONFIRMATION_STATE_INVALID'
      using errcode = '23514';
  end if;

  if confirmation.result_snapshot is null then
    insert into app.package_size_confirmation_items(
      confirmation_id,
      snapshot_item_id,
      article_id,
      selection_kind,
      selected_variant_id,
      other_note,
      quantity_snapshot,
      product_name_snapshot,
      product_code_snapshot
    )
    select
      confirmation.id,
      snapshot_item.id,
      snapshot_item.article_id,
      selection.value->>'kind',
      case
        when selection.value->>'kind' = 'variant'
          then (selection.value->>'variantId')::uuid
        else null
      end,
      case
        when selection.value->>'kind' = 'other'
          then btrim(selection.value->>'note')
        else null
      end,
      snapshot_item.quantity,
      snapshot_item.product_name_snapshot,
      snapshot_item.product_code_snapshot
    from jsonb_array_elements(p_selections) selection(value)
    join app.member_orders orders
      on orders.id = confirmation.order_id
    join app.order_package_snapshot_items snapshot_item
      on snapshot_item.snapshot_id = orders.active_package_snapshot_id
      and snapshot_item.article_id =
        (selection.value->>'articleId')::uuid
    on conflict (confirmation_id, article_id) do nothing;
    get diagnostics inserted_count = row_count;
    if (
      select count(*)
      from app.package_size_confirmation_items confirmation_item
      where confirmation_item.confirmation_id = confirmation.id
    ) <> confirmation.selected_count
    then
      raise exception 'PACKAGE_SIZE_CONFIRMATION_ITEMS_INCOMPLETE'
        using errcode = '23514';
    end if;

    stable_result := result || jsonb_build_object('reused', false);
    update app.package_size_confirmations
    set schema_version = 2,
        result_snapshot = stable_result
    where id = confirmation.id
    returning result_snapshot into stable_result;
  else
    stable_result := confirmation.result_snapshot;
  end if;

  return stable_result || jsonb_build_object(
    'reused',
    coalesce((result->>'reused')::boolean, false)
  );
end;
$$;

revoke execute on function public.confirm_parent_package_sizes_v3(
  text, uuid, jsonb, text, uuid, uuid
) from service_role;
revoke all on function public.confirm_parent_package_sizes_v4(
  text, uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.confirm_parent_package_sizes_v4(
  text, uuid, jsonb, text, uuid, uuid
) to service_role;

create table private.parent_package_selection_requests (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  package_revision_id uuid not null
    references app.package_template_revisions(id) on delete restrict,
  request_id uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
  ),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  unique (parent_account_id, request_id)
);

alter table private.parent_package_selection_requests enable row level security;
revoke all on table private.parent_package_selection_requests
from public, anon, authenticated, service_role;

create or replace function private.protect_parent_package_selection_request()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'PACKAGE_SELECTION_REQUEST_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger parent_package_selection_requests_immutable
before update or delete on private.parent_package_selection_requests
for each row
execute function private.protect_parent_package_selection_request();

create or replace function public.select_parent_package_v3(
  p_token_hash text,
  p_member_season_id uuid,
  p_package_revision_id uuid,
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
  target_member_id uuid;
  request_hash text;
  existing private.parent_package_selection_requests%rowtype;
  result jsonb;
begin
  if p_request_id is null
    or p_member_season_id is null
    or p_package_revision_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
  then
    raise exception 'PACKAGE_SELECTION_INVALID' using errcode = '22023';
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
    raise exception 'MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  request_hash := encode(extensions.digest(
    p_member_season_id::text || ':' ||
    p_package_revision_id::text || ':' ||
    p_expected_revision,
    'sha256'
  ), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'parent-package-selection:' || account_id::text || ':' ||
        p_request_id::text,
      0
    )
  );
  select *
  into existing
  from private.parent_package_selection_requests selection_request
  where selection_request.parent_account_id = account_id
    and selection_request.request_id = p_request_id
  for update;
  if found then
    if existing.request_hash <> request_hash
      or existing.member_season_id <> p_member_season_id
      or existing.package_revision_id <> p_package_revision_id
    then
      raise exception 'PACKAGE_SELECTION_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  result := public.select_parent_package_v2(
    p_token_hash,
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    p_correlation_id
  ) || jsonb_build_object('reused', false);
  insert into private.parent_package_selection_requests(
    parent_account_id,
    member_season_id,
    package_revision_id,
    request_id,
    request_hash,
    result_snapshot,
    correlation_id
  )
  values(
    account_id,
    p_member_season_id,
    p_package_revision_id,
    p_request_id,
    request_hash,
    result,
    p_correlation_id
  );
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
    'order.package_selection.requested',
    'member_order',
    (result->>'orderId')::uuid,
    jsonb_build_object(
      'memberSeasonId', p_member_season_id,
      'packageRevisionId', p_package_revision_id,
      'parentAccountId', account_id,
      'requestId', p_request_id
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke execute on function public.select_parent_package_v2(
  text, uuid, uuid, text, uuid
) from service_role;
revoke all on function public.select_parent_package_v3(
  text, uuid, uuid, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.select_parent_package_v3(
  text, uuid, uuid, text, uuid, uuid
) to service_role;

create or replace function public.get_parent_package_workspace_v3(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        jsonb_set(
          member.value,
          '{availablePackages}',
          coalesce((
            select jsonb_agg(
              package.value || jsonb_build_object(
                'items',
                coalesce((
                  select jsonb_agg(jsonb_build_object(
                    'articleId', item.article_id,
                    'name', item.product_name_snapshot,
                    'code', item.product_code_snapshot,
                    'quantity', item.quantity
                  ) order by item.sort_order, item.id)
                  from app.package_template_items item
                  where item.revision_id =
                    (package.value->>'revisionId')::uuid
                ), '[]'::jsonb)
              )
              order by package.ordinality
            )
            from jsonb_array_elements(
              member.value->'availablePackages'
            ) with ordinality as package(value, ordinality)
          ), '[]'::jsonb),
          true
        )
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality as member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from (
    select public.get_parent_package_workspace_v2(p_token_hash) result
  ) workspace;
$$;

revoke execute on function public.get_parent_package_workspace_v2(text)
from service_role;
revoke all on function public.get_parent_package_workspace_v3(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v3(text)
to service_role;

revoke all on function app.protect_package_size_confirmation_item()
from public, anon, authenticated, service_role;
revoke all on function private.preserve_reserved_size_provenance()
from public, anon, authenticated, service_role;
revoke all on function private.protect_parent_package_selection_request()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

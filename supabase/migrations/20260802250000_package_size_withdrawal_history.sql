-- Preserve every material size projection state and let a parent explicitly
-- withdraw a reserved-size change by reselecting the actually reserved size.
--
-- The current member_article_sizes row remains a projection. This append-only
-- history keeps imported raw conflicts after a later parent confirmation.

create table app.member_size_selection_history (
  id uuid primary key default gen_random_uuid(),
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  article_id uuid not null
    references app.articles(id) on delete restrict,
  article_variant_id uuid,
  selection_status app.size_selection_status not null,
  selection_source app.size_selection_source not null,
  raw_value text,
  member_note text,
  origin text not null check (
    origin in ('upgrade_backfill', 'projection_change')
  ),
  recorded_at timestamptz not null default timezone('utc', now()),
  constraint member_size_history_variant_fkey
    foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  constraint member_size_history_payload_check check (
    (raw_value is null or length(btrim(raw_value)) between 1 and 160)
    and (member_note is null or length(btrim(member_note)) between 1 and 500)
  )
);

create index member_size_selection_history_lookup_idx
  on app.member_size_selection_history(
    member_season_id,
    article_id,
    recorded_at desc,
    id desc
  );

alter table app.member_size_selection_history enable row level security;
create policy "clothing staff can read size selection history"
on app.member_size_selection_history
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);
revoke all on table app.member_size_selection_history
from public, anon, authenticated, service_role;
grant select on table app.member_size_selection_history to authenticated;

insert into app.member_size_selection_history(
  member_season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value,
  member_note,
  origin,
  recorded_at
)
select
  size_profile.member_season_id,
  size_profile.article_id,
  size_profile.article_variant_id,
  size_profile.selection_status,
  size_profile.selection_source,
  size_profile.raw_value,
  size_profile.member_note,
  'upgrade_backfill',
  coalesce(size_profile.updated_at, size_profile.created_at)
from app.member_article_sizes size_profile;

create or replace function app.capture_member_size_selection_history()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
    and old.member_season_id is not distinct from new.member_season_id
    and old.article_id is not distinct from new.article_id
    and old.article_variant_id is not distinct from new.article_variant_id
    and old.selection_status is not distinct from new.selection_status
    and old.selection_source is not distinct from new.selection_source
    and old.raw_value is not distinct from new.raw_value
    and old.member_note is not distinct from new.member_note
  then
    return new;
  end if;

  insert into app.member_size_selection_history(
    member_season_id,
    article_id,
    article_variant_id,
    selection_status,
    selection_source,
    raw_value,
    member_note,
    origin
  )
  values(
    new.member_season_id,
    new.article_id,
    new.article_variant_id,
    new.selection_status,
    new.selection_source,
    new.raw_value,
    new.member_note,
    'projection_change'
  );
  return new;
end;
$$;

create trigger member_article_sizes_capture_history
after insert or update of
  member_season_id,
  article_id,
  article_variant_id,
  selection_status,
  selection_source,
  raw_value,
  member_note
on app.member_article_sizes
for each row execute function app.capture_member_size_selection_history();

create or replace function app.protect_member_size_selection_history()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  raise exception 'MEMBER_SIZE_HISTORY_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger member_size_selection_history_immutable
before update or delete on app.member_size_selection_history
for each row execute function app.protect_member_size_selection_history();

alter table app.package_size_change_requests
  add column withdrawn_by_parent_account_id uuid
    references private.parent_accounts(id) on delete restrict;

alter table app.package_size_change_requests
  drop constraint package_size_change_requests_status_check,
  drop constraint package_size_change_lifecycle_check;

alter table app.package_size_change_requests
  add constraint package_size_change_requests_status_check check (
    status in (
      'requested',
      'approved',
      'rejected',
      'superseded',
      'withdrawn'
    )
  ) not valid,
  add constraint package_size_change_lifecycle_check check (
    (
      status = 'requested'
      and resolved_at is null
      and resolved_by is null
      and resolution_reason is null
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
      and withdrawn_by_parent_account_id is null
    )
    or (
      status = 'approved'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, ''))) between 3 and 500
      and approved_variant_id is not null
      and released_reservation_id is not null
      and replacement_order_line_id is not null
      and withdrawn_by_parent_account_id is null
    )
    or (
      status = 'rejected'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, ''))) between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
      and withdrawn_by_parent_account_id is null
    )
    or (
      status = 'superseded'
      and resolved_at is not null
      and resolved_by is null
      and length(btrim(coalesce(resolution_reason, ''))) between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
      and withdrawn_by_parent_account_id is null
    )
    or (
      status = 'withdrawn'
      and resolved_at is not null
      and resolved_by is null
      and length(btrim(coalesce(resolution_reason, ''))) between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
      and withdrawn_by_parent_account_id is not null
    )
  ) not valid;

alter table app.package_size_change_requests
  validate constraint package_size_change_requests_status_check;
alter table app.package_size_change_requests
  validate constraint package_size_change_lifecycle_check;

create or replace function app.protect_package_size_change_request()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'PACKAGE_SIZE_CHANGE_IMMUTABLE' using errcode = '23514';
  end if;
  if old.member_season_id is distinct from new.member_season_id
    or old.order_id is distinct from new.order_id
    or old.order_line_id is distinct from new.order_line_id
    or old.article_id is distinct from new.article_id
    or old.current_variant_id is distinct from new.current_variant_id
    or old.requested_variant_id is distinct from new.requested_variant_id
    or old.requested_raw_value is distinct from new.requested_raw_value
    or old.requested_member_note is distinct from new.requested_member_note
    or old.parent_account_id is distinct from new.parent_account_id
    or old.requested_at is distinct from new.requested_at
    or old.correlation_id is distinct from new.correlation_id
    or old.created_at is distinct from new.created_at
    or old.status <> 'requested'
    or new.status not in (
      'approved',
      'rejected',
      'superseded',
      'withdrawn'
    )
    or (
      new.status = 'withdrawn'
      and new.withdrawn_by_parent_account_id is null
    )
    or (
      new.status <> 'withdrawn'
      and new.withdrawn_by_parent_account_id is not null
    )
  then
    raise exception 'PACKAGE_SIZE_CHANGE_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

alter table app.package_size_confirmations
  add column client_request_hash text,
  add constraint package_size_confirmation_client_hash_check check (
    client_request_hash is null
    or client_request_hash ~ '^[0-9a-f]{64}$'
  ) not valid;

alter table app.package_size_confirmations
  validate constraint package_size_confirmation_client_hash_check;

create or replace function public.confirm_parent_package_sizes_v5(
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
  target_member_id uuid;
  target_order_id uuid;
  existing app.package_size_confirmations%rowtype;
  client_hash text;
  effective_revision text;
  result jsonb;
  selection jsonb;
  target_article_id uuid;
  target_variant_id uuid;
  target_size app.member_article_sizes%rowtype;
  withdrawn_request app.package_size_change_requests%rowtype;
  change_key text;
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
      from jsonb_array_elements(p_selections) item
      where jsonb_typeof(item.value) <> 'object'
        or coalesce(item.value->>'articleId', '') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        or coalesce(item.value->>'kind', '') not in ('variant', 'other')
        or (
          item.value->>'kind' = 'variant'
          and coalesce(item.value->>'variantId', '') !~
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

  client_hash := encode(extensions.digest(
    p_member_season_id::text || ':' ||
    p_expected_revision || ':' ||
    p_selections::text,
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

  select *
  into existing
  from app.package_size_confirmations confirmation
  where confirmation.parent_account_id = account_id
    and confirmation.request_id = p_request_id
  for update;
  if found then
    if coalesce(existing.client_request_hash, existing.request_hash)
      is distinct from client_hash
      or existing.member_season_id <> p_member_season_id
    then
      raise exception 'PACKAGE_SIZE_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    if existing.result_snapshot is null then
      raise exception 'PACKAGE_SIZE_CONFIRMATION_STATE_INVALID'
        using errcode = '23514';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  if private.package_workspace_revision(p_member_season_id)
    <> p_expected_revision
  then
    raise exception 'PACKAGE_SIZE_SELECTION_CONFLICT' using errcode = '40001';
  end if;

  for selection in
    select item.value
    from jsonb_array_elements(p_selections) item(value)
    where item.value->>'kind' = 'variant'
    order by (item.value->>'articleId')::uuid
  loop
    target_article_id := (selection->>'articleId')::uuid;
    target_variant_id := (selection->>'variantId')::uuid;
    select *
    into target_size
    from app.member_article_sizes size_profile
    where size_profile.member_season_id = p_member_season_id
      and size_profile.article_id = target_article_id
    for update;

    if found
      and target_size.selection_status = 'change_requested'
      and target_size.article_variant_id = target_variant_id
    then
      update app.package_size_change_requests request
      set status = 'withdrawn',
          resolved_at = timezone('utc', now()),
          resolution_reason = 'Ingetrokken door herbevestiging van de gereserveerde maat',
          withdrawn_by_parent_account_id = account_id
      where request.member_season_id = p_member_season_id
        and request.article_id = target_article_id
        and request.status = 'requested'
      returning * into withdrawn_request;
      if not found then
        raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
          using errcode = '23514';
      end if;

      perform set_config('app.package_size_internal', 'on', true);
      update app.member_article_sizes
      set selection_status = 'confirmed',
          requested_article_variant_id = null,
          requested_raw_value = null,
          requested_member_note = null,
          requested_at = null,
          requested_by_parent_account_id = null,
          updated_at = timezone('utc', now())
      where member_season_id = p_member_season_id
        and article_id = target_article_id;
      perform set_config('app.package_size_internal', 'off', true);

      change_key := encode(extensions.digest(
        'size-change-reserved:' || p_member_season_id::text || ':' ||
          target_article_id::text,
        'sha256'
      ), 'hex');
      perform private.auto_resolve_action_item(
        'size_change_after_reservation',
        target_size.season_id,
        change_key,
        'Automatisch gesloten doordat de gereserveerde maat is herbevestigd'
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
        'order.package_size_change.withdrawn',
        'package_size_change_request',
        withdrawn_request.id,
        jsonb_build_object(
          'memberSeasonId', p_member_season_id,
          'orderId', withdrawn_request.order_id,
          'orderLineId', withdrawn_request.order_line_id,
          'articleId', target_article_id,
          'parentAccountId', account_id
        ),
        p_correlation_id
      );
    end if;
  end loop;

  effective_revision := private.package_workspace_revision(
    p_member_season_id
  );
  result := public.confirm_parent_package_sizes_v4(
    p_token_hash,
    p_member_season_id,
    p_selections,
    effective_revision,
    p_request_id,
    p_correlation_id
  );
  update app.package_size_confirmations
  set client_request_hash = client_hash
  where id = (result->>'confirmationId')::uuid
    and parent_account_id = account_id
    and member_season_id = p_member_season_id;
  if not found then
    raise exception 'PACKAGE_SIZE_CONFIRMATION_STATE_INVALID'
      using errcode = '23514';
  end if;
  return result;
end;
$$;

revoke execute on function public.confirm_parent_package_sizes_v4(
  text, uuid, jsonb, text, uuid, uuid
) from service_role;
revoke all on function public.confirm_parent_package_sizes_v5(
  text, uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.confirm_parent_package_sizes_v5(
  text, uuid, jsonb, text, uuid, uuid
) to service_role;

revoke all on function app.capture_member_size_selection_history()
from public, anon, authenticated, service_role;
revoke all on function app.protect_member_size_selection_history()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

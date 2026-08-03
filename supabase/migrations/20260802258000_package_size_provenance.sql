-- Keep enough durable provenance to reconstruct a size transition after raw
-- import staging has expired, without copying the CSV row or other PII.
alter table app.package_size_change_requests
  add column client_request_id uuid;

alter table app.member_size_selection_history
  add column correlation_id uuid,
  add column client_request_id uuid,
  add column size_change_request_id uuid
    references app.package_size_change_requests(id) on delete restrict,
  add column import_run_id uuid
    references app.dynamic_import_runs(id) on delete restrict,
  add column import_source_row integer,
  add column actor_user_id uuid,
  add column actor_parent_account_id uuid
    references private.parent_accounts(id) on delete restrict,
  add constraint member_size_history_import_provenance_check check (
    (
      import_run_id is null
      and import_source_row is null
    )
    or (
      import_run_id is not null
      and import_source_row between 1 and 200000
    )
  ) not valid,
  add constraint member_size_history_actor_check check (
    actor_user_id is null
    or actor_parent_account_id is null
  ) not valid;

alter table app.member_size_selection_history
  validate constraint member_size_history_import_provenance_check;
alter table app.member_size_selection_history
  validate constraint member_size_history_actor_check;

create index member_size_selection_history_correlation_idx
  on app.member_size_selection_history(correlation_id)
  where correlation_id is not null;
create index member_size_selection_history_import_idx
  on app.member_size_selection_history(import_run_id, import_source_row)
  where import_run_id is not null;

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
    or old.client_request_id is distinct from new.client_request_id
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

create or replace function private.capture_package_size_change_request()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order_id uuid;
  target_line_id uuid;
  target_current_variant_id uuid;
  target_reservation_id uuid;
  captured_request_id uuid;
begin
  perform set_config('app.size_change_request_id', '', true);
  if new.selection_status <> 'change_requested' then
    return new;
  end if;
  if tg_op = 'UPDATE'
    and old.selection_status = 'change_requested'
    and old.article_variant_id is not distinct from new.article_variant_id
    and old.requested_article_variant_id
      is not distinct from new.requested_article_variant_id
    and old.requested_raw_value is not distinct from new.requested_raw_value
    and old.requested_member_note is not distinct from new.requested_member_note
    and old.requested_by_parent_account_id
      is not distinct from new.requested_by_parent_account_id
    and old.requested_at is not distinct from new.requested_at
  then
    return new;
  end if;

  select orders.id, line.id, line.article_variant_id, reservation.id
  into
    target_order_id,
    target_line_id,
    target_current_variant_id,
    target_reservation_id
  from app.member_orders orders
  join app.order_lines line
    on line.order_id = orders.id
    and line.article_id = new.article_id
    and line.status <> 'cancelled'
  join app.inventory_reservations reservation
    on reservation.order_line_id = line.id
    and reservation.status = 'reserved'
  where orders.member_season_id = new.member_season_id
  order by line.created_at desc, line.id desc
  limit 1;

  if target_line_id is null
    or target_current_variant_id is distinct from new.article_variant_id
    or new.requested_by_parent_account_id is null
    or new.requested_at is null
  then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
      using errcode = '23514';
  end if;

  update app.package_size_change_requests request
  set status = 'superseded',
      resolved_at = timezone('utc', now()),
      resolution_reason = 'Vervangen door een nieuwer ouderverzoek'
  where request.order_line_id = target_line_id
    and request.status = 'requested';

  insert into app.package_size_change_requests(
    member_season_id,
    order_id,
    order_line_id,
    article_id,
    current_variant_id,
    requested_variant_id,
    requested_raw_value,
    requested_member_note,
    parent_account_id,
    requested_at,
    correlation_id,
    client_request_id
  )
  values(
    new.member_season_id,
    target_order_id,
    target_line_id,
    new.article_id,
    new.article_variant_id,
    new.requested_article_variant_id,
    new.requested_raw_value,
    new.requested_member_note,
    new.requested_by_parent_account_id,
    new.requested_at,
    nullif(current_setting('app.size_correlation_id', true), '')::uuid,
    nullif(current_setting('app.size_client_request_id', true), '')::uuid
  )
  returning id into captured_request_id;
  perform set_config(
    'app.size_change_request_id',
    captured_request_id::text,
    true
  );
  return new;
end;
$$;

create or replace function app.capture_member_size_selection_history()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  provenance_correlation_id uuid :=
    nullif(current_setting('app.size_correlation_id', true), '')::uuid;
  provenance_client_request_id uuid :=
    nullif(current_setting('app.size_client_request_id', true), '')::uuid;
  provenance_change_request_id uuid :=
    nullif(current_setting('app.size_change_request_id', true), '')::uuid;
  provenance_import_run_id uuid :=
    nullif(current_setting('app.size_import_run_id', true), '')::uuid;
  provenance_import_source_row integer :=
    nullif(current_setting('app.size_import_source_row', true), '')::integer;
  provenance_actor_user_id uuid;
  provenance_parent_account_id uuid;
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

  provenance_actor_user_id := coalesce(
    auth.uid(),
    new.confirmed_by,
    new.updated_by,
    new.created_by
  );
  if provenance_actor_user_id is null then
    provenance_parent_account_id := coalesce(
      new.requested_by_parent_account_id,
      new.confirmed_by_parent_account_id
    );
  end if;

  insert into app.member_size_selection_history(
    member_season_id,
    article_id,
    article_variant_id,
    selection_status,
    selection_source,
    raw_value,
    member_note,
    origin,
    correlation_id,
    client_request_id,
    size_change_request_id,
    import_run_id,
    import_source_row,
    actor_user_id,
    actor_parent_account_id
  )
  values(
    new.member_season_id,
    new.article_id,
    new.article_variant_id,
    new.selection_status,
    new.selection_source,
    new.raw_value,
    new.member_note,
    'projection_change',
    provenance_correlation_id,
    provenance_client_request_id,
    provenance_change_request_id,
    provenance_import_run_id,
    provenance_import_source_row,
    provenance_actor_user_id,
    provenance_parent_account_id
  );
  perform set_config('app.size_change_request_id', '', true);
  return new;
end;
$$;

drop trigger member_article_sizes_capture_history
on app.member_article_sizes;
create trigger member_article_sizes_record_history
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

create or replace function app.resolve_package_size_change_v3(
  p_request_id uuid,
  p_decision text,
  p_approved_variant_id uuid,
  p_reason text,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_member_season_id uuid;
begin
  perform private.require_admin_aal2();
  perform set_config(
    'app.size_correlation_id',
    coalesce(p_correlation_id::text, ''),
    true
  );
  perform set_config('app.size_client_request_id', '', true);
  perform set_config(
    'app.size_change_request_id',
    coalesce(p_request_id::text, ''),
    true
  );
  perform set_config('app.size_import_run_id', '', true);
  perform set_config('app.size_import_source_row', '', true);

  select member_season.member_id, request.member_season_id
  into target_member_id, target_member_season_id
  from app.package_size_change_requests request
  join app.member_seasons member_season
    on member_season.id = request.member_season_id
  where request.id = p_request_id;
  if target_member_id is null then
    raise exception 'PACKAGE_SIZE_CHANGE_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || target_member_season_id::text,
      0
    )
  );
  return app.resolve_package_size_change_v2(
    p_request_id,
    p_decision,
    p_approved_variant_id,
    p_reason,
    p_expected_revision,
    p_correlation_id
  );
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
  perform set_config('app.package_size_internal', 'on', true);
$needle$;
  replacement := $replacement$
  perform set_config(
    'app.size_correlation_id',
    coalesce(p_correlation_id::text, ''),
    true
  );
  perform set_config('app.size_import_run_id', '', true);
  perform set_config('app.size_import_source_row', '', true);
  perform set_config('app.package_size_internal', 'on', true);
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_CORE_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)'::regprocedure
  );
  needle := $needle$
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;
  select member_season.member_id
$needle$;
  replacement := $replacement$
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;
  perform set_config(
    'app.size_correlation_id',
    coalesce(p_correlation_id::text, ''),
    true
  );
  perform set_config(
    'app.size_client_request_id',
    p_request_id::text,
    true
  );
  perform set_config('app.size_change_request_id', '', true);
  perform set_config('app.size_import_run_id', '', true);
  perform set_config('app.size_import_source_row', '', true);
  select member_season.member_id
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_V5_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  needle := $needle$
      if not found then
        raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
          using errcode = '23514';
      end if;

      perform set_config('app.package_size_internal', 'on', true);
$needle$;
  replacement := $replacement$
      if not found then
        raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
          using errcode = '23514';
      end if;
      perform set_config(
        'app.size_change_request_id',
        withdrawn_request.id::text,
        true
      );

      perform set_config('app.package_size_internal', 'on', true);
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_SIZE_WITHDRAW_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'private.apply_dynamic_import_row(uuid,integer)'::regprocedure
  );
  needle := $needle$
  fields := selected.selected_values->'fields';
$needle$;
  replacement := $replacement$
  perform set_config(
    'app.size_correlation_id',
    coalesce(target_run.correlation_id::text, ''),
    true
  );
  perform set_config('app.size_client_request_id', '', true);
  perform set_config('app.size_change_request_id', '', true);
  perform set_config('app.size_import_run_id', p_run_id::text, true);
  perform set_config(
    'app.size_import_source_row',
    p_source_row::text,
    true
  );
  fields := selected.selected_values->'fields';
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'DYNAMIC_IMPORT_SIZE_PROVENANCE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

revoke all on function app.capture_member_size_selection_history()
from public, anon, authenticated, service_role;
revoke all on function private.capture_package_size_change_request()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

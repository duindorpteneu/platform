-- Package-first payment and size communication.
--
-- A commercial package may be paid before any size has been confirmed and
-- before physical stock exists. Logistics remain line/size/allocation based;
-- payment and size communication use the immutable package snapshot instead.

create or replace function private.mail_v2_template_allows_zero_lines(
  p_template_key text
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_template_key in (
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder',
    'size_confirmed',
    'payment_request',
    'payment_reminder',
    'payment_received_waiting_stock'
  );
$$;

revoke all on function private.mail_v2_template_allows_zero_lines(text)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_active_package_order(
  p_order_id uuid,
  p_member_season_id uuid,
  p_season_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from app.member_orders orders
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.member_id = orders.member_id
      and member_season.season_id = orders.season_id
      and member_season.participation_status = 'active'
      and member_season.reconciliation_status = 'resolved'
    join app.seasons season
      on season.id = orders.season_id
      and season.status = 'open'
    where orders.id = p_order_id
      and orders.member_season_id = p_member_season_id
      and orders.season_id = p_season_id
      and orders.package_assignment_state = 'active'
      and orders.package_revision_id is not null
      and orders.active_package_snapshot_id is not null
  );
$$;

revoke all on function private.mail_v2_active_package_order(
  uuid, uuid, uuid
) from public, anon, authenticated, service_role;

-- Public checkout is available for a real active package, regardless of
-- order lines, confirmed sizes, stock or allocation. Existing line-based
-- legacy orders keep their dual-compatibility path; withdrawals stay closed.
do $migration$
declare
  function_source text;
  needle text := $needle$
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc
    and orders.id = p_order_id
$needle$;
  replacement text := $replacement$
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc
    and orders.id = p_order_id
    and orders.package_assignment_state = 'active'
    and orders.active_package_snapshot_id is not null
    and (
      orders.package_revision_id is not null
      or exists(
        select 1
        from app.order_lines line
        where line.order_id = orders.id
          and line.status <> 'cancelled'
      )
    )
$replacement$;
begin
  function_source := pg_get_functiondef(
    'public.prepare_mollie_payment(text,uuid,text)'::regprocedure
  );
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PACKAGE_PAYMENT_PREPARE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

alter function private.mail_v2_size_segment(uuid)
rename to mail_v2_size_segment_v1;

create or replace function private.mail_v2_size_segment(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select case
  when exists(
    select 1
    from app.member_orders orders
    where orders.id = p_order_id
      and orders.package_assignment_state = 'active'
      and orders.package_revision_id is not null
      and orders.active_package_snapshot_id is not null
  ) then (
  with target as (
    select
      orders.id,
      orders.member_season_id,
      orders.active_package_snapshot_id
    from app.member_orders orders
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.participation_status = 'active'
      and member_season.reconciliation_status = 'resolved'
    join app.seasons season
      on season.id = orders.season_id
      and season.status = 'open'
    where orders.id = p_order_id
      and orders.package_assignment_state = 'active'
      and orders.package_revision_id is not null
      and orders.active_package_snapshot_id is not null
  ),
  state as (
    select
      count(*)::integer item_count,
      count(*) filter (
        where size_profile.member_season_id is null
          or (
            size_profile.selection_status = 'conflict'
            and not (
              size_profile.selection_source = 'parent'
              and size_profile.confirmed_at is not null
              and length(btrim(coalesce(size_profile.member_note, '')))
                between 1 and 500
            )
          )
      )::integer fill_count,
      count(*) filter (
        where size_profile.selection_status = 'imported_unconfirmed'
      )::integer review_count
    from target
    join app.order_package_snapshot_items item
      on item.snapshot_id = target.active_package_snapshot_id
    left join app.member_article_sizes size_profile
      on size_profile.member_season_id = target.member_season_id
      and size_profile.article_id = item.article_id
  )
  select case
    when item_count = 0 then 'blocked'
    when fill_count > 0 then 'fill'
    when review_count > 0 then 'review'
    else 'complete'
  end
  from state
  )
  else private.mail_v2_size_segment_v1(p_order_id)
  end;
$$;

revoke all on function private.mail_v2_size_segment_v1(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_size_segment(uuid)
from public, anon, authenticated, service_role;

-- Let the established payload and event writers resolve commercial package
-- processes without requiring a materialized logistics line.
do $migration$
declare
  function_source text;
  needle text;
  replacement text;
begin
  function_source := pg_get_functiondef(
    'private.mail_v2_member_payload_v2(text,uuid,uuid,uuid,uuid)'::regprocedure
  );
  needle := $needle$
    where candidate.member_season_id = member_season.id
      and candidate.active_package_snapshot_id is not null
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = candidate.id
          and line.status <> 'cancelled'
      )
$needle$;
  replacement := $replacement$
    where candidate.member_season_id = member_season.id
      and candidate.active_package_snapshot_id is not null
      and (
        (
          private.mail_v2_template_allows_zero_lines(p_template_key)
          and (
            (
              candidate.package_assignment_state = 'active'
              and candidate.package_revision_id is not null
            )
            or exists(
              select 1
              from app.order_lines line
              where line.order_id = candidate.id
                and line.status <> 'cancelled'
            )
          )
        )
        or (
          not private.mail_v2_template_allows_zero_lines(p_template_key)
          and exists(
            select 1
            from app.order_lines line
            where line.order_id = candidate.id
              and line.status <> 'cancelled'
          )
        )
      )
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'MAIL_PAYLOAD_PACKAGE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'private.enqueue_mail_v2_member_event(text,uuid,uuid,text,uuid,uuid,text,uuid)'::regprocedure
  );
  needle := $needle$
  where orders.member_season_id = p_member_season_id
    and orders.active_package_snapshot_id is not null
    and exists(
      select 1
      from app.order_lines line
      where line.order_id = orders.id
        and line.status <> 'cancelled'
    )
$needle$;
  replacement := $replacement$
  where orders.member_season_id = p_member_season_id
    and orders.active_package_snapshot_id is not null
    and (
      (
        private.mail_v2_template_allows_zero_lines(p_template_key)
        and (
          (
            orders.package_assignment_state = 'active'
            and orders.package_revision_id is not null
          )
          or exists(
            select 1
            from app.order_lines line
            where line.order_id = orders.id
              and line.status <> 'cancelled'
          )
        )
      )
      or (
        not private.mail_v2_template_allows_zero_lines(p_template_key)
        and exists(
          select 1
          from app.order_lines line
          where line.order_id = orders.id
            and line.status <> 'cancelled'
        )
      )
    )
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'MAIL_EVENT_PACKAGE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'private.mail_v2_campaign_candidates(text,uuid,uuid[])'::regprocedure
  );
  needle := $needle$
    if candidate.participation_status <> 'active'
      or candidate.season_status <> 'open'
      or candidate.active_package_snapshot_id is null
      or not exists(
        select 1
        from app.order_lines line
        where line.order_id = candidate.order_id
          and line.status <> 'cancelled'
      )
    then
$needle$;
  replacement := $replacement$
    if candidate.participation_status <> 'active'
      or candidate.season_status <> 'open'
      or candidate.active_package_snapshot_id is null
      or (
        (
          private.mail_v2_template_allows_zero_lines(p_template_key)
          and not exists(
            select 1
            from app.member_orders active_order
            where active_order.id = candidate.order_id
              and (
                (
                  active_order.package_assignment_state = 'active'
                  and active_order.package_revision_id is not null
                )
                or exists(
                  select 1
                  from app.order_lines line
                  where line.order_id = active_order.id
                    and line.status <> 'cancelled'
                )
              )
          )
        )
        or (
          not private.mail_v2_template_allows_zero_lines(p_template_key)
          and not exists(
            select 1
            from app.order_lines line
            where line.order_id = candidate.order_id
              and line.status <> 'cancelled'
          )
        )
      )
    then
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'MAIL_CAMPAIGN_PACKAGE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);

  function_source := pg_get_functiondef(
    'app.get_mail_v2_campaign_workspace_v1()'::regprocedure
  );
  needle := $needle$
        where orders.active_package_snapshot_id is not null
          and exists(
            select 1
            from app.order_lines line
            where line.order_id = orders.id
              and line.status <> 'cancelled'
          )
$needle$;
  replacement := $replacement$
        where orders.active_package_snapshot_id is not null
          and (
            (
              orders.package_assignment_state = 'active'
              and orders.package_revision_id is not null
            )
            or exists(
              select 1
              from app.order_lines line
              where line.order_id = orders.id
                and line.status <> 'cancelled'
            )
          )
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'MAIL_CAMPAIGN_WORKSPACE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

-- Preserve the existing state machine for logistics mail. Commercial package
-- events get an equivalent package-snapshot state proof without a line gate.
alter function private.mail_v2_event_state(uuid)
rename to mail_v2_event_state_v4;

create or replace function private.mail_v2_event_state(
  p_event_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  size_segment text;
  payment_state text;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found
    or not private.mail_v2_template_allows_zero_lines(target.template_key)
  then
    return private.mail_v2_event_state_v4(p_event_id);
  end if;
  if exists(
    select 1
    from private.mail_v2_event_suppressions suppression
    where suppression.event_id = target.id
  ) then
    return 'terminal';
  end if;
  if exists(
    select 1
    from app.order_lines line
    where line.order_id = target.order_id
      and line.status <> 'cancelled'
  ) and not private.mail_v2_active_package_order(
    target.order_id,
    target.member_season_id,
    target.season_id
  ) then
    return private.mail_v2_event_state_v4(p_event_id);
  end if;
  if not private.mail_v2_active_package_order(
    target.order_id,
    target.member_season_id,
    target.season_id
  ) or not exists(
    select 1
    from private.parent_authorized_member_seasons(target.parent_account_id)
      authorized
    where authorized.member_season_id = target.member_season_id
  ) then
    return 'terminal';
  end if;

  -- Keep the established allocation-aware readiness proof once logistics
  -- lines exist. Only the pre-confirmation package state needs this no-line
  -- exception.
  if target.template_key = 'payment_received_waiting_stock'
    and exists(
      select 1
      from app.order_lines line
      where line.order_id = target.order_id
        and line.status <> 'cancelled'
    )
  then
    return private.mail_v2_event_state_v4(p_event_id);
  end if;

  if target.template_key in (
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder'
  ) then
    size_segment := private.mail_v2_size_segment(target.order_id);
    if target.template_key in ('size_fill_request', 'size_fill_reminder') then
      return case when size_segment = 'fill' then 'eligible' else 'terminal' end;
    end if;
    return case when size_segment = 'review' then 'eligible' else 'terminal' end;
  end if;

  if target.template_key = 'size_confirmed' then
    return case when exists(
      select 1
      from app.package_size_confirmations confirmation
      join app.member_orders orders on orders.id = confirmation.order_id
      where confirmation.id = target.source_id
        and confirmation.member_season_id = target.member_season_id
        and confirmation.package_snapshot_id =
          orders.active_package_snapshot_id
        and private.package_sizes_complete(
          orders.id,
          confirmation.package_snapshot_id
        )
    ) then 'eligible' else 'terminal' end;
  end if;

  payment_state := private.mail_v2_payment_state(target.order_id);
  if target.template_key in ('payment_request', 'payment_reminder') then
    return case
      when payment_state = 'review' then 'pending'
      when payment_state = 'paid' then 'terminal'
      else 'eligible'
    end;
  end if;
  return case
    when payment_state = 'paid' then 'eligible'
    when payment_state = 'review' then 'pending'
    else 'terminal'
  end;
end;
$$;

revoke all on function private.mail_v2_event_state_v4(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

-- A payment received before size confirmation still gets a useful package
-- overview instead of an empty logistics table.
alter function private.mail_v2_member_payload(
  text, uuid, uuid, uuid, uuid
) rename to mail_v2_member_payload_v3;

create or replace function private.mail_v2_member_payload(
  p_template_key text,
  p_parent_account_id uuid,
  p_member_season_id uuid,
  p_source_id uuid,
  p_order_line_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  payload jsonb;
  fallback_lines jsonb;
begin
  payload := private.mail_v2_member_payload_v3(
    p_template_key,
    p_parent_account_id,
    p_member_season_id,
    p_source_id,
    p_order_line_id
  );
  if p_template_key <> 'payment_received_waiting_stock'
    or jsonb_array_length(coalesce(payload->'lines', '[]'::jsonb)) > 0
  then
    return payload;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'product', item.product_name_snapshot,
    'size', coalesce(variant.size, 'Nog te kiezen'),
    'quantity', item.quantity,
    'status', case
      when size_profile.selection_status in ('confirmed', 'locked')
        then 'Maat bevestigd; wacht op voorraad'
      when size_profile.selection_status = 'imported_unconfirmed'
        then 'Maat nog controleren'
      when size_profile.selection_status = 'conflict'
        then 'Maat vraagt aandacht'
      else 'Maat nog invullen'
    end
  ) order by item.sort_order, item.id), '[]'::jsonb)
  into fallback_lines
  from app.member_orders orders
  join app.order_package_snapshot_items item
    on item.snapshot_id = orders.active_package_snapshot_id
  left join app.member_article_sizes size_profile
    on size_profile.member_season_id = orders.member_season_id
    and size_profile.article_id = item.article_id
  left join app.article_variants variant
    on variant.id = size_profile.article_variant_id
  where orders.id = nullif(payload->>'orderId', '')::uuid;
  return jsonb_set(payload, '{lines}', fallback_lines, true);
end;
$$;

revoke all on function private.mail_v2_member_payload_v3(
  text, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_member_payload(
  text, uuid, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

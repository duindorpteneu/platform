-- Close the remaining multi-season reporting and manual-payment correction
-- gaps. Read models only call a payment "paid" when its immutable order,
-- member-season and package snapshot still reconcile exactly.

create table private.payment_reconciliation_resolutions (
  payment_id uuid primary key
    references app.payments(id) on delete restrict,
  provider_event_id uuid not null unique
    references private.payment_events(id) on delete restrict,
  resolution_type text not null check (
    resolution_type = 'duplicate_refund_verified'
  ),
  resolved_at timestamptz not null default timezone('utc', now())
);

alter table private.payment_reconciliation_resolutions
enable row level security;
revoke all on table private.payment_reconciliation_resolutions
from public, anon, authenticated, service_role;

create or replace function private.order_payment_projection(
  p_order_id uuid
)
returns table(
  effective_status text,
  valid_payment_id uuid,
  paid_at timestamptz,
  conflict_count integer
)
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with target as (
    select
      orders.id,
      orders.member_season_id,
      orders.active_package_snapshot_id,
      orders.amount_due_cents,
      snapshot.currency
    from app.member_orders orders
    join app.order_package_snapshots snapshot
      on snapshot.id = orders.active_package_snapshot_id
      and snapshot.order_id = orders.id
    where orders.id = p_order_id
  ),
  payment_state as (
    select
      payment.id,
      payment.status::text status,
      payment.paid_at,
      payment.created_at,
      (
        payment.status = 'paid'
        and payment.reconciliation_issue is null
        and payment.member_season_id = target.member_season_id
        and payment.package_snapshot_id
          = target.active_package_snapshot_id
        and payment.amount_cents = target.amount_due_cents
        and payment.currency = target.currency
      ) valid_paid,
      (
        payment.status = 'duplicate_paid'
        or (
          payment.reconciliation_issue is not null
          and not exists(
            select 1
            from private.payment_reconciliation_resolutions resolution
            where resolution.payment_id = payment.id
          )
        )
      ) unresolved_conflict
    from target
    join app.payments payment on payment.order_id = target.id
  ),
  aggregate_state as (
    select
      count(*) filter (where valid_paid)::integer valid_paid_count,
      (
        array_agg(id order by id) filter (where valid_paid)
      )[1] valid_payment_id,
      max(paid_at) filter (where valid_paid) paid_at,
      (
        count(*) filter (where unresolved_conflict)
        + greatest(count(*) filter (where valid_paid) - 1, 0)
      )::integer conflict_count
    from payment_state
  ),
  latest_non_paid as (
    select state.status
    from payment_state state
    where not state.valid_paid
      and not state.unresolved_conflict
    order by case state.status
      when 'refunded' then 1
      when 'pending' then 2
      when 'open' then 3
      else 4
    end, state.created_at desc, state.id desc
    limit 1
  )
  select
    case
      when aggregate_state.conflict_count > 0
        then 'reconciliation_required'
      when aggregate_state.valid_paid_count = 1 then 'paid'
      else coalesce(latest_non_paid.status, 'open')
    end,
    case
      when aggregate_state.conflict_count = 0
        and aggregate_state.valid_paid_count = 1
        then aggregate_state.valid_payment_id
      else null
    end,
    case
      when aggregate_state.conflict_count = 0
        and aggregate_state.valid_paid_count = 1
        then aggregate_state.paid_at
      else null
    end,
    aggregate_state.conflict_count
  from aggregate_state
  left join latest_non_paid on true;
$$;

revoke all on function private.order_payment_projection(uuid)
from public, anon, authenticated, service_role;

create or replace function private.order_has_effective_paid_payment(
  p_order_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select projection.effective_status = 'paid'
  from private.order_payment_projection(p_order_id) projection;
$$;

revoke all on function private.order_has_effective_paid_payment(uuid)
from public, anon, authenticated, service_role;

create or replace function private.export_effective_payment_status(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select projection.effective_status
  from private.order_payment_projection(p_order_id) projection;
$$;

create or replace function private.order_effective_payment_status(
  p_order_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select case projection.effective_status
    when 'reconciliation_required' then 'open'
    else projection.effective_status
  end
  from private.order_payment_projection(p_order_id) projection;
$$;

revoke all on function private.export_effective_payment_status(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.order_effective_payment_status(uuid)
from public, anon, authenticated, service_role;

create or replace function private.member_size_revision_v2(
  p_member_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws(
    '|',
    'member-sizes-v2',
    member_season.id::text,
    member_season.member_id::text,
    member_season.season_id::text,
    member_season.participation_status::text,
    member_season.reconciliation_status::text,
    coalesce(member_season.team_name, ''),
    season.status::text,
    coalesce((
      select string_agg(
        link.article_id::text || ':' || article.active::text,
        ',' order by link.article_id
      )
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      where link.season_id = member_season.season_id
    ), ''),
    coalesce((
      select string_agg(
        variant.id::text || ':' || variant.article_id::text || ':'
          || variant.size || ':' || variant.active::text,
        ',' order by variant.id
      )
      from app.article_variants variant
      where exists(
        select 1
        from app.article_seasons link
        where link.season_id = member_season.season_id
          and link.article_id = variant.article_id
      )
    ), ''),
    coalesce((
      select string_agg(
        size.article_id::text || ':' || size.article_variant_id::text,
        ',' order by size.article_id
      )
      from app.member_article_sizes size
      where size.member_season_id = member_season.id
    ), ''),
    coalesce((
      select string_agg(
        line.id::text || ':' || line.article_id::text || ':'
          || line.article_variant_id::text || ':' || line.status::text || ':'
          || line.product_name_snapshot || ':' || line.size_snapshot,
        ',' order by line.id
      )
      from app.member_orders orders
      join app.order_lines line
        on line.order_id = orders.id
        and line.status <> 'cancelled'
      where orders.member_season_id = member_season.id
    ), '')
  ), 'sha256'), 'hex')
  from app.member_seasons member_season
  join app.seasons season on season.id = member_season.season_id
  where member_season.id = p_member_season_id;
$$;

create or replace function private.member_size_revision(
  p_member_id uuid,
  p_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select private.member_size_revision_v2(member_season.id)
  from app.member_seasons member_season
  where member_season.member_id = p_member_id
    and member_season.season_id = p_season_id;
$$;

revoke all on function private.member_size_revision_v2(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.member_size_revision(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.member_saved_view_filter_shape_valid(
  p_filters jsonb
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    jsonb_typeof(p_filters) = 'object'
    and not exists(
      select 1
      from jsonb_object_keys(
        case
          when jsonb_typeof(p_filters) = 'object' then p_filters
          else '{}'::jsonb
        end
      ) filter_key
      where filter_key not in (
        'team',
        'payment',
        'orderStatus',
        'articleId',
        'size',
        'lineStatus'
      )
    )
    and (
      not (p_filters ? 'team')
      or (
        jsonb_typeof(p_filters->'team') = 'string'
        and p_filters->>'team' = btrim(p_filters->>'team')
        and length(p_filters->>'team') between 1 and 120
      )
    )
    and (
      not (p_filters ? 'payment')
      or (
        jsonb_typeof(p_filters->'payment') = 'string'
        and p_filters->>'payment' in (
          'paid',
          'unpaid',
          'review',
          'no_order'
        )
      )
    )
    and (
      not (p_filters ? 'orderStatus')
      or (
        jsonb_typeof(p_filters->'orderStatus') = 'string'
        and p_filters->>'orderStatus' in (
          'Nog niet betaald',
          'Nalevering',
          'Gedeeltelijk af te halen',
          'Volledig af te halen',
          'Gedeeltelijk afgehaald',
          'Afgerond'
        )
      )
    )
    and (
      not (p_filters ? 'articleId')
      or (
        jsonb_typeof(p_filters->'articleId') = 'string'
        and p_filters->>'articleId' ~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      )
    )
    and (
      not (p_filters ? 'size')
      or (
        jsonb_typeof(p_filters->'size') = 'string'
        and p_filters->>'size' = btrim(p_filters->>'size')
        and length(p_filters->>'size') between 1 and 80
      )
    )
    and (
      not (p_filters ? 'lineStatus')
      or (
        jsonb_typeof(p_filters->'lineStatus') = 'string'
        and p_filters->>'lineStatus' in (
          'backorder',
          'ready_for_pickup',
          'picked_up',
          'cancelled'
        )
      )
    );
$$;

revoke all on function private.member_saved_view_filter_shape_valid(jsonb)
from public, anon, authenticated, service_role;

create or replace function app.get_member_list(
  p_search text default null,
  p_team text default null,
  p_payment_filter text default null,
  p_order_status text default null,
  p_article_id uuid default null,
  p_size text default null,
  p_line_status app.order_line_status default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  active_season_id uuid;
  active_season_name text;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'INVALID_MEMBER_LIST_PAGE' using errcode = '22023';
  end if;
  if length(coalesce(p_search, '')) > 120
    or length(coalesce(p_team, '')) > 120
    or length(coalesce(p_size, '')) > 80
  then
    raise exception 'INVALID_MEMBER_LIST_FILTER' using errcode = '22023';
  end if;
  if p_payment_filter is not null
    and p_payment_filter not in ('paid', 'unpaid', 'review', 'no_order')
  then
    raise exception 'INVALID_PAYMENT_FILTER' using errcode = '22023';
  end if;
  if p_order_status is not null and p_order_status not in (
    'Nog niet betaald', 'Nalevering', 'Gedeeltelijk af te halen',
    'Volledig af te halen', 'Gedeeltelijk afgehaald', 'Afgerond'
  ) then
    raise exception 'INVALID_ORDER_STATUS_FILTER' using errcode = '22023';
  end if;

  select season.id, season.name
  into active_season_id, active_season_name
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id
  where settings.id = true;

  return (
    with base as (
      select
        member.id,
        member.relation_number,
        member.first_name,
        member.insertion,
        member.last_name,
        member_season.id member_season_id,
        member_season.team_name,
        member_season.participation_status,
        member_season.reconciliation_status,
        greatest(member.updated_at, member_season.updated_at) member_updated_at,
        orders.id order_id,
        orders.amount_due_cents,
        orders.order_status,
        orders.updated_at order_updated_at,
        projection.effective_status payment_state,
        coalesce(sum(line.quantity) filter (
          where line.status in ('ready_for_pickup', 'picked_up')
        ), 0)::integer progress_quantity,
        coalesce(sum(line.quantity) filter (
          where line.status <> 'cancelled'
        ), 0)::integer total_quantity
      from app.member_seasons member_season
      join app.members member on member.id = member_season.member_id
      left join app.member_orders orders
        on orders.member_season_id = member_season.id
        and orders.season_id = member_season.season_id
      left join app.order_lines line on line.order_id = orders.id
      left join lateral private.order_payment_projection(orders.id)
        projection on orders.id is not null
      where member_season.season_id = active_season_id
        and (
          nullif(trim(p_search), '') is null
          or concat_ws(
            ' ',
            member.first_name,
            member.insertion,
            member.last_name
          ) ilike '%' || trim(p_search) || '%'
          or coalesce(member_season.team_name, '')
            ilike '%' || trim(p_search) || '%'
          or coalesce(member.relation_number, '')
            ilike '%' || trim(p_search) || '%'
        )
        and (
          nullif(trim(p_team), '') is null
          or member_season.team_name = trim(p_team)
        )
        and (
          p_payment_filter is null
          or (
            p_payment_filter = 'paid'
            and orders.id is not null
            and projection.effective_status = 'paid'
          )
          or (
            p_payment_filter = 'unpaid'
            and orders.id is not null
            and projection.effective_status
              not in ('paid', 'reconciliation_required')
          )
          or (
            p_payment_filter = 'review'
            and orders.id is not null
            and projection.effective_status = 'reconciliation_required'
          )
          or (p_payment_filter = 'no_order' and orders.id is null)
        )
        and (p_order_status is null or orders.order_status = p_order_status)
        and (
          p_article_id is null
          or exists(
            select 1
            from app.order_lines filter_line
            join app.article_variants filter_variant
              on filter_variant.id = filter_line.article_variant_id
            where filter_line.order_id = orders.id
              and filter_variant.article_id = p_article_id
          )
        )
        and (
          nullif(trim(p_size), '') is null
          or exists(
            select 1
            from app.order_lines filter_line
            join app.article_variants filter_variant
              on filter_variant.id = filter_line.article_variant_id
            where filter_line.order_id = orders.id
              and filter_variant.size = trim(p_size)
          )
        )
        and (
          p_line_status is null
          or exists(
            select 1
            from app.order_lines filter_line
            where filter_line.order_id = orders.id
              and filter_line.status = p_line_status
          )
        )
      group by
        member.id,
        member_season.id,
        orders.id,
        projection.effective_status
    ),
    page as (
      select *
      from base
      order by
        (participation_status = 'active') desc,
        greatest(
          member_updated_at,
          coalesce(order_updated_at, member_updated_at)
        ) desc,
        lower(last_name),
        lower(first_name),
        relation_number
      limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'activeSeason', case
        when active_season_id is null then null
        else jsonb_build_object(
          'id', active_season_id,
          'name', active_season_name
        )
      end,
      'totalCount', (
        select count(*)::integer
        from app.member_seasons
        where season_id = active_season_id
      ),
      'activeCount', (
        select count(*)::integer
        from app.member_seasons
        where season_id = active_season_id
          and participation_status = 'active'
      ),
      'filteredCount', (select count(*)::integer from base),
      'filterOptions', jsonb_build_object(
        'teams', coalesce((
          select jsonb_agg(team order by lower(team))
          from (
            select distinct team_name team
            from app.member_seasons
            where season_id = active_season_id
              and team_name is not null
          ) teams
        ), '[]'::jsonb),
        'articles', coalesce((
          select jsonb_agg(
            jsonb_build_object('id', article.id, 'name', article.name)
            order by article.sort_order, lower(article.name)
          )
          from app.article_seasons link
          join app.articles article on article.id = link.article_id
          where link.season_id = active_season_id
            and article.active
        ), '[]'::jsonb),
        'sizes', coalesce((
          select jsonb_agg(size order by lower(size))
          from (
            select distinct variant.size
            from app.article_seasons link
            join app.article_variants variant
              on variant.article_id = link.article_id
            where link.season_id = active_season_id
              and variant.active
          ) sizes
        ), '[]'::jsonb)
      ),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', id,
          'memberSeasonId', member_season_id,
          'memberName', concat_ws(
            ' ',
            first_name,
            insertion,
            last_name
          ),
          'relationNumber', relation_number,
          'team', coalesce(team_name, 'Onbekend team'),
          'activeForSeason', participation_status = 'active',
          'updatedAt', greatest(
            member_updated_at,
            coalesce(order_updated_at, member_updated_at)
          ),
          'order', case
            when order_id is null then null
            else jsonb_build_object(
              'id', order_id,
              'amountDueCents', amount_due_cents,
              'paymentStatus', case payment_state
                when 'paid' then 'Betaald'
                when 'reconciliation_required' then 'Controle vereist'
                else 'Nog te betalen'
              end,
              'orderStatus', order_status,
              'progressQuantity', progress_quantity,
              'totalQuantity', total_quantity
            )
          end,
          'bulkEligibility', jsonb_build_object(
            'portalAccessPreflight',
              reconciliation_status = 'resolved',
            'mailPreflight',
              reconciliation_status = 'resolved',
            'teamStatusPreflight',
              reconciliation_status = 'resolved'
              and team_name is not null
          )
        ) order by
          (participation_status = 'active') desc,
          greatest(
            member_updated_at,
            coalesce(order_updated_at, member_updated_at)
          ) desc,
          lower(last_name),
          lower(first_name),
          relation_number)
        from page
      ), '[]'::jsonb)
    )
  );
end;
$$;

revoke all on function app.get_member_list(
  text, text, text, text, uuid, text, app.order_line_status, integer, integer
) from public, anon;
grant execute on function app.get_member_list(
  text, text, text, text, uuid, text, app.order_line_status, integer, integer
) to authenticated;

create or replace function private.member_size_profile_json_v2(
  p_member_season_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
  target_season_name text;
  target_season_status app.season_status;
  target_member_season app.member_seasons%rowtype;
begin
  select member_season.*
  into target_member_season
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select season.id, season.name, season.status
  into target_season_id, target_season_name, target_season_status
  from app.seasons season
  where season.id = target_member_season.season_id;

  return jsonb_build_object(
    'seasonId', target_season_id,
    'seasonName', target_season_name,
    'editable',
      target_member_season.participation_status = 'active'
      and target_member_season.reconciliation_status = 'resolved'
      and target_season_status = 'open',
    'revision',
      private.member_size_revision_v2(target_member_season.id),
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', article.id,
        'name', article.name,
        'code', article.code,
        'active', article.active,
        'selectedVariantId',
          coalesce(order_line.article_variant_id, size.article_variant_id),
        'ordered', order_line.id is not null,
        'orderLineStatus', order_line.status,
        'variants', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', variant.id,
            'size', variant.size,
            'active', variant.active
          ) order by variant.sort_order, lower(variant.size), variant.id)
          from app.article_variants variant
          where variant.article_id = article.id
            and (
              variant.active
              or variant.id = coalesce(
                order_line.article_variant_id,
                size.article_variant_id
              )
            )
        ), '[]'::jsonb)
      ) order by article.sort_order, lower(article.name), article.id)
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      left join app.member_article_sizes size
        on size.member_season_id = target_member_season.id
        and size.article_id = article.id
      left join lateral (
        select line.id, line.article_variant_id, line.status
        from app.member_orders orders
        join app.order_lines line on line.order_id = orders.id
        where orders.member_season_id = target_member_season.id
          and line.article_id = article.id
          and line.status <> 'cancelled'
        order by line.created_at desc, line.id desc
        limit 1
      ) order_line on true
      where link.season_id = target_season_id
        and (
          article.active
          or size.article_id is not null
          or order_line.id is not null
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function private.member_size_profile_json(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_season_id uuid;
begin
  select member_season.id into target_member_season_id
  from app.app_settings settings
  join app.member_seasons member_season
    on member_season.season_id = settings.active_season_id
    and member_season.member_id = p_member_id
  where settings.id = true;
  if target_member_season_id is null then
    if not exists(
      select 1 from app.members member where member.id = p_member_id
    ) then
      raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
    end if;
    return null;
  end if;
  return private.member_size_profile_json_v2(target_member_season_id);
end;
$$;

revoke all on function private.member_size_profile_json_v2(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.member_size_profile_json(uuid)
from public, anon, authenticated, service_role;

create or replace function app.get_member_detail_v3(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  target_role app.staff_role;
  target_member app.members%rowtype;
  target_member_season app.member_seasons%rowtype;
  target_order app.member_orders%rowtype;
  active_season_id uuid;
  active_season_name text;
  qr_status text;
begin
  perform private.require_clothing_aal2();
  target_role := app.staff_role();
  if p_member_id is null then
    raise exception 'INVALID_MEMBER_ID' using errcode = '22023';
  end if;

  select member.* into target_member
  from app.members member
  where member.id = p_member_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select season.id, season.name
  into active_season_id, active_season_name
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id
  where settings.id = true;

  select member_season.* into target_member_season
  from app.member_seasons member_season
  where member_season.member_id = p_member_id
    and member_season.season_id = active_season_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select orders.* into target_order
  from app.member_orders orders
  where orders.member_season_id = target_member_season.id;

  if target_order.id is not null then
    qr_status := case
      when private.order_qr_usable(target_order.id) then 'Actief'
      when exists(
        select 1
        from private.qr_order_identities identity
        where identity.order_id = target_order.id
      ) or exists(
        select 1
        from private.qr_tokens token
        where token.order_id = target_order.id
      ) then 'Ingetrokken'
      else 'Niet aangemaakt'
    end;
  end if;

  result := jsonb_build_object(
    'id', target_member.id,
    'memberName', concat_ws(
      ' ',
      target_member.first_name,
      target_member.insertion,
      target_member.last_name
    ),
    'firstName', target_member.first_name,
    'insertion', target_member.insertion,
    'lastName', target_member.last_name,
    'relationNumber', target_member.relation_number,
    'email', target_member.email,
    'team', coalesce(target_member_season.team_name, 'Onbekend team'),
    'activeForSeason',
      target_member_season.participation_status = 'active',
    'gender', target_member.gender::text,
    'dateOfBirth', case
      when target_role = 'beheerder' then (
        select identity.date_of_birth
        from private.member_sensitive_identity identity
        where identity.member_id = target_member.id
      )
      else null
    end,
    'updatedAt', greatest(
      target_member.updated_at,
      target_member_season.updated_at
    ),
    'activeSeason', jsonb_build_object(
      'id', active_season_id,
      'name', active_season_name
    ),
    'memberSeasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', member_season.id,
        'seasonId', member_season.season_id,
        'seasonName', season.name,
        'team', member_season.team_name,
        'participationStatus', member_season.participation_status::text,
        'reconciliationStatus',
          member_season.reconciliation_status::text
      ) order by season.starts_on desc nulls last, season.name desc)
      from app.member_seasons member_season
      join app.seasons season on season.id = member_season.season_id
      where member_season.member_id = target_member.id
    ), '[]'::jsonb),
    'sizeProfile',
      private.member_size_profile_json_v2(target_member_season.id),
    'parentLinks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', grant_row.id,
        'email', grant_row.email_normalized,
        'linkedAt', grant_row.granted_at
      ) order by lower(grant_row.email_normalized))
      from private.parent_portal_grants grant_row
      where grant_row.member_season_id = target_member_season.id
        and grant_row.status = 'active'
    ), '[]'::jsonb),
    'order', case
      when target_order.id is null then null
      else jsonb_build_object(
        'id', target_order.id,
        'amountDueCents', target_order.amount_due_cents,
        'orderStatus', target_order.order_status,
        'paymentStatus',
          case private.export_effective_payment_status(target_order.id)
            when 'paid' then 'Betaald'
            when 'reconciliation_required' then 'Controle vereist'
            else 'Nog te betalen'
          end,
        'paidAt', (
          select projection.paid_at
          from private.order_payment_projection(target_order.id) projection
        ),
        'qrStatus', qr_status,
        'lines', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', line.id,
            'article', line.product_name_snapshot,
            'size', line.size_snapshot,
            'quantity', line.quantity,
            'status', line.status::text
          ) order by line.created_at, line.id)
          from app.order_lines line
          where line.order_id = target_order.id
        ), '[]'::jsonb)
      )
    end,
    'activities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', activity.id,
        'action', activity.action,
        'entityType', activity.entity_type,
        'createdAt', activity.created_at
      ) order by activity.created_at desc, activity.id desc)
      from (
        select audit.id, audit.action, audit.entity_type, audit.created_at
        from app.audit_logs audit
        where audit.action <> 'qr.lookup'
          and (
            (
              audit.entity_id = target_member.id
              and audit.metadata->>'seasonId' = active_season_id::text
            )
            or (
              target_order.id is not null
              and audit.entity_id = target_order.id
            )
          )
        order by audit.created_at desc, audit.id desc
        limit 10
      ) activity
    ), '[]'::jsonb)
  );
  return result;
end;
$$;

revoke all on function app.get_member_detail_v3(uuid)
from public, anon;
grant execute on function app.get_member_detail_v3(uuid)
to authenticated;

create or replace function app.get_payment_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  active_season_id uuid;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  select settings.active_season_id into active_season_id
  from app.app_settings settings
  where settings.id = true;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'open', (
        select count(*) from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
          and payment.status = 'open'
      ),
      'pending', (
        select count(*) from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
          and payment.status = 'pending'
      ),
      'paid', (
        select count(*) from app.member_orders orders
        where orders.season_id = active_season_id
          and private.order_has_effective_paid_payment(orders.id)
      ),
      'duplicatePaid', (
        select count(*) from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
          and payment.status = 'duplicate_paid'
      ),
      'refunded', (
        select count(*) from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
          and payment.status = 'refunded'
      ),
      'review', (
        select count(*) from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
          and payment.reconciliation_issue is not null
      )
    ),
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'paymentId', attempt.id,
        'orderId', attempt.order_id,
        'memberName', concat_ws(
          ' ',
          member.first_name,
          member.insertion,
          member.last_name
        ),
        'relationNumber', member.relation_number,
        'team', coalesce(member_season.team_name, 'Onbekend team'),
        'method', attempt.method::text,
        'status', case
          when attempt.status = 'paid'
            and not private.order_has_effective_paid_payment(attempt.order_id)
            then 'open'
          else attempt.status::text
        end,
        'amountCents', attempt.amount_cents,
        'currency', attempt.currency,
        'providerPaymentId', attempt.provider_payment_id,
        'reconciliationIssue', attempt.reconciliation_issue,
        'createdAt', attempt.created_at,
        'reconciledAt', attempt.reconciled_at
      ) order by attempt.created_at desc, attempt.id desc)
      from (
        select payment.*
        from app.payments payment
        join app.member_orders orders on orders.id = payment.order_id
        where orders.season_id = active_season_id
        order by payment.created_at desc, payment.id desc
        limit 100
      ) attempt
      join app.member_orders orders on orders.id = attempt.order_id
      join app.member_seasons member_season
        on member_season.id = orders.member_season_id
      join app.members member on member.id = member_season.member_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_payment_workspace() from public, anon;
grant execute on function app.get_payment_workspace() to authenticated;

alter function private.build_export_rows(text, uuid, text)
rename to build_export_rows_before_season_hardening;

create or replace function private.build_export_rows(
  p_type text,
  p_season_id uuid,
  p_filter text
)
returns table(row_data jsonb)
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  if p_type = 'members' then
    return query
    select jsonb_build_object(
      'relationNumber', member.relation_number,
      'name', concat_ws(
        ' ',
        member.first_name,
        member.insertion,
        member.last_name
      ),
      'team', coalesce(member_season.team_name, 'Onbekend team'),
      'email', member.email,
      'active', member_season.participation_status = 'active',
      'parentLinked', exists(
        select 1
        from private.parent_portal_grants grant_row
        where grant_row.member_season_id = member_season.id
          and grant_row.status = 'active'
      )
    )
    from app.member_seasons member_season
    join app.members member on member.id = member_season.member_id
    where member_season.season_id = p_season_id
      and (
        p_filter = 'all'
        or (
          p_filter = 'active'
          and member_season.participation_status = 'active'
        )
        or (
          p_filter = 'inactive'
          and member_season.participation_status <> 'active'
        )
        or (
          p_filter = 'linked'
          and exists(
            select 1
            from private.parent_portal_grants grant_row
            where grant_row.member_season_id = member_season.id
              and grant_row.status = 'active'
          )
        )
        or (
          p_filter = 'unlinked'
          and not exists(
            select 1
            from private.parent_portal_grants grant_row
            where grant_row.member_season_id = member_season.id
              and grant_row.status = 'active'
          )
        )
      )
    order by member.relation_number, member_season.id;

  elsif p_type in ('orders', 'package_orders', 'outstanding')
    and p_filter in ('unpaid', 'review')
  then
    return query
    select prior.row_data
    from private.build_export_rows_before_season_hardening(
      p_type,
      p_season_id,
      'all'
    ) prior
    where (
      p_filter = 'review'
      and prior.row_data->>'paymentStatus'
        = 'reconciliation_required'
    ) or (
      p_filter = 'unpaid'
      and prior.row_data->>'paymentStatus'
        not in ('paid', 'reconciliation_required')
    );

  elsif p_type = 'deliveries' then
    return query
    select prior.row_data
    from private.build_export_rows_before_season_hardening(
      p_type,
      p_season_id,
      p_filter
    ) prior
    union all
    select jsonb_build_object(
      'delivery', coalesce(
        receipt.packing_slip_reference,
        receipt.id::text
      ),
      'date', coalesce(
        draft.received_on,
        receipt.received_on
      )::text,
      'variant', draft_line.product_name_snapshot
        || ' — ' || draft_line.size_snapshot,
      'received', receipt_line.received_quantity,
      'reserved', greatest(stock.reserved, 0),
      'available', greatest(stock.available, 0)
    )
    from app.inventory_delivery_drafts draft
    join app.inventory_delivery_draft_lines draft_line
      on draft_line.draft_id = draft.id
      and draft_line.quantity > 0
    join app.delivery_receipts receipt
      on receipt.id = draft.posted_receipt_id
    join app.delivery_receipt_lines receipt_line
      on receipt_line.receipt_id = receipt.id
      and receipt_line.article_variant_id
        = draft_line.article_variant_id
    cross join lateral private.inventory_balance(
      draft.season_id,
      draft_line.article_variant_id
    ) stock
    where draft.status = 'posted'
      and draft.season_id = p_season_id
      and not exists(
        select 1
        from app.inventory_reservations reservation
        join app.order_lines line on line.id = reservation.order_line_id
        join app.member_orders orders on orders.id = line.order_id
        where reservation.receipt_line_id = receipt_line.id
          and orders.season_id = p_season_id
      )
      and (
        p_filter = 'all'
        or (p_filter = 'available' and stock.available > 0)
        or (p_filter = 'fully_allocated' and stock.available <= 0)
      )
    order by
      1;
  else
    return query
    select prior.row_data
    from private.build_export_rows_before_season_hardening(
      p_type,
      p_season_id,
      p_filter
    ) prior;
  end if;
end;
$$;

revoke all on function private.build_export_rows_before_season_hardening(
  text, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function private.build_export_rows(text, uuid, text)
from public, anon, authenticated, service_role;

alter function app.get_export_workspace()
rename to get_export_workspace_before_payment_review;

create or replace function app.get_export_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  result jsonb;
  review_option jsonb := jsonb_build_array(jsonb_build_object(
    'value',
    'review',
    'label',
    'Controle vereist'
  ));
begin
  result := app.get_export_workspace_before_payment_review();
  result := jsonb_set(
    result,
    '{filters,orders}',
    coalesce(result#>'{filters,orders}', '[]'::jsonb) || review_option,
    true
  );
  result := jsonb_set(
    result,
    '{filters,package_orders}',
    coalesce(result#>'{filters,package_orders}', '[]'::jsonb)
      || review_option,
    true
  );
  result := jsonb_set(
    result,
    '{filters,outstanding}',
    coalesce(result#>'{filters,outstanding}', '[]'::jsonb)
      || review_option,
    true
  );
  return result;
end;
$$;

revoke all on function app.get_export_workspace_before_payment_review()
from public, anon, authenticated, service_role;
revoke all on function app.get_export_workspace()
from public, anon;
grant execute on function app.get_export_workspace()
to authenticated;

alter function app.create_export(text, uuid, text)
rename to create_export_before_season_hardening;

create or replace function app.create_export(
  p_type text,
  p_season_id uuid,
  p_filter text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  safe_filter text := coalesce(nullif(btrim(p_filter), ''), 'all');
  allowed_filters text[];
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_type is null or p_type <> all(array[
    'members', 'orders', 'package_orders', 'package_items', 'payments',
    'deliveries', 'fulfilments', 'outstanding'
  ]) then
    raise exception 'INVALID_EXPORT_TYPE' using errcode = '22023';
  end if;
  allowed_filters := case p_type
    when 'members' then
      array['all', 'active', 'inactive', 'linked', 'unlinked']
    when 'orders' then
      array[
        'all', 'unpaid', 'review', 'paid', 'backorder',
        'ready_for_pickup', 'picked_up'
      ]
    when 'package_orders' then
      array[
        'all', 'unpaid', 'review', 'paid', 'size_missing', 'backorder',
        'ready_for_pickup', 'picked_up', 'legacy', 'template',
        'admin_change'
      ]
    when 'package_items' then
      array[
        'all', 'size_missing', 'backorder', 'ready_for_pickup',
        'picked_up', 'cancelled', 'issued'
      ]
    when 'payments' then
      array[
        'all', 'open', 'pending', 'paid', 'failed', 'canceled',
        'expired', 'refunded', 'duplicate_paid', 'mollie', 'cash', 'card'
      ]
    when 'deliveries' then
      array['all', 'available', 'fully_allocated']
    when 'fulfilments' then
      array['all', 'active', 'corrected', 'reversed']
    when 'outstanding' then
      array[
        'all', 'unpaid', 'review', 'backorder', 'ready_for_pickup'
      ]
  end;
  if not (safe_filter = any(allowed_filters)) then
    raise exception 'INVALID_EXPORT_FILTER' using errcode = '22023';
  end if;
  if p_season_id is null then
    raise exception 'EXPORT_SEASON_REQUIRED' using errcode = '22023';
  end if;
  return app.create_export_before_season_hardening(
    p_type,
    p_season_id,
    safe_filter
  );
end;
$$;

revoke all on function app.create_export_before_season_hardening(
  text, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function app.create_export(text, uuid, text)
from public, anon;
grant execute on function app.create_export(text, uuid, text)
to authenticated;

create or replace function private.record_verified_duplicate_refund_resolution()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  evidence_event_id uuid;
  resolution_inserted boolean := false;
begin
  if new.status = 'refunded'
    and old.status = 'duplicate_paid'
    and new.reconciliation_issue = 'duplicate payment refunded'
  then
    select event.id into evidence_event_id
    from private.payment_events event
    where event.payment_id = new.id
      and event.event_type = 'refunded'
      and event.provider_payload_redacted->>'status' = 'refunded'
      and (event.provider_payload_redacted->>'amount_cents')::integer
        = new.amount_cents
      and event.provider_payload_redacted->>'currency' = new.currency
    order by event.processed_at desc, event.id desc
    limit 1;
    if evidence_event_id is null then
      raise exception 'PAYMENT_REFUND_RESOLUTION_EVENT_REQUIRED'
        using errcode = '23514';
    end if;
    insert into private.payment_reconciliation_resolutions(
      payment_id,
      provider_event_id,
      resolution_type
    ) values (
      new.id,
      evidence_event_id,
      'duplicate_refund_verified'
    )
    on conflict (payment_id) do nothing
    returning true into resolution_inserted;
    if resolution_inserted then
      insert into app.audit_logs(
        actor_user_id,
        action,
        entity_type,
        entity_id,
        metadata
      ) values (
        null,
        'payment.duplicate_refund.verified',
        'payment',
        new.id,
        jsonb_build_object(
          'provider_event_id', evidence_event_id,
          'resolution_type', 'duplicate_refund_verified'
        )
      );
    end if;
  end if;
  return new;
end;
$$;

create constraint trigger payments_record_verified_duplicate_refund_resolution
after update on app.payments
deferrable initially deferred
for each row
execute function private.record_verified_duplicate_refund_resolution();

revoke all on function private.record_verified_duplicate_refund_resolution()
from public, anon, authenticated, service_role;

insert into private.payment_reconciliation_resolutions(
  payment_id,
  provider_event_id,
  resolution_type,
  resolved_at
)
select distinct on (payment.id)
  payment.id,
  event.id,
  'duplicate_refund_verified',
  event.processed_at
from app.payments payment
join private.payment_events event
  on event.payment_id = payment.id
  and event.event_type = 'refunded'
  and event.provider_payload_redacted->>'status' = 'refunded'
  and (event.provider_payload_redacted->>'amount_cents')::integer
    = payment.amount_cents
  and event.provider_payload_redacted->>'currency' = payment.currency
where payment.method = 'mollie'
  and payment.status = 'refunded'
  and payment.reconciliation_issue = 'duplicate payment refunded'
order by payment.id, event.processed_at desc, event.id desc
on conflict (payment_id) do nothing;

insert into app.audit_logs(
  actor_user_id,
  action,
  entity_type,
  entity_id,
  metadata,
  created_at
)
select
  null,
  'payment.duplicate_refund.verified',
  'payment',
  resolution.payment_id,
  jsonb_build_object(
    'provider_event_id', resolution.provider_event_id,
    'resolution_type', resolution.resolution_type,
    'historical_backfill', true
  ),
  resolution.resolved_at
from private.payment_reconciliation_resolutions resolution
where not exists(
  select 1
  from app.audit_logs audit
  where audit.action = 'payment.duplicate_refund.verified'
    and audit.entity_type = 'payment'
    and audit.entity_id = resolution.payment_id
    and audit.metadata->>'provider_event_id'
      = resolution.provider_event_id::text
);

alter function app.get_operational_health_v10(
  text, integer, text, integer
) rename to get_operational_health_v10_before_payment_resolution;

create or replace function app.get_operational_health_v10(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  result := app.get_operational_health_v10_before_payment_resolution(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  return jsonb_set(
    result,
    '{reconciliationIssues}',
    to_jsonb((
      select count(*)
      from app.payments payment
      where payment.reconciliation_issue is not null
        and not exists(
          select 1
          from private.payment_reconciliation_resolutions resolution
          where resolution.payment_id = payment.id
        )
    )),
    true
  );
end;
$$;

revoke all on function app.get_operational_health_v10_before_payment_resolution(
  text, integer, text, integer
) from public, anon, authenticated, service_role;
revoke all on function app.get_operational_health_v10(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v10(
  text, integer, text, integer
) to service_role;

create or replace function private.revoke_order_qr_v2(
  p_order_id uuid,
  p_actor_id uuid,
  p_reason text,
  p_suspend boolean default true
)
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  normalized_reason text;
  target_identity_id uuid;
  affected integer := 0;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_order_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'QR_REVOCATION_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('qr-order:' || p_order_id::text, 0)
  );
  select identity.id into target_identity_id
  from private.qr_order_identities identity
  where identity.order_id = p_order_id
  for update;
  if target_identity_id is null then
    return 0;
  end if;
  perform set_config('app.qr_internal', 'on', true);
  update private.qr_order_locators locator
  set active = false,
      revoked_at = timezone('utc', now()),
      revoked_by = p_actor_id,
      revocation_reason = normalized_reason
  where locator.identity_id = target_identity_id
    and locator.active;
  get diagnostics affected = row_count;
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = left(normalized_reason, 160)
  where grant_row.order_id = p_order_id
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  if p_suspend then
    update private.qr_order_identities identity
    set suspended_at = timezone('utc', now()),
        suspended_by = p_actor_id,
        suspension_reason = normalized_reason,
        updated_at = timezone('utc', now())
    where identity.id = target_identity_id;
  end if;
  perform set_config('app.qr_internal', 'off', true);
  return affected;
end;
$$;

revoke all on function private.revoke_order_qr_v2(
  uuid, uuid, text, boolean
) from public, anon, authenticated, service_role;

create table private.manual_payment_corrections (
  request_id uuid primary key,
  payment_id uuid not null unique
    references app.payments(id) on delete restrict,
  order_id uuid not null
    references app.member_orders(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  package_snapshot_id uuid not null
    references app.order_package_snapshots(id) on delete restrict,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  method app.payment_method not null check (method in ('cash', 'card')),
  amount_cents integer not null check (amount_cents > 0),
  currency text not null check (currency = 'EUR'),
  reason text not null check (
    reason = btrim(reason)
    and length(reason) between 4 and 500
  ),
  evidence_reference text not null check (
    evidence_reference = btrim(evidence_reference)
    and length(evidence_reference) between 4 and 160
  ),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'email', 'recipient', 'name', 'member_name', 'date_of_birth',
      'token', 'token_hash', 'qr_token', 'qr_hash', 'checkout_url'
    ]
  ),
  recorded_at timestamptz not null default timezone('utc', now())
);

alter table private.manual_payment_corrections enable row level security;
revoke all on table private.manual_payment_corrections
from public, anon, authenticated, service_role;

create or replace function private.reject_manual_payment_correction_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'MANUAL_PAYMENT_CORRECTION_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger manual_payment_corrections_immutable
before update or delete on private.manual_payment_corrections
for each row execute function private.reject_manual_payment_correction_mutation();

revoke all on function private.reject_manual_payment_correction_mutation()
from public, anon, authenticated, service_role;

create or replace function app.record_manual_payment_refund_v1(
  p_order_id uuid,
  p_payment_id uuid,
  p_amount_cents integer,
  p_reason text,
  p_evidence_reference text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target_payment app.payments%rowtype;
  target_order app.member_orders%rowtype;
  existing private.manual_payment_corrections%rowtype;
  normalized_reason text;
  normalized_evidence text;
  request_hash text;
  result jsonb;
  released_count integer;
  qr_revoked_count integer;
  qr_active_before boolean;
  refund_recorded_at timestamptz := timezone('utc', now());
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  normalized_evidence := regexp_replace(
    btrim(coalesce(p_evidence_reference, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_order_id is null
    or p_payment_id is null
    or p_request_id is null
    or p_amount_cents is null
    or p_amount_cents <= 0
    or length(normalized_reason) not between 4 and 500
    or length(normalized_evidence) not between 4 and 160
  then
    raise exception 'INVALID_MANUAL_PAYMENT_REFUND'
      using errcode = '22023';
  end if;

  request_hash := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'paymentId', p_payment_id,
      'orderId', p_order_id,
      'amountCents', p_amount_cents,
      'reason', normalized_reason,
      'evidenceReference', normalized_evidence
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    'manual-payment-refund:' || p_request_id::text,
    0
  ));

  select orders.* into target_order
  from app.member_orders orders
  where orders.id = p_order_id
  for update;
  if not found then
    raise exception 'MANUAL_PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select correction.* into existing
  from private.manual_payment_corrections correction
  where correction.request_id = p_request_id;
  if found then
    if existing.order_id <> p_order_id
      or existing.payment_id <> p_payment_id
      or existing.actor_user_id <> actor
      or existing.request_hash <> request_hash
    then
      raise exception 'MANUAL_PAYMENT_REFUND_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select payment.* into target_payment
  from app.payments payment
  where payment.id = p_payment_id
    and payment.order_id = target_order.id
  for update;
  if not found then
    raise exception 'MANUAL_PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_payment.method not in ('cash', 'card')
    or target_payment.manual_request_id is null
    or target_payment.status <> 'paid'
    or target_payment.reconciliation_issue is not null
  then
    raise exception 'MANUAL_PAYMENT_REFUND_NOT_ALLOWED'
      using errcode = '23514';
  end if;
  if target_payment.amount_cents <> p_amount_cents
    or target_order.amount_due_cents <> p_amount_cents
    or target_payment.currency <> 'EUR'
    or target_payment.package_snapshot_id
      <> target_order.active_package_snapshot_id
    or target_payment.member_season_id <> target_order.member_season_id
  then
    raise exception 'MANUAL_PAYMENT_REFUND_AMOUNT_MISMATCH'
      using errcode = '23514';
  end if;
  if exists(
    select 1
    from app.payments conflict
    where conflict.order_id = target_order.id
      and conflict.id <> target_payment.id
      and (
        conflict.status = 'duplicate_paid'
        or (
          conflict.reconciliation_issue is not null
          and not exists(
            select 1
            from private.payment_reconciliation_resolutions resolution
            where resolution.payment_id = conflict.id
          )
        )
      )
  ) then
    raise exception 'PAYMENT_RECONCILIATION_OPEN'
      using errcode = '23514';
  end if;

  qr_active_before := exists(
    select 1
    from private.qr_order_identities identity
    join private.qr_order_locators locator
      on locator.identity_id = identity.id
      and locator.active
    where identity.order_id = target_order.id
  ) or exists(
    select 1
    from private.qr_tokens token
    where token.order_id = target_order.id
      and token.active
  );
  released_count := private.release_order_inventory_allocations(
    target_order.id,
    normalized_reason,
    actor,
    'manual_payment_refund',
    p_request_id,
    p_correlation_id
  );
  qr_revoked_count := private.revoke_order_qr_v2(
    target_order.id,
    actor,
    'Handmatige betaling is extern terugbetaald',
    true
  );

  update app.payments
  set status = 'refunded',
      refunded_at = refund_recorded_at,
      reconciled_at = refund_recorded_at,
      reconciliation_issue = null
  where id = target_payment.id;

  perform app.refresh_order_status(target_order.id);

  result := jsonb_build_object(
    'requestId', p_request_id,
    'paymentId', target_payment.id,
    'orderId', target_order.id,
    'memberSeasonId', target_order.member_season_id,
    'seasonId', target_order.season_id,
    'packageSnapshotId', target_order.active_package_snapshot_id,
    'status', 'refunded',
    'method', target_payment.method::text,
    'amountCents', target_payment.amount_cents,
    'currency', 'EUR',
    'refundedAt', refund_recorded_at,
    'releasedAllocationCount', released_count,
    'qrRevoked', qr_active_before or qr_revoked_count > 0,
    'refundCreated', false,
    'refundExternallyConfirmed', true,
    'reused', false
  );

  insert into private.manual_payment_corrections(
    request_id,
    payment_id,
    order_id,
    member_season_id,
    package_snapshot_id,
    actor_user_id,
    method,
    amount_cents,
    currency,
    reason,
    evidence_reference,
    request_hash,
    result_snapshot
  ) values (
    p_request_id,
    target_payment.id,
    target_order.id,
    target_order.member_season_id,
    target_order.active_package_snapshot_id,
    actor,
    target_payment.method,
    target_payment.amount_cents,
    'EUR',
    normalized_reason,
    normalized_evidence,
    request_hash,
    result
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'payment.manual.refund_recorded',
    'payment',
    target_payment.id,
    jsonb_build_object(
      'order_id', target_order.id,
      'member_season_id', target_order.member_season_id,
      'package_snapshot_id', target_order.active_package_snapshot_id,
      'request_id', p_request_id,
      'method', target_payment.method::text,
      'amount_cents', target_payment.amount_cents,
      'currency', 'EUR',
      'reason_recorded', true,
      'reason_sha256', encode(extensions.digest(
        convert_to(normalized_reason, 'UTF8'),
        'sha256'
      ), 'hex'),
      'evidence_recorded', true,
      'evidence_sha256', encode(extensions.digest(
        convert_to(normalized_evidence, 'UTF8'),
        'sha256'
      ), 'hex'),
      'released_allocation_count', released_count,
      'qr_revoked', qr_active_before or qr_revoked_count > 0,
      'refund_created', false,
      'refund_externally_confirmed', true
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.record_manual_payment_refund_v1(
  uuid, uuid, integer, text, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.record_manual_payment_refund_v1(
  uuid, uuid, integer, text, text, uuid, uuid
) to authenticated;

notify pgrst, 'reload schema';

create or replace function app.get_staff_shell_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
begin
  if not app.is_staff_member() then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'activeSeason', (
      select jsonb_build_object('id', s.id, 'name', s.name)
      from app.app_settings settings
      join app.seasons s on s.id = settings.active_season_id
      where settings.id = true
      limit 1
    )
  );
end;
$$;

create or replace function app.get_backoffice_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  resolved_role app.staff_role;
  active_season_id uuid;
  active_season_name text;
begin
  resolved_role := app.staff_role();
  if resolved_role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select s.id, s.name into active_season_id, active_season_name
  from app.app_settings settings
  join app.seasons s on s.id = settings.active_season_id
  where settings.id = true
  limit 1;

  return jsonb_build_object(
    'activeSeason', case when active_season_id is null then null else jsonb_build_object('id', active_season_id, 'name', active_season_name) end,
    'generatedAt', now(),
    'metrics', jsonb_build_object(
      'totalMembers', (select count(*)::integer from app.members where active_for_season = true),
      'totalOrders', (select count(*)::integer from app.member_orders where season_id = active_season_id),
      'paidOrders', (
        select count(*)::integer from app.member_orders mo
        where mo.season_id = active_season_id
          and exists (select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid')
      ),
      'unpaidOrders', (
        select count(*)::integer from app.member_orders mo
        where mo.season_id = active_season_id
          and not exists (select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid')
      ),
      'partiallyReadyOrders', (select count(*)::integer from app.member_orders where season_id = active_season_id and order_status = 'Gedeeltelijk af te halen'),
      'fullyReadyOrders', (select count(*)::integer from app.member_orders where season_id = active_season_id and order_status = 'Volledig af te halen'),
      'backorderOrders', (
        select count(distinct mo.id)::integer
        from app.member_orders mo
        join app.order_lines ol on ol.order_id = mo.id
        where mo.season_id = active_season_id and ol.status = 'backorder'
      ),
      'readyOrders', (
        select count(distinct mo.id)::integer
        from app.member_orders mo
        join app.order_lines ol on ol.order_id = mo.id
        where mo.season_id = active_season_id and ol.status = 'ready_for_pickup'
      )
    ),
    'recentMembers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderId', recent.id,
        'memberName', concat_ws(' ', recent.first_name, recent.insertion, recent.last_name),
        'team', recent.team,
        'relationNumber', recent.relation_number,
        'paymentStatus', case when recent.paid then 'Betaald' else 'Nog te betalen' end,
        'orderStatus', recent.order_status,
        'progressQuantity', recent.progress_quantity,
        'totalQuantity', recent.total_quantity,
        'updatedAt', recent.updated_at
      ) order by recent.updated_at desc)
      from (
        select mo.id, mo.order_status, mo.updated_at, m.first_name, m.insertion, m.last_name, m.team, m.relation_number,
          exists(select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid') as paid,
          coalesce(sum(ol.quantity) filter (where ol.status in ('ready_for_pickup', 'picked_up')), 0)::integer as progress_quantity,
          coalesce(sum(ol.quantity) filter (where ol.status <> 'cancelled'), 0)::integer as total_quantity
        from app.member_orders mo
        join app.members m on m.id = mo.member_id
        left join app.order_lines ol on ol.order_id = mo.id
        where mo.season_id = active_season_id
        group by mo.id, m.id
        order by mo.updated_at desc
        limit 5
      ) recent
    ), '[]'::jsonb),
    'activities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', recent_activity.id,
        'action', recent_activity.action,
        'entityType', recent_activity.entity_type,
        'createdAt', recent_activity.created_at
      ) order by recent_activity.created_at desc, recent_activity.id desc)
      from (
        select id, action, entity_type, created_at
        from app.audit_logs
        where action <> 'qr.lookup'
        order by created_at desc, id desc
        limit 5
      ) recent_activity
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_staff_shell_context() from public, anon;
revoke all on function app.get_backoffice_dashboard() from public, anon;
grant execute on function app.get_staff_shell_context() to authenticated;
grant execute on function app.get_backoffice_dashboard() to authenticated;

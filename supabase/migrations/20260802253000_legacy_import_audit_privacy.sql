-- Legacy Sportlink RPCs authenticate before reporting the irreversible cutover.
-- Package-parent actor identifiers remain available to administrators, while
-- clothing-committee audit reads receive a redacted projection.

create or replace function app.get_sportlink_import_summary(p_members jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_clothing_aal2();
  raise exception 'LEGACY_IMPORT_DISABLED' using errcode = '55000';
end;
$$;

drop policy if exists "settings audit access" on app.audit_logs;
create policy "settings audit access" on app.audit_logs
for select using (
  app.staff_role() = 'beheerder'
  or (
    app.staff_role() = 'kledingcommissie'
    and app.audit_category(action) in (
      'members',
      'orders',
      'payments',
      'inventory',
      'fulfilment',
      'communications'
    )
    and action not in (
      'order.package_selection.requested',
      'order.package_size_change.withdrawn'
    )
  )
);

create or replace function app.get_audit_workspace_v2(
  p_category text default null,
  p_action text default null,
  p_actor_user_id uuid default null,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  viewer_role app.staff_role := app.staff_role();
  safe_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if viewer_role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_category is not null and p_category not in (
    'members',
    'orders',
    'payments',
    'inventory',
    'fulfilment',
    'communications',
    'settings',
    'security'
  ) then
    raise exception 'AUDIT_FILTER_INVALID' using errcode = '22023';
  end if;
  if p_action is not null and (
    length(p_action) > 100
    or p_action !~ '^[a-z][a-z0-9_.-]+$'
  ) then
    raise exception 'AUDIT_FILTER_INVALID' using errcode = '22023';
  end if;
  if viewer_role = 'kledingcommissie'
    and p_category in ('settings', 'security')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'viewerRole', viewer_role,
    'categories', case
      when viewer_role = 'beheerder' then jsonb_build_array(
        'members',
        'orders',
        'payments',
        'inventory',
        'fulfilment',
        'communications',
        'settings',
        'security'
      )
      else jsonb_build_array(
        'members',
        'orders',
        'payments',
        'inventory',
        'fulfilment',
        'communications'
      )
    end,
    'actors', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', profile.auth_user_id,
        'displayName', profile.display_name
      ) order by profile.display_name)
      from app.staff_profiles profile
    ), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(
        row_to_json(entry)::jsonb
        order by entry."createdAt" desc, entry.id desc
      )
      from (
        select
          audit.id::text as id,
          audit.action,
          app.audit_category(audit.action) as category,
          audit.entity_type as "entityType",
          audit.entity_id as "entityId",
          case
            when viewer_role = 'kledingcommissie'
              then audit.metadata - 'parentAccountId'
            else audit.metadata
          end as metadata,
          audit.correlation_id as "correlationId",
          audit.created_at as "createdAt",
          audit.actor_user_id as "actorUserId",
          coalesce(profile.display_name, 'Systeem') as "actorName"
        from app.audit_logs audit
        left join app.staff_profiles profile
          on profile.auth_user_id = audit.actor_user_id
        where (
          viewer_role = 'beheerder'
          or app.audit_category(audit.action) in (
            'members',
            'orders',
            'payments',
            'inventory',
            'fulfilment',
            'communications'
          )
        )
          and (
            p_category is null
            or app.audit_category(audit.action) = p_category
          )
          and (p_action is null or audit.action = p_action)
          and (
            p_actor_user_id is null
            or audit.actor_user_id = p_actor_user_id
          )
          and (p_before is null or audit.created_at < p_before)
        order by audit.created_at desc, audit.id desc
        limit safe_limit
      ) entry
    ), '[]'::jsonb),
    'limit', safe_limit
  );
end;
$$;

revoke execute on function app.get_audit_workspace(
  text, text, uuid, timestamptz, integer
) from authenticated;
revoke all on function app.get_audit_workspace_v2(
  text, text, uuid, timestamptz, integer
) from public, anon;
grant execute on function app.get_audit_workspace_v2(
  text, text, uuid, timestamptz, integer
) to authenticated;

notify pgrst, 'reload schema';

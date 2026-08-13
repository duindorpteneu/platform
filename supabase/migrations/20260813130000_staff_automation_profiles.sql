-- Keep non-personal release-acceptance actors in the immutable audit chain
-- without exposing them as manageable human staff accounts.

alter table app.staff_profiles
  add column automation_kind text;

alter table app.staff_profiles
  add constraint staff_profiles_automation_kind_check
  check (
    automation_kind is null
    or automation_kind = 'sendgrid_acceptance'
  );

create index staff_profiles_automation_kind_idx
  on app.staff_profiles(automation_kind)
  where automation_kind is not null;

comment on column app.staff_profiles.automation_kind is
'Null for human staff; allowlisted non-personal audit actor kind for release automation. Automation profiles never appear in the staff-management workspace.';

create or replace function private.guard_staff_automation_profile_v1()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if coalesce(
    current_setting('app.staff_automation_internal', true),
    ''
  ) = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if (
    tg_op = 'INSERT'
    and new.automation_kind is not null
  ) or (
    tg_op = 'UPDATE'
    and (
      old.automation_kind is not null
      or new.automation_kind is not null
    )
  ) or (
    tg_op = 'DELETE'
    and old.automation_kind is not null
  ) then
    raise exception 'STAFF_AUTOMATION_PROFILE_MANAGED_INTERNALLY'
      using errcode = '23514';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function private.guard_staff_automation_profile_v1()
from public, anon, authenticated, service_role;

create trigger staff_automation_profile_guard
before insert or update or delete on app.staff_profiles
for each row execute function private.guard_staff_automation_profile_v1();

drop policy if exists "admins manage profiles" on app.staff_profiles;
create policy "admins manage human profiles" on app.staff_profiles
for all
using (
  app.staff_role() = 'beheerder'
  and automation_kind is null
)
with check (
  app.staff_role() = 'beheerder'
  and automation_kind is null
);

-- Preserve the old implementation for backwards-compatible projection, but
-- remove every API privilege from its deliberately unfiltered raw result.
alter function app.get_settings_workspace_v2()
rename to settings_workspace_legacy_raw_20260813;

revoke all on function app.settings_workspace_legacy_raw_20260813()
from public, anon, authenticated, service_role;

create function app.get_settings_workspace_v2()
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb := app.settings_workspace_legacy_raw_20260813();
  visible_staff jsonb;
begin
  select coalesce(
    jsonb_agg(entry.value order by entry.ordinality),
    '[]'::jsonb
  )
  into visible_staff
  from jsonb_array_elements(workspace->'staff')
    with ordinality entry(value, ordinality)
  where not exists (
    select 1
    from app.staff_profiles profile
    where profile.auth_user_id = (entry.value->>'authUserId')::uuid
      and profile.automation_kind is not null
  );

  return jsonb_set(workspace, '{staff}', visible_staff, true);
end;
$$;

revoke all on function app.get_settings_workspace_v2()
from public, anon;
grant execute on function app.get_settings_workspace_v2()
to authenticated;

create or replace function app.get_settings_workspace_v3()
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb := app.get_settings_workspace_v2();
  projection jsonb := private.published_branding_projection_v1();
  visible_staff jsonb;
begin
  if projection is null then
    raise exception 'PUBLISHED_BRANDING_REQUIRED' using errcode = '23514';
  end if;

  select coalesce(
    jsonb_agg(entry.value order by entry.ordinality),
    '[]'::jsonb
  )
  into visible_staff
  from jsonb_array_elements(workspace->'staff')
    with ordinality entry(value, ordinality)
  where not exists (
    select 1
    from app.staff_profiles profile
    where profile.auth_user_id = (entry.value->>'authUserId')::uuid
      and profile.automation_kind is not null
  );

  workspace := jsonb_set(workspace, '{staff}', visible_staff, true);
  return jsonb_set(
    workspace,
    '{settings}',
    (workspace->'settings') || jsonb_build_object(
      'clubName', projection->>'clubName',
      'contactEmail', projection->>'contactEmail',
      'clubAddressLine', projection->>'clubAddressLine',
      'clubPostalCode', projection->>'clubPostalCode',
      'clubCity', projection->>'clubCity',
      'pickupAddressDiffers', true,
      'pickupName', projection->>'pickupName',
      'pickupAddressLine', projection->>'pickupAddressLine',
      'pickupPostalCode', projection->>'pickupPostalCode',
      'pickupCity', projection->>'pickupCity',
      'pickupLocation', projection->>'pickupLocation',
      'brandingRevisionId', projection->>'revisionId',
      'brandingRevision', (projection->>'revision')::integer,
      'brandingContentHash', projection->>'contentHash'
    ),
    true
  );
end;
$$;

revoke all on function app.get_settings_workspace_v3()
from public, anon;
grant execute on function app.get_settings_workspace_v3()
to authenticated;

create or replace function app.get_settings_workspace()
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
begin
  return app.get_settings_workspace_v3();
end;
$$;

revoke all on function app.get_settings_workspace()
from public, anon;
grant execute on function app.get_settings_workspace()
to authenticated;

notify pgrst, 'reload schema';

alter table app.seasons
  add constraint seasons_default_amount_upper
  check (default_amount_cents <= 10000000) not valid;
alter table app.seasons validate constraint seasons_default_amount_upper;

alter table app.seasons
  add constraint seasons_dates_order
  check (starts_on is null or ends_on is null or starts_on <= ends_on) not valid;
alter table app.seasons validate constraint seasons_dates_order;

create or replace function app.set_member_active_for_season(
  p_member_id uuid,
  p_active boolean,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target app.members%rowtype;
  target_season_id uuid;
  normalized_reason text := trim(p_reason);
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_member_id is null or p_active is null or length(normalized_reason) not between 3 and 240 then
    raise exception 'MEMBER_STATUS_INPUT_INVALID' using errcode = '22023';
  end if;
  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;
  select * into target from app.members where id = p_member_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;

  update app.members set active_for_season = p_active where id = p_member_id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, case when p_active then 'member.activated' else 'member.deactivated' end,
    'member', p_member_id, jsonb_build_object(
      'seasonId', target_season_id,
      'activeBefore', target.active_for_season,
      'activeAfter', p_active,
      'reason', normalized_reason
    ), p_correlation_id);
  return jsonb_build_object('memberId', p_member_id, 'activeForSeason', p_active);
end;
$$;

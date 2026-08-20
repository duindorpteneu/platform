-- Family-wide member email and parent portal identity transfer.
--
-- The authoritative family boundary is the set of active-season member
-- seasons authorized by one parent account. Member email equality is never an
-- authorization or grouping primitive. Historical grants are only revoked;
-- their identity snapshots are never rewritten.

create table private.parent_family_email_transfers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  selected_member_id uuid not null
    references app.members(id) on delete restrict,
  selected_member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  old_parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  new_parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  old_email_normalized text not null check (
    old_email_normalized = lower(trim(old_email_normalized))
  ),
  new_email_normalized text not null check (
    new_email_normalized = lower(trim(new_email_normalized))
  ),
  expected_family_revision text not null check (
    expected_family_revision ~ '^[0-9a-f]{64}$'
  ),
  affected_member_count integer not null check (affected_member_count > 0),
  affected_member_season_count integer not null check (
    affected_member_season_count > 0
  ),
  activation_batch_id uuid
    references private.parent_access_batches(id) on delete restrict,
  sessions_revoked integer not null default 0 check (sessions_revoked >= 0),
  otp_challenges_invalidated integer not null default 0 check (
    otp_challenges_invalidated >= 0
  ),
  old_authorized_member_season_count integer not null default 0 check (
    old_authorized_member_season_count >= 0
  ),
  activation_mail_queued boolean not null,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

create table private.parent_family_email_transfer_items (
  transfer_id uuid not null
    references private.parent_family_email_transfers(id) on delete restrict,
  member_id uuid not null references app.members(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  old_grant_id uuid not null
    references private.parent_portal_grants(id) on delete restrict,
  new_grant_id uuid not null
    references private.parent_portal_grants(id) on delete restrict,
  primary key (transfer_id, member_season_id)
);

create index parent_family_email_transfers_old_account_idx
  on private.parent_family_email_transfers(old_parent_account_id, created_at desc);
create index parent_family_email_transfers_new_account_idx
  on private.parent_family_email_transfers(new_parent_account_id, created_at desc);
create index parent_family_email_transfer_items_member_idx
  on private.parent_family_email_transfer_items(member_id, transfer_id);
create index parent_family_email_transfer_items_old_grant_idx
  on private.parent_family_email_transfer_items(old_grant_id);
create index parent_family_email_transfer_items_new_grant_idx
  on private.parent_family_email_transfer_items(new_grant_id);

alter table private.parent_family_email_transfers enable row level security;
alter table private.parent_family_email_transfer_items enable row level security;
revoke all on table private.parent_family_email_transfers
from public, anon, authenticated, service_role;
revoke all on table private.parent_family_email_transfer_items
from public, anon, authenticated, service_role;

create or replace function private.reject_parent_family_email_history_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'PARENT_FAMILY_EMAIL_HISTORY_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger parent_family_email_transfers_immutable
before update or delete on private.parent_family_email_transfers
for each row execute function private.reject_parent_family_email_history_mutation();
create trigger parent_family_email_transfer_items_immutable
before update or delete on private.parent_family_email_transfer_items
for each row execute function private.reject_parent_family_email_history_mutation();

revoke all on function private.reject_parent_family_email_history_mutation()
from public, anon, authenticated, service_role;

create or replace function private.current_parent_family_member_seasons(
  p_parent_account_id uuid
)
returns table (
  member_season_id uuid,
  member_id uuid,
  season_id uuid,
  grant_id uuid
)
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select
    member_season.id,
    member_season.member_id,
    member_season.season_id,
    grant_row.id
  from private.parent_authorized_member_seasons(p_parent_account_id) authorized
  join app.member_seasons member_season
    on member_season.id = authorized.member_season_id
  join app.app_settings settings
    on settings.id = true
    and settings.active_season_id = member_season.season_id
  join private.parent_accounts account
    on account.id = p_parent_account_id
  join lateral (
    select candidate.id
    from private.parent_portal_grants candidate
    where candidate.member_season_id = member_season.id
      and candidate.parent_account_id = p_parent_account_id
      and candidate.email_normalized = account.email_normalized
      and (
        candidate.status = 'active'
        or (
          not private.parent_access_v2_enabled()
          and candidate.status = 'review_required'
          and candidate.source = 'legacy_review'
        )
      )
    order by
      case when candidate.status = 'active' then 0 else 1 end,
      candidate.updated_at desc,
      candidate.id
    limit 1
  ) grant_row on true
  order by member_season.id;
$$;

revoke all on function private.current_parent_family_member_seasons(uuid)
from public, anon, authenticated, service_role;

create or replace function private.member_family_email_preview_v1(
  p_member_id uuid,
  p_member_season_id uuid,
  p_new_email text,
  p_expected_profile_revision text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  normalized_email text := lower(nullif(btrim(normalize(p_new_email, NFKC)), ''));
  selected_member app.members%rowtype;
  selected_member_season app.member_seasons%rowtype;
  old_account private.parent_accounts%rowtype;
  target_account_id uuid;
  affected_children jsonb;
  affected_member_count integer := 1;
  affected_member_season_count integer := 0;
  blocked_count integer := 0;
  family_state jsonb;
  family_revision text;
begin
  if p_member_id is null
    or p_member_season_id is null
    or normalized_email is null
    or not private.parent_access_email_valid(normalized_email)
    or p_expected_profile_revision !~ '^[0-9a-f]{64}$'
  then
    raise exception 'MEMBER_FAMILY_EMAIL_INPUT_INVALID' using errcode = '22023';
  end if;

  select member.* into selected_member
  from app.members member
  where member.id = p_member_id;
  select member_season.* into selected_member_season
  from app.member_seasons member_season
  join app.app_settings settings
    on settings.id = true
    and settings.active_season_id = member_season.season_id
  where member_season.id = p_member_season_id
    and member_season.member_id = p_member_id;
  if selected_member.id is null or selected_member_season.id is null then
    raise exception 'MEMBER_PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if private.member_profile_revision(p_member_id, p_member_season_id)
    <> p_expected_profile_revision
  then
    raise exception 'MEMBER_PROFILE_STALE' using errcode = '40001';
  end if;

  select account.* into old_account
  from private.parent_accounts account
  join private.current_parent_family_member_seasons(account.id) family
    on family.member_season_id = p_member_season_id
  order by account.id
  limit 1;

  if old_account.id is null then
    affected_children := jsonb_build_array(jsonb_build_object(
      'memberId', selected_member.id,
      'memberSeasonId', selected_member_season.id,
      'memberName', concat_ws(' ', selected_member.first_name,
        selected_member.insertion, selected_member.last_name),
      'team', coalesce(selected_member_season.team_name, 'Onbekend team')
    ));
    family_state := jsonb_build_object(
      'version', 'member-family-email-v1',
      'memberId', p_member_id,
      'memberSeasonId', p_member_season_id,
      'newEmail', normalized_email,
      'profileRevision', p_expected_profile_revision,
      'portalAccessActive', false
    );
    family_revision := encode(extensions.digest(
      convert_to(family_state::text, 'UTF8'), 'sha256'
    ), 'hex');
    return jsonb_build_object(
      'portalAccessActive', false,
      'transferRequired', false,
      'currentMemberEmail', selected_member.email,
      'currentPortalEmail', null,
      'newEmail', normalized_email,
      'affectedMemberCount', 1,
      'affectedMemberSeasonCount', 0,
      'activePortalCount', 0,
      'targetAccountReused', false,
      'blockedCount', 0,
      'affectedChildren', affected_children,
      'familyRevision', family_revision
    );
  end if;

  select account.id into target_account_id
  from private.parent_accounts account
  where account.email_normalized = normalized_email;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'memberId', family.member_id,
      'memberSeasonId', family.member_season_id,
      'memberName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'team', coalesce(member_season.team_name, 'Onbekend team')
    ) order by member.last_name, member.first_name, family.member_season_id), '[]'::jsonb),
    count(distinct family.member_id)::integer,
    count(*)::integer
  into affected_children, affected_member_count, affected_member_season_count
  from private.current_parent_family_member_seasons(old_account.id) family
  join app.members member on member.id = family.member_id
  join app.member_seasons member_season on member_season.id = family.member_season_id;

  select count(*)::integer into blocked_count
  from private.current_parent_family_member_seasons(old_account.id) family
  where exists(
    select 1
    from private.parent_portal_grants conflicting
    where conflicting.member_season_id = family.member_season_id
      and conflicting.status = 'active'
      and conflicting.parent_account_id <> old_account.id
      and conflicting.parent_account_id is distinct from target_account_id
  );

  select jsonb_build_object(
    'version', 'member-family-email-v1',
    'selectedMemberId', p_member_id,
    'selectedMemberSeasonId', p_member_season_id,
    'newEmail', normalized_email,
    'profileRevision', p_expected_profile_revision,
    'activeSeasonId', settings.active_season_id,
    'grantsV2', private.parent_access_v2_enabled(),
    'oldParentAccountId', old_account.id,
    'oldPortalEmail', old_account.email_normalized,
    'targetParentAccountId', target_account_id,
    'mailV2Cutover', private.mail_templates_v2_cutover_started(),
    'family', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', family.member_id,
        'memberSeasonId', family.member_season_id,
        'memberEmail', member.email,
        'memberUpdatedAt', member.updated_at,
        'memberSeasonUpdatedAt', member_season.updated_at,
        'grantId', family.grant_id,
        'grantStatus', grant_row.status,
        'grantEmail', grant_row.email_normalized,
        'grantUpdatedAt', grant_row.updated_at
      ) order by family.member_season_id)
      from private.current_parent_family_member_seasons(old_account.id) family
      join app.members member on member.id = family.member_id
      join app.member_seasons member_season on member_season.id = family.member_season_id
      join private.parent_portal_grants grant_row on grant_row.id = family.grant_id
    ), '[]'::jsonb)
  ) into family_state
  from app.app_settings settings
  where settings.id = true;
  family_revision := encode(extensions.digest(
    convert_to(family_state::text, 'UTF8'), 'sha256'
  ), 'hex');

  return jsonb_build_object(
    'portalAccessActive', true,
    'transferRequired', old_account.email_normalized <> normalized_email,
    'currentMemberEmail', selected_member.email,
    'currentPortalEmail', old_account.email_normalized,
    'newEmail', normalized_email,
    'affectedMemberCount', affected_member_count,
    'affectedMemberSeasonCount', affected_member_season_count,
    'activePortalCount', affected_member_season_count,
    'targetAccountReused', target_account_id is not null,
    'blockedCount', blocked_count + case
      when not private.mail_templates_v2_cutover_started()
        and old_account.email_normalized <> normalized_email then 1
      else 0 end,
    'affectedChildren', affected_children,
    'familyRevision', family_revision
  );
end;
$$;

revoke all on function private.member_family_email_preview_v1(
  uuid, uuid, text, text
) from public, anon, authenticated, service_role;

create or replace function app.preview_member_family_email_transfer_v1(
  p_member_id uuid,
  p_member_season_id uuid,
  p_new_email text,
  p_expected_profile_revision text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.member_family_email_preview_v1(
    p_member_id,
    p_member_season_id,
    p_new_email,
    p_expected_profile_revision
  );
end;
$$;

revoke all on function app.preview_member_family_email_transfer_v1(
  uuid, uuid, text, text
) from public, anon;
grant execute on function app.preview_member_family_email_transfer_v1(
  uuid, uuid, text, text
) to authenticated;

create or replace function private.member_portal_access_summary_v1(
  p_member_season_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with authorized_account as (
    select account.id, account.email_normalized
    from private.parent_accounts account
    join private.current_parent_family_member_seasons(account.id) family
      on family.member_season_id = p_member_season_id
    order by account.id
    limit 1
  )
  select case when exists(select 1 from authorized_account) then
    jsonb_build_object(
      'active', true,
      'parentAccountId', account.id,
      'loginEmail', account.email_normalized,
      'linkedChildrenCount', (
        select count(distinct family.member_id)::integer
        from private.current_parent_family_member_seasons(account.id) family
      )
    )
  else jsonb_build_object(
    'active', false,
    'parentAccountId', null,
    'loginEmail', null,
    'linkedChildrenCount', 0
  ) end
  from (select true) seed
  left join authorized_account account on true;
$$;

revoke all on function private.member_portal_access_summary_v1(uuid)
from public, anon, authenticated, service_role;

create or replace function app.get_member_detail_v6(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  target_member_season_id uuid;
begin
  perform private.require_clothing_aal2();
  result := app.get_member_detail_v5(p_member_id);
  select member_season.id into target_member_season_id
  from app.app_settings settings
  join app.member_seasons member_season
    on member_season.season_id = settings.active_season_id
    and member_season.member_id = p_member_id
  where settings.id = true;
  if target_member_season_id is null then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_set(
    result,
    '{sizeProfile}',
    private.member_size_profile_json_v3(target_member_season_id),
    true
  ) || jsonb_build_object(
    'memberSeasonId', target_member_season_id,
    'profileRevision', private.member_profile_revision(
      p_member_id,
      target_member_season_id
    ),
    'portalAccess', private.member_portal_access_summary_v1(
      target_member_season_id
    )
  );
end;
$$;

create or replace function app.get_parent_family_email_reconciliation_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  perform private.require_admin_aal2();
  with current_rows as (
    select
      account.id parent_account_id,
      account.email_normalized parent_email,
      family.member_id,
      family.member_season_id,
      member.email member_email,
      grant_row.email_normalized grant_email,
      concat_ws(' ', member.first_name, member.insertion, member.last_name) member_name,
      coalesce(member_season.team_name, 'Onbekend team') team,
      member.email is distinct from grant_row.email_normalized mismatched
    from private.parent_accounts account
    join private.current_parent_family_member_seasons(account.id) family on true
    join app.members member on member.id = family.member_id
    join app.member_seasons member_season on member_season.id = family.member_season_id
    join private.parent_portal_grants grant_row on grant_row.id = family.grant_id
    where grant_row.status = 'active'
  ), grouped as (
    select
      parent_account_id,
      parent_email,
      bool_or(mismatched) inconsistent,
      count(*)::integer linked_child_count,
      count(*) filter (where mismatched)::integer mismatch_count,
      jsonb_agg(jsonb_build_object(
        'memberId', member_id,
        'memberSeasonId', member_season_id,
        'memberName', member_name,
        'team', team,
        'memberEmail', member_email,
        'activeGrantEmail', grant_email,
        'mismatched', mismatched
      ) order by member_name, member_season_id) children
    from current_rows
    group by parent_account_id, parent_email
  )
  select jsonb_build_object(
    'authorizedFamilyCount', (select count(*)::integer from grouped),
    'authorizedChildCount', (
      select coalesce(sum(linked_child_count), 0)::integer from grouped
    ),
    'inconsistentFamilyCount', (
      select count(*)::integer from grouped where inconsistent
    ),
    'mismatchedChildCount', (
      select coalesce(sum(mismatch_count), 0)::integer from grouped
    ),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'parentAccountId', parent_account_id,
        'parentEmail', parent_email,
        'linkedChildCount', linked_child_count,
        'mismatchCount', mismatch_count,
        'familyEmailsInconsistent', inconsistent,
        'children', children
      ) order by parent_email, parent_account_id)
      from grouped
      where inconsistent
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function app.get_parent_family_email_reconciliation_v1()
from public, anon;
grant execute on function app.get_parent_family_email_reconciliation_v1()
to authenticated;

create or replace function app.update_member_profile_v2(
  p_member_id uuid,
  p_member_season_id uuid,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date,
  p_gender app.gender_code,
  p_team text,
  p_expected_revision text,
  p_expected_family_revision text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
#variable_conflict use_variable
declare
  actor uuid := private.require_admin_aal2();
  normalized_first_name text := nullif(btrim(regexp_replace(
    normalize(p_first_name, NFKC), '[[:space:]]+', ' ', 'g'
  )), '');
  normalized_insertion text := nullif(btrim(regexp_replace(
    normalize(p_insertion, NFKC), '[[:space:]]+', ' ', 'g'
  )), '');
  normalized_last_name text := nullif(btrim(regexp_replace(
    normalize(p_last_name, NFKC), '[[:space:]]+', ' ', 'g'
  )), '');
  normalized_email text := lower(nullif(btrim(normalize(p_email, NFKC)), ''));
  normalized_team text := nullif(btrim(regexp_replace(
    normalize(p_team, NFKC), '[[:space:]]+', ' ', 'g'
  )), '');
  normalized_reason text := nullif(btrim(regexp_replace(
    normalize(p_reason, NFKC), '[[:space:]]+', ' ', 'g'
  )), '');
  request_hash text;
  previous private.member_profile_edit_requests%rowtype;
  selected_member app.members%rowtype;
  selected_member_season app.member_seasons%rowtype;
  selected_identity private.member_sensitive_identity%rowtype;
  active_season_id uuid;
  preview jsonb;
  locked_preview jsonb;
  portal_access_active boolean := false;
  portal_transfer_required boolean := false;
  old_parent_account_id uuid;
  new_parent_account_id uuid;
  old_portal_email text;
  target_account_reused boolean := false;
  family_member_ids uuid[] := array[]::uuid[];
  family_member_season_ids uuid[] := array[]::uuid[];
  old_grant_ids uuid[] := array[]::uuid[];
  new_grant_ids uuid[] := array[]::uuid[];
  email_changed_member_ids uuid[] := array[]::uuid[];
  changed_fields text[] := array[]::text[];
  lock_id uuid;
  array_index integer;
  target_grant private.parent_portal_grants%rowtype;
  activation_batch private.parent_access_batches%rowtype;
  transfer_id uuid;
  now_utc timestamptz := timezone('utc', now());
  sessions_revoked integer := 0;
  otp_challenges_invalidated integer := 0;
  old_authorized_count integer := 0;
  activation_mail_queued boolean := false;
  affected integer;
  result jsonb;
begin
  if p_member_id is null or p_member_season_id is null or p_request_id is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or (p_expected_family_revision is not null
      and p_expected_family_revision !~ '^[0-9a-f]{64}$')
    or normalized_first_name is null or length(normalized_first_name) > 120
    or normalized_last_name is null or length(normalized_last_name) > 120
    or length(coalesce(normalized_insertion, '')) > 80
    or length(coalesce(normalized_email, '')) > 320
    or length(coalesce(normalized_team, '')) > 120
    or length(coalesce(normalized_reason, '')) not between 3 and 500
    or concat_ws('', normalized_first_name, normalized_insertion,
      normalized_last_name, normalized_email, normalized_team) ~ '[[:cntrl:]]'
    or (normalized_email is not null
      and not private.parent_access_email_valid(normalized_email))
    or (p_date_of_birth is not null
      and p_date_of_birth not between date '1900-01-01' and current_date)
  then
    raise exception 'MEMBER_PROFILE_INPUT_INVALID' using errcode = '22023';
  end if;

  request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'version', 'member-profile-v2',
    'memberId', p_member_id,
    'memberSeasonId', p_member_season_id,
    'firstName', normalized_first_name,
    'insertion', normalized_insertion,
    'lastName', normalized_last_name,
    'email', normalized_email,
    'dateOfBirth', p_date_of_birth,
    'gender', p_gender::text,
    'team', normalized_team,
    'expectedRevision', p_expected_revision,
    'expectedFamilyRevision', p_expected_family_revision,
    'reason', normalized_reason
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_advisory_xact_lock(hashtextextended(
    'member-profile-request:' || p_request_id::text, 0
  ));
  select * into previous
  from private.member_profile_edit_requests request
  where request.request_id = p_request_id;
  if found then
    if previous.staff_user_id <> actor or previous.request_hash <> request_hash then
      raise exception 'MEMBER_PROFILE_REQUEST_REUSED' using errcode = '40001';
    end if;
    return previous.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select settings.active_season_id into active_season_id
  from app.app_settings settings where settings.id = true;
  select member.* into selected_member
  from app.members member where member.id = p_member_id;
  select member_season.* into selected_member_season
  from app.member_seasons member_season
  where member_season.id = p_member_season_id
    and member_season.member_id = p_member_id
    and member_season.season_id = active_season_id;
  if selected_member.id is null or selected_member_season.id is null then
    raise exception 'MEMBER_PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;

  if selected_member.email is distinct from normalized_email
    and exists(
      select 1
      from private.parent_accounts account
      join private.current_parent_family_member_seasons(account.id) family
        on family.member_season_id = p_member_season_id
    )
  then
    if normalized_email is null then
      raise exception 'MEMBER_FAMILY_EMAIL_REQUIRED' using errcode = '23514';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(
      'parent-access-grants-global', 0
    ));
    perform pg_advisory_xact_lock(hashtextextended(
      'parent-access-season:' || active_season_id::text, 0
    ));
    preview := private.member_family_email_preview_v1(
      p_member_id,
      p_member_season_id,
      normalized_email,
      p_expected_revision
    );
    portal_access_active := (preview->>'portalAccessActive')::boolean;
    portal_transfer_required := (preview->>'transferRequired')::boolean;
    if portal_access_active then
      if p_expected_family_revision is null then
        raise exception 'MEMBER_FAMILY_EMAIL_PREFLIGHT_REQUIRED'
          using errcode = '40001';
      end if;
      if preview->>'familyRevision' <> p_expected_family_revision then
        raise exception 'MEMBER_FAMILY_EMAIL_STALE' using errcode = '40001';
      end if;
      if (preview->>'blockedCount')::integer > 0 then
        raise exception 'MEMBER_FAMILY_EMAIL_BLOCKED' using errcode = '23514';
      end if;
    end if;
  end if;

  if portal_access_active then
    select account.id, account.email_normalized
    into old_parent_account_id, old_portal_email
    from private.parent_accounts account
    join private.current_parent_family_member_seasons(account.id) family
      on family.member_season_id = p_member_season_id
    order by account.id
    limit 1;
    select
      array_agg(family.member_id order by family.member_season_id),
      array_agg(family.member_season_id order by family.member_season_id),
      array_agg(family.grant_id order by family.member_season_id)
    into family_member_ids, family_member_season_ids, old_grant_ids
    from private.current_parent_family_member_seasons(old_parent_account_id) family;
  else
    family_member_ids := array[p_member_id];
    family_member_season_ids := array[p_member_season_id];
  end if;

  for lock_id in
    select distinct item from unnest(family_member_ids) item order by item
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'dynamic-import-member:' || lock_id::text, 0
    ));
  end loop;
  for lock_id in
    select distinct item from unnest(family_member_season_ids) item order by item
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'dynamic-import-member-season:' || lock_id::text, 0
    ));
  end loop;

  perform 1 from app.app_settings settings where settings.id = true for update;
  if portal_transfer_required then
    perform 1 from app.email_templates template
    where template.template_key = 'portal_access_invite' for update;
  end if;
  perform 1 from app.members member
  where member.id = any(family_member_ids)
  order by member.id for update;
  perform 1 from app.member_seasons member_season
  where member_season.id = any(family_member_season_ids)
  order by member_season.id for update;
  select identity.* into selected_identity
  from private.member_sensitive_identity identity
  where identity.member_id = p_member_id for update;
  if selected_identity.member_id is null then
    raise exception 'MEMBER_PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;

  if portal_access_active then
    perform pg_advisory_xact_lock(hashtextextended(
      'parent-auth-account:' || old_parent_account_id::text, 0
    ));
    select account.id into old_parent_account_id
    from private.parent_accounts account
    where account.id = old_parent_account_id for update;
    if portal_transfer_required then
      select account.id into new_parent_account_id
      from private.parent_accounts account
      where account.email_normalized = normalized_email;
      target_account_reused := new_parent_account_id is not null;
      if new_parent_account_id is not null then
        perform pg_advisory_xact_lock(hashtextextended(
          'parent-auth-account:' || new_parent_account_id::text, 0
        ));
        perform 1 from private.parent_accounts account
        where account.id = new_parent_account_id for update;
      end if;
    end if;
    perform 1 from private.parent_portal_grants grant_row
    where grant_row.member_season_id = any(family_member_season_ids)
    order by grant_row.id for update;
  end if;

  select member.* into selected_member
  from app.members member where member.id = p_member_id;
  select member_season.* into selected_member_season
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  select identity.* into selected_identity
  from private.member_sensitive_identity identity
  where identity.member_id = p_member_id;
  if private.member_profile_revision(p_member_id, p_member_season_id)
    <> p_expected_revision
  then
    raise exception 'MEMBER_PROFILE_STALE' using errcode = '40001';
  end if;

  if portal_access_active then
    locked_preview := private.member_family_email_preview_v1(
      p_member_id,
      p_member_season_id,
      normalized_email,
      p_expected_revision
    );
    if locked_preview->>'familyRevision' <> p_expected_family_revision then
      raise exception 'MEMBER_FAMILY_EMAIL_STALE' using errcode = '40001';
    end if;
    if (locked_preview->>'blockedCount')::integer > 0 then
      raise exception 'MEMBER_FAMILY_EMAIL_BLOCKED' using errcode = '23514';
    end if;
  end if;

  select coalesce(array_agg(member.id order by member.id), array[]::uuid[])
  into email_changed_member_ids
  from app.members member
  where member.id = any(family_member_ids)
    and member.email is distinct from normalized_email;

  if selected_member.first_name is distinct from normalized_first_name then
    changed_fields := array_append(changed_fields, 'firstName');
  end if;
  if selected_member.insertion is distinct from normalized_insertion then
    changed_fields := array_append(changed_fields, 'insertion');
  end if;
  if selected_member.last_name is distinct from normalized_last_name then
    changed_fields := array_append(changed_fields, 'lastName');
  end if;
  if selected_member.email is distinct from normalized_email then
    changed_fields := array_append(changed_fields, 'email');
  end if;
  if selected_identity.date_of_birth is distinct from p_date_of_birth then
    changed_fields := array_append(changed_fields, 'dateOfBirth');
  end if;
  if selected_member.gender is distinct from p_gender then
    changed_fields := array_append(changed_fields, 'gender');
  end if;
  if selected_member_season.team_name is distinct from normalized_team then
    changed_fields := array_append(changed_fields, 'team');
  end if;

  update app.members member
  set email = normalized_email
  where member.id = any(family_member_ids)
    and member.email is distinct from normalized_email;
  update app.members member
  set first_name = normalized_first_name,
      insertion = normalized_insertion,
      last_name = normalized_last_name,
      gender = p_gender,
      team = normalized_team
  where member.id = p_member_id;
  update private.member_sensitive_identity identity
  set date_of_birth = p_date_of_birth,
      source_import_batch_id = null,
      updated_by = actor,
      updated_at = now_utc
  where identity.member_id = p_member_id;
  update app.member_seasons member_season
  set team_name = normalized_team,
      reconciliation_status = case
        when normalized_team is null then 'legacy_unknown'::app.member_season_reconciliation
        else 'resolved'::app.member_season_reconciliation
      end,
      source_import_batch_id = null,
      updated_at = now_utc
  where member_season.id = p_member_season_id;

  if portal_transfer_required then
    if new_parent_account_id is null then
      insert into private.parent_accounts(email_normalized)
      values(normalized_email)
      on conflict (email_normalized) do update
        set email_normalized = excluded.email_normalized
      returning id into new_parent_account_id;
      perform pg_advisory_xact_lock(hashtextextended(
        'parent-auth-account:' || new_parent_account_id::text, 0
      ));
    end if;

    update private.parent_portal_grants grant_row
    set status = 'revoked',
        revoked_by = actor,
        revoked_at = now_utc,
        revoked_reason = 'Gezinsbreed e-mailadres overgezet',
        updated_at = now_utc
    where grant_row.id = any(old_grant_ids)
      and grant_row.status <> 'revoked';

    insert into private.parent_access_batches(
      batch_key, operation, season_id, selection_hash,
      selected_count, actor_user_id
    ) values (
      p_request_id, 'activate', active_season_id, request_hash,
      cardinality(family_member_season_ids), actor
    ) returning * into activation_batch;

    for array_index in 1..cardinality(family_member_season_ids)
    loop
      target_grant := null;
      select grant_row.* into target_grant
      from private.parent_portal_grants grant_row
      where grant_row.member_season_id = family_member_season_ids[array_index]
        and grant_row.parent_account_id = new_parent_account_id
        and grant_row.email_normalized = normalized_email
        and grant_row.status = 'active'
      order by grant_row.id
      limit 1 for update;
      if target_grant.id is null then
        select grant_row.* into target_grant
        from private.parent_portal_grants grant_row
        where grant_row.member_season_id = family_member_season_ids[array_index]
          and grant_row.email_normalized = normalized_email
          and grant_row.status in ('pending_account', 'review_required')
          and grant_row.parent_account_id is not distinct from new_parent_account_id
        order by grant_row.updated_at desc, grant_row.id
        limit 1 for update;
      end if;
      if target_grant.id is not null and target_grant.status <> 'active' then
        update private.parent_portal_grants grant_row
        set parent_account_id = new_parent_account_id,
            status = 'active',
            source = 'administrator',
            granted_by = actor,
            granted_at = now_utc,
            revoked_by = null,
            revoked_at = null,
            revoked_reason = null,
            updated_at = now_utc
        where grant_row.id = target_grant.id
        returning * into target_grant;
      elsif target_grant.id is null then
        insert into private.parent_portal_grants(
          member_season_id, email_normalized, parent_account_id,
          status, source, granted_by, granted_at
        ) values (
          family_member_season_ids[array_index], normalized_email,
          new_parent_account_id, 'active', 'administrator', actor, now_utc
        ) returning * into target_grant;
      end if;
      new_grant_ids := array_append(new_grant_ids, target_grant.id);
      perform private.refresh_parent_legacy_projection(
        old_parent_account_id,
        family_member_ids[array_index]
      );
      perform private.refresh_parent_legacy_projection(
        new_parent_account_id,
        family_member_ids[array_index]
      );
      insert into private.parent_access_batch_items(
        batch_id, member_season_id, grant_id, outcome
      ) values (
        activation_batch.id,
        family_member_season_ids[array_index],
        target_grant.id,
        'activated'
      );
      insert into app.audit_logs(
        actor_user_id, action, entity_type, entity_id, metadata, correlation_id
      ) values
      (
        actor, 'parent.access.revoked', 'parent_portal_grant',
        old_grant_ids[array_index],
        jsonb_build_object(
          'memberSeasonId', family_member_season_ids[array_index],
          'requestId', p_request_id,
          'familyEmailTransfer', true,
          'reasonRecorded', true
        ),
        p_correlation_id
      ),
      (
        actor, 'parent.access.activated', 'parent_portal_grant',
        target_grant.id,
        jsonb_build_object(
          'memberSeasonId', family_member_season_ids[array_index],
          'batchId', activation_batch.id,
          'requestId', p_request_id,
          'familyEmailTransfer', true,
          'grantReused', target_grant.granted_at < now_utc
        ),
        p_correlation_id
      );
    end loop;

    select count(*)::integer into old_authorized_count
    from private.parent_authorized_member_seasons(old_parent_account_id);
    if old_authorized_count = 0 then
      update private.parent_sessions session
      set revoked_at = now_utc
      where session.parent_account_id = old_parent_account_id
        and session.revoked_at is null
        and session.expires_at > now_utc;
      get diagnostics sessions_revoked = row_count;
      update private.parent_otp_challenges challenge
      set used_at = now_utc
      where challenge.parent_account_id = old_parent_account_id
        and challenge.used_at is null
        and challenge.expires_at > now_utc;
      get diagnostics otp_challenges_invalidated = row_count;
    end if;
    update private.email_jobs invite_job
    set status = 'failed',
        completed_at = now_utc,
        last_error = 'access_transferred_before_send',
        updated_at = now_utc
    where invite_job.context_kind = 'portal_access'
      and invite_job.parent_account_id = old_parent_account_id
      and invite_job.status in ('queued', 'retry')
      and not exists(
        select 1
        from private.parent_access_batch_items batch_item
        join private.parent_portal_grants batch_grant
          on batch_grant.id = batch_item.grant_id
        where batch_item.batch_id = invite_job.parent_access_batch_id
          and batch_grant.parent_account_id = old_parent_account_id
          and batch_grant.status = 'active'
      );

    select exists(
      select 1 from private.mail_v2_domain_events event
      where event.template_key = 'portal_access_invite'
        and event.parent_account_id = new_parent_account_id
        and event.source_type = 'parent_access_batch'
        and event.source_id = activation_batch.id
    ) into activation_mail_queued;

    insert into private.parent_family_email_transfers(
      request_id, actor_user_id, selected_member_id,
      selected_member_season_id, old_parent_account_id,
      new_parent_account_id, old_email_normalized, new_email_normalized,
      expected_family_revision, affected_member_count,
      affected_member_season_count, activation_batch_id,
      sessions_revoked, otp_challenges_invalidated,
      old_authorized_member_season_count, activation_mail_queued,
      correlation_id
    ) values (
      p_request_id, actor, p_member_id, p_member_season_id,
      old_parent_account_id, new_parent_account_id,
      old_portal_email, normalized_email, p_expected_family_revision,
      (select count(distinct item) from unnest(family_member_ids) item),
      cardinality(family_member_season_ids), activation_batch.id,
      sessions_revoked, otp_challenges_invalidated,
      old_authorized_count, activation_mail_queued, p_correlation_id
    ) returning id into transfer_id;
    insert into private.parent_family_email_transfer_items(
      transfer_id, member_id, member_season_id, old_grant_id, new_grant_id
    )
    select transfer_id, family_member_ids[item.ordinality], item.member_season_id,
      old_grant_ids[item.ordinality], new_grant_ids[item.ordinality]
    from unnest(family_member_season_ids) with ordinality
      item(member_season_id, ordinality);
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    ) values (
      actor,
      'parent.access.family_email_transferred',
      'parent_family_email_transfer',
      transfer_id,
      jsonb_build_object(
        'oldParentAccountId', old_parent_account_id,
        'newParentAccountId', new_parent_account_id,
        'affectedMemberCount', (
          select count(distinct item) from unnest(family_member_ids) item
        ),
        'affectedMemberSeasonIds', to_jsonb(family_member_season_ids),
        'oldGrantIds', to_jsonb(old_grant_ids),
        'newGrantIds', to_jsonb(new_grant_ids),
        'sessionsRevoked', sessions_revoked,
        'otpChallengesInvalidated', otp_challenges_invalidated,
        'oldAuthorizedMemberSeasonCount', old_authorized_count,
        'activationMailQueued', activation_mail_queued,
        'requestId', p_request_id
      ),
      p_correlation_id
    );
  elsif portal_access_active then
    new_parent_account_id := old_parent_account_id;
    old_authorized_count := cardinality(family_member_season_ids);
  end if;

  for lock_id in
    select item from unnest(email_changed_member_ids) item order by item
  loop
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    ) values (
      actor,
      'member.profile.updated',
      'member',
      lock_id,
      jsonb_build_object(
        'memberSeasonId', case when lock_id = p_member_id
          then p_member_season_id else (
            select member_season.id
            from app.member_seasons member_season
            where member_season.member_id = lock_id
              and member_season.season_id = active_season_id
            limit 1
          ) end,
        'seasonId', active_season_id,
        'changedFields', case when lock_id = p_member_id
          then to_jsonb(changed_fields)
          else jsonb_build_array('email') end,
        'changedCount', case when lock_id = p_member_id
          then cardinality(changed_fields) else 1 end,
        'requestId', p_request_id,
        'portalAccessUnchanged', not portal_transfer_required,
        'portalAccessTransferred', portal_transfer_required,
        'familyWide', portal_access_active,
        'reason', normalized_reason
      ),
      p_correlation_id
    );
  end loop;
  if not (p_member_id = any(email_changed_member_ids))
    and cardinality(changed_fields) > 0
  then
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    ) values (
      actor, 'member.profile.updated', 'member', p_member_id,
      jsonb_build_object(
        'memberSeasonId', p_member_season_id,
        'seasonId', active_season_id,
        'changedFields', to_jsonb(changed_fields),
        'changedCount', cardinality(changed_fields),
        'requestId', p_request_id,
        'portalAccessUnchanged', not portal_transfer_required,
        'portalAccessTransferred', portal_transfer_required,
        'familyWide', portal_access_active,
        'reason', normalized_reason
      ),
      p_correlation_id
    );
  end if;

  result := app.get_member_detail_v6(p_member_id) || jsonb_build_object(
    'reused', false,
    'familyEmailTransfer', jsonb_build_object(
      'portalAccessActive', portal_access_active,
      'accessTransferred', portal_transfer_required,
      'affectedMemberCount', (
        select count(distinct item) from unnest(family_member_ids) item
      ),
      'affectedMemberSeasonCount', cardinality(family_member_season_ids),
      'targetAccountReused', target_account_reused,
      'sessionsRevoked', sessions_revoked,
      'otpChallengesInvalidated', otp_challenges_invalidated,
      'oldAuthorizedMemberSeasonCount', old_authorized_count,
      'activationMailQueued', activation_mail_queued
    )
  );
  insert into private.member_profile_edit_requests(
    request_id, staff_user_id, member_id, member_season_id,
    request_hash, result_snapshot, correlation_id
  ) values (
    p_request_id, actor, p_member_id, p_member_season_id,
    request_hash, result, p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.update_member_profile_v2(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, text, uuid, uuid
) from public, anon;
grant execute on function app.update_member_profile_v2(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, text, uuid, uuid
) to authenticated;

create or replace function app.update_member_profile_v1(
  p_member_id uuid,
  p_member_season_id uuid,
  p_first_name text,
  p_insertion text,
  p_last_name text,
  p_email text,
  p_date_of_birth date,
  p_gender app.gender_code,
  p_team text,
  p_expected_revision text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language sql
security definer
set search_path = app, private, pg_temp
as $$
  select app.update_member_profile_v2(
    p_member_id, p_member_season_id, p_first_name, p_insertion,
    p_last_name, p_email, p_date_of_birth, p_gender, p_team,
    p_expected_revision, null, p_reason, p_request_id, p_correlation_id
  );
$$;

-- Serialize authorization changes with OTP verification and session creation.
-- This closes the race where a session could otherwise be inserted just after
-- the transfer had revoked all sessions visible at its snapshot.
create or replace function public.create_parent_otp(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
volatile
security definer
set search_path = private, app, extensions, pg_temp
as $$
declare
  account_id uuid;
  normalized_email text := lower(trim(p_email));
  email_key_hash text;
  now_utc timestamptz := timezone('utc', now());
begin
  if normalized_email is null
    or length(normalized_email) not between 3 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
  then
    return null;
  end if;
  email_key_hash := encode(extensions.digest(normalized_email, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    'otp_request:' || email_key_hash, 0
  ));
  if exists(
    select 1 from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '60 seconds'
  ) then
    return null;
  end if;
  if (
    select count(*) from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '1 hour'
  ) >= 5 then
    return null;
  end if;
  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values('otp_request', email_key_hash, now_utc);

  select account.id into account_id
  from private.parent_accounts account
  where account.email_normalized = normalized_email;
  if account_id is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || account_id::text, 0
  ));
  perform 1 from private.parent_accounts account
  where account.id = account_id for update;
  if not private.parent_account_has_portal_access(account_id) then
    return null;
  end if;
  update private.parent_otp_challenges challenge
  set used_at = now_utc
  where challenge.parent_account_id = account_id
    and challenge.used_at is null
    and challenge.expires_at > now_utc;
  insert into private.parent_otp_challenges(
    parent_account_id, code_hash, expires_at
  ) values (
    account_id, p_code_hash, now_utc + interval '10 minutes'
  );
  return account_id;
end;
$$;

create or replace function private.consume_parent_otp(
  p_email text,
  p_code_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  select * into account
  from private.parent_accounts target
  where target.email_normalized = lower(trim(p_email))
  limit 1;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || account.id::text, 0
  ));
  select * into account
  from private.parent_accounts target
  where target.id = account.id
  for update;
  if not private.parent_account_has_portal_access(account.id) then
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into challenge
  from private.parent_otp_challenges target
  where target.parent_account_id = account.id
  order by target.created_at desc
  limit 1
  for update;
  if not found
    or challenge.used_at is not null
    or challenge.expires_at <= now_utc
    or challenge.attempts >= challenge.max_attempts
  then
    return jsonb_build_object('status', 'invalid');
  end if;
  if challenge.code_hash <> p_code_hash then
    update private.parent_otp_challenges target
    set attempts = attempts + 1
    where target.id = challenge.id;
    return jsonb_build_object('status', 'invalid');
  end if;
  update private.parent_otp_challenges target
  set used_at = now_utc
  where target.id = challenge.id;
  update private.parent_accounts target
  set last_login_at = now_utc
  where target.id = account.id;
  return jsonb_build_object(
    'status', 'verified',
    'parentAccountId', account.id
  );
end;
$$;

create or replace function public.create_parent_session(
  p_parent_account_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  session_id uuid;
begin
  if p_parent_account_id is null
    or p_token_hash is null
    or p_token_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
    or p_expires_at <= timezone('utc', now())
    or p_expires_at > timezone('utc', now()) + interval '30 days'
  then
    raise exception 'PARENT_SESSION_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || p_parent_account_id::text, 0
  ));
  perform 1 from private.parent_accounts account
  where account.id = p_parent_account_id for update;
  if not found
    or not private.parent_account_has_portal_access(p_parent_account_id)
  then
    raise exception 'PARENT_ACCESS_REQUIRED' using errcode = '42501';
  end if;
  insert into private.parent_sessions(
    parent_account_id, token_hash, expires_at
  ) values (
    p_parent_account_id, p_token_hash, p_expires_at
  ) returning id into session_id;
  return session_id;
end;
$$;

revoke all on function public.create_parent_otp(text, text, timestamptz)
from public, anon, authenticated;
grant execute on function public.create_parent_otp(text, text, timestamptz)
to service_role;
revoke all on function private.consume_parent_otp(text, text)
from public, anon, authenticated;
grant execute on function private.consume_parent_otp(text, text)
to service_role;
revoke all on function public.create_parent_session(uuid, text, timestamptz)
from public, anon, authenticated;
grant execute on function public.create_parent_session(uuid, text, timestamptz)
to service_role;

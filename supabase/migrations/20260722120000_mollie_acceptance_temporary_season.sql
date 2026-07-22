create table if not exists private.mollie_acceptance_fixtures (
  paid_order_id uuid primary key,
  mismatch_order_id uuid not null unique,
  paid_member_id uuid not null unique,
  mismatch_member_id uuid not null unique,
  paid_relation text not null unique,
  mismatch_relation text not null unique,
  fixture_email text not null,
  fixture_season_id uuid not null,
  created_season boolean not null,
  previous_active_season_id uuid,
  previous_mollie_enabled boolean not null,
  created_at timestamptz not null default timezone('utc', now())
);

revoke all on table private.mollie_acceptance_fixtures
from public, anon, authenticated, service_role;

create or replace function public.prepare_mollie_acceptance_fixture(
  p_paid_member_id uuid,
  p_mismatch_member_id uuid,
  p_paid_order_id uuid,
  p_mismatch_order_id uuid,
  p_paid_relation text,
  p_mismatch_relation text,
  p_fixture_email text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  fixture_season_id uuid;
  previous_active_season_id uuid;
  previous_mollie_enabled boolean;
  created_fixture_season boolean := false;
begin
  if not private.is_mollie_acceptance_identity(
    p_paid_member_id, p_mismatch_member_id, p_paid_order_id, p_mismatch_order_id,
    p_paid_relation, p_mismatch_relation, p_fixture_email
  ) then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select settings.active_season_id, settings.mollie_enabled
  into previous_active_season_id, previous_mollie_enabled
  from app.app_settings settings
  where settings.id = true
  for update;
  if not found then
    raise exception 'APP_SETTINGS_REQUIRED' using errcode = '23514';
  end if;

  select season.id into fixture_season_id
  from app.seasons season
  where season.id = previous_active_season_id and season.status = 'open'
  for update;

  if fixture_season_id is null then
    insert into app.seasons (
      name, starts_on, default_amount_cents, status, opened_at
    ) values (
      'Mollie acceptatie ' || p_paid_relation,
      current_date,
      100,
      'open',
      timezone('utc', now())
    ) returning id into fixture_season_id;
    created_fixture_season := true;
  end if;

  if exists (
    select 1 from app.members member
    where member.id in (p_paid_member_id, p_mismatch_member_id)
      or member.relation_number in (p_paid_relation, p_mismatch_relation)
  ) or exists (
    select 1 from app.member_orders orders
    where orders.id in (p_paid_order_id, p_mismatch_order_id)
  ) or exists (
    select 1 from private.mollie_acceptance_fixtures fixture
    where fixture.paid_order_id = p_paid_order_id
      or fixture.mismatch_order_id = p_mismatch_order_id
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_FIXTURE_EXISTS' using errcode = '23505';
  end if;

  insert into private.mollie_acceptance_fixtures (
    paid_order_id, mismatch_order_id, paid_member_id, mismatch_member_id,
    paid_relation, mismatch_relation, fixture_email, fixture_season_id,
    created_season, previous_active_season_id, previous_mollie_enabled
  ) values (
    p_paid_order_id, p_mismatch_order_id, p_paid_member_id, p_mismatch_member_id,
    p_paid_relation, p_mismatch_relation, p_fixture_email, fixture_season_id,
    created_fixture_season, previous_active_season_id, previous_mollie_enabled
  );

  insert into app.members (
    id, relation_number, first_name, last_name, email, team, active_for_season
  ) values
    (p_paid_member_id, p_paid_relation, 'Mollie', 'Acceptance Paid', p_fixture_email,
      case when previous_mollie_enabled then 'MOLLIE-ACCEPTANCE-M1' else 'MOLLIE-ACCEPTANCE-M0' end, true),
    (p_mismatch_member_id, p_mismatch_relation, 'Mollie', 'Acceptance Mismatch', p_fixture_email,
      case when previous_mollie_enabled then 'MOLLIE-ACCEPTANCE-M1' else 'MOLLIE-ACCEPTANCE-M0' end, true);

  insert into app.member_orders (id, member_id, season_id, amount_due_cents)
  values
    (p_paid_order_id, p_paid_member_id, fixture_season_id, 100),
    (p_mismatch_order_id, p_mismatch_member_id, fixture_season_id, 100);

  update app.app_settings
  set active_season_id = fixture_season_id,
      mollie_enabled = true,
      updated_at = timezone('utc', now())
  where id = true;
  return true;
end;
$$;

create or replace function public.cleanup_mollie_acceptance_fixture(
  p_paid_member_id uuid,
  p_mismatch_member_id uuid,
  p_paid_order_id uuid,
  p_mismatch_order_id uuid,
  p_paid_relation text,
  p_mismatch_relation text,
  p_fixture_email text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  fixture_record private.mollie_acceptance_fixtures%rowtype;
  restore_disabled boolean := false;
  restore_active_season_id uuid;
begin
  if not private.is_mollie_acceptance_identity(
    p_paid_member_id, p_mismatch_member_id, p_paid_order_id, p_mismatch_order_id,
    p_paid_relation, p_mismatch_relation, p_fixture_email
  ) then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select fixture.* into fixture_record
  from private.mollie_acceptance_fixtures fixture
  where fixture.paid_order_id = p_paid_order_id
    and fixture.mismatch_order_id = p_mismatch_order_id
    and fixture.paid_member_id = p_paid_member_id
    and fixture.mismatch_member_id = p_mismatch_member_id
    and fixture.paid_relation = p_paid_relation
    and fixture.mismatch_relation = p_mismatch_relation
    and fixture.fixture_email = p_fixture_email
  for update;

  if not found then
    select coalesce(bool_or(member.team = 'MOLLIE-ACCEPTANCE-M0'), false)
      and not coalesce(bool_or(member.team = 'MOLLIE-ACCEPTANCE-M1'), false)
    into restore_disabled
    from app.members member
    where member.id in (p_paid_member_id, p_mismatch_member_id)
      and member.relation_number in (p_paid_relation, p_mismatch_relation)
      and member.email = p_fixture_email;
  end if;

  delete from app.email_events event where event.email_job_id in (
    select job.id from private.email_jobs job where job.order_id in (p_paid_order_id, p_mismatch_order_id)
  );
  delete from private.email_jobs job where job.order_id in (p_paid_order_id, p_mismatch_order_id);
  delete from private.payment_events event where event.payment_id in (
    select payment.id from app.payments payment where payment.order_id in (p_paid_order_id, p_mismatch_order_id)
  );
  delete from app.audit_logs audit
  where audit.entity_id in (p_paid_order_id, p_mismatch_order_id, p_paid_member_id, p_mismatch_member_id)
    or audit.entity_id in (
      select payment.id from app.payments payment where payment.order_id in (p_paid_order_id, p_mismatch_order_id)
    );
  delete from private.qr_tokens token where token.order_id in (p_paid_order_id, p_mismatch_order_id);
  delete from app.payments payment where payment.order_id in (p_paid_order_id, p_mismatch_order_id);
  delete from app.order_lines line where line.order_id in (p_paid_order_id, p_mismatch_order_id);
  delete from app.member_orders orders
  where orders.id in (p_paid_order_id, p_mismatch_order_id)
    and orders.member_id in (p_paid_member_id, p_mismatch_member_id);

  delete from private.parent_member_links link where link.parent_account_id in (
    select account.id from private.parent_accounts account where account.email_normalized = p_fixture_email
  );
  delete from private.parent_sessions session where session.parent_account_id in (
    select account.id from private.parent_accounts account where account.email_normalized = p_fixture_email
  );
  delete from private.parent_accounts account where account.email_normalized = p_fixture_email;
  delete from private.rate_limit_events event
  where event.scope in ('otp_request', 'otp_verify')
    and event.key_hash = encode(extensions.digest(p_fixture_email, 'sha256'), 'hex');

  delete from app.members member
  where member.id in (p_paid_member_id, p_mismatch_member_id)
    and member.relation_number in (p_paid_relation, p_mismatch_relation)
    and member.email = p_fixture_email;

  if fixture_record.paid_order_id is not null then
    select season.id into restore_active_season_id
    from app.seasons season
    where season.id = fixture_record.previous_active_season_id;

    update app.app_settings
    set active_season_id = restore_active_season_id,
        mollie_enabled = fixture_record.previous_mollie_enabled,
        updated_at = timezone('utc', now())
    where id = true;

    delete from private.mollie_acceptance_fixtures fixture
    where fixture.paid_order_id = p_paid_order_id;

    if fixture_record.created_season then
      delete from app.seasons season
      where season.id = fixture_record.fixture_season_id
        and season.name = 'Mollie acceptatie ' || p_paid_relation;
    end if;
  elsif restore_disabled then
    update app.app_settings
    set mollie_enabled = false, updated_at = timezone('utc', now())
    where id = true;
  end if;
  return true;
end;
$$;

notify pgrst, 'reload schema';

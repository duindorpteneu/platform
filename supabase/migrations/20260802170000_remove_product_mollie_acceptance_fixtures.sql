-- Staging acceptance data is provisioned through a target-locked external SQL
-- harness. No fixture mutation contract may remain in the product schema.

do $migration_guard$
declare
  active_fixture_exists boolean := false;
begin
  if to_regclass('private.mollie_acceptance_fixtures') is not null then
    execute 'select exists (select 1 from private.mollie_acceptance_fixtures)'
      into active_fixture_exists;
    if active_fixture_exists then
      raise exception 'ACTIVE_MOLLIE_ACCEPTANCE_FIXTURE_REQUIRES_CLEANUP'
        using errcode = '55006';
    end if;
  end if;

  if exists (
    select 1
    from app.members member
    where member.relation_number ~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-[PM]$'
      or member.email ~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
      or member.team in ('MOLLIE-ACCEPTANCE', 'MOLLIE-ACCEPTANCE-M0', 'MOLLIE-ACCEPTANCE-M1')
  ) or exists (
    select 1
    from app.seasons season
    where season.name ~ '^Mollie acceptatie MOLLIE-[0-9]{1,20}a[0-9]{1,6}-P$'
  ) or exists (
    select 1
    from private.parent_accounts account
    where account.email_normalized ~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
  ) then
    raise exception 'ORPHAN_MOLLIE_ACCEPTANCE_FIXTURE_REQUIRES_REVIEW'
      using errcode = '55006';
  end if;
end
$migration_guard$;

drop function if exists public.cleanup_mollie_acceptance_fixture(
  uuid, uuid, uuid, uuid, text, text, text
);
drop function if exists public.get_mollie_acceptance_payment_state(uuid, uuid);
drop function if exists public.prepare_mollie_acceptance_fixture(
  uuid, uuid, uuid, uuid, text, text, text
);
drop function if exists private.is_mollie_acceptance_identity(
  uuid, uuid, uuid, uuid, text, text, text
);
drop function if exists public.parent_otp_members_visible(uuid[], text);

drop table if exists private.mollie_acceptance_fixtures;

notify pgrst, 'reload schema';

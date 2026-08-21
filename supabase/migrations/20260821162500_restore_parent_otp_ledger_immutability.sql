-- Close the narrowly-scoped backfill window immediately after
-- 20260821162000 has assigned every historical recipient identity.

create or replace function private.guard_parent_otp_delivery_ledger()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  if tg_op = 'DELETE'
    and coalesce(
      current_setting('app.parent_otp_delivery_retention', true),
      'off'
    ) = 'on'
  then
    return old;
  end if;
  raise exception 'PARENT_OTP_DELIVERY_LEDGER_IMMUTABLE'
    using errcode = '23514';
end;
$$;

revoke all on function private.guard_parent_otp_delivery_ledger()
from public, anon, authenticated, service_role;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821162500_restore_parent_otp_ledger_immutability',
  'passed',
  jsonb_build_object('guard', 'strict')
)
on conflict (migration_key) do nothing;

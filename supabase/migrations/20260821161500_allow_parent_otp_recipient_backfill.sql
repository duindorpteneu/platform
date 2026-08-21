-- Narrow forward-only compatibility window for the historical recipient
-- identity backfill in 20260821162000. The existing append-only ledger remains
-- immutable except for a one-time NULL -> recipient_identity_id assignment
-- where every pre-existing column is byte-for-byte unchanged.

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
  if tg_op = 'UPDATE'
    and tg_table_schema = 'private'
    and tg_table_name = 'parent_otp_delivery_attempts'
    and to_jsonb(old)->>'recipient_identity_id' is null
    and to_jsonb(new)->>'recipient_identity_id' is not null
    and (to_jsonb(new) - 'recipient_identity_id')
      = (to_jsonb(old) - 'recipient_identity_id')
  then
    return new;
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
  '20260821161500_allow_parent_otp_recipient_backfill',
  'passed',
  jsonb_build_object('scope', 'recipient_identity_null_to_bound')
)
on conflict (migration_key) do nothing;

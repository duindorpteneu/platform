create or replace function private.is_mollie_acceptance_identity(
  p_paid_member_id uuid,
  p_mismatch_member_id uuid,
  p_paid_order_id uuid,
  p_mismatch_order_id uuid,
  p_paid_relation text,
  p_mismatch_relation text,
  p_fixture_email text
)
returns boolean
language sql
immutable
set search_path = pg_temp
as $$
  select p_paid_member_id is not null
    and p_mismatch_member_id is not null
    and p_paid_order_id is not null
    and p_mismatch_order_id is not null
    and p_paid_member_id <> p_mismatch_member_id
    and p_paid_order_id <> p_mismatch_order_id
    and p_paid_relation ~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-P$'
    and p_mismatch_relation ~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-M$'
    and p_fixture_email ~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$';
$$;

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
  previous_mollie_enabled boolean;
begin
  if not private.is_mollie_acceptance_identity(
    p_paid_member_id, p_mismatch_member_id, p_paid_order_id, p_mismatch_order_id,
    p_paid_relation, p_mismatch_relation, p_fixture_email
  ) then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select settings.active_season_id, settings.mollie_enabled
  into fixture_season_id, previous_mollie_enabled
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true
  for update of settings, season;
  if fixture_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;
  if exists (
    select 1 from app.members member
    where member.id in (p_paid_member_id, p_mismatch_member_id)
      or member.relation_number in (p_paid_relation, p_mismatch_relation)
  ) or exists (
    select 1 from app.member_orders orders
    where orders.id in (p_paid_order_id, p_mismatch_order_id)
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_FIXTURE_EXISTS' using errcode = '23505';
  end if;

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
  set mollie_enabled = true, updated_at = timezone('utc', now())
  where id = true;
  return true;
end;
$$;

create or replace function public.get_mollie_acceptance_payment_state(
  p_order_id uuid,
  p_member_id uuid
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
  if not exists (
    select 1
    from app.member_orders orders
    join app.members member on member.id = orders.member_id
    where orders.id = p_order_id
      and member.id = p_member_id
      and member.relation_number ~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-[PM]$'
      and member.email ~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
  ) then
    return null;
  end if;

  select jsonb_build_object(
    'paymentId', payment.id,
    'providerPaymentId', payment.provider_payment_id,
    'amountCents', payment.amount_cents,
    'paymentStatus', payment.status::text,
    'reconciliationIssue', payment.reconciliation_issue,
    'paidPayments', (select count(*) from app.payments item where item.order_id = p_order_id and item.status = 'paid'),
    'activeQr', (select count(*) from private.qr_tokens qr where qr.order_id = p_order_id and qr.active),
    'allQr', (select count(*) from private.qr_tokens qr where qr.order_id = p_order_id),
    'paymentEmailJobs', (select count(*) from private.email_jobs job where job.order_id = p_order_id and job.template_key = 'payment_received'),
    'paidEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'paid'),
    'refundEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'refunded'),
    'mismatchEvents', (select count(*) from private.payment_events event where event.payment_id = payment.id and event.event_type = 'mismatch'),
    'paidAudits', (select count(*) from app.audit_logs audit where audit.entity_id = p_order_id and audit.action = 'payment.mollie.paid'),
    'refundAudits', (select count(*) from app.audit_logs audit where audit.entity_id = p_order_id and audit.action = 'payment.mollie.refunded'),
    'manualReviewAudits', (select count(*) from app.audit_logs audit where audit.entity_id = payment.id and audit.action = 'payment.mollie.manual_review')
  ) into result
  from app.payments payment
  where payment.order_id = p_order_id and payment.method = 'mollie'
  order by payment.created_at desc
  limit 1;
  return result;
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
  restore_disabled boolean := false;
begin
  if not private.is_mollie_acceptance_identity(
    p_paid_member_id, p_mismatch_member_id, p_paid_order_id, p_mismatch_order_id,
    p_paid_relation, p_mismatch_relation, p_fixture_email
  ) then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select coalesce(bool_or(member.team = 'MOLLIE-ACCEPTANCE-M0'), false)
    and not coalesce(bool_or(member.team = 'MOLLIE-ACCEPTANCE-M1'), false)
  into restore_disabled
  from app.members member
  where member.id in (p_paid_member_id, p_mismatch_member_id)
    and member.relation_number in (p_paid_relation, p_mismatch_relation)
    and member.email = p_fixture_email;

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

  if restore_disabled then
    update app.app_settings
    set mollie_enabled = false, updated_at = timezone('utc', now())
    where id = true;
  end if;
  return true;
end;
$$;

revoke all on function private.is_mollie_acceptance_identity(uuid,uuid,uuid,uuid,text,text,text)
from public, anon, authenticated, service_role;
revoke all on function public.prepare_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)
from public, anon, authenticated;
revoke all on function public.get_mollie_acceptance_payment_state(uuid,uuid)
from public, anon, authenticated;
revoke all on function public.cleanup_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)
from public, anon, authenticated;
grant execute on function public.prepare_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)
to service_role;
grant execute on function public.get_mollie_acceptance_payment_state(uuid,uuid)
to service_role;
grant execute on function public.cleanup_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)
to service_role;

notify pgrst, 'reload schema';

\set ON_ERROR_STOP on

begin;

with fixture_orders as (
  select orders.id
  from app.member_orders orders
  join app.members member on member.id = orders.member_id
  where member.relation_number in (:'paid_relation', :'mismatch_relation')
    and member.id in (:'paid_member_id', :'mismatch_member_id')
), fixture_jobs as (
  select job.id from private.email_jobs job
  where job.order_id in (select id from fixture_orders)
)
delete from app.email_events event
where event.email_job_id in (select id from fixture_jobs);

with fixture_orders as (
  select orders.id
  from app.member_orders orders
  join app.members member on member.id = orders.member_id
  where member.relation_number in (:'paid_relation', :'mismatch_relation')
    and member.id in (:'paid_member_id', :'mismatch_member_id')
)
delete from private.email_jobs job
where job.order_id in (select id from fixture_orders);

with fixture_payments as (
  select payment.id
  from app.payments payment
  join app.member_orders orders on orders.id = payment.order_id
  join app.members member on member.id = orders.member_id
  where member.relation_number in (:'paid_relation', :'mismatch_relation')
    and member.id in (:'paid_member_id', :'mismatch_member_id')
)
delete from private.payment_events event
where event.payment_id in (select id from fixture_payments);

delete from app.audit_logs audit
where audit.entity_id in (
  :'paid_order_id'::uuid, :'mismatch_order_id'::uuid,
  :'paid_member_id'::uuid, :'mismatch_member_id'::uuid
) or audit.entity_id in (
  select payment.id from app.payments payment
  where payment.order_id in (:'paid_order_id'::uuid, :'mismatch_order_id'::uuid)
);

delete from private.qr_tokens token
where token.order_id in (:'paid_order_id'::uuid, :'mismatch_order_id'::uuid);

delete from app.payments payment
where payment.order_id in (:'paid_order_id'::uuid, :'mismatch_order_id'::uuid);

delete from app.order_lines line
where line.order_id in (:'paid_order_id'::uuid, :'mismatch_order_id'::uuid);

delete from app.member_orders orders
where orders.id in (:'paid_order_id'::uuid, :'mismatch_order_id'::uuid)
  and orders.member_id in (:'paid_member_id'::uuid, :'mismatch_member_id'::uuid);

delete from private.parent_member_links link
where link.parent_account_id = :'parent_account_id'::uuid
  and link.member_id in (:'paid_member_id'::uuid, :'mismatch_member_id'::uuid);

delete from private.parent_sessions session
where session.parent_account_id = :'parent_account_id'::uuid;

delete from private.parent_accounts account
where account.id = :'parent_account_id'::uuid
  and account.email_normalized = :'fixture_email';

with removed as (
  delete from app.members member
  where member.id in (:'paid_member_id'::uuid, :'mismatch_member_id'::uuid)
    and member.relation_number in (:'paid_relation', :'mismatch_relation')
  returning member.team
)
update app.app_settings settings
set mollie_enabled = false, updated_at = timezone('utc', now())
where settings.id = true
  and exists (select 1 from removed where team = 'MOLLIE-ACCEPTANCE-M0')
  and not exists (select 1 from removed where team = 'MOLLIE-ACCEPTANCE-M1');

commit;

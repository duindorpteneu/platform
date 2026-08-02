begin read only;

with fixture_input (
  paid_member_id,
  mismatch_member_id,
  paid_order_id,
  mismatch_order_id,
  paid_relation,
  mismatch_relation,
  fixture_email,
  state_order_id,
  state_member_id
) as (
  values (
    :'paid_member_id'::uuid,
    :'mismatch_member_id'::uuid,
    :'paid_order_id'::uuid,
    :'mismatch_order_id'::uuid,
    :'paid_relation'::text,
    :'mismatch_relation'::text,
    :'fixture_email'::text,
    :'state_order_id'::uuid,
    :'state_member_id'::uuid
  )
)
select coalesce((
  select jsonb_build_object(
    'paymentId', payment.id,
    'providerPaymentId', payment.provider_payment_id,
    'amountCents', payment.amount_cents,
    'paymentStatus', payment.status::text,
    'reconciliationIssue', payment.reconciliation_issue,
    'paidPayments', (select count(*) from app.payments item
      where item.order_id = fixture_input.state_order_id and item.status = 'paid'),
    'activeQr', (select count(*) from private.qr_tokens qr
      where qr.order_id = fixture_input.state_order_id and qr.active),
    'allQr', (select count(*) from private.qr_tokens qr
      where qr.order_id = fixture_input.state_order_id),
    'paymentEmailJobs', (select count(*) from private.email_jobs job
      where job.order_id = fixture_input.state_order_id and job.template_key = 'payment_received'),
    'paidEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'paid'),
    'refundEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'refunded'),
    'mismatchEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'mismatch'),
    'paidAudits', (select count(*) from app.audit_logs audit
      where audit.entity_id = fixture_input.state_order_id and audit.action = 'payment.mollie.paid'),
    'refundAudits', (select count(*) from app.audit_logs audit
      where audit.entity_id = fixture_input.state_order_id and audit.action = 'payment.mollie.refunded'),
    'manualReviewAudits', (select count(*) from app.audit_logs audit
      where audit.entity_id = payment.id and audit.action = 'payment.mollie.manual_review')
  )
  from fixture_input
  join app.member_orders orders
    on orders.id = fixture_input.state_order_id
   and orders.member_id = fixture_input.state_member_id
  join app.members member
    on member.id = fixture_input.state_member_id
   and member.email = fixture_input.fixture_email
   and (
     (fixture_input.state_order_id = fixture_input.paid_order_id
       and fixture_input.state_member_id = fixture_input.paid_member_id
       and member.relation_number = fixture_input.paid_relation)
     or
     (fixture_input.state_order_id = fixture_input.mismatch_order_id
       and fixture_input.state_member_id = fixture_input.mismatch_member_id
       and member.relation_number = fixture_input.mismatch_relation)
   )
  join lateral (
    select candidate.*
    from app.payments candidate
    where candidate.order_id = fixture_input.state_order_id
      and candidate.method = 'mollie'
    order by candidate.created_at desc
    limit 1
  ) payment on true
), 'null'::jsonb)
from fixture_input;

rollback;

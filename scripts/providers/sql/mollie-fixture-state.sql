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
    'hardAllocations', (select count(*) from app.inventory_allocations allocation
      where allocation.order_id = fixture_input.state_order_id
        and allocation.status in ('reserved', 'fulfilled')),
    'readyLines', (select count(*) from app.order_lines line
      where line.order_id = fixture_input.state_order_id
        and line.status = 'ready_for_pickup'),
    'activeQr', (
      (select count(*) from private.qr_tokens qr
        where qr.order_id = fixture_input.state_order_id and qr.active)
      +
      (select count(*)
        from private.qr_order_identities identity
        join private.qr_order_locators locator
          on locator.identity_id = identity.id
          and locator.active
        where identity.order_id = fixture_input.state_order_id
          and identity.suspended_at is null)
    ),
    'allQr', (
      (select count(*) from private.qr_tokens qr
        where qr.order_id = fixture_input.state_order_id)
      +
      (select count(*)
        from private.qr_order_identities identity
        join private.qr_order_locators locator
          on locator.identity_id = identity.id
        where identity.order_id = fixture_input.state_order_id)
    ),
    'qrBusinessEligible', private.order_qr_business_eligible(fixture_input.state_order_id),
    'qrUsable', private.order_qr_usable(fixture_input.state_order_id),
    'paymentEmailJobs', (select count(*) from private.email_jobs job
      where job.order_id = fixture_input.state_order_id
        and job.template_key in (
          'payment_received',
          'payment_received_waiting_stock'
        )),
    'paymentCommunicationIntents', (
      (select count(*) from private.email_jobs job
        where job.order_id = fixture_input.state_order_id
          and job.template_key = 'payment_received')
      +
      (select count(*) from private.mail_v2_domain_events event
        where event.order_id = fixture_input.state_order_id
          and event.template_key = 'payment_received_waiting_stock')
    ),
    'paidEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'paid'),
    'refundEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'refunded'),
    'mismatchEvents', (select count(*) from private.payment_events event
      where event.payment_id = payment.id and event.event_type = 'mismatch'),
    'paidAudits', (select count(*) from app.audit_logs audit
      where audit.entity_id = fixture_input.state_order_id and audit.action = 'payment.mollie.paid_v2'),
    'refundAudits', (select count(*) from app.audit_logs audit
      where audit.entity_id = fixture_input.state_order_id and audit.action = 'payment.mollie.refunded_v2'),
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

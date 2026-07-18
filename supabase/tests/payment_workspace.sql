begin;

create extension if not exists pgtap with schema extensions;
select plan(12);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('d0000000-0000-4000-8000-000000000001', 'Betalingen commissie', 'kledingcommissie'),
  ('d0000000-0000-4000-8000-000000000002', 'Betalingen uitgifte', 'uitgifte');
insert into app.members(id, relation_number, first_name, last_name, email, team)
values('d1000000-0000-4000-8000-000000000001', 'PAY-WS-001', 'Pim', 'Betaling', 'pim-betaling@example.invalid', 'JO17-1');
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'd2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', active_season_id, 12500
from app.app_settings where id=true;
insert into app.payments(order_id, method, status, amount_cents, idempotency_key, created_at)
select 'd2000000-0000-4000-8000-000000000001', 'mollie', 'open', 12500,
  'payment-workspace-open-' || value, timezone('utc', now()) - make_interval(secs => value)
from generate_series(1,105) value;
insert into app.payments(order_id, method, status, amount_cents, idempotency_key, provider_payment_id, reconciliation_issue) values
  ('d2000000-0000-4000-8000-000000000001', 'mollie', 'pending', 12500, 'payment-workspace-pending', 'tr_workspace_pending', null),
  ('d2000000-0000-4000-8000-000000000001', 'mollie', 'duplicate_paid', 12500, 'payment-workspace-duplicate', 'tr_workspace_duplicate', 'duplicate paid payment; manual reconciliation required'),
  ('d2000000-0000-4000-8000-000000000001', 'mollie', 'refunded', 12500, 'payment-workspace-refunded', 'tr_workspace_refunded', null);

select set_config('request.jwt.claims', '{"sub":"d0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.get_payment_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifterol kan betalingenreadmodel niet openen');

reset role;
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
set local role authenticated;
select throws_ok($$select app.get_payment_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'AAL1 kan betalingenreadmodel niet openen');

reset role;
select set_config('request.jwt.claims', '{"sub":"d0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
create temporary table payment_workspace_result as select app.get_payment_workspace() result;
select is(jsonb_array_length(result->'attempts'), 100, 'readmodel begrenst recente pogingen hard op 100') from payment_workspace_result;
select is((result #>> '{summary,open}')::integer, 105, 'samenvatting telt open pogingen') from payment_workspace_result;
select is((result #>> '{summary,pending}')::integer, 1, 'samenvatting telt pending pogingen') from payment_workspace_result;
select is((result #>> '{summary,paid}')::integer, 0, 'samenvatting telt paid pogingen') from payment_workspace_result;
select is((result #>> '{summary,duplicatePaid}')::integer, 1, 'samenvatting telt duplicate paid pogingen') from payment_workspace_result;
select is((result #>> '{summary,refunded}')::integer, 1, 'samenvatting telt refunds') from payment_workspace_result;
select is((result #>> '{summary,review}')::integer, 1, 'samenvatting telt manual-reviewissues') from payment_workspace_result;
select ok((result->'attempts'->0) ?& array[
  'paymentId','orderId','memberName','relationNumber','team','method','status','amountCents','currency',
  'providerPaymentId','reconciliationIssue','createdAt','reconciledAt'
], 'attempt bevat exact de benodigde operationele dimensies') from payment_workspace_result;
select ok(result::text not like '%pim-betaling@example.invalid%', 'readmodel bevat geen e-mailadres') from payment_workspace_result;
select ok(result::text !~ '(checkoutUrl|checkout_url|metadata|token|tokenHash|token_hash)',
  'readmodel bevat geen checkout, metadata of tokenmateriaal') from payment_workspace_result;

select * from finish();
rollback;

create or replace function app.record_manual_payment(
  p_order_id uuid,
  p_method app.payment_method,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_order app.member_orders%rowtype;
  existing_payment app.payments%rowtype;
  payment_id uuid;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_order_id is null or p_idempotency_key is null or length(trim(p_idempotency_key)) < 16 then
    raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023';
  end if;

  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;

  select * into existing_payment from app.payments
  where order_id = p_order_id and status = 'paid'
  order by paid_at asc nulls last, created_at asc
  limit 1;
  if found then
    return jsonb_build_object('status', 'already_paid', 'paymentId', existing_payment.id, 'amountCents', existing_payment.amount_cents);
  end if;

  insert into app.payments (order_id, method, status, amount_cents, currency, idempotency_key, paid_at)
  values (p_order_id, p_method, 'paid', target_order.amount_due_cents, 'EUR', p_idempotency_key, timezone('utc', now()))
  returning id into payment_id;

  update app.member_orders
  set order_status = 'Nalevering', updated_at = timezone('utc', now())
  where id = p_order_id;

  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'payment.manual.recorded', 'payment', payment_id,
    jsonb_build_object('order_id', p_order_id, 'method', p_method, 'amount_cents', target_order.amount_due_cents));

  return jsonb_build_object('status', 'paid', 'paymentId', payment_id, 'amountCents', target_order.amount_due_cents);
end;
$$;

revoke all on function app.record_manual_payment(uuid, app.payment_method, text) from public, anon;
grant execute on function app.record_manual_payment(uuid, app.payment_method, text) to authenticated;

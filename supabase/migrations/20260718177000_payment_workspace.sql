create or replace function app.get_payment_workspace()
returns jsonb
language plpgsql stable security definer
set search_path = app, pg_temp
as $$
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'summary', jsonb_build_object(
      'open', (select count(*) from app.payments where status = 'open'),
      'pending', (select count(*) from app.payments where status = 'pending'),
      'paid', (select count(*) from app.payments where status = 'paid'),
      'duplicatePaid', (select count(*) from app.payments where status = 'duplicate_paid'),
      'refunded', (select count(*) from app.payments where status = 'refunded'),
      'review', (select count(*) from app.payments where reconciliation_issue is not null)
    ),
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'paymentId', attempt.id,
        'orderId', attempt.order_id,
        'memberName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
        'relationNumber', member.relation_number,
        'team', member.team,
        'method', attempt.method::text,
        'status', attempt.status::text,
        'amountCents', attempt.amount_cents,
        'currency', attempt.currency,
        'providerPaymentId', attempt.provider_payment_id,
        'reconciliationIssue', attempt.reconciliation_issue,
        'createdAt', attempt.created_at,
        'reconciledAt', attempt.reconciled_at
      ) order by attempt.created_at desc, attempt.id desc)
      from (
        select * from app.payments order by created_at desc, id desc limit 100
      ) attempt
      join app.member_orders orders on orders.id = attempt.order_id
      join app.members member on member.id = orders.member_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_payment_workspace() from public, anon;
grant execute on function app.get_payment_workspace() to authenticated;

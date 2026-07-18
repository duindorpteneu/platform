create or replace function public.prepare_mollie_payment(
  p_token_hash text, p_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  target_payment app.payments%rowtype;
  now_utc timestamptz := timezone('utc', now());
  reused boolean := false;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' or length(trim(p_idempotency_key)) not between 8 and 160 then
    raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023';
  end if;
  select orders.* into target_order
  from private.parent_sessions session
  join private.parent_member_links link on link.parent_account_id = session.parent_account_id and link.unlinked_at is null
  join app.member_orders orders on orders.member_id = link.member_id
  where session.token_hash = p_token_hash and session.revoked_at is null and session.expires_at > now_utc
    and orders.id = p_order_id for update of orders;
  if not found then raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode = '42501'; end if;
  if exists(select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23514';
  end if;

  select * into target_payment from app.payments where idempotency_key = trim(p_idempotency_key) for update;
  if found then
    if target_payment.order_id <> p_order_id then raise exception 'PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if target_payment.status not in ('open', 'pending') then
      raise exception 'PAYMENT_ATTEMPT_NOT_REUSABLE' using errcode = '23514';
    end if;
    if (target_payment.provider_payment_id is null and target_payment.created_at + interval '1 hour' <= now_utc)
      or (target_payment.provider_payment_id is not null and (
        target_payment.checkout_url is null or target_payment.provider_expires_at <= now_utc
      ))
    then raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514'; end if;
    reused := true;
  else
    select * into target_payment from app.payments
    where order_id = p_order_id and method = 'mollie' and status in ('open', 'pending')
    order by created_at desc limit 1 for update;
    if found then
      if (target_payment.provider_payment_id is null and target_payment.created_at + interval '1 hour' <= now_utc)
        or (target_payment.provider_payment_id is not null and (
          target_payment.checkout_url is null or target_payment.provider_expires_at <= now_utc
        ))
      then raise exception 'PAYMENT_ATTEMPT_REVIEW_REQUIRED' using errcode = '23514'; end if;
      reused := true;
    else
      insert into app.payments(order_id, method, status, amount_cents, currency, idempotency_key)
      values(p_order_id, 'mollie', 'open', target_order.amount_due_cents, 'EUR', trim(p_idempotency_key))
      returning * into target_payment;
    end if;
  end if;

  return jsonb_build_object(
    'paymentId', target_payment.id, 'orderId', target_order.id,
    'amountCents', target_order.amount_due_cents, 'currency', 'EUR',
    'status', target_payment.status::text, 'providerPaymentId', target_payment.provider_payment_id,
    'checkoutUrl', target_payment.checkout_url, 'reused', reused,
    'idempotencyKey', target_payment.idempotency_key,
    'metadata', jsonb_build_object(
      'payment_id', target_payment.id, 'order_id', target_order.id,
      'member_id', target_order.member_id, 'season_id', target_order.season_id, 'schema_version', 1
    )
  );
end;
$$;

create or replace function app.reconcile_mollie_payment(
  p_event_key text,
  p_provider_id text,
  p_local_payment_id uuid,
  p_metadata_payment_id uuid,
  p_order_id uuid,
  p_member_id uuid,
  p_season_id uuid,
  p_amount_cents integer,
  p_currency text,
  p_status app.payment_status,
  p_provider_created_at timestamptz,
  p_provider_updated_at timestamptz,
  p_provider_expires_at timestamptz,
  p_paid_at timestamptz,
  p_refunded_at timestamptz,
  p_expected_qr_version integer,
  p_token_hash text,
  p_validation_issue text default null,
  p_observation jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare existing_event private.payment_events%rowtype; issue text; safe_observation jsonb; result jsonb;
begin
  if length(trim(p_event_key)) not between 8 and 240 or jsonb_typeof(coalesce(p_observation, '{}'::jsonb)) <> 'object' then
    raise exception 'INVALID_PAYMENT_EVENT' using errcode = '22023';
  end if;
  select * into existing_event from private.payment_events where idempotency_key = trim(p_event_key);
  if found then
    return jsonb_build_object('paymentId', existing_event.payment_id, 'status', 'replay',
      'effect', 'event_replay', 'eventType', existing_event.event_type);
  end if;
  if not exists(select 1 from app.payments where id = p_local_payment_id) then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_validation_issue is not null and p_validation_issue not in (
    'MOLLIE_METADATA_INVALID', 'MOLLIE_METADATA_MISSING', 'MOLLIE_METADATA_SCHEMA_INVALID'
  ) then raise exception 'INVALID_VALIDATION_ISSUE' using errcode = '22023'; end if;
  issue := case
    when p_validation_issue is not null then p_validation_issue
    when p_metadata_payment_id is null then 'MOLLIE_METADATA_MISSING'
    when p_metadata_payment_id <> p_local_payment_id then 'MOLLIE_METADATA_PAYMENT_MISMATCH'
    else null end;
  safe_observation := jsonb_strip_nulls(jsonb_build_object(
    'provider_id', left(trim(p_provider_id), 160), 'status', p_status::text,
    'amount_cents', p_amount_cents, 'currency', left(coalesce(p_currency, ''), 3),
    'provider_created_at', p_provider_created_at, 'provider_updated_at', p_provider_updated_at,
    'provider_expires_at', p_provider_expires_at,
    'schema_version', case when (p_observation->>'schema_version') ~ '^[0-9]+$'
      then (p_observation->>'schema_version')::integer else null end
  ));
  if issue is not null then
    update app.payments set reconciliation_issue = issue, reconciled_at = timezone('utc', now())
    where id = p_local_payment_id;
    insert into private.payment_events(payment_id, event_type, provider_payload_redacted, idempotency_key)
    values(p_local_payment_id, 'mismatch', safe_observation || jsonb_build_object('issue', issue), trim(p_event_key))
    on conflict(idempotency_key) do nothing;
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
    values(null, 'payment.mollie.manual_review', 'payment', p_local_payment_id,
      jsonb_build_object('issue', issue, 'provider_status', p_status::text));
    return jsonb_build_object('paymentId', p_local_payment_id, 'status', 'manual_review',
      'effect', 'mismatch', 'issue', issue);
  end if;
  result := app.reconcile_mollie_payment(
    p_event_key, p_provider_id, p_local_payment_id, p_order_id, p_member_id, p_season_id,
    p_amount_cents, p_currency, p_status, p_provider_created_at, p_provider_updated_at,
    p_provider_expires_at, p_paid_at, p_refunded_at, p_expected_qr_version, p_token_hash, p_observation
  );
  return result;
end;
$$;

revoke execute on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text, jsonb
) from service_role;
revoke all on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text, text, jsonb
) from public, anon, authenticated;
grant execute on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text, text, jsonb
) to service_role;

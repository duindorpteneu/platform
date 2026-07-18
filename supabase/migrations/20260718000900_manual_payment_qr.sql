create or replace function app.record_manual_payment_with_qr(
  p_order_id uuid,
  p_method app.payment_method,
  p_idempotency_key text,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  payment_result jsonb;
  active_version integer;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_QR_TOKEN' using errcode = '22023';
  end if;

  payment_result := app.record_manual_payment(p_order_id, p_method, p_idempotency_key);

  select version into active_version
  from private.qr_tokens
  where order_id = p_order_id and active = true
  limit 1;

  if active_version is null then
    perform app.store_order_qr(p_order_id, p_token_hash, 1);
    active_version := 1;
  end if;

  perform app.refresh_order_status(p_order_id);
  return payment_result || jsonb_build_object('qrStatus', 'active', 'qrVersion', active_version);
end;
$$;

revoke execute on function app.record_manual_payment(uuid, app.payment_method, text) from authenticated;
revoke all on function app.record_manual_payment_with_qr(uuid, app.payment_method, text, text) from public, anon;
grant execute on function app.record_manual_payment_with_qr(uuid, app.payment_method, text, text) to authenticated;

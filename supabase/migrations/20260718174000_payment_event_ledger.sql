create table private.payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references app.payments(id) on delete restrict,
  event_type text not null check (event_type in (
    'observed', 'paid', 'duplicate_paid', 'refunded', 'stale_ignored',
    'terminal_ignored', 'replay', 'mismatch'
  )),
  provider_payload_redacted jsonb not null default '{}'::jsonb,
  processed_at timestamptz not null default timezone('utc', now()),
  idempotency_key text not null unique check (length(idempotency_key) between 8 and 240),
  check (not (provider_payload_redacted ?| array['email','recipient','name','member_name','token','token_hash','qr_token','qr_hash','checkout_url']))
);

create index payment_events_payment_processed_idx on private.payment_events(payment_id, processed_at desc);
alter table private.payment_events enable row level security;
revoke all on private.payment_events from public, anon, authenticated;

alter function app.reconcile_mollie_payment(
  text, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text
) rename to reconcile_mollie_payment_core;

revoke all on function app.reconcile_mollie_payment_core(
  text, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text
) from public, anon, authenticated, service_role;

create or replace function app.reconcile_mollie_payment(
  p_event_key text,
  p_provider_id text,
  p_local_payment_id uuid,
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
  p_observation jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  existing_event private.payment_events%rowtype;
  event_type text;
  safe_observation jsonb;
  issue text;
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

  safe_observation := jsonb_strip_nulls(jsonb_build_object(
    'provider_id', left(trim(p_provider_id), 160),
    'status', p_status::text,
    'amount_cents', p_amount_cents,
    'currency', left(coalesce(p_currency, ''), 3),
    'provider_created_at', p_provider_created_at,
    'provider_updated_at', p_provider_updated_at,
    'provider_expires_at', p_provider_expires_at,
    'schema_version', case when (p_observation->>'schema_version') ~ '^[0-9]+$'
      then (p_observation->>'schema_version')::integer else null end
  ));

  begin
    result := app.reconcile_mollie_payment_core(
      p_provider_id, p_local_payment_id, p_order_id, p_member_id, p_season_id,
      p_amount_cents, p_currency, p_status, p_provider_created_at, p_provider_updated_at,
      p_provider_expires_at, p_paid_at, p_refunded_at, p_expected_qr_version, p_token_hash
    );
  exception
    when sqlstate '23514' or sqlstate '22023' or sqlstate '40001' then
      issue := sqlerrm;
      if issue not in (
        'PAYMENT_METADATA_MISMATCH', 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH',
        'INVALID_MOLLIE_RECONCILIATION', 'INVALID_QR_TOKEN', 'QR_VERSION_CONFLICT', 'QR_ALREADY_ACTIVE'
      ) then raise; end if;
      update app.payments set reconciliation_issue = left(issue, 500), reconciled_at = timezone('utc', now())
      where id = p_local_payment_id;
      insert into private.payment_events(payment_id, event_type, provider_payload_redacted, idempotency_key)
      values(p_local_payment_id, 'mismatch', safe_observation || jsonb_build_object('issue', issue), trim(p_event_key))
      on conflict(idempotency_key) do nothing;
      insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
      values(null, 'payment.mollie.manual_review', 'payment', p_local_payment_id,
        jsonb_build_object('issue', issue, 'provider_status', p_status::text));
      return jsonb_build_object('paymentId', p_local_payment_id, 'status', 'manual_review',
        'effect', 'mismatch', 'issue', issue);
  end;

  event_type := case result->>'effect'
    when 'paid' then 'paid'
    when 'duplicate_paid' then 'duplicate_paid'
    when 'refunded' then 'refunded'
    when 'stale_ignored' then 'stale_ignored'
    when 'terminal_ignored' then 'terminal_ignored'
    when 'already_processed' then 'replay'
    else 'observed' end;
  insert into private.payment_events(payment_id, event_type, provider_payload_redacted, idempotency_key)
  values(p_local_payment_id, event_type, safe_observation, trim(p_event_key))
  on conflict(idempotency_key) do nothing;
  return result || jsonb_build_object('eventType', event_type);
end;
$$;

revoke all on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text, jsonb
) from public, anon, authenticated;
grant execute on function app.reconcile_mollie_payment(
  text, text, uuid, uuid, uuid, uuid, integer, text, app.payment_status,
  timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text, jsonb
) to service_role;

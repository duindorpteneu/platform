create or replace function app.claim_email_jobs(p_claim_token uuid, p_limit integer)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb; safe_limit integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);
  with candidates as (
    select id from private.email_jobs
    where status in ('queued', 'retry') and attempts < 5 and available_at <= timezone('utc', now())
    order by available_at, created_at
    for update skip locked limit safe_limit
  ), claimed as (
    update private.email_jobs job set status = 'processing', attempts = attempts + 1,
      claim_token = p_claim_token, claimed_at = timezone('utc', now()), updated_at = timezone('utc', now())
    from candidates where job.id = candidates.id returning job.*
  )
  select jsonb_build_object('claimToken', p_claim_token, 'jobs', coalesce(jsonb_agg(jsonb_build_object(
    'id', claimed.id, 'kind', claimed.kind, 'recipientEmail', claimed.recipient_email,
    'templateKey', claimed.template_key, 'subjectSource', template.subject_source,
    'bodySource', template.body_source, 'allowedShortcodes', template.allowed_shortcodes,
    'orderId', claimed.order_id, 'payload', claimed.payload, 'attempt', claimed.attempts
  ) order by claimed.created_at), '[]'::jsonb)) into result
  from claimed left join app.email_templates template on template.id = claimed.template_id;
  return result;
end;
$$;

create or replace function app.complete_email_job(
  p_job_id uuid, p_claim_token uuid, p_outcome text,
  p_provider_message_id text default null, p_error text default null
)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare target_job private.email_jobs%rowtype; final_status text; next_available timestamptz;
begin
  if p_outcome not in ('sent', 'retry', 'failed') then
    raise exception 'INVALID_EMAIL_JOB_OUTCOME' using errcode = '22023';
  end if;
  select * into target_job from private.email_jobs
  where id = p_job_id and status = 'processing' and claim_token = p_claim_token for update;
  if not found then raise exception 'EMAIL_JOB_CLAIM_CONFLICT' using errcode = '40001'; end if;
  if p_outcome = 'sent' and (p_provider_message_id is null or length(trim(p_provider_message_id)) not between 3 and 240) then
    raise exception 'EMAIL_PROVIDER_MESSAGE_REQUIRED' using errcode = '22023';
  end if;
  final_status := case when p_outcome = 'retry' and target_job.attempts >= 5 then 'failed' else p_outcome end;
  next_available := case when final_status = 'retry' then timezone('utc', now())
    + interval '1 minute' * power(2, least(target_job.attempts - 1, 6)) else target_job.available_at end;
  update private.email_jobs set status = final_status,
    provider_message_id = case when final_status = 'sent' then trim(p_provider_message_id) else provider_message_id end,
    sent_at = case when final_status = 'sent' then timezone('utc', now()) else sent_at end,
    completed_at = case when final_status in ('sent', 'failed') then timezone('utc', now()) else null end,
    available_at = next_available, last_error = case when final_status = 'sent' then null else nullif(left(trim(p_error), 1000), '') end,
    claim_token = null, claimed_at = null, updated_at = timezone('utc', now())
  where id = target_job.id;
  return jsonb_build_object('jobId', target_job.id, 'status', final_status,
    'attempts', target_job.attempts, 'availableAt', next_available);
exception when unique_violation then
  raise exception 'EMAIL_PROVIDER_MESSAGE_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.record_sendgrid_events(p_events jsonb)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare item record; target_job_id uuid; inserted_count integer := 0; ignored_count integer := 0; affected integer;
begin
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'INVALID_SENDGRID_EVENTS' using errcode = '22023';
  end if;
  for item in select * from jsonb_to_recordset(p_events)
    as event_data(event_id text, provider_message_id text, event_type text, occurred_at timestamptz)
  loop
    if item.event_id is null or item.provider_message_id is null or item.occurred_at is null
      or item.event_type not in ('delivered', 'bounced', 'deferred', 'dropped', 'failed')
    then ignored_count := ignored_count + 1; continue; end if;
    select id into target_job_id from private.email_jobs
    where provider_message_id = item.provider_message_id;
    if target_job_id is null then ignored_count := ignored_count + 1; continue; end if;
    insert into app.email_events(email_job_id, provider_event_id, provider_message_id, event_type, occurred_at)
    values(target_job_id, left(item.event_id, 240), item.provider_message_id, item.event_type, item.occurred_at)
    on conflict(provider_event_id) do nothing;
    get diagnostics affected = row_count;
    if affected = 1 then
      inserted_count := inserted_count + 1;
      update private.email_jobs set delivery_status = item.event_type, updated_at = timezone('utc', now())
      where id = target_job_id;
    else ignored_count := ignored_count + 1;
    end if;
  end loop;
  return jsonb_build_object('recorded', inserted_count, 'ignored', ignored_count);
end;
$$;

create or replace function app.record_manual_payment_with_qr_trusted(
  p_actor_id uuid, p_order_id uuid, p_method app.payment_method,
  p_idempotency_key text, p_token_hash text
)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare target_order app.member_orders%rowtype; payment_id uuid; qr_version integer;
begin
  if p_actor_id is null or not exists(
    select 1 from app.staff_profiles where auth_user_id = p_actor_id and active = true
      and role in ('beheerder', 'kledingcommissie')
  ) then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  if p_method not in ('cash', 'card') or length(trim(p_idempotency_key)) not between 8 and 160
    or p_token_hash !~ '^[0-9a-f]{64}$'
  then raise exception 'INVALID_MANUAL_PAYMENT' using errcode = '22023'; end if;
  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if exists(select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23505';
  end if;
  insert into app.payments(order_id, method, status, amount_cents, idempotency_key, paid_at)
  values(p_order_id, p_method, 'paid', target_order.amount_due_cents, trim(p_idempotency_key), timezone('utc', now()))
  returning id into payment_id;
  select coalesce(max(version), 0) + 1 into qr_version from private.qr_tokens where order_id = p_order_id;
  insert into private.qr_tokens(order_id, token_hash, version, created_by)
  values(p_order_id, p_token_hash, qr_version, p_actor_id);
  perform private.enqueue_order_email(p_order_id, 'payment_received',
    'transaction:payment_received:' || payment_id::text);
  perform app.refresh_order_status(p_order_id);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'payment.manual.recorded', 'member_order', p_order_id,
    jsonb_build_object('payment_id', payment_id, 'method', p_method::text, 'amount_cents', target_order.amount_due_cents));
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'qr.created', 'member_order', p_order_id, jsonb_build_object('version', qr_version));
  return jsonb_build_object('paymentId', payment_id, 'status', 'paid', 'amountCents', target_order.amount_due_cents,
    'method', p_method::text, 'qrStatus', 'active', 'qrVersion', qr_version);
end;
$$;

create or replace function app.reserve_order_lines(p_receipt_line_id uuid, p_order_line_ids uuid[])
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid(); receipt_line app.delivery_receipt_lines%rowtype; requested integer; consumed integer;
  selected_quantity integer; line_id uuid; line_record app.order_lines%rowtype; affected_order_ids uuid[] := '{}';
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  requested := coalesce(array_length(p_order_line_ids, 1), 0);
  if requested = 0 or requested <> (select count(distinct value) from unnest(p_order_line_ids) value) then
    raise exception 'INVALID_RESERVATION_SELECTION' using errcode = '22023'; end if;
  select * into receipt_line from app.delivery_receipt_lines where id = p_receipt_line_id for update;
  if not found then raise exception 'RECEIPT_LINE_NOT_FOUND' using errcode = 'P0002'; end if;
  select coalesce(sum(quantity), 0) into consumed from app.inventory_reservations
  where receipt_line_id = p_receipt_line_id and status in ('reserved', 'fulfilled');
  select coalesce(sum(quantity), 0) into selected_quantity from app.order_lines where id = any(p_order_line_ids);
  if receipt_line.received_quantity - consumed < selected_quantity then raise exception 'INSUFFICIENT_STOCK' using errcode = '23514'; end if;
  foreach line_id in array p_order_line_ids loop
    select * into line_record from app.order_lines where id = line_id for update;
    if not found or line_record.article_variant_id <> receipt_line.article_variant_id or line_record.status <> 'backorder' then
      raise exception 'ORDER_LINE_NOT_RESERVABLE' using errcode = '23514'; end if;
    insert into app.inventory_reservations(receipt_line_id, order_line_id, quantity, actor_user_id)
    values(p_receipt_line_id, line_record.id, line_record.quantity, actor);
    update app.order_lines set status = 'ready_for_pickup', updated_at = timezone('utc', now()) where id = line_record.id;
    if not line_record.order_id = any(affected_order_ids) then affected_order_ids := array_append(affected_order_ids, line_record.order_id); end if;
  end loop;
  foreach line_id in array affected_order_ids loop
    perform app.refresh_order_status(line_id);
    perform private.enqueue_order_email(line_id, 'ready_for_pickup',
      'transaction:ready_for_pickup:' || p_receipt_line_id::text || ':' || line_id::text);
  end loop;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, 'stock.lines.reserved', 'delivery_receipt_line', p_receipt_line_id,
    jsonb_build_object('order_line_ids', p_order_line_ids));
  return jsonb_build_object('reservedLines', requested);
end;
$$;

revoke all on function private.enqueue_order_email(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.prepare_mollie_payment(text, uuid, text) from public, anon, authenticated;
revoke all on function app.bind_mollie_payment(uuid, text, text, app.payment_status, timestamptz) from public, anon, authenticated;
revoke all on function app.get_mollie_reconciliation_context(text) from public, anon, authenticated;
revoke all on function app.reconcile_mollie_payment(text, uuid, uuid, uuid, uuid, integer, text, app.payment_status, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text) from public, anon, authenticated;
revoke all on function app.claim_email_jobs(uuid, integer) from public, anon, authenticated;
revoke all on function app.complete_email_job(uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function app.record_sendgrid_events(jsonb) from public, anon, authenticated;
revoke all on function app.get_email_workspace() from public, anon;
revoke all on function app.create_email_bulk(text, uuid[], text) from public, anon;
revoke all on function app.update_email_template(uuid, text, text, integer) from public, anon;
revoke all on function app.record_manual_payment_with_qr_trusted(uuid, uuid, app.payment_method, text, text) from public, anon, authenticated;
revoke all on function app.reserve_order_lines(uuid, uuid[]) from public, anon;

grant execute on function private.enqueue_order_email(uuid, text, text, uuid) to service_role;
grant execute on function public.prepare_mollie_payment(text, uuid, text) to service_role;
grant execute on function app.bind_mollie_payment(uuid, text, text, app.payment_status, timestamptz) to service_role;
grant execute on function app.get_mollie_reconciliation_context(text) to service_role;
grant execute on function app.reconcile_mollie_payment(text, uuid, uuid, uuid, uuid, integer, text, app.payment_status, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, integer, text) to service_role;
grant execute on function app.claim_email_jobs(uuid, integer) to service_role;
grant execute on function app.complete_email_job(uuid, uuid, text, text, text) to service_role;
grant execute on function app.record_sendgrid_events(jsonb) to service_role;
grant execute on function app.get_email_workspace() to authenticated;
grant execute on function app.create_email_bulk(text, uuid[], text) to authenticated;
grant execute on function app.update_email_template(uuid, text, text, integer) to authenticated;
grant execute on function app.record_manual_payment_with_qr_trusted(uuid, uuid, app.payment_method, text, text) to service_role;
grant execute on function app.reserve_order_lines(uuid, uuid[]) to authenticated;

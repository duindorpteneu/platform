alter table app.email_batches drop constraint email_batches_selected_count_check;
alter table app.email_batches add constraint email_batches_selected_count_check
check (selected_count between 1 and 2000);

create or replace function app.reconcile_mollie_payment(
  p_provider_id text, p_local_payment_id uuid, p_order_id uuid, p_member_id uuid, p_season_id uuid,
  p_amount_cents integer, p_currency text, p_status app.payment_status,
  p_provider_created_at timestamptz, p_provider_updated_at timestamptz, p_provider_expires_at timestamptz,
  p_paid_at timestamptz, p_refunded_at timestamptz,
  p_expected_qr_version integer, p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_payment app.payments%rowtype;
  target_order app.member_orders%rowtype;
  primary_payment_id uuid;
  current_qr_version integer;
  resulting_status app.payment_status;
  effect text := 'updated';
  was_primary_paid boolean;
begin
  if length(trim(p_provider_id)) not between 3 and 160 or p_status = 'duplicate_paid'
    or p_provider_updated_at is null
  then raise exception 'INVALID_MOLLIE_RECONCILIATION' using errcode = '22023'; end if;

  select * into target_payment from app.payments
  where id = p_local_payment_id and provider_payment_id = trim(p_provider_id) for update;
  if not found then raise exception 'PAYMENT_METADATA_MISMATCH' using errcode = '23514'; end if;
  select * into target_order from app.member_orders where id = target_payment.order_id for update;
  if target_order.id <> p_order_id or target_order.member_id <> p_member_id or target_order.season_id <> p_season_id then
    raise exception 'PAYMENT_METADATA_MISMATCH' using errcode = '23514';
  end if;
  if target_payment.method <> 'mollie' or target_payment.amount_cents <> p_amount_cents
    or target_order.amount_due_cents <> p_amount_cents or p_currency <> 'EUR' or target_payment.currency <> 'EUR'
  then raise exception 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH' using errcode = '23514'; end if;

  if target_payment.provider_updated_at is not null and p_provider_updated_at < target_payment.provider_updated_at then
    return jsonb_build_object('paymentId', target_payment.id, 'orderId', target_order.id,
      'status', target_payment.status::text, 'effect', 'stale_ignored');
  end if;

  if p_status = 'paid' then
    if target_payment.status = 'paid' then
      effect := 'already_processed';
    elsif target_payment.status = 'refunded' then
      effect := 'terminal_ignored';
    else
      select id into primary_payment_id from app.payments
      where order_id = target_order.id and status = 'paid' and id <> target_payment.id
      order by paid_at, created_at limit 1 for update;
      if primary_payment_id is not null then
        update app.payments set status = 'duplicate_paid', paid_at = coalesce(paid_at, p_paid_at, p_provider_updated_at),
          provider_created_at = coalesce(provider_created_at, p_provider_created_at),
          provider_updated_at = p_provider_updated_at, provider_expires_at = p_provider_expires_at,
          reconciled_at = timezone('utc', now()), reconciliation_issue = 'duplicate paid payment; manual reconciliation required'
        where id = target_payment.id;
        effect := 'duplicate_paid';
      else
        if p_token_hash !~ '^[0-9a-f]{64}$' or p_expected_qr_version is null or p_expected_qr_version < 0 then
          raise exception 'INVALID_QR_TOKEN' using errcode = '22023';
        end if;
        select coalesce(max(version), 0) into current_qr_version
        from private.qr_tokens where order_id = target_order.id;
        if current_qr_version <> p_expected_qr_version then
          raise exception 'QR_VERSION_CONFLICT' using errcode = '40001';
        end if;
        if exists(select 1 from private.qr_tokens where order_id = target_order.id and active) then
          raise exception 'QR_ALREADY_ACTIVE' using errcode = '23514';
        end if;
        update app.payments set status = 'paid', paid_at = coalesce(paid_at, p_paid_at, p_provider_updated_at),
          provider_created_at = coalesce(provider_created_at, p_provider_created_at),
          provider_updated_at = p_provider_updated_at, provider_expires_at = p_provider_expires_at,
          reconciled_at = timezone('utc', now()), reconciliation_issue = null
        where id = target_payment.id;
        insert into private.qr_tokens(order_id, token_hash, version)
        values(target_order.id, p_token_hash, current_qr_version + 1);
        perform private.enqueue_order_email(target_order.id, 'payment_received',
          'transaction:payment_received:' || target_payment.id::text);
        perform app.refresh_order_status(target_order.id);
        insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
        values(null, 'payment.mollie.paid', 'member_order', target_order.id,
          jsonb_build_object('payment_id', target_payment.id, 'amount_cents', target_order.amount_due_cents,
            'qr_version', current_qr_version + 1));
        effect := 'paid';
      end if;
    end if;
  elsif p_status = 'refunded' then
    if target_payment.status = 'refunded' then
      effect := 'already_processed';
    else
      was_primary_paid := target_payment.status = 'paid';
      update app.payments set status = 'refunded', refunded_at = coalesce(refunded_at, p_refunded_at, p_provider_updated_at),
        provider_created_at = coalesce(provider_created_at, p_provider_created_at),
        provider_updated_at = p_provider_updated_at, provider_expires_at = p_provider_expires_at,
        reconciled_at = timezone('utc', now()),
        reconciliation_issue = case when target_payment.status = 'duplicate_paid' then 'duplicate payment refunded' else null end
      where id = target_payment.id;
      if was_primary_paid then
        update private.qr_tokens set active = false, revoked_at = coalesce(revoked_at, timezone('utc', now())),
          revocation_reason = coalesce(revocation_reason, 'Mollie payment refunded')
        where order_id = target_order.id and active;
        perform app.refresh_order_status(target_order.id);
      end if;
      insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
      values(null, 'payment.mollie.refunded', 'member_order', target_order.id,
        jsonb_build_object('payment_id', target_payment.id, 'qr_blocked', was_primary_paid));
      effect := 'refunded';
    end if;
  else
    if target_payment.status in ('paid', 'refunded') then
      effect := 'terminal_ignored';
    else
      update app.payments set status = p_status,
        provider_created_at = coalesce(provider_created_at, p_provider_created_at),
        provider_updated_at = p_provider_updated_at, provider_expires_at = p_provider_expires_at,
        reconciled_at = timezone('utc', now()) where id = target_payment.id;
    end if;
  end if;

  select status into resulting_status from app.payments where id = target_payment.id;
  if effect in ('already_processed', 'terminal_ignored') then
    update app.payments set provider_updated_at = greatest(coalesce(provider_updated_at, p_provider_updated_at), p_provider_updated_at),
      reconciled_at = timezone('utc', now()) where id = target_payment.id;
  end if;
  return jsonb_build_object('paymentId', target_payment.id, 'orderId', target_order.id,
    'status', resulting_status::text, 'effect', effect);
end;
$$;

create or replace function app.get_email_workspace()
returns jsonb
language plpgsql stable security definer
set search_path = app, private, pg_temp
as $$
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'templateKeys', array['verification_code','payment_request','payment_received','ready_for_pickup','payment_reminder','qr_code_resent'],
    'templates', coalesce((select jsonb_agg(jsonb_build_object(
      'id', template.id, 'key', template.template_key, 'subjectSource', template.subject_source,
      'bodySource', template.body_source, 'allowedShortcodes', template.allowed_shortcodes,
      'active', template.active, 'version', template.version, 'updatedAt', template.updated_at
    ) order by template.template_key) from app.email_templates template), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(jsonb_build_object(
      'id', batch.id, 'batchKey', batch.batch_key, 'templateKey', template.template_key,
      'selectedCount', batch.selected_count, 'createdAt', batch.created_at
    ) order by batch.created_at desc)
      from (select * from app.email_batches order by created_at desc limit 25) batch
      join app.email_templates template on template.id = batch.template_id), '[]'::jsonb),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object(
      'id', job.id, 'orderId', job.order_id, 'templateKey', job.template_key,
      'status', job.status, 'attempts', job.attempts, 'deliveryStatus', job.delivery_status,
      'availableAt', job.available_at, 'sentAt', job.sent_at, 'createdAt', job.created_at
    ) order by job.created_at desc) from (select * from private.email_jobs where order_id is not null order by created_at desc limit 100) job), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object(
      'orderId', orders.id, 'memberName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'relationNumber', member.relation_number, 'team', member.team, 'season', season.name,
      'amountDueCents', orders.amount_due_cents,
      'paymentReminderEligible', not exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'),
      'readyForPickupEligible', exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid')
        and exists(select 1 from app.order_lines line where line.order_id = orders.id and line.status = 'ready_for_pickup'),
      'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'orderLineId', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.id)
        from app.order_lines line join app.articles article on article.id = line.article_id
        where line.order_id = orders.id and line.status <> 'cancelled'), '[]'::jsonb)
    ) order by member.last_name, member.first_name)
      from app.member_orders orders
      join app.members member on member.id = orders.member_id and member.active_for_season
      join app.seasons season on season.id = orders.season_id
      join app.app_settings settings on settings.id = true and settings.active_season_id = orders.season_id), '[]'::jsonb)
  );
end;
$$;

create or replace function app.update_email_template(
  p_template_id uuid, p_subject_source text, p_body_source text, p_expected_version integer
)
returns jsonb
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); target app.email_templates%rowtype; token text; combined text;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(trim(p_subject_source)) not between 3 and 180 or p_subject_source ~ E'[\r\n]'
    or length(trim(p_body_source)) not between 10 and 10000
    or p_subject_source ~ '[<>]' or p_body_source ~ '[<>]'
    or lower(p_subject_source || ' ' || p_body_source) ~ 'javascript[[:space:]]*:'
  then raise exception 'INVALID_EMAIL_TEMPLATE_SOURCE' using errcode = '22023'; end if;
  select * into target from app.email_templates where id = p_template_id for update;
  if not found then raise exception 'EMAIL_TEMPLATE_NOT_FOUND' using errcode = 'P0002'; end if;
  if target.version <> p_expected_version then raise exception 'EMAIL_TEMPLATE_VERSION_CONFLICT' using errcode = '40001'; end if;
  combined := p_subject_source || E'\n' || p_body_source;
  for token in select distinct match[1] from regexp_matches(combined, '\{\{([a-z_]+)\}\}', 'g') as match loop
    if not ('{{' || token || '}}') = any(target.allowed_shortcodes) then
      raise exception 'EMAIL_TEMPLATE_SHORTCODE_NOT_ALLOWED' using errcode = '22023';
    end if;
  end loop;
  if regexp_replace(combined, '\{\{[a-z_]+\}\}', '', 'g') ~ '(\{\{|\}\})' then
    raise exception 'EMAIL_TEMPLATE_SHORTCODE_NOT_ALLOWED' using errcode = '22023';
  end if;
  update app.email_templates set subject_source = trim(p_subject_source), body_source = trim(p_body_source),
    version = version + 1, updated_by = actor where id = target.id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, 'email.template.updated', 'email_template', target.id,
    jsonb_build_object('template_key', target.template_key, 'version_before', target.version, 'version_after', target.version + 1));
  return jsonb_build_object('templateId', target.id, 'templateKey', target.template_key, 'version', target.version + 1);
end;
$$;

create or replace function app.create_email_bulk(p_template_key text, p_order_ids uuid[], p_batch_key text)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid(); target_template app.email_templates%rowtype; target_batch app.email_batches%rowtype;
  requested_count integer; eligible_count integer; selection_hash text; order_id uuid; inserted_batch boolean := false;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  requested_count := coalesce(array_length(p_order_ids, 1), 0);
  if p_template_key not in ('payment_reminder', 'ready_for_pickup') or requested_count not between 1 and 2000
    or requested_count <> (select count(distinct value) from unnest(p_order_ids) value)
    or length(trim(p_batch_key)) not between 8 and 160
  then raise exception 'INVALID_EMAIL_BULK' using errcode = '22023'; end if;
  select * into target_template from app.email_templates where template_key = p_template_key and active for share;
  if not found then raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514'; end if;
  perform 1 from app.member_orders where id = any(p_order_ids) order by id for update;
  select count(*) into eligible_count from app.member_orders orders
  where orders.id = any(p_order_ids) and (
    (p_template_key = 'payment_reminder' and not exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'))
    or (p_template_key = 'ready_for_pickup'
      and exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid')
      and exists(select 1 from app.order_lines line where line.order_id = orders.id and line.status = 'ready_for_pickup'))
  );
  if eligible_count <> requested_count then raise exception 'EMAIL_BULK_SELECTION_NOT_ELIGIBLE' using errcode = '23514'; end if;
  select md5(string_agg(value::text, ',' order by value)) into selection_hash from unnest(p_order_ids) value;
  insert into app.email_batches(batch_key, template_id, selection_hash, selected_count, actor_user_id)
  values(trim(p_batch_key), target_template.id, selection_hash, requested_count, actor)
  on conflict(batch_key) do nothing returning * into target_batch;
  if found then inserted_batch := true;
  else
    select * into target_batch from app.email_batches where batch_key = trim(p_batch_key) for update;
    if target_batch.template_id <> target_template.id or target_batch.selection_hash <> selection_hash then
      raise exception 'EMAIL_BATCH_KEY_CONFLICT' using errcode = '23505';
    end if;
  end if;
  foreach order_id in array p_order_ids loop
    perform private.enqueue_order_email(order_id, p_template_key,
      'bulk:' || trim(p_batch_key) || ':' || p_template_key || ':' || order_id::text, target_batch.id);
  end loop;
  if inserted_batch then
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
    values(actor, 'email.bulk.created', 'email_batch', target_batch.id,
      jsonb_build_object('template_key', p_template_key, 'selected_count', requested_count));
  end if;
  return jsonb_build_object('batchId', target_batch.id, 'templateKey', p_template_key,
    'jobCount', requested_count, 'reused', not inserted_batch);
end;
$$;

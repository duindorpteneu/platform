create or replace function app.create_season(
  p_name text,
  p_starts_on date,
  p_ends_on date,
  p_default_amount_cents integer,
  p_make_active boolean default true,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target_id uuid;
  normalized_name text := trim(p_name);
begin
  actor := private.require_admin_aal2();
  if length(normalized_name) not between 1 and 120
    or p_default_amount_cents is null or p_default_amount_cents not between 0 and 10000000
    or (p_starts_on is not null and p_ends_on is not null and p_starts_on > p_ends_on)
  then
    raise exception 'SEASON_INPUT_INVALID' using errcode = '22023';
  end if;

  insert into app.seasons(name, starts_on, ends_on, default_amount_cents, status, opened_at)
  values(normalized_name, p_starts_on, p_ends_on, p_default_amount_cents, 'open', timezone('utc', now()))
  returning id into target_id;

  if coalesce(p_make_active, false) or not exists(
    select 1 from app.app_settings where id = true and active_season_id is not null
  ) then
    update app.app_settings
    set active_season_id = target_id, updated_at = timezone('utc', now())
    where id = true;
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'season.created', 'season', target_id, jsonb_build_object(
    'madeActive', coalesce(p_make_active, false),
    'hasStartDate', p_starts_on is not null,
    'hasEndDate', p_ends_on is not null,
    'defaultAmountCents', p_default_amount_cents
  ), p_correlation_id);

  return app.get_settings_workspace();
exception when unique_violation then
  raise exception 'SEASON_NAME_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.get_catalog_seasons()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', season.id,
      'name', season.name,
      'status', season.status,
      'active', season.id = settings.active_season_id
    ) order by (season.id = settings.active_season_id) desc, season.starts_on desc nulls last, season.name)
    from app.seasons season
    cross join app.app_settings settings
    where settings.id = true
  ), '[]'::jsonb);
end;
$$;

create or replace function app.bulk_set_article_season(
  p_season_id uuid,
  p_article_ids uuid[],
  p_linked boolean,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  requested_count integer := coalesce(array_length(p_article_ids, 1), 0);
  changed_count integer := 0;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_season_id is null or p_linked is null or requested_count not between 1 and 500
    or requested_count <> (select count(distinct article_id) from unnest(p_article_ids) article_id)
  then
    raise exception 'ARTICLE_SEASON_SELECTION_INVALID' using errcode = '22023';
  end if;
  if not exists(select 1 from app.seasons where id = p_season_id and status = 'open') then
    raise exception 'SEASON_NOT_OPEN' using errcode = '23514';
  end if;
  if (select count(*) from app.articles where id = any(p_article_ids)) <> requested_count then
    raise exception 'ARTICLE_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_linked then
    insert into app.article_seasons(article_id, season_id)
    select article_id, p_season_id from unnest(p_article_ids) article_id
    on conflict(article_id, season_id) do nothing;
  else
    delete from app.article_seasons
    where season_id = p_season_id and article_id = any(p_article_ids);
  end if;
  get diagnostics changed_count = row_count;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor,
    case when p_linked then 'catalog.article_seasons.bulk_linked' else 'catalog.article_seasons.bulk_unlinked' end,
    'season', p_season_id,
    jsonb_build_object('requestedCount', requested_count, 'changedCount', changed_count),
    p_correlation_id
  );
  return jsonb_build_object(
    'seasonId', p_season_id,
    'linked', p_linked,
    'requestedCount', requested_count,
    'changedCount', changed_count
  );
end;
$$;

create or replace function app.set_member_active_for_season(
  p_member_id uuid,
  p_active boolean,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target app.members%rowtype;
  normalized_reason text := trim(p_reason);
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_member_id is null or p_active is null or length(normalized_reason) not between 3 and 240 then
    raise exception 'MEMBER_STATUS_INPUT_INVALID' using errcode = '22023';
  end if;
  select * into target from app.members where id = p_member_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;

  update app.members set active_for_season = p_active where id = p_member_id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, case when p_active then 'member.activated' else 'member.deactivated' end,
    'member', p_member_id, jsonb_build_object(
      'activeBefore', target.active_for_season,
      'activeAfter', p_active,
      'reason', normalized_reason
    ), p_correlation_id);
  return jsonb_build_object('memberId', p_member_id, 'activeForSeason', p_active);
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
  select orders.* into target_order
  from app.member_orders orders
  join app.members member on member.id = orders.member_id and member.active_for_season = true
  where orders.id = p_order_id for update of orders;
  if not found then raise exception 'MEMBER_NOT_ACTIVE' using errcode = '23514'; end if;
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
  join app.members member on member.id = link.member_id and member.active_for_season = true
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

revoke all on function app.create_season(text,date,date,integer,boolean,uuid) from public, anon;
revoke all on function app.get_catalog_seasons() from public, anon;
revoke all on function app.bulk_set_article_season(uuid,uuid[],boolean,uuid) from public, anon;
revoke all on function app.set_member_active_for_season(uuid,boolean,text,uuid) from public, anon;
grant execute on function app.create_season(text,date,date,integer,boolean,uuid) to authenticated;
grant execute on function app.get_catalog_seasons() to authenticated;
grant execute on function app.bulk_set_article_season(uuid,uuid[],boolean,uuid) to authenticated;
grant execute on function app.set_member_active_for_season(uuid,boolean,text,uuid) to authenticated;

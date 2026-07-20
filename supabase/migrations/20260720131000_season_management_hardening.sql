create or replace function app.audit_category(p_action text)
returns text
language sql
immutable
set search_path = app, pg_temp
as $$
  select case
    when p_action ~ '^(member|import)\.' then 'members'
    when p_action ~ '^order\.' then 'orders'
    when p_action ~ '^payment\.' then 'payments'
    when p_action ~ '^(stock|inventory|delivery|reservation|catalog)\.' then 'inventory'
    when p_action ~ '^(qr|fulfilment)\.' then 'fulfilment'
    when p_action ~ '^(email|export)\.' then 'communications'
    when p_action ~ '^(settings|staff|season)\.' then 'settings'
    when p_action ~ '^(auth|parent|security)\.' then 'security'
    else 'security'
  end;
$$;

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
    or p_make_active is null
    or (p_starts_on is not null and p_ends_on is not null and p_starts_on > p_ends_on)
  then
    raise exception 'SEASON_INPUT_INVALID' using errcode = '22023';
  end if;

  insert into app.seasons(name, starts_on, ends_on, default_amount_cents, status, opened_at)
  values(normalized_name, p_starts_on, p_ends_on, p_default_amount_cents, 'open', timezone('utc', now()))
  returning id into target_id;

  if p_make_active then
    update app.app_settings
    set active_season_id = target_id, updated_at = timezone('utc', now())
    where id = true;
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'season.created', 'season', target_id, jsonb_build_object(
    'madeActive', p_make_active,
    'hasStartDate', p_starts_on is not null,
    'hasEndDate', p_ends_on is not null,
    'defaultAmountCents', p_default_amount_cents
  ), p_correlation_id);

  return app.get_settings_workspace();
exception when unique_violation then
  raise exception 'SEASON_NAME_EXISTS' using errcode = '23505';
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
    jsonb_build_object(
      'articleIds', to_jsonb(p_article_ids),
      'requestedCount', requested_count,
      'changedCount', changed_count
    ),
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

create or replace function app.enforce_new_payment_eligibility()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
begin
  if not exists(
    select 1
    from app.member_orders orders
    join app.members member on member.id = orders.member_id and member.active_for_season = true
    join app.app_settings settings on settings.id = true and settings.active_season_id = orders.season_id
    join app.seasons season on season.id = orders.season_id and season.status = 'open'
    where orders.id = new.order_id
  ) then
    raise exception 'ORDER_SEASON_NOT_ACTIVE' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists payments_enforce_new_eligibility on app.payments;
create trigger payments_enforce_new_eligibility
before insert on app.payments
for each row execute function app.enforce_new_payment_eligibility();

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
  join app.app_settings settings on settings.id = true and settings.active_season_id = orders.season_id
  join app.seasons season on season.id = orders.season_id and season.status = 'open'
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

revoke all on function app.enforce_new_payment_eligibility() from public, anon, authenticated;

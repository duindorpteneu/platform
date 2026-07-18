alter table app.payments
  add column checkout_url text,
  add column provider_expires_at timestamptz,
  add column provider_created_at timestamptz,
  add column provider_updated_at timestamptz,
  add column reconciled_at timestamptz,
  add column refunded_at timestamptz,
  add column reconciliation_issue text;

alter table app.payments
  add constraint payments_checkout_url_https check (checkout_url is null or checkout_url ~ '^https://'),
  add constraint payments_reconciliation_issue_length check (reconciliation_issue is null or length(reconciliation_issue) <= 500);

create index payments_order_attempts_idx on app.payments(order_id, created_at desc);

create table app.email_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique check (template_key in (
    'verification_code', 'payment_request', 'payment_received',
    'ready_for_pickup', 'payment_reminder', 'qr_code_resent'
  )),
  subject_source text not null check (length(subject_source) between 3 and 180),
  body_source text not null check (length(body_source) between 10 and 10000),
  allowed_shortcodes text[] not null,
  active boolean not null default true,
  version integer not null default 1 check (version > 0),
  updated_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  check (array_length(allowed_shortcodes, 1) is not null)
);

create trigger email_templates_touch_updated_at before update on app.email_templates
for each row execute function app.touch_updated_at();

insert into app.email_templates(template_key, subject_source, body_source, allowed_shortcodes)
values
  ('verification_code', 'Uw verificatiecode voor {{clubnaam}}',
    'Gebruik de verificatiecode uit dit beveiligde bericht om in te loggen bij {{clubnaam}}. Deel deze code niet.',
    array['{{clubnaam}}','{{contact_email}}']),
  ('payment_request', 'Betalingsverzoek tenue {{volledige_naam}}',
    'Beste {{voornaam}}, betaal het vaste bedrag van {{bedrag}} voor seizoen {{seizoen}} via {{betaallink}}. Vragen? {{contact_email}}',
    array['{{voornaam}}','{{volledige_naam}}','{{team}}','{{relatienummer}}','{{seizoen}}','{{bedrag}}','{{betaallink}}','{{clubnaam}}','{{contact_email}}']),
  ('payment_received', 'Betaling ontvangen voor {{volledige_naam}}',
    'De betaling van {{bedrag}} voor seizoen {{seizoen}} is ontvangen. Bewaar toegang tot het ledenportaal voor de actuele tenue-status.',
    array['{{voornaam}}','{{volledige_naam}}','{{team}}','{{relatienummer}}','{{seizoen}}','{{bedrag}}','{{qr_code}}','{{artikelen_af_te_halen}}','{{artikelen_nalevering}}','{{afhaallocatie}}','{{clubnaam}}','{{contact_email}}']),
  ('ready_for_pickup', 'Tenue-artikelen af te halen voor {{volledige_naam}}',
    'De volgende artikelen zijn af te halen: {{artikelen_af_te_halen}}. Nalevering: {{artikelen_nalevering}}. Locatie: {{afhaallocatie}}.',
    array['{{voornaam}}','{{volledige_naam}}','{{team}}','{{relatienummer}}','{{seizoen}}','{{qr_code}}','{{artikelen_af_te_halen}}','{{artikelen_nalevering}}','{{afhaallocatie}}','{{clubnaam}}','{{contact_email}}']),
  ('payment_reminder', 'Herinnering betaling tenue {{volledige_naam}}',
    'Voor {{volledige_naam}} staat nog {{bedrag}} open voor seizoen {{seizoen}}. Betalen kan via {{betaallink}}.',
    array['{{voornaam}}','{{volledige_naam}}','{{team}}','{{relatienummer}}','{{seizoen}}','{{bedrag}}','{{betaallink}}','{{clubnaam}}','{{contact_email}}']),
  ('qr_code_resent', 'QR-code tenue {{volledige_naam}}',
    'Hierbij ontvangt u opnieuw de QR-code voor {{volledige_naam}}: {{qr_code}}. Deel deze code niet.',
    array['{{voornaam}}','{{volledige_naam}}','{{team}}','{{relatienummer}}','{{seizoen}}','{{qr_code}}','{{clubnaam}}','{{contact_email}}']);

create table app.email_batches (
  id uuid primary key default gen_random_uuid(),
  batch_key text not null unique check (length(batch_key) between 8 and 160),
  template_id uuid not null references app.email_templates(id) on delete restrict,
  selection_hash text not null check (selection_hash ~ '^[0-9a-f]{32}$'),
  selected_count integer not null check (selected_count between 1 and 500),
  actor_user_id uuid not null,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.email_jobs
  add column order_id uuid references app.member_orders(id) on delete restrict,
  add column template_id uuid references app.email_templates(id) on delete restrict,
  add column batch_id uuid references app.email_batches(id) on delete restrict,
  add column idempotency_key text,
  add column provider_message_id text,
  add column delivery_status text,
  add column claim_token uuid,
  add column claimed_at timestamptz,
  add column completed_at timestamptz,
  add column updated_at timestamptz not null default timezone('utc', now());

alter table private.email_jobs drop constraint email_jobs_status_check;
alter table private.email_jobs
  add constraint email_jobs_status_check check (status in ('queued', 'processing', 'retry', 'sent', 'failed')),
  add constraint email_jobs_attempts_limit check (attempts between 0 and 5),
  add constraint email_jobs_idempotency_length check (idempotency_key is null or length(idempotency_key) between 8 and 240),
  add constraint email_jobs_delivery_status_check check (delivery_status is null or delivery_status in ('delivered', 'bounced', 'deferred', 'dropped', 'failed'));

drop index private.email_jobs_queue_idx;
create index email_jobs_queue_idx on private.email_jobs(available_at, created_at)
where status in ('queued', 'retry') and attempts < 5;
create unique index email_jobs_idempotency_idx on private.email_jobs(idempotency_key) where idempotency_key is not null;
create unique index email_jobs_provider_message_idx on private.email_jobs(provider_message_id) where provider_message_id is not null;
create index email_jobs_batch_idx on private.email_jobs(batch_id, created_at) where batch_id is not null;

create table app.email_events (
  id bigint generated always as identity primary key,
  email_job_id uuid not null references private.email_jobs(id) on delete restrict,
  provider_event_id text not null unique check (length(provider_event_id) between 1 and 240),
  provider_message_id text not null,
  event_type text not null check (event_type in ('delivered', 'bounced', 'deferred', 'dropped', 'failed')),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default timezone('utc', now())
);

create index email_events_job_occurred_idx on app.email_events(email_job_id, occurred_at desc);

alter table app.email_templates enable row level security;
alter table app.email_batches enable row level security;
alter table app.email_events enable row level security;
alter table private.email_jobs enable row level security;

revoke all on app.email_templates, app.email_batches, app.email_events from public, anon, authenticated;
revoke all on private.email_jobs from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;

create or replace function private.enqueue_order_email(
  p_order_id uuid,
  p_template_key text,
  p_idempotency_key text,
  p_batch_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_template app.email_templates%rowtype;
  job_id uuid;
  target_email text;
  message_payload jsonb;
begin
  if length(trim(p_idempotency_key)) not between 8 and 240 then
    raise exception 'INVALID_EMAIL_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  select * into target_template from app.email_templates
  where template_key = p_template_key and active = true;
  if not found then raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514'; end if;

  select lower(trim(member.email)), jsonb_build_object(
    'orderId', orders.id,
    'memberId', member.id,
    'firstName', member.first_name,
    'fullName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
    'team', member.team,
    'relationNumber', member.relation_number,
    'season', season.name,
    'amountCents', orders.amount_due_cents,
    'clubName', settings.club_name,
    'contactEmail', settings.contact_email,
    'pickupLocation', settings.pickup_location,
    'qrVersion', (select token.version from private.qr_tokens token where token.order_id = orders.id and token.active limit 1),
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderLineId', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.id)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status <> 'cancelled'
    ), '[]'::jsonb),
    'articlesReady', coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderLineId', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.id)
      from app.order_lines line join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status = 'ready_for_pickup'
    ), '[]'::jsonb),
    'articlesBackorder', coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderLineId', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.id)
      from app.order_lines line join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status = 'backorder'
    ), '[]'::jsonb)
  ) into target_email, message_payload
  from app.member_orders orders
  join app.members member on member.id = orders.member_id
  join app.seasons season on season.id = orders.season_id
  cross join app.app_settings settings
  where orders.id = p_order_id and settings.id = true;
  if not found or target_email is null or target_email !~ '^[^[:space:]@]+@[^[:space:]@]+$' then
    raise exception 'ORDER_EMAIL_NOT_AVAILABLE' using errcode = '23514';
  end if;

  insert into private.email_jobs(
    kind, recipient_email, template_key, template_id, order_id, batch_id,
    idempotency_key, payload, status, available_at
  ) values (
    case when p_batch_id is null then 'transactional' else 'bulk' end,
    target_email, target_template.template_key, target_template.id, p_order_id, p_batch_id,
    trim(p_idempotency_key), message_payload, 'queued', timezone('utc', now())
  ) on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning id into job_id;

  if job_id is null then
    select id into job_id from private.email_jobs where idempotency_key = trim(p_idempotency_key);
  end if;
  return job_id;
end;
$$;

create or replace function public.prepare_mollie_payment(
  p_token_hash text,
  p_order_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  target_payment app.payments%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' or length(trim(p_idempotency_key)) not between 8 and 160 then
    raise exception 'INVALID_PAYMENT_REQUEST' using errcode = '22023';
  end if;
  select orders.* into target_order
  from private.parent_sessions session
  join private.parent_member_links link on link.parent_account_id = session.parent_account_id and link.unlinked_at is null
  join app.member_orders orders on orders.member_id = link.member_id
  where session.token_hash = p_token_hash and session.revoked_at is null and session.expires_at > now_utc
    and orders.id = p_order_id
  for update of orders;
  if not found then raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode = '42501'; end if;
  if exists(select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23514';
  end if;

  select * into target_payment from app.payments where idempotency_key = trim(p_idempotency_key);
  if found then
    if target_payment.order_id <> p_order_id then raise exception 'PAYMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if target_payment.status not in ('open', 'pending')
      or coalesce(target_payment.provider_expires_at, target_payment.created_at + interval '30 minutes') <= now_utc
    then raise exception 'PAYMENT_ATTEMPT_NOT_REUSABLE' using errcode = '23514'; end if;
  else
    select * into target_payment from app.payments
    where order_id = p_order_id and method = 'mollie' and status in ('open', 'pending')
      and coalesce(provider_expires_at, created_at + interval '30 minutes') > now_utc
    order by created_at desc limit 1 for update;
    if not found then
      insert into app.payments(order_id, method, status, amount_cents, currency, idempotency_key)
      values(p_order_id, 'mollie', 'open', target_order.amount_due_cents, 'EUR', trim(p_idempotency_key))
      returning * into target_payment;
    end if;
  end if;

  return jsonb_build_object(
    'paymentId', target_payment.id, 'orderId', target_order.id,
    'amountCents', target_order.amount_due_cents, 'currency', 'EUR',
    'status', target_payment.status::text, 'providerPaymentId', target_payment.provider_payment_id,
    'checkoutUrl', target_payment.checkout_url,
    'reused', target_payment.idempotency_key <> trim(p_idempotency_key) or target_payment.created_at < now_utc,
    'idempotencyKey', target_payment.idempotency_key,
    'metadata', jsonb_build_object(
      'payment_id', target_payment.id, 'order_id', target_order.id,
      'member_id', target_order.member_id, 'season_id', target_order.season_id, 'schema_version', 1
    )
  );
end;
$$;

create or replace function app.bind_mollie_payment(
  p_payment_id uuid,
  p_provider_id text,
  p_checkout_url text,
  p_status app.payment_status,
  p_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare target_payment app.payments%rowtype;
begin
  if length(trim(p_provider_id)) not between 3 and 160 or p_checkout_url !~ '^https://'
    or p_status not in ('open', 'pending')
  then raise exception 'INVALID_MOLLIE_BINDING' using errcode = '22023'; end if;
  select * into target_payment from app.payments where id = p_payment_id for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if target_payment.method <> 'mollie' or target_payment.status not in ('open', 'pending') then
    raise exception 'PAYMENT_NOT_BINDABLE' using errcode = '23514';
  end if;
  if target_payment.provider_payment_id is not null and target_payment.provider_payment_id <> trim(p_provider_id) then
    raise exception 'PAYMENT_PROVIDER_CONFLICT' using errcode = '23505';
  end if;
  update app.payments set provider_payment_id = trim(p_provider_id), checkout_url = trim(p_checkout_url),
    status = p_status, provider_expires_at = p_expires_at, provider_updated_at = timezone('utc', now())
  where id = p_payment_id;
  return jsonb_build_object('paymentId', p_payment_id, 'providerPaymentId', trim(p_provider_id), 'status', p_status::text);
exception when unique_violation then
  raise exception 'PAYMENT_PROVIDER_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.get_mollie_reconciliation_context(p_provider_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb;
begin
  select jsonb_build_object(
    'paymentId', payment.id, 'providerPaymentId', payment.provider_payment_id,
    'paymentStatus', payment.status::text, 'amountCents', payment.amount_cents, 'currency', payment.currency,
    'orderId', orders.id, 'memberId', orders.member_id, 'seasonId', orders.season_id,
    'amountDueCents', orders.amount_due_cents,
    'qrVersion', coalesce((select max(token.version) from private.qr_tokens token where token.order_id = orders.id), 0),
    'activeQrVersion', (select token.version from private.qr_tokens token where token.order_id = orders.id and token.active limit 1)
  ) into result
  from app.payments payment join app.member_orders orders on orders.id = payment.order_id
  where payment.provider_payment_id = trim(p_provider_id);
  if result is null then raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002'; end if;
  return result;
end;
$$;

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  '275a0000-0000-4000-8000-000000000001',
  'Projectiehardening beheerder',
  'beheerder'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"275a0000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_back_in_stock as
select app.save_mail_template_draft_v1(
  'back_in_stock',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'back_in_stock'
      and status = 'draft'
  ),
  'Weer op voorraad',
  'Pakketregel beschikbaar voor {{member_first_name}}',
  'De gereserveerde pakketregel kan worden afgehaald.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Beste "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"ready_items"}},
      {"type":"protectedBlock","attrs":{"kind":"pickup_location"}}
    ]
  }'::jsonb,
  '<p>De gereserveerde pakketregel kan worden afgehaald.</p>',
  'De gereserveerde pakketregel kan worden afgehaald.',
  null
) result;
select app.publish_mail_template_revision_v1(
  (saved.result->>'revisionId')::uuid,
  saved.result->>'contentHash',
  '275e0000-0000-4000-8000-000000000001'
)
from saved_back_in_stock saved;
reset role;

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', statement_timestamp() - interval '1 hour')
on conflict (key) do update set activated_at = excluded.activated_at;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

insert into app.articles(id, name, code, sort_order, active)
select
  (
    '275a10'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'Projectiehardening product ' || scenario,
  'PROJ-HARD-' || lpad(scenario::text, 2, '0'),
  274 + scenario,
  true
from generate_series(1, 10) scenario;
insert into app.article_seasons(article_id, season_id)
select
  article.id,
  settings.active_season_id
from app.articles article
cross join app.app_settings settings
where settings.id = true
  and article.code like 'PROJ-HARD-%';
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
)
select
  (
    '275a11'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a10'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'M',
  'PROJ-HARD-' || lpad(scenario::text, 2, '0') || '-M',
  1,
  true
from generate_series(1, 10) scenario;

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  '275a1200-0000-4000-8000-000000000001',
  'PROJ-HARD-001',
  'Robin',
  'Projectie',
  'projectie-hardening@example.invalid',
  'JO15-1'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  '275a1300-0000-4000-8000-000000000001',
  '275a1200-0000-4000-8000-000000000001',
  settings.active_season_id,
  10000
from app.app_settings settings
where settings.id = true;

insert into app.order_lines(id, order_id, article_variant_id)
select
  (
    '275a14'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  '275a1300-0000-4000-8000-000000000001',
  (
    '275a11'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid
from generate_series(1, 10) scenario;

insert into private.parent_accounts(id, email_normalized)
values(
  '275a1500-0000-4000-8000-000000000001',
  'projectie-hardening@example.invalid'
);
insert into private.parent_portal_grants(
  id,
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  granted_by,
  granted_at
)
select
  '275a1600-0000-4000-8000-000000000001',
  member_season.id,
  'projectie-hardening@example.invalid',
  '275a1500-0000-4000-8000-000000000001',
  'active',
  'administrator',
  '275a0000-0000-4000-8000-000000000001',
  statement_timestamp()
from app.member_seasons member_season
where member_season.member_id =
  '275a1200-0000-4000-8000-000000000001';

insert into app.inventory_allocations(
  id,
  season_id,
  member_id,
  member_season_id,
  order_id,
  order_line_id,
  article_id,
  article_variant_id,
  quantity,
  status,
  reconciliation_status,
  allocation_mode,
  paid_at,
  size_valid_at,
  priority_at,
  product_name_snapshot,
  size_snapshot,
  allocated_at
)
select
  (
    '275a20'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  orders.season_id,
  orders.member_id,
  orders.member_season_id,
  orders.id,
  (
    '275a14'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a10'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a11'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  1,
  'reserved',
  'resolved',
  'fifo',
  statement_timestamp() - interval '2 hours',
  statement_timestamp() - interval '1 hour',
  statement_timestamp() - interval '1 hour',
  'Projectiehardening product ' || scenario,
  'M',
  statement_timestamp() - interval '30 minutes'
from generate_series(1, 10) scenario
cross join app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';

alter table app.inventory_allocation_events
  disable trigger inventory_allocation_events_mail_v2;
insert into app.inventory_allocation_events(
  id,
  allocation_id,
  event_type,
  next_status,
  reason_code,
  source_type,
  source_id,
  idempotency_key,
  safe_context
)
select
  (
    '275a30'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a20'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'reserved',
  'reserved',
  'projection_hardening.reserved',
  'projection_hardening_test',
  '275a0000-0000-4000-8000-000000000001',
  repeat(to_hex(scenario), 64),
  '{}'::jsonb
from generate_series(1, 10) scenario;
alter table app.inventory_allocation_events
  enable trigger inventory_allocation_events_mail_v2;

update app.order_lines
set status = 'ready_for_pickup',
    updated_at = statement_timestamp()
where order_id = '275a1300-0000-4000-8000-000000000001';

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  '275e1000-0000-4000-8000-000000000001',
  '275a1300-0000-4000-8000-000000000001',
  'cash',
  'paid',
  10000,
  'projection-hardening-paid',
  statement_timestamp() - interval '4 hours'
);
insert into private.release_cutovers(key)
values('allocation_qr_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key in ('allocation_qr_v2', 'scanner_pwa_v2');
select app.register_order_qr_locator(
  '275a1300-0000-4000-8000-000000000001',
  1,
  1,
  repeat('n', 43),
  repeat('9', 64),
  repeat('d', 64),
  '275e1100-0000-4000-8000-000000000001'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  (
    '275a40'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'pickup_ready',
  '275a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  (
    '275a14'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'inventory_allocation_event',
  (
    '275a30'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a3000-0000-4000-8000-'
    || lpad(
      case when scenario = 2 then 1 else scenario end::text,
      12,
      '0'
    )
  )::uuid,
  'projection-hardening:pickup:' || scenario,
  '{}'::jsonb
from generate_series(1, 10) scenario
cross join app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot,
  created_at
)
select
  (
    '275a50'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'out_of_stock',
  '275a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  (
    '275a14'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'mail_campaign',
  (
    '275a5000-0000-4000-8000-'
    || lpad(scenario::text, 12, '0')
  )::uuid,
  (
    '275a5100-0000-4000-8000-'
    || lpad(scenario::text, 12, '0')
  )::uuid,
  'projection-hardening:out-of-stock:' || scenario,
  '{}'::jsonb,
  statement_timestamp() - interval '2 hours'
from (
  values (1), (2), (3), (5), (6), (7), (8), (9), (10)
) selected(scenario)
cross join app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';

select throws_ok(
  format(
    $sql$insert into private.mail_v2_domain_events(
      template_key,
      parent_account_id,
      season_id,
      member_season_id,
      order_id,
      order_line_id,
      source_type,
      source_id,
      idempotency_key,
      payload_snapshot
    )
    select
      'pickup_ready',
      '275a1500-0000-4000-8000-000000000001',
      orders.season_id,
      orders.member_season_id,
      orders.id,
      '275a1402-0000-4000-8000-000000000001',
      'inventory_allocation_event',
      '275a3001-0000-4000-8000-000000000001',
      'projection-hardening:wrong-line',
      '{}'::jsonb
    from app.member_orders orders
    where orders.id = '275a1300-0000-4000-8000-000000000001'$sql$
  ),
  '23514',
  'MAIL_V2_READY_SOURCE_INVALID',
  'een pickup-event met een bron van een andere orderregel wordt bij insert geweigerd'
);
select throws_ok(
  format(
    $sql$insert into private.mail_v2_domain_events(
      template_key,
      parent_account_id,
      season_id,
      member_season_id,
      order_id,
      order_line_id,
      source_type,
      source_id,
      idempotency_key,
      payload_snapshot
    )
    select
      'back_in_stock',
      '275a1500-0000-4000-8000-000000000001',
      orders.season_id,
      orders.member_season_id,
      orders.id,
      '275a1401-0000-4000-8000-000000000001',
      'mail_campaign',
      '275a3001-0000-4000-8000-000000000001',
      'projection-hardening:wrong-source',
      '{}'::jsonb
    from app.member_orders orders
    where orders.id = '275a1300-0000-4000-8000-000000000001'$sql$
  ),
  '23514',
  'MAIL_V2_READY_SOURCE_INVALID',
  'een back-in-stock-event zonder allocation-eventbron wordt bij insert geweigerd'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot,
  created_at
)
select
  (
    '275b'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'pickup_ready',
  '275a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  '275a1409-0000-4000-8000-000000000001',
  'inventory_allocation_event',
  '275a3009-0000-4000-8000-000000000001',
  (
    '275b1000-0000-4000-8000-'
    || lpad(noise::text, 12, '0')
  )::uuid,
  'projection-hardening:failed-noise:' || noise,
  '{}'::jsonb,
  statement_timestamp() - interval '4 hours'
from generate_series(1, 101) noise
cross join app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';

alter table private.email_jobs disable trigger email_jobs_guard_snapshot;
insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  payload,
  status,
  attempts,
  available_at,
  sent_at,
  idempotency_key,
  completed_at,
  context_kind,
  parent_account_id,
  season_id,
  mail_template_revision_id,
  mail_branding_revision_id,
  rendered_subject_snapshot,
  rendered_preheader_snapshot,
  rendered_html_snapshot,
  rendered_text_snapshot,
  from_name_snapshot,
  from_email_snapshot,
  reply_to_email_snapshot,
  render_hash
)
select
  (
    '275a80'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'bulk',
  'projectie-hardening@example.invalid',
  'out_of_stock',
  '{"schemaVersion":1,"eventCount":1}'::jsonb,
  'sent',
  1,
  statement_timestamp() - interval '2 hours',
  statement_timestamp() - interval '90 minutes',
  'projection-hardening:oos-job:' || scenario,
  statement_timestamp() - interval '90 minutes',
  'mail_v2',
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  revision.id,
  branding.id,
  'Tijdelijk niet leverbaar',
  'Voorraadbericht',
  '<p>Tijdelijk niet leverbaar.</p>',
  'Tijdelijk niet leverbaar.',
  branding.from_name,
  branding.from_email,
  branding.reply_to_email,
  repeat(to_hex(scenario), 64)
from (
  values (1), (2), (3), (5), (6), (7), (8), (9), (10)
) selected(scenario)
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'out_of_stock'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id, from_name, from_email, reply_to_email
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;

insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  payload,
  status,
  attempts,
  available_at,
  sent_at,
  last_error,
  idempotency_key,
  delivery_status,
  claim_token,
  claimed_at,
  completed_at,
  uncertain_at,
  context_kind,
  parent_account_id,
  season_id,
  mail_template_revision_id,
  mail_branding_revision_id,
  rendered_subject_snapshot,
  rendered_preheader_snapshot,
  rendered_html_snapshot,
  rendered_text_snapshot,
  from_name_snapshot,
  from_email_snapshot,
  reply_to_email_snapshot,
  render_hash
)
select
  (
    '275a90'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'transactional',
  'projectie-hardening@example.invalid',
  'pickup_ready',
  jsonb_build_object('schemaVersion', 1, 'eventCount',
    case when scenario = 3 then 2 else 1 end),
  case scenario
    when 3 then 'queued'
    when 5 then 'retry'
    when 6 then 'processing'
    when 7 then 'delivery_uncertain'
    when 8 then 'sent'
    when 9 then 'failed'
    when 10 then 'sent'
  end,
  case when scenario in (3, 5) then 0 else 1 end,
  statement_timestamp() - interval '1 hour',
  case when scenario in (8, 10)
    then statement_timestamp() - interval '5 minutes' end,
  case
    when scenario = 5 then 'tijdelijke_fout'
    when scenario = 7 then 'delivery_uncertain'
    when scenario = 9 then 'provider_rejected'
  end,
  'projection-hardening:pickup-job:' || scenario,
  case when scenario = 10 then 'bounced' end,
  case when scenario in (6, 7)
    then (
      '275a9100-0000-4000-8000-'
      || lpad(scenario::text, 12, '0')
    )::uuid end,
  case when scenario in (6, 7)
    then statement_timestamp() - interval '5 minutes' end,
  case when scenario in (8, 9, 10)
    then statement_timestamp() - interval '5 minutes' end,
  case when scenario = 7
    then statement_timestamp() - interval '5 minutes' end,
  'mail_v2',
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  revision.id,
  branding.id,
  'Afhaalklaar',
  'Afhaalbericht',
  '<p>Afhaalklaar.</p>',
  'Afhaalklaar.',
  branding.from_name,
  branding.from_email,
  branding.reply_to_email,
  repeat(to_hex(scenario), 64)
from (
  values (3), (5), (6), (7), (8), (9), (10)
) selected(scenario)
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id, from_name, from_email, reply_to_email
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;

insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  payload,
  status,
  attempts,
  available_at,
  last_error,
  idempotency_key,
  completed_at,
  context_kind,
  parent_account_id,
  season_id,
  mail_template_revision_id,
  mail_branding_revision_id,
  rendered_subject_snapshot,
  rendered_preheader_snapshot,
  rendered_html_snapshot,
  rendered_text_snapshot,
  from_name_snapshot,
  from_email_snapshot,
  reply_to_email_snapshot,
  render_hash,
  created_at,
  updated_at
)
select
  (
    '275c'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  'transactional',
  'projectie-hardening@example.invalid',
  'pickup_ready',
  '{"schemaVersion":1,"eventCount":1}'::jsonb,
  'failed',
  1,
  statement_timestamp() - interval '4 hours',
  'provider_rejected',
  'projection-hardening:failed-noise-job:' || noise,
  statement_timestamp() - interval '4 hours',
  'mail_v2',
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  revision.id,
  branding.id,
  'Afhaalklaar',
  'Afhaalbericht',
  '<p>Afhaalklaar.</p>',
  'Afhaalklaar.',
  branding.from_name,
  branding.from_email,
  branding.reply_to_email,
  lpad(to_hex(noise), 64, '0'),
  statement_timestamp() - interval '4 hours',
  statement_timestamp() - interval '4 hours'
from generate_series(1, 101) noise
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id, from_name, from_email, reply_to_email
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;
alter table private.email_jobs enable trigger email_jobs_guard_snapshot;

insert into private.mail_v2_projection_batches(
  id,
  parent_account_id,
  season_id,
  template_key,
  cohort_id,
  template_revision_id,
  branding_revision_id,
  status,
  email_job_id,
  event_count,
  eligible_event_count,
  eligibility_revision
)
select
  (
    '275a60'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  'out_of_stock',
  (
    '275a5100-0000-4000-8000-'
    || lpad(scenario::text, 12, '0')
  )::uuid,
  revision.id,
  branding.id,
  'queued',
  (
    '275a80'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  1,
  1,
  repeat(to_hex(scenario), 64)
from (
  values (1), (2), (3), (5), (6), (7), (8), (9), (10)
) selected(scenario)
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'out_of_stock'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;
insert into private.mail_v2_projections(event_id, projection_batch_id)
select
  (
    '275a50'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a60'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid
from (
  values (1), (2), (3), (5), (6), (7), (8), (9), (10)
) selected(scenario);

insert into private.mail_v2_projection_batches(
  id,
  parent_account_id,
  season_id,
  template_key,
  cohort_id,
  template_revision_id,
  branding_revision_id,
  status,
  lease_token,
  lease_expires_at,
  event_count
)
select
  '275a7002-0000-4000-8000-000000000001',
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  'pickup_ready',
  '275a3000-0000-4000-8000-000000000002',
  revision.id,
  branding.id,
  'leased',
  '275a7102-0000-4000-8000-000000000001',
  statement_timestamp() + interval '1 hour',
  1
from app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;
insert into private.mail_v2_projections(event_id, projection_batch_id)
values(
  '275a4002-0000-4000-8000-000000000001',
  '275a7002-0000-4000-8000-000000000001'
);

insert into private.mail_v2_projection_batches(
  id,
  parent_account_id,
  season_id,
  template_key,
  cohort_id,
  template_revision_id,
  branding_revision_id,
  status,
  email_job_id,
  retry_count,
  event_count,
  eligible_event_count,
  eligibility_revision
)
select
  (
    '275a70'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  'pickup_ready',
  (
    '275a3000-0000-4000-8000-'
    || lpad(scenario::text, 12, '0')
  )::uuid,
  revision.id,
  branding.id,
  'queued',
  (
    '275a90'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  0,
  case when scenario = 3 then 2 else 1 end,
  case when scenario = 3 then 2 else 1 end,
  repeat(to_hex(scenario), 64)
from (
  values (3), (5), (6), (7), (8), (9), (10)
) selected(scenario)
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;
insert into private.mail_v2_projections(event_id, projection_batch_id)
select
  (
    '275a40'
    || lpad(scenario::text, 2, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275a70'
    || lpad(
      case when scenario = 4 then 3 else scenario end::text,
      2,
      '0'
    )
    || '-0000-4000-8000-000000000001'
  )::uuid
from (
  values (3), (4), (5), (6), (7), (8), (9), (10)
) selected(scenario);

insert into private.mail_v2_projection_batches(
  id,
  parent_account_id,
  season_id,
  template_key,
  cohort_id,
  template_revision_id,
  branding_revision_id,
  status,
  email_job_id,
  event_count,
  eligible_event_count,
  eligibility_revision,
  created_at,
  updated_at
)
select
  (
    '275d'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  '275a1500-0000-4000-8000-000000000001',
  settings.active_season_id,
  'pickup_ready',
  (
    '275b1000-0000-4000-8000-'
    || lpad(noise::text, 12, '0')
  )::uuid,
  revision.id,
  branding.id,
  'queued',
  (
    '275c'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  1,
  1,
  lpad(to_hex(noise), 64, '0'),
  statement_timestamp() - interval '4 hours',
  statement_timestamp() - interval '4 hours'
from generate_series(1, 101) noise
cross join app.app_settings settings
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding
where settings.id = true;
insert into private.mail_v2_projections(event_id, projection_batch_id)
select
  (
    '275b'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid,
  (
    '275d'
    || lpad(to_hex(noise), 4, '0')
    || '-0000-4000-8000-000000000001'
  )::uuid
from generate_series(1, 101) noise;

select is(
  private.reconcile_mail_v2_event_supersessions(),
  5,
  'reconciliatie behandelt alleen veilige unprojected, leased, queued, retry en sent paden'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.template_key = 'back_in_stock'
      and event.idempotency_key like 'back-in-stock-v2:%'
  ),
  4,
  'vier nog niet verzonden pickup-paden leveren exact één back-in-stock-event'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    where suppression.reason = 'superseded_by_back_in_stock'
  ),
  4,
  'uitsluitend de vier vervangen pickup-events worden onderdrukt'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    where suppression.reason =
      'out_of_stock_resolved_by_back_in_stock'
  ),
  4,
  'ieder back-in-stock-event sluit exact het bijbehorende OOS-feit'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    where suppression.reason =
      'out_of_stock_resolved_by_pickup_delivery'
  ),
  1,
  'een al verzonden pickup sluit OOS zonder dubbele back-in-stockmail'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events pickup_event
    join private.mail_v2_event_suppressions suppression
      on suppression.event_id = pickup_event.id
      and suppression.reason = 'superseded_by_back_in_stock'
    join private.mail_v2_domain_events back_event
      on back_event.id = suppression.superseding_event_id
    where pickup_event.template_key = 'pickup_ready'
      and back_event.template_key = 'back_in_stock'
      and back_event.cohort_id = pickup_event.cohort_id
  ),
  4,
  'back-in-stock behoudt het allocationcohort voor gezinsconsolidatie'
);
select is(
  (
    select count(*)::integer
    from private.email_jobs job
    where job.id in (
      '275a9003-0000-4000-8000-000000000001',
      '275a9005-0000-4000-8000-000000000001'
    )
      and job.status = 'superseded'
  ),
  2,
  'queued en retry jobs worden vóór providerclaim niet-foutief geannuleerd'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_projection_batches batch
    where batch.id in (
      '275a7003-0000-4000-8000-000000000001',
      '275a7005-0000-4000-8000-000000000001'
    )
      and batch.status = 'leased'
      and batch.retry_count = 1
      and batch.email_job_id is null
  ),
  2,
  'geannuleerde jobs krijgen een nieuwe projectieversie en idempotentiesleutel'
);
select ok(
  not exists(
    select 1
    from private.mail_v2_event_suppressions suppression
    where suppression.event_id =
      '275a4004-0000-4000-8000-000000000001'
  ),
  'het tweede event in een multi-eventbatch blijft behouden'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    where suppression.event_id in (
      '275a4006-0000-4000-8000-000000000001',
      '275a4007-0000-4000-8000-000000000001',
      '275a4009-0000-4000-8000-000000000001',
      '275a4010-0000-4000-8000-000000000001'
    )
  ),
  0,
  'processing, onzeker, failed en bounced worden nooit automatisch gedupliceerd'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_event_suppressions suppression
    where suppression.event_id::text like '275b%'
  ),
  0,
  'meer dan honderd oudere failures blokkeren of muteren latere actionable events niet'
);
select is(
  private.reconcile_mail_v2_event_supersessions(),
  0,
  'herhaalde reconciliatie is volledig idempotent'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.template_key = 'back_in_stock'
      and event.idempotency_key like 'back-in-stock-v2:%'
  ),
  4,
  'herhaalde reconciliatie maakt geen dubbele back-in-stock-events'
);

set local role service_role;
select app.claim_mail_v2_domain_projections_v1(
  '275a9900-0000-4000-8000-000000000001',
  10
);
reset role;

select is(
  (
    select count(*)::integer
    from private.mail_v2_projection_batches batch
    where batch.template_key = 'back_in_stock'
      and batch.cohort_id =
        '275a3000-0000-4000-8000-000000000001'
      and batch.event_count = 2
  ),
  1,
  'twee gereedgekomen lijnen uit één allocatieronde vormen één back-in-stockbatch'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_projections projection
    join private.mail_v2_domain_events event
      on event.id = projection.event_id
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
    where event.template_key = 'back_in_stock'
      and batch.cohort_id =
        '275a3000-0000-4000-8000-000000000001'
  ),
  2,
  'de geconsolideerde back-in-stockbatch bevat beide concrete events'
);
select is(
  private.mail_v2_event_state(
    '275a4001-0000-4000-8000-000000000001'
  ),
  'terminal',
  'een immutable suppressie maakt het oude pickup-event blijvend terminaal'
);

select set_config('app.inventory_internal', 'on', true);
update app.inventory_allocations
set status = 'released',
    released_at = statement_timestamp(),
    release_reason = 'Regressietest allocatie-episode A vrijgegeven',
    updated_at = statement_timestamp()
where id = '275a2001-0000-4000-8000-000000000001';
update app.order_lines
set status = 'backorder',
    updated_at = statement_timestamp()
where id = '275a1401-0000-4000-8000-000000000001';
select set_config('app.inventory_internal', 'off', true);

insert into app.inventory_allocations(
  id,
  season_id,
  member_id,
  member_season_id,
  order_id,
  order_line_id,
  article_id,
  article_variant_id,
  quantity,
  status,
  reconciliation_status,
  allocation_mode,
  paid_at,
  size_valid_at,
  priority_at,
  product_name_snapshot,
  size_snapshot,
  allocated_at
)
select
  '275a2011-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_id,
  orders.member_season_id,
  orders.id,
  '275a1401-0000-4000-8000-000000000001',
  '275a1001-0000-4000-8000-000000000001',
  '275a1101-0000-4000-8000-000000000001',
  1,
  'reserved',
  'resolved',
  'fifo',
  statement_timestamp() - interval '2 hours',
  statement_timestamp() - interval '1 hour',
  statement_timestamp() - interval '1 hour',
  'Projectiehardening product 1',
  'M',
  statement_timestamp()
from app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';
alter table app.inventory_allocation_events
  disable trigger inventory_allocation_events_mail_v2;
insert into app.inventory_allocation_events(
  id,
  allocation_id,
  event_type,
  next_status,
  reason_code,
  source_type,
  source_id,
  idempotency_key,
  safe_context
) values (
  '275a3011-0000-4000-8000-000000000001',
  '275a2011-0000-4000-8000-000000000001',
  'reserved',
  'reserved',
  'projection_hardening.reallocated',
  'projection_hardening_test',
  '275a0000-0000-4000-8000-000000000001',
  repeat('b', 64),
  '{}'::jsonb
);
alter table app.inventory_allocation_events
  enable trigger inventory_allocation_events_mail_v2;
update app.order_lines
set status = 'ready_for_pickup',
    updated_at = statement_timestamp()
where id = '275a1401-0000-4000-8000-000000000001';
insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '275a4011-0000-4000-8000-000000000001',
  'pickup_ready',
  '275a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  '275a1401-0000-4000-8000-000000000001',
  'inventory_allocation_event',
  '275a3011-0000-4000-8000-000000000001',
  '275a3000-0000-4000-8000-000000000011',
  'projection-hardening:pickup:11',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '275a1300-0000-4000-8000-000000000001';

select is(
  private.mail_v2_allocation_event_is_ready(
    '275a4001-0000-4000-8000-000000000001'
  ),
  false,
  'allocation-event A wordt na vrijgave nooit opnieuw afhaalklaar'
);
select is(
  private.mail_v2_ready_lines(
    '275a4001-0000-4000-8000-000000000001'
  ),
  '[]'::jsonb,
  'de render van oud event A lekt nooit de nieuwe allocatie B'
);
select is(
  private.mail_v2_allocation_event_is_ready(
    '275a4011-0000-4000-8000-000000000001'
  ),
  true,
  'de nieuwe allocation-episode B heeft een eigen geldig pickup-event'
);
select is(
  jsonb_array_length(
    private.mail_v2_ready_lines(
      '275a4011-0000-4000-8000-000000000001'
    )
  ),
  1,
  'alleen event B rendert de actuele harde allocatie'
);

select * from finish();
rollback;

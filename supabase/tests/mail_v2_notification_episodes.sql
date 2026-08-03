begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  '276a0000-0000-4000-8000-000000000001',
  'Episodebeheerder',
  'beheerder'
);
insert into app.articles(id, name, code, sort_order, active)
values(
  '276a1000-0000-4000-8000-000000000001',
  'Episodeproduct',
  'EPISODE-PRODUCT',
  276,
  true
);
insert into app.article_seasons(article_id, season_id)
select
  '276a1000-0000-4000-8000-000000000001',
  settings.active_season_id
from app.app_settings settings
where settings.id = true;
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values (
  '276a1100-0000-4000-8000-000000000001',
  '276a1000-0000-4000-8000-000000000001',
  'M',
  'EPISODE-PRODUCT-M',
  1,
  true
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  '276a1200-0000-4000-8000-000000000001',
  'EPISODE-001',
  'Sam',
  'Episode',
  'episode@example.invalid',
  'JO15-1'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  '276a1300-0000-4000-8000-000000000001',
  '276a1200-0000-4000-8000-000000000001',
  settings.active_season_id,
  10000
from app.app_settings settings
where settings.id = true;
insert into app.order_lines(
  id,
  order_id,
  article_variant_id
) values (
  '276a1400-0000-4000-8000-000000000001',
  '276a1300-0000-4000-8000-000000000001',
  '276a1100-0000-4000-8000-000000000001'
);
insert into private.parent_accounts(id, email_normalized)
values(
  '276a1500-0000-4000-8000-000000000001',
  'episode@example.invalid'
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
  '276a1600-0000-4000-8000-000000000001',
  member_season.id,
  'episode@example.invalid',
  '276a1500-0000-4000-8000-000000000001',
  'active',
  'administrator',
  '276a0000-0000-4000-8000-000000000001',
  statement_timestamp()
from app.member_seasons member_season
where member_season.member_id =
  '276a1200-0000-4000-8000-000000000001';

select ok(
  not has_table_privilege(
    'anon',
    'private.mail_v2_notification_episodes',
    'SELECT'
  )
  and not has_table_privilege(
    'authenticated',
    'private.mail_v2_notification_episodes',
    'SELECT'
  )
  and not has_table_privilege(
    'service_role',
    'private.mail_v2_notification_episodes',
    'SELECT'
  ),
  'episodegegevens zijn voor alle API-rollen default-deny'
);
select ok(
  not has_function_privilege(
    'service_role',
    'private.bind_mail_v2_event_to_episodes(uuid,boolean)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'private.transition_mail_v2_notification_episode(uuid,text,text,text,text,uuid,uuid)',
    'EXECUTE'
  ),
  'interne episodehelpers zijn niet rechtstreeks uitvoerbaar'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a2000-0000-4000-8000-000000000001',
  'size_fill_request',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'mail_campaign',
  '276a2100-0000-4000-8000-000000000001',
  '276a2200-0000-4000-8000-000000000001',
  'episode:size-fill:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a2000-0000-4000-8000-000000000002',
  'size_review_request',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'mail_campaign',
  '276a2100-0000-4000-8000-000000000002',
  '276a2200-0000-4000-8000-000000000002',
  'episode:size-review:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';

select is(
  (
    select count(*)::integer
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'size_confirmation'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
      and episode.status = 'open'
  ),
  1,
  'invullen en controleren blijven één pakketbreed maatproces'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_episode_dispatches dispatch
    join private.mail_v2_notification_episodes episode
      on episode.id = dispatch.episode_id
    where episode.process_key = 'size_confirmation'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
  ),
  2,
  'beide maatsegmenten staan immutable in dezelfde episode'
);
select ok(
  private.mail_v2_campaign_current_episode_exists(
    'size_fill_request',
    '276a1500-0000-4000-8000-000000000001',
    '276a1300-0000-4000-8000-000000000001',
    null
  )
  and private.mail_v2_campaign_current_episode_exists(
    'size_review_request',
    '276a1500-0000-4000-8000-000000000001',
    '276a1300-0000-4000-8000-000000000001',
    null
  ),
  'campagnededupe leest de duurzame open episode'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a2000-0000-4000-8000-000000000003',
  'size_confirmed',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'package_size_confirmation',
  '276a2100-0000-4000-8000-000000000003',
  '276a2200-0000-4000-8000-000000000003',
  'episode:size-confirmed:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'size_confirmation'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
      and episode.episode_number = 1
  ),
  'closed',
  'pakketbrede maatbevestiging sluit de eerste maatepisode'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a2000-0000-4000-8000-000000000004',
  'size_fill_request',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'mail_campaign',
  '276a2100-0000-4000-8000-000000000004',
  '276a2200-0000-4000-8000-000000000004',
  'episode:size-fill:2',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
select is(
  (
    select max(episode.episode_number)
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'size_confirmation'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
  ),
  2,
  'een later opnieuw ontbrekende maat opent aantoonbaar episode twee'
);
select set_config('app.package_size_internal', 'on', true);
insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  member_season_id,
  selection_status,
  selection_source,
  confirmed_at
)
select
  orders.member_id,
  orders.season_id,
  '276a1000-0000-4000-8000-000000000001',
  '276a1100-0000-4000-8000-000000000001',
  orders.member_season_id,
  'confirmed',
  'staff',
  statement_timestamp()
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001'
on conflict (member_id, season_id, article_id) do update
set article_variant_id = excluded.article_variant_id,
    member_season_id = excluded.member_season_id,
    selection_status = excluded.selection_status,
    selection_source = excluded.selection_source,
    raw_value = null,
    member_note = null,
    confirmed_at = excluded.confirmed_at,
    updated_at = statement_timestamp();
select set_config('app.package_size_internal', 'off', true);
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'size_confirmation'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
      and episode.episode_number = 2
  ),
  'closed',
  'een aantoonbaar compleet maatprofiel sluit de herintrede-episode'
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
  '276a3000-0000-4000-8000-000000000001',
  'out_of_stock',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  '276a1400-0000-4000-8000-000000000001',
  'mail_campaign',
  '276a3100-0000-4000-8000-000000000001',
  '276a3200-0000-4000-8000-000000000001',
  'episode:out-of-stock:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
insert into private.mail_v2_event_suppressions(event_id, reason)
values(
  '276a3000-0000-4000-8000-000000000001',
  'eligibility_inactive'
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
  '276a3000-0000-4000-8000-000000000002',
  'out_of_stock',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  '276a1400-0000-4000-8000-000000000001',
  'mail_campaign',
  '276a3100-0000-4000-8000-000000000002',
  '276a3200-0000-4000-8000-000000000002',
  'episode:out-of-stock:2',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
select is(
  (
    select max(episode.episode_number)
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'shortage'
      and episode.scope_id =
        '276a1400-0000-4000-8000-000000000001'
  ),
  2,
  'tekort opgelost en later opnieuw ontstaan krijgt episode twee'
);
insert into app.inventory_movements(
  id,
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  source_type,
  reason_code,
  idempotency_key
)
select
  '276a3300-0000-4000-8000-000000000001',
  settings.active_season_id,
  '276a1000-0000-4000-8000-000000000001',
  '276a1100-0000-4000-8000-000000000001',
  'opening_balance',
  1,
  'episode_test',
  'episode.stock_available',
  repeat('6', 64)
from app.app_settings settings
where settings.id = true;
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'shortage'
      and episode.scope_id =
        '276a1400-0000-4000-8000-000000000001'
      and episode.episode_number = 2
  ),
  'closed',
  'vrije voorraad sluit de concrete tekortepisode'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a4000-0000-4000-8000-000000000001',
  'available_payment_required',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'mail_campaign',
  '276a4100-0000-4000-8000-000000000001',
  '276a4200-0000-4000-8000-000000000001',
  'episode:availability:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
insert into private.mail_v2_event_suppressions(event_id, reason)
values(
  '276a4000-0000-4000-8000-000000000001',
  'retry_exhausted'
);
select is(
  (
    select blocked_reason
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'availability_payment'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
      and episode.status = 'open'
  ),
  'projection_retry_exhausted',
  'uitgeputte projectie blokkeert dezelfde episode en sluit haar niet'
);
select throws_ok(
  format(
    $sql$insert into private.mail_v2_domain_events(
      template_key,
      parent_account_id,
      season_id,
      member_season_id,
      order_id,
      source_type,
      source_id,
      idempotency_key,
      payload_snapshot
    )
    select
      'available_payment_required',
      '276a1500-0000-4000-8000-000000000001',
      orders.season_id,
      orders.member_season_id,
      orders.id,
      'mail_campaign',
      '276a4100-0000-4000-8000-000000000002',
      'episode:availability:blocked',
      '{}'::jsonb
    from app.member_orders orders
    where orders.id =
      '276a1300-0000-4000-8000-000000000001'$sql$
  ),
  '55000',
  'MAIL_V2_NOTIFICATION_EPISODE_BLOCKED',
  'gewone campagne kan een geblokkeerde episode niet omzeilen'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a5000-0000-4000-8000-000000000001',
  'payment_request',
  '276a1500-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  'mail_campaign',
  '276a5100-0000-4000-8000-000000000001',
  '276a5200-0000-4000-8000-000000000001',
  'episode:payment:1',
  '{}'::jsonb
from app.member_orders orders
where orders.id = '276a1300-0000-4000-8000-000000000001';
insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  '276a5300-0000-4000-8000-000000000001',
  '276a1300-0000-4000-8000-000000000001',
  'cash',
  'paid',
  10000,
  'episode-payment-paid',
  statement_timestamp()
);
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'payment'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
  ),
  'closed',
  'geldige betaling sluit betaalverzoekepisode transactioneel'
);
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'availability_payment'
      and episode.scope_id =
        '276a1300-0000-4000-8000-000000000001'
  ),
  'closed',
  'betaling sluit ook de geblokkeerde onbetaalde-voorraadepisode'
);

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  '276a6000-0000-4000-8000-000000000001',
  'portal_access_reminder',
  '276a1500-0000-4000-8000-000000000001',
  member_season.season_id,
  member_season.id,
  'mail_campaign',
  '276a6100-0000-4000-8000-000000000001',
  '276a6200-0000-4000-8000-000000000001',
  'episode:portal-reminder:1',
  '{}'::jsonb
from app.member_seasons member_season
where member_season.member_id =
  '276a1200-0000-4000-8000-000000000001';
update private.parent_accounts
set last_login_at = statement_timestamp()
where id = '276a1500-0000-4000-8000-000000000001';
select is(
  (
    select status
    from private.mail_v2_notification_episodes episode
    where episode.process_key = 'portal_access'
      and episode.parent_account_id =
        '276a1500-0000-4000-8000-000000000001'
  ),
  'closed',
  'ouderlogin sluit de open toegangsepisode'
);

update app.member_seasons
set participation_status = 'inactive',
    updated_at = statement_timestamp()
where member_id = '276a1200-0000-4000-8000-000000000001';
select is(
  (
    select count(*)::integer
    from private.mail_v2_notification_episodes episode
    where episode.parent_account_id =
        '276a1500-0000-4000-8000-000000000001'
      and episode.status = 'open'
  ),
  0,
  'inactief lid-seizoen sluit alle resterende order- en regelprocessen'
);

select throws_ok(
  $$update private.mail_v2_notification_episodes
    set episode_number = 99
    where opening_event_id =
      '276a2000-0000-4000-8000-000000000004'$$,
  '23514',
  'MAIL_V2_EPISODE_INTERNAL_REQUIRED',
  'episode-identiteit kan niet buiten interne lifecycle worden gewijzigd'
);
select throws_ok(
  $$delete from private.mail_v2_episode_dispatches
    where event_id =
      '276a2000-0000-4000-8000-000000000001'$$,
  '23514',
  'MAIL_V2_EPISODE_LEDGER_IMMUTABLE',
  'eventbindingen zijn append-only'
);
select ok(
  not exists(
    select 1
    from private.mail_v2_episode_transitions transition
    where transition.reason_code ~* '(email|token|payload|secret)'
  ),
  'episodetransities bevatten alleen veilige reason codes en identifiers'
);
select is(
  (
    select status
    from private.migration_reconciliations
    where migration_key =
      '20260802276000_mail_v2_notification_episodes'
  ),
  'passed',
  'upgradebackfill heeft een fail-closed reconciliatiebewijs'
);

select * from finish();
rollback;

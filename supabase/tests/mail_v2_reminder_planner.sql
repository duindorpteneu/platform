begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  (
    '27800000-0000-4000-8000-000000000001',
    'Reminderbeheerder',
    'beheerder'
  ),
  (
    '27800000-0000-4000-8000-000000000002',
    'Remindercommissie',
    'kledingcommissie'
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"27800000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

create temporary table payment_request_draft as
select app.save_mail_template_draft_v1(
  'payment_request',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'payment_request'
      and status = 'draft'
  ),
  'Betaalverzoek reminderfixture',
  'Betaalverzoek voor {{member_first_name}}',
  'Betaal {{package_amount}} veilig via {{payment_url}}.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Betaal voor "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"payment_summary"}},
      {"type":"protectedBlock","attrs":{"kind":"payment_action"}}
    ]
  }'::jsonb,
  '<p>Betaal het vaste pakketbedrag veilig.</p>',
  'Betaal het vaste pakketbedrag veilig.',
  null
) result;
select lives_ok(
  format(
    $sql$select app.publish_mail_template_revision_v1(
      %L::uuid,
      %L,
      null
    )$sql$,
    (select result->>'revisionId' from payment_request_draft),
    (select result->>'contentHash' from payment_request_draft)
  ),
  'de initiële betaalmail kan worden gepubliceerd'
);

create temporary table payment_reminder_draft as
select app.save_mail_template_draft_v1(
  'payment_reminder',
  (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'payment_reminder'
      and status = 'draft'
  ),
  'Betalingsherinnering fixture',
  'Herinnering voor {{member_first_name}}',
  'Betaal {{package_amount}} veilig via {{payment_url}}.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Herinnering voor "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"payment_summary"}},
      {"type":"protectedBlock","attrs":{"kind":"payment_action"}}
    ]
  }'::jsonb,
  '<p>Het vaste pakketbedrag staat nog open.</p>',
  'Het vaste pakketbedrag staat nog open.',
  null
) result;
select lives_ok(
  format(
    $sql$select app.publish_mail_template_revision_v1(
      %L::uuid,
      %L,
      null
    )$sql$,
    (select result->>'revisionId' from payment_reminder_draft),
    (select result->>'contentHash' from payment_reminder_draft)
  ),
  'de betalingsherinnering kan worden gepubliceerd'
);
reset role;

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', statement_timestamp() - interval '1 hour')
on conflict (key) do update
set activated_at = excluded.activated_at;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

insert into app.articles(id, name, code, sort_order, active)
values(
  '27810000-0000-4000-8000-000000000001',
  'Reminderbroek',
  'REM-BROEK',
  780,
  true
);
insert into app.article_seasons(article_id, season_id)
select
  '27810000-0000-4000-8000-000000000001',
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
  '27820000-0000-4000-8000-000000000001',
  '27810000-0000-4000-8000-000000000001',
  '152',
  'REM-BROEK-152',
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
  '27830000-0000-4000-8000-000000000001',
  'REM-001',
  'Sofie',
  'Reminder',
  'reminder@example.invalid',
  'JO13-1'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  '27840000-0000-4000-8000-000000000001',
  '27830000-0000-4000-8000-000000000001',
  settings.active_season_id,
  12500
from app.app_settings settings
where settings.id = true;
insert into app.order_lines(
  id,
  order_id,
  article_variant_id
) values (
  '27850000-0000-4000-8000-000000000001',
  '27840000-0000-4000-8000-000000000001',
  '27820000-0000-4000-8000-000000000001'
);
insert into private.parent_accounts(id, email_normalized)
values(
  '27860000-0000-4000-8000-000000000001',
  'reminder@example.invalid'
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
  '27870000-0000-4000-8000-000000000001',
  member_season.id,
  'reminder@example.invalid',
  '27860000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  '27800000-0000-4000-8000-000000000001',
  timestamptz '2026-08-03 08:00:00+00'
from app.member_seasons member_season
where member_season.member_id =
  '27830000-0000-4000-8000-000000000001';

select is(
  (
    select count(*)::integer
    from private.mail_reminder_due_candidates(
      '27880000-0000-4000-8000-000000000001',
      timestamptz '2026-08-03 12:00:00+00'
    )
  ),
  0,
  'een niet-bestaande regel heeft geen doelgroep'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.mail_reminder_rules',
    'SELECT'
  )
  and not has_table_privilege(
    'service_role',
    'private.mail_reminder_runs',
    'SELECT'
  ),
  'regelconfiguratie en runledger zijn default-deny'
);
select ok(
  has_function_privilege(
    'authenticated',
    'app.save_mail_reminder_rule_v1(uuid,uuid,text,integer,jsonb,uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'app.run_due_mail_reminders_v1(timestamptz,integer)',
    'EXECUTE'
  ),
  'alleen de smalle beheer- en scheduler-RPCs zijn bereikbaar'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"27800000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $sql$select app.save_mail_reminder_rule_v1(
      null,
      %L::uuid,
      'payment_reminder',
      null,
      %L::jsonb,
      null
    )$sql$,
    (
      select active_season_id
      from app.app_settings
      where id = true
    ),
    '{
      "internalName":"Commissieregel",
      "firstDelayHours":24,
      "frequencyHours":48,
      "maximumDispatches":3,
      "cooldownHours":24,
      "endAt":"2099-08-31T22:00:00Z",
      "quietStart":"23:00",
      "quietEnd":"06:00"
    }'
  ),
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan de herinneringsplanner niet beheren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"27800000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table saved_rule as
select app.save_mail_reminder_rule_v1(
  null,
  (
    select active_season_id
    from app.app_settings
    where id = true
  ),
  'payment_reminder',
  null,
  '{
    "internalName":"Openstaande pakketbetaling",
    "firstDelayHours":1,
    "frequencyHours":24,
    "maximumDispatches":2,
    "cooldownHours":12,
    "endAt":"2099-08-31T22:00:00Z",
    "quietStart":"23:00",
    "quietEnd":"06:00"
  }'::jsonb,
  '27880000-0000-4000-8000-000000000002'
) result;
select is(
  (select result->>'active' from saved_rule),
  'false',
  'een nieuwe regel is verplicht inactief'
);
select is(
  app.get_mail_reminder_workspace_v1()->>'newRulesDefaultActive',
  'false',
  'workspace maakt de veilige standaard expliciet'
);
select throws_ok(
  $$insert into app.mail_reminder_rules(
    season_id,
    template_key,
    internal_name,
    first_delay_hours,
    frequency_hours,
    maximum_dispatches,
    cooldown_hours,
    end_at,
    quiet_start,
    quiet_end,
    created_by,
    updated_by
  )
  select
    active_season_id,
    'payment_reminder',
    'Direct verboden',
    1,
    24,
    2,
    12,
    timestamptz '2099-08-31 22:00:00+00',
    time '23:00',
    time '06:00',
    '27800000-0000-4000-8000-000000000001',
    '27800000-0000-4000-8000-000000000001'
  from app.app_settings
  where id = true$$,
  '42501',
  null,
  'rechtstreekse tabelmutatie is niet toegestaan'
);
create temporary table active_rule as
select app.set_mail_reminder_rule_active_v1(
  (select (result->>'id')::uuid from saved_rule),
  (select (result->>'revision')::integer from saved_rule),
  true,
  'Planneracceptatie na review',
  '27880000-0000-4000-8000-000000000003'
) result;
select is(
  (select result->>'active' from active_rule),
  'true',
  'AAL2-beheerder kan de gereviewde regel activeren'
);
reset role;

select private.enqueue_mail_v2_member_event(
  'payment_request',
  '27860000-0000-4000-8000-000000000001',
  (
    select id
    from app.member_seasons
    where member_id = '27830000-0000-4000-8000-000000000001'
  ),
  'payment',
  '27840000-0000-4000-8000-000000000001',
  '27890000-0000-4000-8000-000000000001',
  'reminder-initial-payment-request'
);

set local role service_role;
create temporary table initial_projection as
select app.claim_mail_v2_domain_projections_v1(
  '27890000-0000-4000-8000-000000000002',
  10
) result;
reset role;
create temporary table initial_render_hash as
select private.mail_v2_render_hash(
  (
    select (result #>> '{groups,0,groupId}')::uuid
    from initial_projection
  ),
  (
    select result #>> '{groups,0,eligibilityRevision}'
    from initial_projection
  ),
  (
    select (result #>> '{groups,0,template,id}')::uuid
    from initial_projection
  ),
  (
    select (result #>> '{groups,0,branding,id}')::uuid
    from initial_projection
  ),
  'Betaalverzoek',
  'Betaal het pakketbedrag.',
  '<p>Betaal het pakketbedrag.</p>',
  'Betaal het pakketbedrag.'
) render_hash;
grant select on initial_projection, initial_render_hash to service_role;
set local role service_role;
create temporary table initial_finalize as
select app.finalize_mail_v2_domain_projection_v1(
  (
    select (result #>> '{groups,0,groupId}')::uuid
    from initial_projection
  ),
  (
    select (result->>'leaseToken')::uuid
    from initial_projection
  ),
  (
    select result #>> '{groups,0,eligibilityRevision}'
    from initial_projection
  ),
  'Betaalverzoek',
  'Betaal het pakketbedrag.',
  '<p>Betaal het pakketbedrag.</p>',
  'Betaal het pakketbedrag.',
  (select render_hash from initial_render_hash)
) result;
reset role;

update private.email_jobs
set status = 'sent',
    sent_at = timestamptz '2026-08-03 09:00:00+00',
    completed_at = timestamptz '2026-08-03 09:00:00+00',
    updated_at = statement_timestamp()
where id = (
  select (result->>'jobId')::uuid
  from initial_finalize
);

select is(
  (
    select count(*)::integer
    from private.mail_reminder_due_candidates(
      (select (result->>'id')::uuid from active_rule),
      timestamptz '2026-08-03 12:00:00+00'
    )
    where due_at <= timestamptz '2026-08-03 12:00:00+00'
  ),
  1,
  'pas na een werkelijk verzonden initiële mail wordt een reminder verschuldigd'
);

set local role service_role;
select is(
  app.run_due_mail_reminders_v1(
    timestamptz '2026-08-03 23:30:00+02',
    100
  )->>'status',
  'completed',
  'scheduler blijft tijdens quiet hours operationeel beschikbaar'
);
reset role;
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_reminder_rule'
  ),
  0,
  'quiet hours produceren geen e-maildomeinevent'
);

set local role service_role;
create temporary table reminder_run as
select app.run_due_mail_reminders_v1(
  timestamptz '2026-08-03 12:00:00+00',
  100
) result;
reset role;
select is(
  (select result->>'dispatchedCount' from reminder_run),
  '1',
  'buiten quiet hours wordt exact één verschuldigde reminder geproduceerd'
);
select is(
  (select result->>'failedRuleCount' from reminder_run),
  '0',
  'een geldige run bevat geen verborgen regelfout'
);
select is(
  (
    select count(*)::integer
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_reminder_rule'
      and event.template_key = 'payment_reminder'
  ),
  1,
  'reminder gebruikt het gewone immutable domeineventpad'
);
select is(
  (
    select count(distinct event.parent_account_id)::integer
    from private.mail_v2_domain_events event
    where event.source_type = 'mail_reminder_rule'
  ),
  1,
  'reminders blijven per ouderaccount consolideerbaar'
);

set local role service_role;
select is(
  app.run_due_mail_reminders_v1(
    timestamptz '2026-08-03 12:00:00+00',
    100
  )->>'dispatchedCount',
  '0',
  'dezelfde schedulerslot is idempotent'
);
reset role;

select is(
  (
    select count(*)::integer
    from private.mail_reminder_rule_revisions revision
    where revision.rule_id =
      (select (result->>'id')::uuid from active_rule)
  ),
  2,
  'aanmaak en activering blijven als immutable revisies bewaard'
);
select is(
  (
    select status
    from private.migration_reconciliations
    where migration_key = '20260802278000_mail_v2_reminder_planner'
  ),
  'passed',
  'plannerexpand heeft een structureel reconciliatiebewijs'
);
select is(
  (
    app.get_operational_health_v8(
      repeat('a', 64),
      1,
      null,
      null
    ) #>> '{reminderPlanner,failedRunsRecent}'
  ),
  '0',
  'operationele health rapporteert geen recente plannerfout'
);

select * from finish();
rollback;

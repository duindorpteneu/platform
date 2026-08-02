begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(
  not has_table_privilege(
    'authenticated',
    'private.parent_portal_grants',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'browserrollen hebben geen directe granttabelrechten'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'private.parent_access_batches',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'browserrollen hebben geen directe toegangsbatchrechten'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'private.parent_access_batch_items',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'browserrollen hebben geen directe toegangsbatchitemrechten'
);
select ok(
  not has_table_privilege(
    'service_role',
    'private.parent_portal_grants',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role krijgt geen brede directe granttoegang'
);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('ac000000-0000-4000-8000-000000000001', 'Toegangsbeheerder', 'beheerder'),
  ('ac000000-0000-4000-8000-000000000002', 'Toegangscommissie', 'kledingcommissie');

insert into app.seasons(
  id,
  name,
  starts_on,
  ends_on,
  default_amount_cents,
  status,
  opened_at
) values (
  'ac100000-0000-4000-8000-000000000001',
  '2043/2044 toegang',
  '2043-07-01',
  '2044-06-30',
  12500,
  'open',
  timezone('utc', now())
);
update app.app_settings
set active_season_id = 'ac100000-0000-4000-8000-000000000001',
    contact_email = 'kleding@duindorpsv.nl'
where id = true;

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season,
  gender
) values
  ('ac200000-0000-4000-8000-000000000001', 'AC-001', 'Anna', 'Familie', 'gezin@example.invalid', 'JO10-1', true, 'female'),
  ('ac200000-0000-4000-8000-000000000002', 'AC-002', 'Bram', 'Familie', ' GEZIN@example.invalid ', 'JO12-1', true, 'male'),
  ('ac200000-0000-4000-8000-000000000003', 'AC-003', 'Chris', 'Familie', 'gezin@example.invalid', 'JO14-1', true, 'other'),
  ('ac200000-0000-4000-8000-000000000004', 'AC-004', 'Dani', 'Ongeldig', 'geen-adres', 'JO16-1', true, 'unknown');

insert into private.member_sensitive_identity(member_id, date_of_birth) values
  ('ac200000-0000-4000-8000-000000000001', '2013-03-04'),
  ('ac200000-0000-4000-8000-000000000002', '2011-05-06'),
  ('ac200000-0000-4000-8000-000000000003', '2009-07-08'),
  ('ac200000-0000-4000-8000-000000000004', null)
on conflict (member_id) do update
set date_of_birth = excluded.date_of_birth;

insert into app.member_seasons(
  id,
  member_id,
  season_id,
  team_name,
  participation_status,
  reconciliation_status
) values
  ('ac300000-0000-4000-8000-000000000001', 'ac200000-0000-4000-8000-000000000001', 'ac100000-0000-4000-8000-000000000001', 'JO10-1', 'active', 'resolved'),
  ('ac300000-0000-4000-8000-000000000002', 'ac200000-0000-4000-8000-000000000002', 'ac100000-0000-4000-8000-000000000001', 'JO12-1', 'active', 'resolved'),
  ('ac300000-0000-4000-8000-000000000003', 'ac200000-0000-4000-8000-000000000003', 'ac100000-0000-4000-8000-000000000001', 'JO14-1', 'active', 'resolved'),
  ('ac300000-0000-4000-8000-000000000004', 'ac200000-0000-4000-8000-000000000004', 'ac100000-0000-4000-8000-000000000001', 'JO16-1', 'active', 'resolved')
on conflict (member_id, season_id) do update
set id = excluded.id,
    team_name = excluded.team_name,
    participation_status = excluded.participation_status,
    reconciliation_status = excluded.reconciliation_status;

insert into private.parent_accounts(id, email_normalized) values
  ('ac700000-0000-4000-8000-000000000001', 'gezin@example.invalid'),
  ('ac700000-0000-4000-8000-000000000002', 'stale@example.invalid');
insert into private.parent_member_links(
  id,
  parent_account_id,
  member_id
) values (
  'ac710000-0000-4000-8000-000000000001',
  'ac700000-0000-4000-8000-000000000001',
  'ac200000-0000-4000-8000-000000000001'
);
insert into private.parent_sessions(
  parent_account_id,
  token_hash,
  last_seen_at,
  expires_at
) values
  (
    'ac700000-0000-4000-8000-000000000001',
    repeat('8', 64),
    timezone('utc', now()) - interval '1 hour',
    timezone('utc', now()) + interval '1 day'
  ),
  (
    'ac700000-0000-4000-8000-000000000002',
    repeat('9', 64),
    timezone('utc', now()) - interval '1 hour',
    timezone('utc', now()) + interval '1 day'
  );

select is(
  private.parent_access_v2_enabled(),
  false,
  'grantcutover staat na expand standaard uit'
);
select is(
  (select count(*) from public.get_parent_session(repeat('8', 64))),
  1::bigint,
  'bestaande oudersessie blijft vóór cutover rollbackcompatibel'
);
select ok(
  (select last_seen_at > timezone('utc', now()) - interval '1 minute'
    from private.parent_sessions
    where token_hash = repeat('8', 64)),
  'geldige sessiecontrole werkt last_seen begrensd bij'
);
select is(
  (select count(*) from public.get_parent_members(repeat('8', 64))),
  1::bigint,
  'bestaande ouderlink blijft vóór cutover bruikbaar'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_parent_access_workspace(
    'ac100000-0000-4000-8000-000000000001', null, 0, 50
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder op AAL1 kan oudertoegang niet inzien'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.preview_parent_portal_activation(
    'ac100000-0000-4000-8000-000000000001',
    array['ac300000-0000-4000-8000-000000000001']::uuid[]
  )$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan oudertoegang niet activeren'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

create temporary table blocked_cutover as
select app.get_parent_access_cutover_status() result;
select is(
  (select result->>'ready' from blocked_cutover),
  'false',
  'onbeoordeelde legacygrant blokkeert de cutover'
);
select throws_ok(
  $$select app.enable_parent_access_grants_v2(
    (select result->>'revision' from blocked_cutover),
    null
  )$$,
  '23514',
  'PARENT_ACCESS_RECONCILIATION_REQUIRED',
  'cutover kan geen reviewgrant overslaan'
);

select ok(
  app.get_parent_access_workspace(
    'ac100000-0000-4000-8000-000000000001',
    null,
    0,
    50
  )::text not like '%gezin@example.invalid%',
  'ledenlijst retourneert geen volledig ouderadres'
);

create temporary table activation_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000001',
  array[
    'ac300000-0000-4000-8000-000000000001',
    'ac300000-0000-4000-8000-000000000002'
  ]::uuid[]
) result;

select is(
  (select (result->>'eligibleCount')::integer from activation_preview),
  2,
  'twee expliciet geselecteerde kinderen zijn geschikt'
);
select is(
  (select jsonb_array_length(result->'groups') from activation_preview),
  1,
  'gedeeld genormaliseerd adres vormt één preflightgroep'
);
select is(
  (select (result->'groups'->0->>'nonSelectedCount')::integer from activation_preview),
  1,
  'niet-geselecteerd kind wordt alleen als waarschuwing geteld'
);
select is(
  (select jsonb_array_length(result->'groups'->0->'members') from activation_preview),
  2,
  'preflight voegt het niet-geselecteerde kind nooit toe'
);

create temporary table activation_result as
select app.activate_parent_portal_access(
  'ac100000-0000-4000-8000-000000000001',
  array[
    'ac300000-0000-4000-8000-000000000001',
    'ac300000-0000-4000-8000-000000000002'
  ]::uuid[],
  (select result->>'revision' from activation_preview),
  'ac400000-0000-4000-8000-000000000001',
  'ac500000-0000-4000-8000-000000000001'
) result;
reset role;

select is(
  (select (result->>'changedCount')::integer from activation_result),
  2,
  'activatie commit exact de twee geselecteerde grants'
);
select is(
  (select count(*) from private.parent_accounts
    where email_normalized = 'gezin@example.invalid'),
  1::bigint,
  'gedeeld adres krijgt exact één ouderaccount'
);
select is(
  (select count(*) from private.parent_portal_grants
    where member_season_id in (
      'ac300000-0000-4000-8000-000000000001',
      'ac300000-0000-4000-8000-000000000002'
    )
      and status = 'active'),
  2::bigint,
  'beide geselecteerde lid-seizoenen hebben een actieve grant'
);
select is(
  (select count(*) from private.parent_portal_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000003'),
  0::bigint,
  'het niet-geselecteerde kind krijgt geen grant'
);
select is(
  (select count(*) from private.email_jobs
    where context_kind = 'portal_access'
      and parent_access_batch_id = (
        select id from private.parent_access_batches
        where batch_key = 'ac400000-0000-4000-8000-000000000001'
      )),
  1::bigint,
  'gedeeld adres krijgt exact één duurzame uitnodigingsjob'
);
select is(
  (select payload ? 'children' from private.email_jobs
    where context_kind = 'portal_access'
      and parent_access_batch_id = (
        select id from private.parent_access_batches
        where batch_key = 'ac400000-0000-4000-8000-000000000001'
      )),
  false,
  'uitnodigingspayload bevat geen kindnamen of ledenlijst'
);

insert into app.seasons(
  id,
  name,
  starts_on,
  ends_on,
  default_amount_cents,
  status,
  opened_at
) values (
  'ac100000-0000-4000-8000-000000000002',
  '2044/2045 toegang',
  '2044-07-01',
  '2045-06-30',
  13000,
  'open',
  timezone('utc', now())
);
insert into app.member_seasons(
  id,
  member_id,
  season_id,
  team_name,
  participation_status,
  reconciliation_status
) values (
  'ac300000-0000-4000-8000-000000000005',
  'ac200000-0000-4000-8000-000000000001',
  'ac100000-0000-4000-8000-000000000002',
  'JO11-1',
  'active',
  'resolved'
);

set local role authenticated;
create temporary table pre_cutover_season_two_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[]
) result;
select app.activate_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[],
  (select result->>'revision' from pre_cutover_season_two_preview),
  'ac400000-0000-4000-8000-000000000020',
  null
);
reset role;

create temporary table pre_cutover_grants as
select member_season_id, id grant_id
from private.parent_portal_grants
where member_season_id in (
  'ac300000-0000-4000-8000-000000000001',
  'ac300000-0000-4000-8000-000000000005'
)
  and status = 'active';
grant select on pre_cutover_grants to authenticated;
set local role authenticated;
create temporary table pre_cutover_current_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from pre_cutover_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000001'
  )]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from pre_cutover_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000001'
  )]::uuid[],
  'Huidig seizoen exact intrekken',
  (select result->>'revision' from pre_cutover_current_revoke_preview),
  'ac400000-0000-4000-8000-000000000021',
  null
);
reset role;
select is(
  (select count(*) from public.get_parent_members(repeat('8', 64))
    where member_id = 'ac200000-0000-4000-8000-000000000001'),
  0::bigint,
  'intrekking van huidig seizoen lekt vóór cutover niet via historische grant'
);

set local role authenticated;
create temporary table pre_cutover_current_reactivation_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000001',
  array['ac300000-0000-4000-8000-000000000001']::uuid[]
) result;
select app.activate_parent_portal_access(
  'ac100000-0000-4000-8000-000000000001',
  array['ac300000-0000-4000-8000-000000000001']::uuid[],
  (select result->>'revision' from pre_cutover_current_reactivation_preview),
  'ac400000-0000-4000-8000-000000000022',
  null
);
create temporary table pre_cutover_season_two_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000002',
  array[(
    select grant_id from pre_cutover_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000005'
  )]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array[(
    select grant_id from pre_cutover_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000005'
  )]::uuid[],
  'Historische regressiegrant opruimen',
  (select result->>'revision' from pre_cutover_season_two_revoke_preview),
  'ac400000-0000-4000-8000-000000000023',
  null
);
reset role;

set local role authenticated;
select is(
  (app.activate_parent_portal_access(
    'ac100000-0000-4000-8000-000000000001',
    array[
      'ac300000-0000-4000-8000-000000000001',
      'ac300000-0000-4000-8000-000000000002'
    ]::uuid[],
    (select result->>'revision' from activation_preview),
    'ac400000-0000-4000-8000-000000000001',
    'ac500000-0000-4000-8000-000000000001'
  )->>'reused'),
  'true',
  'retry met dezelfde batchsleutel retourneert idempotent hetzelfde resultaat'
);
reset role;
update app.seasons
set status = 'archived'
where id = 'ac100000-0000-4000-8000-000000000001';
set local role authenticated;
select is(
  (app.activate_parent_portal_access(
    'ac100000-0000-4000-8000-000000000001',
    array[
      'ac300000-0000-4000-8000-000000000001',
      'ac300000-0000-4000-8000-000000000002'
    ]::uuid[],
    (select result->>'revision' from activation_preview),
    'ac400000-0000-4000-8000-000000000001',
    'ac500000-0000-4000-8000-000000000001'
  )->>'reused'),
  'true',
  'geslaagde activatieretry blijft idempotent nadat het seizoen archiveert'
);
reset role;
update app.seasons
set status = 'open'
where id = 'ac100000-0000-4000-8000-000000000001';

set local role authenticated;
create temporary table active_season_a_cutover as
select app.get_parent_access_cutover_status() result;
reset role;
update app.app_settings
set active_season_id = 'ac100000-0000-4000-8000-000000000002'
where id = true;
set local role authenticated;
create temporary table active_season_b_cutover as
select app.get_parent_access_cutover_status() result;
select is(
  (select result->>'ready' from active_season_b_cutover),
  'false',
  'cutover accepteert geen legacy-link zonder grant in exact actief seizoen'
);
select isnt(
  (select result->>'revision' from active_season_b_cutover),
  (select result->>'revision' from active_season_a_cutover),
  'actief-seizoenwijziging verandert de cutoverrevision'
);
reset role;
update app.app_settings
set active_season_id = 'ac100000-0000-4000-8000-000000000001'
where id = true;
set local role authenticated;

create temporary table ready_cutover as
select app.get_parent_access_cutover_status() result;
select is(
  (select result->>'ready' from ready_cutover),
  'true',
  'alle legacykoppelingen zijn na expliciete activatie gereconcilieerd'
);
select is(
  (select (result->>'sessionsToRevokeCount')::integer from ready_cutover),
  1,
  'cutoverpreview telt de ongeautoriseerde bestaande sessie'
);
create temporary table cutover_result as
select app.enable_parent_access_grants_v2(
  (select result->>'revision' from ready_cutover),
  'ac500000-0000-4000-8000-000000000002'
) result;
select is(
  (select result->>'enabled' from cutover_result),
  'true',
  'beheerder activeert het grantcontract pas na reconciliatie'
);
select is(
  (select (result->>'sessionsRevoked')::integer from cutover_result),
  1,
  'cutover trekt alleen sessies zonder actieve grant in'
);
reset role;
create temporary table claimed_portal_job as
select id
from private.email_jobs
where context_kind = 'portal_access'
  and parent_access_batch_id = (
    select id from private.parent_access_batches
    where batch_key = 'ac400000-0000-4000-8000-000000000001'
  );
grant select on claimed_portal_job to service_role;
set local role service_role;
select is(
  (select count(*) from public.get_parent_session(repeat('8', 64))),
  1::bigint,
  'sessie met gereconcilieerde grant blijft bij cutover geldig'
);
select is(
  (select count(*) from public.get_parent_session(repeat('9', 64))),
  0::bigint,
  'sessie zonder actieve grant is bij cutover ingetrokken'
);

select is(
  jsonb_array_length(
    app.claim_email_jobs(
      'ac600000-0000-4000-8000-000000000001',
      25
    )->'jobs'
  ),
  0,
  'rollbackworker claimt geen portaaluitnodiging'
);
select is(
  jsonb_array_length(
    app.claim_email_jobs_v2(
      'ac600000-0000-4000-8000-000000000002',
      25
    )->'jobs'
  ),
  2,
  'v2-worker claimt alle geldige geconsolideerde portaaluitnodigingen'
);
select is(
  app.authorize_claimed_email_job(
    (select id from claimed_portal_job),
    'ac600000-0000-4000-8000-000000000002'
  ),
  true,
  'worker herverifieert een actieve uitnodiging vlak voor verzending'
);
reset role;
update private.email_jobs
set status = 'queued',
    attempts = 0,
    claim_token = null,
    claimed_at = null,
    updated_at = timezone('utc', now())
where context_kind = 'portal_access'
  and parent_access_batch_id = (
    select id from private.parent_access_batches
    where batch_key = 'ac400000-0000-4000-8000-000000000001'
  );
set local role authenticated;

create temporary table blocked_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000001',
  array['ac300000-0000-4000-8000-000000000004']::uuid[]
) result;
select is(
  (select (result->>'blockedCount')::integer from blocked_preview),
  1,
  'ongeldig e-mailadres blokkeert activatie'
);
select throws_ok(
  $$select app.activate_parent_portal_access(
    'ac100000-0000-4000-8000-000000000001',
    array['ac300000-0000-4000-8000-000000000004']::uuid[],
    (select result->>'revision' from blocked_preview),
    'ac400000-0000-4000-8000-000000000004',
    null
  )$$,
  '23514',
  'PARENT_ACCESS_SELECTION_BLOCKED',
  'een geblokkeerde selectie commit nooit gedeeltelijk'
);

reset role;

create temporary table known_otp_result as
select public.create_parent_otp(
    'gezin@example.invalid',
    repeat('1', 64),
    timezone('utc', now()) + interval '10 minutes'
  ) account_id;
select isnt(
  (select account_id from known_otp_result),
  null::uuid,
  'actieve grant ontsluit een OTP-challenge'
);
select is(
  public.create_parent_otp(
    'ongegrant@example.invalid',
    repeat('3', 64),
    timezone('utc', now()) + interval '10 minutes'
  ),
  null::uuid,
  'import of onbekend adres zonder grant krijgt geen OTP'
);

select is(
  (private.consume_parent_otp(
    'gezin@example.invalid',
    repeat('1', 64)
  )->>'status'),
  'verified',
  'juiste OTP wordt alleen bij actieve grant geconsumeerd'
);
select public.create_parent_session(
  (select id from private.parent_accounts
    where email_normalized = 'gezin@example.invalid'),
  repeat('4', 64),
  timezone('utc', now()) + interval '1 day'
);
select is(
  (select count(*) from public.get_parent_members(repeat('4', 64))),
  2::bigint,
  'oudersessie ziet uitsluitend de twee actieve lid-seizoengrants'
);
select is(
  (select date_of_birth from public.get_parent_members(repeat('4', 64))
    where member_season_id = 'ac300000-0000-4000-8000-000000000001'),
  date '2013-03-04',
  'gegrant ouderaccount mag DOB van het eigen lid zien'
);
select throws_ok(
  $$select public.create_parent_session(
    'ac700000-0000-4000-8000-000000000001',
    repeat('7', 64),
    timezone('utc', now()) + interval '31 days'
  )$$,
  '22023',
  'PARENT_SESSION_INVALID',
  'database weigert een oudersessie langer dan dertig dagen'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table season_two_activation_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[]
) result;
select app.activate_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[],
  (select result->>'revision' from season_two_activation_preview),
  'ac400000-0000-4000-8000-000000000010',
  null
);
reset role;
select is(
  (select count(*) from private.parent_portal_grants grant_row
    join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
    where member_season.member_id = 'ac200000-0000-4000-8000-000000000001'
      and grant_row.status = 'active'),
  2::bigint,
  'één lid kan in twee seizoenen een afzonderlijke actieve grant hebben'
);
select is(
  (select count(*) from private.parent_portal_grants grant_row
    join app.member_seasons member_season
      on member_season.id = grant_row.member_season_id
    where member_season.member_id = 'ac200000-0000-4000-8000-000000000001'
      and grant_row.legacy_link_id is not null),
  1::bigint,
  'memberbrede legacy-link is aan maximaal één seizoensgrant gekoppeld'
);

create temporary table season_two_grant as
select grant_row.id grant_id
from private.parent_portal_grants grant_row
where grant_row.member_season_id = 'ac300000-0000-4000-8000-000000000005'
  and grant_row.status = 'active';
grant select on season_two_grant to authenticated;

set local role authenticated;
create temporary table season_two_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000002',
  array[(select grant_id from season_two_grant)]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array[(select grant_id from season_two_grant)]::uuid[],
  'Tweede seizoen tijdelijk ingetrokken',
  (select result->>'revision' from season_two_revoke_preview),
  'ac400000-0000-4000-8000-000000000011',
  null
);
create temporary table season_two_reactivation_preview as
select app.preview_parent_portal_activation(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[]
) result;
select app.activate_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array['ac300000-0000-4000-8000-000000000005']::uuid[],
  (select result->>'revision' from season_two_reactivation_preview),
  'ac400000-0000-4000-8000-000000000012',
  null
);
reset role;
select is(
  (select count(*) from private.parent_portal_grants
    where member_season_id = 'ac300000-0000-4000-8000-000000000005'
      and status = 'active'),
  1::bigint,
  'ingetrokken seizoensgrant kan expliciet worden geheractiveerd'
);
select is(
  (select count(*) from private.parent_member_links
    where id = 'ac710000-0000-4000-8000-000000000001'
      and unlinked_at is null),
  1::bigint,
  'intrekken van één seizoen houdt de legacyprojectie bij andere actieve seizoenen'
);

create temporary table season_two_reactivated_grant as
select grant_row.id grant_id
from private.parent_portal_grants grant_row
where grant_row.member_season_id = 'ac300000-0000-4000-8000-000000000005'
  and grant_row.status = 'active';
grant select on season_two_reactivated_grant to authenticated;
set local role authenticated;
create temporary table season_two_final_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000002',
  array[(select grant_id from season_two_reactivated_grant)]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000002',
  array[(select grant_id from season_two_reactivated_grant)]::uuid[],
  'Tweede seizoen na regressietest ingetrokken',
  (select result->>'revision' from season_two_final_revoke_preview),
  'ac400000-0000-4000-8000-000000000013',
  null
);
reset role;
select is(
  (select count(*) from public.get_parent_members(repeat('4', 64))),
  2::bigint,
  'na tweede-seizoenstest blijven alleen de twee oorspronkelijke grants leesbaar'
);

create temporary table active_grant_ids as
select member_season_id, id grant_id
from private.parent_portal_grants
where member_season_id in (
  'ac300000-0000-4000-8000-000000000001',
  'ac300000-0000-4000-8000-000000000002'
)
  and status = 'active';
grant select on active_grant_ids to authenticated;

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table shared_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000001',
  array(
    select grant_id
    from active_grant_ids
    order by grant_id
  )
) result;
select is(
  (select jsonb_array_length(result->'groups')
    from shared_revoke_preview),
  1,
  'intrekpreflight groepeert een gedeeld ouderadres'
);
select is(
  (select jsonb_array_length(result->'groups'->0->'members')
    from shared_revoke_preview),
  2,
  'intrekpreflight toont beide expliciet geselecteerde kinderen'
);

create temporary table revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from active_grant_ids
    where member_season_id = 'ac300000-0000-4000-8000-000000000001'
  )]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from active_grant_ids
    where member_season_id = 'ac300000-0000-4000-8000-000000000001'
  )]::uuid[],
  'Toegang op verzoek ingetrokken',
  (select result->>'revision' from revoke_preview),
  'ac400000-0000-4000-8000-000000000002',
  null
);
reset role;

select is(
  (select count(*) from public.get_parent_members(repeat('4', 64))),
  1::bigint,
  'intrekking van één kind laat alleen de andere grant leesbaar'
);
select is(
  (select count(*) from private.parent_sessions
    where token_hash = repeat('4', 64) and revoked_at is null),
  1::bigint,
  'sessie blijft actief zolang een ander kind gegrant is'
);

update private.email_jobs
set status = 'processing',
    attempts = 1,
    claim_token = 'ac600000-0000-4000-8000-000000000003',
    claimed_at = timezone('utc', now()),
    updated_at = timezone('utc', now())
where context_kind = 'portal_access'
  and parent_access_batch_id = (
    select id from private.parent_access_batches
    where batch_key = 'ac400000-0000-4000-8000-000000000001'
  );

select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table final_revoke_preview as
select app.preview_parent_portal_revocation(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from active_grant_ids
    where member_season_id = 'ac300000-0000-4000-8000-000000000002'
  )]::uuid[]
) result;
select app.revoke_parent_portal_access(
  'ac100000-0000-4000-8000-000000000001',
  array[(
    select grant_id from active_grant_ids
    where member_season_id = 'ac300000-0000-4000-8000-000000000002'
  )]::uuid[],
  'Alle toegang ingetrokken',
  (select result->>'revision' from final_revoke_preview),
  'ac400000-0000-4000-8000-000000000003',
  null
);
reset role;

set local role service_role;
select is(
  app.authorize_claimed_email_job(
    (select id from claimed_portal_job),
    'ac600000-0000-4000-8000-000000000003'
  ),
  false,
  'vlak-voor-send controle onderdrukt een ingetrokken uitnodiging'
);
reset role;
select is(
  (select count(*) from public.get_parent_session(repeat('4', 64))),
  0::bigint,
  'laatste intrekking maakt de bestaande oudersessie direct ongeldig'
);
select is(
  (select status from private.email_jobs
    where context_kind = 'portal_access'
      and parent_access_batch_id = (
        select id from private.parent_access_batches
        where batch_key = 'ac400000-0000-4000-8000-000000000001'
      )),
  'failed',
  'vlak-voor-send controle parkeert een ingetrokken uitnodiging'
);
select is(
  (select last_error from private.email_jobs
    where context_kind = 'portal_access'
      and parent_access_batch_id = (
        select id from private.parent_access_batches
        where batch_key = 'ac400000-0000-4000-8000-000000000001'
      )),
  'access_inactive_before_send',
  'geannuleerde uitnodiging bewaart alleen een PII-vrije reden'
);
select is(
  (select count(*) from app.audit_logs
    where action like 'parent.access.%'
      and metadata::text ~* '(gezin@example|Anna|Bram|2013-03-04)'),
  0::bigint,
  'toegangsaudit bevat geen e-mail, naam of DOB'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  (select jsonb_array_length(app.get_email_workspace_v3()->'templates')),
  7,
  'beheerder beheert de portaaluitnodiging in e-mailworkspace v3'
);
select ok(
  exists(
    select 1
    from jsonb_array_elements(
      app.get_email_workspace_v3()->'jobs'
    ) job
    where job->>'contextKind' = 'portal_access'
      and not (job ? 'recipientEmail')
  ),
  'beheerder ziet portaaljobstatus zonder ontvanger-PII'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select is(
  (select jsonb_array_length(app.get_email_workspace_v3()->'templates')),
  6,
  'kledingcommissie krijgt de toegangstemplate niet'
);
select is(
  (select count(*)
    from jsonb_array_elements(
      app.get_email_workspace_v3()->'jobs'
    ) job
    where job->>'contextKind' = 'portal_access'),
  0::bigint,
  'kledingcommissie ziet geen portaaltoegangsjobs'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  (select jsonb_array_length(app.get_email_workspace_v2()->'templates')),
  6,
  'legacy e-mailworkspace behoudt exact zes templates'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'private.enqueue_parent_access_invite(uuid,uuid)',
    'EXECUTE'
  ),
  'clientrollen kunnen uitnodigingen niet rechtstreeks enqueuen'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.claim_email_jobs_v2(uuid,integer)',
    'EXECUTE'
  ),
  'alleen de serviceworker kan beide duurzame mailcontexten claimen'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.claim_email_jobs_v2(uuid,integer)',
    'EXECUTE'
  ),
  'browserrollen kunnen de v2-mailqueue niet claimen'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.authorize_claimed_email_job(uuid,uuid)',
    'EXECUTE'
  ),
  'serviceworker kan vlak vóór verzending opnieuw autoriseren'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.authorize_claimed_email_job(uuid,uuid)',
    'EXECUTE'
  ),
  'browserrollen kunnen geen geclaimde mailjob autoriseren'
);

select * from finish();
rollback;

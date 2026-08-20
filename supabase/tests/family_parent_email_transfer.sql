begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(
  not has_table_privilege(
    'authenticated', 'private.parent_family_email_transfers',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'browserrollen hebben geen directe toegang tot transferhistorie'
);
select ok(
  not has_table_privilege(
    'service_role', 'private.parent_family_email_transfer_items',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role krijgt geen brede toegang tot transferitems'
);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e9000000-0000-4000-8000-000000000001', 'Gezinsbeheerder', 'beheerder'),
  ('e9000000-0000-4000-8000-000000000002', 'Gezinscommissie', 'kledingcommissie');
insert into app.seasons(id, name, default_amount_cents, status) values
  ('e9100000-0000-4000-8000-000000000001', '2055/2056 gezin', 10000, 'open'),
  ('e9100000-0000-4000-8000-000000000002', '2054/2055 historie', 9000, 'archived');
update app.app_settings
set active_season_id = 'e9100000-0000-4000-8000-000000000001'
where id = true;
insert into private.release_cutovers(key, activated_at) values
  ('parent_access_grants_v2', timezone('utc', now()) - interval '1 hour'),
  ('mail_templates_v2', timezone('utc', now()) - interval '1 hour')
on conflict (key) do nothing;
update app.release_feature_flags set enabled = true
where key in ('parent_access_grants_v2', 'mail_templates_v2');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e9000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
create temporary table saved_family_invite as
select app.save_mail_template_draft_v1(
  'portal_access_invite',
  (select content_hash from app.mail_template_revisions
   where template_key = 'portal_access_invite' and status = 'draft'),
  'Portaaltoegang uitnodiging',
  'Toegang tot {{club_name}}',
  'Open zelf het veilige tenueportaal.',
  '{
    "type":"doc",
    "content":[
      {"type":"paragraph","content":[{"type":"text","text":"Uw portaaltoegang is geactiveerd."}]},
      {"type":"protectedBlock","attrs":{"kind":"portal_route"}}
    ]
  }'::jsonb,
  '<p>Uw portaaltoegang is geactiveerd.</p>',
  'Uw portaaltoegang is geactiveerd. Open zelf het tenueportaal.',
  null
) result;
select app.publish_mail_template_revision_v1(
  (select (result->>'revisionId')::uuid from saved_family_invite),
  (select result->>'contentHash' from saved_family_invite),
  null
);
reset role;

insert into app.members(
  id, relation_number, first_name, last_name, email, team,
  active_for_season, gender
) values
  ('e9200000-0000-4000-8000-000000000001', 'GEZ-1', 'Anna', 'Gezin', 'oud@example.invalid', 'MO9-1', true, 'female'),
  ('e9200000-0000-4000-8000-000000000002', 'GEZ-2', 'Bram', 'Gezin', 'oud@example.invalid', 'JO11-2', true, 'male'),
  ('e9200000-0000-4000-8000-000000000003', 'GEZ-3', 'Cato', 'Gezin', 'oud@example.invalid', 'MO14-1', true, 'female'),
  ('e9200000-0000-4000-8000-000000000004', 'LOS-1', 'Daan', 'Los', 'oud@example.invalid', 'JO16-1', true, 'male'),
  ('e9200000-0000-4000-8000-000000000005', 'ZON-1', 'Evi', 'Zonder', 'zonder@example.invalid', 'MO12-1', true, 'female');
update app.member_seasons set id = 'e9300000-0000-4000-8000-000000000001'
where member_id = 'e9200000-0000-4000-8000-000000000001'
  and season_id = 'e9100000-0000-4000-8000-000000000001';
update app.member_seasons set id = 'e9300000-0000-4000-8000-000000000002'
where member_id = 'e9200000-0000-4000-8000-000000000002'
  and season_id = 'e9100000-0000-4000-8000-000000000001';
update app.member_seasons set id = 'e9300000-0000-4000-8000-000000000003'
where member_id = 'e9200000-0000-4000-8000-000000000003'
  and season_id = 'e9100000-0000-4000-8000-000000000001';
update app.member_seasons set id = 'e9300000-0000-4000-8000-000000000004'
where member_id = 'e9200000-0000-4000-8000-000000000004'
  and season_id = 'e9100000-0000-4000-8000-000000000001';
update app.member_seasons set id = 'e9300000-0000-4000-8000-000000000005'
where member_id = 'e9200000-0000-4000-8000-000000000005'
  and season_id = 'e9100000-0000-4000-8000-000000000001';
insert into app.member_seasons(
  id, member_id, season_id, team_name, participation_status,
  reconciliation_status
) values (
  'e9300000-0000-4000-8000-000000000011',
  'e9200000-0000-4000-8000-000000000001',
  'e9100000-0000-4000-8000-000000000002',
  'MO8-1', 'inactive', 'resolved'
);

insert into private.parent_accounts(id, email_normalized) values
  ('e9400000-0000-4000-8000-000000000001', 'oud@example.invalid'),
  ('e9400000-0000-4000-8000-000000000002', 'nieuw@example.invalid');
insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source, granted_by, granted_at
) values
  ('e9500000-0000-4000-8000-000000000001', 'e9300000-0000-4000-8000-000000000001', 'oud@example.invalid', 'e9400000-0000-4000-8000-000000000001', 'active', 'administrator', 'e9000000-0000-4000-8000-000000000001', timezone('utc', now()) - interval '1 day'),
  ('e9500000-0000-4000-8000-000000000002', 'e9300000-0000-4000-8000-000000000002', 'oud@example.invalid', 'e9400000-0000-4000-8000-000000000001', 'active', 'administrator', 'e9000000-0000-4000-8000-000000000001', timezone('utc', now()) - interval '1 day'),
  ('e9500000-0000-4000-8000-000000000003', 'e9300000-0000-4000-8000-000000000003', 'oud@example.invalid', 'e9400000-0000-4000-8000-000000000001', 'active', 'administrator', 'e9000000-0000-4000-8000-000000000001', timezone('utc', now()) - interval '1 day'),
  ('e9500000-0000-4000-8000-000000000011', 'e9300000-0000-4000-8000-000000000011', 'oud@example.invalid', 'e9400000-0000-4000-8000-000000000001', 'active', 'administrator', 'e9000000-0000-4000-8000-000000000001', timezone('utc', now()) - interval '1 year');
insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source
) values (
  'e9500000-0000-4000-8000-000000000012',
  'e9300000-0000-4000-8000-000000000002',
  'nieuw@example.invalid',
  'e9400000-0000-4000-8000-000000000002',
  'pending_account', 'administrator'
);
insert into private.parent_sessions(parent_account_id, token_hash, expires_at) values
  ('e9400000-0000-4000-8000-000000000001', repeat('1', 64), timezone('utc', now()) + interval '1 day'),
  ('e9400000-0000-4000-8000-000000000002', repeat('2', 64), timezone('utc', now()) + interval '1 day');
insert into private.parent_otp_challenges(
  parent_account_id, code_hash, expires_at
) values (
  'e9400000-0000-4000-8000-000000000001', repeat('3', 64),
  timezone('utc', now()) + interval '10 minutes'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e9000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
create temporary table initial_family_detail as
select app.get_member_detail_v6(
  'e9200000-0000-4000-8000-000000000001'
) result;
create temporary table family_preview as
select app.preview_member_family_email_transfer_v1(
  'e9200000-0000-4000-8000-000000000001',
  'e9300000-0000-4000-8000-000000000001',
  ' NIEUW@EXAMPLE.INVALID ',
  (select result->>'profileRevision' from initial_family_detail)
) result;
select is((select result->>'affectedMemberCount' from family_preview), '3',
  'preflight ontdekt drie kinderen via het ouderaccount');
select is((select result->>'activePortalCount' from family_preview), '3',
  'preflight toont drie actieve huidige grants');
select is((select result->>'newEmail' from family_preview), 'nieuw@example.invalid',
  'preflight normaliseert het doeladres');
select ok(
  not exists(
    select 1 from family_preview,
      jsonb_array_elements(result->'affectedChildren') child
    where child->>'memberId' = 'e9200000-0000-4000-8000-000000000004'
  ),
  'een los lid met hetzelfde e-mailadres wordt niet als familie gezien'
);
select is(
  app.preview_member_family_email_transfer_v1(
    'e9200000-0000-4000-8000-000000000003',
    'e9300000-0000-4000-8000-000000000003',
    'nieuw@example.invalid',
    app.get_member_detail_v6(
      'e9200000-0000-4000-8000-000000000003'
    )->>'profileRevision'
  )->>'affectedMemberCount',
  '3',
  'starten bij een ander kind levert dezelfde familieomvang'
);
create temporary table transfer_result as
select app.update_member_profile_v2(
  'e9200000-0000-4000-8000-000000000001',
  'e9300000-0000-4000-8000-000000000001',
  'Anna', null, 'Gezin', 'nieuw@example.invalid', null,
  'female', 'MO9-1',
  (select result->>'profileRevision' from initial_family_detail),
  (select result->>'familyRevision' from family_preview),
  'E-mailadres ouder gewijzigd',
  'e9600000-0000-4000-8000-000000000001',
  'e9600000-0000-4000-8000-000000000002'
) result;
reset role;

select is(
  (select count(*) from app.members
   where id in (
     'e9200000-0000-4000-8000-000000000001',
     'e9200000-0000-4000-8000-000000000002',
     'e9200000-0000-4000-8000-000000000003'
   ) and email = 'nieuw@example.invalid'),
  3::bigint,
  'alle drie member-e-mails veranderen atomair'
);
select is(
  (select email from app.members where id = 'e9200000-0000-4000-8000-000000000004'),
  'oud@example.invalid',
  'het losse lid blijft ongewijzigd'
);
select is(
  (select count(*) from private.parent_portal_grants
   where id in (
     'e9500000-0000-4000-8000-000000000001',
     'e9500000-0000-4000-8000-000000000002',
     'e9500000-0000-4000-8000-000000000003'
   ) and status = 'revoked' and email_normalized = 'oud@example.invalid'),
  3::bigint,
  'oude grantgeschiedenis wordt ingetrokken zonder identiteit te herschrijven'
);
select is(
  (select count(*) from private.parent_portal_grants grant_row
   where grant_row.member_season_id in (
     'e9300000-0000-4000-8000-000000000001',
     'e9300000-0000-4000-8000-000000000002',
     'e9300000-0000-4000-8000-000000000003'
   ) and grant_row.parent_account_id = 'e9400000-0000-4000-8000-000000000002'
     and grant_row.status = 'active'),
  3::bigint,
  'het bestaande doelaccount krijgt exact drie actieve grants'
);
select is(
  (select count(*) from private.parent_accounts
   where email_normalized = 'nieuw@example.invalid'),
  1::bigint,
  'het bestaande doelaccount wordt hergebruikt'
);
select is(
  (select status::text from private.parent_portal_grants
   where id = 'e9500000-0000-4000-8000-000000000012'),
  'active',
  'een bestaande open doelgrant wordt idempotent geactiveerd'
);
select ok(
  (select revoked_at is null from private.parent_sessions
   where token_hash = repeat('2', 64)),
  'een bestaande sessie op het doelaccount blijft geldig'
);
select is(
  (select count(*) from public.get_parent_members(repeat('2', 64))),
  3::bigint,
  'de bestaande doelsessie ziet meteen alle overgezette kinderen'
);
select ok(
  (select revoked_at is not null from private.parent_sessions
   where token_hash = repeat('1', 64)),
  'oude sessies worden ingetrokken wanneer geen actuele toegang resteert'
);
select ok(
  (select used_at is not null from private.parent_otp_challenges
   where parent_account_id = 'e9400000-0000-4000-8000-000000000001'),
  'openstaande oude OTP-uitdagingen worden ongeldig gemaakt'
);
select is(
  public.create_parent_otp(
    'oud@example.invalid', repeat('4', 64), timezone('utc', now()) + interval '10 minutes'
  ),
  null::uuid,
  'het oude adres kan geen nieuwe OTP-uitdaging krijgen'
);
select is(
  public.create_parent_otp(
    'nieuw@example.invalid', repeat('5', 64), timezone('utc', now()) + interval '10 minutes'
  ),
  'e9400000-0000-4000-8000-000000000002'::uuid,
  'het nieuwe adres kan direct een OTP aanvragen'
);
select is(
  private.consume_parent_otp('nieuw@example.invalid', repeat('5', 64))->>'status',
  'verified',
  'de OTP op het nieuwe account kan direct worden geverifieerd'
);
select lives_ok(
  $$select public.create_parent_session(
    'e9400000-0000-4000-8000-000000000002', repeat('6', 64),
    timezone('utc', now()) + interval '1 day'
  )$$,
  'het nieuwe account kan direct een sessie aanmaken'
);
select is(
  (select count(*) from private.mail_v2_domain_events event
   where event.template_key = 'portal_access_invite'
     and event.parent_account_id = 'e9400000-0000-4000-8000-000000000002'
     and event.source_id = (
       select activation_batch_id from private.parent_family_email_transfers
       where request_id = 'e9600000-0000-4000-8000-000000000001'
     )),
  3::bigint,
  'de bestaande portal_access_invite-producer maakt één event per kind'
);
set local role service_role;
create temporary table family_mail_claim as
select app.claim_mail_v2_domain_projections_v1(
  'e9700000-0000-4000-8000-000000000001', 10
) result;
reset role;
select is(
  jsonb_array_length((select result->'groups' from family_mail_claim)),
  1,
  'Mail-v2 groepeert de drie events tot één gezinsmail'
);
select is(
  (select count(*) from private.mail_v2_domain_events event
   where event.template_key = 'portal_access_invite'
     and event.parent_account_id = 'e9400000-0000-4000-8000-000000000001'),
  0::bigint,
  'de transfer maakt geen nieuwe mail voor het oude adres'
);
select ok(
  (select metadata::text !~ '@|tokenHash|codeHash|sessionToken' from app.audit_logs
   where action = 'parent.access.family_email_transferred'
   order by id desc limit 1),
  'familieaudit bevat IDs en tellingen maar geen e-mail of secrets'
);
select is(
  (select count(*) from app.audit_logs
   where action = 'member.profile.updated'
     and metadata->>'requestId' = 'e9600000-0000-4000-8000-000000000001'),
  3::bigint,
  'ieder gewijzigd lid behoudt normale profielaudit'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e9000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.update_member_profile_v2(
    'e9200000-0000-4000-8000-000000000001',
    'e9300000-0000-4000-8000-000000000001',
    'Anna', null, 'Gezin', 'nieuw@example.invalid', null,
    'female', 'MO9-1',
    (select result->>'profileRevision' from initial_family_detail),
    (select result->>'familyRevision' from family_preview),
    'E-mailadres ouder gewijzigd',
    'e9600000-0000-4000-8000-000000000001',
    'e9600000-0000-4000-8000-000000000002'
  )->>'reused',
  'true',
  'dezelfde request-ID hergebruikt exact het opgeslagen resultaat'
);
select lives_ok(
  $$select app.update_member_profile_v2(
    'e9200000-0000-4000-8000-000000000005',
    'e9300000-0000-4000-8000-000000000005',
    'Evi', null, 'Zonder', 'losnieuw@example.invalid', null,
    'female', 'MO12-1',
    app.get_member_detail_v6(
      'e9200000-0000-4000-8000-000000000005'
    )->>'profileRevision',
    null, 'Gewone profielcorrectie',
    'e9600000-0000-4000-8000-000000000003', null
  )$$,
  'zonder actieve portaltoegang blijft dit een gewone enkelvoudige profielwijziging'
);
select is(
  app.get_member_detail_v6('e9200000-0000-4000-8000-000000000001')
    #>> '{portalAccess,loginEmail}',
  'nieuw@example.invalid',
  'liddetail toont het actuele loginadres'
);
select is(
  app.get_member_detail_v6('e9200000-0000-4000-8000-000000000001')
    #>> '{portalAccess,linkedChildrenCount}',
  '3',
  'liddetail toont de gezinsomvang'
);
select is(
  app.get_parent_family_email_reconciliation_v1()
    ->>'mismatchedChildCount',
  '0',
  'reconciliatie vindt na transfer geen actuele mismatch'
);
reset role;

update app.members
set email = 'afwijkend@example.invalid'
where id = 'e9200000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e9000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select is(
  app.get_parent_family_email_reconciliation_v1()
    ->>'inconsistentFamilyCount',
  '1',
  'reconciliatie groepeert een afwijkend kind als inconsistent gezin'
);
select is(
  app.get_parent_family_email_reconciliation_v1()
    ->>'mismatchedChildCount',
  '1',
  'reconciliatie telt uitsluitend het afwijkende kind'
);
select is(
  app.get_parent_family_email_reconciliation_v1()
    #>> '{groups,0,children,2,memberEmail}',
  'afwijkend@example.invalid',
  'reconciliatie toont het actuele afwijkende lidadres'
);
select is(
  app.get_parent_family_email_reconciliation_v1()
    #>> '{groups,0,children,2,activeGrantEmail}',
  'nieuw@example.invalid',
  'reconciliatie toont daarnaast het autoritatieve grantadres'
);
reset role;
update app.members
set email = 'nieuw@example.invalid'
where id = 'e9200000-0000-4000-8000-000000000003';

select is(
  (select count(*) from private.parent_family_email_transfers
   where request_id = 'e9600000-0000-4000-8000-000000000001'),
  1::bigint,
  'retry maakt geen tweede transfertelling'
);
select is(
  (select count(*) from private.mail_v2_domain_events event
   where event.template_key = 'portal_access_invite'
     and event.parent_account_id = 'e9400000-0000-4000-8000-000000000002'),
  3::bigint,
  'retry maakt geen dubbele activatiemail-events'
);
select is(
  (select count(*) from private.parent_portal_grants
   where member_season_id = 'e9300000-0000-4000-8000-000000000005'),
  0::bigint,
  'gewone profielwijziging activeert geen portalgrant'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e9000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
select throws_ok(
  $$select app.preview_member_family_email_transfer_v1(
    'e9200000-0000-4000-8000-000000000001',
    'e9300000-0000-4000-8000-000000000001',
    'ander@example.invalid', repeat('a', 64)
  )$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan geen gezinsbrede e-mailtransfer voorbereiden'
);
reset role;

select * from finish();
rollback;

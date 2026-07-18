begin;
select plan(30);

insert into app.seasons(id, name, starts_on, ends_on, default_amount_cents, status) values
  ('f1000000-0000-4000-8000-000000000001', '2036/37 instellingen', '2036-07-01', '2037-06-30', 12500, 'open'),
  ('f1000000-0000-4000-8000-000000000002', '2035/36 instellingen', '2035-07-01', '2036-06-30', 11500, 'archived');
update app.app_settings set club_name='Duindorp SV', active_season_id='f1000000-0000-4000-8000-000000000001', mollie_enabled=false, email_enabled=false where id=true;
insert into app.staff_profiles(auth_user_id, display_name, role, active) values
  ('f0000000-0000-4000-8000-000000000001', 'Ada Beheerder', 'beheerder', true),
  ('f0000000-0000-4000-8000-000000000002', 'Koen Commissie', 'kledingcommissie', true),
  ('f0000000-0000-4000-8000-000000000003', 'Udo Uitgifte', 'uitgifte', true),
  ('f0000000-0000-4000-8000-000000000004', 'Bep Beheerder', 'beheerder', true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select lives_ok($$select app.get_settings_workspace()$$, 'beheerder op AAL2 kan instellingen openen');
select is(app.get_settings_workspace()->'settings'->>'clubName', 'Duindorp SV', 'clubnaam is canoniek vast');
select is(jsonb_array_length(app.get_settings_workspace()->'roles'), 3, 'workspace bevat exact drie rollen');
select ok(jsonb_array_length(app.get_settings_workspace()->'seasons') >= 3, 'workspace bevat seed- en testseizoenen');
select is(jsonb_array_length(app.get_settings_workspace()->'staff'), 4, 'workspace bevat staff-profielen');

select lives_ok($$select app.update_settings(
  ' KLEDING@DUINDORPSV.NL ', ' Clubhuis ', 'f1000000-0000-4000-8000-000000000001',
  '[{"seasonId":"f1000000-0000-4000-8000-000000000001","amountCents":13000},{"seasonId":"f1000000-0000-4000-8000-000000000002","amountCents":12000}]'::jsonb,
  true, true, 'fa000000-0000-4000-8000-000000000001')$$,
  'beheerder kan instellingen en seizoensbedragen atomair wijzigen');
select is((select club_name from app.app_settings where id), 'Duindorp SV', 'clubnaam blijft vast');
select is((select contact_email from app.app_settings where id), 'kleding@duindorpsv.nl', 'contactmail wordt genormaliseerd');
select is((select pickup_location from app.app_settings where id), 'Clubhuis', 'afhaallocatie wordt getrimd');
select is((select default_amount_cents from app.seasons where id='f1000000-0000-4000-8000-000000000001'), 13000, 'standaardbedrag wordt als centen opgeslagen');
select ok((select mollie_enabled and email_enabled from app.app_settings where id), 'operationele switches zijn opgeslagen');
select ok(exists(select 1 from app.audit_logs where action='settings.updated' and correlation_id='fa000000-0000-4000-8000-000000000001'), 'instellingenmutatie is gecorreleerd geaudit');
select ok(not exists(select 1 from app.audit_logs where action='settings.updated' and metadata::text ~* 'duindorpsv|clubhuis'), 'auditmetadata bevat geen contactgegevens of locatie');
select throws_ok($$select app.update_settings('geen-email','Clubhuis','f1000000-0000-4000-8000-000000000001','[]'::jsonb,false,false,null)$$, '22023', 'SETTINGS_CONTACT_EMAIL_INVALID', 'ongeldig contactmailadres wordt geweigerd');
select throws_ok($$select app.update_settings(null,null,'f1000000-0000-4000-8000-000000000002','[]'::jsonb,false,false,null)$$, '22023', 'SETTINGS_ACTIVE_SEASON_INVALID', 'gearchiveerd seizoen kan niet actief worden');

select throws_ok($$select app.update_staff_profile('f0000000-0000-4000-8000-000000000001','Ada Beheerder','kledingcommissie',true,null)$$, '23514', 'STAFF_SELF_LOCKOUT_BLOCKED', 'beheerder kan eigen beheerderstoegang niet verwijderen');
select lives_ok($$select app.update_staff_profile('f0000000-0000-4000-8000-000000000003','Udo Scanner','uitgifte',false,'fa000000-0000-4000-8000-000000000002')$$, 'beheerder kan een ander staff-profiel veilig blokkeren');
select ok(not (select active from app.staff_profiles where auth_user_id='f0000000-0000-4000-8000-000000000003'), 'staff-profiel is geblokkeerd');
select ok(exists(select 1 from app.audit_logs where action='staff.updated' and correlation_id='fa000000-0000-4000-8000-000000000002'), 'staffwijziging is geaudit');
select lives_ok($$select app.register_invited_staff('f0000000-0000-4000-8000-000000000005','Kiki Commissie','kledingcommissie',null)$$, 'uitgenodigde auth-user kan als staff-profiel worden geregistreerd');
select is((select role::text from app.staff_profiles where auth_user_id='f0000000-0000-4000-8000-000000000005'), 'kledingcommissie', 'uitnodiging gebruikt exact een canonieke rol');

reset role;
insert into app.audit_logs(actor_user_id, action, entity_type, metadata) values
  ('f0000000-0000-4000-8000-000000000001', 'payment.manual.recorded', 'payment', '{}'::jsonb),
  ('f0000000-0000-4000-8000-000000000001', 'settings.updated', 'app_settings', '{}'::jsonb),
  ('f0000000-0000-4000-8000-000000000001', 'auth.failed', 'staff_session', '{}'::jsonb);
set local role authenticated;

select is(app.get_audit_workspace(null,null,null,null,50)->>'viewerRole', 'beheerder', 'beheerder krijgt volledige auditworkspace');
select is(jsonb_array_length(app.get_audit_workspace(null,null,null,null,50)->'categories'), 8, 'beheerder krijgt alle acht categorieën');
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select throws_ok($$select app.get_settings_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'kledingcommissie heeft geen instellingenworkspace');
select is(app.get_audit_workspace(null,null,null,null,100)->>'viewerRole', 'kledingcommissie', 'kledingcommissie krijgt operationele auditworkspace');
select is(jsonb_array_length(app.get_audit_workspace(null,null,null,null,100)->'categories'), 6, 'kledingcommissie krijgt alleen operationele categorieën');
select ok(not exists(select 1 from app.audit_logs where action in ('settings.updated','auth.failed')), 'RLS verbergt settings- en securityaudit voor kledingcommissie');
select throws_ok($$select app.get_audit_workspace('settings',null,null,null,50)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'kledingcommissie kan beveiligde categorie niet forceren');
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000003","aal":"aal2"}', true);
select throws_ok($$select app.get_audit_workspace(null,null,null,null,50)$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'uitgifterol krijgt geen auditworkspace');
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000001","aal":"aal1"}', true);
select throws_ok($$select app.get_settings_workspace()$$, '42501', 'STAFF_AUTHORIZATION_REQUIRED', 'instellingen vereisen aantoonbaar AAL2');

select * from finish();
rollback;

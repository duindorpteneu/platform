begin;
select plan(20);

select is((select count(*)::integer from app.app_settings where id), 1, 'migrations leveren de verplichte instellingenrij');

insert into app.staff_profiles(auth_user_id, display_name, role, active)
values ('f4000000-0000-4000-8000-000000000001', 'Adresbeheerder', 'beheerder', true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f4000000-0000-4000-8000-000000000001","aal":"aal2"}', true);

select lives_ok($$select app.get_settings_workspace_v2()$$, 'beheerder kan de uitgebreide instellingen openen');
select ok(app.get_settings_workspace_v2()->'settings' ? 'pickupAddressDiffers', 'workspace bevat expliciete afhaaladreskeuze');

select lives_ok($$select app.update_settings_v2(
  ' KLEDING@DUINDORPSV.NL ', ' Duinlaan 1 ', '2584 AB', ' Den Haag ',
  false, null, null, null, null, null, '[]'::jsonb, false, false,
  'f4100000-0000-4000-8000-000000000001'
)$$, 'verenigingsgegevens kunnen zonder actief seizoen worden opgeslagen');
select is((select contact_email from app.app_settings where id), 'kleding@duindorpsv.nl', 'contactmail wordt genormaliseerd');
select is((select club_address_line from app.app_settings where id), 'Duinlaan 1', 'verenigingsadres wordt getrimd');
select is((select pickup_location from app.app_settings where id), 'Duindorp SV, Duinlaan 1, 2584 AB Den Haag', 'mailshortcode gebruikt standaard het verenigingsadres');
select is((select active_season_id from app.app_settings where id), null, 'instellingen opslaan vereist geen actief seizoen');
select ok(
  jsonb_array_length(app.get_settings_workspace_v2()->'seasons') > 0
  and not exists (
    select 1
    from jsonb_array_elements(app.get_settings_workspace_v2()->'seasons') season
    where jsonb_typeof(season->'active') <> 'boolean' or (season->>'active')::boolean
  ),
  'workspace retourneert false voor ieder seizoen wanneer geen actief seizoen is ingesteld'
);

select lives_ok($$select app.update_settings_v2(
  'kleding@duindorpsv.nl', 'Duinlaan 1', '2584 AB', 'Den Haag',
  true, 'Tenuepunt', 'Markt 2', '2511 AA', 'Den Haag', null, '[]'::jsonb, false, false,
  'f4100000-0000-4000-8000-000000000002'
)$$, 'afwijkend afhaaladres kan volledig worden opgeslagen');
select is((select pickup_location from app.app_settings where id), 'Tenuepunt, Markt 2, 2511 AA Den Haag', 'afhaallocatie wordt voor bestaande communicatie afgeleid');
select is(app.get_settings_workspace_v2() #>> '{settings,pickupName}', 'Tenuepunt', 'workspace retourneert het gestructureerde afhaaladres');
select throws_ok($$select app.update_settings_v2(
  null, 'Duinlaan 1', null, 'Den Haag', false, null, null, null, null,
  null, '[]'::jsonb, false, false, null
)$$, '22023', 'SETTINGS_CLUB_ADDRESS_INVALID', 'onvolledig verenigingsadres wordt geweigerd');
select throws_ok($$select app.update_settings_v2(
  null, null, null, null, true, 'Tenuepunt', null, '2511 AA', 'Den Haag',
  null, '[]'::jsonb, false, false, null
)$$, '22023', 'SETTINGS_PICKUP_ADDRESS_INVALID', 'onvolledig afhaaladres wordt geweigerd');

create temporary table created_season_response as
select app.create_season_v2(
  '2041/42 adrescontrole', '2041-07-01', '2042-06-30', 9900, true,
  'f4100000-0000-4000-8000-000000000003'
) response;
select ok((select response is not null from created_season_response), 'nieuw seizoen wordt aangemaakt');
select ok(
  exists(select 1 from created_season_response, jsonb_array_elements(response->'seasons') season where season->>'name' = '2041/42 adrescontrole'),
  'nieuw seizoen is direct in dezelfde mutatierespons zichtbaar'
);
select is((select response #>> '{settings,activeSeasonId}' from created_season_response), (select id::text from app.seasons where name = '2041/42 adrescontrole'), 'nieuw seizoen is direct actief in dezelfde mutatierespons');
select is((select count(*)::integer from app.app_settings where id), 1, 'seizoensmutatie behoudt exact één instellingenrij');
select ok(exists(select 1 from app.audit_logs where action = 'settings.updated' and correlation_id = 'f4100000-0000-4000-8000-000000000002'), 'adreswijziging is geaudit');
select ok(not exists(select 1 from app.audit_logs where correlation_id = 'f4100000-0000-4000-8000-000000000002' and metadata::text ~* 'tenuepunt|markt'), 'audit bevat geen adresgegevens');

select * from finish();
rollback;

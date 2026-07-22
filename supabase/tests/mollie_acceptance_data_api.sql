begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(has_function_privilege('service_role',
  'public.prepare_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)', 'EXECUTE'),
  'alleen de service role kan een streng begrensde Mollie-acceptatiefixture voorbereiden');
select ok(not has_function_privilege('authenticated',
  'public.prepare_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)', 'EXECUTE'),
  'medewerkers kunnen de acceptatiefixture niet voorbereiden');
select ok(not has_function_privilege('anon',
  'public.cleanup_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)', 'EXECUTE'),
  'anonieme clients kunnen de acceptatiecleanup niet uitvoeren');
select ok(has_function_privilege('service_role',
  'public.get_mollie_acceptance_payment_state(uuid,uuid)', 'EXECUTE'),
  'service role kan uitsluitend de begrensde acceptatiebetaalstaat lezen');
select ok(has_function_privilege('service_role',
  'public.is_operational_feature_enabled(text)', 'EXECUTE'),
  'service role kan de operationele providerflag via een begrensd contract lezen');
select ok(not has_function_privilege('anon',
  'public.is_operational_feature_enabled(text)', 'EXECUTE'),
  'anonieme clients kunnen operationele providerflags niet opvragen');

create temporary table original_mollie_setting as
select mollie_enabled from app.app_settings where id = true;

select is(public.prepare_mollie_acceptance_fixture(
  'a9100000-0000-4000-8000-000000000001', 'a9100000-0000-4000-8000-000000000002',
  'a9200000-0000-4000-8000-000000000001', 'a9200000-0000-4000-8000-000000000002',
  'MOLLIE-12345a1-P', 'MOLLIE-12345a1-M', 'mollie-acceptance+12345a1@example.invalid'
), true, 'hosted RPC maakt de fictieve fixture atomair aan');
select is((select count(*) from app.members where id in (
  'a9100000-0000-4000-8000-000000000001', 'a9100000-0000-4000-8000-000000000002'
)), 2::bigint, 'fixture bevat exact twee actieve leden');
select is((select count(*) from app.member_orders where id in (
  'a9200000-0000-4000-8000-000000000001', 'a9200000-0000-4000-8000-000000000002'
) and amount_due_cents = 100), 2::bigint, 'fixture bevat exact twee orders van één euro');
select is(public.parent_otp_members_visible(array[
  'a9100000-0000-4000-8000-000000000001'::uuid,
  'a9100000-0000-4000-8000-000000000002'::uuid
], 'mollie-acceptance+12345a1@example.invalid'), true,
  'fixture is direct via het hosted OTP-zichtbaarheidscontract beschikbaar');
select is(public.is_operational_feature_enabled('mollie_enabled'), true,
  'Mollie-featureflag is via het servicecontract direct zichtbaar');
select is(public.get_mollie_acceptance_payment_state(
  'a9200000-0000-4000-8000-000000000001', 'a9100000-0000-4000-8000-000000000001'
), null::jsonb, 'betaalstaat is leeg voordat een checkout is aangemaakt');

select throws_ok($$select public.prepare_mollie_acceptance_fixture(
  'a9300000-0000-4000-8000-000000000001', 'a9300000-0000-4000-8000-000000000002',
  'a9400000-0000-4000-8000-000000000001', 'a9400000-0000-4000-8000-000000000002',
  'NIET-TOEGESTAAN-P', 'NIET-TOEGESTAAN-M', 'persoon@example.nl'
)$$, '22023', 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY',
  'RPC weigert alle niet-fictieve of niet-herkenbare fixture-identiteiten');

select is(public.cleanup_mollie_acceptance_fixture(
  'a9100000-0000-4000-8000-000000000001', 'a9100000-0000-4000-8000-000000000002',
  'a9200000-0000-4000-8000-000000000001', 'a9200000-0000-4000-8000-000000000002',
  'MOLLIE-12345a1-P', 'MOLLIE-12345a1-M', 'mollie-acceptance+12345a1@example.invalid'
), true, 'hosted cleanup is idempotent en begrensd');
select is((select count(*) from app.members where id in (
  'a9100000-0000-4000-8000-000000000001', 'a9100000-0000-4000-8000-000000000002'
)), 0::bigint, 'cleanup verwijdert beide fictieve leden');
select is((select mollie_enabled from app.app_settings where id = true),
  (select mollie_enabled from original_mollie_setting),
  'cleanup herstelt de oorspronkelijke Mollie-featureflag');

update app.app_settings set active_season_id = null where id = true;
select is(public.prepare_mollie_acceptance_fixture(
  'a9500000-0000-4000-8000-000000000001', 'a9500000-0000-4000-8000-000000000002',
  'a9600000-0000-4000-8000-000000000001', 'a9600000-0000-4000-8000-000000000002',
  'MOLLIE-67890a2-P', 'MOLLIE-67890a2-M', 'mollie-acceptance+67890a2@example.invalid'
), true, 'fixture maakt alleen bij ontbreken van een actief seizoen een tijdelijk testseizoen');
select is((select count(*) from app.seasons where name = 'Mollie acceptatie MOLLIE-67890a2-P'),
  1::bigint, 'tijdelijk testseizoen is streng herkenbaar en uniek');
select is(public.cleanup_mollie_acceptance_fixture(
  'a9500000-0000-4000-8000-000000000001', 'a9500000-0000-4000-8000-000000000002',
  'a9600000-0000-4000-8000-000000000001', 'a9600000-0000-4000-8000-000000000002',
  'MOLLIE-67890a2-P', 'MOLLIE-67890a2-M', 'mollie-acceptance+67890a2@example.invalid'
), true, 'cleanup herstelt ook staging zonder actief seizoen');
select is((select active_season_id from app.app_settings where id = true), null::uuid,
  'cleanup herstelt de ontbrekende actieve-seizoenstatus');
select is((select count(*) from app.seasons where name = 'Mollie acceptatie MOLLIE-67890a2-P'),
  0::bigint, 'cleanup verwijdert het tijdelijke testseizoen');

select * from finish();
rollback;
reset role;

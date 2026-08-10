begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

select is(
  to_regprocedure('public.prepare_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)'),
  null::regprocedure,
  'productschema bevat geen staging-fixturevoorbereiding'
);
select is(
  to_regprocedure('public.get_mollie_acceptance_payment_state(uuid,uuid)'),
  null::regprocedure,
  'productschema bevat geen staging-fixturestaatlezer'
);
select is(
  to_regprocedure('public.cleanup_mollie_acceptance_fixture(uuid,uuid,uuid,uuid,text,text,text)'),
  null::regprocedure,
  'productschema bevat geen staging-fixturecleanup'
);
select is(
  to_regprocedure('private.is_mollie_acceptance_identity(uuid,uuid,uuid,uuid,text,text,text)'),
  null::regprocedure,
  'private productschema bevat geen staging-identiteitshelper'
);
select is(
  to_regprocedure('public.parent_otp_members_visible(uuid[],text)'),
  null::regprocedure,
  'productschema bevat geen staging-zichtbaarheidshelper'
);
select is(
  to_regclass('private.mollie_acceptance_fixtures'),
  null::regclass,
  'een schone productmigratie maakt geen staging-fixtureledger'
);
select ok(has_function_privilege('service_role',
  'public.is_operational_feature_enabled(text)', 'EXECUTE'),
  'service role kan de operationele providerflag via een begrensd contract lezen');
select ok(not has_function_privilege('anon',
  'public.is_operational_feature_enabled(text)', 'EXECUTE'),
  'anonieme clients kunnen operationele providerflags niet opvragen');

select * from finish();
rollback;
reset role;

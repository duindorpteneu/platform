begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e0000000-0000-4000-8000-000000000001', 'OTP commissie', 'kledingcommissie'),
  ('e0000000-0000-4000-8000-000000000002', 'OTP beheerder', 'beheerder');
create temporary table otp_template_id as
select id, version as initial_version
from app.email_templates
where template_key='verification_code';
grant select on otp_template_id to authenticated;

select ok((select array_position(allowed_shortcodes, '{{verificatiecode}}') is not null
  from app.email_templates where template_key='verification_code'),
  'OTP-template staat de verificatiecode-shortcode toe');
select ok(has_function_privilege('service_role', 'public.get_parent_otp_email_template()', 'EXECUTE'),
  'service role kan het actieve OTP-template voor directe verzending ophalen');
select ok(not has_function_privilege('authenticated', 'public.get_parent_otp_email_template()', 'EXECUTE'),
  'browserrollen kunnen het directe OTP-template-RPC niet uitvoeren');

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.update_email_template(
  (select id from otp_template_id), 'Code voor {{clubnaam}}',
  'Uw code is {{verificatiecode}}.', (select initial_version from otp_template_id))$$,
  '42501', 'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan het OTP-template niet wijzigen');

reset role;
select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.update_email_template(
  (select id from otp_template_id), 'Code voor {{clubnaam}}',
  'Deze tekst mist de verplichte code-shortcode.', (select initial_version from otp_template_id))$$,
  '23514', 'EMAIL_VERIFICATION_CODE_REQUIRED',
  'OTP-template kan niet zonder verificatiecode worden opgeslagen');
select lives_ok($$select app.update_email_template(
  (select id from otp_template_id), 'Code voor {{clubnaam}}',
  'Uw code is {{verificatiecode}}. Vragen? {{contact_email}}', (select initial_version from otp_template_id))$$,
  'OTP-template is via dezelfde geautoriseerde en geversioneerde RPC bewerkbaar');
reset role;

select is(
  (select version from app.email_templates where template_key='verification_code'),
  (select initial_version + 1 from otp_template_id),
  'geslaagde OTP-wijziging verhoogt de templateversie');
select is((select subject_source from app.email_templates where template_key='verification_code'), 'Code voor {{clubnaam}}',
  'OTP-onderwerp is opgeslagen');
select is((select count(*) from app.audit_logs where action='email.template.updated'
  and entity_id=(select id from app.email_templates where template_key='verification_code')), 1::bigint,
  'OTP-templatewijziging is één keer zonder inhoud geaudit');
select is(public.get_parent_otp_email_template()->>'bodySource',
  'Uw code is {{verificatiecode}}. Vragen? {{contact_email}}',
  'directe verzendflow leest de actuele bewerkbare bron');
select is(public.get_parent_otp_email_template()->>'clubName', 'Duindorp SV',
  'directe verzendflow ontvangt uitsluitend de noodzakelijke clubcontext');

select * from finish();
rollback;
reset role;

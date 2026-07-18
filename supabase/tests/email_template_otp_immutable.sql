begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into app.staff_profiles(auth_user_id, display_name, role)
values('e0000000-0000-4000-8000-000000000001', 'OTP commissie', 'kledingcommissie');
create temporary table otp_template_id as
select id from app.email_templates where template_key='verification_code';
grant select on otp_template_id to authenticated;

select set_config('request.jwt.claims', '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
set local role authenticated;
select throws_ok($$select app.update_email_template(
  (select id from otp_template_id), 'Nieuwe verificatiecode',
  'Deze inhoud zou de beveiligde OTP-flow wijzigen.', 1)$$,
  '23514', 'EMAIL_TEMPLATE_IMMUTABLE',
  'verification_code is ook via directe RPC niet bewerkbaar');
reset role;
select is((select version from app.email_templates where template_key='verification_code'), 1,
  'geblokkeerde OTP-wijziging verhoogt de versie niet');
select is((select count(*) from app.audit_logs where action='email.template.updated'
  and entity_id=(select id from app.email_templates where template_key='verification_code')), 0::bigint,
  'geblokkeerde OTP-wijziging schrijft geen misleidende updateaudit');

select * from finish();
rollback;

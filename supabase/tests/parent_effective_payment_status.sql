begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into app.members(id, relation_number, first_name, last_name, email, team)
values('f1000000-0000-4000-8000-000000000001', 'PARENT-PAY-001', 'Ouder', 'Status', 'ouder-status@example.invalid', 'JO15-1');
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'f2000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', active_season_id, 12500
from app.app_settings where id=true;
insert into private.parent_accounts(id, email_normalized)
values('f3000000-0000-4000-8000-000000000001', 'ouder-status@example.invalid');
insert into private.parent_sessions(parent_account_id, token_hash, expires_at)
values('f3000000-0000-4000-8000-000000000001', repeat('9',64), timezone('utc', now()) + interval '1 hour');
insert into private.parent_member_links(parent_account_id, member_id)
values('f3000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001');
insert into app.payments(id, order_id, method, status, amount_cents, idempotency_key, provider_payment_id, paid_at, created_at) values
  ('f4000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'mollie', 'paid', 12500,
    'parent-primary-paid', 'tr_parent_primary', timezone('utc', now()), timezone('utc', now()) - interval '1 minute'),
  ('f4000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', 'mollie', 'duplicate_paid', 12500,
    'parent-later-duplicate', 'tr_parent_duplicate', timezone('utc', now()), timezone('utc', now()));
insert into private.qr_tokens(order_id, token_hash, version)
values('f2000000-0000-4000-8000-000000000001', repeat('a',64), 1);

select is((select payment_status from public.get_parent_members(repeat('9',64))), 'paid',
  'latere duplicate_paid maskeert primaire paid niet');
select is((select qr_version from public.get_parent_members(repeat('9',64))), 1,
  'primaire paid houdt actieve QR zichtbaar');
select is((select count(*) from public.get_parent_members(repeat('9',64))), 1::bigint,
  'ouderreadmodel retourneert het gekoppelde lid exact één keer');

update app.payments set status='refunded', refunded_at=timezone('utc', now())
where id='f4000000-0000-4000-8000-000000000001';
update private.qr_tokens set active=false, revoked_at=timezone('utc', now()), revocation_reason='Mollie payment refunded'
where order_id='f2000000-0000-4000-8000-000000000001' and active;
select is((select payment_status from public.get_parent_members(repeat('9',64))), 'refunded',
  'refund van primaire betaling heeft prioriteit boven duplicate_paid');
select is((select qr_version from public.get_parent_members(repeat('9',64))), null,
  'refund verbergt ingetrokken QR in ouderreadmodel');
select ok((select article_lines = '[]'::jsonb from public.get_parent_members(repeat('9',64))),
  'ouderreadmodel blijft zonder extra providerdetails compact');

select * from finish();
rollback;

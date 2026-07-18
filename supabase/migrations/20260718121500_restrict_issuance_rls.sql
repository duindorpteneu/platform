drop policy if exists "staff can read settings" on app.app_settings;
create policy "operations can read settings" on app.app_settings
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

drop policy if exists "staff can read seasons" on app.seasons;
create policy "operations can read seasons" on app.seasons
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

drop policy if exists "staff can read own profile" on app.staff_profiles;
create policy "staff can read own profile" on app.staff_profiles
for select using (auth_user_id = auth.uid());

drop policy if exists "staff can read imports" on app.import_batches;
create policy "operations can read imports" on app.import_batches
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

drop policy if exists "staff can read members" on app.members;

drop policy if exists "staff can read articles" on app.articles;

drop policy if exists "staff can read variants" on app.article_variants;

drop policy if exists "staff can read orders" on app.member_orders;

drop policy if exists "staff can read order lines" on app.order_lines;

drop policy if exists "staff can read payments" on app.payments;

drop policy if exists "staff can read fulfilments" on app.fulfilments;
create policy "operations can read fulfilments" on app.fulfilments
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

drop policy if exists "staff can read fulfilment lines" on app.fulfilment_lines;
create policy "operations can read fulfilment lines" on app.fulfilment_lines
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke insert, update, delete on app.audit_logs from authenticated;

#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-package-finance-race.XXXXXX)"
previous_active_season="$("${psql_cmd[@]}" -Atc "select coalesce(active_season_id::text, '') from app.app_settings where id=true")"
previous_package_flag="$("${psql_cmd[@]}" -Atc "select enabled::text from app.release_feature_flags where key='package_orders_v2'")"
actor_id="f9f00000-0000-4000-8000-000000000001"

wait_for_marker() {
  local log_file="$1" marker="$2"
  for _attempt in $(seq 1 200); do
    if grep -q "$marker" "$log_file" 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  echo "Synchronisatiemarker niet bereikt: $marker"
  tail -n 60 "$log_file" 2>/dev/null || true
  return 1
}

cleanup() {
  set +e
  if [[ -n "${previous_active_season:-}" ]]; then
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id='$previous_active_season' where id=true" >/dev/null
  else
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id=null where id=true" >/dev/null
  fi
  "${psql_cmd[@]}" -c "update app.release_feature_flags set enabled=$previous_package_flag where key='package_orders_v2'" >/dev/null
  "${psql_cmd[@]}" <<'SQL' >/dev/null
begin;
set local session_replication_role=replica;
create temporary table fixture_cleanup_email_jobs(id uuid primary key) on commit drop;
insert into fixture_cleanup_email_jobs(id)
select job.id from private.email_jobs job
join app.member_orders orders on orders.id=job.order_id
where orders.member_season_id::text like 'f9f51000-%';
delete from private.email_delivery_attempt_outcomes where delivery_attempt_id in
  (select attempt.id from private.email_delivery_attempts attempt
   where attempt.email_job_id in (select id from fixture_cleanup_email_jobs));
delete from private.email_delivery_attempt_provider_messages where delivery_attempt_id in
  (select attempt.id from private.email_delivery_attempts attempt
   where attempt.email_job_id in (select id from fixture_cleanup_email_jobs));
delete from app.email_events where email_job_id in (select id from fixture_cleanup_email_jobs);
delete from private.fulfilment_mail_projection_batches where email_job_id in (select id from fixture_cleanup_email_jobs);
delete from private.mail_v2_projection_batches where email_job_id in (select id from fixture_cleanup_email_jobs);
update private.email_jobs set current_delivery_attempt_id=null
where id in (select id from fixture_cleanup_email_jobs);
delete from private.email_delivery_attempts where email_job_id in (select id from fixture_cleanup_email_jobs);
delete from private.email_jobs where id in (select id from fixture_cleanup_email_jobs);
do $cleanup$
declare target record; predicate text;
begin
  for target in
    select table_schema,table_name
    from information_schema.tables
    where table_type='BASE TABLE' and table_schema in ('app','private')
      and (table_schema,table_name) not in (
        ('app','app_settings'),('app','audit_logs'),('app','release_feature_flags')
      )
    order by table_schema,table_name
  loop
    select string_agg(format('%I::text like ''f9f%%''',column_name),' or ')
    into predicate
    from information_schema.columns
    where table_schema=target.table_schema and table_name=target.table_name
      and udt_name='uuid';
    if predicate is not null then
      execute format('delete from %I.%I where %s',target.table_schema,target.table_name,predicate);
    end if;
  end loop;
end;
$cleanup$;
delete from app.audit_logs
where entity_id::text like 'f9f%'
  or correlation_id::text like 'f9f%'
  or metadata::text like '%f9f%';
commit;
SQL
  rm -rf "$test_tmp_dir"
}
trap cleanup EXIT

"${psql_cmd[@]}" -v actor_id="$actor_id" <<'SQL'
begin;
update app.app_settings set active_season_id=null where id=true;
update app.release_feature_flags set enabled=true where key='package_orders_v2';
insert into app.staff_profiles(auth_user_id,display_name,role,active)
values(:'actor_id'::uuid,'Pakket-financerace beheerder','beheerder',true);
insert into app.seasons(id,name,starts_on,ends_on,default_amount_cents,status,opened_at)
values('f9f10000-0000-4000-8000-000000000001','Pakket-financeraces','2055-07-01','2056-06-30',12500,'open',timezone('utc',now()));
insert into app.articles(id,name,code,icon_type,sort_order) values
 ('f9f20000-0000-4000-8000-000000000001','Financerace shirt','F9-SHIRT','shirt',10),
 ('f9f20000-0000-4000-8000-000000000002','Financerace broek','F9-BROEK','circle-dot',20),
 ('f9f20000-0000-4000-8000-000000000003','Financerace keeper','F9-KEEPER','shirt',30);
insert into app.article_variants(id,article_id,size,sku,sort_order) values
 ('f9f30000-0000-4000-8000-000000000001','f9f20000-0000-4000-8000-000000000001','164','F9-SHIRT-164',10),
 ('f9f30000-0000-4000-8000-000000000002','f9f20000-0000-4000-8000-000000000002','164','F9-BROEK-164',10),
 ('f9f30000-0000-4000-8000-000000000003','f9f20000-0000-4000-8000-000000000003','164','F9-KEEPER-164',10);
insert into app.article_seasons(article_id,season_id) values
 ('f9f20000-0000-4000-8000-000000000001','f9f10000-0000-4000-8000-000000000001'),
 ('f9f20000-0000-4000-8000-000000000002','f9f10000-0000-4000-8000-000000000001'),
 ('f9f20000-0000-4000-8000-000000000003','f9f10000-0000-4000-8000-000000000001');
insert into app.package_templates(id,season_id,template_key,created_by)
select ('f9f40000-0000-4000-8000-00000000000'||suffix)::uuid,
 'f9f10000-0000-4000-8000-000000000001','finance-race-'||suffix,:'actor_id'::uuid
from generate_series(1,6) suffix;
insert into app.package_template_revisions(id,template_id,season_id,revision_number,name,
 description,price_cents,status,active,is_default,created_by,published_by,published_at)
select ('f9f41000-0000-4000-8000-00000000000'||suffix)::uuid,
 ('f9f40000-0000-4000-8000-00000000000'||suffix)::uuid,
 'f9f10000-0000-4000-8000-000000000001',1,'Financerace pakket '||suffix,'',
 case when suffix<=3 then 12500 else 10000 end,'draft',false,false,
 :'actor_id'::uuid,null,null
from generate_series(1,6) suffix;
insert into app.package_template_items(id,revision_id,article_id,quantity,
 product_name_snapshot,product_code_snapshot,sort_order,season_id)
select ('f9f42000-0000-4000-8000-00000000000'||suffix)::uuid,
 ('f9f41000-0000-4000-8000-00000000000'||suffix)::uuid,
 ('f9f20000-0000-4000-8000-00000000000'||(((suffix-1)%3)+1))::uuid,
 1,'Financerace component','F9-COMP',10,'f9f10000-0000-4000-8000-000000000001'
from generate_series(1,6) suffix;
update app.package_template_revisions set status='published',active=true,
 is_default=id='f9f41000-0000-4000-8000-000000000001',
 published_by=:'actor_id'::uuid,published_at=timezone('utc',now())
where id::text like 'f9f41000-%';
insert into app.members(id,relation_number,first_name,last_name,email,team)
select ('f9f50000-0000-4000-8000-00000000000'||suffix)::uuid,
 'F9-RACE-'||suffix,'Financerace',suffix::text,'finance-race-'||suffix||'@example.invalid','Race'
from generate_series(1,5) suffix;
insert into app.member_seasons(id,member_id,season_id,team_name,participation_status,reconciliation_status)
select ('f9f51000-0000-4000-8000-00000000000'||suffix)::uuid,
 ('f9f50000-0000-4000-8000-00000000000'||suffix)::uuid,
 'f9f10000-0000-4000-8000-000000000001','Race','active','resolved'
from generate_series(1,5) suffix;
insert into app.member_article_sizes(member_id,season_id,article_id,article_variant_id,
 member_season_id,selection_status,selection_source,confirmed_at,confirmed_by)
select member.id,'f9f10000-0000-4000-8000-000000000001',article.id,variant.id,
 member_season.id,'confirmed','staff',timezone('utc',now()),:'actor_id'::uuid
from app.members member
join app.member_seasons member_season on member_season.member_id=member.id
cross join app.articles article
join app.article_variants variant on variant.article_id=article.id
where member.id::text like 'f9f50000-%' and article.id::text like 'f9f20000-%';
select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
create temporary table finance_fixture_workspace as
select member_season.id member_season_id,
  private.package_workspace_revision(member_season.id) workspace_revision
from app.member_seasons member_season where member_season.id::text like 'f9f51000-%';
grant select on finance_fixture_workspace to authenticated;
set local role authenticated;
select app.select_member_package_v3(workspace.member_season_id,
 'f9f41000-0000-4000-8000-000000000001',workspace.workspace_revision,
 'Financiële concurrencyfixture',
 ('f9f80000-0000-4000-8000-00000000000'||right(workspace.member_season_id::text,1))::uuid,null)
from finance_fixture_workspace workspace;
reset role;
update app.app_settings set active_season_id='f9f10000-0000-4000-8000-000000000001' where id=true;
insert into app.payments(id,order_id,method,status,amount_cents,provider_payment_id,
 idempotency_key,metadata_schema_version,provider_created_at,provider_updated_at)
select 'f9f60000-0000-4000-8000-000000000001',orders.id,'mollie','pending',12500,
 'tr_finrace1','package-finance-race-payment-1',2,timezone('utc',now()),timezone('utc',now())
from app.member_orders orders where orders.member_season_id='f9f51000-0000-4000-8000-000000000001';
insert into app.payments(id,order_id,method,status,amount_cents,idempotency_key,paid_at)
select ('f9f60000-0000-4000-8000-00000000000'||suffix)::uuid,orders.id,'cash','paid',12500,
 'package-finance-race-payment-'||suffix,timezone('utc',now())
from generate_series(2,4) suffix join app.member_orders orders
 on orders.member_season_id=('f9f51000-0000-4000-8000-00000000000'||suffix)::uuid;
insert into app.payments(id,order_id,method,status,amount_cents,provider_payment_id,
 idempotency_key,metadata_schema_version,paid_at,provider_created_at,provider_updated_at)
select 'f9f60000-0000-4000-8000-000000000005',orders.id,'mollie','paid',12500,
 'tr_finrace5','package-finance-race-payment-5',2,timezone('utc',now()),timezone('utc',now()),timezone('utc',now())
from app.member_orders orders where orders.member_season_id='f9f51000-0000-4000-8000-000000000005';
update app.app_settings set active_season_id='f9f10000-0000-4000-8000-000000000001' where id=true;
commit;
SQL

preflight() {
  local member_suffix="$1" revision_suffix="$2" request_suffix="$3" reason="$4"
  "${psql_cmd[@]}" -v actor_id="$actor_id" -At <<SQL
begin;
select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true) as ignored
\gset
set local role authenticated;
select app.preflight_package_change_v2(
 (select id from app.member_orders where member_season_id='f9f51000-0000-4000-8000-00000000000${member_suffix}'),
 'f9f41000-0000-4000-8000-00000000000${revision_suffix}',
 '$reason','f9f81000-0000-4000-8000-00000000000${request_suffix}',null)->>'revision';
commit;
SQL
}

# Pakketwissel versus betaalwebhook: een blocked preflight wordt na provider-paid stale.
payment_revision="$(preflight 1 2 1 'Pakketwissel versus betaalwebhook')"
webhook_log="$test_tmp_dir/webhook.log"; webhook_apply_log="$test_tmp_dir/webhook-apply.log"
("${psql_cmd[@]}" >"$webhook_log" 2>&1 <<'SQL'
begin;
select app.reconcile_mollie_payment_v3('finance-race-webhook-1','tr_finrace1',
 'f9f60000-0000-4000-8000-000000000001','f9f60000-0000-4000-8000-000000000001',
 (select id from app.member_orders where member_season_id='f9f51000-0000-4000-8000-000000000001'),
 'f9f50000-0000-4000-8000-000000000001','f9f51000-0000-4000-8000-000000000001',
 'f9f10000-0000-4000-8000-000000000001',12500,'EUR','paid',timezone('utc',now()),
 timezone('utc',now()),null,timezone('utc',now()),null,null,'{"schema_version":2}'::jsonb);
\echo FINANCE_WEBHOOK_HOLDING
select pg_sleep(1.2);
commit;
SQL
) & webhook_pid=$!
wait_for_marker "$webhook_log" FINANCE_WEBHOOK_HOLDING
set +e
"${psql_cmd[@]}" -v actor_id="$actor_id" >"$webhook_apply_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000001','$payment_revision','SWITCH_PACKAGE',null);
commit;
SQL
webhook_apply_status=$?
wait "$webhook_pid"; webhook_status=$?
set -e
if [[ "$webhook_status" -ne 0 || "$webhook_apply_status" -eq 0 ]] || ! grep -Eq 'PACKAGE_CHANGE_(STALE|BLOCKED)' "$webhook_apply_log"; then
  tail -n 80 "$webhook_log"; tail -n 80 "$webhook_apply_log"; exit 1
fi

# Twee gelijktijdige switches: exact één adjustment/credit wint.
switch_a_revision="$(preflight 2 2 2 'Eerste gelijktijdige pakketcorrectie')"
switch_a_log="$test_tmp_dir/switch-a.log"; switch_b_log="$test_tmp_dir/switch-b.log"
("${psql_cmd[@]}" -v actor_id="$actor_id" >"$switch_a_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000002','$switch_a_revision','SWITCH_PACKAGE',null);
\echo FINANCE_SWITCH_HOLDING
select pg_sleep(1.2); commit;
SQL
) & switch_a_pid=$!
wait_for_marker "$switch_a_log" FINANCE_SWITCH_HOLDING
switch_b_revision="$(preflight 2 3 3 'Tweede gelijktijdige pakketcorrectie')"
wait "$switch_a_pid"
"${psql_cmd[@]}" -v actor_id="$actor_id" >"$switch_b_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000003','$switch_b_revision','SWITCH_PACKAGE',null);
commit;
SQL
switch_state="$("${psql_cmd[@]}" -Atc "select count(*)||':'||(select count(*) from app.package_credit_allocations allocation join app.package_financial_adjustments adjustment on adjustment.id=allocation.adjustment_id where adjustment.order_id=orders.id)||':'||(select count(*) from app.package_refunds refund where refund.order_id=orders.id) from app.package_financial_adjustments financial join app.member_orders orders on orders.id=financial.order_id where orders.member_season_id='f9f51000-0000-4000-8000-000000000002' group by orders.id")"
[[ "$switch_state" == "2:2:0" ]] || { echo "Onverwachte dubbele-switchstaat: $switch_state"; tail -n 80 "$switch_a_log"; tail -n 80 "$switch_b_log"; exit 1; }

# Switch versus allocationworker: de workertransactie voltooit vóór één atomische switch.
allocation_revision="$(preflight 3 2 4 'Pakketwissel versus voorraadallocatie')"
worker_log="$test_tmp_dir/worker.log"; worker_apply_log="$test_tmp_dir/worker-apply.log"
("${psql_cmd[@]}" >"$worker_log" 2>&1 <<'SQL'
begin;
select app.process_inventory_allocation_queue(100);
\echo FINANCE_WORKER_HOLDING
select pg_sleep(1.2); commit;
SQL
) & worker_pid=$!
wait_for_marker "$worker_log" FINANCE_WORKER_HOLDING
"${psql_cmd[@]}" -v actor_id="$actor_id" >"$worker_apply_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000004','$allocation_revision','SWITCH_PACKAGE',null);
commit;
SQL
wait "$worker_pid"
allocation_state="$("${psql_cmd[@]}" -Atc "select count(*) from app.package_financial_adjustments adjustment join app.member_orders orders on orders.id=adjustment.order_id where orders.member_season_id='f9f51000-0000-4000-8000-000000000003'")"
[[ "$allocation_state" == "1" ]] || { tail -n 80 "$worker_log"; tail -n 80 "$worker_apply_log"; exit 1; }

# Refund versus duplicate refund: dezelfde command-ID geeft één bewijsledger en één completion.
manual_revision="$(preflight 4 4 5 'Goedkopere correctie voor dubbele refundrace')"
manual_apply="$("${psql_cmd[@]}" -v actor_id="$actor_id" -At <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000005','$manual_revision','SWITCH_PACKAGE',null)::text;
commit;
SQL
)"
manual_refund_id="$(printf '%s' "$manual_apply" | sed -n 's/.*"refundId": "\([^"]*\)".*/\1/p')"
manual_payment_id="f9f60000-0000-4000-8000-000000000004"
[[ "$manual_refund_id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Handmatige refund-ID ontbreekt"; exit 1; }
manual_a_log="$test_tmp_dir/manual-a.log"; manual_b_log="$test_tmp_dir/manual-b.log"
("${psql_cmd[@]}" -v actor_id="$actor_id" >"$manual_a_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.record_manual_payment_refund_v2('$manual_refund_id','$manual_payment_id',2500,
 'Extern terugbetaald tijdens race','Kasbon F9-001','f9f82000-0000-4000-8000-000000000001',null);
\echo FINANCE_MANUAL_REFUND_HOLDING
select pg_sleep(1.2); commit;
SQL
) & manual_a_pid=$!
wait_for_marker "$manual_a_log" FINANCE_MANUAL_REFUND_HOLDING
"${psql_cmd[@]}" -v actor_id="$actor_id" >"$manual_b_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.record_manual_payment_refund_v2('$manual_refund_id','$manual_payment_id',2500,
 'Extern terugbetaald tijdens race','Kasbon F9-001','f9f82000-0000-4000-8000-000000000001',null);
commit;
SQL
wait "$manual_a_pid"
grep -q '"reused": true' "$manual_b_log" || { tail -n 80 "$manual_a_log"; tail -n 80 "$manual_b_log"; exit 1; }
manual_state="$("${psql_cmd[@]}" -Atc "select refund.status||':'||(select count(*) from private.manual_payment_corrections where request_id='f9f82000-0000-4000-8000-000000000001')||':'||payment.status from app.package_refunds refund join app.payments payment on payment.id=refund.payment_id where refund.id='$manual_refund_id'")"
[[ "$manual_state" == "manual_completed:1:paid" ]] || { echo "Onverwachte dubbele-refundstaat: $manual_state"; exit 1; }

# Refundreconciliatie versus tweede correctie: refundrijlock + statehash maken de oude correctie stale.
mollie_revision="$(preflight 5 4 6 'Goedkopere correctie voor Mollie-refundrace')"
mollie_apply="$("${psql_cmd[@]}" -v actor_id="$actor_id" -At <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000006','$mollie_revision','SWITCH_PACKAGE',null)::text;
commit;
SQL
)"
mollie_refund_id="$(printf '%s' "$mollie_apply" | sed -n 's/.*"refundId": "\([^"]*\)".*/\1/p')"
"${psql_cmd[@]}" -Atc "select app.prepare_mollie_refund_v1('$mollie_refund_id','f9f83000-0000-4000-8000-000000000001',null); select app.bind_mollie_refund_v1('$mollie_refund_id','re_finrace5','pending',timezone('utc',now()));" >/dev/null
second_revision="$(preflight 5 5 7 'Tweede correctie tijdens refundreconciliatie')"
reconcile_log="$test_tmp_dir/reconcile.log"; second_log="$test_tmp_dir/second.log"
("${psql_cmd[@]}" >"$reconcile_log" 2>&1 <<'SQL'
begin;
select app.reconcile_mollie_refunds_v1('tr_finrace5',
 '[{"id":"re_finrace5","status":"refunded","amount":{"currency":"EUR","value":"25.00"}}]'::jsonb,
 timezone('utc',now()));
\echo FINANCE_REFUND_RECONCILE_HOLDING
select pg_sleep(1.2); commit;
SQL
) & reconcile_pid=$!
wait_for_marker "$reconcile_log" FINANCE_REFUND_RECONCILE_HOLDING
set +e
"${psql_cmd[@]}" -v actor_id="$actor_id" >"$second_log" 2>&1 <<SQL
begin; select set_config('request.jwt.claims',jsonb_build_object('sub',:'actor_id','aal','aal2')::text,true);
set local role authenticated;
select app.apply_package_change_v2('f9f81000-0000-4000-8000-000000000007','$second_revision','SWITCH_PACKAGE',null);
commit;
SQL
second_status=$?; wait "$reconcile_pid"; reconcile_status=$?; set -e
if [[ "$reconcile_status" -ne 0 || "$second_status" -eq 0 ]] || ! grep -q 'PACKAGE_CHANGE_STALE' "$second_log"; then
  tail -n 80 "$reconcile_log"; tail -n 80 "$second_log"; exit 1
fi
reconcile_state="$("${psql_cmd[@]}" -Atc "select refund.status||':'||(select count(*) from app.package_financial_adjustments adjustment where adjustment.order_id=refund.order_id) from app.package_refunds refund where refund.id='$mollie_refund_id'")"
[[ "$reconcile_state" == "completed:1" ]] || { echo "Onverwachte refund/re-correctiestaat: $reconcile_state"; exit 1; }

echo "Package-financial-adjustment concurrencytests geslaagd: webhook, dubbele switch, allocationworker, dubbele refund en refund/re-correctie zijn raceveilig."

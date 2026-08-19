-- The active package snapshot is the entitlement. Size selections choose its
-- variants, payment locks those choices, and order lines execute entitlement.
-- Missing execution rows must never reduce the fulfilment denominator.

alter table app.package_size_confirmations
  drop constraint package_size_confirmations_actor_check;
alter table app.package_size_confirmations
  drop constraint package_size_confirmations_source_check;
alter table app.package_size_confirmations
  add constraint package_size_confirmations_source_check
    check (source in ('parent', 'staff', 'system_reconciliation')),
  add constraint package_size_confirmations_actor_check check (
    (source = 'parent' and parent_account_id is not null and staff_user_id is null)
    or (source = 'staff' and staff_user_id is not null and parent_account_id is null)
    or (source = 'system_reconciliation' and staff_user_id is null and parent_account_id is null)
  );
alter table app.member_package_size_selections
  drop constraint member_package_size_selections_confirmed_by_source_check;
alter table app.member_package_size_selections
  add constraint member_package_size_selections_confirmed_by_source_check
    check (confirmed_by_source in ('parent', 'staff', 'system_reconciliation'));

create or replace function private.package_sizes_complete(p_order_id uuid, p_snapshot_id uuid)
returns boolean language sql stable security definer
set search_path = app, private, pg_temp as $$
  select p_order_id is not null and p_snapshot_id is not null
    and exists(select 1 from app.member_package_assignments a where a.id=p_snapshot_id and a.order_id=p_order_id and a.status='active')
    and exists(select 1 from app.order_package_snapshot_items i where i.snapshot_id=p_snapshot_id)
    and not exists(
      select 1 from app.order_package_snapshot_items i
      where i.snapshot_id=p_snapshot_id and not exists(
        select 1 from app.member_package_size_selections s
        join app.article_variants v on v.id=s.selected_variant_id and v.article_id=i.article_id and v.active
        where s.assignment_id=p_snapshot_id and s.snapshot_item_id=i.id
          and s.article_id=i.article_id and s.selection_kind='variant'
      )
    );
$$;

create or replace function private.package_fulfilment_quantities(p_order_id uuid)
returns jsonb language sql stable security definer
set search_path=app,private,pg_temp as $$
  with target as (
    select active_package_snapshot_id snapshot_id from app.member_orders where id=p_order_id
  ), package_items as (
    select i.id, i.quantity, i.order_line_id
    from app.order_package_snapshot_items i join target t on t.snapshot_id=i.snapshot_id
  ), package_totals as (
    select coalesce(sum(i.quantity),0)::int expected,
      coalesce(sum(case when l.status='ready_for_pickup' then l.quantity else 0 end),0)::int ready,
      coalesce(sum(case when l.status='picked_up' then l.quantity else 0 end),0)::int picked,
      coalesce(sum(case when l.id is null or l.status='backorder' then i.quantity else 0 end),0)::int backorder
    from package_items i left join app.order_lines l on l.id=i.order_line_id and l.status<>'cancelled'
  ), loose as (
    select coalesce(sum(l.quantity),0)::int expected,
      coalesce(sum(l.quantity) filter(where l.status='ready_for_pickup'),0)::int ready,
      coalesce(sum(l.quantity) filter(where l.status='picked_up'),0)::int picked,
      coalesce(sum(l.quantity) filter(where l.status='backorder'),0)::int backorder
    from app.order_lines l where l.order_id=p_order_id and l.status<>'cancelled'
      and not exists(select 1 from package_items i where i.order_line_id=l.id)
  ) select jsonb_build_object('expectedQuantity',p.expected+l.expected,
    'readyQuantity',p.ready+l.ready,'pickedUpQuantity',p.picked+l.picked,
    'backorderQuantity',p.backorder+l.backorder) from package_totals p cross join loose l;
$$;
revoke all on function private.package_fulfilment_quantities(uuid) from public,anon,authenticated,service_role;

create or replace function private.ensure_package_size_lifecycle(
  p_order_id uuid, p_source text default 'system_reconciliation', p_lock boolean default false,
  p_parent_account_id uuid default null
) returns jsonb language plpgsql security definer
set search_path=app,private,extensions,pg_temp as $$
declare o app.member_orders%rowtype; c_id uuid; rev integer; item record; line app.order_lines%rowtype;
  materialized int:=0; confirmed int:=0; locked int:=0;
begin
  select * into o from app.member_orders where id=p_order_id for update;
  if not found or o.package_assignment_state<>'active' or o.active_package_snapshot_id is null then
    raise exception 'PACKAGE_SIZES_REQUIRED' using errcode='23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-lifecycle:'||o.id::text,0));
  if exists(
    select 1 from app.order_package_snapshot_items i
    left join app.member_article_sizes s on s.member_season_id=o.member_season_id and s.article_id=i.article_id
    left join app.article_variants v on v.id=s.article_variant_id and v.article_id=i.article_id and v.active
    where i.snapshot_id=o.active_package_snapshot_id
      and (s.article_variant_id is null or v.id is null or s.selection_status in ('conflict','change_requested'))
  ) or not exists(select 1 from app.order_package_snapshot_items i where i.snapshot_id=o.active_package_snapshot_id) then
    raise exception 'PACKAGE_SIZES_REQUIRED' using errcode='23514';
  end if;

  if not private.package_sizes_complete(o.id,o.active_package_snapshot_id) then
    select coalesce(max(revision),0)+1 into rev from app.package_size_confirmations where order_id=o.id;
    insert into app.package_size_confirmations(order_id,member_season_id,revision,source,parent_account_id,staff_user_id,
      selected_count,conflict_count,change_request_count,package_snapshot_id,schema_version)
    values(o.id,o.member_season_id,rev,p_source,case when p_source='parent' then p_parent_account_id else null end,
      case when p_source='staff' then auth.uid() else null end,
      (select count(*) from app.order_package_snapshot_items where snapshot_id=o.active_package_snapshot_id),0,0,
      o.active_package_snapshot_id,2) returning id into c_id;
    insert into app.package_size_confirmation_items(confirmation_id,snapshot_item_id,article_id,selection_kind,
      selected_variant_id,other_note,quantity_snapshot,product_name_snapshot,product_code_snapshot)
    select c_id,i.id,i.article_id,'variant',s.article_variant_id,null,i.quantity,i.product_name_snapshot,i.product_code_snapshot
    from app.order_package_snapshot_items i join app.member_article_sizes s
      on s.member_season_id=o.member_season_id and s.article_id=i.article_id
    where i.snapshot_id=o.active_package_snapshot_id;
    get diagnostics confirmed=row_count;
  end if;

  perform set_config('app.package_size_internal','on',true);
  update app.member_article_sizes s set selection_status=case when p_lock then 'locked' else 'confirmed' end,
    confirmed_at=coalesce(s.confirmed_at,timezone('utc',now())),updated_at=timezone('utc',now())
  where s.member_season_id=o.member_season_id and exists(
    select 1 from app.order_package_snapshot_items i where i.snapshot_id=o.active_package_snapshot_id and i.article_id=s.article_id);
  if p_lock then get diagnostics locked=row_count; end if;

  for item in select i.*,s.selected_variant_id from app.order_package_snapshot_items i
    join app.member_package_size_selections s on s.assignment_id=i.snapshot_id and s.snapshot_item_id=i.id
    where i.snapshot_id=o.active_package_snapshot_id order by i.sort_order,i.id
  loop
    select * into line from app.order_lines l where l.id=item.order_line_id and l.status<>'cancelled' for update;
    if line.id is null then
      insert into app.order_lines(order_id,article_variant_id,quantity,package_template_item_id)
      values(o.id,item.selected_variant_id,item.quantity,item.template_item_id) returning * into line;
      update app.order_package_snapshot_items set order_line_id=line.id,article_variant_id=item.selected_variant_id,
        variant_label_snapshot=line.size_snapshot,size_snapshot=line.size_snapshot where id=item.id;
      materialized:=materialized+1;
    elsif line.article_variant_id is distinct from item.selected_variant_id or line.quantity is distinct from item.quantity then
      if exists(select 1 from app.inventory_reservations r where r.order_line_id=line.id)
        or exists(select 1 from app.fulfilment_lines f where f.order_line_id=line.id) then
        raise exception 'PACKAGE_LINE_HISTORY_REQUIRES_CORRECTION' using errcode='23514';
      end if;
      update app.order_lines set article_variant_id=item.selected_variant_id,quantity=item.quantity,
        package_template_item_id=item.template_item_id,updated_at=timezone('utc',now()) where id=line.id;
    end if;
    perform private.enqueue_inventory_variant(o.season_id,item.selected_variant_id,'package_size_materialized');
  end loop;
  perform set_config('app.package_size_internal','off',true);
  return jsonb_build_object('orderLinesMaterialized',materialized,'sizeSelectionsConfirmed',confirmed,'sizeSelectionsLocked',locked);
end; $$;
revoke all on function private.ensure_package_size_lifecycle(uuid,text,boolean,uuid) from public,anon,authenticated,service_role;

create or replace function app.refresh_order_status(p_order_id uuid) returns text language plpgsql
set search_path=app,private,pg_temp as $$
declare q jsonb; expected int; ready int; picked int; backorder int; next_status text;
begin
  if not exists(select 1 from app.member_orders where id=p_order_id) then raise exception 'ORDER_NOT_FOUND' using errcode='P0002'; end if;
  if not exists(select 1 from app.payments where order_id=p_order_id and status='paid') then next_status:='Nog niet betaald';
  else
    q:=private.package_fulfilment_quantities(p_order_id); expected:=(q->>'expectedQuantity')::int;
    ready:=(q->>'readyQuantity')::int; picked:=(q->>'pickedUpQuantity')::int; backorder:=(q->>'backorderQuantity')::int;
    next_status:=case when expected>0 and picked=expected then 'Afgerond'
      when picked>0 then 'Gedeeltelijk afgehaald' when ready>0 and (backorder>0 or ready<expected) then 'Gedeeltelijk af te halen'
      when expected>0 and ready=expected then 'Volledig af te halen' else 'Nalevering' end;
  end if;
  update app.member_orders set order_status=next_status,updated_at=timezone('utc',now()) where id=p_order_id;
  return next_status;
end; $$;

alter function app.get_member_list_v2(text,text,text,text,uuid,text,app.order_line_status,integer,integer)
  rename to get_member_list_v2_before_package_entitlement;
revoke all on function app.get_member_list_v2_before_package_entitlement(text,text,text,text,uuid,text,app.order_line_status,integer,integer)
  from public,anon,authenticated,service_role;
create function app.get_member_list_v2(
  p_search text default null,p_team text default null,p_payment_filter text default null,p_order_status text default null,
  p_article_id uuid default null,p_size text default null,p_line_status app.order_line_status default null,
  p_limit integer default 50,p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path=app,private,pg_temp as $$
declare result jsonb; members jsonb;
begin
  result:=app.get_member_list_v2_before_package_entitlement(p_search,p_team,p_payment_filter,p_order_status,
    p_article_id,p_size,p_line_status,p_limit,p_offset);
  select coalesce(jsonb_agg(case when member.value->'order' is null then member.value else
    jsonb_set(jsonb_set(member.value,'{order,totalQuantity}',
      to_jsonb((private.package_fulfilment_quantities((member.value#>>'{order,id}')::uuid)->>'expectedQuantity')::int),true),
      '{order,progressQuantity}',to_jsonb((
        (private.package_fulfilment_quantities((member.value#>>'{order,id}')::uuid)->>'readyQuantity')::int+
        (private.package_fulfilment_quantities((member.value#>>'{order,id}')::uuid)->>'pickedUpQuantity')::int)),true)
    end order by member.ordinality),'[]'::jsonb) into members
  from jsonb_array_elements(result->'members') with ordinality member(value,ordinality);
  return jsonb_set(result,'{members}',members,true);
end; $$;
revoke all on function app.get_member_list_v2(text,text,text,text,uuid,text,app.order_line_status,integer,integer) from public,anon;
grant execute on function app.get_member_list_v2(text,text,text,text,uuid,text,app.order_line_status,integer,integer) to authenticated;

alter function public.prepare_mollie_payment(text,uuid,text) rename to prepare_mollie_payment_before_package_sizes;
revoke all on function public.prepare_mollie_payment_before_package_sizes(text,uuid,text) from public,anon,authenticated,service_role;
create function public.prepare_mollie_payment(p_token_hash text,p_order_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=app,private,public,pg_temp as $$
declare result jsonb;
begin
  if private.parent_account_for_member_season(p_token_hash,(select member_season_id from app.member_orders where id=p_order_id)) is null
    then raise exception 'PARENT_ORDER_ACCESS_DENIED' using errcode='42501'; end if;
  perform private.ensure_package_size_lifecycle(p_order_id,'parent',false,
    private.parent_account_for_member_season(p_token_hash,(select member_season_id from app.member_orders where id=p_order_id)));
  result:=public.prepare_mollie_payment_before_package_sizes(p_token_hash,p_order_id,p_idempotency_key);
  perform app.refresh_order_status(p_order_id); return result;
end; $$;
revoke all on function public.prepare_mollie_payment(text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.prepare_mollie_payment(text,uuid,text) to service_role;

alter function app.record_manual_payment_v2(uuid,app.payment_method,integer,text,uuid,uuid)
  rename to record_manual_payment_v2_before_package_sizes;
revoke all on function app.record_manual_payment_v2_before_package_sizes(uuid,app.payment_method,integer,text,uuid,uuid)
  from public,anon,authenticated,service_role;
create function app.record_manual_payment_v2(p_order_id uuid,p_method app.payment_method,p_amount_cents integer,
  p_reason text,p_request_id uuid,p_correlation_id uuid default null) returns jsonb language plpgsql security definer
set search_path=app,private,pg_temp as $$
declare result jsonb;
begin
  perform private.require_admin_aal2();
  perform private.ensure_package_size_lifecycle(p_order_id,'staff',true);
  result:=app.record_manual_payment_v2_before_package_sizes(p_order_id,p_method,p_amount_cents,p_reason,p_request_id,p_correlation_id);
  perform app.refresh_order_status(p_order_id); return result;
end; $$;
revoke all on function app.record_manual_payment_v2(uuid,app.payment_method,integer,text,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function app.record_manual_payment_v2(uuid,app.payment_method,integer,text,uuid,uuid) to authenticated;

alter function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid)
  rename to confirm_parent_package_sizes_v5_before_paid_lock;
revoke all on function public.confirm_parent_package_sizes_v5_before_paid_lock(text,uuid,jsonb,text,uuid,uuid)
  from public,anon,authenticated,service_role;
create function public.confirm_parent_package_sizes_v5(p_token_hash text,p_member_season_id uuid,p_selections jsonb,
  p_expected_revision text,p_request_id uuid,p_correlation_id uuid default null) returns jsonb language plpgsql security definer
set search_path=app,private,public,pg_temp as $$
declare result jsonb; order_id uuid; paid boolean;
begin
  result:=public.confirm_parent_package_sizes_v5_before_paid_lock(p_token_hash,p_member_season_id,p_selections,
    p_expected_revision,p_request_id,p_correlation_id);
  select o.id,exists(select 1 from app.payments p where p.order_id=o.id and p.status='paid') into order_id,paid
  from app.member_orders o where o.member_season_id=p_member_season_id;
  if paid and private.package_sizes_complete(order_id,(select active_package_snapshot_id from app.member_orders where id=order_id)) then
    perform private.ensure_package_size_lifecycle(order_id,'parent',true,
      private.parent_account_for_member_season(p_token_hash,p_member_season_id));
    perform app.refresh_order_status(order_id);
  end if;
  return result;
end; $$;
revoke all on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid) to service_role;

-- Paid transitions never fail on incomplete legacy sizes. Complete selections
-- are locked; incomplete entitlement remains paid and Nalevering.
create or replace function private.lock_paid_package_sizes() returns trigger language plpgsql security definer
set search_path=app,private,pg_temp as $$
begin
  if new.status='paid' and old.status is distinct from 'paid' then
    begin perform private.ensure_package_size_lifecycle(new.order_id,'system_reconciliation',true);
    exception when sqlstate '23514' then
      if sqlerrm <> 'PACKAGE_SIZES_REQUIRED' then raise; end if;
    end;
    perform app.refresh_order_status(new.order_id);
  end if; return new;
end; $$;
create trigger payments_lock_package_sizes after update of status on app.payments
for each row execute function private.lock_paid_package_sizes();

-- Invariant-driven, idempotent reconciliation with a durable aggregate audit.
do $$ declare o record; metrics jsonb:=jsonb_build_object('paidBrokenOrdersDetected',0,'completePrefilledSizesRepaired',0,
  'missingSizesLeftForMemberAction',0,'orderLinesMaterialized',0,'sizeSelectionsConfirmed',0,'sizeSelectionsLocked',0,'statusesRefreshed',0); r jsonb;
begin
  for o in select orders.id from app.member_orders orders where orders.package_assignment_state='active'
    and exists(select 1 from app.payments p where p.order_id=orders.id and p.status='paid')
    and exists(select 1 from app.order_package_snapshot_items i where i.snapshot_id=orders.active_package_snapshot_id)
    and exists(select 1 from app.order_package_snapshot_items i left join app.order_lines l on l.id=i.order_line_id and l.status<>'cancelled'
      where i.snapshot_id=orders.active_package_snapshot_id and l.id is null)
  loop
    metrics:=jsonb_set(metrics,'{paidBrokenOrdersDetected}',to_jsonb((metrics->>'paidBrokenOrdersDetected')::int+1));
    begin
      r:=private.ensure_package_size_lifecycle(o.id,'system_reconciliation',true);
      metrics:=jsonb_set(metrics,'{completePrefilledSizesRepaired}',to_jsonb((metrics->>'completePrefilledSizesRepaired')::int+1));
      metrics:=jsonb_set(metrics,'{orderLinesMaterialized}',to_jsonb((metrics->>'orderLinesMaterialized')::int+(r->>'orderLinesMaterialized')::int));
      metrics:=jsonb_set(metrics,'{sizeSelectionsConfirmed}',to_jsonb((metrics->>'sizeSelectionsConfirmed')::int+(r->>'sizeSelectionsConfirmed')::int));
      metrics:=jsonb_set(metrics,'{sizeSelectionsLocked}',to_jsonb((metrics->>'sizeSelectionsLocked')::int+(r->>'sizeSelectionsLocked')::int));
    exception when sqlstate '23514' then
      if sqlerrm<>'PACKAGE_SIZES_REQUIRED' then raise; end if;
      metrics:=jsonb_set(metrics,'{missingSizesLeftForMemberAction}',to_jsonb((metrics->>'missingSizesLeftForMemberAction')::int+1));
    end;
    perform app.refresh_order_status(o.id);
    metrics:=jsonb_set(metrics,'{statusesRefreshed}',to_jsonb((metrics->>'statusesRefreshed')::int+1));
  end loop;
  insert into app.audit_logs(actor_user_id,action,entity_type,metadata)
  values(null,'package_lifecycle.reconciled','system',metrics);
  insert into private.migration_reconciliations(migration_key,status,metrics)
  values('20260819130000_package_size_payment_lifecycle','passed',metrics)
  on conflict(migration_key) do update set status=excluded.status,metrics=excluded.metrics,reconciled_at=timezone('utc',now());
end $$;

notify pgrst,'reload schema';

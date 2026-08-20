-- The active package snapshot is the entitlement. Size selections choose its
-- variants after explicit confirmation, and order lines execute entitlement.
-- Missing execution rows must never reduce the fulfilment denominator.

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

create or replace function private.ensure_package_size_lifecycle(p_order_id uuid)
returns jsonb language plpgsql security definer
set search_path=app,private,extensions,pg_temp as $$
declare o app.member_orders%rowtype; item record; line app.order_lines%rowtype;
  matching_line_count int; materialized int:=0; linked int:=0;
begin
  select * into o from app.member_orders where id=p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode='P0002';
  end if;
  if o.package_revision_id is null then
    return jsonb_build_object('orderLinesMaterialized',0,'snapshotItemsLinked',0);
  end if;
  if o.package_assignment_state<>'active' or o.active_package_snapshot_id is null then
    raise exception 'PACKAGE_SIZES_REQUIRED' using errcode='23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('package-lifecycle:'||o.id::text,0));
  if not private.package_sizes_complete(o.id,o.active_package_snapshot_id) then
    raise exception 'PACKAGE_SIZES_REQUIRED' using errcode='23514';
  end if;

  for item in select i.*,s.selected_variant_id from app.order_package_snapshot_items i
    join app.member_package_size_selections s on s.assignment_id=i.snapshot_id and s.snapshot_item_id=i.id
    where i.snapshot_id=o.active_package_snapshot_id order by i.sort_order,i.id
  loop
    line := null;
    select * into line from app.order_lines l where l.id=item.order_line_id and l.status<>'cancelled' for update;
    if item.order_line_id is not null and line.id is null then
      raise exception 'PACKAGE_LINE_STATE_REQUIRES_CORRECTION' using errcode='23514';
    end if;
    if line.id is null then
      select count(*),(array_agg(l.id order by l.created_at,l.id))[1]
      into matching_line_count,line.id
      from app.order_lines l where l.order_id=o.id and l.status<>'cancelled'
        and l.package_template_item_id=item.template_item_id and l.article_id=item.article_id;
      if matching_line_count>1 then
        raise exception 'PACKAGE_ACTIVE_LINE_DUPLICATE' using errcode='23514';
      elsif matching_line_count=1 then
        select * into line from app.order_lines l where l.id=line.id for update;
      end if;
    end if;
    if line.id is null then
      insert into app.order_lines(order_id,article_variant_id,quantity,package_template_item_id)
      values(o.id,item.selected_variant_id,item.quantity,item.template_item_id) returning * into line;
      materialized:=materialized+1;
    elsif line.order_id is distinct from o.id
      or line.article_variant_id is distinct from item.selected_variant_id
      or line.quantity is distinct from item.quantity
      or line.package_template_item_id is distinct from item.template_item_id then
      raise exception 'PACKAGE_LINE_STATE_REQUIRES_CORRECTION' using errcode='23514';
    end if;
    update app.order_package_snapshot_items set order_line_id=line.id,article_variant_id=item.selected_variant_id,
      variant_label_snapshot=line.size_snapshot,size_snapshot=line.size_snapshot where id=item.id and order_line_id is null;
    if found then linked:=linked+1; end if;
    perform private.enqueue_inventory_variant(o.season_id,item.selected_variant_id,'package_size_materialized');
  end loop;
  return jsonb_build_object('orderLinesMaterialized',materialized,'snapshotItemsLinked',linked);
end; $$;
revoke all on function private.ensure_package_size_lifecycle(uuid) from public,anon,authenticated,service_role;

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
  perform private.ensure_package_size_lifecycle(p_order_id);
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
  perform private.ensure_package_size_lifecycle(p_order_id);
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
    perform private.ensure_package_size_lifecycle(order_id);
    perform app.refresh_order_status(order_id);
  end if;
  return result;
end; $$;
revoke all on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.confirm_parent_package_sizes_v5(text,uuid,jsonb,text,uuid,uuid) to service_role;

-- Paid transitions never fail on incomplete or ambiguous legacy execution.
-- Payment remains the authoritative fact; follow-up stays auditably visible.
create or replace function private.lock_paid_package_sizes() returns trigger language plpgsql security definer
set search_path=app,private,pg_temp as $$
begin
  if new.status='paid' and old.status is distinct from 'paid' and exists(
    select 1 from app.member_orders orders
    where orders.id=new.order_id and orders.package_revision_id is not null
  ) then
    begin perform private.ensure_package_size_lifecycle(new.order_id);
    exception when others then
      insert into app.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
      values(null,'package_lifecycle.paid_followup_required','member_order',new.order_id,
        jsonb_build_object('errorCode',sqlstate));
    end;
    perform app.refresh_order_status(new.order_id);
  end if; return new;
end; $$;
create trigger payments_lock_package_sizes after update of status on app.payments
for each row execute function private.lock_paid_package_sizes();

-- Reconcile only execution rows backed by explicit package-wide confirmation.
-- Any incomplete or ambiguous paid order remains untouched and is auditable.
do $$ declare o record; metrics jsonb:=jsonb_build_object('paidOrdersDetected',0,'paidOrdersReconciled',0,
  'paidOrdersReviewRequired',0,'orderLinesMaterialized',0,'snapshotItemsLinked',0);
begin
  for o in select orders.id from app.member_orders orders where orders.package_assignment_state='active'
    and orders.package_revision_id is not null
    and exists(select 1 from app.payments p where p.order_id=orders.id and p.status='paid')
    and exists(select 1 from app.order_package_snapshot_items i where i.snapshot_id=orders.active_package_snapshot_id)
    and exists(select 1 from app.order_package_snapshot_items i left join app.order_lines l on l.id=i.order_line_id and l.status<>'cancelled'
      where i.snapshot_id=orders.active_package_snapshot_id and l.id is null)
  loop
    metrics:=jsonb_set(metrics,'{paidOrdersDetected}',to_jsonb((metrics->>'paidOrdersDetected')::int+1));
    metrics:=jsonb_set(metrics,'{paidOrdersReviewRequired}',to_jsonb((metrics->>'paidOrdersReviewRequired')::int+1));
    insert into app.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
    values(null,'package_lifecycle.review_required','member_order',o.id,
      jsonb_build_object('errorCode','LEGACY_PACKAGE_EXECUTION_REQUIRES_REVIEW'));
  end loop;
  insert into private.migration_reconciliations(migration_key,status,metrics)
  values('20260819130000_package_size_payment_lifecycle',
    case when (metrics->>'paidOrdersReviewRequired')::int=0 then 'passed' else 'failed' end,metrics)
  on conflict(migration_key) do update set status=excluded.status,metrics=excluded.metrics,reconciled_at=timezone('utc',now());
end $$;

notify pgrst,'reload schema';

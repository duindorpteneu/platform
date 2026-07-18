drop function if exists public.get_parent_members(text);

create function public.get_parent_members(p_token_hash text)
returns table (
  member_id uuid,
  relation_number text,
  first_name text,
  insertion text,
  last_name text,
  team text,
  order_id uuid,
  amount_due_cents integer,
  payment_status text,
  order_status text,
  article_lines jsonb,
  qr_version integer
)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select m.id, m.relation_number, m.first_name, m.insertion, m.last_name, m.team,
    mo.id, mo.amount_due_cents,
    coalesce((select p.status::text from app.payments p where p.order_id = mo.id order by p.created_at desc limit 1), 'open'),
    mo.order_status,
    coalesce((select jsonb_agg(jsonb_build_object('id', ol.id, 'article', a.name, 'size', av.size, 'quantity', ol.quantity, 'status', ol.status::text) order by a.sort_order, av.size)
      from app.order_lines ol join app.article_variants av on av.id = ol.article_variant_id join app.articles a on a.id = av.article_id
      where ol.order_id = mo.id), '[]'::jsonb),
    (select qt.version from private.qr_tokens qt where qt.order_id = mo.id and qt.active = true limit 1)
  from private.parent_sessions ps
  join private.parent_member_links pml on pml.parent_account_id = ps.parent_account_id and pml.unlinked_at is null
  join app.members m on m.id = pml.member_id and m.active_for_season = true
  left join app.member_orders mo on mo.member_id = m.id
  where ps.token_hash = p_token_hash and ps.revoked_at is null and ps.expires_at > timezone('utc', now());
$$;

revoke all on function public.get_parent_members(text) from public, anon, authenticated;
grant execute on function public.get_parent_members(text) to service_role;

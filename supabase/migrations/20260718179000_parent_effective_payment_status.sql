create or replace function public.get_parent_members(p_token_hash text)
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
  select member.id, member.relation_number, member.first_name, member.insertion, member.last_name, member.team,
    orders.id, orders.amount_due_cents,
    coalesce((
      select payment.status::text
      from app.payments payment
      where payment.order_id = orders.id
      order by case payment.status
        when 'paid' then 1
        when 'refunded' then 2
        when 'duplicate_paid' then 3
        else 4
      end, payment.created_at desc
      limit 1
    ), 'open'),
    orders.order_status,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.size_snapshot)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status <> 'cancelled'
    ), '[]'::jsonb),
    (select token.version from private.qr_tokens token where token.order_id = orders.id and token.active = true limit 1)
  from private.parent_sessions session
  join private.parent_member_links link on link.parent_account_id = session.parent_account_id and link.unlinked_at is null
  join app.members member on member.id = link.member_id and member.active_for_season = true
  left join app.member_orders orders on orders.member_id = member.id
  where session.token_hash = p_token_hash and session.revoked_at is null
    and session.expires_at > timezone('utc', now());
$$;

revoke all on function public.get_parent_members(text) from public, anon, authenticated;
grant execute on function public.get_parent_members(text) to service_role;

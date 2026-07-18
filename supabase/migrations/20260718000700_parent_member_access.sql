create or replace function public.get_parent_session(p_token_hash text)
returns table (parent_account_id uuid, email_normalized text)
language sql
security definer
set search_path = private, pg_temp
as $$
  select pa.id, pa.email_normalized
  from private.parent_sessions ps
  join private.parent_accounts pa on pa.id = ps.parent_account_id
  where ps.token_hash = p_token_hash
    and ps.revoked_at is null
    and ps.expires_at > timezone('utc', now());
$$;

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
  article_lines jsonb
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
      where ol.order_id = mo.id), '[]'::jsonb)
  from private.parent_sessions ps
  join private.parent_member_links pml on pml.parent_account_id = ps.parent_account_id and pml.unlinked_at is null
  join app.members m on m.id = pml.member_id and m.active_for_season = true
  left join app.member_orders mo on mo.member_id = m.id
  where ps.token_hash = p_token_hash and ps.revoked_at is null and ps.expires_at > timezone('utc', now());
$$;

create or replace function public.get_parent_candidates(p_token_hash text)
returns table (member_id uuid, relation_number text, first_name text, insertion text, last_name text, team text)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select m.id, m.relation_number, m.first_name, m.insertion, m.last_name, m.team
  from private.parent_sessions ps
  join private.parent_accounts pa on pa.id = ps.parent_account_id
  join app.members m on lower(m.email) = pa.email_normalized and m.active_for_season = true
  where ps.token_hash = p_token_hash and ps.revoked_at is null and ps.expires_at > timezone('utc', now())
    and not exists (select 1 from private.parent_member_links pml where pml.parent_account_id = pa.id and pml.member_id = m.id and pml.unlinked_at is null);
$$;

create or replace function public.link_parent_member(p_token_hash text, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare account_id uuid; account_email text; member_email text; link_id uuid;
begin
  select parent_account_id, email_normalized into account_id, account_email from public.get_parent_session(p_token_hash) limit 1;
  if account_id is null then raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501'; end if;
  select lower(email) into member_email from app.members where id = p_member_id and active_for_season = true;
  if member_email is null or member_email <> account_email then raise exception 'MEMBER_LINK_NOT_ALLOWED' using errcode = '42501'; end if;
  insert into private.parent_member_links (parent_account_id, member_id, unlinked_at)
  values (account_id, p_member_id, null)
  on conflict (parent_account_id, member_id) do update set unlinked_at = null, linked_at = timezone('utc', now())
  returning id into link_id;
  return jsonb_build_object('linkId', link_id, 'memberId', p_member_id);
end;
$$;

create or replace function public.unlink_parent_member(p_token_hash text, p_link_id uuid)
returns boolean
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare account_id uuid; affected integer;
begin
  select parent_account_id into account_id from public.get_parent_session(p_token_hash) limit 1;
  if account_id is null then raise exception 'PARENT_SESSION_REQUIRED' using errcode = '42501'; end if;
  update private.parent_member_links set unlinked_at = timezone('utc', now())
  where id = p_link_id and parent_account_id = account_id and unlinked_at is null;
  get diagnostics affected = row_count;
  return affected > 0;
end;
$$;

revoke all on function public.get_parent_session(text) from public, anon, authenticated;
revoke all on function public.get_parent_members(text) from public, anon, authenticated;
revoke all on function public.get_parent_candidates(text) from public, anon, authenticated;
revoke all on function public.link_parent_member(text, uuid) from public, anon, authenticated;
revoke all on function public.unlink_parent_member(text, uuid) from public, anon, authenticated;
grant execute on function public.get_parent_session(text) to service_role;
grant execute on function public.get_parent_members(text) to service_role;
grant execute on function public.get_parent_candidates(text) to service_role;
grant execute on function public.link_parent_member(text, uuid) to service_role;
grant execute on function public.unlink_parent_member(text, uuid) to service_role;

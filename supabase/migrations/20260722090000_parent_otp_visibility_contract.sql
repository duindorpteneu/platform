create or replace function public.parent_otp_members_visible(
  p_member_ids uuid[],
  p_email text
)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select
    p_member_ids is not null
    and cardinality(p_member_ids) between 1 and 10
    and cardinality(p_member_ids) = (
      select count(distinct member.id)::integer
      from app.members member
      where member.id = any(p_member_ids)
        and member.active_for_season = true
        and lower(trim(member.email)) = lower(trim(p_email))
    );
$$;

revoke all on function public.parent_otp_members_visible(uuid[], text)
from public, anon, authenticated;
grant execute on function public.parent_otp_members_visible(uuid[], text)
to service_role;

notify pgrst, 'reload schema';

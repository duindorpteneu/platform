-- A package can be selected before an order exists, so the optimistic
-- workspace revision belongs to the member-season rather than to the order.

create or replace function public.get_parent_package_workspace_v2(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        member.value || jsonb_build_object(
          'revision',
          private.package_workspace_revision(
            (member.value->>'memberSeasonId')::uuid
          )
        )
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality as member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from (
    select public.get_parent_package_workspace(p_token_hash) result
  ) workspace;
$$;

revoke all on function public.get_parent_package_workspace_v2(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v2(text)
to service_role;

notify pgrst, 'reload schema';

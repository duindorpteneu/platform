create or replace function private.parent_package_item_with_icon(
  p_item jsonb
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select p_item || jsonb_build_object(
    'iconType',
    coalesce((
      select article.icon_type::text
      from app.articles article
      where article.id = (p_item->>'articleId')::uuid
    ), 'package')
  );
$$;

revoke all on function private.parent_package_item_with_icon(jsonb)
from public, anon, authenticated, service_role;

create or replace function public.get_parent_package_workspace_v5(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, public, pg_temp
as $$
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        jsonb_set(
          case
            when member.value->'order' is null
              or jsonb_typeof(member.value->'order') = 'null'
            then member.value
            else jsonb_set(
              member.value,
              '{order,items}',
              coalesce((
                select jsonb_agg(
                  private.parent_package_item_with_icon(item.value)
                  order by item.ordinality
                )
                from jsonb_array_elements(
                  coalesce(member.value #> '{order,items}', '[]'::jsonb)
                ) with ordinality as item(value, ordinality)
              ), '[]'::jsonb),
              true
            )
          end,
          '{availablePackages}',
          coalesce((
            select jsonb_agg(
              jsonb_set(
                package.value,
                '{items}',
                coalesce((
                  select jsonb_agg(
                    private.parent_package_item_with_icon(item.value)
                    order by item.ordinality
                  )
                  from jsonb_array_elements(
                    coalesce(package.value->'items', '[]'::jsonb)
                  ) with ordinality as item(value, ordinality)
                ), '[]'::jsonb),
                true
              )
              order by package.ordinality
            )
            from jsonb_array_elements(
              coalesce(member.value->'availablePackages', '[]'::jsonb)
            ) with ordinality as package(value, ordinality)
          ), '[]'::jsonb),
          true
        )
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality as member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from (
    select public.get_parent_package_workspace_v4(p_token_hash) result
  ) workspace;
$$;

revoke execute on function public.get_parent_package_workspace_v4(text)
from service_role;
revoke all on function public.get_parent_package_workspace_v5(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v5(text)
to service_role;

notify pgrst, 'reload schema';

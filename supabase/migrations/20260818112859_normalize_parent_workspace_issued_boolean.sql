create or replace function public.get_parent_package_workspace_v6(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, public, pg_temp
as $function$
  with workspace as (
    select public.get_parent_package_workspace_v5(p_token_hash) result
  )
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        case
          when exists(
            select 1
            from app.member_orders orders
            where orders.member_season_id =
                (member.value->>'memberSeasonId')::uuid
              and orders.package_assignment_state = 'withdrawn'
          ) then jsonb_set(
            member.value,
            '{order}',
            'null'::jsonb,
            true
          )
          when jsonb_typeof(
            member.value #> '{order,items}'
          ) = 'array'
          then jsonb_set(
            member.value,
            '{order,items}',
            coalesce((
              select jsonb_agg(
                case
                  when order_item.value->'issued' = 'null'::jsonb
                  then jsonb_set(
                    order_item.value,
                    '{issued}',
                    'false'::jsonb,
                    false
                  )
                  else order_item.value
                end
                order by order_item.ordinality
              )
              from jsonb_array_elements(
                member.value #> '{order,items}'
              ) with ordinality order_item(value, ordinality)
            ), '[]'::jsonb),
            false
          )
          else member.value
        end
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from workspace;
$function$;

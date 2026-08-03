-- Remove broad table-shaped access to package-size internals. Staff reads use
-- role-cut RPC projections so parent identifiers and free text never become
-- generally selectable by every authenticated staff role.

drop policy if exists "clothing staff can read member sizes"
  on app.member_article_sizes;
drop policy if exists "clothing staff can read package size confirmations"
  on app.package_size_confirmations;
drop policy if exists "clothing staff can read package size confirmation items"
  on app.package_size_confirmation_items;
drop policy if exists "clothing staff can read package size change requests"
  on app.package_size_change_requests;
drop policy if exists "clothing staff can read size selection history"
  on app.member_size_selection_history;

revoke select on table app.member_article_sizes from authenticated;
revoke select on table app.package_size_confirmations from authenticated;
revoke select on table app.package_size_confirmation_items from authenticated;
revoke select on table app.package_size_change_requests from authenticated;
revoke select on table app.member_size_selection_history from authenticated;

create or replace function app.get_catalog_order_workspace_v4()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb;
  active_season uuid;
  role_name app.staff_role;
begin
  role_name := app.staff_role();
  if role_name not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  workspace := app.get_catalog_order_workspace_v3();
  active_season := nullif(workspace->'activeSeason'->>'id', '')::uuid;
  return workspace || jsonb_build_object(
    'packageSizeChangeRequests',
    case
      when role_name = 'beheerder' and active_season is not null then
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'requestId', request.id,
            'memberId', member_season.member_id,
            'memberSeasonId', member_season.id,
            'memberName', concat_ws(
              ' ',
              member.first_name,
              nullif(member.insertion, ''),
              member.last_name
            ),
            'team', member_season.team_name,
            'articleId', request.article_id,
            'articleName', article.name,
            'currentVariantId', request.current_variant_id,
            'currentSize', current_variant.size,
            'requestedKind', case
              when request.requested_variant_id is null then 'other'
              else 'variant'
            end,
            'requestedVariantId', request.requested_variant_id,
            'requestedSize', requested_variant.size,
            'requestedRawValue', request.requested_raw_value,
            'requestedMemberNote', request.requested_member_note,
            'requestedAt', request.requested_at,
            'revision', private.package_workspace_revision(
              request.member_season_id
            ),
            'variants', coalesce((
              select jsonb_agg(jsonb_build_object(
                'id', variant.id,
                'label', variant.size
              ) order by variant.sort_order, lower(variant.size), variant.id)
              from app.article_variants variant
              join app.article_seasons article_season
                on article_season.article_id = variant.article_id
                and article_season.season_id = member_season.season_id
              where variant.article_id = request.article_id
                and variant.active
            ), '[]'::jsonb)
          ) order by request.requested_at, request.id)
          from app.package_size_change_requests request
          join app.member_seasons member_season
            on member_season.id = request.member_season_id
            and member_season.season_id = active_season
          join app.members member on member.id = member_season.member_id
          join app.articles article on article.id = request.article_id
          join app.article_variants current_variant
            on current_variant.id = request.current_variant_id
          left join app.article_variants requested_variant
            on requested_variant.id = request.requested_variant_id
          where request.status = 'requested'
        ), '[]'::jsonb)
      else '[]'::jsonb
    end
  );
end;
$$;

revoke execute on function app.get_catalog_order_workspace_v3()
from authenticated;
revoke all on function app.get_catalog_order_workspace_v4()
from public, anon;
grant execute on function app.get_catalog_order_workspace_v4()
to authenticated;

notify pgrst, 'reload schema';

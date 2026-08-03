-- Resolve package-size requests in the same global lock order as parent
-- confirmation, package selection, allocation and fulfilment:
-- member -> member-season -> order lifecycle rows.

create or replace function app.resolve_package_size_change_v3(
  p_request_id uuid,
  p_decision text,
  p_approved_variant_id uuid,
  p_reason text,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_member_season_id uuid;
begin
  perform private.require_admin_aal2();
  select member_season.member_id, request.member_season_id
  into target_member_id, target_member_season_id
  from app.package_size_change_requests request
  join app.member_seasons member_season
    on member_season.id = request.member_season_id
  where request.id = p_request_id;
  if target_member_id is null then
    raise exception 'PACKAGE_SIZE_CHANGE_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || target_member_season_id::text,
      0
    )
  );
  return app.resolve_package_size_change_v2(
    p_request_id,
    p_decision,
    p_approved_variant_id,
    p_reason,
    p_expected_revision,
    p_correlation_id
  );
end;
$$;

revoke execute on function app.resolve_package_size_change_v2(
  uuid, text, uuid, text, text, uuid
) from authenticated;
revoke all on function app.resolve_package_size_change_v3(
  uuid, text, uuid, text, text, uuid
) from public, anon;
grant execute on function app.resolve_package_size_change_v3(
  uuid, text, uuid, text, text, uuid
) to authenticated;

notify pgrst, 'reload schema';

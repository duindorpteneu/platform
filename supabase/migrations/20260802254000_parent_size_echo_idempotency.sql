-- A historical size can be deactivated after it was confirmed, reserved or
-- issued. Parents must still be able to echo that exact value as part of a
-- package-wide confirmation, but they may never select another inactive SKU.
--
-- A retry with a fresh client request id and the same still-open reserved-size
-- request is also a semantic no-op. It records a confirmation fact without
-- resetting the request episode, its FIFO timestamp or its action item.
do $migration$
declare
  function_source text;
  needle text;
  replacement text;
begin
  function_source := pg_get_functiondef(
    'public.confirm_parent_package_sizes(text,uuid,jsonb,text,uuid)'::regprocedure
  );

  needle := $needle$
        and variant.active
$needle$;
  replacement := $replacement$
        and (
          variant.active
          or exists(
            select 1
            from app.member_article_sizes existing_size
            where existing_size.member_season_id = p_member_season_id
              and existing_size.article_id = selected_article_id
              and (
                existing_size.article_variant_id = selected_variant_id
                or (
                  existing_size.selection_status = 'change_requested'
                  and existing_size.requested_article_variant_id =
                    selected_variant_id
                )
              )
          )
        )
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_ACTIVE_VARIANT_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  needle := $needle$
    differs := case
      when selected_kind = 'variant' then
        size_profile.article_variant_id is distinct from selected_variant_id
        or size_profile.selection_status = 'conflict'
        or (
          size_profile.selection_status = 'change_requested'
          and size_profile.requested_article_variant_id
            is distinct from selected_variant_id
        )
      else
        size_profile.selection_status is distinct from 'conflict'
        or size_profile.selection_source is distinct from 'parent'
        or size_profile.raw_value is distinct from 'Anders…'
        or size_profile.member_note is distinct from selected_note
    end;
$needle$;
  replacement := $replacement$
    differs := case
      when selected_kind = 'variant' then
        case
          when size_profile.selection_status = 'change_requested' then
            size_profile.requested_article_variant_id
              is distinct from selected_variant_id
            or size_profile.requested_raw_value is not null
          else
            size_profile.article_variant_id is distinct from selected_variant_id
            or size_profile.selection_status = 'conflict'
        end
      else
        case
          when size_profile.selection_status = 'change_requested' then
            size_profile.requested_article_variant_id is not null
            or size_profile.requested_raw_value is distinct from 'Anders…'
            or size_profile.requested_member_note is distinct from selected_note
          else
            size_profile.selection_status is distinct from 'conflict'
            or size_profile.selection_source is distinct from 'parent'
            or size_profile.raw_value is distinct from 'Anders…'
            or size_profile.member_note is distinct from selected_note
        end
    end;
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_DIFF_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  needle := $needle$
      change_request_count := change_request_count + 1;
    elsif selected_kind = 'variant' then
$needle$;
  replacement := $replacement$
      change_request_count := change_request_count + 1;
    elsif not differs then
      if size_profile.selection_status = 'change_requested' then
        change_request_count := change_request_count + 1;
      elsif selected_kind = 'other' then
        conflict_count := conflict_count + 1;
      end if;
    elsif selected_kind = 'variant' then
$replacement$;
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_NOOP_PATCH_AMBIGUOUS';
  end if;
  function_source := replace(function_source, needle, replacement);

  execute function_source;
end;
$migration$;

-- Only the latest workspace contract is callable by the application role.
revoke execute on function public.get_parent_package_workspace(text)
from service_role;

notify pgrst, 'reload schema';

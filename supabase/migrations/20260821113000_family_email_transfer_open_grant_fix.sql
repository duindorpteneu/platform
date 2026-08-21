-- Reuse unresolved target grants during a family e-mail transfer and keep the
-- resulting access batch/mail lifecycle operationally complete.
--
-- The original function definition is immutable in its applied migration. A
-- forward-only replacement is derived from that exact definition so this
-- hotfix stays small while failing closed if its predecessor ever diverges.

do $migration$
declare
  function_signature regprocedure :=
    'app.update_member_profile_v2(uuid,uuid,text,text,text,text,date,app.gender_code,text,text,text,text,uuid,uuid)'::regprocedure;
  function_definition text;
  old_grant_match text := $old$
          and grant_row.status in ('pending_account', 'review_required')
          and grant_row.parent_account_id is not distinct from new_parent_account_id
$old$;
  new_grant_match text := $new$
          and grant_row.status in ('pending_account', 'review_required')
          and (
            grant_row.parent_account_id is null
            or grant_row.parent_account_id = new_parent_account_id
          )
$new$;
  old_batch_boundary text := $old$
    end loop;

    select count(*)::integer into old_authorized_count
$old$;
  new_batch_boundary text := $new$
    end loop;

    update private.parent_access_batches batch
    set result = jsonb_build_object(
          'operation', 'activate',
          'seasonId', active_season_id,
          'selectedCount', cardinality(family_member_season_ids),
          'changedCount', cardinality(family_member_season_ids),
          'unchangedCount', 0,
          'groupCount', 1,
          'inviteJobCount', 1,
          'sessionsRevoked', 0,
          'committed', true,
          'reused', false
        ),
        completed_at = now_utc
    where batch.id = activation_batch.id;
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    ) values (
      actor,
      'parent.access.batch_activated',
      'parent_access_batch',
      activation_batch.id,
      jsonb_build_object(
        'seasonId', active_season_id,
        'selectedCount', cardinality(family_member_season_ids),
        'changedCount', cardinality(family_member_season_ids),
        'unchangedCount', 0,
        'inviteJobCount', 1,
        'familyEmailTransfer', true,
        'requestId', p_request_id
      ),
      p_correlation_id
    );

    select count(*)::integer into old_authorized_count
$new$;
begin
  select pg_get_functiondef(function_signature) into function_definition;

  if function_definition is null
    or length(function_definition) - length(replace(function_definition, old_grant_match, ''))
      <> length(old_grant_match)
    or length(function_definition) - length(replace(function_definition, old_batch_boundary, ''))
      <> length(old_batch_boundary)
    or length(function_definition) - length(replace(
      function_definition, 'access_transferred_before_send', ''
    )) <> length('access_transferred_before_send')
  then
    raise exception 'FAMILY_EMAIL_TRANSFER_PREDECESSOR_MISMATCH'
      using errcode = '23514';
  end if;

  function_definition := replace(
    function_definition,
    old_grant_match,
    new_grant_match
  );
  function_definition := replace(
    function_definition,
    old_batch_boundary,
    new_batch_boundary
  );
  function_definition := replace(
    function_definition,
    'access_transferred_before_send',
    'access_revoked_before_send'
  );
  execute function_definition;
end;
$migration$;

revoke all on function app.update_member_profile_v2(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, text, uuid, uuid
) from public, anon;
grant execute on function app.update_member_profile_v2(
  uuid, uuid, text, text, text, text, date, app.gender_code,
  text, text, text, text, uuid, uuid
) to authenticated;

notify pgrst, 'reload schema';

-- Legacy plaintext templates remain available during the mail-v2 cutover, but
-- changing any template is an administrative AAL2 operation.
create or replace function app.update_email_template(
  p_template_id uuid,
  p_subject_source text,
  p_body_source text,
  p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_key text;
begin
  perform private.require_admin_aal2();

  select template.template_key into target_key
  from app.email_templates template
  where template.id = p_template_id;
  if target_key is null then
    raise exception 'EMAIL_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;

  if target_key = 'verification_code'
    and strpos(
      p_subject_source || E'\n' || p_body_source,
      '{{verificatiecode}}'
    ) = 0
  then
    raise exception 'EMAIL_VERIFICATION_CODE_REQUIRED' using errcode = '23514';
  end if;

  if target_key = 'portal_access_invite'
    and strpos(
      p_subject_source || E'\n' || p_body_source,
      '{{portaal_url}}'
    ) = 0
  then
    raise exception 'EMAIL_PORTAL_URL_REQUIRED' using errcode = '23514';
  end if;

  return app.update_email_template_core_v2(
    p_template_id,
    p_subject_source,
    p_body_source,
    p_expected_version
  );
end;
$$;

revoke all on function app.update_email_template(uuid, text, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function app.update_email_template(uuid, text, text, integer)
  to authenticated;

comment on function app.update_email_template(uuid, text, text, integer) is
  'Legacy cutover mutation; beheerder with aal2 only. Mail-v2 is the target catalog.';

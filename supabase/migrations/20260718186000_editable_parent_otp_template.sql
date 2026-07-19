update app.email_templates
set body_source = 'Uw verificatiecode is {{verificatiecode}}. Deze code is tien minuten geldig en eenmalig te gebruiken. Deel de code niet. Vragen? {{contact_email}}',
    allowed_shortcodes = array['{{verificatiecode}}', '{{clubnaam}}', '{{contact_email}}'],
    version = version + 1,
    updated_at = timezone('utc', now())
where template_key = 'verification_code';

drop function app.update_email_template(uuid, text, text, integer);

alter function app.update_email_template_core(uuid, text, text, integer)
rename to update_email_template_core_v2;

revoke all on function app.update_email_template_core_v2(uuid, text, text, integer)
from public, anon, authenticated, service_role;

create or replace function app.update_email_template(
  p_template_id uuid, p_subject_source text, p_body_source text, p_expected_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare target_key text;
begin
  select template_key into target_key from app.email_templates where id = p_template_id;
  if target_key is null then
    raise exception 'EMAIL_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_key = 'verification_code'
    and strpos(p_subject_source || E'\n' || p_body_source, '{{verificatiecode}}') = 0
  then
    raise exception 'EMAIL_VERIFICATION_CODE_REQUIRED' using errcode = '23514';
  end if;
  return app.update_email_template_core_v2(
    p_template_id, p_subject_source, p_body_source, p_expected_version
  );
end;
$$;

revoke all on function app.update_email_template(uuid, text, text, integer)
from public, anon, authenticated, service_role;
grant execute on function app.update_email_template(uuid, text, text, integer) to authenticated;

create or replace function public.get_parent_otp_email_template()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare result jsonb;
begin
  select jsonb_build_object(
    'templateKey', template.template_key,
    'templateVersion', template.version,
    'subjectSource', template.subject_source,
    'bodySource', template.body_source,
    'allowedShortcodes', template.allowed_shortcodes,
    'clubName', settings.club_name,
    'contactEmail', settings.contact_email
  ) into result
  from app.email_templates template
  cross join app.app_settings settings
  where template.template_key = 'verification_code'
    and template.active = true
    and settings.id = true;

  if result is null then
    raise exception 'PARENT_OTP_EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
  end if;
  return result;
end;
$$;

revoke all on function public.get_parent_otp_email_template() from public, anon, authenticated;
grant execute on function public.get_parent_otp_email_template() to service_role;

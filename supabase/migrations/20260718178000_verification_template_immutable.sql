alter function app.update_email_template(uuid, text, text, integer)
rename to update_email_template_core;

revoke all on function app.update_email_template_core(uuid, text, text, integer)
from public, anon, authenticated, service_role;

create or replace function app.update_email_template(
  p_template_id uuid, p_subject_source text, p_body_source text, p_expected_version integer
)
returns jsonb
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); target_key text;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  select template_key into target_key from app.email_templates where id = p_template_id;
  if target_key is null then raise exception 'EMAIL_TEMPLATE_NOT_FOUND' using errcode = 'P0002'; end if;
  if target_key = 'verification_code' then
    raise exception 'EMAIL_TEMPLATE_IMMUTABLE' using errcode = '23514';
  end if;
  return app.update_email_template_core(p_template_id, p_subject_source, p_body_source, p_expected_version);
end;
$$;

revoke all on function app.update_email_template(uuid, text, text, integer) from public, anon;
grant execute on function app.update_email_template(uuid, text, text, integer) to authenticated;

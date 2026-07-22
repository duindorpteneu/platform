create or replace function public.is_operational_feature_enabled(p_flag text)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select case p_flag
    when 'mollie_enabled' then settings.mollie_enabled
    when 'email_enabled' then settings.email_enabled
    else false
  end
  from app.app_settings settings
  where settings.id = true;
$$;

revoke all on function public.is_operational_feature_enabled(text)
from public, anon, authenticated;
grant execute on function public.is_operational_feature_enabled(text)
to service_role;

notify pgrst, 'reload schema';

-- The settings v2 RPCs were introduced in the previous forward migration.
-- Explicitly refresh hosted PostgREST so an application release can use them
-- immediately after `supabase db push` without changing existing settings or seasons.
create or replace function app.get_settings_rpc_contract_version()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $$
  select jsonb_build_object(
    'version', '20260720142000',
    'ready', count(*) = 3 and bool_and(has_function_privilege('authenticated', procedure.oid, 'EXECUTE'))
  )
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'app'
    and procedure.proname = any(array[
      'get_settings_workspace_v2',
      'update_settings_v2',
      'create_season_v2'
    ]);
$$;

revoke all on function app.get_settings_rpc_contract_version() from public, anon, authenticated;
grant execute on function app.get_settings_rpc_contract_version() to service_role;

notify pgrst, 'reload schema';

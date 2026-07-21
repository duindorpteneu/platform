-- Re-publish the service-only post-MFA session contract after the hosted
-- PostgREST schema cache has seen the forward-created function.
revoke all on function app.create_staff_app_session_for_user(uuid) from public, anon, authenticated;
grant execute on function app.create_staff_app_session_for_user(uuid) to service_role;

notify pgrst, 'reload schema';

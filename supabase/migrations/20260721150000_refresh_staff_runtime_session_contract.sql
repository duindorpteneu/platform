-- Keep every opaque staff-session runtime function visible in hosted
-- PostgREST after the forward-only session migrations.
revoke all on function app.create_staff_app_session_for_user(uuid) from public, anon, authenticated;
revoke all on function app.get_staff_app_session(text) from public, anon, authenticated;
revoke all on function app.revoke_staff_app_session(text) from public, anon, authenticated;
grant execute on function app.create_staff_app_session_for_user(uuid) to service_role;
grant execute on function app.get_staff_app_session(text) to service_role;
grant execute on function app.revoke_staff_app_session(text) to service_role;

notify pgrst, 'reload schema';

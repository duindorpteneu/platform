create or replace function app.consume_staff_search_rate()
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  actor_key text;
begin
  if actor is null
    or coalesce(auth.jwt()->>'aal', '') <> 'aal2'
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  actor_key := encode(digest(actor::text, 'sha256'), 'hex');
  return app.consume_rate_limit('search', actor_key, 120, 60);
end;
$$;

revoke all on function app.consume_staff_search_rate() from public, anon;
grant execute on function app.consume_staff_search_rate() to authenticated;

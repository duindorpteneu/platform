-- The preceding staff password-recovery migration introduced a service-only
-- RPC after the last explicit PostgREST reload. Refresh the hosted schema cache
-- without changing data, privileges or the established settings contract version.
notify pgrst, 'reload schema';

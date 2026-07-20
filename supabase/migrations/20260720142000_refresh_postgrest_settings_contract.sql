-- The settings v2 RPCs were introduced in the previous forward migration.
-- Explicitly refresh hosted PostgREST so an application release can use them
-- immediately after `supabase db push` without changing existing settings or seasons.
notify pgrst, 'reload schema';

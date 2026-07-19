-- Keep the hosted PostgREST schema contract aligned with supabase/config.toml.
-- The private schema remains deliberately excluded from the Data API.
alter role authenticator set pgrst.db_schemas = 'public, graphql_public, app';

notify pgrst, 'reload config';
notify pgrst, 'reload schema';

create or replace function public.create_parent_otp(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  account_id uuid;
begin
  insert into private.parent_accounts (email_normalized)
  values (lower(trim(p_email)))
  on conflict (email_normalized) do update set email_normalized = excluded.email_normalized
  returning id into account_id;
  insert into private.parent_otp_challenges (parent_account_id, code_hash, expires_at)
  values (account_id, p_code_hash, p_expires_at);
  return account_id;
end;
$$;

create or replace function public.consume_parent_otp(p_email text, p_code_hash text)
returns jsonb
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  return private.consume_parent_otp(p_email, p_code_hash);
end;
$$;

create or replace function public.create_parent_session(
  p_parent_account_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare session_id uuid;
begin
  insert into private.parent_sessions (parent_account_id, token_hash, expires_at)
  values (p_parent_account_id, p_token_hash, p_expires_at)
  returning id into session_id;
  return session_id;
end;
$$;

revoke all on function public.create_parent_otp(text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.consume_parent_otp(text, text) from public, anon, authenticated;
revoke all on function public.create_parent_session(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.create_parent_otp(text, text, timestamptz) to service_role;
grant execute on function public.consume_parent_otp(text, text) to service_role;
grant execute on function public.create_parent_session(uuid, text, timestamptz) to service_role;

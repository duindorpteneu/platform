create table if not exists private.parent_accounts (
  id uuid primary key default gen_random_uuid(),
  email_normalized text not null unique,
  created_at timestamptz not null default timezone('utc', now()),
  last_login_at timestamptz
);

create table if not exists private.parent_otp_challenges (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null references private.parent_accounts(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5 check (max_attempts = 5),
  used_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists private.parent_sessions (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null references private.parent_accounts(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default timezone('utc', now()),
  last_seen_at timestamptz not null default timezone('utc', now()),
  expires_at timestamptz not null,
  revoked_at timestamptz
);

create table if not exists private.parent_member_links (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null references private.parent_accounts(id) on delete cascade,
  member_id uuid not null references app.members(id) on delete restrict,
  linked_at timestamptz not null default timezone('utc', now()),
  unlinked_at timestamptz,
  unique (parent_account_id, member_id)
);

create table if not exists private.email_jobs (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  recipient_email text not null,
  template_key text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check (status in ('queued', 'processing', 'sent', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default timezone('utc', now()),
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists parent_otp_latest_idx on private.parent_otp_challenges (parent_account_id, created_at desc);
create index if not exists parent_sessions_active_idx on private.parent_sessions (token_hash, expires_at) where revoked_at is null;
create index if not exists email_jobs_queue_idx on private.email_jobs (available_at, created_at) where status in ('queued', 'processing');

create or replace function private.consume_parent_otp(p_email text, p_code_hash text)
returns jsonb
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  now_utc timestamptz := timezone('utc', now());
begin
  select * into account from private.parent_accounts
  where email_normalized = lower(trim(p_email)) limit 1;
  if not found then return jsonb_build_object('status', 'invalid'); end if;

  select * into challenge from private.parent_otp_challenges
  where parent_account_id = account.id
  order by created_at desc limit 1 for update;
  if not found or challenge.used_at is not null or challenge.expires_at <= now_utc or challenge.attempts >= challenge.max_attempts then
    return jsonb_build_object('status', 'invalid');
  end if;

  if challenge.code_hash <> p_code_hash then
    update private.parent_otp_challenges set attempts = attempts + 1 where id = challenge.id;
    return jsonb_build_object('status', 'invalid');
  end if;

  update private.parent_otp_challenges set used_at = now_utc where id = challenge.id;
  update private.parent_accounts set last_login_at = now_utc where id = account.id;
  return jsonb_build_object('status', 'verified', 'parentAccountId', account.id);
end;
$$;

revoke all on schema private from anon, authenticated;
revoke all on function private.consume_parent_otp(text, text) from public, anon, authenticated;
grant execute on function private.consume_parent_otp(text, text) to service_role;

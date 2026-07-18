alter table private.email_jobs
  add column template_version integer,
  add column subject_source_snapshot text,
  add column body_source_snapshot text,
  add column allowed_shortcodes_snapshot text[];

update private.email_jobs job set
  template_version = template.version,
  subject_source_snapshot = template.subject_source,
  body_source_snapshot = template.body_source,
  allowed_shortcodes_snapshot = template.allowed_shortcodes
from app.email_templates template
where job.template_id = template.id and job.order_id is not null;

alter table private.email_jobs add constraint email_jobs_durable_snapshot_check check (
  order_id is null or (
    template_id is not null and template_version is not null and template_version > 0
    and subject_source_snapshot is not null and body_source_snapshot is not null
    and allowed_shortcodes_snapshot is not null
  )
);

create or replace function private.guard_email_job_snapshot()
returns trigger
language plpgsql security definer
set search_path = private, app, pg_temp
as $$
declare target_template app.email_templates%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.order_id is null or new.template_id is null or new.template_key = 'verification_code' then
      raise exception 'DURABLE_ORDER_EMAIL_REQUIRED' using errcode = '23514';
    end if;
    select * into target_template from app.email_templates where id = new.template_id and active;
    if not found or target_template.template_key <> new.template_key then
      raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
    end if;
    new.template_version := target_template.version;
    new.subject_source_snapshot := target_template.subject_source;
    new.body_source_snapshot := target_template.body_source;
    new.allowed_shortcodes_snapshot := target_template.allowed_shortcodes;
  elsif old.order_id is not null and (
    new.order_id is distinct from old.order_id or new.template_id is distinct from old.template_id
    or new.template_key is distinct from old.template_key or new.recipient_email is distinct from old.recipient_email
    or new.payload is distinct from old.payload or new.idempotency_key is distinct from old.idempotency_key
    or new.template_version is distinct from old.template_version
    or new.subject_source_snapshot is distinct from old.subject_source_snapshot
    or new.body_source_snapshot is distinct from old.body_source_snapshot
    or new.allowed_shortcodes_snapshot is distinct from old.allowed_shortcodes_snapshot
  ) then
    raise exception 'EMAIL_JOB_SNAPSHOT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger email_jobs_guard_snapshot
before insert or update on private.email_jobs
for each row execute function private.guard_email_job_snapshot();

create or replace function app.claim_email_jobs(p_claim_token uuid, p_limit integer)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb; safe_limit integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);
  with candidates as (
    select id from private.email_jobs
    where order_id is not null and template_version is not null
      and status in ('queued', 'retry') and attempts < 5 and available_at <= timezone('utc', now())
    order by available_at, created_at for update skip locked limit safe_limit
  ), claimed as (
    update private.email_jobs job set status = 'processing', attempts = attempts + 1,
      claim_token = p_claim_token, claimed_at = timezone('utc', now()), updated_at = timezone('utc', now())
    from candidates where job.id = candidates.id returning job.*
  )
  select jsonb_build_object('claimToken', p_claim_token, 'jobs', coalesce(jsonb_agg(jsonb_build_object(
    'id', claimed.id, 'kind', claimed.kind, 'recipientEmail', claimed.recipient_email,
    'templateKey', claimed.template_key, 'templateVersion', claimed.template_version,
    'subjectSource', claimed.subject_source_snapshot, 'bodySource', claimed.body_source_snapshot,
    'allowedShortcodes', claimed.allowed_shortcodes_snapshot,
    'orderId', claimed.order_id, 'payload', claimed.payload, 'attempt', claimed.attempts
  ) order by claimed.created_at), '[]'::jsonb)) into result from claimed;
  return result;
end;
$$;

revoke all on function private.guard_email_job_snapshot() from public, anon, authenticated, service_role;
revoke all on function app.claim_email_jobs(uuid, integer) from public, anon, authenticated;
grant execute on function app.claim_email_jobs(uuid, integer) to service_role;

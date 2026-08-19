-- Temporary VoetbalAssist SMTP bulk pacing: persistent and multi-worker safe.
create table private.email_bulk_rate_limit (
  singleton boolean primary key default true check (singleton),
  next_slot_at timestamptz not null default '-infinity'
);
alter table private.email_bulk_rate_limit enable row level security;
revoke all on private.email_bulk_rate_limit from public, anon, authenticated;

create or replace function app.claim_email_jobs_priority_v3(
  p_claim_token uuid,
  p_limit integer,
  p_allow_bulk boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  safe_limit integer;
  allow_bulk boolean := false;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);
  if p_allow_bulk then
    insert into private.email_bulk_rate_limit(singleton, next_slot_at)
    values (true, '-infinity') on conflict (singleton) do nothing;
    allow_bulk := true;
  end if;

  update private.email_jobs invite_job
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'access_inactive_before_send',
      updated_at = timezone('utc', now())
  where invite_job.context_kind = 'portal_access'
    and invite_job.status in ('queued', 'retry')
    and not exists(
      select 1
      from private.parent_access_batch_items batch_item
      join private.parent_portal_grants grant_row
        on grant_row.id = batch_item.grant_id
        and grant_row.parent_account_id = invite_job.parent_account_id
        and grant_row.status = 'active'
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.participation_status = 'active'
      where batch_item.batch_id = invite_job.parent_access_batch_id
        and batch_item.outcome = 'activated'
    );

  with candidates as (
    select job.id
    from private.email_jobs job
    where job.status in ('queued', 'retry')
      and job.attempts < 5
      and job.available_at <= timezone('utc', now())
      and (
        not (job.kind = 'bulk' or (job.context_kind = 'portal_access' and exists (
          select 1 from private.parent_access_batches priority_batch
          where priority_batch.id = job.parent_access_batch_id and priority_batch.selected_count > 1
        ))) or (
          allow_bulk and exists (
            select 1 from private.email_bulk_rate_limit slot
            where slot.singleton and slot.next_slot_at <= statement_timestamp()
          )
        )
      )
      and (
        not (job.kind = 'bulk' or (job.context_kind = 'portal_access' and exists (
          select 1 from private.parent_access_batches priority_batch
          where priority_batch.id = job.parent_access_batch_id and priority_batch.selected_count > 1
        )))
        or job.id = (
          select bulk_job.id from private.email_jobs bulk_job
          where bulk_job.status in ('queued','retry') and bulk_job.attempts < 5
            and bulk_job.available_at <= timezone('utc', now())
            and (bulk_job.kind = 'bulk' or (bulk_job.context_kind = 'portal_access' and exists (
              select 1 from private.parent_access_batches bulk_batch where bulk_batch.id = bulk_job.parent_access_batch_id and bulk_batch.selected_count > 1
            )))
          order by bulk_job.available_at, bulk_job.created_at limit 1
        )
      )
      and (
        (
          job.context_kind = 'order'
          and job.template_version is not null
        )
        or (
          job.context_kind = 'portal_access'
          and job.template_version is not null
          and exists(
            select 1
            from private.parent_access_batch_items batch_item
            join private.parent_portal_grants grant_row
              on grant_row.id = batch_item.grant_id
              and grant_row.parent_account_id = job.parent_account_id
              and grant_row.status = 'active'
            join app.member_seasons member_season
              on member_season.id = grant_row.member_season_id
              and member_season.participation_status = 'active'
            where batch_item.batch_id = job.parent_access_batch_id
              and batch_item.outcome = 'activated'
          )
        )
        or (
          job.context_kind = 'fulfilment'
          and private.mail_templates_v2_enabled()
          and job.template_version is null
          and job.render_hash is not null
          and exists(
            select 1
            from private.fulfilment_mail_projection_batches batch
            where batch.email_job_id = job.id
              and batch.status = 'queued'
          )
        )
        or (
          job.context_kind = 'mail_v2'
          and private.mail_templates_v2_enabled()
          and job.template_version is null
          and job.render_hash is not null
          and exists(
            select 1
            from private.mail_v2_projection_batches batch
            where batch.email_job_id = job.id
              and batch.status = 'queued'
          )
        )
      )
    order by
      (job.kind = 'bulk' or (job.context_kind = 'portal_access' and exists (
        select 1 from private.parent_access_batches priority_batch
        where priority_batch.id = job.parent_access_batch_id and priority_batch.selected_count > 1
      ))),
      job.available_at, job.created_at
    for update skip locked
    limit safe_limit
  ),
  claimed as (
    update private.email_jobs job
    set status = 'processing',
        attempts = attempts + 1,
        claim_token = p_claim_token,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    from candidates
    where job.id = candidates.id
    returning job.*
  ),
  bulk_slot as (
    update private.email_bulk_rate_limit slot
    set next_slot_at = statement_timestamp() + interval '30 seconds'
    where slot.singleton
      and slot.next_slot_at <= statement_timestamp()
      and exists (
        select 1 from claimed
        where claimed.kind = 'bulk'
          or (
            claimed.context_kind = 'portal_access'
            and exists (
              select 1 from private.parent_access_batches batch
              where batch.id = claimed.parent_access_batch_id
                and batch.selected_count > 1
            )
          )
      )
    returning true
  )
  select jsonb_build_object(
    'claimToken',
    p_claim_token,
    'jobs',
    coalesce(jsonb_agg(
      case
        when claimed.context_kind in ('fulfilment', 'mail_v2')
          then jsonb_build_object(
            'id', claimed.id,
            'kind', claimed.kind,
            'contextKind', claimed.context_kind,
            'recipientEmail', claimed.recipient_email,
            'templateKey', claimed.template_key,
            'templateRevisionId', claimed.mail_template_revision_id,
            'brandingRevisionId', claimed.mail_branding_revision_id,
            'subject', claimed.rendered_subject_snapshot,
            'preheader', claimed.rendered_preheader_snapshot,
            'html', claimed.rendered_html_snapshot,
            'text', claimed.rendered_text_snapshot,
            'fromName', claimed.from_name_snapshot,
            'fromEmail', claimed.from_email_snapshot,
            'replyToEmail', claimed.reply_to_email_snapshot,
            'renderHash', claimed.render_hash,
            'parentAccountId', claimed.parent_account_id,
            'seasonId', claimed.season_id,
            'eventCount', (claimed.payload->>'eventCount')::integer,
            'attempt', claimed.attempts
          )
        else jsonb_build_object(
          'id', claimed.id,
          'kind', claimed.kind,
          'contextKind', claimed.context_kind,
          'recipientEmail', claimed.recipient_email,
          'templateKey', claimed.template_key,
          'templateVersion', claimed.template_version,
          'subjectSource', claimed.subject_source_snapshot,
          'bodySource', claimed.body_source_snapshot,
          'allowedShortcodes', claimed.allowed_shortcodes_snapshot,
          'orderId', claimed.order_id,
          'parentAccountId', claimed.parent_account_id,
          'payload', claimed.payload,
          'attempt', claimed.attempts
        )
      end
      order by claimed.created_at
    ), '[]'::jsonb)
  ) into result
  from claimed;
  return result;
end;
$$;


create or replace function app.claim_email_jobs_v5(
  p_claim_token uuid,
  p_limit integer,
  p_allow_bulk boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  legacy_claim jsonb;
  job_payload jsonb;
  claimed_jobs jsonb := '[]'::jsonb;
  target_job private.email_jobs%rowtype;
  attempt_id uuid;
  next_attempt_number integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;

  update private.email_jobs job
  set status = 'delivery_uncertain',
      uncertain_at = coalesce(job.uncertain_at, statement_timestamp()),
      completed_at = null,
      claim_token = null,
      claimed_at = null,
      last_error = 'legacy_delivery_attempt_ambiguous',
      updated_at = statement_timestamp()
  where job.status in ('queued', 'retry')
    and exists(
      select 1
      from private.email_delivery_attempts attempt
      where attempt.id = job.current_delivery_attempt_id
        and attempt.legacy_ambiguous
    );
  update private.email_jobs job
  set status = 'failed',
      completed_at = statement_timestamp(),
      claim_token = null,
      claimed_at = null,
      last_error = 'delivery_attempts_exhausted',
      updated_at = statement_timestamp()
  where job.status in ('queued', 'retry')
    and (
      select count(*)
      from private.email_delivery_attempts attempt
      where attempt.email_job_id = job.id
    ) >= 5;

  legacy_claim := app.claim_email_jobs_priority_v3(p_claim_token, p_limit, p_allow_bulk);
  for job_payload in
    select value from jsonb_array_elements(legacy_claim->'jobs')
  loop
    select * into target_job
    from private.email_jobs job
    where job.id = (job_payload->>'id')::uuid
      and job.status = 'processing'
      and job.claim_token = p_claim_token
    for update;
    if not found
      or target_job.attempts <> (job_payload->>'attempt')::integer
    then
      raise exception 'EMAIL_DELIVERY_ATTEMPT_CLAIM_CONFLICT'
        using errcode = '40001';
    end if;
    select coalesce(max(attempt.attempt_number), 0) + 1
    into next_attempt_number
    from private.email_delivery_attempts attempt
    where attempt.email_job_id = target_job.id;
    if next_attempt_number > 5 then
      raise exception 'EMAIL_DELIVERY_ATTEMPTS_EXHAUSTED'
        using errcode = '23514';
    end if;

    insert into private.email_delivery_attempts(
      email_job_id,
      attempt_number,
      claim_token,
      claimed_at
    ) values (
      target_job.id,
      next_attempt_number,
      p_claim_token,
      target_job.claimed_at
    )
    returning id into attempt_id;

    update private.email_jobs
    set current_delivery_attempt_id = attempt_id,
        attempts = next_attempt_number
    where id = target_job.id;

    claimed_jobs := claimed_jobs || jsonb_build_array(
      jsonb_set(
        job_payload || jsonb_build_object(
          'deliveryAttemptId',
          attempt_id
        ),
        '{attempt}',
        to_jsonb(next_attempt_number),
        true
      )
    );
  end loop;

  return jsonb_build_object(
    'claimToken',
    p_claim_token,
    'jobs',
    claimed_jobs
  );
end;
$$;


revoke all on function app.claim_email_jobs_priority_v3(uuid, integer, boolean) from public, anon, authenticated;
revoke all on function app.claim_email_jobs_v4(uuid, integer) from public, anon, authenticated;
revoke all on function app.claim_email_jobs_v5(uuid, integer, boolean) from public, anon, authenticated;
grant execute on function app.claim_email_jobs_v4(uuid, integer) to service_role;
grant execute on function app.claim_email_jobs_v5(uuid, integer, boolean) to service_role;
comment on function app.claim_email_jobs_v5(uuid, integer, boolean) is 'Claims direct mail first and at most one bulk send per persistent 30-second slot.';
notify pgrst, 'reload schema';

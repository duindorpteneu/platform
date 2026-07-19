-- SendGrid's Mail Send X-Message-ID and Event Webhook sg_message_id are
-- different identifiers. Correlate signed events through the non-PII job UUID
-- that the application already sends as a custom argument.
create or replace function app.record_sendgrid_events(p_events jsonb)
returns jsonb
language plpgsql security definer
set search_path = app, private, pg_temp
as $$
declare
  item record;
  target_job_id uuid;
  target_provider_message_id text;
  event_provider_message_id text;
  inserted_count integer := 0;
  ignored_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'INVALID_SENDGRID_EVENTS' using errcode = '22023';
  end if;

  for item in select * from jsonb_to_recordset(p_events)
    as event_data(email_job_id uuid, event_id text, provider_message_id text, event_type text, occurred_at timestamptz)
  loop
    if item.email_job_id is null or item.event_id is null or item.occurred_at is null
      or item.event_type not in ('delivered', 'bounced', 'deferred', 'dropped', 'failed')
    then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    select id, provider_message_id
      into target_job_id, target_provider_message_id
    from private.email_jobs
    where id = item.email_job_id and status = 'sent';

    if target_job_id is null then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    event_provider_message_id := coalesce(nullif(trim(item.provider_message_id), ''), target_provider_message_id);
    if event_provider_message_id is null then
      ignored_count := ignored_count + 1;
      continue;
    end if;

    insert into app.email_events(email_job_id, provider_event_id, provider_message_id, event_type, occurred_at)
    values(target_job_id, left(item.event_id, 240), event_provider_message_id, item.event_type, item.occurred_at)
    on conflict(provider_event_id) do nothing;
    get diagnostics affected = row_count;

    if affected = 1 then
      inserted_count := inserted_count + 1;
      update private.email_jobs
      set delivery_status = item.event_type, updated_at = timezone('utc', now())
      where id = target_job_id;
    else
      ignored_count := ignored_count + 1;
    end if;
  end loop;

  return jsonb_build_object('recorded', inserted_count, 'ignored', ignored_count);
end;
$$;

revoke all on function app.record_sendgrid_events(jsonb) from public, anon, authenticated;
grant execute on function app.record_sendgrid_events(jsonb) to service_role;

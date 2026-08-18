-- SQLSTATE 40001 is reserved for serialization failures. PostgREST's database
-- stack may retry it inside the same HTTP request, so using it for a durable
-- business state can turn one deferred webhook or duplicate finalizer into a
-- tight retry storm. Return an explicit pending/absent result instead.

create or replace function app.assert_sendgrid_events_ready_v1(
  p_events jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, app, private, pg_temp
as $$
declare
  event_item jsonb;
  target text;
  email_job_id_text text;
  delivery_attempt_id_text text;
  delivery_id_text text;
  ready_count integer := 0;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'SENDGRID_EVENT_READINESS_INVALID'
      using errcode = '22023';
  end if;

  for event_item in
    select value
    from jsonb_array_elements(p_events)
  loop
    target := nullif(btrim(event_item ->> 'target'), '');
    email_job_id_text :=
      nullif(btrim(event_item ->> 'email_job_id'), '');
    delivery_attempt_id_text :=
      nullif(btrim(event_item ->> 'delivery_attempt_id'), '');
    delivery_id_text :=
      nullif(btrim(event_item ->> 'delivery_id'), '');

    if target = 'email_job' then
      if email_job_id_text is null
        or delivery_attempt_id_text is null
        or email_job_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
        or delivery_attempt_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.email_delivery_attempts attempt
        where attempt.id = delivery_attempt_id_text::uuid
          and attempt.email_job_id = email_job_id_text::uuid
      )
        and not exists (
          select 1
          from private.email_delivery_attempt_outcomes outcome
          where outcome.delivery_attempt_id =
              delivery_attempt_id_text::uuid
            and outcome.outcome in (
              'authorization_denied',
              'sent',
              'retry',
              'failed',
              'recovered_sent',
              'recovered_retry',
              'legacy_retry',
              'legacy_sent',
              'legacy_failed',
              'legacy_superseded'
            )
        )
      then
        continue;
      end if;
    elsif target = 'parent_otp' then
      if delivery_attempt_id_text is null
        or delivery_attempt_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.parent_otp_delivery_attempts attempt
        where attempt.id = delivery_attempt_id_text::uuid
      )
        and not exists (
          select 1
          from private.parent_otp_delivery_outcomes outcome
          where outcome.delivery_attempt_id =
            delivery_attempt_id_text::uuid
        )
      then
        continue;
      end if;
    elsif target = 'mail_test' then
      if delivery_id_text is null
        or delivery_id_text !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      then
        raise exception 'SENDGRID_EVENT_READINESS_INVALID'
          using errcode = '22023';
      end if;
      if exists (
        select 1
        from private.mail_test_deliveries delivery
        where delivery.id = delivery_id_text::uuid
      )
        and not exists (
          select 1
          from private.mail_test_delivery_outcomes outcome
          where outcome.delivery_id = delivery_id_text::uuid
        )
      then
        continue;
      end if;
    else
      raise exception 'SENDGRID_EVENT_READINESS_INVALID'
        using errcode = '22023';
    end if;
    ready_count := ready_count + 1;
  end loop;

  return jsonb_build_object('ready', ready_count);
end;
$$;

create or replace function app.finish_operation_run(
  p_run_id uuid,
  p_status text,
  p_processed_count integer,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.operation_runs%rowtype;
  finished timestamptz := timezone('utc', now());
begin
  if p_run_id is null or p_status not in ('succeeded', 'failed', 'paused')
    or p_processed_count is null
    or p_processed_count not between 0 and 1000000000
    or (
      p_status = 'failed'
      and (
        p_error_code is null
        or p_error_code !~ '^[a-z0-9][a-z0-9._-]{0,63}$'
      )
    )
    or (p_status <> 'failed' and p_error_code is not null)
  then
    raise exception 'INVALID_OPERATION_RESULT' using errcode = '22023';
  end if;

  select * into target
  from private.operation_runs
  where id = p_run_id and status = 'running'
  for update;
  if not found then
    return null;
  end if;

  update private.operation_runs
  set status = p_status,
      finished_at = finished,
      processed_count = p_processed_count,
      error_code = p_error_code
  where id = target.id;

  return jsonb_build_object(
    'runId', target.id,
    'operation', target.operation,
    'status', p_status,
    'finishedAt', finished
  );
end;
$$;

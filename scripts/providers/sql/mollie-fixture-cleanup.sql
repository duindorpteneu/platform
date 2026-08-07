begin;

do $lock$
begin
  perform pg_advisory_xact_lock(hashtextextended('duindorp:mollie-acceptance-fixture', 0));
end
$lock$;

create temporary table mollie_acceptance_input (
  paid_member_id uuid not null,
  mismatch_member_id uuid not null,
  paid_order_id uuid not null,
  mismatch_order_id uuid not null,
  readiness_article_id uuid not null,
  readiness_variant_id uuid not null,
  readiness_order_line_id uuid not null,
  readiness_qr_request_id uuid not null,
  paid_relation text not null,
  mismatch_relation text not null,
  fixture_email text not null
) on commit drop;

insert into mollie_acceptance_input values (
  :'paid_member_id'::uuid,
  :'mismatch_member_id'::uuid,
  :'paid_order_id'::uuid,
  :'mismatch_order_id'::uuid,
  :'readiness_article_id'::uuid,
  :'readiness_variant_id'::uuid,
  :'readiness_order_line_id'::uuid,
  :'readiness_qr_request_id'::uuid,
  :'paid_relation',
  :'mismatch_relation',
  :'fixture_email'
);

do $fixture$
declare
  fixture_input mollie_acceptance_input%rowtype;
  fixture_marker_exists boolean;
  fixture_marker text;
begin
  select * into strict fixture_input from mollie_acceptance_input;
  fixture_marker := regexp_replace(
    fixture_input.paid_relation,
    '^MOLLIE-(.+)-P$',
    '\1'
  );

  if fixture_input.paid_member_id = fixture_input.mismatch_member_id
    or fixture_input.paid_order_id = fixture_input.mismatch_order_id
    or cardinality(array[
      fixture_input.paid_member_id,
      fixture_input.mismatch_member_id,
      fixture_input.paid_order_id,
      fixture_input.mismatch_order_id,
      fixture_input.readiness_article_id,
      fixture_input.readiness_variant_id,
      fixture_input.readiness_order_line_id,
      fixture_input.readiness_qr_request_id
    ]) <> (
      select count(distinct identifier)
      from unnest(array[
        fixture_input.paid_member_id,
        fixture_input.mismatch_member_id,
        fixture_input.paid_order_id,
        fixture_input.mismatch_order_id,
        fixture_input.readiness_article_id,
        fixture_input.readiness_variant_id,
        fixture_input.readiness_order_line_id,
        fixture_input.readiness_qr_request_id
      ]) identifier
    )
    or fixture_input.paid_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-P$'
    or fixture_input.mismatch_relation !~ '^MOLLIE-[0-9]{1,20}a[0-9]{1,6}-M$'
    or fixture_input.fixture_email !~ '^mollie-acceptance\+[0-9]{1,20}a[0-9]{1,6}@example\.invalid$'
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(fixture_input.mismatch_relation, '^MOLLIE-(.+)-M$', '\1')
    or regexp_replace(fixture_input.paid_relation, '^MOLLIE-(.+)-P$', '\1')
      <> regexp_replace(fixture_input.fixture_email, '^mollie-acceptance\+(.+)@example\.invalid$', '\1')
  then
    raise exception 'INVALID_MOLLIE_ACCEPTANCE_IDENTITY' using errcode = '22023';
  end if;

  select exists (
    select 1
    from app.members member
    where member.id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
      or member.relation_number in (fixture_input.paid_relation, fixture_input.mismatch_relation)
  ) or exists (
    select 1
    from app.member_orders orders
    where orders.id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or exists (
    select 1
    from app.articles article
    where article.id = fixture_input.readiness_article_id
  ) or exists (
    select 1
    from app.article_variants variant
    where variant.id = fixture_input.readiness_variant_id
  ) or exists (
    select 1
    from app.order_lines line
    where line.id = fixture_input.readiness_order_line_id
  ) into fixture_marker_exists;

  if not fixture_marker_exists then
    if exists (
      select 1 from private.parent_accounts account
      where account.email_normalized = fixture_input.fixture_email
    ) then
      raise exception 'MOLLIE_ACCEPTANCE_CLEANUP_SCOPE_VIOLATION' using errcode = '23514';
    end if;
    return;
  end if;

  if not (
    exists (
      select 1 from app.members member
      where member.id = fixture_input.paid_member_id
        and member.relation_number = fixture_input.paid_relation
        and member.email = fixture_input.fixture_email
        and member.team = 'MOLLIE-ACCEPTANCE'
    ) and exists (
      select 1 from app.members member
      where member.id = fixture_input.mismatch_member_id
        and member.relation_number = fixture_input.mismatch_relation
        and member.email = fixture_input.fixture_email
        and member.team = 'MOLLIE-ACCEPTANCE'
    ) and (
      select count(*) from app.members member
      where member.id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
        or member.relation_number in (fixture_input.paid_relation, fixture_input.mismatch_relation)
    ) = 2
    and exists (
      select 1
      from app.member_orders paid_order
      join app.member_orders mismatch_order
        on mismatch_order.id = fixture_input.mismatch_order_id
       and mismatch_order.member_id = fixture_input.mismatch_member_id
       and mismatch_order.season_id = paid_order.season_id
       and mismatch_order.amount_due_cents = 100
      where paid_order.id = fixture_input.paid_order_id
        and paid_order.member_id = fixture_input.paid_member_id
        and paid_order.amount_due_cents = 100
    ) and (
      select count(*) from app.member_orders orders
      where orders.id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
    ) = 2
    and exists (
      select 1
      from app.articles article
      join app.article_variants variant
        on variant.id = fixture_input.readiness_variant_id
       and variant.article_id = article.id
      join app.article_seasons article_season
        on article_season.article_id = article.id
       and article_season.season_id = (
         select orders.season_id
         from app.member_orders orders
         where orders.id = fixture_input.paid_order_id
       )
      where article.id = fixture_input.readiness_article_id
        and article.name = 'Mollie acceptance ' || fixture_marker
        and article.code = 'MOL-' || upper(substr(
          replace(fixture_input.readiness_article_id::text, '-', ''),
          1,
          12
        ))
        and variant.size = 'TEST-' || fixture_marker
    )
    and exists (
      select 1
      from app.order_lines line
      where line.id = fixture_input.readiness_order_line_id
        and line.order_id = fixture_input.paid_order_id
        and line.article_id = fixture_input.readiness_article_id
        and line.article_variant_id = fixture_input.readiness_variant_id
        and line.quantity = 1
    )
    and (
      select count(*)
      from app.article_variants variant
      where variant.article_id = fixture_input.readiness_article_id
    ) = 1
    and (
      select count(*)
      from app.order_lines line
      where line.article_id = fixture_input.readiness_article_id
         or line.article_variant_id = fixture_input.readiness_variant_id
    ) = 1
    and exists (
      select 1
      from app.member_article_sizes size_choice
      join app.member_orders orders
        on orders.id = fixture_input.paid_order_id
       and orders.member_id = size_choice.member_id
       and orders.season_id = size_choice.season_id
       and orders.member_season_id = size_choice.member_season_id
      where size_choice.article_id = fixture_input.readiness_article_id
        and size_choice.article_variant_id = fixture_input.readiness_variant_id
        and size_choice.selection_status = 'confirmed'
        and size_choice.confirmed_at is not null
    )
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_CLEANUP_SCOPE_VIOLATION' using errcode = '23514';
  end if;

  if exists (
    select 1
    from private.parent_accounts account
    join private.parent_member_links link on link.parent_account_id = account.id
    where account.email_normalized = fixture_input.fixture_email
      and link.member_id not in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_CLEANUP_SCOPE_VIOLATION' using errcode = '23514';
  end if;

  delete from app.email_events event
  where event.email_job_id in (
    select job.id from private.email_jobs job
    where job.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  );
  delete from private.email_jobs job
  where job.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id);
  delete from private.payment_events event
  where event.payment_id in (
    select payment.id from app.payments payment
    where payment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  );
  delete from app.audit_logs audit
  where audit.entity_id in (
    fixture_input.paid_order_id,
    fixture_input.mismatch_order_id,
    fixture_input.paid_member_id,
    fixture_input.mismatch_member_id
  ) or audit.entity_id in (
    select payment.id from app.payments payment
    where payment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or audit.entity_id in (
    select line.id from app.order_lines line
    where line.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or audit.entity_id in (
    select fulfilment.id from app.fulfilments fulfilment
    where fulfilment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or audit.metadata->>'order_id' in (
    fixture_input.paid_order_id::text,
    fixture_input.mismatch_order_id::text
  );
  delete from private.qr_tokens token
  where token.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id);
  delete from app.payments payment
  where payment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id);
  delete from app.fulfilment_lines line
  where line.order_line_id in (
    select orders_line.id from app.order_lines orders_line
    where orders_line.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or line.fulfilment_id in (
    select fulfilment.id from app.fulfilments fulfilment
    where fulfilment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  );
  delete from app.fulfilments fulfilment
  where fulfilment.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id);
  delete from app.inventory_reservations reservation
  where reservation.order_line_id in (
    select line.id from app.order_lines line
      where line.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  );
  delete from private.inventory_allocation_queue queue
  where queue.article_variant_id = fixture_input.readiness_variant_id
    and queue.season_id = (
      select orders.season_id
      from app.member_orders orders
      where orders.id = fixture_input.paid_order_id
    );
  delete from app.order_lines line
  where line.order_id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id);
  delete from app.member_orders orders
  where orders.id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
    and orders.member_id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id);

  delete from private.parent_member_links link
  where link.parent_account_id in (
    select account.id from private.parent_accounts account
    where account.email_normalized = fixture_input.fixture_email
  );
  delete from private.parent_sessions session
  where session.parent_account_id in (
    select account.id from private.parent_accounts account
    where account.email_normalized = fixture_input.fixture_email
  );
  delete from private.parent_accounts account
  where account.email_normalized = fixture_input.fixture_email;
  delete from private.rate_limit_events event
  where event.scope in ('otp_request', 'otp_verify')
    and event.key_hash = encode(extensions.digest(fixture_input.fixture_email, 'sha256'), 'hex');

  alter table app.member_size_selection_history
    disable trigger member_size_selection_history_immutable;
  delete from app.member_size_selection_history history
  where history.member_season_id in (
      select member_season.id
      from app.member_seasons member_season
      where member_season.member_id in (
        fixture_input.paid_member_id,
        fixture_input.mismatch_member_id
      )
    )
    and history.article_id = fixture_input.readiness_article_id;
  alter table app.member_size_selection_history
    enable trigger member_size_selection_history_immutable;
  delete from app.member_article_sizes size_choice
  where size_choice.member_id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id);
  delete from app.members member
  where member.id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
    and member.relation_number in (fixture_input.paid_relation, fixture_input.mismatch_relation)
    and member.email = fixture_input.fixture_email;
  delete from app.article_seasons article_season
  where article_season.article_id = fixture_input.readiness_article_id;
  delete from app.article_variants variant
  where variant.id = fixture_input.readiness_variant_id
    and variant.article_id = fixture_input.readiness_article_id;
  delete from app.articles article
  where article.id = fixture_input.readiness_article_id
    and article.name = 'Mollie acceptance ' || fixture_marker
    and article.code = 'MOL-' || upper(substr(
      replace(fixture_input.readiness_article_id::text, '-', ''),
      1,
      12
    ));

  if exists (
    select 1 from app.members member
    where member.id in (fixture_input.paid_member_id, fixture_input.mismatch_member_id)
      or member.relation_number in (fixture_input.paid_relation, fixture_input.mismatch_relation)
  ) or exists (
    select 1 from app.member_orders orders
    where orders.id in (fixture_input.paid_order_id, fixture_input.mismatch_order_id)
  ) or exists (
    select 1 from private.parent_accounts account
    where account.email_normalized = fixture_input.fixture_email
  ) or exists (
    select 1 from app.articles article
    where article.id = fixture_input.readiness_article_id
  ) or exists (
    select 1 from app.article_variants variant
    where variant.id = fixture_input.readiness_variant_id
  ) or exists (
    select 1 from app.order_lines line
    where line.id = fixture_input.readiness_order_line_id
  ) then
    raise exception 'MOLLIE_ACCEPTANCE_CLEANUP_INCOMPLETE' using errcode = '23514';
  end if;
end
$fixture$;

select jsonb_build_object('cleaned', true);
commit;

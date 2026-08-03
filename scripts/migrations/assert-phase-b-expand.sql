\set ON_ERROR_STOP on

do $$
declare
  invalid_constraints integer;
  missing_rls integer;
begin
  if not exists(
    select 1
    from app.members member
    where member.id = 'ec400000-0000-4000-8000-000000000001'
      and member.relation_number is null
      and member.email = 'legacy-ongeldig'
  ) then
    raise exception 'UPGRADE_EMPTY_IDENTITY_NOT_CANONICALIZED';
  end if;
  if exists(
    select 1
    from app.member_external_identities identity_row
    where identity_row.member_id = 'ec400000-0000-4000-8000-000000000001'
  ) then
    raise exception 'UPGRADE_EMPTY_IDENTITY_PLACEHOLDER_RETAINED';
  end if;
  if (select count(*) from app.member_seasons where member_id::text like 'eb4%') <> 2 then
    raise exception 'UPGRADE_MEMBER_SEASONS_MISMATCH';
  end if;
  if exists(
    select 1
    from app.member_orders orders
    left join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.member_id = orders.member_id
      and member_season.season_id = orders.season_id
    where orders.id::text like 'eb5%' and member_season.id is null
  ) then
    raise exception 'UPGRADE_ORDER_MEMBER_SEASON_MISMATCH';
  end if;
  if (select count(*) from private.member_sensitive_identity
      where member_id::text like 'eb4%' and date_of_birth is null) <> 2 then
    raise exception 'UPGRADE_SENSITIVE_IDENTITY_MISMATCH';
  end if;
  if (select count(*) from app.members
      where id::text like 'eb4%' and gender = 'unknown') <> 2 then
    raise exception 'UPGRADE_GENDER_WAS_GUESSED';
  end if;
  if (select count(*) from app.member_external_identities
      where member_id::text like 'eb4%' and issuer = 'sportlink'
        and external_id_normalized = upper(trim(external_id))) <> 2 then
    raise exception 'UPGRADE_EXTERNAL_IDENTITIES_MISMATCH';
  end if;
  if (select count(*) from private.parent_portal_grants grant_row
      join app.member_seasons member_season on member_season.id = grant_row.member_season_id
      where member_season.member_id::text like 'eb4%') <> 1 then
    raise exception 'UPGRADE_PARENT_GRANT_COUNT_MISMATCH';
  end if;
  if exists(
    select 1
    from private.parent_portal_grants grant_row
    join app.member_seasons member_season on member_season.id = grant_row.member_season_id
    where member_season.member_id = 'eb400000-0000-4000-8000-000000000002'
  ) then
    raise exception 'UPGRADE_SHARED_EMAIL_AUTO_GRANT';
  end if;
  if (select count(*) from private.parent_portal_grants
      where legacy_link_id = 'eb870000-0000-4000-8000-000000000001'
        and status = 'review_required') <> 1 then
    raise exception 'UPGRADE_LEGACY_GRANT_NOT_REVIEW_REQUIRED';
  end if;

  if (select count(*) from app.package_templates) <> 0
    or (select count(*) from app.package_template_revisions) <> 0
    or (select count(*) from app.package_template_items) <> 0
  then
    raise exception 'UPGRADE_INVENTED_PACKAGE_TEMPLATES';
  end if;
  if (select count(*) from app.order_package_snapshots
      where order_id::text like 'eb5%') <> 2 then
    raise exception 'UPGRADE_ORDER_SNAPSHOT_COUNT_MISMATCH';
  end if;
  if (select count(*) from app.order_package_snapshot_items item
      join app.order_package_snapshots snapshot on snapshot.id = item.snapshot_id
      where snapshot.order_id::text like 'eb5%') <> 3 then
    raise exception 'UPGRADE_SNAPSHOT_ITEM_COUNT_MISMATCH';
  end if;
  if exists(
    select 1
    from app.member_orders orders
    join app.order_package_snapshots snapshot on snapshot.id = orders.active_package_snapshot_id
    where orders.id::text like 'eb5%'
      and (
        snapshot.order_id <> orders.id
        or snapshot.package_name <> 'Legacy tenue'
        or snapshot.package_price_cents <> orders.amount_due_cents
        or snapshot.currency <> 'EUR'
        or snapshot.template_revision_id is not null
        or orders.package_revision_id is not null
        or lower(snapshot.package_name) similar to '%(speler|keeper)%'
      )
  ) then
    raise exception 'UPGRADE_LEGACY_SNAPSHOT_CLASSIFICATION_OR_PRICE_MISMATCH';
  end if;
  if exists(
    select 1
    from app.order_lines line
    join app.articles article on article.id = line.article_id
    where line.id::text like 'eb6%'
      and (
        line.product_name_snapshot <> article.name
        or line.product_code_snapshot <> article.code
      )
  ) then
    raise exception 'UPGRADE_PRODUCT_SNAPSHOT_MISMATCH';
  end if;
  if (select count(*) from app.member_article_sizes
      where member_id::text like 'eb4%' and member_season_id is not null) <> 3 then
    raise exception 'UPGRADE_SIZE_MEMBER_SEASON_MISMATCH';
  end if;

  if (select count(*) from app.member_orders where id::text like 'eb5%') <> 2
    or (select sum(amount_due_cents) from app.member_orders where id::text like 'eb5%') <> 26000
    or (select count(*) from app.payments where id::text like 'eb7%') <> 2
    or (select sum(amount_cents) from app.payments where id::text like 'eb7%') <> 26000
    or (select count(*) from app.payments where id::text like 'eb7%' and status = 'paid') <> 1
    or (select sum(amount_cents) from app.payments where id::text like 'eb7%' and status = 'paid') <> 12500
  then
    raise exception 'UPGRADE_FINANCIAL_RECONCILIATION_MISMATCH';
  end if;
  if (select sum(received_quantity) from app.delivery_receipt_lines where id::text like 'eb81%') <> 7
    or (select sum(quantity) from app.inventory_reservations
        where id::text like 'eb82%' and status = 'reserved') <> 1
    or (select sum(quantity) from app.inventory_reservations
        where id::text like 'eb82%' and status = 'fulfilled') <> 1
    or (
      (select sum(received_quantity) from app.delivery_receipt_lines where id::text like 'eb81%')
      - (select sum(quantity) from app.fulfilment_lines
          where id::text like 'eb84%' and reversed_at is null)
    ) <> 6
    or (
      (select sum(received_quantity) from app.delivery_receipt_lines where id::text like 'eb81%')
      - (select sum(quantity) from app.inventory_reservations
          where id::text like 'eb82%' and status in ('reserved', 'fulfilled'))
    ) <> 5
  then
    raise exception 'UPGRADE_STOCK_RECONCILIATION_MISMATCH';
  end if;
  if (select count(*) from app.fulfilments where id::text like 'eb83%') <> 1
    or (select count(*) from app.fulfilment_lines
        where id::text like 'eb84%' and reversed_at is null) <> 1
    or (select count(*) from private.qr_tokens
        where id::text like 'eb85%' and active) <> 1
  then
    raise exception 'UPGRADE_FULFILMENT_OR_QR_RECONCILIATION_MISMATCH';
  end if;
  if (select count(*) from app.inventory_allocations
      where legacy_reservation_id::text like 'eb82%') <> 3
    or (select count(*) from app.inventory_allocations
        where legacy_reservation_id::text like 'eb82%'
          and reconciliation_status = 'review_required') <> 1
    or (select count(*) from app.inventory_allocations
        where legacy_reservation_id::text like 'eb82%'
          and status = 'reserved') <> 1
    or (select count(*) from app.inventory_allocations
        where legacy_reservation_id::text like 'eb82%'
          and status = 'fulfilled') <> 1
    or (select count(*) from app.inventory_allocations
        where legacy_reservation_id::text like 'eb82%'
          and status = 'released') <> 1
  then
    raise exception 'UPGRADE_INVENTORY_ALLOCATION_BACKFILL_MISMATCH';
  end if;
  if (select count(*) from private.inventory_legacy_reconciliation
      where receipt_line_id::text like 'eb81%' and status = 'pending') <> 2
    or (select sum(unassigned_quantity)
        from private.inventory_legacy_reconciliation
        where receipt_line_id::text like 'eb81%') <> 5
    or (select coalesce(sum(on_hand_delta), 0) from app.inventory_movements
        where source_type = 'inventory_reservation'
          and source_id::text like 'eb82%') <> 1
    or (select coalesce(sum(reserved_delta), 0) from app.inventory_movements
        where source_type = 'inventory_reservation'
          and source_id::text like 'eb82%') <> 1
    or (select coalesce(sum(issued_delta), 0) from app.inventory_movements
        where source_type = 'inventory_reservation'
          and source_id::text like 'eb82%') <> 1
  then
    raise exception 'UPGRADE_INVENTORY_JOURNAL_BACKFILL_MISMATCH';
  end if;
  if (private.inventory_reconciliation_report()->>'pendingCandidates')::integer <> 2
    or (private.inventory_reconciliation_report()->>'pendingQuantity')::integer <> 5
    or (private.inventory_reconciliation_report()->>'reviewAllocations')::integer <> 1
    or (private.inventory_reconciliation_report()->>'ready')::boolean
    or (select enabled from app.release_feature_flags
        where key = 'allocation_qr_v2')
  then
    raise exception 'UPGRADE_INVENTORY_CUTOVER_NOT_BLOCKED';
  end if;

  select count(*) into invalid_constraints
  from pg_constraint constraint_row
  join pg_class table_row on table_row.oid = constraint_row.conrelid
  join pg_namespace namespace_row on namespace_row.oid = table_row.relnamespace
  where namespace_row.nspname in ('app', 'private')
    and table_row.relname in (
      'member_seasons',
      'member_sensitive_identity',
      'member_external_identities',
      'parent_portal_grants',
      'package_templates',
      'package_template_revisions',
      'package_template_items',
      'order_package_snapshots',
      'order_package_snapshot_items',
      'inventory_delivery_drafts',
      'inventory_delivery_draft_lines',
      'inventory_allocations',
      'inventory_allocation_events',
      'inventory_movements',
      'inventory_legacy_reconciliation',
      'inventory_legacy_assignments'
    )
    and not constraint_row.convalidated;
  if invalid_constraints <> 0 then
    raise exception 'UPGRADE_UNVALIDATED_CONSTRAINTS';
  end if;

  select count(*) into missing_rls
  from (values
    ('app', 'member_seasons'),
    ('private', 'member_sensitive_identity'),
    ('app', 'member_external_identities'),
    ('private', 'parent_portal_grants'),
    ('app', 'package_templates'),
    ('app', 'package_template_revisions'),
    ('app', 'package_template_items'),
    ('app', 'order_package_snapshots'),
    ('app', 'order_package_snapshot_items'),
    ('app', 'inventory_delivery_drafts'),
    ('app', 'inventory_delivery_draft_lines'),
    ('app', 'inventory_allocations'),
    ('app', 'inventory_allocation_events'),
    ('app', 'inventory_movements'),
    ('private', 'inventory_legacy_reconciliation'),
    ('private', 'inventory_legacy_assignments'),
    ('private', 'migration_reconciliations')
  ) expected(schema_name, table_name)
  left join pg_namespace namespace_row on namespace_row.nspname = expected.schema_name
  left join pg_class table_row
    on table_row.relnamespace = namespace_row.oid
    and table_row.relname = expected.table_name
    and table_row.relkind = 'r'
  where table_row.oid is null or not table_row.relrowsecurity;
  if missing_rls <> 0 then
    raise exception 'UPGRADE_RLS_MISSING';
  end if;

  if (select count(*) from supabase_migrations.schema_migrations
      where version in ('20260802180000', '20260802263000', '20260802264000')) <> 3 then
    raise exception 'UPGRADE_MIGRATION_LEDGER_MISMATCH';
  end if;
end;
$$;

select 'phase-b-expand-upgrade-assertions-passed';

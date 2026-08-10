\set ON_ERROR_STOP on

with fingerprint as (
  select jsonb_build_object(
    'members', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, relation_number, email, team, active_for_season
        from app.members
        where id::text like 'eb4%'
        order by id
      ) row_data
    ),
    'orders', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, member_id, season_id, amount_due_cents, order_status
        from app.member_orders
        where id::text like 'eb5%'
        order by id
      ) row_data
    ),
    'orderLines', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, order_id, article_variant_id, article_id, quantity, status, size_snapshot
        from app.order_lines
        where id::text like 'eb6%'
        order by id
      ) row_data
    ),
    'payments', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, order_id, method, status, amount_cents, currency,
          provider_payment_id, idempotency_key, paid_at
        from app.payments
        where id::text like 'eb7%'
        order by id
      ) row_data
    ),
    'receiptLines', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, receipt_id, article_variant_id, received_quantity
        from app.delivery_receipt_lines
        where id::text like 'eb81%'
        order by id
      ) row_data
    ),
    'reservations', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, receipt_line_id, order_line_id, quantity, status
        from app.inventory_reservations
        where id::text like 'eb82%'
        order by id
      ) row_data
    ),
    'fulfilments', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, order_id, location, reversed_at, corrected_at
        from app.fulfilments
        where id::text like 'eb83%'
        order by id
      ) row_data
    ),
    'fulfilmentLines', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, fulfilment_id, order_line_id, reservation_id, quantity, reversed_at
        from app.fulfilment_lines
        where id::text like 'eb84%'
        order by id
      ) row_data
    ),
    'qrTokens', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, order_id, version, active
        from private.qr_tokens
        where id::text like 'eb85%'
        order by id
      ) row_data
    ),
    'memberSizes', (
      select coalesce(jsonb_agg(to_jsonb(row_data)
        order by row_data.member_id, row_data.season_id, row_data.article_id), '[]'::jsonb)
      from (
        select member_id, season_id, article_id, article_variant_id
        from app.member_article_sizes
        where member_id::text like 'eb4%'
        order by member_id, season_id, article_id
      ) row_data
    ),
    'parentAccounts', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, email_normalized
        from private.parent_accounts
        where id::text like 'eb86%'
        order by id
      ) row_data
    ),
    'parentLinks', (
      select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.id), '[]'::jsonb)
      from (
        select id, parent_account_id, member_id, unlinked_at
        from private.parent_member_links
        where id::text like 'eb87%'
        order by id
      ) row_data
    )
  ) payload
)
select encode(extensions.digest(payload::text, 'sha256'), 'hex')
from fingerprint;

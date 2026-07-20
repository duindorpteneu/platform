create or replace function private.team_order_articles_revision(
  p_team text,
  p_variant_ids uuid[],
  p_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws('|',
    'team-order-articles-v2', p_season_id::text, p_team,
    coalesce((select season.default_amount_cents::text from app.seasons season where season.id = p_season_id), ''),
    coalesce((select string_agg(value::text, ',' order by value) from unnest(p_variant_ids) value), ''),
    coalesce((
      select string_agg(member.id::text || ':' || member.active_for_season::text, ',' order by member.id)
      from app.members member where member.team = p_team
    ), ''),
    coalesce((
      select string_agg(orders.id::text || ':' || orders.member_id::text || ':' ||
        (exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'))::text,
        ',' order by orders.member_id)
      from app.member_orders orders
      join app.members member on member.id = orders.member_id
      where member.team = p_team and orders.season_id = p_season_id
    ), ''),
    coalesce((
      select string_agg(line.order_id::text || ':' || line.article_id::text || ':' || line.status::text,
        ',' order by line.order_id, line.article_id, line.id)
      from app.order_lines line
      join app.member_orders orders on orders.id = line.order_id and orders.season_id = p_season_id
      join app.members member on member.id = orders.member_id and member.team = p_team
      where line.article_id in (
        select variant.article_id from app.article_variants variant where variant.id = any(p_variant_ids)
      )
    ), ''),
    coalesce((
      select string_agg(variant.id::text || ':' || variant.article_id::text || ':' || variant.active::text || ':' ||
        article.active::text || ':' || (exists(
          select 1 from app.article_seasons link where link.article_id = article.id and link.season_id = p_season_id
        ))::text, ',' order by variant.id)
      from app.article_variants variant
      join app.articles article on article.id = variant.article_id
      where variant.id = any(p_variant_ids)
    ), '')
  ), 'sha256'), 'hex');
$$;

revoke all on function private.team_order_articles_revision(text, uuid[], uuid) from public, anon, authenticated;

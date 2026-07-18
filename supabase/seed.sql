insert into app.seasons (name, starts_on, ends_on, default_amount_cents, status, opened_at)
values ('2025/26', '2025-08-01', '2026-07-31', 12500, 'open', timezone('utc', now()))
on conflict (name) do nothing;

insert into app.app_settings (id, club_name, active_season_id)
select true, 'Duindorp SV', id from app.seasons where name = '2025/26'
on conflict (id) do update set active_season_id = excluded.active_season_id;

insert into app.articles (name, code, icon_type, sort_order)
values
  ('Shirt', 'SHIRT', 'shirt', 1),
  ('Broekje', 'BROEK', 'circle-dot', 2),
  ('Sokken', 'SOK', 'package', 3)
on conflict do nothing;

insert into app.article_seasons(article_id, season_id)
select article.id, settings.active_season_id
from app.articles article
cross join app.app_settings settings
where settings.id = true and settings.active_season_id is not null
on conflict do nothing;

insert into app.seasons (name, starts_on, ends_on, default_amount_cents, status, opened_at)
values ('2025/26', '2025-08-01', '2026-07-31', 12500, 'open', timezone('utc', now()))
on conflict (name) do nothing;

insert into app.app_settings (id, club_name, active_season_id)
select true, 'Duindorp SV', id from app.seasons where name = '2025/26'
on conflict (id) do update set active_season_id = excluded.active_season_id;

insert into app.articles (name, sort_order)
values ('Shirt', 1), ('Broekje', 2), ('Sokken', 3)
on conflict do nothing;

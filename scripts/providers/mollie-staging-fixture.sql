\set ON_ERROR_STOP on

begin;

select exists (
  select 1
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id
  where settings.id = true and season.status = 'open'
) as has_active_season \gset

\if :has_active_season
\else
  \echo 'MOLLIE_FIXTURE_ACTIVE_SEASON_REQUIRED'
  \quit 3
\endif

select exists (
  select 1 from app.members
  where relation_number in (:'paid_relation', :'mismatch_relation')
) as fixture_exists \gset

\if :fixture_exists
  \echo 'MOLLIE_FIXTURE_ALREADY_EXISTS'
  \quit 3
\endif

select mollie_enabled as previous_mollie_enabled,
       active_season_id as fixture_season_id
from app.app_settings
where id = true
\gset

insert into app.members (
  id, relation_number, first_name, last_name, email, team, active_for_season
) values
  (:'paid_member_id', :'paid_relation', 'Mollie', 'Acceptance Paid', :'fixture_email',
    case when :'previous_mollie_enabled'::boolean then 'MOLLIE-ACCEPTANCE-M1' else 'MOLLIE-ACCEPTANCE-M0' end, true),
  (:'mismatch_member_id', :'mismatch_relation', 'Mollie', 'Acceptance Mismatch', :'fixture_email',
    case when :'previous_mollie_enabled'::boolean then 'MOLLIE-ACCEPTANCE-M1' else 'MOLLIE-ACCEPTANCE-M0' end, true);

insert into app.member_orders (id, member_id, season_id, amount_due_cents)
values
  (:'paid_order_id', :'paid_member_id', :'fixture_season_id', 100),
  (:'mismatch_order_id', :'mismatch_member_id', :'fixture_season_id', 100);

insert into private.parent_accounts (id, email_normalized)
values (:'parent_account_id', :'fixture_email');

insert into private.parent_member_links (parent_account_id, member_id)
values
  (:'parent_account_id', :'paid_member_id'),
  (:'parent_account_id', :'mismatch_member_id');

update app.app_settings
set mollie_enabled = true, updated_at = timezone('utc', now())
where id = true;

commit;

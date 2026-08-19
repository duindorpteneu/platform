-- Package obligations are born at assignment time. The immutable commercial
-- snapshot is the assignment identity; catalog changes therefore cannot alter
-- an existing member's obligations, confirmation or payment history.

create table app.member_package_assignments (
  id uuid primary key references app.order_package_snapshots(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  member_season_id uuid not null references app.member_seasons(id) on delete restrict,
  package_revision_id uuid references app.package_template_revisions(id) on delete restrict,
  status text not null check (status in ('active', 'historical', 'withdrawn')),
  assigned_at timestamptz not null,
  ended_at timestamptz,
  assignment_reason text not null default 'Bestaande pakkettoewijzing',
  constraint member_package_assignment_lifecycle check (
    (status = 'active' and ended_at is null)
    or (status in ('historical', 'withdrawn') and ended_at is not null)
  ),
  unique (id, member_season_id),
  unique (id, order_id)
);

create unique index member_package_assignments_one_active_idx
  on app.member_package_assignments(member_season_id) where status = 'active';
create index member_package_assignments_history_idx
  on app.member_package_assignments(member_season_id, assigned_at desc);

insert into app.member_package_assignments(
  id, order_id, member_season_id, package_revision_id, status,
  assigned_at, ended_at, assignment_reason
)
select snapshot.id, snapshot.order_id, snapshot.member_season_id,
  snapshot.template_revision_id,
  case
    when orders.active_package_snapshot_id = snapshot.id
      and orders.package_assignment_state = 'active' then 'active'
    when orders.active_package_snapshot_id = snapshot.id
      and orders.package_assignment_state = 'withdrawn' then 'withdrawn'
    else 'historical'
  end,
  snapshot.created_at,
  case when orders.active_package_snapshot_id = snapshot.id
      and orders.package_assignment_state = 'active'
    then null else greatest(snapshot.created_at, orders.updated_at) end,
  coalesce(nullif(btrim(snapshot.reason), ''), 'Gemigreerde pakkettoewijzing')
from app.order_package_snapshots snapshot
join app.member_orders orders on orders.id = snapshot.order_id;

create table app.member_package_size_selections (
  assignment_id uuid not null,
  member_season_id uuid not null,
  snapshot_item_id uuid not null references app.order_package_snapshot_items(id) on delete restrict,
  article_id uuid not null references app.articles(id) on delete restrict,
  confirmation_id uuid not null references app.package_size_confirmations(id) on delete restrict,
  selection_kind text not null check (selection_kind in ('variant', 'other')),
  selected_variant_id uuid,
  other_note text,
  size_label_snapshot text not null,
  confirmed_at timestamptz not null,
  confirmed_by_source text not null check (confirmed_by_source in ('parent', 'staff')),
  primary key (assignment_id, article_id),
  foreign key (assignment_id, member_season_id)
    references app.member_package_assignments(id, member_season_id) on delete restrict,
  foreign key (selected_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict,
  unique (assignment_id, snapshot_item_id),
  constraint member_package_size_selection_payload check (
    (selection_kind = 'variant' and selected_variant_id is not null and other_note is null)
    or (selection_kind = 'other' and selected_variant_id is null
      and length(btrim(coalesce(other_note, ''))) between 1 and 500)
  )
);

-- Latest immutable confirmation is the current projection. Earlier ledgers and
-- their items remain untouched and continue to provide the full audit trail.
insert into app.member_package_size_selections(
  assignment_id, member_season_id, snapshot_item_id, article_id,
  confirmation_id, selection_kind, selected_variant_id, other_note,
  size_label_snapshot, confirmed_at, confirmed_by_source
)
select distinct on (confirmation.package_snapshot_id, item.article_id)
  confirmation.package_snapshot_id, confirmation.member_season_id,
  item.snapshot_item_id, item.article_id, confirmation.id,
  item.selection_kind, item.selected_variant_id, item.other_note,
  item.size_label_snapshot, confirmation.created_at, confirmation.source
from app.package_size_confirmation_items item
join app.package_size_confirmations confirmation
  on confirmation.id = item.confirmation_id
where confirmation.package_snapshot_id is not null
order by confirmation.package_snapshot_id, item.article_id,
  confirmation.revision desc, confirmation.created_at desc;

create or replace function private.sync_member_package_assignment()
returns trigger language plpgsql security definer
set search_path = app, private, pg_temp as $$
begin
  update app.member_package_assignments
  set status = 'historical', ended_at = coalesce(ended_at, timezone('utc', now()))
  where member_season_id = new.member_season_id
    and status = 'active' and id <> new.active_package_snapshot_id;

  insert into app.member_package_assignments(
    id, order_id, member_season_id, package_revision_id, status,
    assigned_at, ended_at, assignment_reason
  )
  select snapshot.id, new.id, new.member_season_id, snapshot.template_revision_id,
    case when new.package_assignment_state = 'active' then 'active' else 'withdrawn' end,
    snapshot.created_at,
    case when new.package_assignment_state = 'active' then null else timezone('utc', now()) end,
    coalesce(nullif(btrim(snapshot.reason), ''), 'Pakket toegewezen door beheer')
  from app.order_package_snapshots snapshot
  where snapshot.id = new.active_package_snapshot_id
  on conflict (id) do update set
    status = excluded.status,
    ended_at = excluded.ended_at;
  return new;
end;
$$;

create trigger member_orders_sync_package_assignment
after insert or update of active_package_snapshot_id, package_assignment_state
on app.member_orders for each row execute function private.sync_member_package_assignment();

create or replace function private.project_assignment_size_selection()
returns trigger language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target app.package_size_confirmations%rowtype;
begin
  select * into target from app.package_size_confirmations where id = new.confirmation_id;
  -- A parent request after reservation records the requested alternative in the
  -- immutable ledger, but the effective assignment choice remains the reserved
  -- variant until staff resolves that request.
  if exists(
    select 1 from app.member_article_sizes size_profile
    where size_profile.member_season_id = target.member_season_id
      and size_profile.article_id = new.article_id
      and size_profile.selection_status = 'change_requested'
  ) then
    return new;
  end if;
  insert into app.member_package_size_selections(
    assignment_id, member_season_id, snapshot_item_id, article_id,
    confirmation_id, selection_kind, selected_variant_id, other_note,
    size_label_snapshot, confirmed_at, confirmed_by_source
  ) values (
    target.package_snapshot_id, target.member_season_id, new.snapshot_item_id,
    new.article_id, target.id, new.selection_kind, new.selected_variant_id,
    new.other_note, new.size_label_snapshot, target.created_at, target.source
  ) on conflict (assignment_id, article_id) do update set
    snapshot_item_id = excluded.snapshot_item_id,
    confirmation_id = excluded.confirmation_id,
    selection_kind = excluded.selection_kind,
    selected_variant_id = excluded.selected_variant_id,
    other_note = excluded.other_note,
    size_label_snapshot = excluded.size_label_snapshot,
    confirmed_at = excluded.confirmed_at,
    confirmed_by_source = excluded.confirmed_by_source;
  return new;
end;
$$;

create trigger package_confirmation_item_project_assignment
after insert on app.package_size_confirmation_items
for each row execute function private.project_assignment_size_selection();

-- Completeness is an assignment fact, never a property of the global member
-- size staging profile. Every required snapshot item needs a selection written
-- by a confirmation for this exact assignment.
create or replace function private.package_sizes_complete(
  p_order_id uuid, p_snapshot_id uuid
) returns boolean language sql stable security definer
set search_path = app, private, pg_temp as $$
  select p_order_id is not null and p_snapshot_id is not null
    and exists(
      select 1 from app.member_package_assignments assignment
      where assignment.id = p_snapshot_id and assignment.order_id = p_order_id
    )
    and exists(
      select 1 from app.order_package_snapshot_items item
      where item.snapshot_id = p_snapshot_id
    )
    and not exists(
      select 1 from app.order_package_snapshot_items item
      where item.snapshot_id = p_snapshot_id
        and not exists(
          select 1 from app.member_package_size_selections selection
          where selection.assignment_id = p_snapshot_id
            and selection.snapshot_item_id = item.id
            and selection.article_id = item.article_id
        )
    );
$$;
revoke all on function private.package_sizes_complete(uuid, uuid)
from public, anon, authenticated, service_role;

-- The established confirmation workflow already distinguishes freely editable
-- pre-reservation sizes from post-reservation change requests. Keep that workflow
-- authoritative so a reserved-size correction creates its audited action item
-- instead of being rejected before the domain transition can run.

-- The parent projection never advertises globally published alternatives.
create or replace function public.get_parent_package_workspace_v7(p_token_hash text)
returns jsonb language sql stable security definer
set search_path = app, private, public, pg_temp as $$
  with workspace as (select public.get_parent_package_workspace_v6(p_token_hash) result)
  select jsonb_set(workspace.result, '{members}', coalesce((
    select jsonb_agg(
      jsonb_set(
        case when member.value->'order' <> 'null'::jsonb
          then jsonb_set(member.value, '{order,canSwitchPackage}', 'false'::jsonb, true)
          else member.value end,
        '{availablePackages}', '[]'::jsonb, true
      ) order by member.ordinality
    ) from jsonb_array_elements(workspace.result->'members')
      with ordinality member(value, ordinality)
  ), '[]'::jsonb), true) from workspace;
$$;
revoke all on function public.get_parent_package_workspace_v7(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v7(text) to service_role;

-- Backoffice size correction is projected from the active assignment only;
-- globally active season articles are no longer presented as member duties.
alter function private.member_size_profile_json_v3(uuid)
rename to member_size_profile_json_v3_global;
create function private.member_size_profile_json_v3(p_member_season_id uuid)
returns jsonb language sql stable security definer
set search_path = app, private, pg_temp as $$
  with profile as (
    select private.member_size_profile_json_v3_global(p_member_season_id) result
  ), active_assignment as (
    select orders.active_package_snapshot_id snapshot_id
    from app.member_orders orders
    where orders.member_season_id = p_member_season_id
      and orders.package_assignment_state = 'active'
  )
  select jsonb_set(profile.result, '{articles}', coalesce((
    select jsonb_agg(article.value order by article.ordinality)
    from jsonb_array_elements(profile.result->'articles')
      with ordinality article(value, ordinality)
    where not exists(select 1 from active_assignment)
      or exists(
      select 1 from app.order_package_snapshot_items snapshot_item
      join active_assignment assignment
        on assignment.snapshot_id = snapshot_item.snapshot_id
      where snapshot_item.article_id = (article.value->>'id')::uuid
    )
  ), '[]'::jsonb), true) from profile;
$$;
revoke all on function private.member_size_profile_json_v3_global(uuid),
  private.member_size_profile_json_v3(uuid)
from public, anon, authenticated, service_role;

alter table app.member_package_assignments enable row level security;
alter table app.member_package_size_selections enable row level security;
revoke all on table app.member_package_assignments,
  app.member_package_size_selections from public, anon, authenticated, service_role;
revoke all on function private.sync_member_package_assignment(),
  private.project_assignment_size_selection()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

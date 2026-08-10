-- Versioned mail templates and fixed Duindorp SV operational branding.
--
-- This is an additive expand migration. The seven legacy rows in
-- app.email_templates remain untouched so the legacy worker and application
-- rollback contract keep their exact response shape while mail_templates_v2 is
-- disabled.

create table app.mail_shortcode_definitions (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{2,63}$'),
  value_type text not null check (
    value_type in ('text', 'email', 'money', 'url', 'integer')
  ),
  description text not null check (length(btrim(description)) between 3 and 240),
  created_at timestamptz not null default timezone('utc', now())
);

insert into app.mail_shortcode_definitions(key, value_type, description) values
  ('club_name', 'text', 'Vaste verenigingsnaam'),
  ('recipient_name', 'text', 'Naam van de ontvanger'),
  ('member_first_name', 'text', 'Voornaam van het lid'),
  ('member_full_name', 'text', 'Volledige naam van het lid'),
  ('team_name', 'text', 'Team van het lid in dit seizoen'),
  ('season_name', 'text', 'Naam van het seizoen'),
  ('package_name', 'text', 'Historische pakketnaam'),
  ('package_amount', 'money', 'Historisch pakketbedrag'),
  ('payment_url', 'url', 'Servergegenereerde betaallink'),
  ('portal_url', 'url', 'Servergegenereerde portaalroute'),
  ('size_confirm_url', 'url', 'Servergegenereerde maatbevestigingsroute'),
  ('pickup_name', 'text', 'Naam van de afhaallocatie'),
  ('pickup_address', 'text', 'Adres van de afhaallocatie'),
  ('contact_email', 'email', 'Contactadres van de kledingcommissie'),
  ('privacy_url', 'url', 'Privacyroute van Duindorp SV'),
  ('otp_expiry_minutes', 'integer', 'Geldigheidsduur van de verificatiecode');

create table app.mail_protected_node_definitions (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{2,63}$'),
  description text not null check (length(btrim(description)) between 3 and 240),
  created_at timestamptz not null default timezone('utc', now())
);

insert into app.mail_protected_node_definitions(key, description) values
  ('portal_route', 'Beveiligde portaalroute zonder login-token'),
  ('otp_code', 'Eenmalige zescijferige verificatiecode'),
  ('otp_validity', 'Geldigheid van de verificatiecode'),
  ('otp_warning', 'Waarschuwing om de verificatiecode niet te delen'),
  ('size_table', 'Beschermde tabel met pakketmaten'),
  ('size_action', 'Beveiligde maatbevestigingsactie'),
  ('payment_summary', 'Beschermde betaalsamenvatting'),
  ('payment_action', 'Beveiligde betaalactie'),
  ('ready_items', 'Beschermde tabel met afhaalklare regels'),
  ('stock_items', 'Beschermde tabel met voorraadstatus'),
  ('picked_up_items', 'Beschermde tabel met zojuist afgehaalde regels'),
  ('remaining_items', 'Beschermde tabel met nog te leveren regels'),
  ('full_package', 'Beschermde tabel met het volledig uitgegeven pakket'),
  ('pickup_location', 'Beschermd afhaaladresblok'),
  ('pickup_qr', 'Beschermde QR- of portaalinstructie'),
  ('failure_reference', 'PII-vrije interne foutreferentie');

create or replace function private.text_array_is_unique(p_values text[])
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_values is not null
    and coalesce(array_length(p_values, 1), 0) = (
      select count(distinct value)
      from unnest(p_values) value
    );
$$;

create or replace function private.mail_mark_is_safe(p_mark jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  mark_type text;
  href text;
begin
  if jsonb_typeof(p_mark) <> 'object' or not (p_mark ? 'type') then
    return false;
  end if;
  mark_type := p_mark->>'type';
  if mark_type in ('bold', 'italic') then
    return (select count(*) = 1 from jsonb_object_keys(p_mark));
  end if;
  if mark_type <> 'link'
    or not (p_mark ? 'attrs')
    or (select count(*) from jsonb_object_keys(p_mark)) <> 2
    or jsonb_typeof(p_mark->'attrs') <> 'object'
    or not ((p_mark->'attrs') ? 'href')
    or (select count(*) from jsonb_object_keys(p_mark->'attrs')) <> 1
  then
    return false;
  end if;
  href := p_mark#>>'{attrs,href}';
  return length(href) between 9 and 2048
    and href !~ '[[:cntrl:][:space:]]'
    and href ~ '^https://[^/@[:space:]]+(/[^[:space:]]*)?$';
end;
$$;

create or replace function private.mail_node_is_safe(
  p_node jsonb,
  p_depth integer,
  p_parent_type text
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  node_type text;
  child jsonb;
  mark jsonb;
  child_count integer;
  child_type text;
  marks jsonb;
  allowed_child_types text[];
begin
  if p_depth not between 0 and 10
    or jsonb_typeof(p_node) <> 'object'
    or not (p_node ? 'type')
  then
    return false;
  end if;
  node_type := p_node->>'type';

  if node_type = 'text' then
    if p_parent_type not in ('paragraph', 'heading')
      or not (p_node ? 'text')
      or jsonb_typeof(p_node->'text') <> 'string'
      or length(p_node->>'text') not between 1 and 4000
      or p_node->>'text' ~ '[[:cntrl:]]'
      or p_node->>'text' ~ '\{\{|\}\}'
      or (select count(*) from jsonb_object_keys(p_node)) not between 2 and 3
    then
      return false;
    end if;
    if p_node ? 'marks' then
      marks := p_node->'marks';
      if jsonb_typeof(marks) <> 'array' or jsonb_array_length(marks) > 4 then
        return false;
      end if;
      for mark in select value from jsonb_array_elements(marks)
      loop
        if not private.mail_mark_is_safe(mark) then
          return false;
        end if;
      end loop;
      if (
        select count(*) <> count(distinct value->>'type')
        from jsonb_array_elements(marks)
      ) then
        return false;
      end if;
    end if;
    return true;
  end if;

  if node_type = 'hardBreak' then
    return p_parent_type in ('paragraph', 'heading')
      and (select count(*) = 1 from jsonb_object_keys(p_node));
  end if;

  if node_type = 'shortcode' then
    return p_parent_type in ('paragraph', 'heading')
      and (select count(*) = 2 from jsonb_object_keys(p_node))
      and jsonb_typeof(p_node->'attrs') = 'object'
      and (select count(*) = 1 from jsonb_object_keys(p_node->'attrs'))
      and (p_node->'attrs') ? 'key'
      and exists(
        select 1
        from app.mail_shortcode_definitions definition
        where definition.key = p_node#>>'{attrs,key}'
      );
  end if;

  if node_type = 'protectedBlock' then
    return p_parent_type = 'doc'
      and (select count(*) = 2 from jsonb_object_keys(p_node))
      and jsonb_typeof(p_node->'attrs') = 'object'
      and (select count(*) = 1 from jsonb_object_keys(p_node->'attrs'))
      and (p_node->'attrs') ? 'kind'
      and exists(
        select 1
        from app.mail_protected_node_definitions definition
        where definition.key = p_node#>>'{attrs,kind}'
      );
  end if;

  if node_type = 'doc' then
    if p_parent_type is not null
      or (select count(*) from jsonb_object_keys(p_node)) <> 2
    then
      return false;
    end if;
    allowed_child_types := array[
      'paragraph', 'heading', 'bulletList', 'orderedList', 'protectedBlock'
    ];
  elsif node_type = 'paragraph' then
    if p_parent_type not in ('doc', 'listItem')
      or (select count(*) from jsonb_object_keys(p_node)) <> 2
    then
      return false;
    end if;
    allowed_child_types := array['text', 'shortcode', 'hardBreak'];
  elsif node_type = 'heading' then
    if p_parent_type <> 'doc'
      or (select count(*) from jsonb_object_keys(p_node)) <> 3
      or jsonb_typeof(p_node->'attrs') <> 'object'
      or (select count(*) = 1 from jsonb_object_keys(p_node->'attrs')) is false
      or not ((p_node->'attrs') ? 'level')
      or p_node#>>'{attrs,level}' not in ('2', '3')
    then
      return false;
    end if;
    allowed_child_types := array['text', 'shortcode', 'hardBreak'];
  elsif node_type in ('bulletList', 'orderedList') then
    if p_parent_type not in ('doc', 'listItem')
      or (select count(*) from jsonb_object_keys(p_node)) <> 2
    then
      return false;
    end if;
    allowed_child_types := array['listItem'];
  elsif node_type = 'listItem' then
    if p_parent_type not in ('bulletList', 'orderedList')
      or (select count(*) from jsonb_object_keys(p_node)) <> 2
    then
      return false;
    end if;
    allowed_child_types := array['paragraph', 'bulletList', 'orderedList'];
  else
    return false;
  end if;

  if not (p_node ? 'content')
    or jsonb_typeof(p_node->'content') <> 'array'
  then
    return false;
  end if;
  child_count := jsonb_array_length(p_node->'content');
  if (node_type in ('doc', 'listItem', 'bulletList', 'orderedList') and child_count < 1)
    or child_count > 100
  then
    return false;
  end if;
  for child in select value from jsonb_array_elements(p_node->'content')
  loop
    child_type := child->>'type';
    if not child_type = any(allowed_child_types)
      or not private.mail_node_is_safe(child, p_depth + 1, node_type)
    then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

create or replace function private.mail_document_is_safe(p_document jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  node_count integer;
begin
  if p_document is null
    or octet_length(p_document::text) > 65536
    or not private.mail_node_is_safe(p_document, 0, null)
  then
    return false;
  end if;
  with recursive nodes(node) as (
    select p_document
    union all
    select child.value
    from nodes parent
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(parent.node->'content') = 'array'
          then parent.node->'content'
        else '[]'::jsonb
      end
    ) child
  )
  select count(*) into node_count from nodes;
  return node_count between 2 and 500;
end;
$$;

create or replace function private.mail_source_tokens_are_safe(
  p_source text,
  p_allowed_keys text[]
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  token_match text[];
  remainder text;
begin
  if p_source is null or p_allowed_keys is null then
    return false;
  end if;
  for token_match in
    select regexp_matches(p_source, '\{\{([a-z][a-z0-9_]{2,63})\}\}', 'g')
  loop
    if not token_match[1] = any(p_allowed_keys)
      or not exists(
        select 1
        from app.mail_shortcode_definitions definition
        where definition.key = token_match[1]
      )
    then
      return false;
    end if;
  end loop;
  remainder := regexp_replace(
    p_source,
    '\{\{[a-z][a-z0-9_]{2,63}\}\}',
    '',
    'g'
  );
  return remainder !~ '\{\{|\}\}';
end;
$$;

create or replace function private.mail_html_is_safe(p_html text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_html is not null
    and octet_length(p_html) between 1 and 100000
    and p_html !~ '[[:cntrl:]]'
    and p_html !~* '<[[:space:]]*(script|style|iframe|frame|object|embed|form|input|button|textarea|select|option|svg|math|img|video|audio|meta|link|base)([[:space:]>]|$)'
    and p_html !~* '[[:space:]]on[a-z]+[[:space:]]*='
    and p_html !~* '(javascript|vbscript|data)[[:space:]]*:'
    and p_html !~* '(srcdoc|formaction|xlink:href)[[:space:]]*=';
$$;

revoke all on function private.text_array_is_unique(text[])
from public, anon, authenticated, service_role;
revoke all on function private.mail_mark_is_safe(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.mail_node_is_safe(jsonb, integer, text)
from public, anon, authenticated, service_role;
revoke all on function private.mail_document_is_safe(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.mail_source_tokens_are_safe(text, text[])
from public, anon, authenticated, service_role;
revoke all on function private.mail_html_is_safe(text)
from public, anon, authenticated, service_role;

create table app.mail_templates (
  template_key text primary key check (
    template_key ~ '^[a-z][a-z0-9_]{2,63}$'
  ),
  internal_name text not null check (
    length(btrim(internal_name)) between 3 and 120
  ),
  process text not null check (
    process in (
      'portal_access',
      'authentication',
      'size',
      'payment',
      'inventory',
      'fulfilment',
      'internal'
    )
  ),
  audience text not null check (audience in ('external', 'internal')),
  allowed_shortcode_keys text[] not null check (
    coalesce(array_length(allowed_shortcode_keys, 1), 0) between 1 and 32
    and private.text_array_is_unique(allowed_shortcode_keys)
  ),
  required_shortcode_keys text[] not null default '{}'::text[] check (
    private.text_array_is_unique(required_shortcode_keys)
    and required_shortcode_keys <@ allowed_shortcode_keys
  ),
  allowed_protected_nodes text[] not null check (
    coalesce(array_length(allowed_protected_nodes, 1), 0) between 1 and 16
    and private.text_array_is_unique(allowed_protected_nodes)
  ),
  required_protected_nodes text[] not null check (
    coalesce(array_length(required_protected_nodes, 1), 0) between 1 and 16
    and private.text_array_is_unique(required_protected_nodes)
    and required_protected_nodes <@ allowed_protected_nodes
  ),
  active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now())
);

insert into app.mail_templates(
  template_key,
  internal_name,
  process,
  audience,
  allowed_shortcode_keys,
  required_shortcode_keys,
  allowed_protected_nodes,
  required_protected_nodes
) values
  (
    'portal_access_invite', 'Portaaltoegang uitnodiging', 'portal_access', 'external',
    array['club_name','recipient_name','portal_url','contact_email','privacy_url'],
    array['club_name','portal_url'],
    array['portal_route'], array['portal_route']
  ),
  (
    'portal_access_reminder', 'Portaaltoegang herinnering', 'portal_access', 'external',
    array['club_name','recipient_name','portal_url','contact_email','privacy_url'],
    array['club_name','portal_url'],
    array['portal_route'], array['portal_route']
  ),
  (
    'login_otp', 'Inlogcode', 'authentication', 'external',
    array['club_name','recipient_name','contact_email','otp_expiry_minutes','privacy_url'],
    array['club_name','otp_expiry_minutes'],
    array['otp_code','otp_validity','otp_warning'],
    array['otp_code','otp_validity','otp_warning']
  ),
  (
    'size_fill_request', 'Maten invullen', 'size', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','size_confirm_url','contact_email','privacy_url'],
    array['member_first_name','season_name','size_confirm_url'],
    array['size_table','size_action'], array['size_table','size_action']
  ),
  (
    'size_fill_reminder', 'Herinnering maten invullen', 'size', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','size_confirm_url','contact_email','privacy_url'],
    array['member_first_name','season_name','size_confirm_url'],
    array['size_table','size_action'], array['size_table','size_action']
  ),
  (
    'size_review_request', 'Maten controleren', 'size', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','size_confirm_url','contact_email','privacy_url'],
    array['member_first_name','season_name','size_confirm_url'],
    array['size_table','size_action'], array['size_table','size_action']
  ),
  (
    'size_review_reminder', 'Herinnering maten controleren', 'size', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','size_confirm_url','contact_email','privacy_url'],
    array['member_first_name','season_name','size_confirm_url'],
    array['size_table','size_action'], array['size_table','size_action']
  ),
  (
    'size_confirmed', 'Maten bevestigd', 'size', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','contact_email','privacy_url'],
    array['member_first_name','season_name'],
    array['size_table'], array['size_table']
  ),
  (
    'payment_request', 'Betaalverzoek', 'payment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','package_amount','payment_url','portal_url','contact_email','privacy_url'],
    array['member_first_name','package_amount','payment_url'],
    array['payment_summary','payment_action'],
    array['payment_summary','payment_action']
  ),
  (
    'payment_reminder', 'Betalingsherinnering', 'payment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','package_amount','payment_url','portal_url','contact_email','privacy_url'],
    array['member_first_name','package_amount','payment_url'],
    array['payment_summary','payment_action'],
    array['payment_summary','payment_action']
  ),
  (
    'payment_received_waiting_stock', 'Betaling ontvangen, wacht op voorraad', 'payment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','package_amount','portal_url','contact_email','privacy_url'],
    array['member_first_name','package_amount'],
    array['payment_summary','stock_items'],
    array['payment_summary','stock_items']
  ),
  (
    'available_payment_required', 'Voorraad beschikbaar, betaling vereist', 'payment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','package_amount','payment_url','portal_url','contact_email','privacy_url'],
    array['member_first_name','package_amount','payment_url'],
    array['stock_items','payment_action'],
    array['stock_items','payment_action']
  ),
  (
    'pickup_ready', 'Pakketregels afhaalklaar', 'inventory', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','pickup_name','pickup_address','contact_email','privacy_url'],
    array['member_first_name','portal_url'],
    array['ready_items','pickup_location','pickup_qr'],
    array['ready_items','pickup_location','pickup_qr']
  ),
  (
    'pickup_reminder', 'Afhaalherinnering', 'inventory', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','pickup_name','pickup_address','contact_email','privacy_url'],
    array['member_first_name','portal_url'],
    array['ready_items','pickup_location','pickup_qr'],
    array['ready_items','pickup_location','pickup_qr']
  ),
  (
    'out_of_stock', 'Tijdelijk niet leverbaar', 'inventory', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','contact_email','privacy_url'],
    array['member_first_name'],
    array['stock_items'], array['stock_items']
  ),
  (
    'back_in_stock', 'Weer op voorraad', 'inventory', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','pickup_name','pickup_address','contact_email','privacy_url'],
    array['member_first_name'],
    array['ready_items','pickup_location'],
    array['ready_items','pickup_location']
  ),
  (
    'partial_pickup', 'Deel van pakket afgehaald', 'fulfilment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','contact_email','privacy_url'],
    array['member_first_name','season_name'],
    array['picked_up_items','remaining_items'],
    array['picked_up_items','remaining_items']
  ),
  (
    'package_complete', 'Pakket volledig afgehaald', 'fulfilment', 'external',
    array['club_name','recipient_name','member_first_name','member_full_name','team_name','season_name','package_name','portal_url','contact_email','privacy_url'],
    array['member_first_name','season_name'],
    array['full_package'], array['full_package']
  ),
  (
    'internal_email_failure', 'Definitieve e-mailfout', 'internal', 'internal',
    array['club_name','contact_email'],
    array['club_name'],
    array['failure_reference'], array['failure_reference']
  );

create table app.mail_template_revisions (
  id uuid primary key default gen_random_uuid(),
  template_key text not null references app.mail_templates(template_key)
    on delete restrict,
  revision integer not null check (revision > 0),
  status text not null default 'draft' check (
    status in ('draft', 'published', 'archived')
  ),
  internal_name text not null check (
    length(btrim(internal_name)) between 3 and 120
  ),
  subject_source text not null check (
    length(btrim(subject_source)) between 3 and 180
    and subject_source !~ '[[:cntrl:]]'
    and subject_source !~ '[<>]'
  ),
  preheader_source text not null check (
    length(btrim(preheader_source)) between 3 and 240
    and preheader_source !~ '[[:cntrl:]]'
    and preheader_source !~ '[<>]'
  ),
  body_tiptap jsonb not null check (
    private.mail_document_is_safe(body_tiptap)
  ),
  sanitized_html_source text,
  text_fallback_source text not null check (
    length(btrim(text_fallback_source)) between 3 and 20000
  ),
  schema_version integer not null default 1 check (schema_version = 1),
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  creation_source text not null check (creation_source in ('system', 'staff')),
  published_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  published_at timestamptz,
  archived_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  archived_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique(template_key, revision),
  constraint mail_template_revisions_lifecycle_check check (
    (
      status = 'draft'
      and published_by is null
      and published_at is null
      and archived_by is null
      and archived_at is null
    )
    or (
      status = 'published'
      and published_at is not null
      and archived_by is null
      and archived_at is null
      and (published_by is not null or creation_source = 'system')
    )
    or (
      status = 'archived'
      and published_at is not null
      and archived_at is not null
      and (published_by is not null or creation_source = 'system')
      and (archived_by is not null or creation_source = 'system')
    )
  ),
  constraint mail_template_revisions_html_check check (
    (status = 'draft' and (
      sanitized_html_source is null
      or private.mail_html_is_safe(sanitized_html_source)
    ))
    or (
      status in ('published', 'archived')
      and private.mail_html_is_safe(sanitized_html_source)
    )
  )
);

create unique index mail_template_revisions_one_draft_idx
  on app.mail_template_revisions(template_key)
  where status = 'draft';
create unique index mail_template_revisions_one_published_idx
  on app.mail_template_revisions(template_key)
  where status = 'published';
create index mail_template_revisions_history_idx
  on app.mail_template_revisions(template_key, revision desc);

create table app.mail_branding_revisions (
  id uuid primary key default gen_random_uuid(),
  revision integer not null unique check (revision > 0),
  status text not null default 'draft' check (
    status in ('draft', 'published', 'archived')
  ),
  club_name text not null check (club_name = 'Duindorp SV'),
  logo_asset_path text not null check (
    logo_asset_path = '/duindorp-sv-logo.png'
  ),
  from_name text not null check (
    length(btrim(from_name)) between 3 and 120
    and from_name !~ '[[:cntrl:]]'
  ),
  from_email text not null check (
    from_email = lower(btrim(from_email))
    and from_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  reply_to_email text not null check (
    reply_to_email = lower(btrim(reply_to_email))
    and reply_to_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  contact_email text not null check (
    contact_email = lower(btrim(contact_email))
    and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  club_address_line text not null check (
    length(btrim(club_address_line)) between 3 and 160
  ),
  club_postal_code text not null check (
    club_postal_code ~ '^[0-9]{4} [A-Z]{2}$'
  ),
  club_city text not null check (
    length(btrim(club_city)) between 2 and 120
  ),
  pickup_name text not null check (
    length(btrim(pickup_name)) between 3 and 120
  ),
  pickup_address_line text not null check (
    length(btrim(pickup_address_line)) between 3 and 160
  ),
  pickup_postal_code text not null check (
    pickup_postal_code ~ '^[0-9]{4} [A-Z]{2}$'
  ),
  pickup_city text not null check (
    length(btrim(pickup_city)) between 2 and 120
  ),
  privacy_url text not null check (
    privacy_url = 'https://duindorpsv.nl/privacy'
  ),
  primary_color text not null check (primary_color ~ '^#[0-9A-F]{6}$'),
  secondary_color text not null check (secondary_color ~ '^#[0-9A-F]{6}$'),
  accent_color text not null check (accent_color ~ '^#[0-9A-F]{6}$'),
  footer_text text not null check (
    length(btrim(footer_text)) between 3 and 1000
    and footer_text !~ '[<>]'
  ),
  contrast_validated boolean not null default false,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  creation_source text not null check (creation_source in ('system', 'staff')),
  published_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  published_at timestamptz,
  archived_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  archived_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint mail_branding_revisions_lifecycle_check check (
    (
      status = 'draft'
      and published_by is null
      and published_at is null
      and archived_by is null
      and archived_at is null
    )
    or (
      status = 'published'
      and published_at is not null
      and archived_by is null
      and archived_at is null
      and (published_by is not null or creation_source = 'system')
    )
    or (
      status = 'archived'
      and published_at is not null
      and archived_at is not null
      and (published_by is not null or creation_source = 'system')
      and (archived_by is not null or creation_source = 'system')
    )
  )
);

create unique index mail_branding_revisions_one_draft_idx
  on app.mail_branding_revisions((true))
  where status = 'draft';
create unique index mail_branding_revisions_one_published_idx
  on app.mail_branding_revisions((true))
  where status = 'published';

create or replace function private.mail_template_content_hash(
  p_template_key text,
  p_internal_name text,
  p_subject_source text,
  p_preheader_source text,
  p_body_tiptap jsonb,
  p_sanitized_html_source text,
  p_text_fallback_source text
)
returns text
language sql
immutable
set search_path = extensions, pg_catalog, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          p_template_key,
          btrim(p_internal_name),
          btrim(p_subject_source),
          btrim(p_preheader_source),
          p_body_tiptap::text,
          coalesce(p_sanitized_html_source, ''),
          btrim(p_text_fallback_source)
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function private.mail_branding_content_hash(
  p_branding app.mail_branding_revisions
)
returns text
language sql
immutable
set search_path = extensions, pg_catalog, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          p_branding.club_name,
          p_branding.logo_asset_path,
          btrim(p_branding.from_name),
          lower(btrim(p_branding.from_email)),
          lower(btrim(p_branding.reply_to_email)),
          lower(btrim(p_branding.contact_email)),
          btrim(p_branding.club_address_line),
          p_branding.club_postal_code,
          btrim(p_branding.club_city),
          btrim(p_branding.pickup_name),
          btrim(p_branding.pickup_address_line),
          p_branding.pickup_postal_code,
          btrim(p_branding.pickup_city),
          p_branding.privacy_url,
          p_branding.primary_color,
          p_branding.secondary_color,
          p_branding.accent_color,
          btrim(p_branding.footer_text),
          p_branding.contrast_validated::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function private.mail_template_content_hash(
  text, text, text, text, jsonb, text, text
) from public, anon, authenticated, service_role;
revoke all on function private.mail_branding_content_hash(
  app.mail_branding_revisions
) from public, anon, authenticated, service_role;

with seed_templates(
  template_key,
  subject_source,
  preheader_source,
  intro_text,
  intro_shortcode
) as (
  values
    ('portal_access_invite', 'Toegang tot het tenueportaal van {{club_name}}', 'Uw portaaltoegang is geactiveerd.', 'Uw toegang tot het tenueportaal is geactiveerd. Vraag op de inlogpagina zelf een verificatiecode aan.', null),
    ('portal_access_reminder', 'Herinnering: toegang tot het tenueportaal', 'Uw portaaltoegang staat klaar.', 'Uw toegang staat nog voor u klaar. Vraag op de inlogpagina zelf een verificatiecode aan.', null),
    ('login_otp', 'Uw verificatiecode voor {{club_name}}', 'Gebruik de code binnen {{otp_expiry_minutes}} minuten.', 'Gebruik onderstaande verificatiecode om veilig in te loggen.', null),
    ('size_fill_request', 'Vul de maten in voor {{member_first_name}}', 'De pakketmaten zijn nog niet compleet.', 'Vul de ontbrekende pakketmaten in voor ', 'member_first_name'),
    ('size_fill_reminder', 'Herinnering: maten invullen voor {{member_first_name}}', 'De pakketmaten zijn nog niet compleet.', 'Vul de ontbrekende pakketmaten in voor ', 'member_first_name'),
    ('size_review_request', 'Controleer de maten voor {{member_first_name}}', 'De geïmporteerde maten wachten op uw bevestiging.', 'Controleer de voorgeselecteerde pakketmaten voor ', 'member_first_name'),
    ('size_review_reminder', 'Herinnering: maten controleren voor {{member_first_name}}', 'De geïmporteerde maten wachten nog op uw bevestiging.', 'Controleer de voorgeselecteerde pakketmaten voor ', 'member_first_name'),
    ('size_confirmed', 'Maten bevestigd voor {{member_first_name}}', 'De pakketmaten zijn veilig vastgelegd.', 'De pakketmaten zijn bevestigd voor ', 'member_first_name'),
    ('payment_request', 'Betaalverzoek voor {{member_first_name}}', 'Betaal veilig het vaste pakketbedrag.', 'Het pakket voor onderstaande speler kan veilig worden betaald.', null),
    ('payment_reminder', 'Herinnering: betaling voor {{member_first_name}}', 'Het vaste pakketbedrag staat nog open.', 'Het pakketbedrag staat nog open.', null),
    ('payment_received_waiting_stock', 'Betaling ontvangen voor {{member_first_name}}', 'Bedankt; we wachten nog op voorraad.', 'Bedankt voor de betaling. Zodra concrete pakketregels zijn gereserveerd volgt een afhaalbericht.', null),
    ('available_payment_required', 'Voorraad beschikbaar; betaling nog nodig', 'Beschikbaarheid is geen reserveringsgarantie.', 'Er is op dit moment voorraad beschikbaar, maar die is pas na betaling en harde reservering gegarandeerd.', null),
    ('pickup_ready', 'Pakketregels afhalen voor {{member_first_name}}', 'Neem de actieve QR in het portaal mee.', 'De onderstaande pakketregels zijn afhaalklaar.', null),
    ('pickup_reminder', 'Herinnering: pakketregels afhalen', 'De gereserveerde pakketregels liggen nog klaar.', 'De onderstaande pakketregels liggen nog voor u klaar.', null),
    ('out_of_stock', 'Pakketregel tijdelijk niet leverbaar', 'We informeren u zodra reservering weer mogelijk is.', 'Een of meer betaalde pakketregels zijn tijdelijk niet leverbaar.', null),
    ('back_in_stock', 'Pakketregel weer beschikbaar', 'Bekijk de actuele afhaalstatus in het portaal.', 'Een of meer pakketregels zijn weer beschikbaar en gereserveerd.', null),
    ('partial_pickup', 'Deel van pakket afgehaald voor {{member_first_name}}', 'Bekijk wat nu is afgehaald en wat nog volgt.', 'Een deel van het pakket is afgehaald voor ', 'member_first_name'),
    ('package_complete', 'Pakket compleet voor {{member_first_name}}', 'Alle pakketregels zijn afgehaald.', 'Het volledige pakket is afgehaald voor ', 'member_first_name'),
    ('internal_email_failure', 'Definitieve e-mailfout', 'Een mailjob vereist beheeractie.', 'Een e-mailproces vereist beheeractie.', null)
)
insert into app.mail_template_revisions(
  template_key,
  revision,
  status,
  internal_name,
  subject_source,
  preheader_source,
  body_tiptap,
  sanitized_html_source,
  text_fallback_source,
  content_hash,
  creation_source
)
select
  template.template_key,
  1,
  'draft',
  template.internal_name,
  seed.subject_source,
  seed.preheader_source,
  document.body,
  null,
  seed.intro_text || coalesce(
    E'\n' || (
      select string_agg('[' || node || ']', E'\n' order by position)
      from unnest(template.required_protected_nodes)
        with ordinality required_node(node, position)
    ),
    ''
  ),
  private.mail_template_content_hash(
    template.template_key,
    template.internal_name,
    seed.subject_source,
    seed.preheader_source,
    document.body,
    null,
    seed.intro_text || coalesce(
      E'\n' || (
        select string_agg('[' || node || ']', E'\n' order by position)
        from unnest(template.required_protected_nodes)
          with ordinality required_node(node, position)
      ),
      ''
    )
  ),
  'system'
from seed_templates seed
join app.mail_templates template
  on template.template_key = seed.template_key
cross join lateral (
  select jsonb_build_object(
    'type', 'doc',
    'content',
    jsonb_build_array(
      jsonb_build_object(
        'type', 'paragraph',
        'content',
        jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', seed.intro_text)
        ) || case
          when seed.intro_shortcode is null then '[]'::jsonb
          else jsonb_build_array(
            jsonb_build_object(
              'type', 'shortcode',
              'attrs', jsonb_build_object('key', seed.intro_shortcode)
            )
          )
        end
      )
    ) || coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'type', 'protectedBlock',
          'attrs', jsonb_build_object('kind', node)
        )
        order by position
      )
      from unnest(template.required_protected_nodes)
        with ordinality required_node(node, position)
    ), '[]'::jsonb)
  ) body
) document;

insert into app.mail_branding_revisions(
  revision,
  status,
  club_name,
  logo_asset_path,
  from_name,
  from_email,
  reply_to_email,
  contact_email,
  club_address_line,
  club_postal_code,
  club_city,
  pickup_name,
  pickup_address_line,
  pickup_postal_code,
  pickup_city,
  privacy_url,
  primary_color,
  secondary_color,
  accent_color,
  footer_text,
  contrast_validated,
  content_hash,
  creation_source,
  published_at
)
select
  1,
  'published',
  'Duindorp SV',
  '/duindorp-sv-logo.png',
  'Kledingcommissie Duindorp SV',
  'kleding@duindorpsv.nl',
  'kleding@duindorpsv.nl',
  'kleding@duindorpsv.nl',
  'Houtrustlaan 1',
  '2566 ZW',
  'Den Haag',
  'Free-Kick Sport',
  'De Savornin Lohmanplein 45',
  '2566 AE',
  'Den Haag',
  'https://duindorpsv.nl/privacy',
  '#17418B',
  '#0B2E63',
  '#2E69CC',
  'Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy',
  true,
  encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          'Duindorp SV',
          '/duindorp-sv-logo.png',
          'Kledingcommissie Duindorp SV',
          'kleding@duindorpsv.nl',
          'kleding@duindorpsv.nl',
          'kleding@duindorpsv.nl',
          'Houtrustlaan 1',
          '2566 ZW',
          'Den Haag',
          'Free-Kick Sport',
          'De Savornin Lohmanplein 45',
          '2566 AE',
          'Den Haag',
          'https://duindorpsv.nl/privacy',
          '#17418B',
          '#0B2E63',
          '#2E69CC',
          'Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy',
          'true'
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  ),
  'system',
  timezone('utc', now());

create or replace function private.guard_mail_template_revision()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_TEMPLATE_REVISION_IMMUTABLE' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.template_key is distinct from old.template_key
      or new.revision is distinct from old.revision
      or new.created_by is distinct from old.created_by
      or new.creation_source is distinct from old.creation_source
      or new.created_at is distinct from old.created_at
    then
      raise exception 'MAIL_TEMPLATE_REVISION_IDENTITY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if old.status = 'draft' and new.status = 'draft' then
      if new.published_by is not null
        or new.published_at is not null
        or new.archived_by is not null
        or new.archived_at is not null
      then
        raise exception 'MAIL_TEMPLATE_REVISION_STATE_INVALID'
          using errcode = '23514';
      end if;
      return new;
    end if;
    if old.status = 'draft' and new.status = 'published' then
      if new.internal_name is distinct from old.internal_name
        or new.subject_source is distinct from old.subject_source
        or new.preheader_source is distinct from old.preheader_source
        or new.body_tiptap is distinct from old.body_tiptap
        or new.sanitized_html_source is distinct from old.sanitized_html_source
        or new.text_fallback_source is distinct from old.text_fallback_source
        or new.schema_version is distinct from old.schema_version
        or new.content_hash is distinct from old.content_hash
      then
        raise exception 'MAIL_TEMPLATE_PUBLISH_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    if old.status = 'published' and new.status = 'archived' then
      if new.internal_name is distinct from old.internal_name
        or new.subject_source is distinct from old.subject_source
        or new.preheader_source is distinct from old.preheader_source
        or new.body_tiptap is distinct from old.body_tiptap
        or new.sanitized_html_source is distinct from old.sanitized_html_source
        or new.text_fallback_source is distinct from old.text_fallback_source
        or new.schema_version is distinct from old.schema_version
        or new.content_hash is distinct from old.content_hash
        or new.published_by is distinct from old.published_by
        or new.published_at is distinct from old.published_at
      then
        raise exception 'MAIL_TEMPLATE_ARCHIVE_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    raise exception 'MAIL_TEMPLATE_REVISION_TRANSITION_INVALID'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create or replace function private.guard_mail_branding_revision()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_BRANDING_REVISION_IMMUTABLE' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.revision is distinct from old.revision
      or new.created_by is distinct from old.created_by
      or new.creation_source is distinct from old.creation_source
      or new.created_at is distinct from old.created_at
    then
      raise exception 'MAIL_BRANDING_REVISION_IDENTITY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if old.status = 'draft' and new.status = 'draft' then
      return new;
    end if;
    if old.status = 'draft' and new.status = 'published' then
      if row(
        new.club_name,
        new.logo_asset_path,
        new.from_name,
        new.from_email,
        new.reply_to_email,
        new.contact_email,
        new.club_address_line,
        new.club_postal_code,
        new.club_city,
        new.pickup_name,
        new.pickup_address_line,
        new.pickup_postal_code,
        new.pickup_city,
        new.privacy_url,
        new.primary_color,
        new.secondary_color,
        new.accent_color,
        new.footer_text,
        new.contrast_validated,
        new.content_hash
      ) is distinct from row(
        old.club_name,
        old.logo_asset_path,
        old.from_name,
        old.from_email,
        old.reply_to_email,
        old.contact_email,
        old.club_address_line,
        old.club_postal_code,
        old.club_city,
        old.pickup_name,
        old.pickup_address_line,
        old.pickup_postal_code,
        old.pickup_city,
        old.privacy_url,
        old.primary_color,
        old.secondary_color,
        old.accent_color,
        old.footer_text,
        old.contrast_validated,
        old.content_hash
      ) then
        raise exception 'MAIL_BRANDING_PUBLISH_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    if old.status = 'published' and new.status = 'archived' then
      if row(
        new.club_name,
        new.logo_asset_path,
        new.from_name,
        new.from_email,
        new.reply_to_email,
        new.contact_email,
        new.club_address_line,
        new.club_postal_code,
        new.club_city,
        new.pickup_name,
        new.pickup_address_line,
        new.pickup_postal_code,
        new.pickup_city,
        new.privacy_url,
        new.primary_color,
        new.secondary_color,
        new.accent_color,
        new.footer_text,
        new.contrast_validated,
        new.content_hash,
        new.published_by,
        new.published_at
      ) is distinct from row(
        old.club_name,
        old.logo_asset_path,
        old.from_name,
        old.from_email,
        old.reply_to_email,
        old.contact_email,
        old.club_address_line,
        old.club_postal_code,
        old.club_city,
        old.pickup_name,
        old.pickup_address_line,
        old.pickup_postal_code,
        old.pickup_city,
        old.privacy_url,
        old.primary_color,
        old.secondary_color,
        old.accent_color,
        old.footer_text,
        old.contrast_validated,
        old.content_hash,
        old.published_by,
        old.published_at
      ) then
        raise exception 'MAIL_BRANDING_ARCHIVE_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    raise exception 'MAIL_BRANDING_REVISION_TRANSITION_INVALID'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger mail_template_revisions_guard
before update or delete on app.mail_template_revisions
for each row execute function private.guard_mail_template_revision();

create trigger mail_branding_revisions_guard
before update or delete on app.mail_branding_revisions
for each row execute function private.guard_mail_branding_revision();

revoke all on function private.guard_mail_template_revision()
from public, anon, authenticated, service_role;
revoke all on function private.guard_mail_branding_revision()
from public, anon, authenticated, service_role;

alter table app.mail_shortcode_definitions enable row level security;
alter table app.mail_protected_node_definitions enable row level security;
alter table app.mail_templates enable row level security;
alter table app.mail_template_revisions enable row level security;
alter table app.mail_branding_revisions enable row level security;

create policy "administrators can read mail shortcode definitions"
on app.mail_shortcode_definitions for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);
create policy "administrators can read mail protected node definitions"
on app.mail_protected_node_definitions for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);
create policy "administrators can read mail templates"
on app.mail_templates for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);
create policy "administrators can read mail template revisions"
on app.mail_template_revisions for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);
create policy "administrators can read mail branding revisions"
on app.mail_branding_revisions for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);

revoke all on table
  app.mail_shortcode_definitions,
  app.mail_protected_node_definitions,
  app.mail_templates,
  app.mail_template_revisions,
  app.mail_branding_revisions
from public, anon, authenticated, service_role;
grant select on table
  app.mail_shortcode_definitions,
  app.mail_protected_node_definitions,
  app.mail_templates,
  app.mail_template_revisions,
  app.mail_branding_revisions
to authenticated;

update app.app_settings
set contact_email = coalesce(contact_email, 'kleding@duindorpsv.nl'),
    club_address_line = coalesce(club_address_line, 'Houtrustlaan 1'),
    club_postal_code = coalesce(club_postal_code, '2566 ZW'),
    club_city = coalesce(club_city, 'Den Haag'),
    pickup_address_differs = case
      when pickup_name is null
        and pickup_address_line is null
        and pickup_postal_code is null
        and pickup_city is null
      then true
      else pickup_address_differs
    end,
    pickup_name = coalesce(pickup_name, 'Free-Kick Sport'),
    pickup_address_line = coalesce(
      pickup_address_line,
      'De Savornin Lohmanplein 45'
    ),
    pickup_postal_code = coalesce(pickup_postal_code, '2566 AE'),
    pickup_city = coalesce(pickup_city, 'Den Haag'),
    pickup_location = coalesce(
      pickup_location,
      'Free-Kick Sport, De Savornin Lohmanplein 45, 2566 AE Den Haag'
    ),
    updated_at = timezone('utc', now())
where id = true;

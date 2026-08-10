begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  ('e6600000-0000-4000-8000-000000000001', 'Mailbeheerder', 'beheerder'),
  ('e6600000-0000-4000-8000-000000000002', 'Mailcommissie', 'kledingcommissie'),
  ('e6600000-0000-4000-8000-000000000003', 'Mailuitgifte', 'uitgifte');

select is(
  (select count(*) from app.email_templates),
  7::bigint,
  'de rollbackcompatibele legacycatalogus blijft exact zeven templates'
);
select is(
  (select count(*) from app.mail_templates),
  19::bigint,
  'mail-v2 bevat de volledige goedgekeurde catalogus'
);
select is(
  (select count(*) from app.mail_templates
    where template_key = 'payment_hold_expired'),
  0::bigint,
  'de afgewezen tijdelijke-holdmail bestaat niet'
);
select is(
  (select count(*) from app.mail_template_revisions
    where status = 'draft'),
  19::bigint,
  'ieder catalogusitem start met één veilige conceptrevisie'
);
select is(
  (select count(*) from app.mail_template_revisions
    where status = 'published'),
  0::bigint,
  'geen externe template wordt door de migratie stil gepubliceerd'
);
select is(
  (select count(*) from app.mail_branding_revisions
    where status = 'published'
      and club_name = 'Duindorp SV'
      and logo_asset_path = '/duindorp-sv-logo.png'
      and from_name = 'Kledingcommissie Duindorp SV'
      and from_email = 'kleding@duindorpsv.nl'
      and reply_to_email = 'kleding@duindorpsv.nl'
      and pickup_name = 'Free-Kick Sport'
      and privacy_url = 'https://duindorpsv.nl/privacy'),
  1::bigint,
  'de expliciet goedgekeurde vaste branding is initieel gepubliceerd'
);
select ok(
  not has_table_privilege(
    'service_role',
    'app.mail_template_revisions',
    'SELECT,INSERT,UPDATE,DELETE'
  ),
  'service role heeft geen brede directe templateprivileges'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'app.mail_template_revisions',
    'INSERT,UPDATE,DELETE'
  ),
  'browserrollen kunnen revisies niet rechtstreeks muteren'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e6600000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_workspace_v1()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder op AAL1 kan mailconfiguratie niet lezen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e6600000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_workspace_v1()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan mailtemplates en branding niet beheren'
);
select is(
  (select count(*) from app.mail_template_revisions),
  0::bigint,
  'RLS verbergt revisies voor de kledingcommissie'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e6600000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_workspace_v1()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'uitgifte kan mailconfiguratie niet lezen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e6600000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;

select is(
  jsonb_array_length(app.get_mail_workspace_v1()->'templates'),
  19,
  'beheerder ziet de volledige v2-catalogus'
);
select is(
  app.get_mail_workspace_v1()->>'featureEnabled',
  'false',
  'mail-v2 blijft standaard uitgeschakeld'
);
select is(
  app.get_mail_workspace_v1()#>>'{branding,published,clubName}',
  'Duindorp SV',
  'brandingworkspace gebruikt het getypeerde camelCase-contract'
);
select ok(
  not (app.get_mail_workspace_v1()#>'{branding,published}' ? 'club_name'),
  'brandingworkspace lekt geen intern snake_case-contract'
);
select ok(
  (app.get_mail_workspace_v1()::text !~* 'date_of_birth|geboortedatum'),
  'mailwerkruimte bevat geen DOB'
);

create temporary table partial_draft as
select id, content_hash
from app.mail_template_revisions
where template_key = 'partial_pickup'
  and status = 'draft';
grant select on partial_draft to authenticated;

select throws_ok(
  format(
    $sql$select app.save_mail_template_draft_v1(
      'partial_pickup',
      %L,
      'Deelafhaling',
      'Deel afgehaald voor {{member_first_name}}',
      'Bekijk de deelafhaling.',
      '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hallo "},{"type":"shortcode","attrs":{"key":"member_first_name"}}]},{"type":"image","attrs":{"src":"x"}}]}'::jsonb,
      '<p>Voorbeeld</p>',
      'Deelafhaling',
      null
    )$sql$,
    (select content_hash from partial_draft)
  ),
  '22023',
  'MAIL_TEMPLATE_DRAFT_INVALID',
  'een onbekende TipTap-node wordt geweigerd'
);

select throws_ok(
  format(
    $sql$select app.save_mail_template_draft_v1(
      'partial_pickup',
      %L,
      'Deelafhaling',
      'Deel afgehaald voor {{member_first_name}}',
      'Bekijk de deelafhaling.',
      '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hallo"}]},{"type":"protectedBlock","attrs":{"kind":"picked_up_items"}},{"type":"protectedBlock","attrs":{"kind":"remaining_items"}}]}'::jsonb,
      '<p onclick="alert(1)">Onveilig</p>',
      'Deelafhaling',
      null
    )$sql$,
    (select content_hash from partial_draft)
  ),
  '22023',
  'MAIL_TEMPLATE_DRAFT_INVALID',
  'eventhandlers in aangeleverde HTML worden geweigerd'
);

create temporary table saved_partial as
select app.save_mail_template_draft_v1(
  'partial_pickup',
  (select content_hash from partial_draft),
  'Deelafhaling',
  'Deel afgehaald voor {{member_first_name}}',
  'Bekijk wat nu is afgehaald en wat nog volgt.',
  '{
    "type":"doc",
    "content":[
      {
        "type":"paragraph",
        "content":[
          {"type":"text","text":"Beste "},
          {"type":"shortcode","attrs":{"key":"member_first_name"}}
        ]
      },
      {"type":"protectedBlock","attrs":{"kind":"picked_up_items"}},
      {"type":"protectedBlock","attrs":{"kind":"remaining_items"}}
    ]
  }'::jsonb,
  '<p>Beste Sophie</p><table><tbody><tr><td>Shirt</td></tr></tbody></table>',
  'Beste {{member_first_name}}, bekijk de afgehaalde en resterende regels.',
  'e66f0000-0000-4000-8000-000000000001'
) result;
grant select on saved_partial to authenticated;

select matches(
  (select result->>'contentHash' from saved_partial),
  '^[0-9a-f]{64}$',
  'een veilig concept krijgt een deterministische contenthash'
);
select throws_ok(
  $$select app.publish_mail_template_revision_v1(
    (select id from partial_draft),
    repeat('0', 64),
    null
  )$$,
  '40001',
  'MAIL_TEMPLATE_PUBLISH_STALE',
  'publiceren met een verouderde hash faalt'
);

create temporary table published_partial as
select app.publish_mail_template_revision_v1(
  (select id from partial_draft),
  (select result->>'contentHash' from saved_partial),
  'e66f0000-0000-4000-8000-000000000002'
) result;
grant select on published_partial to authenticated;

select is(
  (select result->>'status' from published_partial),
  'published',
  'een volledig beschermd concept wordt gepubliceerd'
);
select is(
  (select count(*) from app.mail_template_revisions
    where template_key = 'partial_pickup'
      and status = 'published'),
  1::bigint,
  'per template bestaat maximaal één gepubliceerde revisie'
);
select throws_ok(
  format(
    $$update app.mail_template_revisions
      set subject_source = 'Stille browserwijziging'
      where id = %L::uuid$$,
    (select id from partial_draft)
  ),
  '42501',
  'permission denied for table mail_template_revisions',
  'browserrollen kunnen gepubliceerde revisies niet rechtstreeks wijzigen'
);
reset role;
select throws_ok(
  format(
    $$update app.mail_template_revisions
      set subject_source = 'Stille wijziging',
          content_hash = %L
      where id = %L::uuid$$,
    repeat('0', 64),
    (select id from partial_draft)
  ),
  '23514',
  'MAIL_TEMPLATE_CONTENT_HASH_INVALID',
  'een gepubliceerde revisie kan niet stil worden herschreven'
);
set local role authenticated;

create temporary table incomplete_package as
select app.save_mail_template_draft_v1(
  'package_complete',
  (select content_hash
    from app.mail_template_revisions
    where template_key = 'package_complete'
      and status = 'draft'),
  'Pakket compleet',
  'Pakket compleet voor {{member_first_name}}',
  'Alle regels zijn afgehaald.',
  '{
    "type":"doc",
    "content":[
      {"type":"paragraph","content":[{"type":"text","text":"Het pakket is compleet."}]}
    ]
  }'::jsonb,
  '<p>Het pakket is compleet.</p>',
  'Het pakket is compleet.',
  null
) result;
grant select on incomplete_package to authenticated;
select throws_ok(
  $$select app.publish_mail_template_revision_v1(
    (select (result->>'revisionId')::uuid from incomplete_package),
    (select result->>'contentHash' from incomplete_package),
    null
  )$$,
  '23514',
  'MAIL_TEMPLATE_NOT_PUBLISHABLE',
  'ontbrekende beschermde pakketnode blokkeert publicatie'
);

create temporary table branding_draft as
select app.save_mail_branding_draft_v1(
  null,
  '{
    "clubName":"Duindorp SV",
    "logoAssetPath":"/duindorp-sv-logo.png",
    "fromName":"Kledingcommissie Duindorp SV",
    "fromEmail":"kleding@duindorpsv.nl",
    "replyToEmail":"kleding@duindorpsv.nl",
    "contactEmail":"kleding@duindorpsv.nl",
    "clubAddressLine":"Houtrustlaan 1",
    "clubPostalCode":"2566 ZW",
    "clubCity":"Den Haag",
    "pickupName":"Free-Kick Sport",
    "pickupAddressLine":"De Savornin Lohmanplein 45",
    "pickupPostalCode":"2566 AE",
    "pickupCity":"Den Haag",
    "privacyUrl":"https://duindorpsv.nl/privacy",
    "primaryColor":"#17418B",
    "secondaryColor":"#0B2E63",
    "accentColor":"#2E69CC",
    "footerText":"Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy",
    "contrastValidated":true
  }'::jsonb,
  'e66f0000-0000-4000-8000-000000000003'
) result;
grant select on branding_draft to authenticated;

select matches(
  (select result->>'contentHash' from branding_draft),
  '^[0-9a-f]{64}$',
  'brandingdraft krijgt een contenthash'
);
select lives_ok(
  $$select app.publish_mail_branding_revision_v1(
    (select (result->>'revisionId')::uuid from branding_draft),
    (select result->>'contentHash' from branding_draft),
    'e66f0000-0000-4000-8000-000000000004'
  )$$,
  'gevalideerde branding kan atomair worden gepubliceerd'
);
select is(
  (select count(*) from app.mail_branding_revisions
    where status = 'published'),
  1::bigint,
  'brandingpublicatie archiveert de vorige revisie'
);
select is(
  (select count(*) from app.audit_logs
    where action in (
      'mail_template.draft_saved',
      'mail_template.published',
      'mail_branding.draft_saved',
      'mail_branding.published'
    )
      and metadata::text !~* 'sophie|kleding@|subject|html|body'),
  5::bigint,
  'mailaudits bevatten alleen hashes en veilige revisiemetadata'
);

select * from finish();
rollback;
reset role;

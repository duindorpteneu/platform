begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into app.staff_profiles(auth_user_id, display_name, role) values
  (
    'e7000000-0000-4000-8000-000000000001',
    'Mailcutover beheerder',
    'beheerder'
  ),
  (
    'e7000000-0000-4000-8000-000000000002',
    'Mailcutover commissie',
    'kledingcommissie'
  );

select throws_ok(
  $$update app.release_feature_flags
    set enabled = true
    where key = 'mail_templates_v2'$$,
  '55000',
  'RELEASE_CUTOVER_GATE_REQUIRED',
  'de databaseflag kan vóór de expliciete mailgate niet direct aan'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e7000000-0000-4000-8000-000000000002","aal":"aal2"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_v2_cutover_snapshot()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'kledingcommissie kan de mailcutover niet bedienen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e7000000-0000-4000-8000-000000000001","aal":"aal1"}',
  true
);
set local role authenticated;
select throws_ok(
  $$select app.get_mail_v2_cutover_snapshot()$$,
  '42501',
  'STAFF_AUTHORIZATION_REQUIRED',
  'beheerder zonder AAL2 kan de mailcutover niet bedienen'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"e7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table initial_mail_cutover as
select app.get_mail_v2_cutover_snapshot() result;
select is(
  (select result->>'ready' from initial_mail_cutover),
  'false',
  'mail-v2 is niet gereed zolang concepten niet zijn gepubliceerd'
);
select is(
  (select result->>'publishedCount' from initial_mail_cutover),
  '0',
  'de migratie publiceert geen externe templates stil'
);
select is(
  (select result->>'producerCount' from initial_mail_cutover),
  '2',
  'alleen de twee werkelijk geïmplementeerde fulfilmentproducenten zijn geregistreerd'
);
select throws_ok(
  $$select app.pause_mail_templates_v2(
    'Nog niet geactiveerde keten',
    null
  )$$,
  '55000',
  'MAIL_V2_CUTOVER_NOT_ACTIVATED',
  'pauzeren vóór de eerste activatie faalt gesloten'
);
select throws_ok(
  format(
    $sql$select app.activate_mail_templates_v2(
      %L,
      'Gate mag nog niet slagen',
      null
    )$sql$,
    (select result->>'revision' from initial_mail_cutover)
  ),
  '23514',
  'MAIL_V2_CUTOVER_RECONCILIATION_REQUIRED',
  'activatie faalt gesloten vóór de volledige catalogus gereed is'
);

do $$
declare
  draft app.mail_template_revisions%rowtype;
  saved jsonb;
begin
  for draft in
    select revision.*
    from app.mail_template_revisions revision
    where revision.status = 'draft'
    order by revision.template_key
  loop
    saved := app.save_mail_template_draft_v1(
      draft.template_key,
      draft.content_hash,
      draft.internal_name,
      draft.subject_source,
      draft.preheader_source,
      draft.body_tiptap,
      '<p>Veilig server-side gerenderd concept</p>',
      draft.text_fallback_source,
      null
    );
    perform app.publish_mail_template_revision_v1(
      draft.id,
      saved->>'contentHash',
      null
    );
  end loop;
end;
$$;

create temporary table ready_mail_cutover as
select app.get_mail_v2_cutover_snapshot() result;
select is(
  (select result->>'catalogCount' from ready_mail_cutover),
  '19',
  'cutover telt exact de goedgekeurde catalogus'
);
select is(
  (select result->>'publishedCount' from ready_mail_cutover),
  '19',
  'alle 19 processen hebben exact één gepubliceerde revisie'
);
select is(
  (select result->>'brandingCount' from ready_mail_cutover),
  '1',
  'exact één contrastgevalideerde branding is gepubliceerd'
);
select is(
  (select result->>'producerCount' from ready_mail_cutover),
  '2',
  'publiceren registreert niet stil ontbrekende producenten'
);
select is(
  (select result->>'ready' from ready_mail_cutover),
  'false',
  'templates en branding zonder producentdekking houden de gate dicht'
);
select throws_ok(
  format(
    $sql$select app.activate_mail_templates_v2(
      %L,
      'Producentdekking ontbreekt nog',
      null
    )$sql$,
    (select result->>'revision' from ready_mail_cutover)
  ),
  '23514',
  'MAIL_V2_CUTOVER_RECONCILIATION_REQUIRED',
  'activatie faalt gesloten zolang niet alle producenten geregistreerd zijn'
);
reset role;

insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
)
select template.template_key, 1
from app.mail_templates template
where template.active
on conflict (template_key) do nothing;

select set_config(
  'request.jwt.claims',
  '{"sub":"e7000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
create temporary table producer_ready_mail_cutover as
select app.get_mail_v2_cutover_snapshot() result;
select is(
  (select result->>'producerCount' from producer_ready_mail_cutover),
  '19',
  'forward-only producentregistraties dekken exact de catalogus'
);
select is(
  (select result->>'ready' from producer_ready_mail_cutover),
  'true',
  'catalogus, producenten en branding maken de databasegate gereed'
);
select throws_ok(
  $$select app.activate_mail_templates_v2(
    repeat('0', 64),
    'Stale activatie hoort te falen',
    null
  )$$,
  '40001',
  'MAIL_V2_CUTOVER_STALE',
  'optimistic cutoverrevision blokkeert een verouderde preflight'
);

create temporary table activated_mail_cutover as
select app.activate_mail_templates_v2(
  (select result->>'revision' from producer_ready_mail_cutover),
  'Volledige catalogus gecontroleerd voor lokale acceptatie',
  'e7000000-0000-4000-8000-000000000010'
) result;
select is(
  (select result->>'enabled' from activated_mail_cutover),
  'true',
  'beheerder met AAL2 activeert mail-v2 na de groene gate'
);
select ok(
  (
    select result->>'cutoverAt' is not null
    from activated_mail_cutover
  ),
  'activatie legt een immutable cutoverwatermerk vast'
);
select is(
  (select result->>'reused' from activated_mail_cutover),
  'false',
  'eerste activatie is geen idempotent hergebruik'
);

create temporary table repeated_activation as
select app.activate_mail_templates_v2(
  (select result->>'revision' from producer_ready_mail_cutover),
  'Idempotente herhaling van dezelfde activatie',
  null
) result;
select is(
  (select result->>'reused' from repeated_activation),
  'true',
  'herhaalde activatie is idempotent'
);

create temporary table paused_mail_cutover as
select app.pause_mail_templates_v2(
  'Tijdelijke operationele pauze voor incidentcontrole',
  'e7000000-0000-4000-8000-000000000011'
) result;
select is(
  (select result->>'enabled' from paused_mail_cutover),
  'false',
  'beheerder kan projectie gecontroleerd pauzeren'
);
select is(
  (select result->>'cutoverAt' from paused_mail_cutover),
  (select result->>'cutoverAt' from activated_mail_cutover),
  'pauze wist of verschuift het cutoverwatermerk niet'
);
select is(
  (select result->>'reused' from paused_mail_cutover),
  'false',
  'de eerste pauze legt een echte toestandsovergang vast'
);

create temporary table repeated_pause as
select app.pause_mail_templates_v2(
  'Herhaalde operationele pauze',
  null
) result;
select is(
  (select result->>'reused' from repeated_pause),
  'true',
  'een herhaalde pauze is idempotent en schrijft geen tweede audit'
);
reset role;

select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'release.mail_templates_v2.activated'
  ),
  1::bigint,
  'de eerste activatie wordt exact één keer geaudit'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'release.mail_templates_v2.paused'
  ),
  1::bigint,
  'operationele pauze wordt exact één keer geaudit'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where action like 'release.mail_templates_v2.%'
      and metadata ? 'reason'
  ),
  'vrije cutoverredenen worden uitsluitend als digest en lengte geaudit'
);
select ok(
  not exists(
    select 1
    from app.audit_logs
    where action like 'release.mail_templates_v2.%'
      and metadata::text ~*
        'subject|body|recipient|email|sophie|date_of_birth'
  ),
  'cutoveraudit bevat geen template-inhoud of PII'
);

select * from finish();
rollback;
reset role;

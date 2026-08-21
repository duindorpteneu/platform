-- Canonical login_otp remains one template and gains a required protected
-- direct-login action. Credentials are injected only during server rendering.

insert into app.mail_protected_node_definitions(key, description)
values(
  'otp_direct_login',
  'Challengegebonden eenmalige directe inlogactie'
)
on conflict (key) do nothing;

update app.mail_templates template
set allowed_protected_nodes = array[
      'otp_code', 'otp_direct_login', 'otp_validity', 'otp_warning'
    ]::text[],
    required_protected_nodes = array[
      'otp_code', 'otp_direct_login', 'otp_validity', 'otp_warning'
    ]::text[]
where template.template_key = 'login_otp';

do $$
declare
  draft app.mail_template_revisions%rowtype;
  base app.mail_template_revisions%rowtype;
  canonical_body jsonb := jsonb_build_object(
    'type', 'doc',
    'content', jsonb_build_array(
      jsonb_build_object(
        'type', 'paragraph',
        'content', jsonb_build_array(jsonb_build_object(
          'type', 'text',
          'text', 'Gebruik onderstaande verificatiecode om veilig in te loggen.'
        ))
      ),
      jsonb_build_object(
        'type', 'protectedBlock',
        'attrs', jsonb_build_object('kind', 'otp_code')
      ),
      jsonb_build_object(
        'type', 'paragraph',
        'content', jsonb_build_array(jsonb_build_object(
          'type', 'text',
          'text', 'Gebruik je liever geen code? Kies dan Direct inloggen.'
        ))
      ),
      jsonb_build_object(
        'type', 'protectedBlock',
        'attrs', jsonb_build_object('kind', 'otp_direct_login')
      ),
      jsonb_build_object(
        'type', 'protectedBlock',
        'attrs', jsonb_build_object('kind', 'otp_validity')
      ),
      jsonb_build_object(
        'type', 'paragraph',
        'content', jsonb_build_array(jsonb_build_object(
          'type', 'text',
          'text', 'Vraag je de e-mail opnieuw aan? Zolang de code geldig is ontvang je dezelfde code opnieuw.'
        ))
      ),
      jsonb_build_object(
        'type', 'protectedBlock',
        'attrs', jsonb_build_object('kind', 'otp_warning')
      )
    )
  );
  canonical_html text := '<p>Gebruik de verificatiecode of de beveiligde directe inlogactie. Beide verlopen tegelijk en zijn eenmalig bruikbaar.</p>';
  canonical_text text := 'Gebruik de verificatiecode of kies Direct inloggen. Beide verlopen tegelijk. Vraag je de e-mail opnieuw aan terwijl de code geldig is, dan ontvang je dezelfde code opnieuw.';
  next_revision integer;
begin
  select revision.* into draft
  from app.mail_template_revisions revision
  where revision.template_key = 'login_otp'
    and revision.status = 'draft'
  for update;
  if draft.id is null then
    select revision.* into base
    from app.mail_template_revisions revision
    where revision.template_key = 'login_otp'
    order by revision.revision desc
    limit 1;
    if base.id is null then
      raise exception 'LOGIN_OTP_TEMPLATE_BASE_MISSING'
        using errcode = '23514';
    end if;
    select coalesce(max(revision.revision), 0) + 1 into next_revision
    from app.mail_template_revisions revision
    where revision.template_key = 'login_otp';
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
    ) values (
      'login_otp',
      next_revision,
      'draft',
      base.internal_name,
      base.subject_source,
      'Je code en directe inlogactie zijn tien minuten geldig.',
      canonical_body,
      canonical_html,
      canonical_text,
      private.mail_template_content_hash(
        'login_otp',
        base.internal_name,
        base.subject_source,
        'Je code en directe inlogactie zijn tien minuten geldig.',
        canonical_body,
        canonical_html,
        canonical_text
      ),
      'system'
    ) returning * into draft;
  else
    update app.mail_template_revisions revision
    set preheader_source =
          'Je code en directe inlogactie zijn tien minuten geldig.',
        body_tiptap = canonical_body,
        sanitized_html_source = canonical_html,
        text_fallback_source = canonical_text,
        content_hash = private.mail_template_content_hash(
          revision.template_key,
          revision.internal_name,
          revision.subject_source,
          'Je code en directe inlogactie zijn tien minuten geldig.',
          canonical_body,
          canonical_html,
          canonical_text
        ),
        updated_at = statement_timestamp()
    where revision.id = draft.id
    returning * into draft;
  end if;
  if not private.mail_template_content_is_allowed(
    draft.template_key,
    draft.subject_source,
    draft.preheader_source,
    draft.body_tiptap,
    draft.sanitized_html_source,
    draft.text_fallback_source
  ) then
    raise exception 'LOGIN_OTP_TEMPLATE_V3_INVALID' using errcode = '23514';
  end if;
  update app.mail_template_revisions revision
  set status = 'archived',
      archived_at = statement_timestamp(),
      archived_by = case
        when revision.creation_source = 'staff'
          then coalesce(revision.published_by, revision.created_by)
        else null
      end,
      updated_at = statement_timestamp()
  where revision.template_key = 'login_otp'
    and revision.status = 'published';
  update app.mail_template_revisions revision
  set status = 'published',
      published_at = statement_timestamp(),
      published_by = case
        when revision.creation_source = 'staff'
          then revision.created_by
        else null
      end,
      updated_at = statement_timestamp()
  where revision.id = draft.id;
end;
$$;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821163000_parent_otp_direct_login_template',
  'passed',
  jsonb_build_object(
    'publishedRevisions', (
      select count(*)
      from app.mail_template_revisions revision
      where revision.template_key = 'login_otp'
        and revision.status = 'published'
    ),
    'requiredDirectLogin', (
      select 'otp_direct_login' = any(template.required_protected_nodes)
      from app.mail_templates template
      where template.template_key = 'login_otp'
    )
  )
)
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = statement_timestamp();

select pg_notify('pgrst', 'reload schema');

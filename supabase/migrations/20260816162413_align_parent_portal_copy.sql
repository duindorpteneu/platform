-- Align untouched system OTP copy without overwriting a template that staff
-- already customised or published through the versioned mail editor.
update app.email_templates
set subject_source = 'Uw verificatiecode voor het tenueportaal van {{clubnaam}}',
    version = version + 1,
    updated_at = timezone('utc', now())
where template_key = 'verification_code'
  and version = 2
  and updated_by is null
  and subject_source = 'Uw verificatiecode voor {{clubnaam}}'
  and body_source = 'Uw verificatiecode is {{verificatiecode}}. Deze code is tien minuten geldig en eenmalig te gebruiken. Deel de code niet. Vragen? {{contact_email}}';

update app.mail_template_revisions revision
set subject_source = 'Uw verificatiecode voor het tenueportaal van {{club_name}}',
    content_hash = private.mail_template_content_hash(
      revision.template_key,
      revision.internal_name,
      'Uw verificatiecode voor het tenueportaal van {{club_name}}',
      revision.preheader_source,
      revision.body_tiptap,
      revision.sanitized_html_source,
      revision.text_fallback_source
    ),
    updated_at = timezone('utc', now())
where revision.template_key = 'login_otp'
  and revision.status = 'draft'
  and revision.creation_source = 'system'
  and revision.subject_source = 'Uw verificatiecode voor {{club_name}}';

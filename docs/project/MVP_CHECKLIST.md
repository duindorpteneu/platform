# MVP checklist

Codex must expand this checklist from the canonical PDF before implementation and keep it traceable to tests.

> Historische v1.0-checklist. De actuele Phase-B-aftekening staat in
> `PROGRESS.md`, `STAGING_VERIFICATION.md` en `RELEASE_CHECKLIST.md`; het
> goedgekeurde addenda v1.1 en v1.2 supersederen conflicterende regels hieronder.

- [x] Three staff roles only
- [x] Sportlink CSV import
- [x] Products, sizes and member order lines
- [x] Exact amount and payment per member
- [x] Handmatige kasregistratie uitsluitend door beheerder+AAL2; legacy pin
      blijft standaard uit achter de expliciete compatibiliteitsflag
- [x] Parent e-mail OTP, six digits, ten minutes
- [ ] No parent password or Supabase Auth account; stable OTP and optional direct-login proof share one ten-minute challenge
- [x] Optional explicit linking of matching members
- [x] One member card and one QR per member/season
- [x] Partial delivery states and item-level fulfilment
- [x] Restricted issuance app
- [x] SendGrid templates and bulk e-mail
- [x] Mollie webhook-first integration with mocked provider contracts
- [ ] Live Mollie test-mode roundtrip on public staging HTTPS
- [x] Exports and audit trail
- [x] Security, RLS and local E2E acceptance gates
- [ ] Live SendGrid delivery, staff invitation and signed event webhook on public staging HTTPS
- [ ] Staging schedulers, alerts and isolated backup/restore drill

# MVP checklist

Codex must expand this checklist from the canonical PDF before implementation and keep it traceable to tests.

- [x] Three staff roles only
- [x] Sportlink CSV import
- [x] Products, sizes and member order lines
- [x] Exact amount and payment per member
- [x] Manual cash/card registration
- [x] Parent e-mail OTP, six digits, ten minutes
- [x] No parent password, magic link or Supabase Auth account
- [x] Optional explicit linking of matching members
- [x] One member card and one QR per member/season
- [x] Partial delivery states and item-level fulfilment
- [x] Restricted issuance app
- [x] SendGrid templates and bulk e-mail
- [x] Mollie webhook-first integration with mocked provider contracts
- [ ] Live Mollie test-mode roundtrip on public staging HTTPS
- [ ] Exports and audit trail
- [ ] Security, RLS and E2E acceptance gates

# Duindorp SV Tenueportaal — Implementation Plan

Status: preflight plan
Baseline: MVP Canon v1.0 (17 July 2026)

## 1. Objective and non-negotiable boundaries

Build one production-oriented Next.js App Router application for Duindorp SV with three protected workspaces:

1. Backoffice for beheerder and kledingcommissie.
2. Mijn Duindorp SV tenue for parents/adult members.
3. Uitgifte for the uitgifte role.

The member, not the household, is the unit of order, exact amount, payment, QR code and fulfilment. The MVP must support partial deliveries without creating a new order or QR code. There are exactly three staff roles: `beheerder`, `kledingcommissie` and `uitgifte`.

The following are explicitly out of scope: combined or partial household payments, webshop/cart functionality, automatic Sportlink synchronisation, multi-club support, native apps, offline fulfilment, returns/exchanges, time slots, accounting integrations, advanced BI and marketing tracking.

## 2. Binding sources

Requirements are interpreted in this order:

1. `docs/canon/Duindorp_SV_Tenueportaal_MVP_Canon_v1.0.pdf`
2. `docs/canon/MVP_CANON_TEXT.txt`
3. `docs/design/APPROVED_MASTER_SHOWCASE.png`
4. `AGENTS.md`
5. The remaining files in `docs/project/`

The PDF and text canon are the functional, technical and visual source of truth. A new feature or deviation requires a documented change request and canon decision before implementation.

## 3. Target architecture

### Application

- Next.js App Router, TypeScript strict mode, React Server Components by default.
- Tailwind CSS, shadcn/ui, Lucide and Motion with reduced-motion support.
- `pnpm`, pinned compatible dependency versions and a committed lockfile.
- Modular monolith; no microservices and no separate frontend applications.
- Server-only domain services for authorization, money, inventory, payments, e-mail, QR and audit.
- Zod validation at every server boundary; database constraints remain the final invariant layer.

### Route groups and surfaces

- `(public)`: `/login`, `/login/code`.
- `(member)`: `/mijn-tenue`, `/mijn-tenue/lid-toevoegen`, `/mijn-tenue/account`, `/betaling/[orderId]`, `/betaling/terug`.
- `(staff)`: `/backoffice` and its operational modules, plus `/uitgifte`.
- Server routes for parent auth, Mollie and SendGrid webhooks, internal e-mail jobs, imports, payments, stock, bulk mail, QR, fulfilment and exports.

### Data and security boundaries

- Supabase Postgres with `app` schema for RLS-protected application data and a private schema for OTPs, session-token hashes, QR-token hashes and sensitive audit details.
- Supabase Auth SSR only for staff; staff access requires active profile, exactly one role and AAL2/TOTP MFA.
- Parents use a custom six-digit OTP and opaque, revocable, hashed session token in a Secure/HttpOnly/SameSite cookie. No parent Supabase Auth account, password or magic link.
- Browser code never writes transactional tables directly. All mutations use server actions or route handlers with fresh authorization and state checks.
- All money is integer eurocents. Database timestamps are UTC and are presented in `Europe/Amsterdam`.
- Secrets remain server-only; no PII, OTP, session token, QR token, provider secret or full webhook payload in logs.

## 4. Build phases

### Phase 0 — Preflight and repository foundation

Deliverables:

- Correctly place the starter canon, project documents and design assets in the repository root; do not create a nested app directory.
- Confirm the repository boundary and inspect local ports without touching sibling projects or processes.
- Scaffold Next.js App Router, TypeScript, Tailwind, shadcn/ui, Motion, Supabase SSR, Zod, Vitest and Playwright using `pnpm`.
- Add `.env.example`, local/staging/production configuration documentation, safe headers baseline, lint/typecheck/test/build scripts and project-specific local ports.
- Add the initial `README.md` and update `PROGRESS.md`, `DECISIONS.md`, `RISKS.md` and `TEST_EVIDENCE.md`.

Gate:

- App starts from the repository root, all three route groups render a protected shell, `pnpm lint`, `pnpm typecheck`, unit test command and production build pass, and no secret is committed.

### Phase 1 — Design system, shells and staff foundation

Deliverables:

- Implement the shared Duindorp SV tokens: Inter, royal blue palette, light surfaces, 12px cards, 4/8px spacing, borders, semantic status colors and focus states.
- Build shared `AppShell`, sidebar, topbar, metric cards, tables, badges, drawers, dialogs, toasts and responsive empty/error/loading/success states.
- Implement Supabase staff SSR session handling, staff profile lookup, role guards, AAL2/MFA enforcement and logout/session revocation.
- Create the audit foundation and server-side authorization helpers.

Gate:

- Staff routes are inaccessible without an active MFA-authenticated profile; negative tests prove role boundaries. The three surfaces look like one design system on desktop, tablet and mobile.

### Phase 2 — Seasons, members, catalog and Sportlink import

Deliverables:

- Migrations for settings, seasons, staff profiles, members, articles and variants, including indexes, constraints and RLS.
- Season opening/archive and active catalog management.
- Sportlink CSV upload, size/MIME/row/cell limits, mapping, preview and transactional upsert by normalized relatienummer.
- Import summary, duplicate/invalid reporting, checksum, actor and audit record; never auto-delete members, orders or payments.
- Member list, filters, search and detail drawer for authorized staff.

Gate:

- A fixture CSV can be previewed and committed atomically; malformed, oversized, duplicate and formula-injection inputs are rejected or safely represented. Unauthorized roles cannot import or enumerate data.

### Phase 3 — Orders and exact manual payments

Deliverables:

- One `member_order` per member and season, exact `amount_due_cents`, article rules and derived order status.
- Backoffice order and payment views.
- Kas/pin registration with no editable amount field; server re-reads the exact order amount and records the actor/method in one transaction.
- Payment status model covering open/pending/paid/failed/canceled/expired/refunded and audit history.
- Queue the payment confirmation e-mail without requiring SendGrid live credentials.

Gate:

- The system makes combined, partial or arbitrary-amount payments impossible at both UI and database/service level. Manual payment changes order state exactly once and activates the QR only after the transaction commits.

### Phase 4 — Parent OTP and member portal

Deliverables:

- Neutral e-mail request response, six-digit cryptographically secure OTP, ten-minute expiry, five-attempt maximum, single-use HMAC/hash storage, resend and IP/e-mail rate limits.
- Parent session creation, rotation, revocation, logout-all and secure cookie handling.
- Explicit candidate selection for additional active members sharing the normalized e-mail address; no automatic family linking.
- Per-member dashboard cards showing exact amount, payment state, one seasonal QR panel and item-level statuses: `Nalevering`, `Af te halen`, `Afgehaald`.
- Payment entry point per member and neutral Mollie return page.

Gate:

- OTP enumeration, replay, expiry, brute-force, cookie and cross-member authorization tests pass. A parent can manage multiple explicitly linked members while each order and payment remains separate.

### Phase 5 — Stock, delivery reservations and QR fulfilment

Deliverables:

- Delivery receipts per article variant and quantity.
- Transactional stock reservations that cannot make available quantity negative and move only selected order lines to `Af te halen`; remaining lines stay `Nalevering`.
- 256-bit random QR bearer token with only a hash stored, one active token per order/season, rotation/revocation with reason and audit.
- Restricted fulfilment lookup by QR or fallback search with minimal member data.
- Atomic fulfilment commit: lock selected lines, re-check paid status, token and `ready_for_pickup`, create fulfilment records and mark selected lines `Afgehaald` in one transaction.
- Correction/reversal flow for beheerder/kledingcommissie with mandatory reason.

Gate:

- The canonical vertical chain works: receive shorts/socks, reserve them, scan, issue only selected paid lines, then receive and issue the shirt later using the same QR. Concurrent issuance cannot double-issue a line.

### Phase 6 — Mollie and SendGrid integrations

Deliverables:

- Mollie Payments API adapter using hosted checkout, exact EUR amount, local payment records, stable idempotency keys and server-only credentials.
- Webhook-first status processing: retrieve the provider payment, compare provider/payment/order metadata, currency and amount, then transactionally process paid/refunded/failed states. Duplicate, delayed and conflicting paid events are safe.
- SendGrid template source with allowlisted shortcodes, sanitization, fictional preview data, versioned audit history and minimal Mail Send permissions.
- Durable `email_jobs` queue, claim/skip-locked processing, five attempts with exponential backoff, idempotent bulk-mail batches and delivery/bounce event handling.
- Feature flags `MOLLIE_ENABLED` and `EMAIL_ENABLED`; adapters and mock/sandbox tests work without live credentials.

Gate:

- Mollie paid, failed, canceled, expired, duplicate, delayed and refunded scenarios pass. No redirect alone can mark an order paid. E-mail jobs cannot double-send after retries or double clicks.

### Phase 7 — Exports, hardening and release evidence

Deliverables:

- Authorized CSV/XLSX exports for members, orders, payments, deliveries, fulfilment and open lines with server-side filters and formula-injection protection.
- Security headers/CSP, CSRF and Origin/Host checks, rate limits, upload limits, redacted structured logs, correlation IDs and health/operational visibility.
- Retention jobs for OTPs, sessions and provider events; backup/restore and incident-response documentation.
- Full Playwright acceptance suite, RLS-negative tests, migration/seed verification, accessibility checks and responsive visual review.
- Release checklist with local, staging and production separation, explicit production approval and live Mollie gate.

Gate:

- All MVP acceptance gates in Canon section 22 are green. No known blocker, TODO, hardcoded production/example data, hidden non-MVP function or secret remains.

## 5. First vertical slice

The first demonstrable end-to-end slice will be implemented on the final architecture, not as a disposable prototype:

1. Seed a fictional season, members, catalog and orders.
2. Register an exact kas/pin payment for one member.
3. Receive shorts/socks and reserve them.
4. Generate/send a ready notification through the local e-mail job mock.
5. Scan the member QR as `uitgifte` and partially fulfil selected lines.
6. Receive the shirt and reserve it later.
7. Reuse the same QR to finish the order.
8. Verify audit history, derived statuses and exports.

This slice is the main integration gate for phases 2–5 and must remain covered by Playwright after later phases are added.

## 6. Test strategy and quality gates

- Unit: money/status derivation, normalization, OTP/QR token handling, CSV validation, shortcode sanitization, idempotency keys and export escaping.
- Integration: migrations, constraints, RLS, parent repositories, staff role guards, manual payment transaction, stock reservation and fulfilment transaction.
- Contract/integration: Mollie and SendGrid adapters with mocks/sandbox payloads and replayed events.
- E2E: staff MFA, import preview/commit, order/manual payment, parent OTP/linking, Mollie return/webhook, partial delivery, same-QR follow-up, fulfilment correction and export authorization.
- Security: negative RLS tests, enumeration/rate-limit tests, CSRF, cookie flags, secret scan, webhook replay and duplicate fulfilment.
- UI: WCAG 2.2 AA essentials, keyboard/focus, 360px member portal, 768px fulfilment, 1280px backoffice, reduced motion and clear non-color status labels.
- Every phase updates `TEST_EVIDENCE.md`; a phase is not marked complete with known red gates.

## 7. Environment and external-service gates

Implementation starts with local mocks and feature flags. Live Mollie/SendGrid credentials are not needed for the first phases. Before production:

- Separate Supabase projects and secrets exist for local, staging and production.
- Staff MFA and RLS are configured and tested.
- SendGrid sender domain/SPF/DKIM and templates are verified.
- Mollie test-mode webhook is publicly reachable over HTTPS and all reconciliation scenarios pass.
- Production backup, restore, rollback/forward-fix and incident procedures are confirmed.

## 8. Ongoing documentation rules

- `PROGRESS.md`: current phase, completed work, next work and blockers.
- `DECISIONS.md`: durable choices and any canon clarification, with impact and reversibility.
- `RISKS.md`: security, payment, privacy, delivery, operational and dependency risks with mitigations.
- `TEST_EVIDENCE.md`: exact commands, results, fixtures and screenshots/notes.
- `MVP_CHECKLIST.md`: expanded traceability from every canon requirement to implementation and tests.


# Progress

## Current phase
Phase 0 complete; Phase 1 dashboard foundation in progress.

## Completed
- Starter governance and canon assets added.
- Next.js App Router foundation, route groups, shared shell and first enterprise dashboard added.
- TypeScript, ESLint and production build gates pass locally.
- Supabase foundation migration, local port contract, server client and staff-role guard added.
- Supabase middleware session refresh and configured staff-route gating added.
- Append-only audit, orders, order lines and payment foundation migration added.
- Sportlink CSV preview domain service and protected `/api/imports/preview` endpoint added.

## In progress
- Supabase staff authentication and data-backed dashboard are not implemented yet.

## Next
- Connect staff Auth/MFA to the shell and add the audit table plus first data-backed member query.

## Blockers
- Live Supabase, Mollie and SendGrid credentials are intentionally not needed for the current foundation phase.

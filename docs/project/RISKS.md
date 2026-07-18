# Risks

| ID | Risk | Impact | Mitigation | Status |
| R-001 | Supabase credentials and local database are not configured yet. | Staff login and database-backed views cannot be live-verified. | Keep adapters/env validation explicit; use migrations, seed and fixture dashboard until the next phase. | Open |
| R-002 | Foundation dashboard is currently a visual fixture, not an operational data view. | Users could mistake sample metrics for live operations if released. | Keep the fixture isolated in the foundation phase and gate release on staff Auth/RLS/data integration. | Open |
| R-003 | Inventory/QR migrations have not yet run on a clean local PostgreSQL instance. | SQL syntax, RLS behavior or concurrency semantics could still fail despite static review. | Install/start only the isolated project Supabase runtime, execute all migrations/seed, then add negative RLS and two-session fulfilment tests before release. | Open |
| R-004 | Native `BarcodeDetector` support differs per browser. | Camera scanning can be unavailable on some issue devices. | Keep the secure token/link input fallback; validate the selected club device matrix and add a project-local scanner library only if required. | Open |

# Risks

| ID | Risk | Impact | Mitigation | Status |
| R-001 | Local Supabase is configured, but staff Auth/MFA fixtures and app-local env keys are not connected yet. | Staff login and fixturevrije backofficeviews zijn nog niet end-to-end bewezen. | Gebruik `.env.local.example`, maak fictieve staffaccounts en test MFA/rollen lokaal voordat datafixtures worden verwijderd. | Open |
| R-002 | Foundation dashboard is currently a visual fixture, not an operational data view. | Users could mistake sample metrics for live operations if released. | Keep the fixture isolated in the foundation phase and gate release on staff Auth/RLS/data integration. | Open |
| R-003 | Inventory/QR migrations had not run on a clean local PostgreSQL instance. | SQL syntax, RLS behavior or concurrency semantics could fail despite static review. | Clean reset, 18 pgTAP assertions and a real two-session race test now pass on the isolated local stack. | Closed |
| R-004 | Native `BarcodeDetector` support differs per browser. | Camera scanning can be unavailable on some issue devices. | Keep the secure token/link input fallback; validate the selected club device matrix and add a project-local scanner library only if required. | Open |

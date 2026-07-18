# Risks

| ID | Risk | Impact | Mitigation | Status |
| R-001 | Supabase credentials and local database are not configured yet. | Staff login and database-backed views cannot be live-verified. | Keep adapters/env validation explicit; use migrations, seed and fixture dashboard until the next phase. | Open |
| R-002 | Foundation dashboard is currently a visual fixture, not an operational data view. | Users could mistake sample metrics for live operations if released. | Keep the fixture isolated in the foundation phase and gate release on staff Auth/RLS/data integration. | Open |
|---|---|---|---|---|

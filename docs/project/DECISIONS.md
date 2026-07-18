# Architecture and product decisions

Record durable decisions here.
| 2026-07-18 | Use project-local Supabase ports 54329 (API), 54339 (database), 54349 (Studio) and 54359 (Inbucket). | Port preflight showed these ports free and AGENTS.md requires isolation from sibling projects. | Keeps local services isolated and documented. | Yes |
| 2026-07-18 | Keep the first dashboard on server-owned fixture data until staff Auth and RLS are connected. | The visual foundation can be validated without weakening the production authorization boundary. | No production transaction data is exposed by the current shell. | Yes |

| Date | Decision | Reason | Canon impact | Reversible |
|---|---|---|---|---|
| 2026-07-18 | Keep parent secrets in `private` schema and expose only narrow server-only RPC wrappers. | Supabase private schema must not be accessed through Data API; this preserves the boundary while allowing server-side OTP/session operations. | Yes |

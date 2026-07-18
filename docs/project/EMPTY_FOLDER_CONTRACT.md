# Empty-folder contract

This starter intentionally contains no application scaffold, dependency manifest, generated migration or implementation code.

Codex must:

- initialize the project directly in the current root;
- preserve the canon and design assets;
- avoid generating a nested app directory;
- detect and avoid conflicts with other local processes;
- create all implementation files itself after preflight;
- keep the repository runnable and tested after each completed phase.

## Local repository boundary

- Expected path: `D:\\Codex\\repos\\duindorp-sv-tenueportaal`.
- `D:\\Codex\\repos` is a parent directory that may contain unrelated repositories.
- Do not read, write, scaffold, run commands in, or alter sibling repositories.

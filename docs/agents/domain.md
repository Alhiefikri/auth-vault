# Domain docs

## Layout

Single-context.

## Location

- **CONTEXT.md** — at the repo root. Contains the project's domain language, key concepts, and glossary.
- **docs/adr/** — at the repo root. Contains architectural decision records.

## Consumer rules

Skills that read domain docs (`improve-codebase-architecture`, `diagnose`, `tdd`, `grill-with-docs`) should:

1. Read `CONTEXT.md` first to understand domain terminology before reasoning about code.
2. Check `docs/adr/` for past architectural decisions before proposing structural changes.
3. When a decision is made that changes domain language or architecture, update `CONTEXT.md` or add an ADR inline as part of the same task.

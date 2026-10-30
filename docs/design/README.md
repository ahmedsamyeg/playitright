# PlayItRight — Design

Implementation design documents. The specs ([docs/specs/](../specs/README.md))
say **what** and carry the requirement IDs; design documents say **how** and
must trace back to those IDs.

| # | Document | Domain |
|---|---|---|
| 01 | [Media database](01-media-database.md) | The on-device SQLite store: placement, full DDL, concurrency, migrations, recovery, query catalog, tests |

## Rules

- Every design section cites the spec requirements it implements (DB-, ARCH-,
  NFR-, MD-, SYNC-…).
- Design never relaxes a P0 requirement. If a design conflicts with a spec,
  the spec wins and the spec gets a revision with the decision recorded (doc 01
  style).
- Design documents are written before their code: the Phase 1 modules land in
  SPM packages whose public API matches what these documents describe.

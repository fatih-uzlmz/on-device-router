# On-device memory ledger contract

This contract defines the records that the Swift JSON ledger and its persistent
Rust shadow must preserve. It is the compatibility boundary for the shadow
migration. The current Swift document is schema version 2.

## Records

The ledger contains five record kinds:

| Kind | Identity | Required data |
| --- | --- | --- |
| Durable fact | Stable fact UUID | Triple, display statement, every source quote and timestamp, created/updated times, confidence, reinforcement/access counts, last access, importance, embedding values, related fact UUIDs, and invalidation time when replaced |
| Relationship | Stable relationship UUID | Triple, source fact UUID, creation time, confidence, and invalidation time when removed |
| Episode | Stable episode UUID | Kind, value, source text, creation time, and expiry time |
| Conversation turn | Stable turn UUID | User message, assistant message, route, timestamp, and expiry time |
| Invalidated fact | Its original fact UUID | The complete fact record, including its original sources and invalidation time |

An invalidated fact remains in history and is excluded from active recall. A
correction adds or updates the new fact and records the old fact's invalidation;
it does not erase the old record or its source evidence. Relationship records
have their own identity and lifecycle. Graph edges and `relatedFactIDs` are
derived retrieval data and may be rebuilt from the ledger records.

## Evidence and time rules

- User source quotes are durable evidence. Assistant text is retained only as
  part of a temporary conversation turn and is never promoted to fact evidence.
- Preserve original IDs, strings, numeric values, and timestamps during import.
  Import does not re-extract, normalize, reinforce, invalidate, or deduplicate
  records.
- Facts are active exactly when `invalidatedAt` is absent. Relationships are
  active exactly when their `invalidatedAt` is absent.
- Episodes and conversation turns retain their existing expiry timestamps and
  lifetimes. Expired temporary records may be purged under the same rules as
  the Swift store; they must not become permanent facts.
- Stable record IDs make retries address the same records. A migration must
  verify the record inventory and content before it is marked complete.

## Derived retrieval data

Embeddings are derived indexes, not the source of truth. The Swift store may
contain NaturalLanguage vectors or 128-element hashed fallback vectors. Keep
those original vectors intact in `payloadJSON`; project them into the Rust
index's fixed 128-dimensional space using the versioned signed-feature hash.
Store each source vector's dimension with the derived index row. Rust hybrid
search applies the same projection to the query and uses vectors only when the
stored source dimension matches the query dimension. The normal app recall path
does not switch to Rust in this step.

## Migration and ownership

- The transfer envelope uses format `on-device-router-ledger`, transfer
  schema version 1, and Swift ledger schema version 2. It sorts records by kind
  and stable ID. Each row carries an indexable text projection and dates in
  Unix seconds; `payloadJSON` carries the complete sorted-key Swift record.
- Rust stores and exports each `payloadJSON` string intact. The wrapper fields
  are checked against the payload before import and regenerated after reopen;
  verification compares the exported records with the original envelope.
- Record UUIDs are unique across kinds because MemLocal's item table uses the
  UUID as its key.
- Store the Rust database in the app's Application Support directory, scoped to
  this app installation. Keep the Swift JSON file intact through import and
  verification.
- Import into a new or disposable Rust database generation. A failed or
  interrupted import can be discarded and retried from the Swift ledger.
- Verify schema version, record counts by kind, stable IDs, and a deterministic
  digest of the imported payloads after closing and reopening the Rust store.
- Do not change the authoritative writer during this migration stage. Swift
  remains canonical until a later cutover has compared behavior and passed
  device restart, correction, contradiction, and recall checks.
- Treat the Rust text/vector/graph indexes as derived views. The complete
  record payload must remain recoverable independently of those indexes.

## Current scope boundary

The app currently synchronizes a full snapshot into the persistent Rust shadow
and compares its export with Swift before and after reopening the database.
MemLocal's graph-edge rows still do not carry all Swift relationship fields,
so the full relationship payload remains in the opaque source record. This
stage does not transfer write authority: Swift remains canonical until the
later behavior and device checks pass.

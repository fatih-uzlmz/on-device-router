# On-device memory ledger contract

This contract defines the records that the persistent Rust ledger must
preserve. The Swift JSON document is the schema-version-3 migration source and
recovery copy.

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
those original vectors and `embeddingProviderVersion` in `payloadJSON`.
NaturalLanguage vectors use `nl-en-rev-<revision>`; the fallback uses `hash-v1`.
On load, Swift regenerates unknown vectors and regenerates older revisions or
hashed vectors when the current NaturalLanguage model is available. Hashed
facts are text-search-only until then. Rust projects vectors into its fixed
128-dimensional index, but hybrid search compares them only when provider
version, source dimension, and projection version all match. Hybrid results now
lead recall only after Swift's existing topic rule accepts them. Eligible Rust
seeds expand through the Swift graph for up to two hops, and Swift recall stays
available as a fallback.

Promotion gate: Rust hybrid must match or beat Swift recall on paraphrase,
correction, contradiction, and irrelevant-fact rejection before its results
can enter recall. The recorded device gate passed all four cases before
promotion.

## Migration and ownership

- The transfer envelope uses format `on-device-router-ledger`, transfer
  schema version 1, and Swift ledger schema version 3. It sorts records by kind
  and stable ID. Each row carries an indexable text projection and dates in
  Unix seconds; `payloadJSON` carries the complete sorted-key Swift record.
- Rust stores and exports each `payloadJSON` string intact. The wrapper fields
  are checked against the payload before import and regenerated after reopen;
  verification compares the exported records with the original envelope.
- Record UUIDs are unique across kinds because MemLocal's item table uses the
  UUID as its key.
- Store the Rust database in the app's Application Support directory, scoped to
  this app installation. Restore a valid existing Rust ledger on startup; use
  Swift JSON to initialize an empty Rust database and as a recovery copy if a
  Rust write fails.
- Import into a new or disposable Rust database generation. A failed or
  interrupted import can be discarded and retried from the Swift ledger.
- Verify schema version, record counts by kind, stable IDs, and a deterministic
  digest of the imported payloads after closing and reopening the Rust store.
- Rust is the durable writer after its complete ledger has been verified.
  Swift applies extraction, deduplication, correction, and invalidation rules
  in memory, then commits the full snapshot to Rust. If that commit fails, save
  the current snapshot to Swift JSON and discard the stale Rust database.
- Treat the Rust text/vector/graph indexes as derived views. The complete
  record payload must remain recoverable independently of those indexes.

## Current scope boundary

The app synchronizes a full snapshot into Rust and verifies the exported
records after reopen. MemLocal's graph-edge rows do not carry all Swift
relationship fields, so the complete relationship payload remains in the
opaque source record; Swift uses that record to rebuild and traverse the graph.

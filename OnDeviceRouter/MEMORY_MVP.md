# Local-first memory MVP

The active app path is intentionally local-only: retrieve local memory, build a
labeled reference block, run Llama on-device, deterministically extract facts
from the user's message, persist appropriate records, and refresh diagnostics.
`Router.swift` and `CloudService.swift` remain available for future work but are
not referenced by the active execution path.

## Ideas retained from the bundled MVP and MemLocal-style design

- A small `MemoryStore` boundary isolates memory from inference and UI code.
- JSON persistence keeps the MVP inspectable and fully inside the app sandbox.
- Facts use subject-predicate-object triples with confidence, timestamps,
  reinforcement, access metadata, embeddings, and validity history.
- Retrieval combines BM25-style lexical matching, on-device embeddings, entity
  matching, graph expansion, importance, and recency.
- Contradicted facts remain as invalidated audit history and never enter recall.

## Project-specific Swift implementation

- Deterministic regular-expression extraction handles the supported personal
  fact forms before any model is involved.
- The version 3 document separates durable facts, entity relationships,
  expiring episodic context, and bounded temporary conversation turns.
- Natural Language sentence embeddings are used when available; a stable hashed
  vector is the deterministic offline fallback and is text-search-only in Rust.
  Each vector carries its provider revision, and legacy vectors are regenerated
  on first load.
- Query vocabulary expansion covers common personal-memory intents such as pets,
  family, food, places, and preferences before graph traversal.
- Llama receives concise statements under an explicitly untrusted
  `Relevant personal memory` label, never reconstructed user/assistant history.

## MemLocal text index adapter

- `MemlocalMemoryStore` wraps the Swift store and keeps its versioned JSON file
  as the authoritative ledger.
- The full Swift ledger is mirrored into a persistent MemLocal database and
  verified after reopening. Active facts are eligible for text search;
  invalidated facts remain in history and are excluded from recall.
- Rust text results supplement Swift recall when the Swift store returns fewer
  facts than requested. Swift extraction, embeddings, graph traversal, episodes,
  JSON migration, and diagnostics remain authoritative.
- Rust hybrid search runs in shadow mode during recall and logs its result IDs.
  Promotion requires matching or beating Swift on paraphrase, correction,
  contradiction, and irrelevant-fact rejection.
- The Rust core is pinned, vendored, and built with its optional HTTP feature
  disabled. See `Native/README.md` for the source revision and rebuild steps.

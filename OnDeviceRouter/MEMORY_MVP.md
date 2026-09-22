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
- The version 2 document separates durable facts, entity relationships,
  expiring episodic context, and bounded temporary conversation turns.
- Natural Language sentence embeddings are used when available; a stable hashed
  vector is the deterministic offline fallback.
- Query vocabulary expansion covers common personal-memory intents such as pets,
  family, food, places, and preferences before graph traversal.
- Llama receives concise statements under an explicitly untrusted
  `Relevant personal memory` label, never reconstructed user/assistant history.

The Rust `memlocal_core` runtime is not integrated. For this MVP its FFI,
packaging, and cross-language lifecycle costs would add complexity without
improving the deterministic extraction and bounded local persistence goals.

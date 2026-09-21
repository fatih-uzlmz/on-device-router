# On-Device Router — iOS App

Runs a privacy-first local-memory lab on a real iPhone. Llama 3.2 1B Instruct
(4-bit) runs through MLX Swift, while typed memories, embeddings, BM25 ranking,
and graph traversal stay on-device. Cloud routing is retained as scaffolding but
is disabled in the current build. The router is a direct port of `router_v1.py`
— same keywords, same weights, same threshold (2.0) — and is covered by
`OnDeviceRouterTests/RouterTests.swift`.

## Requirements

- A compatible iPhone with enough storage for the downloaded 4-bit Llama weights
- Xcode 26+ with the iOS 26 SDK
- Network access for the first model download; later local inference is offline

## Setup (about 2 minutes)

1. Open `OnDeviceRouter.xcodeproj` in Xcode.
2. Copy `Secrets.template.swift` → `Secrets.swift` and fill in your API key.
   `Secrets.swift` is git-ignored and never committed.
3. Plug in your iPhone (the MLX model does NOT run in the Simulator),
   select it as the run destination, and press Run.

## What to try

- Send a harmless fact such as "My dog's name is Snow" and restart the app.
- Ask a follow-up such as "What is my dog's name?" to exercise local recall.
- Watch the header and Xcode console for stored vectors, graph edges, and hits.

## Notes

- The audit log hashes queries with SHA-256: proof of local decisions without
  retaining health/finance text.
- `Secrets.swift` remains git-ignored for the later cloud-enabled build, but
  the current local-only path does not make cloud requests.

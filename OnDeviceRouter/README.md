# On-Device Router — iOS App

Runs the privacy-first router on a real iPhone: easy queries stay on-device
(Apple Foundation Models, free, offline), hard reasoning goes to the cloud.
The router is a direct port of `router_v1.py` — same keywords, same weights,
same threshold (2.0) — and is covered by `OnDeviceRouterTests/RouterTests.swift`.

## Requirements

- iPhone 15 Pro or newer (Apple Intelligence on: Settings → Apple Intelligence & Siri)
- Xcode 26+ with the iOS 26 SDK
- A cloud API key (any OpenAI-compatible endpoint) for the fallback path

## Setup (about 2 minutes)

1. Open `OnDeviceRouter.xcodeproj` in Xcode.
2. Copy `Secrets.template.swift` → `Secrets.swift` and fill in your API key.
   `Secrets.swift` is git-ignored and never committed.
3. Plug in your iPhone (the on-device model does NOT run in the Simulator),
   select it as the run destination, and press Run.

## What to try

- "Summarize: …" → green **On-device** badge, works in airplane mode
- "What were my blood test results last month?" → forced on-device (privacy gate)
- "Prove the square root of 2 is irrational" → blue **Cloud** badge
- Watch the header: "% on-device" is your live cost-savings meter

## Notes

- API names follow Apple's WWDC25 Foundation Models docs; if Xcode's
  autocomplete suggests a newer signature, trust Xcode.
- The audit log hashes queries with SHA-256: proof of routing decisions
  without retaining health/finance text.

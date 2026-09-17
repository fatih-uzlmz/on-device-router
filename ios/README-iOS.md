# iOS Demo App — Setup

Runs the privacy-first router on your iPhone 16: easy queries stay on-device
(Apple Foundation Models, free, offline), hard reasoning goes to the cloud.

## Requirements

- iPhone 15 Pro or newer (you have iPhone 16 — good)
- Apple Intelligence enabled: Settings → Apple Intelligence & Siri → on
- Xcode 26+ with the iOS 26 SDK
- A cloud API key (OpenAI-compatible) for the fallback path

## Steps (about 5 minutes)

1. In Xcode: File → New → Project → iOS → App. Name it `OnDeviceRouter`,
   interface SwiftUI, language Swift.
2. Set the deployment target to iOS 26.0 (Project → Target → General).
3. Drag all `.swift` files from this `ios/` folder into the project
   (check "Copy items if needed"). Delete the template `ContentView.swift`
   Xcode generated — ours replaces it.
4. Create `Secrets.swift` in the project (do NOT commit it):
   ```swift
   // (already templated in CloudService.swift — copy the Secrets enum,
   //  paste your real key)
   ```
   Add `Secrets.swift` to `.gitignore`.
5. Plug in your iPhone 16 (the on-device model does NOT run in the Simulator).
   Select it as the run destination and press Run.

## What to try

- "Summarize: …" → green **On-device** badge, works in airplane mode
- "What were my blood test results last month?" → forced on-device (privacy gate)
- "Prove the square root of 2 is irrational" → blue **Cloud** badge
- Watch the header: "% on-device" is your live cost-savings meter

## Notes

- API names follow Apple's WWDC25 Foundation Models docs; if Xcode's
  autocomplete suggests a newer signature, trust Xcode.
- The router is a direct port of `router_v1.py` — same keywords, same
  threshold (1.5). Improve one, port to the other.
- The audit log hashes queries with SHA-256: proof of routing decisions
  without retaining health/finance text.

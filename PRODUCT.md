# On-Device Router — Product Overview

## What it is

A privacy-first intelligent routing system for mobile AI. For every query, it
decides: can this be answered by the small model on the phone, or does it need
a frontier model in the cloud? Easy work stays on-device (private, free,
offline). Hard reasoning goes to the cloud. Health and finance queries never
leave the device, no matter what.

## The problem

- Running every AI query on frontier cloud models is expensive: high token
  bills, latency, and no offline use.
- Sending everything to the cloud is a privacy liability: health and finance
  data should never leave the user's phone.
- Apple and Google now ship on-device models and basic routing switches, but
  they give developers the switch — not the policy engine that decides per
  query, per regulation, with proof.

## The solution

A three-stage routing pipeline plus a proof layer:

1. **Privacy gate.** Health / finance / personal-data queries are forced
   on-device. This outranks everything else — capability never overrides
   privacy.
2. **Complexity scoring.** The query is scored on reasoning signals
   (proofs, math, code, analysis → cloud) vs. device-friendly signals
   (summarize, extract, translate, rewrite, device tasks → local), plus
   length and numeric-reasoning features.
3. **Threshold decision.** Score ≥ threshold → cloud frontier model.
   Below → on-device small language model.
4. **Audit log.** Every routing decision is recorded with a SHA-256 hash of
   the query (not the query text), the destination, the reasons, and latency.
   This is the compliance story: verifiable proof that sensitive queries never
   touched the cloud, without retaining the sensitive data itself.

## What exists today

- **`router_v1.py`** — the algorithm in Python: privacy gate, heuristic
  complexity scorer, threshold decision, eval harness. 100% routing accuracy
  on the first 33-query seed set; 63.6% of queries kept on-device
  (zero cloud inference cost).
- **`ios/`** — iPhone demo app (SwiftUI):
  - `Router.swift` — Swift port of the algorithm (same signals, same threshold)
  - `LocalModelService.swift` — on-device inference via Apple's Foundation
    Models framework (free, offline; iPhone 15 Pro or newer)
  - `CloudService.swift` — frontier-model fallback via any OpenAI-compatible API
  - `RoutingEngine.swift` — orchestrates route → execute → audit
  - `ContentView.swift` — chat UI; every answer is badged green (on-device)
    or blue (cloud), with a live "% on-device" cost-savings meter
- **`docs/`** — original vision doc, competitor analysis, and the
  Apple/Google diligence slide deck (Turkish).

## The cost-savings math

Every query kept on-device is a query with zero cloud tokens. At 60%+
on-device routing, a $500K/month inference bill becomes ~$200K — with quality
held constant, because only queries the small model can handle stay local.

## Roadmap

- [x] v1 heuristic router + eval harness
- [x] iOS demo app scaffold (build & run in Xcode on a real device)
- [ ] v2: bigger, messier eval set (ambiguous, multi-intent, adversarial queries)
- [ ] v2: learned router — tiny classifier trained on where small vs. large
      model answers agree, replacing keyword heuristics
- [ ] Cascade routing: try on-device first, escalate on low confidence
- [ ] On-device memory layer (the original wedge: encrypted per-user memory)
- [ ] Benchmark: token savings vs. quality on a realistic workload

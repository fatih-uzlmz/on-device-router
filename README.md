# On-Device Router

Privacy-first intelligent routing: decide per query whether it can be answered
by the on-device model or needs a frontier cloud model.

## How v1 works

1. **Privacy gate** — health / finance / personal-data queries are forced
   on-device. They never reach the cloud, regardless of complexity.
2. **Complexity scorer** — heuristic features (reasoning keywords, math/code
   signals, query length) produce a score.
3. **Decision** — score >= threshold → cloud, else on-device.

## Results (v1, seed set)

- 33 labeled queries, 100% routing accuracy
- 63.6% of queries stay on-device (zero cloud inference cost)
- Threshold swept 0.5–3.0; 1.5–2.0 optimal on this set

## Honest caveats

- Small hand-built dataset — v1 is a baseline, not a proof. Next: a larger,
  messier eval set (ambiguous queries, adversarial phrasing, multi-intent).
- Heuristics don't generalize; v2 should be a tiny learned classifier
  (distilled, quantized) running on-device.

## Roadmap

- [ ] v2: learned router (tiny classifier, Core ML / ExecuTorch)
- [ ] iOS demo app (SwiftUI + Foundation Models framework)
- [ ] Benchmark: token savings vs quality on a realistic workload
- [ ] Audit log: per-query proof of "never left the device"

# Memory search validation — 2026-09-26

The iPhone 16 running iOS 26.5 was tested through Xcode 26.2. These device runs
recorded the hybrid candidate gate before promotion. The app now uses eligible
Rust hybrid IDs in recall and retains Swift's mandatory topic filter.

## Results

- Both on-device extraction tests passed on the physical iPhone in the 15:07
  and 15:17 runs. The simulator crashes in these tests were SIGABRTs during
  MLX Metal device initialization, before extraction returned.
- The four-case hybrid gate passed 4/4 on the iPhone in isolated runs at 15:14
  and 15:16. After fixing ledger verification, two consecutive combined
  extraction-plus-gate runs at 15:24 and 15:25 each passed all three tests,
  including 4/4 gate cases: paraphrase, correction, contradiction, and
  irrelevant-fact rejection. The timestamp-rounding regression test also passed.
- Earlier combined runs exposed an intermittent ledger verification failure.
  Rust's JSON round trip changed a Unix timestamp by less than one microsecond;
  record IDs, content, and opaque payload JSON were identical. Verification now
  tolerates that rounding in wrapper timestamps while requiring exact payloads.
  The gate test uses its own temporary database and asserts that the Rust index
  stays available. One earlier rerun also encountered a SQLite lock in the
  shared app shadow database.
- Raw Rust results included irrelevant facts. The 4/4 result applies only after
  Swift's topic filter removed ineligible candidates; the same filter remains
  on the promoted recall path.

The repeated 4/4 runs establish the Rust hybrid candidate path on this device.
Hybrid candidates now lead factual recall, then seed the Swift two-hop graph;
Swift lexical/entity recall remains a fallback. Swift still applies extraction,
deduplication, and contradiction rules before committing complete snapshots to
the authoritative Rust ledger. The recorded runs predate those graph and
write-authority changes, so they do not verify those paths.

The app was built, installed, and launched on the wired iPhone. The device
reported a running `OnDeviceRouter` process after launch.

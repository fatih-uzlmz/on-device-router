# Memory shadow validation — 2026-09-26

The iPhone 16 running iOS 26.5 was tested through Xcode 26.2. Swift remains the
authoritative writer and recall path. Rust hybrid results are logged in shadow
mode; the existing Swift topic filter is mandatory for candidate eligibility.

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
- Raw Rust results included irrelevant facts. The 4/4 result applies to the
  complete shadow candidate path with Swift's topic filter; that filter must
  remain in place for any future promotion.

The repeated 4/4 runs establish the current shadow candidate path on this
device, but Rust results have **not** been promoted into recall. Swift remains
the authoritative writer and recall path. Graph retrieval, consolidation
bridging, and write-authority migration remain out of scope.

The app was built, installed, and launched on the wired iPhone. The device
reported a running `OnDeviceRouter` process after launch.

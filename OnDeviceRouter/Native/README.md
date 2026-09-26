# MemLocal iOS integration

The app uses the persistent Rust ledger as its durable source of truth after
startup verification. An existing Rust ledger is restored into the in-memory
Swift fact engine; an empty database is bootstrapped from the legacy
`SimpleMemoryStore` JSON file. Swift JSON persistence is disabled while Rust is
healthy. If a Rust ledger write fails, the current snapshot is saved to JSON
and the stale Rust database is discarded so the app can recover on the next
launch.

The on-device MLX model extracts proposed atomic facts and triples after each
answer. Swift validates their exact user evidence, merges duplicates, matches
corrections against active facts, invalidates replaced values, and sends the
complete record snapshot to Rust before the next turn. Recent conversation
evidence and durable fact sources are included in recall. Swift also handles
embeddings, graph links, episodes, and legacy JSON migration. Deterministic
extraction remains a fallback for the phrases it recognizes.

The Rust source and Swift adapter include a versioned full-snapshot sync and
export API. Each row keeps its original Swift record JSON intact alongside
Rust text and vector projections. Original on-device fact embeddings are
projected into a fixed 128-dimensional Rust index; hybrid search accepts query
vectors through the C bridge and compares only matching provider revisions,
source dimensions, and projection versions. Hybrid result IDs now lead recall
only after Swift's mandatory topic filter. Those seed IDs expand through the
Swift ledger's relationship graph for up to two hops; Swift lexical/entity
recall remains a fallback. The checked-in XCFramework contains the ledger and
embedding bridge symbols.

See `LEDGER_CONTRACT.md` for the record fields, evidence rules, and migration
checks. If startup cannot validate the existing Rust database, the adapter
rebuilds it from the current recovery snapshot.

The Rust core is vendored at the revision in `UPSTREAM_REVISION` under its
Apache-2.0 license. The `http` feature is disabled. The checked-in
`../Frameworks/MemlocalCore.xcframework` contains release static libraries for
arm64 iOS devices and arm64 iOS simulators, built with an iOS minimum of 26.0.

To regenerate the framework, install Rustup, then run:

```sh
./OnDeviceRouter/Native/build-memlocal-xcframework.sh
```

Rustup reads the pinned compiler version and Apple targets from
`rust-toolchain.toml`. Set `IOS_MINIMUM` to change the minimum deployment target
or `MEMLOCAL_BUILD_ROOT` to choose a build directory. The script writes the
resulting framework into `OnDeviceRouter/Frameworks`.

# MemLocal iOS integration

The app keeps `SimpleMemoryStore` as its canonical JSON-backed ledger. The
MemLocal adapter mirrors the complete ledger into a persistent Rust shadow
database and can add BM25 matches from active durable facts to Swift recall
when the Swift store returns fewer facts than requested. The shadow is checked
against the Swift snapshot before and after reopening it during startup.

The on-device MLX model extracts proposed atomic facts and triples after each
answer. Swift validates their exact user evidence, matches corrections against
active facts, invalidates replaced values, and persists facts and source
messages before the next turn. Recent conversation evidence and durable fact
sources are included in recall. Swift also handles embeddings, graph links,
episodes, migration, and diagnostics. Deterministic extraction remains a
fallback for the phrases it recognizes.

The Rust source and Swift adapter include a versioned full-snapshot sync and
export API. Each row keeps its original Swift record JSON intact alongside
Rust text and vector projections. Original on-device fact embeddings are
projected into a fixed 128-dimensional Rust index; hybrid search accepts query
vectors through the C bridge and matches only compatible source dimensions.
The app has not switched recall to Rust hybrid or graph search. Swift remains
the authoritative writer during this migration stage. The rebuilt checked-in
XCFramework contains the ledger and embedding bridge symbols.

See `LEDGER_CONTRACT.md` for the record fields, evidence rules, and migration
checks. Rust import requires an empty shadow database; discard an incomplete
database and retry from the Swift snapshot rather than importing twice into a
partially populated store.

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

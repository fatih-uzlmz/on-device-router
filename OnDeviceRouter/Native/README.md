# MemLocal iOS integration

The app keeps `SimpleMemoryStore` as its canonical JSON-backed ledger. The
MemLocal adapter indexes active fact statements in an in-memory Rust text index
and can add BM25 matches to Swift recall when the Swift store returns fewer
facts than requested. The index is rebuilt from the ledger on launch. Fact
extraction, contradiction handling, graph expansion, episodes, migration, and
diagnostics continue to come from the Swift store.

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

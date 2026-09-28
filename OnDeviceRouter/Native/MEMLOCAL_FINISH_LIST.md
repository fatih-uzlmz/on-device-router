# MemLocal Finish List

Audit of the vendored Rust core (`OnDeviceRouter/Native/memlocal_core`, upstream
`memlocal/memlocal_core @ d46d09c`) and the Swift shim, as actually built into
the app. Date: 2026-09-27.

## What's solid (don't rewrite)

- **Storage/search core is real.** `MemoryStore` (~2000 lines): `put_memory`,
  BM25 text search, HNSW semantic search, hybrid, deduped hybrid, 2-hop graph
  expansion, temporal search, triple search. These are implementations, not stubs.
- **Ledger sync path works.** Swift→Rust JSON sync is the app's durable commit
  point; hydration/verify/restore around it is sound. `prepare_router_ledger`
  validates format versions, duplicate IDs, UUID parsing, and payload-id
  matching with proper `Result` errors — no unwraps on this path.
- **FFI boundary is panic-guarded.** `status_code()` wraps all 11 int-returning
  C functions in `catch_unwind`; `open`/`free_string`/`free_error`/`last_error`
  have direct guards. A Rust panic becomes a -1/null + error string, not UB.
- **Contradiction scan is real.** `find_contradicting_triples` does what it says.
- **Long-term subsystem wrappers are thin but functional** (they delegate to the
  store). The problem with them is exposure, not correctness.

## P0 — correctness / safety (do first)

1. **SQLite code-14 root cause still unknown.** The sim reproduces it on every
   run: parent dir exists (Swift creates it), path is absolute, stale dirs are
   removed — CozoDB still returns `unable to open database file`. The
   `create_dir_all` fix didn't touch it. **Fix:** debug on the Mac where it
   reproduces; check what path/flags CozoDB actually passes to sqlite and
   whether the sim container is the issue. (A host-side `cargo test` run is
   the first discriminator: if engine open works on macOS, the bug is
   sim-environmental.)
2. **Parallel-execution hang.** The 3 `MemlocalMemoryStore` tests wedge the
   runner at 0% CPU under parallel testing; they pass serially. Ruled out:
   shared DB file (each test uses an isolated temp URL) and unguarded FFI
   panics (the boundary is guarded — see above). Remaining suspects: CozoDB
   global state (rayon thread pool?), lock ordering on the engine's
   `Mutex<SensoryBuffer>` / `Mutex<WorkingMemory>` / `Mutex<ConversationBuffer>`.
   **Fix:** reproduce the hang, sample the wedged threads (`sample` / lldb),
   then fix.
3. **Mutex poison handling (minor).** ~10 `mutex.lock().unwrap()`s in
   `bridge.rs`'s short-term-memory pub API (not reachable via the C ABI today).
   A poisoned mutex would panic; the FFI guard converts it to -1, but the
   handle is then permanently broken. **Fix:** use
   `unwrap_or_else(PoisonError::into_inner)` like the shim does, or map to
   `Err`.

## P1 — finish the contract the app needs

4. **Consolidation apply path.** Detection works and is dry-run wired. Nothing
   ever invalidates the older fact — Swift still owns correction/invalidation
   with its own logic. **Fix:** define invalidation semantics (who wins, what
   happens to evidence/relationships), review on-device dry-run logs, then
   wire apply mode.
5. **Rust-side tests are nearly absent.** 5 tests total, all in `bridge.rs`.
   Zero coverage for storage, schema/migrations, ledger sync round-trips,
   hybrid ranking, or graph expansion. The Swift suite cannot catch Rust logic
   bugs. **Fix:** unit tests per module; at minimum ledger round-trip,
   hybrid ranking determinism, and contradiction-scan cases.
6. **Dead code in the iOS build.** Every engine open constructs 8 long-term
   subsystems, 3 short-term buffers, and the tool executor — none reachable
   via the C ABI. **Fix:** either expose what's needed or feature-gate them
   out of the FFI build (binary size is ~64MB/slice; open pays for all of it).

## P2 — process

7. **xcframework/source drift.** The prebuilt binary lagged the Rust source by
   a full commit (the code-14 fix shipped in source only). The build script
   exists (`Native/build-memlocal-xcframework.sh`). **Fix:** run it in CI or
   as a pre-push hook; never commit source without rebuilding.
8. **Upstream decision.** Vendored at `d46d09c` with no tracking. Decide:
   track upstream, or declare the fork and delete `UPSTREAM_REVISION`.

## Suggested order

1 (code-14) → 2 (hang), then 5 (tests pin the fixes), then 4, then 6–8.
Item 3 is minor hardening; do it with 5.

#!/usr/bin/env python3
"""Canonical SHA-256 digest of the Rust sources that build MemlocalCore.xcframework.

The prebuilt xcframework is committed to the repo; this digest lets a test detect
when the binary has drifted from source. The Swift test
`rustSourceMatchesPrebuiltXcframework` implements the identical canonical form --
keep them in sync:

    digest = SHA256( concat over files sorted by relpath of (relpath_utf8 + b"\\n" + file_bytes) )

where files = <crate>/src/**, <crate>/include/**, <crate>/Cargo.toml,
<crate>/Cargo.lock for crates memlocal_core and memlocal_swift_shim,
and relpath = "<crate>/<path within crate>" with "/" separators.
"""
import hashlib
import os
import sys

NATIVE_DIR = os.path.dirname(os.path.abspath(__file__))
CRATES = ("memlocal_core", "memlocal_swift_shim")
INCLUDED_TOPS = ("src", "include")
INCLUDED_ROOT_FILES = ("Cargo.toml", "Cargo.lock")


def collect():
    entries = []
    for crate in CRATES:
        crate_dir = os.path.join(NATIVE_DIR, crate)
        for top in INCLUDED_TOPS:
            top_dir = os.path.join(crate_dir, top)
            for root, _dirs, files in os.walk(top_dir):
                for name in files:
                    full = os.path.join(root, name)
                    rel = os.path.relpath(full, NATIVE_DIR).replace(os.sep, "/")
                    entries.append(rel)
        for name in INCLUDED_ROOT_FILES:
            full = os.path.join(crate_dir, name)
            if os.path.isfile(full):
                entries.append("%s/%s" % (crate, name))
    entries.sort()
    return entries


def digest():
    h = hashlib.sha256()
    for rel in collect():
        full = os.path.join(NATIVE_DIR, *rel.split("/"))
        with open(full, "rb") as f:
            h.update(rel.encode("utf-8"))
            h.update(b"\n")
            h.update(f.read())
    return h.hexdigest()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--list":
        print("\n".join(collect()))
    else:
        print(digest())

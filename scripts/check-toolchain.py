#!/usr/bin/env python3
# Fails unless the toolchain installed by rustup comes from the pinned channel manifest.
# Usage: check-toolchain.py <pinned manifest (checked by SHA-256)> <toolchain dir> <target>...
# rustup checks every downloaded component against the manifest it fetched and keeps a copy of
# that manifest in lib/rustlib/multirust-channel-manifest.toml (re-serialized, so it is compared
# by content, not by bytes). Same date and same component hashes = same compiler and standard
# libraries on every runner. Standard library only (Python >= 3.11).
import sys
import tomllib

HOST = "x86_64-unknown-linux-gnu"


def components(manifest, targets):
    pkg = manifest["pkg"]
    wanted = [("rustc", HOST), ("cargo", HOST), ("rust-std", HOST)]
    wanted += [("rust-std", t) for t in targets]
    out = {}
    for name, target in wanted:
        entry = pkg[name]["target"][target]
        if not entry.get("available"):
            raise SystemExit(f"{name} for {target} is not available in the manifest")
        out[(name, target)] = (pkg[name]["version"], entry.get("xz_hash"), entry.get("hash"))
    return manifest["date"], out


def main():
    pinned_path, toolchain, *targets = sys.argv[1:]
    with open(pinned_path, "rb") as f:
        pinned = components(tomllib.load(f), targets)
    with open(f"{toolchain}/lib/rustlib/multirust-channel-manifest.toml", "rb") as f:
        installed = components(tomllib.load(f), targets)
    if pinned != installed:
        print(f"pinned:    {pinned}\ninstalled: {installed}", file=sys.stderr)
        raise SystemExit("installed Rust toolchain does not match the pinned manifest")
    date, comps = pinned
    print(f"Rust toolchain matches the pinned manifest ({date}):")
    for (name, target), (version, xz_hash, _) in sorted(comps.items()):
        print(f"  {name} {target} {xz_hash}")


main()

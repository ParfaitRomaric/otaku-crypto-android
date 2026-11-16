#!/usr/bin/env python3
# Verdict of `cargo audit --json` for the release (Otaku ADR-0034 §3, §4). Fails on:
# - a vulnerability of a crate linked into the Android library (linked-crates.txt: union of the
#   cargo trees of every shipped target);
# - an `unsound` or `yanked` warning on such a crate, unless it is written in the exception list
#   (scripts/audit-exceptions.txt, reviewed by Kurapika and Killua; empty today);
# - an unreadable report, or cargo audit failing without reporting a vulnerability.
# A vulnerability or warning of a crate of the workspace not linked for the phone, and every
# `unmaintained` warning, is printed for review but does not fail.
# Usage: audit-verdict.py <cargo-audit.json> <linked-crates.txt> <exit status> <exceptions file>
# Standard library only.
import json
import sys


def main():
    report_path, linked_path, status, exceptions_path = (
        sys.argv[1],
        sys.argv[2],
        int(sys.argv[3]),
        sys.argv[4],
    )
    with open(linked_path, encoding="utf-8") as f:
        linked = {line.strip() for line in f if line.strip()}
    # One exception per line: "<advisory id or yanked> <crate> v<version>"; "#" starts a comment.
    with open(exceptions_path, encoding="utf-8") as f:
        exceptions = {
            " ".join(line.split("#", 1)[0].split())
            for line in f
            if line.split("#", 1)[0].strip()
        }
    try:
        with open(report_path, encoding="utf-8") as f:
            report = json.load(f)
        found = report["vulnerabilities"]["list"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"::error::unreadable cargo audit report ({type(error).__name__})")

    blocking = []
    for entry in found:
        package = entry["package"]
        name_version = f"{package['name']} v{package['version']}"
        advisory = entry["advisory"]["id"]
        if name_version in linked:
            blocking.append(f"{advisory} {name_version}")
            print(f"::error::{advisory}: {name_version} is linked into the Android library")
        else:
            print(f"::warning::{advisory}: {name_version} (in Cargo.lock, not linked for the phone)")
    for kind, warnings in sorted((report.get("warnings") or {}).items()):
        for warning in warnings or []:
            package = warning.get("package") or {}
            advisory = (warning.get("advisory") or {}).get("id") or kind
            name_version = f"{package.get('name')} v{package.get('version')}"
            is_linked = name_version in linked
            excepted = f"{advisory} {name_version}" in exceptions
            if kind in ("unsound", "yanked") and is_linked and not excepted:
                blocking.append(f"{kind} {advisory} {name_version}")
                print(f"::error::{kind} {advisory}: {name_version} is linked into the Android library")
                continue
            where = "linked" if is_linked else "not linked"
            note = ", listed exception" if excepted else ""
            print(f"::warning::{kind} {advisory}: {name_version} ({where} for the phone{note})")
    if blocking:
        raise SystemExit(f"{len(blocking)} blocking finding(s) on crates linked for the phone")
    if status != 0 and not found:
        raise SystemExit("::error::cargo audit failed without reporting a vulnerability")
    print(f"cargo audit: nothing blocking in the {len(linked)} crates linked for the phone")


main()

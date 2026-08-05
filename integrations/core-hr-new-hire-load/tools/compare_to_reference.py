#!/usr/bin/env python3
"""Diff our archive's layout against a real .iar exported from an instance.

The layout OIC's importer expects is version-specific and not fully published.
The reliable way to learn it is to export any integration from the target
instance and look at what came out.

Point this at that export and at ours, and it reports the structural
difference: paths present in the reference but missing here, our paths that
have no counterpart, and per-file shape differences for the descriptors that
matter (ics.json, project.xml, appinstances). That turns "path not found" into
a specific list of things to fix.

Usage:
    compare_to_reference.py exported_from_instance.iar
    compare_to_reference.py exported_from_instance.iar --ours dist/OURS.iar
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(os.path.dirname(PROJECT_ROOT))
DEFAULT_OURS = os.path.join(REPO_ROOT, "dist", "NEW_HIRE_LOAD_01.00.0000.iar")

# Segments that vary per integration. Normalising them is what lets two
# archives for different integrations be compared structurally.
NORMALISERS = [
    (re.compile(r"^icspackage/project/[^/]+/"), "icspackage/project/<PROJECT>/"),
    (re.compile(r"^icspackage/appinstances/[^/]+$"),
     "icspackage/appinstances/<CONNECTION>.xml"),
    (re.compile(r"^icspackage/schedule/[^/]+$"),
     "icspackage/schedule/<PROJECT>.xml"),
    (re.compile(r"processor_[^/]+"), "processor_<N>"),
    (re.compile(r"resourcegroup_[^/]+"), "resourcegroup_<N>"),
]


def normalise(name: str) -> str:
    for pattern, replacement in NORMALISERS:
        name = pattern.sub(replacement, name, count=1)
    return name


def shape(names: list[str]) -> dict[str, list[str]]:
    """Normalised path -> the concrete paths that produced it."""
    grouped: dict[str, list[str]] = {}
    for name in names:
        grouped.setdefault(normalise(name), []).append(name)
    return grouped


def project_of(names: list[str]) -> str | None:
    for name in names:
        parts = name.split("/")
        if name.startswith("icspackage/project/") and len(parts) > 3:
            return parts[2]
    return None


def describe_xml(blob: bytes) -> list[str]:
    """Top-level element names, so two descriptors can be compared by shape."""
    try:
        root = ET.fromstring(blob)
    except ET.ParseError:
        return []
    tag = root.tag.split("}")[-1]
    children = sorted({child.tag.split("}")[-1] for child in root})
    return [f"<{tag}>"] + [f"  <{c}>" for c in children]


def describe_json(blob: bytes) -> list[str]:
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return []
    return sorted(data.keys()) if isinstance(data, dict) else []


def report_section(title: str, lines: list[str]) -> None:
    print(f"\n{title}")
    print("-" * len(title))
    if not lines:
        print("  (none)")
        return
    for line in lines:
        print(f"  {line}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help=".iar exported from the instance")
    parser.add_argument("--ours", default=DEFAULT_OURS)
    args = parser.parse_args(argv)

    for path in (args.reference, args.ours):
        if not zipfile.is_zipfile(path):
            print(f"not a ZIP archive: {path}", file=sys.stderr)
            return 1

    with zipfile.ZipFile(args.reference) as ref, zipfile.ZipFile(args.ours) as ours:
        ref_names, our_names = ref.namelist(), ours.namelist()

        print(f"reference : {args.reference} ({len(ref_names)} entries)")
        print(f"ours      : {args.ours} ({len(our_names)} entries)")
        print(f"reference project dir : {project_of(ref_names)}")
        print(f"our project dir       : {project_of(our_names)}")

        ref_shape, our_shape = shape(ref_names), shape(our_names)

        report_section(
            "In the reference, missing from ours (fix these first)",
            sorted(set(ref_shape) - set(our_shape)),
        )
        report_section(
            "In ours, absent from the reference (may be ignored, or wrong)",
            sorted(set(our_shape) - set(ref_shape)),
        )

        # Compare the descriptors that carry the import contract.
        interesting = [
            n for n in ref_names
            if posixpath.basename(n) in ("ics.json", "project.xml")
            or n.startswith("icspackage/appinstances/")
        ]
        lines: list[str] = []
        for name in sorted(interesting):
            blob = ref.read(name)
            described = (describe_json(blob) if name.endswith(".json")
                         else describe_xml(blob))
            lines.append(f"{name}:")
            lines.extend(f"    {d}" for d in described or ["(unparsed)"])
        report_section("Reference descriptor shapes", lines)

        # The reference's own file listing, so the exact layout is on record.
        report_section("Full reference listing", sorted(ref_names))

    print("\nNext: make the paths under the first section exist in src/, "
          "rebuild, and re-import.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

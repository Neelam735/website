#!/usr/bin/env python3
"""Check an .iar before it goes anywhere near an OIC instance.

OIC's import wizard is the only authority on whether an archive imports. This
catches the failures that are cheap to find first: a malformed archive, a
mismatched version, XML that does not parse, a map that references a schema
that is not in the package, a lookup the project binds to that nobody
packaged, or a credential that escaped review.

It also checks the one thing specific to this integration that no importer
would ever catch: that the fixed-width layout adds up. A layout whose columns
overlap or leave a gap imports perfectly and delivers a corrupt file.

Usage:
    validate_iar.py dist/PRINCIPAL_401K_LOANS_01.00.0000.iar
"""

from __future__ import annotations

import argparse
import posixpath
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

# The entries OIC's importer resolves by path. A missing one is what surfaces
# as an unhelpful "path not found" during import, which is why they are
# checked by exact path here rather than inferred.
REQUIRED_ROOT_ENTRIES = ["ics.json"]
REQUIRED_PROJECT_ENTRIES = [
    "PROJECT-INF/project.xml",
    "ics_project_attributes.properties",
]

# Anything matching these in a packaged file means a secret was committed.
SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key block"),
    (re.compile(r"-----BEGIN PGP PRIVATE KEY BLOCK-----"), "PGP private key"),
    (re.compile(r"\baws_secret_access_key\b", re.I), "AWS secret key"),
    (re.compile(r"\bpassword\s*[\"']?\s*[:=]\s*[\"'][^\"'${}\s][^\"']{5,}",
                re.I), "hard-coded password"),
    # The shape a leaked credential would actually take in this archive.
    # Every connection descriptor here is an OIC app instance, where a secret
    # is a property attribute pair - name="password" value="..." - and not a
    # key/value assignment, so the pattern above walks straight past it. A
    # ${PLACEHOLDER} value is the expected form and is excluded.
    (re.compile(r'name\s*=\s*"(?:password|passphrase|privateKey|'
                r'privateKeyPassword|clientSecret|secretKey|apiKey)"'
                r'\s+value\s*=\s*"(?!\$\{)[^"]{4,}"', re.I),
     "hard-coded password"),
]

# A US national identifier in a packaged artifact means test data was left in
# a lookup or a sample got swept into src/. This file exists to move that
# data; none of it belongs in the archive that describes how.
SSN_PATTERN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")

XML_SUFFIXES = (".xml", ".xsd", ".nxsd", ".xsl", ".wsdl")

# The record length every record in the Principal file pads to.
RECORD_LENGTH = 200

LAYOUT_MAP = "maps/map_canonical_to_principal.xsl"

# One table per record type the file contains. Checking that all three are
# present matters as much as checking the arithmetic in each: a heading that
# is renamed or deleted takes its whole table out of the parser's view, and
# every remaining table still adds up perfectly.
LAYOUT_RECORDS = ("header", "detail", "trailer")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.checks = 0

    def check(self, ok: bool, message: str, *, fatal: bool = True) -> bool:
        self.checks += 1
        if not ok:
            (self.errors if fatal else self.warnings).append(message)
        return ok


def parse_layout(source: str) -> dict[str, list[tuple[int, int, str]]]:
    """Pull the LAYOUT tables out of the formatting map's header comment.

    The tables are the layout's statement of itself: three columns of
    position, length and field name, one table per record type. Reading them
    back mechanically is what lets check_layout below assert that the document
    a reviewer reads and the file the map produces describe the same thing.
    """
    layouts: dict[str, list[tuple[int, int, str]]] = {}
    current: str | None = None
    row = re.compile(r"^\s*(\d+)[-\s]*\d*\s+(\d+)\s\s+(\S.*?)\s*$")

    for line in source.splitlines():
        heading = re.search(r"LAYOUT - (\w+)", line)
        if heading:
            current = heading.group(1)
            layouts[current] = []
            continue
        if current is None:
            continue
        if "-->" in line or "<xsl:" in line:
            current = None
            continue
        if "Pos" in line and "Len" in line:
            continue
        match = row.match(line)
        if match:
            layouts[current].append(
                (int(match.group(1)), int(match.group(2)), match.group(3)))
    return layouts


def check_layout(source: str, report: Report) -> None:
    """Every field contiguous, nothing overlapping, 200 characters exactly.

    A fixed-width layout has no delimiters to reveal a mistake. A field that
    starts one column early overlaps its neighbour; one that starts one column
    late leaves a gap that shifts nothing but silently blanks a character.
    Both import fine and both corrupt every record.
    """
    layouts = parse_layout(source)

    for expected in LAYOUT_RECORDS:
        report.check(
            expected in layouts,
            f"{LAYOUT_MAP} has no 'LAYOUT - {expected}' table; the layout is "
            f"no longer documented where the validator can check it",
        )

    for record_type, fields in layouts.items():
        if not report.check(bool(fields),
                            f"LAYOUT - {record_type} lists no fields"):
            continue

        position = 1
        for start, length, name in fields:
            report.check(
                start == position,
                f"LAYOUT - {record_type}: field '{name}' starts at {start} "
                f"but the previous field ends at {position - 1}, so it "
                f"{'overlaps' if start < position else 'leaves a gap'}",
            )
            position = start + length

        report.check(
            position - 1 == RECORD_LENGTH,
            f"LAYOUT - {record_type}: fields cover {position - 1} characters, "
            f"not {RECORD_LENGTH}",
        )


def validate(path: str) -> Report:
    report = Report()

    if not zipfile.is_zipfile(path):
        report.errors.append(f"{path} is not a ZIP archive")
        return report

    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        report.check(bad is None, f"corrupt entry in archive: {bad}")

        names = archive.namelist()

        for required in REQUIRED_ROOT_ENTRIES:
            report.check(required in names, f"missing required entry: {required}")

        # A path escaping the archive root is how a malicious .iar writes
        # outside the import directory.
        for name in names:
            report.check(
                not name.startswith("/") and ".." not in name.split("/"),
                f"unsafe path in archive: {name}",
            )

        # icspackage/project/<PROJECT>/... -> segment 2 is the project.
        project_dirs = {
            n.split("/")[2] for n in names
            if n.startswith("icspackage/project/") and len(n.split("/")) > 3
        }
        if not report.check(len(project_dirs) == 1,
                            f"expected exactly one project directory, "
                            f"found {sorted(project_dirs) or 'none'}"):
            return report
        project = project_dirs.pop()
        project_root = f"icspackage/project/{project}"

        for rel in REQUIRED_PROJECT_ENTRIES:
            report.check(f"{project_root}/{rel}" in names,
                         f"missing required entry: {project_root}/{rel}")

        descriptor = f"{project_root}/PROJECT-INF/project.xml"
        if descriptor not in names:
            # Nothing below can be cross-checked without it.
            return report

        # Identity must agree across the file name, the project directory,
        # ics.json and project.xml. Drift here is what makes an archive import
        # as an integration nobody recognises.
        if "ics.json" in names:
            try:
                manifest = json.loads(archive.read("ics.json"))
            except json.JSONDecodeError as exc:
                manifest = None
                report.check(False, f"ics.json is not valid JSON ({exc})")
            if manifest is not None:
                declared = manifest.get("integrations") or []
                report.check(len(declared) == 1,
                             f"ics.json declares {len(declared)} integrations, "
                             f"expected 1")
                if declared:
                    code = declared[0].get("code", "")
                    version = declared[0].get("version", "")
                    report.check(
                        project == f"{code}_{version}",
                        f"ics.json says {code}_{version} but the project "
                        f"directory is {project}",
                    )
                    report.check(
                        posixpath.basename(path) == f"{code}_{version}.iar",
                        f"file name {posixpath.basename(path)} does not match "
                        f"{code}_{version}.iar",
                        fatal=False,
                    )
                # Every connection ics.json names must have a descriptor.
                for conn in manifest.get("connections") or []:
                    conn_code = conn.get("code", "")
                    report.check(
                        f"icspackage/appinstances/{conn_code}.xml" in names,
                        f"ics.json declares connection {conn_code}, which has "
                        f"no descriptor under icspackage/appinstances/",
                    )
                # And every lookup. A missing lookup does not fail the import;
                # it fails at runtime, as an empty loan type on every row.
                for lookup in manifest.get("lookups") or []:
                    lookup_code = lookup.get("code", "")
                    report.check(
                        f"icspackage/lookups/{lookup_code}.xml" in names,
                        f"ics.json declares lookup {lookup_code}, which has "
                        f"no definition under icspackage/lookups/",
                    )

        # A scheduled integration with no schedule definition imports, then
        # silently never runs.
        try:
            pattern = ET.fromstring(archive.read(descriptor)).find(
                "{*}pattern")
            is_scheduled = pattern is not None and "SCHEDULED" in (
                pattern.text or "")
        except ET.ParseError:
            is_scheduled = False
        if is_scheduled:
            report.check(
                any(n.startswith("icspackage/schedule/") for n in names),
                "project.xml declares a scheduled pattern but the archive has "
                "no icspackage/schedule/ definition",
                fatal=False,
            )

        # Every XML artifact must parse. A map that fails to parse fails the
        # import with a far less helpful message than this one.
        for name in names:
            if not name.endswith(XML_SUFFIXES):
                continue
            try:
                ET.fromstring(archive.read(name))
                report.checks += 1
            except ET.ParseError as exc:
                report.errors.append(f"{name}: malformed XML ({exc})")

        # Every resource the descriptor declares must actually be packaged.
        # A malformed descriptor was already reported above; there is no tree
        # left to cross-check against, so stop rather than crash.
        try:
            root = ET.fromstring(archive.read(descriptor))
        except ET.ParseError:
            return report

        declared = [
            el.get("path") for el in root.iter()
            if el.tag.endswith("resource") and el.get("path")
        ]
        report.check(bool(declared), "project.xml declares no resources")
        for rel in declared:
            report.check(
                f"{project_root}/{rel}" in names,
                f"project.xml declares {rel}, which is not in the archive",
            )

        # And every connection and lookup the project binds to.
        for el in root.iter():
            if el.tag.endswith("appinstanceReference"):
                code = el.get("code", "")
                report.check(
                    f"icspackage/appinstances/{code}.xml" in names,
                    f"project.xml binds connection {code}, which has no "
                    f"descriptor under icspackage/appinstances/",
                )
            if el.tag.endswith("lookupReference"):
                code = el.get("code", "")
                report.check(
                    f"icspackage/lookups/{code}.xml" in names,
                    f"project.xml binds lookup {code}, which has no "
                    f"definition under icspackage/lookups/",
                )

        # Maps and the flow must not reference resources that were left out.
        packaged_basenames = {posixpath.basename(n) for n in names}
        for name in names:
            if not name.endswith((".xsl", ".json")):
                continue
            body = archive.read(name).decode("utf-8", errors="replace")
            for ref in re.findall(r"\.\./[\w/]+/([\w.-]+\.(?:xsl|xsd|nxsd))", body):
                report.check(
                    ref in packaged_basenames,
                    f"{name} references {ref}, which is not in the archive",
                )

        # Every lookup a map resolves must be packaged. dvm:lookupValue on a
        # lookup that does not exist returns the default on every row, so an
        # unpackaged lookup is not an error at runtime - it is a file full of
        # defaults, which is worse.
        for name in names:
            if not name.endswith(".xsl"):
                continue
            body = archive.read(name).decode("utf-8", errors="replace")
            for lookup in re.findall(r"dvm:lookupValue\(\s*'([A-Z0-9_]+)'", body):
                report.check(
                    f"icspackage/lookups/{lookup}.xml" in names,
                    f"{posixpath.basename(name)} resolves lookup {lookup}, "
                    f"which is not in the archive; every row would take the "
                    f"default",
                )

        # The fixed-width layout, from the map that owns it.
        layout_entry = next(
            (n for n in names if n.endswith(LAYOUT_MAP)), None)
        if report.check(layout_entry is not None,
                        f"{LAYOUT_MAP} is not in the archive"):
            check_layout(
                archive.read(layout_entry).decode("utf-8", errors="replace"),
                report)

        for name in names:
            body = archive.read(name).decode("utf-8", errors="replace")
            for pattern, label in SECRET_PATTERNS:
                if pattern.search(body):
                    report.errors.append(f"{name}: looks like a {label}")
            if SSN_PATTERN.search(body):
                report.errors.append(
                    f"{name}: contains something shaped like a national "
                    f"identifier")

    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("iar", help="path to the .iar to validate")
    args = parser.parse_args(argv)

    report = validate(args.iar)

    for warning in report.warnings:
        print(f"WARN  {warning}")
    for error in report.errors:
        print(f"ERROR {error}", file=sys.stderr)

    if report.errors:
        print(f"\nFAILED: {len(report.errors)} error(s) in {args.iar}",
              file=sys.stderr)
        return 1

    print(f"OK: {args.iar} passed {report.checks} checks"
          + (f" ({len(report.warnings)} warning(s))" if report.warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

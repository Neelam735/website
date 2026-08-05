#!/usr/bin/env python3
"""Check an .iar before it goes anywhere near an OIC instance.

OIC's import wizard is the only authority on whether an archive imports. This
catches the failures that are cheap to find first: a malformed archive, a
mismatched version, XML that does not parse, a map that references a schema
that is not in the package, or a credential that escaped review.

Usage:
    validate_iar.py dist/NEW_HIRE_LOAD_01.00.0000.iar
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
    (re.compile(r"\baws_secret_access_key\b", re.I), "AWS secret key"),
    (re.compile(r"\bpassword\s*[\"']?\s*[:=]\s*[\"'][^\"'${}\s][^\"']{5,}",
                re.I), "hard-coded password"),
]

XML_SUFFIXES = (".xml", ".xsd", ".nxsd", ".xsl", ".wsdl")


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

        # And every connection the project binds to.
        for el in root.iter():
            if el.tag.endswith("appinstanceReference"):
                code = el.get("code", "")
                report.check(
                    f"icspackage/appinstances/{code}.xml" in names,
                    f"project.xml binds connection {code}, which has no "
                    f"descriptor under icspackage/appinstances/",
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

        for name in names:
            body = archive.read(name).decode("utf-8", errors="replace")
            for pattern, label in SECRET_PATTERNS:
                if pattern.search(body):
                    report.errors.append(f"{name}: looks like a {label}")

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

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
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

REQUIRED_ENTRIES = [
    "META-INF/MANIFEST.MF",
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

        missing = [r for r in REQUIRED_ENTRIES if r not in names]
        for required in missing:
            report.check(False, f"missing required entry: {required}")
        if missing:
            # Everything below reads the manifest; without it there is nothing
            # further worth reporting.
            return report

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

        # Manifest version must agree with the directory name and file name.
        manifest = archive.read("META-INF/MANIFEST.MF").decode("utf-8")
        headers = dict(
            line.split(":", 1) for line in manifest.splitlines() if ":" in line
        )
        headers = {k.strip(): v.strip() for k, v in headers.items()}

        identifier = headers.get("ICS-Package-Identifier", "")
        version = headers.get("ICS-Package-Version", "")
        report.check(bool(identifier), "manifest has no ICS-Package-Identifier")
        report.check(bool(version), "manifest has no ICS-Package-Version")
        report.check(
            project == f"{identifier}_{version}",
            f"manifest says {identifier}_{version} but the project directory "
            f"is {project}",
        )
        report.check(
            posixpath.basename(path) == f"{identifier}_{version}.iar",
            f"file name {posixpath.basename(path)} does not match "
            f"{identifier}_{version}.iar",
            fatal=False,
        )

        descriptor = f"{project_root}/icspackage.xml"
        if not report.check(descriptor in names, f"missing {descriptor}"):
            return report

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
        report.check(bool(declared), "icspackage.xml declares no resources")
        for rel in declared:
            report.check(
                f"{project_root}/{rel}" in names,
                f"icspackage.xml declares {rel}, which is not in the archive",
            )

        # And every connection descriptor it points at.
        for el in root.iter():
            if el.tag.endswith("descriptor") and (el.text or "").strip():
                rel = el.text.strip()
                report.check(
                    f"{project_root}/{rel}" in names,
                    f"connection descriptor {rel} is not in the archive",
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

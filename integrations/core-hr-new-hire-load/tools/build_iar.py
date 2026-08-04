#!/usr/bin/env python3
"""Package the integration source tree into an OIC integration archive (.iar).

An .iar is a ZIP with a manifest and a project directory. This script builds
one from src/ so the archive is reproducible from version control rather than
being a binary someone once exported and dropped in a shared drive.

Reproducible means byte-identical across machines and runs: entries are sorted,
timestamps are fixed, and permissions are normalised. Two builds of the same
commit produce the same checksum, so "is deployed what we reviewed?" is a
question you can answer with sha256sum.

Usage:
    build_iar.py                       # -> dist/NEW_HIRE_LOAD_01.00.0000.iar
    build_iar.py --out /tmp/build
    build_iar.py --version 01.01.0000
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
SRC = os.path.join(PROJECT_ROOT, "src")

IDENTIFIER = "NEW_HIRE_LOAD"
DEFAULT_VERSION = "01.00.0000"

# Fixed DOS timestamp (1980-01-01 00:00:00), the ZIP epoch. Using the real
# mtime would make every rebuild a different file.
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)

EXCLUDED_NAMES = {".DS_Store", "Thumbs.db", "__pycache__"}
EXCLUDED_SUFFIXES = (".pyc", ".swp", "~")

# Files whose presence in the archive would mean a secret escaped review.
SECRET_SUFFIXES = (".pem", ".key", ".p12", ".jks", ".pfx")


def _included(path: str) -> bool:
    name = os.path.basename(path)
    if name in EXCLUDED_NAMES or name.startswith("."):
        return False
    return not name.endswith(EXCLUDED_SUFFIXES)


def collect(src_dir: str) -> list[tuple[str, str]]:
    """Return [(archive_name, absolute_path)] sorted for deterministic output."""
    entries: list[tuple[str, str]] = []
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = sorted(d for d in dirs if _included(os.path.join(root, d)))
        for filename in sorted(files):
            full = os.path.join(root, filename)
            if not _included(full):
                continue
            # ZIP entries always use forward slashes, on every platform.
            arcname = os.path.relpath(full, src_dir).replace(os.sep, "/")
            entries.append((arcname, full))
    return sorted(entries)


def check_no_secrets(entries: list[tuple[str, str]]) -> list[str]:
    """Refuse to ship key material. Connections carry placeholders only."""
    return [name for name, _ in entries if name.endswith(SECRET_SUFFIXES)]


def render_manifest(version: str) -> str:
    """MANIFEST.MF, written by us rather than copied.

    Keeping it generated means the version in the manifest can never drift
    from the version in the file name.
    """
    lines = [
        "Manifest-Version: 1.0",
        "Created-By: build_iar.py",
        f"ICS-Package-Identifier: {IDENTIFIER}",
        f"ICS-Package-Version: {version}",
        "ICS-Package-Type: INTEGRATION",
        "ICS-Package-Style: SCHEDULED_ORCHESTRATION",
    ]
    # A JAR manifest must end with a newline; some readers drop the last
    # header without it.
    return "\n".join(lines) + "\n"


def build(out_dir: str, version: str, src_dir: str = SRC) -> str:
    if not os.path.isdir(src_dir):
        raise SystemExit(f"source tree not found: {src_dir}")

    entries = collect(src_dir)
    if not entries:
        raise SystemExit(f"no files to package under {src_dir}")

    leaked = check_no_secrets(entries)
    if leaked:
        raise SystemExit(
            "refusing to build: key material in the source tree:\n  "
            + "\n  ".join(leaked)
        )

    project_dir = f"icspackage/project/{IDENTIFIER}_{version}"
    if not any(name.startswith(project_dir + "/") for name, _ in entries):
        raise SystemExit(
            f"no project directory '{project_dir}' in {src_dir}.\n"
            f"Rename the directory under src/icspackage/project/ to match "
            f"--version, or pass the version it already has."
        )

    os.makedirs(out_dir, exist_ok=True)
    iar_path = os.path.join(out_dir, f"{IDENTIFIER}_{version}.iar")

    with zipfile.ZipFile(iar_path, "w", zipfile.ZIP_DEFLATED) as archive:
        # The manifest goes in first, as JAR readers expect.
        info = zipfile.ZipInfo("META-INF/MANIFEST.MF", date_time=FIXED_TIMESTAMP)
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, render_manifest(version))

        for arcname, full in entries:
            if arcname == "META-INF/MANIFEST.MF":
                continue  # generated above; never copy a stale one
            info = zipfile.ZipInfo(arcname, date_time=FIXED_TIMESTAMP)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as handle:
                archive.writestr(info, handle.read())

    return iar_path


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.dirname(PROJECT_ROOT)), "dist"))
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--src", default=SRC)
    args = parser.parse_args(argv)

    iar_path = build(args.out, args.version, args.src)

    with zipfile.ZipFile(iar_path) as archive:
        count = len(archive.namelist())

    print(f"built    : {iar_path}")
    print(f"entries  : {count}")
    print(f"size     : {os.path.getsize(iar_path):,} bytes")
    print(f"sha256   : {sha256(iar_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

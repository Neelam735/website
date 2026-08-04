"""Tests for building and validating the .iar.

The validator's job is to fail on a bad archive, so most of these deliberately
corrupt a good one and assert the failure is caught.
"""

import os
import shutil
import sys
import unittest
import zipfile
from tempfile import TemporaryDirectory

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import build_iar  # noqa: E402
import validate_iar  # noqa: E402

SRC = os.path.join(os.path.dirname(__file__), "..", "src")
VERSION = build_iar.DEFAULT_VERSION
PROJECT = f"{build_iar.IDENTIFIER}_{VERSION}"


def build_into(tmp):
    return build_iar.build(tmp, VERSION, SRC)


def rewrite(original, tmp, *, drop=(), add=None, rename=None):
    """Copy an archive, optionally dropping, adding or renaming entries."""
    out = os.path.join(tmp, "modified.iar")
    with zipfile.ZipFile(original) as src, zipfile.ZipFile(out, "w") as dst:
        for item in src.namelist():
            if item in drop:
                continue
            target = rename.get(item, item) if rename else item
            dst.writestr(target, src.read(item))
        for name, body in (add or {}).items():
            dst.writestr(name, body)
    return out


class TestBuild(unittest.TestCase):

    def test_archive_is_a_valid_zip_with_the_expected_name(self):
        with TemporaryDirectory() as tmp:
            path = build_into(tmp)
            self.assertEqual(os.path.basename(path), f"{PROJECT}.iar")
            self.assertTrue(zipfile.is_zipfile(path))

    def test_manifest_is_the_first_entry(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                self.assertEqual(archive.namelist()[0], "META-INF/MANIFEST.MF")

    def test_manifest_version_tracks_the_requested_version(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                manifest = archive.read("META-INF/MANIFEST.MF").decode()
        self.assertIn(f"ICS-Package-Version: {VERSION}", manifest)
        self.assertIn(f"ICS-Package-Identifier: {build_iar.IDENTIFIER}", manifest)
        self.assertTrue(manifest.endswith("\n"))

    def test_build_is_byte_identical_across_runs(self):
        with TemporaryDirectory() as one, TemporaryDirectory() as two:
            self.assertEqual(build_iar.sha256(build_into(one)),
                             build_iar.sha256(build_into(two)))

    def test_entries_are_sorted(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                body = archive.namelist()[1:]  # manifest is pinned first
        self.assertEqual(body, sorted(body))

    def test_all_timestamps_are_fixed(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                stamps = {i.date_time for i in archive.infolist()}
        self.assertEqual(stamps, {build_iar.FIXED_TIMESTAMP})

    def test_junk_files_are_excluded(self):
        with TemporaryDirectory() as tmp:
            staged = os.path.join(tmp, "src")
            shutil.copytree(SRC, staged)
            noise = os.path.join(staged, "icspackage", "project", PROJECT)
            open(os.path.join(noise, ".DS_Store"), "w").close()
            open(os.path.join(noise, "notes.txt~"), "w").close()

            with zipfile.ZipFile(build_iar.build(tmp, VERSION, staged)) as archive:
                names = archive.namelist()
        self.assertFalse([n for n in names if ".DS_Store" in n or n.endswith("~")])

    def test_build_refuses_to_package_key_material(self):
        with TemporaryDirectory() as tmp:
            staged = os.path.join(tmp, "src")
            shutil.copytree(SRC, staged)
            key = os.path.join(staged, "icspackage", "project", PROJECT,
                               "connections", "sftp.pem")
            with open(key, "w") as handle:
                handle.write("placeholder")
            with self.assertRaises(SystemExit) as ctx:
                build_iar.build(tmp, VERSION, staged)
        self.assertIn("key material", str(ctx.exception))

    def test_version_mismatch_with_the_project_directory_is_refused(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as ctx:
                build_iar.build(tmp, "09.09.9999", SRC)
        self.assertIn("no project directory", str(ctx.exception))

    def test_missing_source_tree_is_refused(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                build_iar.build(tmp, VERSION, os.path.join(tmp, "absent"))


class TestValidateAcceptsAGoodArchive(unittest.TestCase):

    def test_freshly_built_archive_passes(self):
        with TemporaryDirectory() as tmp:
            report = validate_iar.validate(build_into(tmp))
        self.assertEqual(report.errors, [])
        self.assertGreater(report.checks, 20)

    def test_every_declared_resource_is_actually_present(self):
        # Guards against the descriptor and the tree drifting apart.
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = set(archive.namelist())
                import xml.etree.ElementTree as ET
                root = ET.fromstring(
                    archive.read(f"icspackage/project/{PROJECT}/icspackage.xml"))
        declared = [el.get("path") for el in root.iter()
                    if el.tag.endswith("resource") and el.get("path")]
        self.assertGreaterEqual(len(declared), 10)
        for rel in declared:
            self.assertIn(f"icspackage/project/{PROJECT}/{rel}", names)


class TestValidateRejectsBadArchives(unittest.TestCase):

    def assertRejected(self, path, fragment):
        report = validate_iar.validate(path)
        self.assertTrue(report.errors, f"expected an error mentioning {fragment}")
        self.assertTrue(
            any(fragment in e for e in report.errors),
            f"expected {fragment!r} in {report.errors}",
        )

    def test_not_a_zip(self):
        with TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "broken.iar")
            with open(path, "w") as handle:
                handle.write("not a zip")
            self.assertRejected(path, "not a ZIP")

    def test_missing_manifest(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp, drop=("META-INF/MANIFEST.MF",))
            self.assertRejected(path, "META-INF/MANIFEST.MF")

    def test_manifest_version_disagreeing_with_the_project_directory(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp,
                           drop=("META-INF/MANIFEST.MF",),
                           add={"META-INF/MANIFEST.MF":
                                "Manifest-Version: 1.0\n"
                                "ICS-Package-Identifier: NEW_HIRE_LOAD\n"
                                "ICS-Package-Version: 02.00.0000\n"})
            self.assertRejected(path, "project directory")

    def test_declared_resource_missing_from_the_archive(self):
        with TemporaryDirectory() as tmp:
            target = (f"icspackage/project/{PROJECT}/resources/processor_10/"
                      "resourcegroup_10/maps/map_canonical_to_hdl.xsl")
            path = rewrite(build_into(tmp), tmp, drop=(target,))
            self.assertRejected(path, "map_canonical_to_hdl.xsl")

    def test_malformed_xml_is_caught(self):
        with TemporaryDirectory() as tmp:
            target = f"icspackage/project/{PROJECT}/icspackage.xml"
            path = rewrite(build_into(tmp), tmp, drop=(target,),
                           add={target: "<icspackage><unclosed></icspackage>"})
            self.assertRejected(path, "malformed XML")

    def test_path_traversal_entry_is_caught(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp,
                           add={"../escaped.txt": "x"})
            self.assertRejected(path, "unsafe path")

    def test_private_key_in_the_archive_is_caught(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(
                build_into(tmp), tmp,
                add={f"icspackage/project/{PROJECT}/connections/leaked":
                     "-----BEGIN RSA PRIVATE KEY-----\nabc\n"})
            self.assertRejected(path, "private key")

    def test_hard_coded_password_is_caught(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(
                build_into(tmp), tmp,
                add={f"icspackage/project/{PROJECT}/connections/oops.json":
                     '{"password": "hunter2secret"}'})
            self.assertRejected(path, "hard-coded password")

    def test_placeholder_credentials_are_not_flagged(self):
        # The shipped connection descriptors use ${...} placeholders; the
        # secret scan must tolerate them or it cries wolf on every build.
        with TemporaryDirectory() as tmp:
            report = validate_iar.validate(build_into(tmp))
        self.assertEqual(report.errors, [])

    def test_two_project_directories_are_rejected(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp,
                           add={"icspackage/project/OTHER_01.00.0000/x.xml":
                                "<x/>"})
            self.assertRejected(path, "exactly one project directory")


if __name__ == "__main__":
    unittest.main()

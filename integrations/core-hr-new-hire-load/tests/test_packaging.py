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


# The paths OIC's importer resolves. Getting one of these wrong is what
# produced "path not found" on the first attempt to import.
REQUIRED_PATHS = [
    "ics.json",
    f"icspackage/project/{PROJECT}/PROJECT-INF/project.xml",
    f"icspackage/project/{PROJECT}/ics_project_attributes.properties",
]


class TestBuild(unittest.TestCase):

    def test_archive_is_a_valid_zip_with_the_expected_name(self):
        with TemporaryDirectory() as tmp:
            path = build_into(tmp)
            self.assertEqual(os.path.basename(path), f"{PROJECT}.iar")
            self.assertTrue(zipfile.is_zipfile(path))

    def test_layout_matches_what_the_importer_resolves(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = set(archive.namelist())
        for required in REQUIRED_PATHS:
            self.assertIn(required, names)

    def test_ics_json_is_the_first_entry(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                self.assertEqual(archive.namelist()[0], "ics.json")

    def test_every_connection_has_an_appinstance_descriptor(self):
        import json
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = set(archive.namelist())
                manifest = json.loads(archive.read("ics.json"))
        self.assertEqual(len(manifest["connections"]), 3)
        for conn in manifest["connections"]:
            self.assertIn(f"icspackage/appinstances/{conn['code']}.xml", names)

    def test_ics_json_identity_matches_the_project_directory(self):
        import json
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                manifest = json.loads(archive.read("ics.json"))
        declared = manifest["integrations"][0]
        self.assertEqual(f"{declared['code']}_{declared['version']}", PROJECT)

    def test_scheduled_integration_ships_a_schedule_definition(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = archive.namelist()
        self.assertTrue([n for n in names
                         if n.startswith("icspackage/schedule/")])

    def test_no_stale_layout_left_behind(self):
        # The first attempt used these paths and OIC rejected it. Nothing
        # should reintroduce them.
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = archive.namelist()
        self.assertFalse([n for n in names if n.startswith("META-INF/")])
        self.assertFalse([n for n in names if n.endswith("/icspackage.xml")])
        self.assertFalse([n for n in names if "/connections/" in n])

    def test_build_is_byte_identical_across_runs(self):
        with TemporaryDirectory() as one, TemporaryDirectory() as two:
            self.assertEqual(build_iar.sha256(build_into(one)),
                             build_iar.sha256(build_into(two)))

    def test_entries_are_sorted(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                body = archive.namelist()[1:]  # ics.json is pinned first
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
            key = os.path.join(staged, "icspackage", "appinstances", "sftp.pem")
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
                root = ET.fromstring(archive.read(
                    f"icspackage/project/{PROJECT}/PROJECT-INF/project.xml"))
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

    def test_missing_ics_json(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp, drop=("ics.json",))
            self.assertRejected(path, "ics.json")

    def test_missing_project_xml(self):
        with TemporaryDirectory() as tmp:
            target = f"icspackage/project/{PROJECT}/PROJECT-INF/project.xml"
            path = rewrite(build_into(tmp), tmp, drop=(target,))
            self.assertRejected(path, "PROJECT-INF/project.xml")

    def test_missing_project_attributes(self):
        with TemporaryDirectory() as tmp:
            target = (f"icspackage/project/{PROJECT}/"
                      "ics_project_attributes.properties")
            path = rewrite(build_into(tmp), tmp, drop=(target,))
            self.assertRejected(path, "ics_project_attributes.properties")

    def test_ics_json_version_disagreeing_with_the_project_directory(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp, drop=("ics.json",),
                           add={"ics.json": '{"integrations": [{"code": '
                                '"NEW_HIRE_LOAD", "version": "02.00.0000"}]}'})
            self.assertRejected(path, "project directory")

    def test_connection_without_a_descriptor_is_caught(self):
        with TemporaryDirectory() as tmp:
            target = "icspackage/appinstances/HCM_CORE_HR.xml"
            path = rewrite(build_into(tmp), tmp, drop=(target,))
            self.assertRejected(path, "HCM_CORE_HR")

    def test_malformed_ics_json_is_caught(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(build_into(tmp), tmp, drop=("ics.json",),
                           add={"ics.json": "{not json"})
            self.assertRejected(path, "not valid JSON")

    def test_declared_resource_missing_from_the_archive(self):
        with TemporaryDirectory() as tmp:
            target = (f"icspackage/project/{PROJECT}/resources/processor_10/"
                      "resourcegroup_10/maps/map_canonical_to_hdl.xsl")
            path = rewrite(build_into(tmp), tmp, drop=(target,))
            self.assertRejected(path, "map_canonical_to_hdl.xsl")

    def test_malformed_xml_is_caught(self):
        with TemporaryDirectory() as tmp:
            target = f"icspackage/project/{PROJECT}/PROJECT-INF/project.xml"
            path = rewrite(build_into(tmp), tmp, drop=(target,),
                           add={target: "<project><unclosed></project>"})
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
                add={f"icspackage/appinstances/leaked":
                     "-----BEGIN RSA PRIVATE KEY-----\nabc\n"})
            self.assertRejected(path, "private key")

    def test_hard_coded_password_is_caught(self):
        with TemporaryDirectory() as tmp:
            path = rewrite(
                build_into(tmp), tmp,
                add={f"icspackage/appinstances/oops.json":
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

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
RESOURCES = (f"icspackage/project/{PROJECT}/resources/processor_10/"
             f"resourcegroup_10")


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
# produces "path not found" on import.
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
                names = archive.namelist()
            for required in REQUIRED_PATHS:
                self.assertIn(required, names)

    def test_ics_json_is_the_first_entry(self):
        """It is the archive's table of contents and OIC reads it first."""
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                self.assertEqual(archive.namelist()[0], "ics.json")

    def test_every_connection_and_lookup_is_packaged(self):
        with TemporaryDirectory() as tmp:
            with zipfile.ZipFile(build_into(tmp)) as archive:
                names = archive.namelist()
            for code in ["HCM_PRINCIPAL_401K", "SFTP_PRINCIPAL_401K",
                         "SMTP_NOTIFY"]:
                self.assertIn(f"icspackage/appinstances/{code}.xml", names)
            for code in ["PFG_401K_LOAN_TYPE", "PFG_401K_LOAN_STATUS",
                         "PFG_401K_CONTRACT", "PFG_401K_SOURCE_CODE"]:
                self.assertIn(f"icspackage/lookups/{code}.xml", names)

    def test_builds_are_reproducible(self):
        """Same commit, same bytes, so a checksum recorded with the change
        ticket proves later that what is deployed is what was reviewed."""
        with TemporaryDirectory() as first, TemporaryDirectory() as second:
            self.assertEqual(build_iar.sha256(build_into(first)),
                             build_iar.sha256(build_into(second)))

    def test_identity_comes_from_the_manifest(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as raised:
                build_iar.build(tmp, "09.99.9999", SRC)
            self.assertIn("ics.json", str(raised.exception))

    def test_refuses_to_package_key_material(self):
        """The PGP key belongs in the OIC certificate store. A key file in
        the tree means somebody was about to skip that step."""
        with TemporaryDirectory() as tmp:
            staged = os.path.join(tmp, "src")
            shutil.copytree(SRC, staged)
            with open(os.path.join(staged, "principal.asc"), "w") as handle:
                handle.write("-----BEGIN PGP PUBLIC KEY BLOCK-----\n")
            with self.assertRaises(SystemExit) as raised:
                build_iar.build(tmp, VERSION, staged)
            self.assertIn("key material", str(raised.exception))

    def test_refuses_to_build_without_the_project_descriptor(self):
        with TemporaryDirectory() as tmp:
            staged = os.path.join(tmp, "src")
            shutil.copytree(SRC, staged)
            os.remove(os.path.join(
                staged, "icspackage", "project", PROJECT, "PROJECT-INF",
                "project.xml"))
            with self.assertRaises(SystemExit) as raised:
                build_iar.build(tmp, VERSION, staged)
            self.assertIn("project.xml", str(raised.exception))


class TestValidateAcceptsAGoodArchive(unittest.TestCase):

    def test_the_built_archive_passes(self):
        with TemporaryDirectory() as tmp:
            report = validate_iar.validate(build_into(tmp))
            self.assertEqual(report.errors, [])
            self.assertEqual(report.warnings, [])
            self.assertGreater(report.checks, 50)


class TestValidateRejectsABadArchive(unittest.TestCase):

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.good = build_into(self.tmp.name)

    def assert_error_mentioning(self, path, fragment):
        report = validate_iar.validate(path)
        self.assertTrue(
            any(fragment in error for error in report.errors),
            f"expected an error mentioning {fragment!r}, got {report.errors}")

    def test_not_a_zip(self):
        path = os.path.join(self.tmp.name, "not.iar")
        with open(path, "w") as handle:
            handle.write("this is not an archive")
        self.assert_error_mentioning(path, "not a ZIP")

    def test_missing_manifest(self):
        path = rewrite(self.good, self.tmp.name, drop=["ics.json"])
        self.assert_error_mentioning(path, "ics.json")

    def test_missing_project_descriptor(self):
        path = rewrite(self.good, self.tmp.name,
                       drop=[f"icspackage/project/{PROJECT}/PROJECT-INF/"
                             f"project.xml"])
        self.assert_error_mentioning(path, "project.xml")

    def test_a_declared_resource_that_is_not_packaged(self):
        path = rewrite(self.good, self.tmp.name,
                       drop=[f"{RESOURCES}/maps/map_status_to_summary.xsl"])
        self.assert_error_mentioning(path, "map_status_to_summary.xsl")

    def test_a_bound_connection_with_no_descriptor(self):
        path = rewrite(self.good, self.tmp.name,
                       drop=["icspackage/appinstances/SFTP_PRINCIPAL_401K.xml"])
        self.assert_error_mentioning(path, "SFTP_PRINCIPAL_401K")

    def test_a_bound_lookup_with_no_definition(self):
        """Not an import failure - dvm:lookupValue on a missing lookup
        returns the default on every row, so this ships a file of defaults."""
        path = rewrite(self.good, self.tmp.name,
                       drop=["icspackage/lookups/PFG_401K_LOAN_TYPE.xml"])
        self.assert_error_mentioning(path, "PFG_401K_LOAN_TYPE")

    def test_malformed_xml(self):
        path = rewrite(self.good, self.tmp.name,
                       add={f"{RESOURCES}/maps/broken.xsl": "<not-closed>"})
        self.assert_error_mentioning(path, "malformed XML")

    def test_identity_drift_between_manifest_and_project_directory(self):
        renames = {
            name: name.replace(PROJECT, f"{build_iar.IDENTIFIER}_02.00.0000")
            for name in zipfile.ZipFile(self.good).namelist()
            if PROJECT in name
        }
        path = rewrite(self.good, self.tmp.name, rename=renames)
        self.assert_error_mentioning(path, "project directory")

    def test_a_path_escaping_the_archive_root(self):
        path = rewrite(self.good, self.tmp.name,
                       add={"../escaped.xml": "<a/>"})
        self.assert_error_mentioning(path, "unsafe path")

    def test_a_hard_coded_password(self):
        path = rewrite(self.good, self.tmp.name, add={
            "icspackage/appinstances/LEAKY.xml":
                '<a><property name="password" value="hunter2xyz"/></a>'})
        self.assert_error_mentioning(path, "hard-coded password")

    def test_a_private_key(self):
        path = rewrite(self.good, self.tmp.name, add={
            "icspackage/leaked.xml":
                "-----BEGIN PGP PRIVATE KEY BLOCK-----"})
        self.assert_error_mentioning(path, "PGP private key")

    def test_a_national_identifier_left_in_a_packaged_artifact(self):
        """Test data in a lookup, or a sample swept into src/. This file
        exists to move that data; none of it belongs in the archive that
        describes how."""
        path = rewrite(self.good, self.tmp.name, add={
            "icspackage/lookups/PFG_401K_TEST.xml":
                "<lookup><row>123-45-6789</row></lookup>"})
        self.assert_error_mentioning(path, "national identifier")


class TestFlowAndDescriptorAgree(unittest.TestCase):
    """`project.xml` says it mirrors the flow step for step. Check it does.

    Two files describing one orchestration drift the moment somebody edits
    one, and the drift is invisible: OIC imports a descriptor missing an
    activity perfectly well, and the flow file is documentation that nothing
    executes. What is left is a reviewer reading a description of an
    integration that is not the one running.
    """

    def setUp(self):
        import json
        import xml.etree.ElementTree as ET

        project_root = os.path.join(
            SRC, "icspackage", "project", PROJECT)
        with open(os.path.join(
                project_root, "resources", "processor_10", "resourcegroup_10",
                "flow", "PRINCIPAL_401K_LOANS.flow.json"),
                encoding="utf-8") as handle:
            self.flow = json.load(handle)
        self.descriptor = ET.parse(os.path.join(
            project_root, "PROJECT-INF", "project.xml")).getroot()

    def flow_activity_ids(self):
        found = set()

        def walk(node):
            if isinstance(node, dict):
                if "id" in node and "type" in node:
                    found.add(node["id"])
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(self.flow)
        return found

    def descriptor_activity_ids(self):
        return {element.get("id") for element in self.descriptor.iter()
                if element.tag.endswith("activity")}

    def test_the_same_activities_appear_in_both(self):
        in_flow = self.flow_activity_ids()
        in_descriptor = self.descriptor_activity_ids()
        self.assertEqual(
            in_flow - in_descriptor, set(),
            "activities in the flow that project.xml does not declare")
        self.assertEqual(
            in_descriptor - in_flow, set(),
            "activities project.xml declares that the flow does not have")

    def test_both_bind_the_same_connections(self):
        in_flow = {connection["ref"] for connection in self.flow["connections"]}
        in_descriptor = {element.get("code")
                         for element in self.descriptor.iter()
                         if element.tag.endswith("appinstanceReference")}
        self.assertEqual(in_flow, in_descriptor)

    def test_both_reference_the_same_lookups(self):
        in_flow = {lookup["ref"] for lookup in self.flow["lookups"]}
        in_descriptor = {element.get("code")
                         for element in self.descriptor.iter()
                         if element.tag.endswith("lookupReference")}
        self.assertEqual(in_flow, in_descriptor)

    def test_every_map_the_flow_uses_is_a_declared_resource(self):
        declared = {os.path.basename(element.get("path"))
                    for element in self.descriptor.iter()
                    if element.tag.endswith("resource") and element.get("path")}

        used = set()

        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key == "map" and isinstance(value, str):
                        used.add(os.path.basename(value))
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(self.flow)
        self.assertTrue(used, "the flow uses no maps, which cannot be right")
        self.assertEqual(used - declared, set())


class TestLayoutValidation(unittest.TestCase):
    """The check no importer would ever make: that the columns add up."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.good = build_into(self.tmp.name)
        self.layout_path = f"{RESOURCES}/maps/map_canonical_to_principal.xsl"
        with zipfile.ZipFile(self.good) as archive:
            self.source = archive.read(self.layout_path).decode("utf-8")

    def test_the_real_layout_parses_into_three_records(self):
        layouts = validate_iar.parse_layout(self.source)
        self.assertEqual(sorted(layouts), ["detail", "header", "trailer"])
        for record_type, fields in layouts.items():
            self.assertGreater(len(fields), 5, record_type)

    def test_the_real_layout_is_contiguous_and_complete(self):
        report = validate_iar.Report()
        validate_iar.check_layout(self.source, report)
        self.assertEqual(report.errors, [])

    def _corrupt(self, old, new):
        path = rewrite(self.good, self.tmp.name, drop=[self.layout_path],
                       add={self.layout_path: self.source.replace(old, new, 1)})
        return validate_iar.validate(path)

    def test_an_overlapping_field_is_caught(self):
        # Detail: loan number at 67 becomes 66, overlapping the middle
        # initial. Every field after it would read one character early.
        report = self._corrupt("     67-76    10  Loan number",
                               "     66-76    10  Loan number")
        self.assertTrue(any("overlaps" in error for error in report.errors),
                        report.errors)

    def test_a_gap_between_fields_is_caught(self):
        report = self._corrupt("     67-76    10  Loan number",
                               "     68-76    10  Loan number")
        self.assertTrue(any("leaves a gap" in error for error in report.errors),
                        report.errors)

    def test_a_record_that_does_not_reach_200_is_caught(self):
        report = self._corrupt("    159-200   42  Filler",
                               "    159-190   32  Filler")
        self.assertTrue(any("not 200" in error for error in report.errors),
                        report.errors)

    def test_removing_the_layout_tables_is_caught(self):
        """The tables are how the layout is reviewable. Deleting them is not
        a documentation change."""
        report = self._corrupt("LAYOUT - header", "Formerly the header")
        self.assertTrue(report.errors)


if __name__ == "__main__":
    unittest.main()

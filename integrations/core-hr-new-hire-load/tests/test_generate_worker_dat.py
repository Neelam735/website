"""Tests for the Worker.dat mapping.

Run: python3 -m unittest discover -s integrations/core-hr-new-hire-load/tests
"""

import csv
import os
import sys
import unittest
import zipfile
from tempfile import TemporaryDirectory

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "tools")
)

from generate_worker_dat import (  # noqa: E402
    BUSINESS_OBJECTS,
    END_OF_TIME,
    SOURCE_SYSTEM_OWNER,
    build,
    write_output,
)

SAMPLE_CSV = os.path.join(
    os.path.dirname(__file__), "..", "hdl", "samples", "newhire_sample.csv"
)


def base_row(**overrides):
    row = {
        "EmployeeNumber": "100501",
        "FirstName": "Jane",
        "MiddleName": "A",
        "LastName": "Doe",
        "Title": "MS.",
        "DateOfBirth": "1992-03-14",
        "Gender": "F",
        "MaritalStatus": "M",
        "EmailAddress": "jane.doe@example.com",
        "PhoneCountryCode": "1",
        "PhoneAreaCode": "415",
        "PhoneNumber": "5550142",
        "AddressLine1": "120 Market Street",
        "City": "San Francisco",
        "State": "CA",
        "PostalCode": "94105",
        "Country": "US",
        "HireDate": "2026-08-17",
        "LegalEmployerName": "Vision Corporation US",
        "LegislationCode": "US",
        "BusinessUnit": "VC_US_BU",
        "JobCode": "SE_III",
    }
    row.update(overrides)
    return row


def rows_of(dat_text):
    """Split a rendered .dat into (metadata_attrs, [merge_row_dicts])."""
    lines = [l for l in dat_text.splitlines() if l]
    attrs = lines[0].split("|")[2:]
    parsed = [dict(zip(attrs, l.split("|")[2:])) for l in lines[1:]]
    return attrs, parsed


class TestStructure(unittest.TestCase):
    def test_one_row_produces_all_nine_objects(self):
        result = build([base_row()])
        self.assertEqual(result.accepted, 1)
        self.assertEqual(result.rejected, 0)
        for obj in BUSINESS_OBJECTS:
            self.assertIn(f"{obj}.dat", result.files, f"{obj}.dat missing")

    def test_files_are_emitted_in_dependency_order(self):
        result = build([base_row()])
        emitted = [f[: -len(".dat")] for f in result.files]
        self.assertEqual(emitted, BUSINESS_OBJECTS)

    def test_every_file_starts_with_metadata_then_merge(self):
        result = build([base_row()])
        for name, text in result.files.items():
            lines = text.splitlines()
            self.assertTrue(lines[0].startswith("METADATA|"), name)
            for line in lines[1:]:
                self.assertTrue(line.startswith("MERGE|"), name)

    def test_column_count_matches_metadata_on_every_row(self):
        result = build([base_row(), base_row(EmployeeNumber="100502")])
        for name, text in result.files.items():
            lines = text.splitlines()
            width = len(lines[0].split("|"))
            for line in lines[1:]:
                self.assertEqual(len(line.split("|")), width, name)


class TestMapping(unittest.TestCase):
    def test_child_rows_reference_the_worker_source_system_id(self):
        result = build([base_row()])
        _, worker = rows_of(result.files["Worker.dat"])
        person_ssid = worker[0]["SourceSystemId"]
        self.assertEqual(person_ssid, "WKR_100501")

        for name in ("PersonName", "PersonEmail", "PersonAddress",
                     "WorkRelationship", "WorkTerms", "Assignment"):
            _, parsed = rows_of(result.files[f"{name}.dat"])
            self.assertEqual(
                parsed[0]["PersonId(SourceSystemId)"], person_ssid, name
            )

    def test_assignment_chains_through_work_terms_and_work_relationship(self):
        result = build([base_row()])
        _, wr = rows_of(result.files["WorkRelationship.dat"])
        _, wt = rows_of(result.files["WorkTerms.dat"])
        _, asg = rows_of(result.files["Assignment.dat"])

        self.assertEqual(wt[0]["PeriodOfServiceId(SourceSystemId)"],
                         wr[0]["SourceSystemId"])
        self.assertEqual(asg[0]["WorkTermsAssignmentId(SourceSystemId)"],
                         wt[0]["SourceSystemId"])
        self.assertEqual(asg[0]["PeriodOfServiceId(SourceSystemId)"],
                         wr[0]["SourceSystemId"])

    def test_effective_dated_rows_end_at_end_of_time(self):
        result = build([base_row()])
        for name in ("Worker", "PersonName", "PersonLegislativeData",
                     "PersonAddress", "WorkTerms", "Assignment"):
            _, parsed = rows_of(result.files[f"{name}.dat"])
            self.assertEqual(parsed[0]["EffectiveEndDate"], END_OF_TIME, name)

    def test_source_system_owner_is_stamped_everywhere(self):
        result = build([base_row()])
        for name, text in result.files.items():
            _, parsed = rows_of(text)
            for row in parsed:
                self.assertEqual(row["SourceSystemOwner"],
                                 SOURCE_SYSTEM_OWNER, name)

    def test_mapping_is_deterministic_across_runs(self):
        self.assertEqual(build([base_row()]).files,
                         build([base_row()]).files)


class TestDateHandling(unittest.TestCase):
    def test_alternative_source_formats_normalise_to_iso(self):
        for supplied in ("17-Aug-2026", "08/17/2026", "20260817", "2026-08-17"):
            result = build([base_row(HireDate=supplied)])
            _, worker = rows_of(result.files["Worker.dat"])
            self.assertEqual(worker[0]["StartDate"], "2026-08-17", supplied)

    def test_unparseable_date_rejects_the_row(self):
        result = build([base_row(HireDate="not-a-date")])
        self.assertEqual(result.accepted, 0)
        self.assertIn("not a recognised date", result.errors[0].message)


class TestValidation(unittest.TestCase):
    def test_missing_required_field_rejects_only_that_row(self):
        result = build([
            base_row(),
            base_row(EmployeeNumber="100502", LastName=""),
            base_row(EmployeeNumber="100503"),
        ])
        self.assertEqual(result.accepted, 2)
        self.assertEqual(result.rejected, 1)
        self.assertEqual(result.errors[0].employee_number, "100502")
        self.assertIn("LastName is required", result.errors[0].message)

    def test_duplicate_employee_number_is_rejected(self):
        result = build([base_row(), base_row()])
        self.assertEqual(result.accepted, 1)
        self.assertIn("duplicate EmployeeNumber", result.errors[0].message)

    def test_reported_line_numbers_account_for_the_header(self):
        result = build([base_row(FirstName=""), base_row(EmployeeNumber="2")])
        self.assertEqual(result.errors[0].row_number, 2)

    def test_embedded_delimiter_cannot_shift_columns(self):
        result = build([base_row(AddressLine1="12|Market St")])
        _, addr = rows_of(result.files["PersonAddress.dat"])
        self.assertEqual(addr[0]["AddressLine1"], "12 Market St")
        self.assertEqual(addr[0]["PostalCode"], "94105")

    def test_embedded_newline_cannot_add_a_row(self):
        result = build([base_row(LastName="Doe\nSmith")])
        _, names = rows_of(result.files["PersonName.dat"])
        self.assertEqual(len(names), 1)
        self.assertEqual(names[0]["LastName"], "Doe Smith")


class TestOptionalObjects(unittest.TestCase):
    def test_optional_files_are_omitted_when_no_row_supplies_them(self):
        row = base_row()
        for optional in ("EmailAddress", "PhoneNumber", "AddressLine1",
                         "Gender", "MaritalStatus"):
            row[optional] = ""
        result = build([row])
        for name in ("PersonEmail", "PersonPhone", "PersonAddress",
                     "PersonLegislativeData"):
            self.assertNotIn(f"{name}.dat", result.files, name)
        # The mandatory backbone still loads.
        for name in ("Worker", "PersonName", "WorkRelationship",
                     "WorkTerms", "Assignment"):
            self.assertIn(f"{name}.dat", result.files, name)

    def test_partial_optional_data_only_emits_rows_that_exist(self):
        result = build([
            base_row(),
            base_row(EmployeeNumber="100502", EmailAddress=""),
        ])
        _, emails = rows_of(result.files["PersonEmail.dat"])
        self.assertEqual(len(emails), 1)
        self.assertEqual(emails[0]["PersonId(SourceSystemId)"], "WKR_100501")


class TestOutput(unittest.TestCase):
    def test_zip_is_flat_with_no_directory_entries(self):
        result = build([base_row()])
        with TemporaryDirectory() as tmp:
            zip_path = write_output(result, tmp, make_zip=True)
            with zipfile.ZipFile(zip_path) as archive:
                names = archive.namelist()
        self.assertTrue(all("/" not in n for n in names), names)
        self.assertEqual(sorted(names),
                         sorted(f"{o}.dat" for o in BUSINESS_OBJECTS))

    def test_rejects_csv_written_only_when_rows_fail(self):
        with TemporaryDirectory() as tmp:
            write_output(build([base_row()]), tmp, make_zip=False)
            self.assertFalse(os.path.exists(os.path.join(tmp, "rejects.csv")))

        with TemporaryDirectory() as tmp:
            write_output(build([base_row(FirstName="")]), tmp, make_zip=False)
            path = os.path.join(tmp, "rejects.csv")
            self.assertTrue(os.path.exists(path))
            with open(path, newline="", encoding="utf-8") as handle:
                reject_rows = list(csv.DictReader(handle))
            self.assertEqual(reject_rows[0]["EmployeeNumber"], "100501")


class TestSampleExtract(unittest.TestCase):
    def test_shipped_sample_loads_cleanly(self):
        with open(SAMPLE_CSV, newline="", encoding="utf-8-sig") as handle:
            result = build(csv.DictReader(handle))
        self.assertEqual(result.rejected, 0, [e.message for e in result.errors])
        self.assertEqual(result.accepted, 5)

    def test_sample_covers_multiple_legal_employers(self):
        with open(SAMPLE_CSV, newline="", encoding="utf-8-sig") as handle:
            result = build(csv.DictReader(handle))
        _, wr = rows_of(result.files["WorkRelationship.dat"])
        self.assertGreater(len({r["LegalEmployerName"] for r in wr}), 1)


if __name__ == "__main__":
    unittest.main()

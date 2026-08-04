"""End-to-end check that the OIC maps and the reference implementation agree.

The XSLT is what actually runs in OIC; generate_worker_dat.py is what we can
test cheaply and read easily. They only stay honest if something asserts they
produce the same bytes, which is what this module does:

    CSV row  --(build csv-namespace XML, as the nXSD reader would)-->
             --map_csv_to_canonical.xsl-->  canonical XML
             --map_canonical_to_hdl.xsl-->  .dat text     ==  Python output

Skipped when lxml is unavailable, so the suite still runs on a bare
interpreter. Install it with `pip install lxml` to get the coverage.
"""

import csv
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from generate_worker_dat import BUSINESS_OBJECTS, build  # noqa: E402

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    etree = None

HERE = os.path.dirname(__file__)
MAPS = os.path.join(
    HERE, "..", "src", "icspackage", "project", "NEW_HIRE_LOAD_01.00.0000",
    "resources", "processor_10", "resourcegroup_10", "maps",
)
SAMPLE_CSV = os.path.join(HERE, "..", "hdl", "samples", "newhire_sample.csv")

CSV_NS = "http://xmlns.oracle.com/hcm/newhire/csv"
DAT_NS = "http://xmlns.oracle.com/hcm/hdl/dat"

# The nXSD reader emits one element per column, in file order.
CSV_COLUMNS = [
    "EmployeeNumber", "FirstName", "MiddleName", "LastName", "Title",
    "DateOfBirth", "Gender", "MaritalStatus", "EmailAddress",
    "PhoneCountryCode", "PhoneAreaCode", "PhoneNumber", "AddressLine1",
    "AddressLine2", "City", "State", "PostalCode", "Country", "HireDate",
    "LegalEmployerName", "LegislationCode", "BusinessUnit", "JobCode",
    "GradeCode", "DepartmentName", "LocationCode", "PositionCode",
    "WorkerType", "AssignmentCategory", "NormalHours", "Frequency",
    "ManagerFlag", "ActionCode",
]


def csv_rows_to_xml(rows):
    """Reproduce what the Stage File read action hands to the first map."""
    root = etree.Element("{%s}NewHireExtract" % CSV_NS, nsmap={"csv": CSV_NS})
    for row in rows:
        hire = etree.SubElement(root, "{%s}NewHire" % CSV_NS)
        for column in CSV_COLUMNS:
            etree.SubElement(hire, "{%s}%s" % (CSV_NS, column)).text = \
                row.get(column, "") or ""
    return etree.ElementTree(root)


def run_pipeline(rows):
    """Run both maps and return {'Worker.dat': text, ...}, as OIC would."""
    to_canonical = etree.XSLT(etree.parse(
        os.path.join(MAPS, "map_csv_to_canonical.xsl")))
    to_hdl = etree.XSLT(etree.parse(
        os.path.join(MAPS, "map_canonical_to_hdl.xsl")))

    canonical = to_canonical(
        csv_rows_to_xml(rows),
        batchId=etree.XSLT.strparam("PARITY"),
        sourceFileName=etree.XSLT.strparam("parity.csv"),
    )

    files = {}
    for obj in BUSINESS_OBJECTS:
        result = to_hdl(canonical, object=etree.XSLT.strparam(obj))
        lines = [
            el.text or "" for el in
            result.getroot().findall("{%s}Line" % DAT_NS)
        ]
        if lines:
            files[f"{obj}.dat"] = "\n".join(lines) + "\n"
    return files


def base_row(**overrides):
    row = {
        "EmployeeNumber": "100501", "FirstName": "Jane", "MiddleName": "A",
        "LastName": "Doe", "Title": "MS.", "DateOfBirth": "1992-03-14",
        "Gender": "F", "MaritalStatus": "M",
        "EmailAddress": "jane.doe@example.com", "PhoneCountryCode": "1",
        "PhoneAreaCode": "415", "PhoneNumber": "5550142",
        "AddressLine1": "120 Market Street", "City": "San Francisco",
        "State": "CA", "PostalCode": "94105", "Country": "US",
        "HireDate": "2026-08-17", "LegalEmployerName": "Vision Corporation US",
        "LegislationCode": "US", "BusinessUnit": "VC_US_BU",
        "JobCode": "SE_III",
    }
    row.update(overrides)
    return row


@unittest.skipIf(etree is None, "lxml not installed")
class TestXsltParity(unittest.TestCase):

    def assertParity(self, rows, msg=""):
        expected = build([dict(r) for r in rows]).files
        actual = run_pipeline(rows)
        self.assertEqual(sorted(actual), sorted(expected),
                         f"different .dat files emitted {msg}")
        for name in expected:
            self.assertEqual(actual[name], expected[name],
                             f"{name} differs {msg}")

    def test_single_row(self):
        self.assertParity([base_row()])

    def test_shipped_sample_extract(self):
        with open(SAMPLE_CSV, newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))
        self.assertParity(rows)

    def test_sparse_row_omits_the_same_optional_files(self):
        row = base_row()
        for optional in ("EmailAddress", "PhoneNumber", "AddressLine1",
                         "Gender", "MaritalStatus", "DateOfBirth",
                         "MiddleName", "Title", "PositionCode"):
            row[optional] = ""
        self.assertParity([row], "(sparse row)")

    def test_defaults_agree(self):
        row = base_row(WorkerType="", ActionCode="", ManagerFlag="")
        self.assertParity([row], "(defaulted fields)")

    def test_alternate_date_formats_agree(self):
        for supplied in ("17-Aug-2026", "08/17/2026", "20260817"):
            self.assertParity([base_row(HireDate=supplied)], f"({supplied})")

    def test_lowercase_legislation_is_uppercased_by_both(self):
        self.assertParity([base_row(LegislationCode="us")])

    def test_missing_country_falls_back_to_legislation_in_both(self):
        self.assertParity([base_row(Country="")])

    def test_embedded_delimiter_sanitised_identically(self):
        self.assertParity([base_row(AddressLine1="12|Market  St")],
                          "(embedded pipe)")

    def test_invalid_rows_dropped_identically(self):
        rows = [
            base_row(),
            base_row(EmployeeNumber="100502", LastName=""),
            base_row(EmployeeNumber="100503", HireDate="not-a-date"),
            base_row(EmployeeNumber="100504"),
        ]
        self.assertParity(rows, "(mixed valid/invalid)")

    def test_date_shaped_junk_rejected_by_both(self):
        # 10 chars with dashes in the right places but not digits: the shape
        # check alone would let this through into a .dat file.
        for junk in ("abcd-ef-gh", "20xx-01-02", "2026/01/02"):
            self.assertParity([base_row(HireDate=junk)], f"({junk})")

    def test_bad_optional_date_rejects_row_in_both(self):
        self.assertParity([base_row(DateOfBirth="abcd-ef-gh")], "(bad DOB)")

    def test_duplicate_person_number_dropped_identically(self):
        self.assertParity([base_row(), base_row(), base_row(EmployeeNumber="X")],
                          "(duplicates)")

    def test_no_valid_rows_produces_no_files_in_either(self):
        self.assertParity([base_row(FirstName="")], "(all invalid)")


@unittest.skipIf(etree is None, "lxml not installed")
class TestMapsAreWellFormed(unittest.TestCase):
    def test_every_map_compiles(self):
        for name in sorted(os.listdir(MAPS)):
            if name.endswith(".xsl"):
                with self.subTest(map=name):
                    etree.XSLT(etree.parse(os.path.join(MAPS, name)))


if __name__ == "__main__":
    unittest.main()

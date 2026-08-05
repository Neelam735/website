"""End-to-end check that the OIC maps and the reference implementation agree.

The XSLT is what actually runs in OIC; generate_principal_file.py is what we
can test cheaply and read easily. They only stay honest if something asserts
they produce the same bytes, which is what this module does:

    extract XML  --map_extract_to_canonical.xsl-->   canonical batch
                 --map_canonical_to_principal.xsl--> 200-char records
                                                        ==  Python output

The one piece OIC supplies at runtime and libxslt does not is
`dvm:lookupValue`. Rather than stubbing it, it is registered here as a real
XPath extension function backed by the same lookup XML that is packaged into
the archive - so a passing run also proves the maps and the packaged lookups
agree, and a lookup row deleted from the archive fails the suite.

Skipped when lxml is unavailable, so the suite still runs on a bare
interpreter. Install it with `pip install lxml` to get the coverage.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from generate_principal_file import (  # noqa: E402
    Lookups, build_canonical, format_file,
)

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    etree = None

HERE = os.path.dirname(__file__)
MAPS = os.path.join(
    HERE, "..", "src", "icspackage", "project", "PRINCIPAL_401K_LOANS_01.00.0000",
    "resources", "processor_10", "resourcegroup_10", "maps",
)
SAMPLE = os.path.join(HERE, "..", "samples", "extract_output_sample.xml")

EXT_NS = "http://xmlns.oracle.com/hcm/principal401k/extract"
CAN_NS = "http://xmlns.oracle.com/hcm/principal401k/canonical"
PFG_NS = "http://xmlns.oracle.com/hcm/principal401k/file"
DVM_NS = "http://xmlns.oracle.com/dvm"

CREATION_DATE = "20260302"
CREATION_TIME = "050000"


def register_dvm(lookups):
    """Back OIC's dvm:lookupValue with the packaged lookup definitions.

    Signature matches the runtime's: (name, sourceColumn, sourceValue,
    targetColumn, defaultValue). Only the ORACLE_HCM -> PRINCIPAL direction is
    implemented, because that is the only direction the maps use; an
    unexpected column pair raises rather than silently returning the default,
    since a silent default is exactly the bug this function would otherwise
    hide.
    """
    tables = {
        "PFG_401K_LOAN_TYPE": lookups.loan_type,
        "PFG_401K_LOAN_STATUS": lookups.loan_status,
        "PFG_401K_CONTRACT": lookups.contract,
        "PFG_401K_SOURCE_CODE": lookups.source_code,
    }

    def lookup_value(_context, name, source_column, source_value,
                     target_column, default_value):
        if (source_column, target_column) != ("ORACLE_HCM", "PRINCIPAL"):
            raise AssertionError(
                f"unexpected lookup direction {source_column} -> "
                f"{target_column} on {name}")
        if name not in tables:
            raise AssertionError(f"no packaged lookup named {name}")
        # XPath string arguments arrive as str; a node-set argument would
        # arrive as a list, which the maps never pass.
        key = (source_value or "").strip()
        return tables[name].get(key, default_value)

    namespace = etree.FunctionNamespace(DVM_NS)
    namespace["lookupValue"] = lookup_value


def run_maps(extract_path, ssn_policy="FULL", contract_override=None):
    """Run both maps over an extract, as OIC would, and return the records."""
    to_canonical = etree.XSLT(etree.parse(
        os.path.join(MAPS, "map_extract_to_canonical.xsl")))
    to_principal = etree.XSLT(etree.parse(
        os.path.join(MAPS, "map_canonical_to_principal.xsl")))

    canonical = to_canonical(
        etree.parse(extract_path),
        runId=etree.XSLT.strparam("PARITY"),
        ssnPolicy=etree.XSLT.strparam(ssn_policy),
        sourceCodeDefault=etree.XSLT.strparam("RG"),
    )

    contract = contract_override
    if contract is None:
        found = canonical.getroot().find(f"{{{CAN_NS}}}ContractNumber")
        contract = (found.text or "") if found is not None else ""

    formatted = to_principal(
        canonical,
        contractNumber=etree.XSLT.strparam(contract),
        senderId=etree.XSLT.strparam("ACMECORP"),
        fileVersion=etree.XSLT.strparam("001"),
        testProductionFlag=etree.XSLT.strparam("T"),
        fileCreationDate=etree.XSLT.strparam(CREATION_DATE),
        fileCreationTime=etree.XSLT.strparam(CREATION_TIME),
    )

    return canonical, [
        element.text or ""
        for element in formatted.getroot().iter(f"{{{PFG_NS}}}Line")
    ]


def run_python(extract_path, ssn_policy="FULL", contract_override=None):
    root = etree.parse(extract_path).getroot()
    # ElementTree and lxml disagree about nothing that matters here, but the
    # reference implementation is written against the stdlib parser, so it
    # gets the stdlib parser.
    import xml.etree.ElementTree as ET
    batch = build_canonical(ET.parse(extract_path).getroot(), Lookups.load(),
                            ssn_policy)
    if contract_override is not None:
        batch.contract_number = contract_override
    del root
    return batch, format_file(
        batch, sender_id="ACMECORP", file_version="001",
        test_production_flag="T", creation_date=CREATION_DATE,
        creation_time=CREATION_TIME,
    )


def write_extract(tmp_path, employees, employer="ACME Corporation US",
                  period_end="2026-02-28", check_date="2026-03-05"):
    """Build a minimal extract document around a list of employee fragments."""
    body = "\n".join(employees)
    document = f"""<?xml version="1.0" encoding="UTF-8"?>
<DATA_DS xmlns="{EXT_NS}">
  <PERIOD_END_DATE>{period_end}</PERIOD_END_DATE>
  <CHECK_DATE>{check_date}</CHECK_DATE>
  <G_LEGAL_EMPLOYER>
    <LEGAL_EMPLOYER_NAME>{employer}</LEGAL_EMPLOYER_NAME>
{body}
  </G_LEGAL_EMPLOYER>
</DATA_DS>
"""
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(document)
    return tmp_path


def employee(number="100501", national_id="123456789", last="Smith",
             first="John", middle="", termination="", loans=None):
    loan_nodes = "\n".join(loans or [loan()])
    termination_tag = (f"      <TERMINATION_DATE>{termination}</TERMINATION_DATE>\n"
                       if termination else "")
    return f"""    <G_EMPLOYEE>
      <PERSON_NUMBER>{number}</PERSON_NUMBER>
      <NATIONAL_ID>{national_id}</NATIONAL_ID>
      <LAST_NAME>{last}</LAST_NAME>
      <FIRST_NAME>{first}</FIRST_NAME>
      <MIDDLE_NAMES>{middle}</MIDDLE_NAMES>
      <ASSIGNMENT_STATUS>ACTIVE</ASSIGNMENT_STATUS>
{termination_tag}{loan_nodes}
    </G_EMPLOYEE>"""


def loan(element="401k Loan Repayment General", number="LN00000001",
         repayment="100.00", payoff="0.00", outstanding="900.00",
         origination="2025-01-01", last_payment="2026-03-05",
         status="ACTIVE", payroll="US Semi-Monthly Payroll",
         period_end="", check_date=""):
    optional = ""
    if period_end:
        optional += f"        <PERIOD_END_DATE>{period_end}</PERIOD_END_DATE>\n"
    if check_date:
        optional += f"        <CHECK_DATE>{check_date}</CHECK_DATE>\n"
    return f"""      <G_LOAN>
        <ELEMENT_NAME>{element}</ELEMENT_NAME>
        <LOAN_NUMBER>{number}</LOAN_NUMBER>
        <LOAN_ORIGINATION_DATE>{origination}</LOAN_ORIGINATION_DATE>
        <ORIGINAL_LOAN_AMOUNT>1000.00</ORIGINAL_LOAN_AMOUNT>
        <REPAYMENT_AMOUNT>{repayment}</REPAYMENT_AMOUNT>
        <PAYOFF_AMOUNT>{payoff}</PAYOFF_AMOUNT>
        <OUTSTANDING_BALANCE>{outstanding}</OUTSTANDING_BALANCE>
        <LAST_PAYMENT_DATE>{last_payment}</LAST_PAYMENT_DATE>
        <LOAN_STATUS>{status}</LOAN_STATUS>
        <PAYROLL_NAME>{payroll}</PAYROLL_NAME>
{optional}      </G_LOAN>"""


@unittest.skipIf(etree is None, "lxml not installed")
class TestParity(unittest.TestCase):
    """Both implementations, same input, same bytes."""

    @classmethod
    def setUpClass(cls):
        register_dvm(Lookups.load())

    def assert_parity(self, path, ssn_policy="FULL"):
        _, xslt_records = run_maps(path, ssn_policy)
        _, python_records = run_python(path, ssn_policy)

        self.assertEqual(len(xslt_records), len(python_records),
                         "record counts differ")
        for index, (from_xslt, from_python) in enumerate(
                zip(xslt_records, python_records)):
            self.assertEqual(
                from_xslt, from_python,
                f"record {index} differs\n"
                f"  xslt  : {from_xslt!r}\n"
                f"  python: {from_python!r}")
        return python_records

    def test_the_full_sample_extract(self):
        records = self.assert_parity(SAMPLE)
        # 1 header + 12 details + 1 trailer; the other five loans reject.
        self.assertEqual(len(records), 14)

    def test_masked_national_identifiers(self):
        self.assert_parity(SAMPLE, ssn_policy="MASKED")

    def _parity_case(self, name, employees, **kwargs):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as tmp:
            path = write_extract(os.path.join(tmp, f"{name}.xml"),
                                 employees, **kwargs)
            return self.assert_parity(path)

    def test_no_loans_at_all(self):
        """Header and trailer only - the SEND_EMPTY case."""
        records = self._parity_case("empty", [])
        self.assertEqual(len(records), 2)
        self.assertTrue(records[0].startswith("H"))
        self.assertTrue(records[1].startswith("T"))

    def test_negative_and_zero_amounts(self):
        self._parity_case("signs", [
            employee(number="1", loans=[loan(repayment="-156.25")]),
            employee(number="2", loans=[loan(repayment="0.00",
                                             outstanding="0.00")]),
            employee(number="3", loans=[loan(repayment="0",
                                             outstanding="-12.34")]),
        ])

    def test_amounts_with_awkward_decimals(self):
        """The cases where float arithmetic and string surgery diverge."""
        self._parity_case("decimals", [
            employee(number=str(index), loans=[loan(repayment=value)])
            for index, value in enumerate(
                ["12.34", "0.1", ".5", "5.", "1000", "8.005", "99.999",
                 "1,234.56", "$78.90", "-0.00", "0.005"])
        ])

    def test_names_needing_folding_and_truncation(self):
        self._parity_case("names", [
            employee(number="1", last="Fernández—Villalobos",
                     first="José Ángel", middle="Íñigo"),
            employee(number="2", last="O'Brien-Smythe", first="Mary Jo"),
            employee(number="3", last="Ålesund", first="Ægir", middle="Ø"),
            employee(number="4",
                     last="Wolfeschlegelsteinhausenbergerdorff",
                     first="Maximilianaaaaaaaaaaaa"),
            employee(number="5", last="  Spaced   Out  ", first=" A  B "),
        ])

    def test_national_identifier_shapes(self):
        self._parity_case("ids", [
            employee(number="1", national_id="123-45-6789"),
            employee(number="2", national_id="12345678"),
            employee(number="3", national_id="1"),
            employee(number="4", national_id=" 987 65 4321 "),
        ])

    def test_dates_missing_and_malformed(self):
        self._parity_case("dates", [
            employee(number="1", loans=[loan(last_payment="")]),
            employee(number="2", loans=[loan(origination="not-a-date")]),
            employee(number="3", loans=[loan(last_payment="2026-03-05T09:00:00")]),
            employee(number="4", termination="2026-02-20"),
        ])

    def test_loan_level_period_overrides_the_batch(self):
        self._parity_case("periods", [
            employee(number="1", loans=[loan(period_end="2026-02-14",
                                             check_date="2026-02-18",
                                             payroll="US Off-Cycle Payroll")]),
        ])

    def test_every_reject_reason(self):
        self._parity_case("rejects", [
            employee(number="1", loans=[loan(number="")]),
            employee(number="2", loans=[loan(element="401k Loan Repayment Hardship")]),
            employee(number="3", national_id=""),
            employee(number="4", last=""),
            employee(number="5", loans=[loan(outstanding="1234567890.00")]),
        ])

    def test_unmapped_legal_employer_rejects_every_row(self):
        records = self._parity_case("employer", [employee()],
                                    employer="Not In The Lookup")
        self.assertEqual(len(records), 2, "header and trailer only")


@unittest.skipIf(etree is None, "lxml not installed")
class TestRecountParity(unittest.TestCase):
    """The reconciliation is implemented twice as well.

    map_file_to_reconciliation.xsl runs at step 136; reconcile() in the
    reference implementation does the same job. Both parse the amounts back
    out of the formatted records, and neither is allowed to consult the
    canonical batch to do it - so they have to be checked against each other
    rather than against the thing they exist to check.
    """

    @classmethod
    def setUpClass(cls):
        register_dvm(Lookups.load())
        cls.recount = etree.XSLT(etree.parse(
            os.path.join(MAPS, "map_file_to_reconciliation.xsl")))

    def recount_xslt(self, records):
        """Returns the four values as strings.

        Not as ints: an unreadable amount column yields NaN by design, so that
        it propagates through sum() and makes step 140's comparison fail.
        Coercing it here would hide the very behaviour these tests check.
        """
        document = etree.Element(f"{{{PFG_NS}}}LoanFile",
                                 nsmap={"pfg": PFG_NS})
        for record in records:
            etree.SubElement(document, f"{{{PFG_NS}}}Line").text = record
        result = self.recount(etree.ElementTree(document)).getroot()
        read = lambda name: result.findtext(  # noqa: E731
            "{http://xmlns.oracle.com/hcm/principal401k/reconciliation}" + name)
        return (read("ActualDetailCount"), read("ActualRepaymentCents"),
                read("ActualOutstandingCents"), read("RecordLengths"))

    def test_the_sample_file(self):
        from generate_principal_file import reconcile
        batch, records = run_python(SAMPLE)
        count, repayment, outstanding, lengths = self.recount_xslt(records)
        check = reconcile(records, batch)

        self.assertEqual(count, str(check.detail_count))
        self.assertEqual(repayment, str(check.repayment_cents))
        self.assertEqual(outstanding, str(check.outstanding_cents))
        self.assertEqual(lengths, "200")

    def test_both_agree_the_sample_reconciles(self):
        from generate_principal_file import reconcile
        batch, records = run_python(SAMPLE)
        count, repayment, outstanding, _ = self.recount_xslt(records)
        self.assertTrue(reconcile(records, batch).reconciled)
        self.assertEqual(count, str(batch.detail_count))
        self.assertEqual(repayment, str(batch.total_repayment_cents))
        self.assertEqual(outstanding, str(batch.total_outstanding_cents))

    def test_both_catch_a_shifted_amount_column(self):
        """The defect the whole check exists for.

        The two disagree about *how* they catch it, and that is fine. The
        reference sums a mis-parsed number; the XSLT reads a column that is no
        longer numeric and produces NaN. Neither equals the trailer, which is
        the only thing step 140 asks.
        """
        from generate_principal_file import reconcile
        batch, records = run_python(SAMPLE)
        damaged = list(records)
        damaged[1] = damaged[1][:78] + " " + damaged[1][78:-1]

        self.assertFalse(reconcile(damaged, batch).reconciled)
        _, repayment, _, _ = self.recount_xslt(damaged)
        self.assertNotEqual(repayment, str(batch.total_repayment_cents))

    def test_a_dropped_detail_row_is_caught_by_both(self):
        from generate_principal_file import reconcile
        batch, records = run_python(SAMPLE)
        damaged = records[:3] + records[4:]

        self.assertFalse(reconcile(damaged, batch).reconciled)
        count, _, _, _ = self.recount_xslt(damaged)
        self.assertNotEqual(count, str(batch.detail_count))

    def test_the_xslt_notices_a_record_of_the_wrong_length(self):
        """Damage in a name column sums correctly; only the length shows it.

        The reference reconcile() checks counts and totals, so this case is
        the XSLT's alone - which is exactly why the flow compares
        RecordLengths as well as the totals.
        """
        _, records = run_python(SAMPLE)
        damaged = list(records)
        damaged[2] = damaged[2][:150]
        _, _, _, lengths = self.recount_xslt(damaged)
        self.assertNotEqual(lengths, "200")
        self.assertIn("150", lengths)

    def test_an_empty_file_recounts_to_zero(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as tmp:
            path = write_extract(os.path.join(tmp, "empty.xml"), [])
            _, records = run_python(path)
        count, repayment, outstanding, lengths = self.recount_xslt(records)
        self.assertEqual((count, repayment, outstanding), ("0", "0", "0"))
        self.assertEqual(lengths, "200")


@unittest.skipIf(etree is None, "lxml not installed")
class TestLookupsAreShared(unittest.TestCase):
    """The maps and the packaged lookups must resolve the same values."""

    @classmethod
    def setUpClass(cls):
        register_dvm(Lookups.load())

    def test_residential_elements_map_to_loan_type_02(self):
        canonical, _ = run_maps(SAMPLE)
        types = {
            node.findtext(f"{{{CAN_NS}}}LoanNumber"):
                node.findtext(f"{{{CAN_NS}}}LoanTypeCode")
            for node in canonical.getroot().iter(f"{{{CAN_NS}}}Loan")
        }
        self.assertEqual(types["LN00022002"], "02",
                         "the residential loan should carry Principal's "
                         "residential loan type code")
        self.assertEqual(types["LN00022001"], "01")

    def test_off_cycle_payroll_uses_its_own_source_code(self):
        canonical, _ = run_maps(SAMPLE)
        codes = {
            node.findtext(f"{{{CAN_NS}}}LoanNumber"):
                node.findtext(f"{{{CAN_NS}}}SourceCode")
            for node in canonical.getroot().iter(f"{{{CAN_NS}}}Loan")
        }
        self.assertEqual(codes["LN00070440"], "OC")
        self.assertEqual(codes["LN00012345"], "SM")


if __name__ == "__main__":
    unittest.main()

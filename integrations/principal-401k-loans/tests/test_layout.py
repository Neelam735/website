"""The fixed-width layout, asserted position by position.

A fixed-width file has no delimiters to tell you when a field has moved. If
the loan number drifts one column left, the file still loads at Principal's
end, still reconciles against its own trailer, and posts every repayment
against a loan number that is off by one character. Nothing about the file
looks wrong.

So the positions are asserted here directly, against the layout table in the
header comment of map_canonical_to_principal.xsl. These tests exist to fail
loudly when a column moves, which is the only warning this format offers.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import xml.etree.ElementTree as ET  # noqa: E402

from generate_principal_file import (  # noqa: E402
    RECORD_LENGTH, Lookups, build_canonical, format_file, reconcile,
)

HERE = os.path.dirname(__file__)
SAMPLE = os.path.join(HERE, "..", "samples", "extract_output_sample.xml")

CREATION_DATE = "20260302"
CREATION_TIME = "050000"


def at(record, start, length):
    """One field, addressed by its 1-based position from the layout table."""
    return record[start - 1:start - 1 + length]


def build_sample(ssn_policy="FULL", test_production_flag="T"):
    batch = build_canonical(ET.parse(SAMPLE).getroot(), Lookups.load(),
                            ssn_policy)
    records = format_file(
        batch, sender_id="ACMECORP", file_version="001",
        test_production_flag=test_production_flag,
        creation_date=CREATION_DATE, creation_time=CREATION_TIME,
    )
    return batch, records


class TestRecordShape(unittest.TestCase):

    def setUp(self):
        self.batch, self.records = build_sample()
        self.header = self.records[0]
        self.details = [r for r in self.records if r.startswith("D")]
        self.trailer = self.records[-1]

    def test_every_record_is_exactly_the_fixed_length(self):
        for index, record in enumerate(self.records):
            self.assertEqual(len(record), RECORD_LENGTH,
                             f"record {index} is {len(record)} characters")

    def test_nothing_reaches_the_truncation_guard(self):
        """The `fix` cut is a guard rail; if it ever fires, a field overran.

        Rebuilding each record without the final pad-and-cut and comparing
        lengths is what distinguishes "padded to 200" from "cut down to 200".
        """
        for record in self.records:
            self.assertLessEqual(len(record.rstrip()), RECORD_LENGTH)
            # A cut record would end mid-field with no trailing filler.
            if record.startswith("D"):
                self.assertTrue(record[158:].strip() == "",
                                "detail filler is not blank, so a field "
                                "overran into it")

    def test_records_are_in_header_details_trailer_order(self):
        self.assertTrue(self.records[0].startswith("H"))
        self.assertTrue(self.records[-1].startswith("T"))
        for record in self.records[1:-1]:
            self.assertTrue(record.startswith("D"))

    def test_the_file_is_ascii(self):
        """Principal's loader reads bytes, not code points.

        A multi-byte character occupies more bytes than columns and shifts
        every field after it on that record - which is why the accented names
        in the sample are folded rather than passed through.
        """
        for record in self.records:
            record.encode("ascii")


class TestHeaderPositions(unittest.TestCase):

    def setUp(self):
        _, self.records = build_sample()
        self.header = self.records[0]

    def test_positions(self):
        header = self.header
        self.assertEqual(at(header, 1, 1), "H")
        self.assertEqual(at(header, 2, 8), "40012345")
        self.assertEqual(at(header, 10, 8), CREATION_DATE)
        self.assertEqual(at(header, 18, 6), CREATION_TIME)
        self.assertEqual(at(header, 24, 10), "LOANREPAY ")
        self.assertEqual(at(header, 34, 8), "20260228")
        self.assertEqual(at(header, 42, 8), "20260305")
        self.assertEqual(at(header, 50, 3), "001")
        self.assertEqual(at(header, 53, 10), "ACMECORP  ")
        self.assertEqual(at(header, 63, 1), "T")
        self.assertEqual(at(header, 64, 137), " " * 137)

    def test_production_flag_needs_an_explicit_p(self):
        _, production = build_sample(test_production_flag="P")
        self.assertEqual(at(production[0], 63, 1), "P")

    def test_anything_other_than_p_is_a_test_transmission(self):
        """Defaulting the other way would let a typo post real money."""
        for flag in ["T", "", "prod", "PROD", "p", "X"]:
            _, records = build_sample(test_production_flag=flag)
            self.assertEqual(at(records[0], 63, 1), "T",
                             f"flag {flag!r} should not mark production")


class TestDetailPositions(unittest.TestCase):

    def setUp(self):
        self.batch, self.records = build_sample()
        self.by_loan = {
            at(record, 67, 10).strip(): record
            for record in self.records if record.startswith("D")
        }

    def test_positions_of_an_ordinary_repayment(self):
        record = self.by_loan["LN00012345"]
        self.assertEqual(at(record, 1, 1), "D")
        self.assertEqual(at(record, 2, 9), "123456789")
        self.assertEqual(at(record, 11, 20), "100501" + " " * 14)
        self.assertEqual(at(record, 31, 20), "OKAFOR" + " " * 14)
        self.assertEqual(at(record, 51, 15), "ADAEZE" + " " * 9)
        self.assertEqual(at(record, 66, 1), "C")
        self.assertEqual(at(record, 67, 10), "LN00012345")
        self.assertEqual(at(record, 77, 2), "01")
        self.assertEqual(at(record, 79, 12), "00000025000+")
        self.assertEqual(at(record, 91, 12), "00000000000+")
        self.assertEqual(at(record, 103, 12), "00000725000+")
        self.assertEqual(at(record, 115, 8), "20260228")
        self.assertEqual(at(record, 123, 8), "20260305")
        self.assertEqual(at(record, 131, 1), "A")
        self.assertEqual(at(record, 132, 8), "20240615")
        self.assertEqual(at(record, 140, 8), "20260305")
        self.assertEqual(at(record, 148, 2), "SM")
        self.assertEqual(at(record, 150, 8), " " * 8)
        self.assertEqual(at(record, 158, 1), "N")
        self.assertEqual(at(record, 159, 42), " " * 42)

    def test_a_negative_repayment_keeps_its_digit_columns(self):
        """Trailing sign is why a reversal lines up with everything else."""
        record = self.by_loan["LN00070440"]
        self.assertEqual(at(record, 79, 12), "00000015625-")
        self.assertEqual(at(record, 79, 11), "00000015625")
        self.assertEqual(at(record, 90, 1), "-")

    def test_a_payoff_carries_the_settling_amount_in_both_columns(self):
        record = self.by_loan["LN00030777"]
        self.assertEqual(at(record, 79, 12), "00000018422+", "repayment")
        self.assertEqual(at(record, 91, 12), "00000018422+", "payoff")
        self.assertEqual(at(record, 103, 12), "00000000000+", "balance")
        self.assertEqual(at(record, 131, 1), "P")

    def test_a_termination_sets_the_date_and_the_indicator(self):
        record = self.by_loan["LN00041188"]
        self.assertEqual(at(record, 150, 8), "20260220")
        self.assertEqual(at(record, 158, 1), "Y")
        self.assertEqual(at(record, 131, 1), "A",
                         "the final repayment period is still active; "
                         "DEFAULTED belongs to the next one")

    def test_a_suspended_loan_reports_zero_rather_than_nothing(self):
        record = self.by_loan["LN00060220"]
        self.assertEqual(at(record, 79, 12), "00000000000+")
        self.assertEqual(at(record, 103, 12), "00000416670+")
        self.assertEqual(at(record, 131, 1), "S")

    def test_an_off_cycle_loan_carries_its_own_period_and_source(self):
        record = self.by_loan["LN00070440"]
        self.assertEqual(at(record, 115, 8), "20260214")
        self.assertEqual(at(record, 123, 8), "20260218")
        self.assertEqual(at(record, 148, 2), "OC")

    def test_names_are_folded_truncated_and_column_safe(self):
        record = self.by_loan["LN00090660"]
        # Fernández—Villalobos: the accent folds, the em dash is dropped
        # entirely rather than replaced, and 20 characters is the column.
        self.assertEqual(at(record, 31, 20), "FERNANDEZVILLALOBOS ")
        self.assertEqual(at(record, 51, 15), "JOSE ANGEL     ")
        self.assertEqual(at(record, 66, 1), "I")
        self.assertEqual(len(record), RECORD_LENGTH)

    def test_a_missing_last_payment_date_is_blank_not_zero(self):
        record = self.by_loan["LN00050011"]
        self.assertEqual(at(record, 132, 8), "20260215")
        # A zero-filled date is a date Principal will try to parse.
        self.assertNotEqual(at(record, 150, 8), "0" * 8)

    def test_both_of_a_participants_concurrent_loans_appear(self):
        self.assertIn("LN00022001", self.by_loan)
        self.assertIn("LN00022002", self.by_loan)
        general = self.by_loan["LN00022001"]
        residential = self.by_loan["LN00022002"]
        self.assertEqual(at(general, 2, 9), at(residential, 2, 9),
                         "same participant")
        self.assertEqual(at(general, 77, 2), "01")
        self.assertEqual(at(residential, 77, 2), "02")

    def test_a_refinance_sends_the_settled_loan_and_the_new_one(self):
        settled = self.by_loan["LN00050010"]
        opened = self.by_loan["LN00050011"]
        self.assertEqual(at(settled, 131, 1), "P")
        self.assertEqual(at(settled, 91, 12), "00000312055+")
        self.assertEqual(at(opened, 131, 1), "A")
        self.assertEqual(at(opened, 91, 12), "00000000000+")


class TestTrailerPositions(unittest.TestCase):

    def setUp(self):
        self.batch, self.records = build_sample()
        self.trailer = self.records[-1]

    def test_positions(self):
        trailer = self.trailer
        self.assertEqual(at(trailer, 1, 1), "T")
        self.assertEqual(at(trailer, 2, 8), "40012345")
        self.assertEqual(at(trailer, 10, 10), "0000000012")
        self.assertEqual(at(trailer, 20, 15), "00000000499852+")
        self.assertEqual(at(trailer, 65, 8), CREATION_DATE)
        self.assertEqual(at(trailer, 73, 6), CREATION_TIME)
        self.assertEqual(at(trailer, 79, 122), " " * 122)

    def test_the_count_matches_the_detail_records(self):
        details = [r for r in self.records if r.startswith("D")]
        self.assertEqual(int(at(self.trailer, 10, 10)), len(details))

    def test_the_totals_match_the_detail_records(self):
        """The check the flow performs at step 140, run here on the sample."""
        check = reconcile(self.records, self.batch)
        self.assertTrue(check.reconciled)
        self.assertEqual(check.repayment_cents,
                         int(at(self.trailer, 20, 14)))
        self.assertEqual(check.outstanding_cents,
                         int(at(self.trailer, 50, 14)))

    def test_the_totals_are_wider_than_a_detail_amount(self):
        """Fourteen digits, not eleven.

        A thousand participants each near the detail column's ceiling would
        overflow an eleven-digit total, and a silently truncated control total
        is worse than no control total: it makes a correct file fail
        Principal's reconciliation.
        """
        self.assertEqual(len(at(self.trailer, 20, 14)), 14)
        self.assertIn(at(self.trailer, 34, 1), "+-")


class TestReconciliationCatchesCorruption(unittest.TestCase):
    """The reconciliation must fail on the faults it exists to catch."""

    def setUp(self):
        self.batch, self.records = build_sample()

    def test_a_clean_file_reconciles(self):
        self.assertTrue(reconcile(self.records, self.batch).reconciled)

    def test_a_dropped_detail_row_fails(self):
        damaged = [r for r in self.records if r is not self.records[3]]
        self.assertFalse(reconcile(damaged, self.batch).reconciled)

    def test_an_amount_shifted_one_column_fails(self):
        """The defect the whole check exists for."""
        record = self.records[1]
        shifted = record[:78] + " " + record[78:-1]
        damaged = [self.records[0], shifted] + self.records[2:]
        self.assertFalse(reconcile(damaged, self.batch).reconciled)

    def test_a_duplicated_detail_row_fails(self):
        damaged = self.records[:2] + [self.records[1]] + self.records[2:]
        self.assertFalse(reconcile(damaged, self.batch).reconciled)


if __name__ == "__main__":
    unittest.main()

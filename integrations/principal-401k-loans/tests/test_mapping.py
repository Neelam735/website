"""The canonical mapping: normalisation, rejects and control totals.

test_layout.py asserts where a value lands. This asserts what the value is.
"""

import os
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from generate_principal_file import (  # noqa: E402
    ID_ALLOWED, MAX_DETAIL_CENTS, NAME_ALLOWED, Lookups, build_canonical,
    clean, load_lookup, to_ccyymmdd, to_cents,
)

HERE = os.path.dirname(__file__)
SAMPLE = os.path.join(HERE, "..", "samples", "extract_output_sample.xml")


def canonical(ssn_policy="FULL"):
    return build_canonical(ET.parse(SAMPLE).getroot(), Lookups.load(),
                           ssn_policy)


class TestToCents(unittest.TestCase):
    """Money, converted by string surgery rather than float arithmetic."""

    def test_ordinary_amounts(self):
        self.assertEqual(to_cents("250.00"), 25000)
        self.assertEqual(to_cents("0.00"), 0)
        self.assertEqual(to_cents("1000"), 100000)
        self.assertEqual(to_cents("0.01"), 1)

    def test_the_values_float_arithmetic_gets_wrong(self):
        # float('12.34') * 100 == 1233.9999999999998
        self.assertEqual(to_cents("12.34"), 1234)
        self.assertEqual(to_cents("8.07"), 807)
        self.assertEqual(to_cents("29.29"), 2929)
        self.assertEqual(to_cents("1.005"), 100)

    def test_signs(self):
        self.assertEqual(to_cents("-156.25"), -15625)
        self.assertEqual(to_cents("+156.25"), 15625)
        # Negative zero is zero. A trailing '-' on a zero amount would tell
        # Principal a reversal happened when nothing moved.
        self.assertEqual(to_cents("-0.00"), 0)

    def test_a_third_decimal_is_truncated_not_rounded(self):
        """Payroll delivers two. Inventing a half-cent is worse than losing
        a fraction that should not exist."""
        self.assertEqual(to_cents("8.005"), 800)
        self.assertEqual(to_cents("99.999"), 9999)

    def test_partial_and_dirty_input(self):
        self.assertEqual(to_cents(".5"), 50)
        self.assertEqual(to_cents("5."), 500)
        self.assertEqual(to_cents("1,234.56"), 123456)
        self.assertEqual(to_cents("$78.90"), 7890)
        self.assertEqual(to_cents("  12.34  "), 1234)

    def test_absent_values(self):
        self.assertEqual(to_cents(None), 0)
        self.assertEqual(to_cents(""), 0)
        self.assertEqual(to_cents("   "), 0)


class TestToCcyymmdd(unittest.TestCase):

    def test_conversion(self):
        self.assertEqual(to_ccyymmdd("2026-02-28"), "20260228")
        self.assertEqual(to_ccyymmdd("2026-02-28T09:15:00"), "20260228")
        self.assertEqual(to_ccyymmdd("2026/02/28"), "20260228")

    def test_anything_unrecognisable_is_empty_not_zero(self):
        """A zero-filled date is a date Principal's loader will try to parse.

        Empty pads to spaces, which the layout permits where a date is
        genuinely optional.
        """
        for value in ["", None, "   ", "not-a-date", "2026-2-8"]:
            self.assertEqual(to_ccyymmdd(value), "",
                             f"{value!r} should not produce a date")

    def test_a_transposed_date_is_rejected_rather_than_reordered(self):
        """28-02-2026 strips to eight digits that look like a date and are
        not. Guessing the intent would be worse than dropping it: a loan
        origination date is not something to infer."""
        self.assertEqual(to_ccyymmdd("28-02-2026"), "")
        self.assertEqual(to_ccyymmdd("02/28/2026"), "")

    def test_the_end_of_time_date_passes_through_visibly(self):
        """PFG_401K_PERIOD_DATES returns it for an unconfirmed payroll, on
        purpose: it is wrong in a way somebody notices in review."""
        self.assertEqual(to_ccyymmdd("4712-12-31"), "47121231")


class TestClean(unittest.TestCase):

    def test_case_and_accents_fold(self):
        self.assertEqual(clean("José Ángel", NAME_ALLOWED), "JOSE ANGEL")
        self.assertEqual(clean("Fernández", NAME_ALLOWED), "FERNANDEZ")
        self.assertEqual(clean("Íñigo", NAME_ALLOWED), "INIGO")

    def test_characters_outside_the_set_are_dropped_not_replaced(self):
        # Replacing an em dash with a space would change the name's shape;
        # dropping it keeps the two halves together, which is what Principal
        # sees on their side of a hyphenated name.
        self.assertEqual(clean("Smith—Jones", NAME_ALLOWED), "SMITHJONES")
        # Ø has no ASCII fold and is dropped; Å does, and folds to A.
        self.assertEqual(clean("Ødegård", NAME_ALLOWED), "DEGARD")
        self.assertEqual(clean("Ålesund", NAME_ALLOWED), "ALESUND")

    def test_the_characters_a_name_may_legitimately_contain_survive(self):
        self.assertEqual(clean("O'Brien-Smythe", NAME_ALLOWED),
                         "O'BRIEN-SMYTHE")
        self.assertEqual(clean("St. John", NAME_ALLOWED), "ST. JOHN")

    def test_internal_whitespace_collapses(self):
        self.assertEqual(clean("  Mary   Jo  ", NAME_ALLOWED), "MARY JO")

    def test_identifiers_allow_less_than_names(self):
        """A loan number is matched exactly at Principal's end; a stray space
        or full stop in it is a failed match, not a cosmetic problem."""
        self.assertEqual(clean("LN-000 123.", ID_ALLOWED), "LN-000123")
        self.assertNotIn(".", clean("LN.1", ID_ALLOWED))


class TestNationalIdentifier(unittest.TestCase):

    def test_punctuation_is_stripped(self):
        loans = {loan.employee_id: loan for loan in canonical().loans}
        self.assertEqual(loans["100501"].ssn, "123456789")

    def test_short_identifiers_are_left_padded(self):
        """Common in records migrated from an older system, and Principal
        matches on the padded form."""
        batch = build_canonical(ET.parse(SAMPLE).getroot(), Lookups.load())
        for loan in batch.loans:
            self.assertEqual(len(loan.ssn), 9)
            self.assertTrue(loan.ssn.isdigit())

    def test_masking_keeps_the_last_four(self):
        full = {loan.employee_id: loan.ssn for loan in canonical().loans}
        masked = {loan.employee_id: loan.ssn
                  for loan in canonical("MASKED").loans}
        self.assertEqual(full["100501"], "123456789")
        self.assertEqual(masked["100501"], "000006789")
        for employee_id, value in masked.items():
            self.assertTrue(value.startswith("00000"), employee_id)
            self.assertEqual(value[5:], full[employee_id][5:], employee_id)


class TestRejects(unittest.TestCase):

    def setUp(self):
        self.batch = canonical()
        self.by_employee = {reject.employee_id: reject
                            for reject in self.batch.rejects}

    def test_the_expected_rows_reject_and_no_others(self):
        self.assertEqual(sorted(self.by_employee),
                         ["100510", "100511", "100512", "100514", "100515"])

    def test_each_reason(self):
        self.assertEqual(self.by_employee["100510"].reason,
                         "MISSING_LOAN_NUMBER")
        self.assertEqual(self.by_employee["100511"].reason,
                         "UNMAPPED_LOAN_TYPE")
        self.assertEqual(self.by_employee["100512"].reason,
                         "MISSING_NATIONAL_ID")
        self.assertEqual(self.by_employee["100514"].reason,
                         "AMOUNT_OVERFLOW")
        self.assertEqual(self.by_employee["100515"].reason,
                         "MISSING_CONTRACT")

    def test_a_rejected_row_is_not_also_a_detail_row(self):
        detail_employees = {loan.employee_id for loan in self.batch.loans}
        self.assertEqual(detail_employees & set(self.by_employee), set())

    def test_an_unmapped_loan_type_is_never_silently_defaulted(self):
        """Defaulting to 01 would misfile a residential loan against a general
        amortisation schedule, and nobody would notice for a month."""
        for loan in self.batch.loans:
            self.assertIn(loan.loan_type_code, {"01", "02"})
        self.assertNotIn("100511",
                         {loan.employee_id for loan in self.batch.loans})

    def test_reject_messages_carry_no_amounts_or_identifiers(self):
        """The summary goes to SFTP and is quoted in an email."""
        identifiers = {loan.ssn for loan in self.batch.loans}
        for reject in self.batch.rejects:
            for identifier in identifiers:
                self.assertNotIn(identifier, reject.message)
            self.assertNotIn("$", reject.message)

    def test_the_overflow_threshold_is_the_column_width(self):
        self.assertEqual(MAX_DETAIL_CENTS, 99999999999)
        self.assertEqual(len(str(MAX_DETAIL_CENTS)), 11)


class TestControlTotals(unittest.TestCase):

    def setUp(self):
        self.batch = canonical()

    def test_totals_cover_the_accepted_rows_only(self):
        self.assertEqual(self.batch.detail_count, len(self.batch.loans))
        self.assertEqual(
            self.batch.total_repayment_cents,
            sum(loan.repayment_cents for loan in self.batch.loans))

    def test_a_rejected_rows_amount_is_not_in_the_totals(self):
        """The overflowing balance would dominate the total if it leaked in."""
        self.assertLess(self.batch.total_outstanding_cents, MAX_DETAIL_CENTS)

    def test_a_negative_repayment_reduces_the_total(self):
        """Netting, not absolute value: Principal reconciles against the money
        that actually moved."""
        with_reversal = self.batch.total_repayment_cents
        without = sum(loan.repayment_cents for loan in self.batch.loans
                      if loan.repayment_cents > 0)
        self.assertLess(with_reversal, without)

    def test_totals_are_integers(self):
        for total in (self.batch.total_repayment_cents,
                      self.batch.total_payoff_cents,
                      self.batch.total_outstanding_cents):
            self.assertIsInstance(total, int)


class TestContractScoping(unittest.TestCase):

    def test_the_first_legal_employer_decides_the_contract(self):
        self.assertEqual(canonical().contract_number, "40012345")

    def test_a_second_contracts_rows_are_rejected_not_misfiled(self):
        """A repayment posted to the wrong contract is found by the
        participant, not by us."""
        batch = canonical()
        self.assertNotIn("100515",
                         {loan.employee_id for loan in batch.loans})
        reject = next(r for r in batch.rejects if r.employee_id == "100515")
        self.assertEqual(reject.reason, "MISSING_CONTRACT")


class TestPackagedLookups(unittest.TestCase):
    """The reference implementation reads the archive's own lookup files, so
    these assert the packaged data, not a copy of it."""

    def setUp(self):
        self.lookups = Lookups.load()

    def test_residential_elements_are_loan_type_02(self):
        for name, code in self.lookups.loan_type.items():
            expected = "02" if ("Residential" in name or "Residence" in name) \
                else "01"
            self.assertEqual(code, expected, name)

    def test_every_status_the_formula_can_return_is_mapped(self):
        for status in ["ACTIVE", "PAID_OFF", "DEFAULTED", "SUSPENDED"]:
            self.assertIn(status, self.lookups.loan_status,
                          f"PFG_401K_LOAN_STATUS.ff can return {status}")
        self.assertEqual(
            set(self.lookups.loan_status.values()), {"A", "P", "D", "S"})

    def test_source_codes_have_a_default_row(self):
        """An unmapped payroll must not hold up a remittance."""
        self.assertEqual(self.lookups.default_source_code, "RG")

    def test_contract_numbers_are_eight_characters(self):
        for employer, contract in self.lookups.contract.items():
            self.assertEqual(len(contract), 8,
                             f"{employer} maps to {contract!r}, which does "
                             f"not fill the header's contract column")

    def test_no_two_employers_share_a_contract_by_accident(self):
        """Not a rule Principal imposes - two employers can share a plan - but
        a duplicate here is far more often a copy-paste slip, and the cost of
        being wrong is a whole employer's repayments filed under another
        employer's plan."""
        contracts = list(self.lookups.contract.values())
        self.assertEqual(len(contracts), len(set(contracts)))

    def test_lookup_files_and_the_manifest_agree(self):
        import json
        with open(os.path.join(HERE, "..", "src", "ics.json"),
                  encoding="utf-8") as handle:
            manifest = json.load(handle)
        declared = {entry["code"] for entry in manifest.get("lookups", [])}
        for name in declared:
            load_lookup(name, "ORACLE_HCM", "PRINCIPAL")
        self.assertEqual(declared, {
            "PFG_401K_LOAN_TYPE", "PFG_401K_LOAN_STATUS",
            "PFG_401K_CONTRACT", "PFG_401K_SOURCE_CODE",
        })


if __name__ == "__main__":
    unittest.main()

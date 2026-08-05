#!/usr/bin/env python3
"""Build the Principal 401(k) loan repayment file from an HCM Extract output.

The same transformation is implemented as XSLT for the OIC runtime
(resources/.../maps/map_extract_to_canonical.xsl and
map_canonical_to_principal.xsl). This module is the reference implementation:
it is what the unit tests assert against, and it is what you run locally to
produce a sample file before touching an environment.

The two implementations are asserted byte-identical by
tests/test_xslt_parity.py. Change one without the other and the suite fails,
which is the point - a fixed-width layout is exactly the kind of thing that
drifts silently, and the failure mode is a file that loads at Principal's end
and posts the wrong numbers.

Usage:
    generate_principal_file.py --extract sample_extract.xml --out ./build
    generate_principal_file.py --extract sample_extract.xml --out ./build \\
        --contract 40012345 --sender ACMECORP --prod
"""

from __future__ import annotations

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

EXT_NS = "http://xmlns.oracle.com/hcm/principal401k/extract"

RECORD_LENGTH = 200
FILE_TYPE = "LOANREPAY"
# Principal's loader reads a bare LF as a truncated record and rejects the
# whole file, so the terminator is CRLF on every platform.
LINE_TERMINATOR = "\r\n"

# Widest value each amount column can hold: 11 digits of cents. An amount
# beyond it is rejected rather than truncated - dropping a leading digit turns
# $150,000.00 into $50,000.00, and it posts.
MAX_DETAIL_CENTS = 99999999999

# Character folding, matched exactly by the $foldFrom/$foldTo variables in
# map_extract_to_canonical.xsl. Both sides must stay the same length.
FOLD_FROM = (
    "abcdefghijklmnopqrstuvwxyz"
    "ÀÁÂÃÄÅÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝÇ"
    "àáâãäåèéêëìíîïñòóôõöùúûüýç"
)
FOLD_TO = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "AAAAAAEEEEIIIINOOOOOUUUUYC"
    "AAAAAAEEEEIIIINOOOOOUUUUYC"
)
assert len(FOLD_FROM) == len(FOLD_TO)
_FOLD = str.maketrans(FOLD_FROM, FOLD_TO)

NAME_ALLOWED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'.")
ID_ALLOWED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

# Reject reasons, in the order the canonical map tests them. Order decides
# only which reason a row that fails several is reported under.
REASONS = (
    "MISSING_CONTRACT",
    "MISSING_NATIONAL_ID",
    "MISSING_LOAN_NUMBER",
    "UNMAPPED_LOAN_TYPE",
    "MISSING_NAME",
    "AMOUNT_OVERFLOW",
)


# --------------------------------------------------------------------------
# Lookups
#
# In OIC these are console-maintained lookups resolved by dvm:lookupValue.
# Here they are loaded from the same XML that is packaged into the archive, so
# the reference implementation and the runtime resolve against one definition
# rather than two copies that can disagree.
# --------------------------------------------------------------------------

LOOKUP_NS = "http://xmlns.oracle.com/ics/lookup"
LOOKUPS_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "src", "icspackage", "lookups",
)


def load_lookup(name: str, source: str, target: str,
                lookups_dir: str = LOOKUPS_DIR) -> dict[str, str]:
    """Read one packaged OIC lookup into {source value: target value}."""
    path = os.path.join(lookups_dir, f"{name}.xml")
    root = ET.parse(path).getroot()
    mapping: dict[str, str] = {}
    for row in root.iter(f"{{{LOOKUP_NS}}}row"):
        columns = {
            column.get("adapter"): (column.text or "").strip()
            for column in row
        }
        if source in columns and target in columns:
            mapping[columns[source]] = columns[target]
    return mapping


@dataclass
class Lookups:
    loan_type: dict[str, str]
    loan_status: dict[str, str]
    contract: dict[str, str]
    source_code: dict[str, str]

    @classmethod
    def load(cls, lookups_dir: str = LOOKUPS_DIR) -> "Lookups":
        return cls(
            loan_type=load_lookup("PFG_401K_LOAN_TYPE", "ORACLE_HCM",
                                  "PRINCIPAL", lookups_dir),
            loan_status=load_lookup("PFG_401K_LOAN_STATUS", "ORACLE_HCM",
                                    "PRINCIPAL", lookups_dir),
            contract=load_lookup("PFG_401K_CONTRACT", "ORACLE_HCM",
                                 "PRINCIPAL", lookups_dir),
            source_code=load_lookup("PFG_401K_SOURCE_CODE", "ORACLE_HCM",
                                    "PRINCIPAL", lookups_dir),
        )

    @property
    def default_source_code(self) -> str:
        return self.source_code.get("DEFAULT", "RG")


# --------------------------------------------------------------------------
# Normalisation
#
# Each function here has a named counterpart in map_extract_to_canonical.xsl.
# They are written to be obviously the same algorithm, not merely to produce
# the same answers, because "obviously the same" is what survives the next
# change to either.
# --------------------------------------------------------------------------


def to_cents(value: str | None) -> int:
    """Decimal string -> signed integer cents, by string surgery.

    Mirrors the to-cents template. Deliberately not float arithmetic:
    `float('12.34') * 100` is 1233.9999999999998, and while round() rescues
    that particular case, XSLT and Python would not always rescue it the same
    way. Splitting on the point is exact in both.

    A third decimal place is truncated rather than rounded. Payroll delivers
    two, and inventing a half-cent that neither HCM nor Principal holds is
    worse than dropping a fraction that should not exist.
    """
    raw = (value or "").strip().replace(",", "").replace("$", "").replace(" ", "")
    negative = raw.startswith("-")
    unsigned = raw[1:] if raw[:1] in "+-" else raw

    whole, _, fraction = unsigned.partition(".")
    fraction = (fraction + "00")[:2]

    # Keep only digits, as the XSLT's translate-based filter does. A stray
    # character in an amount becomes a smaller amount, not an exception -
    # matching the runtime is what matters here, and the overflow and
    # reconciliation checks are what catch a genuinely broken value.
    whole_digits = "".join(character for character in whole
                           if character.isdigit()) or "0"
    fraction_digits = "".join(character for character in fraction
                              if character.isdigit()) or "0"

    magnitude = int(whole_digits) * 100 + int(fraction_digits)
    return -magnitude if negative and magnitude else magnitude


def to_ccyymmdd(value: str | None) -> str:
    """YYYY-MM-DD (optionally with a time part) -> CCYYMMDD, else empty.

    The month and day range checks are not decoration. Stripping separators
    from a date already in the wrong order - 28-02-2026, which is what a
    hand-populated DFF sometimes holds - yields eight digits that look like a
    date and are not. Checking the ranges turns it into an empty field rather
    than a corrupt one.

    A full calendar validation is deliberately not attempted: 20260231 passes
    this and is not a real date. The point is to catch transposed formats, and
    Principal validates the date properly at their end.
    """
    date = (value or "").strip()[:10]
    compact = date.replace("-", "").replace("/", "")
    if len(compact) != 8 or not compact.isdigit():
        return ""
    if not 1 <= int(compact[4:6]) <= 12 or not 1 <= int(compact[6:8]) <= 31:
        return ""
    return compact


def clean(value: str | None, allowed: set[str]) -> str:
    """Upper-case, de-accent, and drop anything outside the allowed set.

    Dropping beats rejecting: an em dash in a surname must not cost somebody
    their loan repayment, but it also must not reach a US-ASCII fixed-width
    file, where a multi-byte character shifts every following column.
    """
    folded = " ".join((value or "").split()).translate(_FOLD)
    return "".join(character for character in folded if character in allowed)


def digits_only(value: str | None) -> str:
    return "".join(character for character in (value or "") if character.isdigit())


# --------------------------------------------------------------------------
# Canonical model
# --------------------------------------------------------------------------


@dataclass
class Loan:
    ssn: str
    employee_id: str
    last_name: str
    first_name: str
    middle_initial: str
    loan_number: str
    loan_type_code: str
    loan_status_code: str
    repayment_cents: int
    payoff_cents: int
    outstanding_cents: int
    pay_period_end: str
    check_date: str
    origination_date: str
    last_payment_date: str
    termination_date: str
    termination_indicator: str
    source_code: str


@dataclass
class Reject:
    employee_id: str
    loan_number: str
    reason: str
    message: str


@dataclass
class LoanBatch:
    contract_number: str = ""
    pay_period_end: str = ""
    check_date: str = ""
    loans: list[Loan] = field(default_factory=list)
    rejects: list[Reject] = field(default_factory=list)

    @property
    def detail_count(self) -> int:
        return len(self.loans)

    @property
    def total_repayment_cents(self) -> int:
        return sum(loan.repayment_cents for loan in self.loans)

    @property
    def total_payoff_cents(self) -> int:
        return sum(loan.payoff_cents for loan in self.loans)

    @property
    def total_outstanding_cents(self) -> int:
        return sum(loan.outstanding_cents for loan in self.loans)


def _text(node: ET.Element | None, tag: str) -> str:
    if node is None:
        return ""
    found = node.find(f"{{{EXT_NS}}}{tag}")
    return (found.text or "") if found is not None else ""


def _reject_message(reason: str, employer: str, element_name: str) -> str:
    """The message the canonical map writes, word for word.

    No amounts and no identifiers: the summary is written to SFTP and quoted
    in an email, and neither is a place for a participant's balance.
    """
    if reason == "MISSING_CONTRACT":
        return (f'Legal employer "{employer}" does not map to the contract '
                "this file is for. Add it to PFG_401K_CONTRACT, or scope the "
                "run to one contract.")
    if reason == "MISSING_NATIONAL_ID":
        return ("No national identifier on the person record; Principal "
                "cannot match the participant.")
    if reason == "MISSING_LOAN_NUMBER":
        return (f'Element "{element_name}" has no loan number on its element '
                "entry DFF.")
    if reason == "UNMAPPED_LOAN_TYPE":
        return f'Element "{element_name}" has no row in PFG_401K_LOAN_TYPE.'
    if reason == "MISSING_NAME":
        return "No last name on the person record."
    return ("An amount exceeds the 11-digit width of its column. Truncating "
            "it would silently drop a leading digit, so the loan is held "
            "back.")


def build_canonical(extract_root: ET.Element, lookups: Lookups,
                    ssn_policy: str = "FULL") -> LoanBatch:
    """HCM Extract XML -> canonical batch. Mirrors map_extract_to_canonical."""
    batch = LoanBatch()

    employers = extract_root.findall(f"{{{EXT_NS}}}G_LEGAL_EMPLOYER")

    # The file carries one contract number and Principal routes on it. The
    # first legal employer decides it; a loan under an employer mapping to a
    # different contract is rejected rather than filed under the wrong plan.
    first_employer = _text(employers[0], "LEGAL_EMPLOYER_NAME").strip() if employers else ""
    batch.contract_number = lookups.contract.get(first_employer, "")

    batch.pay_period_end = to_ccyymmdd(_text(extract_root, "PERIOD_END_DATE"))
    batch.check_date = to_ccyymmdd(_text(extract_root, "CHECK_DATE"))

    for employer in employers:
        employer_name = _text(employer, "LEGAL_EMPLOYER_NAME").strip()
        employer_contract = lookups.contract.get(employer_name, "")

        for employee in employer.findall(f"{{{EXT_NS}}}G_EMPLOYEE"):
            employee_id = _text(employee, "PERSON_NUMBER").strip()
            raw_id = digits_only(_text(employee, "NATIONAL_ID"))
            last_name = clean(_text(employee, "LAST_NAME"), NAME_ALLOWED)
            first_name = clean(_text(employee, "FIRST_NAME"), NAME_ALLOWED)
            middle = clean(_text(employee, "MIDDLE_NAMES"), NAME_ALLOWED)
            termination = to_ccyymmdd(_text(employee, "TERMINATION_DATE"))

            for loan_node in employee.findall(f"{{{EXT_NS}}}G_LOAN"):
                element_name = _text(loan_node, "ELEMENT_NAME").strip()
                loan_number = clean(_text(loan_node, "LOAN_NUMBER"), ID_ALLOWED)
                loan_type = lookups.loan_type.get(element_name, "")
                loan_status = lookups.loan_status.get(
                    _text(loan_node, "LOAN_STATUS").strip(), "A")
                source_code = lookups.source_code.get(
                    _text(loan_node, "PAYROLL_NAME").strip(),
                    lookups.default_source_code)

                repayment = to_cents(_text(loan_node, "REPAYMENT_AMOUNT"))
                payoff = to_cents(_text(loan_node, "PAYOFF_AMOUNT"))
                outstanding = to_cents(_text(loan_node, "OUTSTANDING_BALANCE"))

                reason = ""
                if (not batch.contract_number or not employer_contract
                        or employer_contract != batch.contract_number):
                    reason = "MISSING_CONTRACT"
                elif not raw_id:
                    reason = "MISSING_NATIONAL_ID"
                elif not loan_number.strip():
                    reason = "MISSING_LOAN_NUMBER"
                elif not loan_type:
                    reason = "UNMAPPED_LOAN_TYPE"
                elif not last_name.strip():
                    reason = "MISSING_NAME"
                elif any(abs(amount) > MAX_DETAIL_CENTS
                         for amount in (repayment, payoff, outstanding)):
                    reason = "AMOUNT_OVERFLOW"

                if reason:
                    batch.rejects.append(Reject(
                        employee_id=employee_id,
                        loan_number=loan_number,
                        reason=reason,
                        message=_reject_message(reason, employer_name,
                                                element_name),
                    ))
                    continue

                # Padded to nine before masking, so masking always takes the
                # last four of a nine-character value. An identifier stored
                # without its leading zero is common in migrated records, and
                # Principal matches on the padded form.
                padded_id = raw_id.rjust(9, "0")[-9:]
                ssn = ("00000" + padded_id[5:]) if ssn_policy == "MASKED" else padded_id

                # The loan's own period wins over the batch's where the
                # extract supplies it: an off-cycle correction carried in the
                # same run belongs to a different period than the regular
                # deduction.
                loan_period = to_ccyymmdd(_text(loan_node, "PERIOD_END_DATE")) \
                    or batch.pay_period_end
                loan_check = to_ccyymmdd(_text(loan_node, "CHECK_DATE")) \
                    or batch.check_date

                batch.loans.append(Loan(
                    ssn=ssn,
                    employee_id=employee_id,
                    last_name=last_name,
                    first_name=first_name,
                    middle_initial=middle.strip()[:1],
                    loan_number=loan_number,
                    loan_type_code=loan_type,
                    loan_status_code=loan_status,
                    repayment_cents=repayment,
                    payoff_cents=payoff,
                    outstanding_cents=outstanding,
                    pay_period_end=loan_period,
                    check_date=loan_check,
                    origination_date=to_ccyymmdd(
                        _text(loan_node, "LOAN_ORIGINATION_DATE")),
                    last_payment_date=to_ccyymmdd(
                        _text(loan_node, "LAST_PAYMENT_DATE")),
                    termination_date=termination,
                    termination_indicator="Y" if termination else "N",
                    source_code=source_code,
                ))

    return batch


# --------------------------------------------------------------------------
# Fixed-width formatting
#
# Mirrors map_canonical_to_principal.xsl. The layout table is in that file's
# header comment; tests/test_layout.py asserts the positions here against it.
# --------------------------------------------------------------------------


def left(value: str, width: int) -> str:
    """Left-justified, space-padded, truncated at the column width."""
    return " ".join(str(value or "").split()).ljust(width)[:width]


def right(value: object, width: int) -> str:
    """Right-justified, zero-padded, keeping the low-order digits."""
    return str(value).rjust(width, "0")[-width:]


def amount(cents: int, digits: int) -> str:
    """`digits` digits of zero-padded cents, then one sign character.

    Trailing sign, not leading: it keeps every digit column in the same place
    whichever sign the value carries.
    """
    return right(abs(int(cents)), digits) + ("-" if int(cents) < 0 else "+")


def fix(text: str) -> str:
    """Pad or cut a record to the fixed length.

    The cut is a guard rail. A 201-character record shifts every subsequent
    record on a mainframe reading fixed blocks, and tests/test_layout.py
    asserts nothing ever reaches it.
    """
    return text.ljust(RECORD_LENGTH)[:RECORD_LENGTH]


def header_record(batch: LoanBatch, sender_id: str, file_version: str,
                  test_production_flag: str, creation_date: str,
                  creation_time: str) -> str:
    return fix(
        "H"
        + left(batch.contract_number, 8)
        + left(creation_date, 8)
        + left(creation_time, 6)
        + left(FILE_TYPE, 10)
        + left(batch.pay_period_end, 8)
        + left(batch.check_date, 8)
        + left(file_version, 3)
        + left(sender_id, 10)
        # Anything other than an explicit P is a test transmission.
        # Defaulting the other way would let a misconfigured environment post
        # real money.
        + ("P" if test_production_flag == "P" else "T")
    )


def detail_record(loan: Loan) -> str:
    return fix(
        "D"
        + left(loan.ssn, 9)
        + left(loan.employee_id, 20)
        + left(loan.last_name, 20)
        + left(loan.first_name, 15)
        + left(loan.middle_initial, 1)
        + left(loan.loan_number, 10)
        + left(loan.loan_type_code, 2)
        + amount(loan.repayment_cents, 11)
        + amount(loan.payoff_cents, 11)
        + amount(loan.outstanding_cents, 11)
        + left(loan.pay_period_end, 8)
        + left(loan.check_date, 8)
        + left(loan.loan_status_code, 1)
        + left(loan.origination_date, 8)
        + left(loan.last_payment_date, 8)
        + left(loan.source_code, 2)
        + left(loan.termination_date, 8)
        + left(loan.termination_indicator, 1)
    )


def trailer_record(batch: LoanBatch, creation_date: str,
                   creation_time: str) -> str:
    return fix(
        "T"
        + left(batch.contract_number, 8)
        + right(batch.detail_count, 10)
        + amount(batch.total_repayment_cents, 14)
        + amount(batch.total_payoff_cents, 14)
        + amount(batch.total_outstanding_cents, 14)
        + left(creation_date, 8)
        + left(creation_time, 6)
    )


def format_file(batch: LoanBatch, *, sender_id: str = "", file_version: str = "001",
                test_production_flag: str = "T", creation_date: str = "",
                creation_time: str = "") -> list[str]:
    """The finished file, as a list of 200-character records."""
    return (
        [header_record(batch, sender_id, file_version, test_production_flag,
                       creation_date, creation_time)]
        + [detail_record(loan) for loan in batch.loans]
        + [trailer_record(batch, creation_date, creation_time)]
    )


# --------------------------------------------------------------------------
# Reconciliation
#
# The independent recount the flow's step 140 performs. Parsing the formatted
# records back is what makes this a check rather than a restatement: the
# trailer's figures came from the canonical batch, these come from the text
# that will actually be delivered.
# --------------------------------------------------------------------------


@dataclass
class Reconciliation:
    detail_count: int
    repayment_cents: int
    outstanding_cents: int
    reconciled: bool


def _parse_amount(record: str, start: int, digits: int) -> int:
    """Read one amount column back out of a formatted record.

    `start` is the 1-based position from the layout table, so that this reads
    the same way the table does.
    """
    field_text = record[start - 1:start - 1 + digits + 1]
    magnitude = int(field_text[:digits])
    return -magnitude if field_text[digits] == "-" else magnitude


def reconcile(records: list[str], batch: LoanBatch) -> Reconciliation:
    details = [record for record in records if record.startswith("D")]
    repayment = sum(_parse_amount(record, 79, 11) for record in details)
    outstanding = sum(_parse_amount(record, 103, 11) for record in details)
    return Reconciliation(
        detail_count=len(details),
        repayment_cents=repayment,
        outstanding_cents=outstanding,
        reconciled=(len(details) == batch.detail_count
                    and repayment == batch.total_repayment_cents
                    and outstanding == batch.total_outstanding_cents),
    )


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def build(extract_path: str, *, lookups: Lookups | None = None,
          ssn_policy: str = "FULL", sender_id: str = "",
          file_version: str = "001", test_production_flag: str = "T",
          creation_date: str = "", creation_time: str = "",
          contract_number: str | None = None) -> tuple[LoanBatch, list[str]]:
    root = ET.parse(extract_path).getroot()
    batch = build_canonical(root, lookups or Lookups.load(), ssn_policy)
    if contract_number is not None:
        batch.contract_number = contract_number
    records = format_file(
        batch, sender_id=sender_id, file_version=file_version,
        test_production_flag=test_production_flag,
        creation_date=creation_date, creation_time=creation_time,
    )
    return batch, records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", required=True,
                        help="HCM Extract XML output")
    parser.add_argument("--out", default="build")
    parser.add_argument("--sender", default="ACMECORP")
    parser.add_argument("--version", dest="file_version", default="001")
    parser.add_argument("--contract", default=None,
                        help="override the contract number the lookup resolves")
    parser.add_argument("--ssn-policy", choices=["FULL", "MASKED"],
                        default="FULL")
    parser.add_argument("--prod", action="store_true",
                        help="mark the file as a production transmission")
    parser.add_argument("--date", default="20260302",
                        help="file creation date, CCYYMMDD; fixed by default "
                             "so repeated runs produce identical bytes")
    parser.add_argument("--time", default="050000",
                        help="file creation time, HHMMSS")
    args = parser.parse_args(argv)

    batch, records = build(
        args.extract,
        ssn_policy=args.ssn_policy,
        sender_id=args.sender,
        file_version=args.file_version,
        test_production_flag="P" if args.prod else "T",
        creation_date=args.date,
        creation_time=args.time,
        contract_number=args.contract,
    )

    check = reconcile(records, batch)

    os.makedirs(args.out, exist_ok=True)
    name = (f"PFG_401K_LOAN_{batch.contract_number}_"
            f"{batch.pay_period_end}_{args.time}.txt")
    path = os.path.join(args.out, name)
    with open(path, "w", encoding="ascii", newline="") as handle:
        for record in records:
            handle.write(record + LINE_TERMINATOR)

    print(f"written    : {path}")
    print(f"contract   : {batch.contract_number or '(unresolved)'}")
    print(f"period end : {batch.pay_period_end or '(none)'}")
    print(f"details    : {batch.detail_count}")
    print(f"rejected   : {len(batch.rejects)}")
    print(f"repayments : {batch.total_repayment_cents / 100:,.2f}")
    print(f"reconciled : {check.reconciled}")

    for reject in batch.rejects:
        print(f"  REJECT {reject.reason}  employee {reject.employee_id}"
              f"  loan {reject.loan_number}")
        print(f"         {reject.message}")

    # A file whose trailer disagrees with its details must not look like a
    # successful run to whatever called this.
    return 0 if check.reconciled else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Build an HCM Data Loader Worker.dat from an ATS new-hire extract.

The same field mapping is implemented as XSLT for the OIC runtime
(resources/.../maps/map_canonical_to_hdl.xsl). This module is the reference
implementation: it is what the unit tests assert against, and it is what you
run locally to produce a sample Worker.zip before touching an environment.

Usage:
    generate_worker_dat.py --csv newhire.csv --out ./build
    generate_worker_dat.py --csv newhire.csv --out ./build --zip
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import re
import sys
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from typing import Iterable

# HDL treats 4712-12-31 as "end of time" for effective-dated rows.
END_OF_TIME = "4712-12-31"

# Stamped into SourceSystemOwner so every row this integration creates is
# traceable back to it. Must match the Source System Owner registered in
# HCM (Manage Common Lookups -> HRC_SOURCE_SYSTEM_OWNER).
SOURCE_SYSTEM_OWNER = "OIC_NEWHIRE"

DEFAULT_ACTION_CODE = "HIRE"

# Business object files, in the order HDL must process them. Order matters:
# a child row cannot resolve its parent GUID until the parent is loaded.
BUSINESS_OBJECTS = [
    "Worker",
    "PersonName",
    "PersonEmail",
    "PersonPhone",
    "PersonLegislativeData",
    "PersonAddress",
    "WorkRelationship",
    "WorkTerms",
    "Assignment",
]

# Columns expected in the ATS extract. Anything else in the file is ignored,
# so upstream can add columns without breaking the load.
REQUIRED_COLUMNS = [
    "EmployeeNumber",
    "FirstName",
    "LastName",
    "HireDate",
    "LegalEmployerName",
    "LegislationCode",
]


class ValidationError(Exception):
    """A source row that HDL would reject, caught before we build the file."""


@dataclass
class RowError:
    row_number: int
    employee_number: str
    message: str


@dataclass
class LoadResult:
    files: dict[str, str] = field(default_factory=dict)
    errors: list[RowError] = field(default_factory=list)
    accepted: int = 0

    @property
    def rejected(self) -> int:
        return len(self.errors)


def _clean(value: str | None) -> str:
    """Strip, and neutralise the characters that would corrupt a .dat row.

    HDL is pipe-delimited with no quoting, so an embedded pipe or newline
    silently shifts every following attribute by one column. Replacing beats
    rejecting here: a stray pipe in an address line should not fail a hire.

    Whitespace runs collapse to a single space. That matches what the XSLT
    does via normalize-space(), which is what keeps the two implementations
    byte-identical.
    """
    if value is None:
        return ""
    return re.sub(r"[|\s]+", " ", value).strip()


def _date(value: str | None, *, field_name: str, required: bool = False) -> str:
    """Normalise a source date to the YYYY-MM-DD that HDL expects."""
    raw = _clean(value)
    if not raw:
        if required:
            raise ValidationError(f"{field_name} is required")
        return ""
    for fmt in ("%Y-%m-%d", "%d-%b-%Y", "%m/%d/%Y", "%d/%m/%Y", "%Y%m%d"):
        try:
            return datetime.strptime(raw, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    raise ValidationError(f"{field_name} '{raw}' is not a recognised date")


def _ssid(prefix: str, employee_number: str) -> str:
    """Deterministic SourceSystemId.

    Deterministic is the whole point: rerunning the same extract MERGEs onto
    the same records instead of creating duplicate people.
    """
    return f"{prefix}_{employee_number}"


class DatFile:
    """One HDL business object file: a METADATA line plus its MERGE rows."""

    def __init__(self, name: str, attributes: list[str]):
        self.name = name
        self.attributes = attributes
        self.rows: list[list[str]] = []

    def add(self, values: dict[str, str]) -> None:
        unknown = set(values) - set(self.attributes)
        if unknown:
            raise ValidationError(
                f"{self.name}: unknown attribute(s) {sorted(unknown)}"
            )
        self.rows.append([_clean(values.get(a, "")) for a in self.attributes])

    def render(self) -> str:
        out = io.StringIO()
        out.write("|".join(["METADATA", self.name, *self.attributes]))
        out.write("\n")
        for row in self.rows:
            out.write("|".join(["MERGE", self.name, *row]))
            out.write("\n")
        return out.getvalue()

    def __len__(self) -> int:
        return len(self.rows)


def _new_files() -> dict[str, DatFile]:
    """Attribute lists per business object, in HDL's documented order."""
    return {
        "Worker": DatFile(
            "Worker",
            [
                "SourceSystemOwner", "SourceSystemId", "EffectiveStartDate",
                "EffectiveEndDate", "PersonNumber", "StartDate", "DateOfBirth",
                "CountryOfBirth", "TownOfBirth", "ActionCode",
            ],
        ),
        "PersonName": DatFile(
            "PersonName",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "EffectiveStartDate", "EffectiveEndDate", "LegislationCode",
                "NameType", "FirstName", "MiddleNames", "LastName", "Title",
            ],
        ),
        "PersonEmail": DatFile(
            "PersonEmail",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "DateFrom", "DateTo", "EmailType", "EmailAddress", "PrimaryFlag",
            ],
        ),
        "PersonPhone": DatFile(
            "PersonPhone",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "DateFrom", "DateTo", "PhoneType", "LegislationCode",
                "CountryCodeNumber", "AreaCode", "PhoneNumber", "PrimaryFlag",
            ],
        ),
        "PersonLegislativeData": DatFile(
            "PersonLegislativeData",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "EffectiveStartDate", "EffectiveEndDate", "LegislationCode",
                "Sex", "MaritalStatus",
            ],
        ),
        "PersonAddress": DatFile(
            "PersonAddress",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "EffectiveStartDate", "EffectiveEndDate", "AddressType",
                "AddressLine1", "AddressLine2", "TownOrCity", "Region1",
                "Region2", "Country", "PostalCode", "PrimaryFlag",
            ],
        ),
        "WorkRelationship": DatFile(
            "WorkRelationship",
            [
                "SourceSystemOwner", "SourceSystemId", "PersonId(SourceSystemId)",
                "LegalEmployerName", "DateStart", "WorkerType", "PrimaryFlag",
                "LegalEmployerSeniorityDate",
            ],
        ),
        "WorkTerms": DatFile(
            "WorkTerms",
            [
                "SourceSystemOwner", "SourceSystemId",
                "PeriodOfServiceId(SourceSystemId)", "PersonId(SourceSystemId)",
                "EffectiveStartDate", "EffectiveEndDate", "EffectiveSequence",
                "EffectiveLatestChange", "AssignmentNumber", "AssignmentName",
                "AssignmentType", "ActionCode", "BusinessUnitShortCode",
                "LegalEmployerName", "PrimaryWorkTermsFlag",
                "AssignmentStatusTypeCode",
            ],
        ),
        "Assignment": DatFile(
            "Assignment",
            [
                "SourceSystemOwner", "SourceSystemId",
                "WorkTermsAssignmentId(SourceSystemId)",
                "PeriodOfServiceId(SourceSystemId)", "PersonId(SourceSystemId)",
                "EffectiveStartDate", "EffectiveEndDate", "EffectiveSequence",
                "EffectiveLatestChange", "AssignmentNumber", "AssignmentType",
                "ActionCode", "BusinessUnitShortCode", "LegalEmployerName",
                "PrimaryAssignmentFlag", "AssignmentStatusTypeCode", "JobCode",
                "GradeCode", "DepartmentName", "LocationCode", "PositionCode",
                "ManagerFlag", "NormalHours", "Frequency", "AssignmentCategory",
            ],
        ),
    }


def _map_row(row: dict[str, str], files: dict[str, DatFile]) -> None:
    """Map one ATS row onto its nine HDL business object rows."""
    for column in REQUIRED_COLUMNS:
        if not _clean(row.get(column)):
            raise ValidationError(f"{column} is required")

    emp = _clean(row["EmployeeNumber"])
    hire_date = _date(row.get("HireDate"), field_name="HireDate", required=True)
    legislation = _clean(row["LegislationCode"]).upper()
    legal_employer = _clean(row["LegalEmployerName"])

    person_ssid = _ssid("WKR", emp)
    pos_ssid = _ssid("POS", emp)
    wt_ssid = _ssid("WT", emp)
    asg_number = f"E{emp}"

    files["Worker"].add({
        "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
        "SourceSystemId": person_ssid,
        "EffectiveStartDate": hire_date,
        "EffectiveEndDate": END_OF_TIME,
        "PersonNumber": emp,
        "StartDate": hire_date,
        "DateOfBirth": _date(row.get("DateOfBirth"), field_name="DateOfBirth"),
        "CountryOfBirth": _clean(row.get("CountryOfBirth")),
        "TownOfBirth": _clean(row.get("TownOfBirth")),
        "ActionCode": _clean(row.get("ActionCode")) or DEFAULT_ACTION_CODE,
    })

    files["PersonName"].add({
        "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
        "SourceSystemId": _ssid("NAME", emp),
        "PersonId(SourceSystemId)": person_ssid,
        "EffectiveStartDate": hire_date,
        "EffectiveEndDate": END_OF_TIME,
        "LegislationCode": legislation,
        "NameType": "GLOBAL",
        "FirstName": _clean(row["FirstName"]),
        "MiddleNames": _clean(row.get("MiddleName")),
        "LastName": _clean(row["LastName"]),
        "Title": _clean(row.get("Title")),
    })

    email = _clean(row.get("EmailAddress"))
    if email:
        files["PersonEmail"].add({
            "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
            "SourceSystemId": _ssid("EML", emp),
            "PersonId(SourceSystemId)": person_ssid,
            "DateFrom": hire_date,
            "DateTo": END_OF_TIME,
            "EmailType": "W1",
            "EmailAddress": email,
            "PrimaryFlag": "Y",
        })

    phone = _clean(row.get("PhoneNumber"))
    if phone:
        files["PersonPhone"].add({
            "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
            "SourceSystemId": _ssid("PHN", emp),
            "PersonId(SourceSystemId)": person_ssid,
            "DateFrom": hire_date,
            "DateTo": END_OF_TIME,
            "PhoneType": "W1",
            "LegislationCode": legislation,
            "CountryCodeNumber": _clean(row.get("PhoneCountryCode")),
            "AreaCode": _clean(row.get("PhoneAreaCode")),
            "PhoneNumber": phone,
            "PrimaryFlag": "Y",
        })

    sex = _clean(row.get("Gender"))
    marital = _clean(row.get("MaritalStatus"))
    if sex or marital:
        files["PersonLegislativeData"].add({
            "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
            "SourceSystemId": _ssid("LEG", emp),
            "PersonId(SourceSystemId)": person_ssid,
            "EffectiveStartDate": hire_date,
            "EffectiveEndDate": END_OF_TIME,
            "LegislationCode": legislation,
            "Sex": sex,
            "MaritalStatus": marital,
        })

    if _clean(row.get("AddressLine1")):
        files["PersonAddress"].add({
            "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
            "SourceSystemId": _ssid("ADR", emp),
            "PersonId(SourceSystemId)": person_ssid,
            "EffectiveStartDate": hire_date,
            "EffectiveEndDate": END_OF_TIME,
            "AddressType": "HOME",
            "AddressLine1": _clean(row.get("AddressLine1")),
            "AddressLine2": _clean(row.get("AddressLine2")),
            "TownOrCity": _clean(row.get("City")),
            "Region1": _clean(row.get("County")),
            "Region2": _clean(row.get("State")),
            "Country": _clean(row.get("Country")) or legislation,
            "PostalCode": _clean(row.get("PostalCode")),
            "PrimaryFlag": "Y",
        })

    files["WorkRelationship"].add({
        "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
        "SourceSystemId": pos_ssid,
        "PersonId(SourceSystemId)": person_ssid,
        "LegalEmployerName": legal_employer,
        "DateStart": hire_date,
        "WorkerType": _clean(row.get("WorkerType")) or "E",
        "PrimaryFlag": "Y",
        "LegalEmployerSeniorityDate": hire_date,
    })

    business_unit = _clean(row.get("BusinessUnit"))
    files["WorkTerms"].add({
        "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
        "SourceSystemId": wt_ssid,
        "PeriodOfServiceId(SourceSystemId)": pos_ssid,
        "PersonId(SourceSystemId)": person_ssid,
        "EffectiveStartDate": hire_date,
        "EffectiveEndDate": END_OF_TIME,
        "EffectiveSequence": "1",
        "EffectiveLatestChange": "Y",
        "AssignmentNumber": f"ET{emp}",
        "AssignmentName": f"{_clean(row['LastName'])}, {_clean(row['FirstName'])}",
        "AssignmentType": "ET",
        "ActionCode": _clean(row.get("ActionCode")) or DEFAULT_ACTION_CODE,
        "BusinessUnitShortCode": business_unit,
        "LegalEmployerName": legal_employer,
        "PrimaryWorkTermsFlag": "Y",
        "AssignmentStatusTypeCode": "ACTIVE_PROCESS",
    })

    files["Assignment"].add({
        "SourceSystemOwner": SOURCE_SYSTEM_OWNER,
        "SourceSystemId": _ssid("ASG", emp),
        "WorkTermsAssignmentId(SourceSystemId)": wt_ssid,
        "PeriodOfServiceId(SourceSystemId)": pos_ssid,
        "PersonId(SourceSystemId)": person_ssid,
        "EffectiveStartDate": hire_date,
        "EffectiveEndDate": END_OF_TIME,
        "EffectiveSequence": "1",
        "EffectiveLatestChange": "Y",
        "AssignmentNumber": asg_number,
        "AssignmentType": "E",
        "ActionCode": _clean(row.get("ActionCode")) or DEFAULT_ACTION_CODE,
        "BusinessUnitShortCode": business_unit,
        "LegalEmployerName": legal_employer,
        "PrimaryAssignmentFlag": "Y",
        "AssignmentStatusTypeCode": "ACTIVE_PROCESS",
        "JobCode": _clean(row.get("JobCode")),
        "GradeCode": _clean(row.get("GradeCode")),
        "DepartmentName": _clean(row.get("DepartmentName")),
        "LocationCode": _clean(row.get("LocationCode")),
        "PositionCode": _clean(row.get("PositionCode")),
        "ManagerFlag": _clean(row.get("ManagerFlag")) or "N",
        "NormalHours": _clean(row.get("NormalHours")),
        "Frequency": _clean(row.get("Frequency")),
        "AssignmentCategory": _clean(row.get("AssignmentCategory")),
    })


def build(rows: Iterable[dict[str, str]]) -> LoadResult:
    """Map source rows to .dat file contents, collecting per-row failures.

    A bad row is skipped, not fatal. One malformed record should not hold up
    everyone else's start date, and the caller gets the rejects to send back.
    """
    files = _new_files()
    result = LoadResult()
    seen: dict[str, int] = {}

    for index, row in enumerate(rows, start=2):  # start=2: line 1 is the header
        emp = _clean(row.get("EmployeeNumber"))
        try:
            if emp and emp in seen:
                raise ValidationError(
                    f"duplicate EmployeeNumber, first seen on line {seen[emp]}"
                )
            _map_row(row, files)
        except ValidationError as exc:
            result.errors.append(RowError(index, emp, str(exc)))
            continue
        if emp:
            seen[emp] = index
        result.accepted += 1

    # Only emit files that actually have rows. An empty .dat with just a
    # METADATA line is valid but makes the load report noisier to read.
    for name in BUSINESS_OBJECTS:
        if len(files[name]):
            result.files[f"{name}.dat"] = files[name].render()

    return result


def write_output(result: LoadResult, out_dir: str, *, make_zip: bool) -> str | None:
    os.makedirs(out_dir, exist_ok=True)
    for filename, content in result.files.items():
        with open(os.path.join(out_dir, filename), "w", encoding="utf-8") as handle:
            handle.write(content)

    if result.errors:
        reject_path = os.path.join(out_dir, "rejects.csv")
        with open(reject_path, "w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["SourceLine", "EmployeeNumber", "Error"])
            for err in result.errors:
                writer.writerow([err.row_number, err.employee_number, err.message])

    if not make_zip or not result.files:
        return None

    # HDL requires a flat zip: .dat files at the root, no directory entries.
    zip_path = os.path.join(out_dir, "Worker.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for filename, content in result.files.items():
            archive.writestr(filename, content)
    return zip_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", required=True, help="ATS new-hire extract")
    parser.add_argument("--out", default="./build", help="output directory")
    parser.add_argument("--zip", action="store_true", help="also build Worker.zip")
    args = parser.parse_args(argv)

    with open(args.csv, newline="", encoding="utf-8-sig") as handle:
        result = build(csv.DictReader(handle))

    zip_path = write_output(result, args.out, make_zip=args.zip)

    print(f"accepted : {result.accepted}")
    print(f"rejected : {result.rejected}")
    for name in result.files:
        print(f"  {name}")
    if zip_path:
        print(f"zip      : {zip_path}")
    for err in result.errors:
        print(f"  line {err.row_number} ({err.employee_number}): {err.message}",
              file=sys.stderr)

    # Rejects alone are not a build failure; they are data for the source team.
    return 0 if result.files else 1


if __name__ == "__main__":
    raise SystemExit(main())

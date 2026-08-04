# Field mapping: ATS extract → HDL Worker business object

One source row produces up to nine HDL rows. Five are always produced; four are
conditional on the source supplying the data.

Constants: `SourceSystemOwner = OIC_NEWHIRE` (overridable),
`EffectiveEndDate`/`DateTo = 4712-12-31` (HDL's end of time).

## Surrogate keys

All derived from `EmployeeNumber`, so the load is idempotent.

| Key | Pattern | Example |
|---|---|---|
| Person | `WKR_<emp>` | `WKR_100501` |
| Name | `NAME_<emp>` | `NAME_100501` |
| Email | `EML_<emp>` | `EML_100501` |
| Phone | `PHN_<emp>` | `PHN_100501` |
| Legislative | `LEG_<emp>` | `LEG_100501` |
| Address | `ADR_<emp>` | `ADR_100501` |
| Work relationship | `POS_<emp>` | `POS_100501` |
| Work terms | `WT_<emp>` | `WT_100501` |
| Assignment | `ASG_<emp>` | `ASG_100501` |

Parent references: `PersonName`, `PersonEmail`, `PersonPhone`,
`PersonLegislativeData`, `PersonAddress`, `WorkRelationship`, `WorkTerms` and
`Assignment` all carry `PersonId(SourceSystemId) = WKR_<emp>`. `WorkTerms`
additionally carries `PeriodOfServiceId = POS_<emp>`; `Assignment` carries both
that and `WorkTermsAssignmentId = WT_<emp>`.

## Required columns

A row missing any of these is rejected before the file is built:
`EmployeeNumber`, `FirstName`, `LastName`, `HireDate`, `LegalEmployerName`,
`LegislationCode`.

A duplicate `EmployeeNumber` within one file is also rejected — first
occurrence wins.

## Worker (always)

| HDL attribute | Source | Notes |
|---|---|---|
| `SourceSystemId` | derived | `WKR_<emp>` |
| `EffectiveStartDate` | `HireDate` | |
| `EffectiveEndDate` | constant | `4712-12-31` |
| `PersonNumber` | `EmployeeNumber` | |
| `StartDate` | `HireDate` | |
| `DateOfBirth` | `DateOfBirth` | Optional; must parse if present |
| `CountryOfBirth` | `CountryOfBirth` | Optional |
| `TownOfBirth` | `TownOfBirth` | Optional |
| `ActionCode` | `ActionCode` | Defaults to `HIRE` |

## PersonName (always)

| HDL attribute | Source | Notes |
|---|---|---|
| `LegislationCode` | `LegislationCode` | Upper-cased |
| `NameType` | constant | `GLOBAL` |
| `FirstName` | `FirstName` | Required |
| `MiddleNames` | `MiddleName` | Optional |
| `LastName` | `LastName` | Required |
| `Title` | `Title` | Optional |

## PersonEmail (when `EmailAddress` present)

`EmailType` = `W1` (work), `PrimaryFlag` = `Y`, `DateFrom` = `HireDate`.

## PersonPhone (when `PhoneNumber` present)

`PhoneType` = `W1`, `PrimaryFlag` = `Y`. Carries `PhoneCountryCode` →
`CountryCodeNumber`, `PhoneAreaCode` → `AreaCode`.

## PersonLegislativeData (when `Gender` or `MaritalStatus` present)

`Gender` → `Sex`, `MaritalStatus` → `MaritalStatus`. Both are Fusion lookup
codes, not free text — `F`/`M`, `S`/`M`/`D`/`W`.

## PersonAddress (when `AddressLine1` present)

`AddressType` = `HOME`, `PrimaryFlag` = `Y`.

| HDL attribute | Source |
|---|---|
| `AddressLine1` / `AddressLine2` | same |
| `TownOrCity` | `City` |
| `Region1` | `County` |
| `Region2` | `State` |
| `Country` | `Country`, falling back to `LegislationCode` |
| `PostalCode` | `PostalCode` |

No `AddressLine1` means the whole object is skipped — HDL rejects a
`PersonAddress` row without one.

## WorkRelationship (always)

| HDL attribute | Source | Notes |
|---|---|---|
| `LegalEmployerName` | `LegalEmployerName` | Must exist in the pod |
| `DateStart` | `HireDate` | |
| `WorkerType` | `WorkerType` | Defaults to `E` (employee) |
| `PrimaryFlag` | constant | `Y` |
| `LegalEmployerSeniorityDate` | `HireDate` | |

## WorkTerms (always)

`AssignmentNumber` = `ET<emp>`, `AssignmentType` = `ET`,
`AssignmentName` = `"<LastName>, <FirstName>"`, `EffectiveSequence` = `1`,
`EffectiveLatestChange` = `Y`, `PrimaryWorkTermsFlag` = `Y`,
`AssignmentStatusTypeCode` = `ACTIVE_PROCESS`.
`BusinessUnitShortCode` from `BusinessUnit`.

## Assignment (always)

`AssignmentNumber` = `E<emp>`, `AssignmentType` = `E`, `EffectiveSequence` = `1`,
`EffectiveLatestChange` = `Y`, `PrimaryAssignmentFlag` = `Y`,
`AssignmentStatusTypeCode` = `ACTIVE_PROCESS`.

Carried through unchanged: `JobCode`, `GradeCode`, `DepartmentName`,
`LocationCode`, `PositionCode`, `NormalHours`, `Frequency`,
`AssignmentCategory`. `ManagerFlag` defaults to `N`.

Every one of these must resolve against reference data in the target pod. They
are the most common cause of a partially failed load.

## Transformations

**Dates.** Accepted: `YYYY-MM-DD`, `YYYYMMDD`, `DD-MON-YYYY`, `MM/DD/YYYY`.
All normalise to `YYYY-MM-DD`. Anything else rejects the row rather than
guessing — an ambiguous `03/04/2026` should fail loudly, not load as the wrong
month.

**Sanitising.** `|`, tab, CR and LF are replaced with spaces, and whitespace
runs collapse. HDL is pipe-delimited with no quoting, so an embedded pipe would
silently shift every following attribute by one column — a corruption that
loads successfully and surfaces weeks later.

**Case.** `LegislationCode` is upper-cased. Everything else is passed through
as supplied; Fusion lookup codes are case-sensitive and the source is expected
to send them correctly.

## Empty files

A business object with no qualifying rows is not written at all. A `.dat` with
only a `METADATA` line is valid but makes the HDL import report harder to read.

## Keeping this accurate

The mapping is implemented twice — `map_canonical_to_hdl.xsl` (runs in OIC) and
`tools/generate_worker_dat.py` (reference). `tests/test_xslt_parity.py` asserts
they produce identical bytes. Change one without the other and the suite fails.

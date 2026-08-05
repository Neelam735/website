# Field mapping: HCM → Principal 401(k) loan repayment file

Record length is 200 characters for every record type. Positions are 1-based
and inclusive, matching the layout tables in the header comment of
[`map_canonical_to_principal.xsl`](../src/icspackage/project/PRINCIPAL_401K_LOANS_01.00.0000/resources/processor_10/resourcegroup_10/maps/map_canonical_to_principal.xsl).
`tests/test_layout.py` asserts every position below, and
`tools/validate_iar.py` refuses to package a layout whose columns do not add
up to 200.

> **On the specification.** No Principal file specification was supplied with
> this build. The layout below is a complete, internally consistent
> fixed-width design following Principal's published loan-remittance
> conventions — record type indicator, contract-keyed header, one detail per
> loan, control-total trailer. **Before the first certification run, reconcile
> it against the specification Principal issues with the onboarding profile.**
> Everything is arranged so that reconciliation is one file's worth of work:
> positions live only in the formatting map, mirrored in
> `tools/generate_principal_file.py`, and the parity test fails if the two
> drift. See [Adjusting to the real spec](#adjusting-to-the-real-spec).

## Constants and run context

| Value | Source | Notes |
|---|---|---|
| Record length | 200 | Every record type |
| Line terminator | CRLF | A bare LF reads as a truncated record on Principal's loader |
| Character set | US-ASCII | A multi-byte character shifts every column after it |
| File type | `LOANREPAY` | Header positions 24–33 |
| File name | `PFG_401K_LOAN_<contract>_<CCYYMMDD>_<HHMMSS>.txt` | `.pgp` appended when encrypted |

## Header record — type `H`

| Target Field | Position/Length | Format | HCM Source | Transformation | Required | Default |
|---|---|---|---|---|---|---|
| Record type | 1 / 1 | `A` | — | Literal `H` | Y | `H` |
| Contract number | 2–9 / 8 | `A` | `LEGAL_EMPLOYER_NAME` (first data group) | `PFG_401K_CONTRACT` lookup; left-justified | Y | — |
| File creation date | 10–17 / 8 | `CCYYMMDD` | — | Run date at step 120 | Y | — |
| File creation time | 18–23 / 6 | `HHMMSS` | — | Run time at step 120 | Y | — |
| File type | 24–33 / 10 | `A` | — | Literal `LOANREPAY`, space-padded | Y | `LOANREPAY` |
| Pay period end date | 34–41 / 8 | `CCYYMMDD` | `PERIOD_END_DATE` | ISO → compact | Y | — |
| Check date | 42–49 / 8 | `CCYYMMDD` | `CHECK_DATE` | ISO → compact | Y | — |
| File version | 50–52 / 3 | `A` | — | `fileVersion` property | Y | `001` |
| Sender id | 53–62 / 10 | `A` | — | `senderId` property | Y | — |
| Test/production flag | 63 / 1 | `A` | — | `P` only when `testProductionFlag = P`; anything else `T` | Y | `T` |
| Filler | 64–200 / 137 | `A` | — | Spaces | Y | spaces |

## Detail record — type `D`

One record per loan, not per participant. A participant with two concurrent
loans produces two records.

| Target Field | Position/Length | Format | HCM Source | Transformation | Required | Default |
|---|---|---|---|---|---|---|
| Record type | 1 / 1 | `A` | — | Literal `D` | Y | `D` |
| National identifier | 2–10 / 9 | `9(9)` | `NATIONAL_ID` (`PER_EXT_SEC_NATIONAL_ID_UE`, type `SSN`, primary) | Non-digits stripped, right-aligned into 9 with leading zeros; `00000` + last 4 when `ssnPolicy = MASKED` | Y | reject |
| Employee id | 11–30 / 20 | `A` | `PERSON_NUMBER` | Left-justified, truncated | Y | — |
| Last name | 31–50 / 20 | `A` | `LAST_NAME` (`NAME_TYPE = GLOBAL`) | Upper-cased, de-accented, non-ASCII dropped, truncated | Y | reject |
| First name | 51–65 / 15 | `A` | `FIRST_NAME` | Same as last name | N | spaces |
| Middle initial | 66 / 1 | `A` | `MIDDLE_NAMES` | First character after cleaning | N | space |
| Loan number | 67–76 / 10 | `A` | `EEV_ATTRIBUTE1`, DFF context `PFG 401K Loan` | Upper-cased, `A–Z 0–9 -` only | Y | reject |
| Loan type code | 77–78 / 2 | `A` | `ELEMENT_NAME` | `PFG_401K_LOAN_TYPE` lookup | Y | reject |
| Loan repayment amount | 79–90 / 12 | `9(11)S` | `RESULT_VALUE` (`PAY_EXT_SEC_RUN_RESULT_UE`, Pay Value, Regular) | → integer cents, zero-padded to 11, trailing `+`/`-` | Y | `00000000000+` |
| Loan payoff amount | 91–102 / 12 | `9(11)S` | `PFG_401K_LOAN_PAYOFF.ff` | Same | Y | `00000000000+` |
| Outstanding balance | 103–114 / 12 | `9(11)S` | `PFG_401K_LOAN_BALANCE.ff` | Same | Y | `00000000000+` |
| Pay period end date | 115–122 / 8 | `CCYYMMDD` | `G_LOAN/PERIOD_END_DATE`, else batch | Loan's own period wins | Y | — |
| Check date | 123–130 / 8 | `CCYYMMDD` | `G_LOAN/CHECK_DATE`, else batch | Loan's own date wins | Y | — |
| Loan status code | 131 / 1 | `A` | `PFG_401K_LOAN_STATUS.ff` | `PFG_401K_LOAN_STATUS` lookup | Y | `A` |
| Loan origination date | 132–139 / 8 | `CCYYMMDD` | `EEV_ATTRIBUTE2`, DFF | ISO → compact | N | spaces |
| Last payment date | 140–147 / 8 | `CCYYMMDD` | `PAYMENT_DATE` | ISO → compact | N | spaces |
| Source code | 148–149 / 2 | `A` | `PAYROLL_NAME` | `PFG_401K_SOURCE_CODE` lookup | Y | `RG` |
| Termination date | 150–157 / 8 | `CCYYMMDD` | `ACTUAL_TERMINATION_DATE` | ISO → compact | N | spaces |
| Termination indicator | 158 / 1 | `A` | derived | `Y` when a termination date is present, else `N` | Y | `N` |
| Filler | 159–200 / 42 | `A` | — | Spaces | Y | spaces |

## Trailer record — type `T`

| Target Field | Position/Length | Format | HCM Source | Transformation | Required | Default |
|---|---|---|---|---|---|---|
| Record type | 1 / 1 | `A` | — | Literal `T` | Y | `T` |
| Contract number | 2–9 / 8 | `A` | as header | Same value as the header | Y | — |
| Detail record count | 10–19 / 10 | `9(10)` | derived | Count of accepted loans, zero-padded | Y | `0000000000` |
| Total repayment amount | 20–34 / 15 | `9(14)S` | derived | Sum of detail repayments in cents | Y | `00000000000000+` |
| Total payoff amount | 35–49 / 15 | `9(14)S` | derived | Sum of detail payoffs | Y | `00000000000000+` |
| Total outstanding balance | 50–64 / 15 | `9(14)S` | derived | Sum of detail balances | Y | `00000000000000+` |
| File creation date | 65–72 / 8 | `CCYYMMDD` | as header | Same value as the header | Y | — |
| File creation time | 73–78 / 6 | `HHMMSS` | as header | Same value as the header | Y | — |
| Filler | 79–200 / 122 | `A` | — | Spaces | Y | spaces |

The trailer's totals are **fourteen** digits where a detail amount is eleven.
A thousand participants each near the detail ceiling would overflow an
eleven-digit total, and a silently truncated control total makes a correct
file fail Principal's reconciliation.

## Amount format

Every amount is integer cents, zero-padded, with the sign as a **trailing**
character:

```
       250.00  ->  00000025000+
      -156.25  ->  00000015625-
         0.00  ->  00000000000+
```

Trailing, because a negative repayment is legitimate — a reversed or
over-collected deduction is remitted back as one and Principal nets it — and
a leading sign would shift every digit column by one on those rows only.

Conversion is by string surgery, not float arithmetic, in both
implementations: `float('12.34') * 100` is `1233.9999999999998`, and while a
`round()` rescues that particular value, XSLT and Python would not always
rescue it identically. A third decimal place is truncated rather than rounded;
payroll delivers two.

## Fields Principal needs that HCM does not hold

Four of the twenty detail fields have no native home in Fusion. Each is called
out here with what was done about it, because these are the decisions most
likely to need revisiting against the real specification.

| Field | Why HCM has no source | Resolution |
|---|---|---|
| **Loan number** | Fusion models a deduction that repays a loan, not the loan. Principal's loan identifier is issued by Principal at origination and has no Fusion attribute. | Element entry DFF, context `PFG 401K Loan`, `EEV_ATTRIBUTE1`. Populated when the deduction is set up from Principal's origination advice. Absent → `MISSING_LOAN_NUMBER` reject, never a generated substitute: an invented identifier posts against nothing and is very hard to unpick afterwards. |
| **Original loan amount** | Same reason. Needed to derive the outstanding balance. | Same DFF, `EEV_ATTRIBUTE3`. |
| **Loan origination date** | Same reason. | Same DFF, `EEV_ATTRIBUTE2`. |
| **Outstanding balance** | Fusion holds no loan balance. | Derived: `PFG_401K_LOAN_BALANCE.ff` = original principal − inception-to-date repayments, on an **element-entry** ITD balance dimension. An assignment-level dimension reports the sum of both loans against each of a participant's two loans, and looks correct until somebody has two. |
| **Loan type** | Element classification distinguishes voluntary deductions, not general from residential loans. | `PFG_401K_LOAN_TYPE` lookup, keyed on element name. Unmapped → `UNMAPPED_LOAN_TYPE` reject rather than a default: defaulting to `01` misfiles a residential loan against a general amortisation schedule, and nobody notices for a month. |
| **Contract number** | A Principal contract is not a Fusion concept. | `PFG_401K_CONTRACT` lookup, keyed on legal employer. |
| **Loan status** | Fusion has no concept of a loan in default. | Derived: `PFG_401K_LOAN_STATUS.ff`, then the `PFG_401K_LOAN_STATUS` lookup. |

### The DFF

One context, `PFG 401K Loan`, on the element entry:

| Attribute | Holds | Format |
|---|---|---|
| `EEV_ATTRIBUTE1` | Principal loan number | Up to 10 characters |
| `EEV_ATTRIBUTE2` | Loan origination date | Date |
| `EEV_ATTRIBUTE3` | Original loan amount | Number, 2dp |

A DFF, not an extension attribute or a lookup, for one reason: it is
per-element-entry. A participant with two concurrent loans has two element
entries, and each needs its own loan number. Anything held at person or
assignment level cannot represent that, and the two loans would report the
same identifier.

## Rejects

A row that cannot be represented is held back, reported, and the rest of the
file is still delivered. One unmappable loan must not cost the other four
hundred participants their repayment posting.

| Reason | Raised when | Fix |
|---|---|---|
| `MISSING_CONTRACT` | Legal employer has no `PFG_401K_CONTRACT` row, or maps to a different contract than the file's | Add the lookup row, or scope the run to one contract with `legalEmployerName` |
| `MISSING_NATIONAL_ID` | No primary SSN on the person record | Add it in HCM; Principal has no other key to match on |
| `MISSING_LOAN_NUMBER` | DFF `EEV_ATTRIBUTE1` empty | Populate from Principal's origination advice |
| `UNMAPPED_LOAN_TYPE` | Element name has no `PFG_401K_LOAN_TYPE` row | Add the lookup row |
| `MISSING_NAME` | No last name on the person record | Fix in HCM |
| `AMOUNT_OVERFLOW` | An amount exceeds 11 digits of cents | Correct the DFF; almost always a data-entry slip |

Reject messages carry the employee number and the loan number and nothing
else — no amounts, no identifiers, no names. The run summary is written to
SFTP and quoted in an email, and neither is a place for a participant's
balance.

## Data cleansing

| Rule | Applied to | Why |
|---|---|---|
| Upper-case | All names | Principal's loader matches case-insensitively but stores what it is sent |
| De-accent | All names | `É → E`, `ñ → N`. A US-ASCII file cannot carry the original |
| Drop unmapped non-ASCII | All names | An em dash has no fold; dropping it keeps the halves of a hyphenated name together, and a character in a name must not cost somebody their repayment |
| Collapse whitespace | All text | Leading, trailing and repeated spaces |
| Truncate | Names, ids | To the column width; Principal matches on the identifier, and a surname clipped at 20 still reads |
| Reject, never truncate | Amounts | Dropping a leading digit turns $150,000.00 into $50,000.00, and it posts |
| Strip non-digits | National identifier | `123-45-6789 → 123456789` |
| Range-check dates | All dates | `28-02-2026` strips to eight digits that look like a date and are not; it becomes blank rather than the year 2802 |

## Adjusting to the real spec

When Principal's specification arrives, the change is bounded:

1. Edit the `LAYOUT` tables and the `left`/`right`/`amount` calls in
   `map_canonical_to_principal.xsl`.
2. Make the same edit to `header_record`, `detail_record` and
   `trailer_record` in `tools/generate_principal_file.py`.
3. Update the positions in `tests/test_layout.py` and the tables above.
4. `make test-pfg401k`.

Step 4 fails if steps 1 and 2 disagree, which is the point. Nothing else in
the integration knows a position — the canonical schema, the flow, the
delivery, the reconciliation and the notification are all layout-independent.

If the real layout is **delimited rather than fixed-width**, the change is
larger but still confined to the same two files plus
`schemas/principal-loan-file.nxsd`: the canonical model already holds every
value in its target representation.

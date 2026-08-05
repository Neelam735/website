# Test cases

Unit cases run in this repository against
[`samples/extract_output_sample.xml`](../samples/extract_output_sample.xml),
which was built so that every case below has a record in it. SIT cases need a
pod, an OIC instance and Principal's certification endpoint.

```bash
make test-pfg401k       # 132 unit tests
```

## Unit — layout

`tests/test_layout.py`. These exist because a fixed-width file has no
delimiter to reveal that a column has moved.

| # | Case | Expected result | Asserted by |
|---|---|---|---|
| L1 | Every record | Exactly 200 characters | `test_every_record_is_exactly_the_fixed_length` |
| L2 | Record order | `H`, then all `D`, then `T` | `test_records_are_in_header_details_trailer_order` |
| L3 | Every record | Encodes as US-ASCII | `test_the_file_is_ascii` |
| L4 | Header, every field | Positions per the layout table | `test_positions` |
| L5 | `testProductionFlag` = `P` | Position 63 is `P` | `test_production_flag_needs_an_explicit_p` |
| L6 | Flag is `prod`, `p`, `X`, empty | Position 63 is `T` | `test_anything_other_than_p_is_a_test_transmission` |
| L7 | Detail, every field | Positions per the layout table | `test_positions_of_an_ordinary_repayment` |
| L8 | Trailer, every field | Positions per the layout table | `test_positions` |
| L9 | Detail filler 159–200 | Blank — a field overrunning into it means the record was cut | `test_nothing_reaches_the_truncation_guard` |
| L10 | Trailer totals | 14 digits, not 11 | `test_the_totals_are_wider_than_a_detail_amount` |

## Unit — the edge cases that motivated the design

| # | Case | Sample record | Expected result | Asserted by |
|---|---|---|---|---|
| E1 | **Multiple concurrent loans** | 100502 | Two detail rows, same identifier, loan types `01` and `02` | `test_both_of_a_participants_concurrent_loans_appear` |
| E2 | **Loan payoff** | 100503 | Repayment and payoff both `00000018422+`, balance zero, status `P` | `test_a_payoff_carries_the_settling_amount_in_both_columns` |
| E3 | **Mid-period termination** | 100504 | Termination date `20260220`, indicator `Y`, status still `A` — the final repayment period is active; `D` belongs to the next one | `test_a_termination_sets_the_date_and_the_indicator` |
| E4 | **Refinance** | 100505 | Two rows: old loan `P` with a payoff, new loan `A` without | `test_a_refinance_sends_the_settled_loan_and_the_new_one` |
| E5 | **Suspended, unpaid leave** | 100506 | Zero repayment, balance outstanding, status `S` — silence would look like a broken feed | `test_a_suspended_loan_reports_zero_rather_than_nothing` |
| E6 | **Negative / adjusted amount** | 100507 | `00000015625-`, digit columns unmoved, total reduced | `test_a_negative_repayment_keeps_its_digit_columns`, `test_a_negative_repayment_reduces_the_total` |
| E7 | **Rehire** | 100508 | One row; origination date predates the current hire; loan carries across | `TestParity.test_the_full_sample_extract` |
| E8 | **Zero balance, settled** | 100513 | Row present with all zeros — tells Principal the loan closed rather than the participant vanishing | `TestParity.test_the_full_sample_extract` |
| E9 | **Off-cycle correction** | 100507 | Loan's own period `20260214` and source `OC`, not the batch's | `test_an_off_cycle_loan_carries_its_own_period_and_source` |
| E10 | **Accented / over-long name** | 100509 | `FERNANDEZVILLALOBOS `, `JOSE ANGEL     `, initial `I`, 200 characters | `test_names_are_folded_truncated_and_column_safe` |
| E11 | **No loans at all** | — | Header and trailer only, count `0000000000` | `TestParity.test_no_loans_at_all` |

## Unit — rejects

| # | Case | Sample record | Expected result |
|---|---|---|---|
| R1 | No loan number on the DFF | 100510 | `MISSING_LOAN_NUMBER`, row absent from the file |
| R2 | Element not in `PFG_401K_LOAN_TYPE` | 100511 | `UNMAPPED_LOAN_TYPE` — never a silent `01` |
| R3 | No national identifier | 100512 | `MISSING_NATIONAL_ID` |
| R4 | Amount wider than the column | 100514 | `AMOUNT_OVERFLOW` — never truncated |
| R5 | Legal employer on another contract | 100515 | `MISSING_CONTRACT` — never misfiled |
| R6 | No last name | (synthetic) | `MISSING_NAME` |
| R7 | Any reject | all | Absent from the detail rows and from the control totals |
| R8 | Any reject | all | Message carries no amount, identifier or name |

`tests/test_mapping.py::TestRejects`.

## Unit — money and dates

| # | Input | Expected | Why it is here |
|---|---|---|---|
| M1 | `250.00` | `25000` | Baseline |
| M2 | `12.34` | `1234` | `float * 100` gives `1233.9999999999998` |
| M3 | `8.005` | `800` | Truncated, not rounded — payroll delivers two decimals |
| M4 | `-0.00` | `0` | A trailing `-` on zero would report a reversal that did not happen |
| M5 | `.5`, `5.`, `1,234.56`, `$78.90` | `50`, `500`, `123456`, `7890` | Dirty input from a DFF |
| M6 | `` / `None` / spaces | `0` | Absent is not an error |
| D1 | `2026-02-28T09:15:00` | `20260228` | Time part discarded |
| D2 | `28-02-2026` | *empty* | Transposed format — would otherwise become the year 2802 |
| D3 | `02/28/2026` | *empty* | Same |
| D4 | `not-a-date`, `2026-2-8` | *empty* | Blank, not zero-filled: a zero date is one Principal tries to parse |
| D5 | `4712-12-31` | `47121231` | End-of-time passes through visibly, so an unconfirmed payroll is caught in review |

`tests/test_mapping.py::TestToCents`, `::TestToCcyymmdd`.

## Unit — XSLT / reference parity

`tests/test_xslt_parity.py`. Runs both implementations over the same input and
asserts identical bytes. `dvm:lookupValue` is registered as a real XPath
extension backed by the packaged lookup XML, so a passing run also proves the
maps and the packaged lookups agree.

| # | Case | Expected result |
|---|---|---|
| P1 | Full sample extract | 14 identical records |
| P2 | `ssnPolicy = MASKED` | Identical |
| P3 | No loans | Identical, 2 records |
| P4 | Negative and zero amounts | Identical |
| P5 | Eleven awkward decimal forms | Identical |
| P6 | Five name-folding cases | Identical |
| P7 | Four identifier shapes | Identical |
| P8 | Missing and malformed dates | Identical |
| P9 | Loan-level period override | Identical |
| P10 | Every reject reason | Identical |
| P11 | Unmapped legal employer | Identical, header and trailer only |

## Unit — reconciliation

The recount is implemented twice as well — `map_file_to_reconciliation.xsl` at
step 136, and `reconcile()` in the reference — and neither may consult the
canonical batch. So they are checked against each other, not against the thing
they exist to check.

`tests/test_layout.py::TestReconciliationCatchesCorruption`, run against a
deliberately damaged file:

| # | Corruption | Expected result |
|---|---|---|
| C1 | None | Reconciles |
| C2 | A detail row dropped | Fails |
| C3 | An amount shifted one column | Fails — the defect the whole check exists for |
| C4 | A detail row duplicated | Fails |

`tests/test_xslt_parity.py::TestRecountParity`:

| # | Case | Expected result |
|---|---|---|
| C5 | Sample file | Both recounts agree; record lengths report exactly `200` |
| C6 | Both recounts vs the trailer | Agree — the file reconciles |
| C7 | An amount shifted one column | Both disagree with the trailer. They disagree *differently* — the reference sums a mis-parsed number, the XSLT reads a non-numeric column and yields `NaN` — and either is a failure |
| C8 | A detail row dropped | Both disagree with the trailer |
| C9 | A record truncated to 150 characters | Record lengths report `200 150`, so step 140 throws. Counts and totals alone would pass |
| C10 | Empty file | Recounts to `0`, `0`, `0`, lengths `200` |

## Unit — status derivation and notification

`tests/test_status_map.py`.

| # | Input | Expected status |
|---|---|---|
| S1 | Delivered, reconciled | `DELIVERED` |
| S2 | Delivered with a reject | `DELIVERED_WITH_REJECTS` |
| S3 | Trailer/file mismatch | `RECONCILIATION_FAILED`, `Reconciled = false` |
| S4 | Duplicate run | `ALREADY_DELIVERED` |
| S5 | Nothing to send, `SKIP_SEND` | `NO_RECORDS_SKIPPED` |
| S6 | Technical fault | `FAILED`, category `TECHNICAL` |
| S7 | Fault before formatting | `Reconciled = N/A`, not `false` |
| S8 | Fault after retrieval | Detail advises `reprocessFlag=Y` |
| S9 | Fault before retrieval | Detail advises `reprocessFlag=N` |
| N1 | Any success | Subject leads with `OK`, carries contract and period |
| N2 | Rejects present | Subject carries `ACTION` — it must survive truncation in a phone preview |
| N3 | Any | Body carries no nine-digit sequence and no SSN-shaped string |
| N4 | Reconciliation failure | Body says **do not rerun** |
| N5 | Amounts | Rendered `4,998.52`, not `499852` — a reader has to be able to notice a wrong total |

## Unit — packaging

`tests/test_packaging.py`. Most of these deliberately corrupt a good archive.

| # | Case | Expected result |
|---|---|---|
| K1 | Built archive | Passes 130+ checks, no warnings |
| K2 | Two builds of one commit | Identical `sha256` |
| K3 | `ics.json` first entry | Yes — OIC reads it first |
| K4 | `--version` disagreeing with `ics.json` | Build refuses |
| K5 | A `.asc` / `.pem` in the tree | Build refuses |
| K6 | Missing manifest / descriptor / declared resource | Validation fails |
| K7 | A bound connection with no descriptor | Validation fails |
| K8 | A bound lookup with no definition | Validation fails — every row would take the default |
| K9 | Path traversal entry | Validation fails |
| K10 | `name="password" value="..."` in a descriptor | Validation fails |
| K11 | A PGP private key block | Validation fails |
| K12 | An SSN-shaped string in any packaged file | Validation fails |
| K13 | A layout field overlapping its neighbour | Validation fails |
| K14 | A layout field leaving a gap | Validation fails |
| K15 | A record not summing to 200 | Validation fails |
| K16 | A `LAYOUT` table deleted | Validation fails |
| K17 | Flow activities vs `project.xml` activities | Identical sets, both directions |
| K18 | Flow connections vs `project.xml` bindings | Identical sets |
| K19 | Flow lookups vs `project.xml` references | Identical sets |
| K20 | Every map the flow invokes | Declared as a resource in `project.xml` |

K17–K20 exist because `project.xml` states that it mirrors the flow step for
step, and two files describing one orchestration drift the moment somebody
edits one. The drift is invisible: OIC imports a descriptor missing an
activity perfectly well, and the flow file is documentation that nothing
executes — so what is left is a reviewer reading a description of an
integration that is not the one running.

## SIT — needs a pod and an instance

Run in order. S1–S4 gate everything after them.

| # | Case | Setup | Expected result |
|---|---|---|---|
| T1 | Extract submits | Submit Now, `reprocessFlag=N` | ESS request id returned, status reaches `SUCCEEDED` |
| T2 | Extract output lands in UCM | After T1 | Document titled `PFG_401K_LOANS_<date>` in the delivery account |
| T3 | Retrieval and decode | After T2 | Staged XML matches the UCM document byte for byte |
| T4 | End-to-end, cleartext | `pgpEncryptionEnabled=N`, test SFTP | File in the remote directory, reconciled, `DELIVERED` |
| T5 | Backoff | Extract taking >5 min | Poll intervals 30, 60, 120, 240, 300, 300… |
| T6 | Extract fails | Break a fast formula | `ExtractFailedError`, business fault, benefits notified, nothing delivered |
| T7 | Extract warns | Force a record-level error | `ExtractFailedError` — a `WARNING` extract would deliver a short file |
| T8 | Poll ceiling | `maxPollAttempts=2` | `TIMED_OUT` message says to check HCM before rerunning |
| T9 | Delivery misconfigured | Disable the UCM delivery option | Step 65 throws naming the account and title |
| T10 | PGP | `pgpEncryptionEnabled=Y` | `.pgp` delivered; Principal decrypts it in certification |
| T11 | Temp-then-rename | Watch the remote directory | `.tmp` appears first, final name only after the write completes |
| T12 | Duplicate guard | Run T4 twice | Second run `ALREADY_DELIVERED`, nothing sent, no page |
| T13 | Reprocess | Break SFTP, run; fix, rerun with `reprocessFlag=Y` | No new ESS request; same UCM document reused; delivered |
| T14 | Zero records | Period with no loans, `SEND_EMPTY` | Header and trailer only, count `0000000000`, delivered |
| T15 | Zero records | Same, `SKIP_SEND` | Nothing delivered, `NO_RECORDS_SKIPPED` |
| T16 | Partial delivery cleanup | Fault between steps 180 and 190 | `.tmp` removed from Principal's directory |
| T17 | Archive | After T4 | Cleartext copy in the UCM archive account under the run id |
| T18 | Summary | After any run | Summary XML in the SFTP archive directory, success or failure |
| T19 | Business fault routing | Force a reject | Benefits and integrations both notified |
| T20 | Technical fault routing | Break the SFTP credential | Integrations only |
| T21 | Masking | `ssnPolicy=MASKED` | Every detail identifier `00000nnnn` |
| T22 | Production flag | `testProductionFlag=P` | Position 63 is `P`; **only ever in production** |
| T23 | Volume | Full population, ~1,800 loans | Extract within its baseline, reconciled, one file |
| T24 | Concurrency | Two runs at once | Second finds the first's file and reports `ALREADY_DELIVERED` |

## UAT — with Principal

| # | Case | Expected result |
|---|---|---|
| U1 | Certification file, test flag `T` | Principal's loader accepts it |
| U2 | Their reconciliation | Their detail count and totals match our trailer |
| U3 | Loan type codes | Residential loans amortise on their residential schedule |
| U4 | A termination | Cure period starts from the date we sent |
| U5 | A negative repayment | Netted, not rejected |
| U6 | A payoff | Loan closed, not left with a residual balance |
| U7 | Two concurrent loans | Posted against the right loan numbers |
| U8 | Empty file | Read as "nothing to report", not as an error |

U2 is the one that matters most. If Principal's totals disagree with our
trailer, the layout is wrong somewhere the reconciliation cannot see it —
because our reconciliation checks that we wrote what we meant to write, and
only Principal can confirm that what we meant was right.

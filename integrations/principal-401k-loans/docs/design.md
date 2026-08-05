# Principal 401(k) Loans — outbound file: design

## What it does

Every week, this extracts the 401(k) loan repayments withheld in the payroll
period from Fusion HCM, formats them into Principal Financial Group's
fixed-width loan repayment file, encrypts it, and delivers it to their SFTP.

```
  Fusion HCM ──extract──▶ UCM ──▶ OIC scheduled orchestration ──PGP──▶ Principal SFTP
                                          │
                                          ├──▶ archive copy (UCM, cleartext)
                                          ├──▶ run summary (SFTP archive)
                                          └──▶ notification email
```

The money has already moved when this runs. Payroll withheld it from the
participant's cheque; what Principal needs is to be told, so they can credit
it against the loan. A week's file that does not arrive is a week of
repayments that do not post, and the participant finds out — not us — when
their loan balance is wrong or, at the far end, when it defaults.

That framing drives most of what follows: the failure this is designed
against is not "the run errored", which somebody notices, but "the run
succeeded and the file was wrong", which nobody does.

## Relationship to the reference build

This follows the patterns established by
[`core-hr-new-hire-load`](../../core-hr-new-hire-load/): the same source tree
layout, the same `ics.json` / `PROJECT-INF/project.xml` / `appinstances`
packaging, the same numbered activity ids, the same two-stage
source → canonical → target mapping, the same derived-status discipline, the
same reference-implementation-plus-parity-test approach, and the same
"nothing environment-specific in the archive" rule.

Deviations from it are called out in [Deviations](#deviations-from-the-reference-pattern)
below, with reasons.

> **A note on inputs.** The brief for this build referenced a "Laborlytics"
> extract and OIC integration as the gold-standard pattern, along with
> Principal's file specification and a field mapping sheet. None were attached
> to the request, and none are in this repository. `core-hr-new-hire-load` is
> the only prior OIC build here, so it is what the conventions below are
> modelled on. The file layout is a designed one — see the warning at the top
> of [`field-mapping.md`](field-mapping.md) — and the places it would need to
> change are listed there.

## Flow

| Step | Action | Notes |
|---|---|---|
| 10 | Schedule | Weekly Mon 05:00, after the payroll confirm, inside Principal's collection window |
| 20 | Assign run context | Stamps `runId` on every artifact this run produces |
| 30 | Switch: submit or reuse | `reprocessFlag=Y` skips submission — see *Reruns* |
| 31 | HCM: `submitESSJobRequest` | Runs the extract; returns an ESS request id |
| 40 | While: poll ESS status | Exponential backoff, 30s → 300s, 40 attempts |
| 50 | Switch: extract outcome | `ERROR`/`WARNING`/timeout each throw distinctly |
| 60 | HCM: UCM `searchDocuments` | By title prefix and period, newest first |
| 65 | Switch: no output | A succeeded extract with no document = misconfigured delivery |
| 70 | HCM: UCM `getFile` | Base64 in the SOAP response |
| 80 | Stage File: write | Decode straight to disk, not into a variable |
| 90 | Stage File: read entire | Whole, not segmented — see *Why not segmented* |
| 100 | Map extract → canonical | Flatten, look up, normalise, validate, total |
| 110 | Switch: zero records | `SEND_EMPTY` or `SKIP_SEND` |
| 120 | Map canonical → Principal | The only place positions exist |
| 130 | Stage File: write | The formatted file |
| 135 | Stage File: read entire | Read the finished file back off disk |
| 136 | Map file → reconciliation | Recount, given only the file |
| 140 | **Switch: reconcile** | Compare against the trailer; mismatch throws |
| 150 | Switch: PGP encrypt | On by default |
| 160 | SFTP: list files | Duplicate guard |
| 170 | Switch: already delivered | Report and stop, do not page |
| 180 | SFTP: write `.tmp` | Temp-then-rename handshake |
| 190 | SFTP: rename | Atomic at Principal's end |
| 200 | Switch: trigger file | Off by default |
| 210 | HCM: archive to UCM | Cleartext copy |
| 220 | Map status → summary | Derives the real outcome |
| 230 | SFTP: write summary | The durable audit record |
| 240 | Notify | Email with counts and rejects |
| F1–F6 | Global fault handler | Classify, clean up, record, notify, rethrow |

## Design decisions

### The detail grain is the loan, not the participant

A participant may hold a general-purpose loan and a primary-residence loan
concurrently — the IRS permits it, and the two amortise on different
schedules. One row per participant would silently merge them, and Principal
would post the combined amount against whichever loan number arrived.

So `G_LOAN` nests under `G_EMPLOYEE` in the extract and the canonical model is
a flat list of loans. The refinance case in the sample — one loan settled and
another opened in the same period — is the same structure doing its job.

### The trailer is checked against the file, not derived from it

Step 135 reads the finished file back off disk, step 136 recounts it, and step
140 compares. This is the single most important part of the flow and the one
most likely to look redundant.

The trailer's figures come from the canonical batch. The recount comes from
the text about to be delivered. A formatting fault — an amount landing one
column left — leaves the canonical batch perfectly correct and the file
corrupt, and the two disagree. Any design where the trailer is computed from
the formatted rows makes them agree by construction and the check proves
nothing. That is precisely the weakness of the BI Publisher eText route, and
the main reason it is the fallback rather than the delivery path.

Keeping it honest takes some deliberate awkwardness. `map_file_to_reconciliation.xsl`
is given the file and nothing else — not the canonical batch, not the counts,
not even the column positions, which are written out again rather than shared
with the formatting map. The duplication is the point: it is a stocktake done
by counting the shelves rather than by re-reading the ledger. Step 135 reads
from disk for the same reason, rather than reusing the message that wrote it.

The check compares record lengths as well as counts and totals. Damage in a
name column sums perfectly and only the record's length gives it away.

A mismatch throws and delivers nothing. Delivering an unreconciled file is
worse than delivering none: Principal posts it, and unwinding a wrong posting
takes weeks.

### Two-stage mapping

Extract → canonical → file, rather than extract → file directly.

Everything that can go wrong with the *data* — a missing loan number, an
unmapped element, an over-wide amount, an accented surname, a transposed date
— happens in the first map. By the time the formatting map runs, every value
is already in its target representation and every unusable row is a reject, so
the second map is a sequence of pad-and-concatenate calls that can be checked
against the layout table by reading down the file.

It also means the layout can be replaced without touching a line of business
logic, which matters given that the layout here is a designed one pending
Principal's specification.

### Amounts are integer cents, converted by string surgery

`float('12.34') * 100` is `1233.9999999999998`. A `round()` rescues that
value; it does not rescue every value, and more to the point the XSLT and the
Python reference would not always rescue it the same way, which would break
parity for reasons that have nothing to do with the mapping.

Splitting on the decimal point and concatenating is exact and trivially
reproducible in any language. `tests/test_xslt_parity.py` runs both
implementations over `12.34`, `0.1`, `.5`, `8.005`, `99.999`, `-0.00` and
others precisely to hold that line.

Control totals are then summed as integers. The XSLT builds the accepted loans
into a variable and reads it back with `exsl:node-set` so `sum()` operates on
integer cents; the alternatives in XSLT 1.0 are recursive summation, which
exceeds the template depth limit on a large file, or summing the raw decimals
as doubles and scaling once, which can disagree with the sum of the rounded
per-row values by a cent. A cent's disagreement between the trailer and the
details is exactly what step 140 exists to catch, so it must not be designed
in.

### Bad rows are rejected, not fatal — except when they are ambiguous

A loan that cannot be represented is held back and reported; the rest of the
file goes. One unmappable loan must not cost four hundred people their
repayment posting.

But "reject the row" is not always the safe answer, and the two cases where it
is not are worth stating:

- **Unmapped loan type** rejects rather than defaulting to `01`. A default
  would misfile a residential loan against a general-purpose amortisation
  schedule — a wrong answer that looks right for about a month.
- **An over-wide amount** rejects rather than truncating. Truncation drops a
  leading digit, turning $150,000.00 into $50,000.00, and it posts.

Where the ambiguity is harmless, the opposite choice is made: an unmapped
payroll takes the `DEFAULT` source code rather than rejecting, because a wrong
source code is a reporting nuisance at Principal's end and holding the whole
remittance for it would cost participants interest.

### Delivery is temp-then-rename, and idempotent

Principal's collector polls their inbound directory on a timer. A file
matching the real pattern is picked up the moment it appears, so writing
straight to the final name lets them collect a half-uploaded file and reject
the truncated result. Step 180 writes `<name>.tmp`; step 190 renames, which is
atomic at their end.

Step 160 is the duplicate guard. A rerun after a delivery that succeeded but
whose summary write failed would otherwise send the same period twice, and
Principal posts both — every participant's loan repaid double. The file name
embeds the contract and the period end date, so an existing file for that pair
means the period is already there. It reports `ALREADY_DELIVERED` and stops:
a duplicate run is an operational hiccup, not a data problem, and should not
page anybody at 05:00.

### Status is derived, not reported

`DELIVERED` is not the only success and `FAILED` is not the only failure. Six
outcomes stay distinct because each needs a different response:

| Status | What happened | What to do |
|---|---|---|
| `DELIVERED` | Sent, trailer and details agree | Nothing |
| `DELIVERED_WITH_REJECTS` | Sent, but short by the rejected rows | Fix the records in HCM, rerun |
| `RECONCILIATION_FAILED` | Built, found inconsistent, nothing sent | **Do not rerun** — a rerun produces the same file |
| `ALREADY_DELIVERED` | Duplicate run, nothing sent | Nothing |
| `NO_RECORDS_SKIPPED` | Nothing to send under `SKIP_SEND` | Nothing |
| `FAILED` | Everything else | Depends on the fault category |

`DELIVERED_WITH_REJECTS` exists so that a run which sent a file short by five
participants does not send a green email. `RECONCILIATION_FAILED` is separate
from `FAILED` because the instinct on a failure is to rerun, and that is the
wrong instinct here.

### Zero records send a file, by default

A period with no loan repayments is normal — a semi-monthly payroll with no
confirm that week, a small population where every loan happens to be settled.
`SEND_EMPTY` writes a header and trailer with zero details, which lets
Principal tell "nothing to report" from "the feed broke". Silence is
indistinguishable from failure, and by the time anyone investigates it has
been several weeks.

`SKIP_SEND` exists because some Principal profiles reject a detail-less file.
Which applies is their onboarding profile's call, not ours.

### National identifiers

The extract always delivers the identifier in full. An extract cannot be
re-run to recover a value it did not emit, and the masking decision belongs to
the environment the file is built in, not to the extract; UCM's security
account protects it at rest in the meantime.

OIC applies `ssnPolicy`. `FULL` is required in production — it is how
Principal matches a participant, and a masked production file matches nobody.
`MASKED` sends `00000` plus the last four and exists for non-production
environments.

Nothing downstream of the file carries an identifier. Reject messages carry
the employee number and the loan number; the notification body carries counts
and aggregates. Email is not an encrypted channel and this feed exists
precisely because the data is sensitive. `tests/test_status_map.py` asserts
the notification body contains no nine-digit sequence.

### Business and technical faults are separated

They need different people and different recovery:

- **Business** — reconciliation, unmapped data, extract errors. The fix is in
  HCM or a lookup, the benefits team owns it, and a rerun after the fix is
  safe.
- **Technical** — connectivity, API, runtime. The fix is in the platform,
  integrations owns it, and the rerun may need `reprocessFlag=Y`.

The handler records which, along with whether reusing the extract output is
safe, because neither is derivable from a fault name once it reaches an inbox
at 05:00.

### Reruns reuse the extract output

`reprocessFlag=Y` skips submission and reuses the most recent successful
extract output for the run date.

Asking HCM to recompute a payroll period it has already reported on can return
a different answer if anything was corrected in between — and the period has
already been partly reported to Principal. Reusing the output that this run
was working from is what makes a retry safe. The summary states whether it is
available, so the decision is not made from a fault name.

The extract archive is retained 90 days, which covers a quarter-end
reconciliation with Principal.

### Why the extract is read whole, not segmented

The reference build reads its input in segments so a large file need not fit
in memory. This does not, because the control totals have to be computed
across every detail row before the first line is formatted. Segmenting would
move the accumulation into the flow and lose the single-map reconciliation —
trading the check that matters most for memory headroom on a file that is
thousands of rows, not hundreds of thousands.

Step 80 still decodes straight to a staged file rather than into a variable,
so the base64 payload is never held as a string.

## Deviations from the reference pattern

| Deviation | Reason |
|---|---|
| Reads the staged file whole rather than in segments | Control totals need the complete batch; see above |
| One global fault handler rather than a per-file scoped one | There is one file in flight, so there is nothing to continue to; every fault ends the run |
| Fault handler rethrows rather than suppressing | A green instance in the monitor for a run that delivered nothing is worse than a red one; the weekly check is the monitor |
| Adds `icspackage/lookups/` to the archive | Four data mappings that benefits maintains without a redeploy. The reference had none |
| `build_iar.py` reads identity from `ics.json` rather than a module constant | One statement of what the archive is, in the file OIC reads first |
| `validate_iar.py` adds a layout check, a lookup-binding check and an OIC-shaped password pattern | The layout is this integration's highest-risk artifact and no importer would ever check it. The password pattern is a gap in the reference validator: it matches `password = "..."` but not `name="password" value="..."`, which is the shape a leaked credential would actually take in an `.iar` |
| `validate_iar.py` refuses an archive containing anything shaped like a national identifier | This file exists to move that data; none of it belongs in the archive that describes how |

## Known limitations

- **The file layout is designed, not specified.** See the warning in
  [`field-mapping.md`](field-mapping.md). It is internally consistent and
  fully tested; it has not been validated against a Principal specification,
  because none was supplied.
- **One contract per run.** A second legal employer on a different contract
  rejects rather than splitting into a second file. Scope the run with
  `legalEmployerName`, or schedule one run per contract. Multi-contract
  splitting would mean multiple files, multiple duplicate guards and multiple
  trailers in one instance, and no requirement for it has been stated.
- **Interest is not modelled or sent.** Principal amortises from the
  origination terms they hold; the balance we send is a principal-basis
  cross-check, not an authority.
- **`PFG_401K_LOAN_BALANCE.ff` returns zero when the DFF has no original
  principal.** The loan number check almost always rejects such a row first,
  since an entry set up without its principal was set up without its loan
  number. Where the principal alone is missing, the row goes out with a zero
  balance. The fix is data, not formula.
- **Date validation is range-checking, not a calendar.** `20260231` passes.
  The point is to catch transposed formats, not to reimplement a calendar in
  XSLT 1.0; Principal validates the date properly.
- **The `.iar` has not been round-tripped through an OIC instance.** None was
  available. See the note in [`../README.md`](../README.md#verification-status).

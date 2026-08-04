# Core HR — New Hire Load (HDL via OIC): design

## What it does

Every night, an ATS extract of new hires lands on SFTP. This integration turns
it into HCM Data Loader files, loads them into Fusion Core HR, waits for the
load to finish, and reports what happened.

```
  ATS  ──SFTP──▶  OIC scheduled orchestration  ──▶  UCM  ──▶  HDL  ──▶  Core HR
                            │
                            ├──▶ run summary + rejects (SFTP)
                            └──▶ notification email
```

## Why HDL and not the REST API

Fusion offers `workers` REST and HDL for the same job. HDL wins here for three
reasons:

- **Atomic per-person load.** A worker is nine related objects (person, name,
  email, phone, legislative data, address, work relationship, work terms,
  assignment). REST would need nine ordered calls per hire with compensation
  logic when call six fails. HDL takes them as one data set.
- **Throughput.** A 5,000-row acquisition file is one HDL import. Over REST it
  is 45,000 calls against a governor-limited endpoint.
- **Restartability.** A failed HDL data set can be corrected and resubmitted in
  HCM without replaying anything through OIC.

The cost is asynchrony: HDL returns a process id, not a result. That is what
the poll loop in the flow is for.

## Flow

| Step | Action | Notes |
|---|---|---|
| 10 | Schedule | Daily 02:00, after the ATS extract window |
| 20 | Assign run context | Stamps `batchId` on every artifact this run produces |
| 30 | FTP List Files | `NEWHIRE_*.csv` in the inbound directory |
| 40 | Switch | No files is a normal night — exit quietly |
| 50 | For each file | **Sequential**; see *Concurrency* below |
| 51 | Stage File: Read in segments | 500 rows at a time, so a large file need not fit in memory |
| 52 | Map CSV → canonical | Source-specific logic, isolated here |
| 60 | For each business object | Nine objects, in dependency order |
| 61 | Map canonical → HDL | One parameterised map, invoked nine times |
| 63 | Stage File: Write | `<Object>.dat` |
| 70 | Stage File: Zip | Flat `Worker.zip`, no directory entries |
| 80 | HCM: Import Bulk Data | Uploads to UCM and submits the import |
| 90 | While: poll status | Until terminal or `maxPollAttempts` |
| 110 | HCM: error report | Only when HDL reports failed rows |
| 120 | Map status → summary | Derives the real outcome |
| 130 | FTP Write summary | Durable audit record |
| 140 | FTP Move source | Archive, **after** the summary is durable |
| 150 | Notify | Email with counts and rejects |

## Design decisions

### Two-stage mapping

CSV → canonical → HDL, rather than CSV → HDL directly.

The CSV shape belongs to whichever ATS is feeding us today. The canonical shape
belongs to this integration. Adding a second source system is then one new
inbound map instead of a second copy of the HDL logic — and the HDL logic is
the part that is expensive to get right and expensive to get wrong.

### Deterministic SourceSystemIds

Every `SourceSystemId` is derived from the employee number: `WKR_100501`,
`ASG_100501`, and so on. No timestamps, no sequences, no random component.

This is what makes the load idempotent. Re-running yesterday's extract MERGEs
onto the same records instead of creating a second Jane Doe. Given that the
recovery procedure for almost any failure is "fix and re-run", non-deterministic
keys would make recovery the most dangerous operation in the system.

### Sequential file processing

Step 50 is deliberately not parallel. Two concurrent HDL imports touching the
same business objects contend on the same records in HCM, and the failure mode
is partially-loaded workers that need manual repair.

### Status is derived, not reported

HDL reports `COMPLETED` whenever the import process finished — including a run
where every single row errored. Passing that through would mean a green
notification for a night when nobody got hired.

`map_status_to_summary.xsl` derives the outcome from the row counts:

| HDL says | Loaded | Failed | Reported as |
|---|---|---|---|
| COMPLETED | > 0 | 0 | `COMPLETED` |
| COMPLETED | > 0 | > 0 | `COMPLETED_WITH_ERRORS` |
| COMPLETED | 0 | > 0 | `FAILED` |
| ERROR / FAILED | — | — | `FAILED` |
| anything, poll ceiling hit | — | — | `TIMED_OUT` |

`TIMED_OUT` is kept distinct from `FAILED` on purpose. A timed-out load may
still be running, and resubmitting it duplicates hires — so the notification
for that case says to check the data set before resubmitting.

### Bad rows are dropped, not fatal

A row missing a last name is rejected and reported; the rest of the file still
loads. One malformed record should not hold up everyone else's start date.

Rejects go to the summary file and the notification, so the source team gets
them back the same morning.

### Sanitising rather than rejecting on delimiters

HDL files are pipe-delimited with no quoting, so an embedded `|` or newline
silently shifts every following attribute by one column — a corruption that
loads successfully and is discovered weeks later. Those characters are replaced
with spaces on the way in. A stray pipe in an address line should not fail a
hire, but it must never be able to shift a column.

### Ordering of archive and audit

The source file is moved to the archive directory (step 140) only after the run
summary is durably written (step 130). Reversed, a failure between the two
would leave the extract gone and no record of what happened to it.

## Two implementations of one mapping

The mapping exists twice:

- `maps/map_canonical_to_hdl.xsl` — what runs in OIC.
- `tools/generate_worker_dat.py` — the reference implementation.

XSLT is what OIC executes but is slow to iterate on and awkward to test. The
Python version is readable, runs locally in milliseconds, and is what the
mapping tests assert against.

Two implementations only stay honest if something checks them, so
`tests/test_xslt_parity.py` runs both over the same inputs and asserts the
output matches byte for byte — including the sparse rows, the alternative date
formats, and the rows that should be rejected.

## Security

- **No credentials in the archive.** OIC does not export secrets; the import
  wizard prompts. Connection descriptors carry `${PLACEHOLDER}` values, and
  both the build and the validator refuse an archive containing key material or
  a hard-coded password.
- **Pin the SFTP host key.** Without a pinned fingerprint, the first connection
  to an impostor host succeeds silently.
- **Dedicated integration account**, not a named person's — a leaver disabling
  the account takes the nightly load down with them.
- **New-hire extracts are personal data**: dates of birth, home addresses, and
  potentially national identifiers. Encrypt at rest on the SFTP server, keep
  the archive directory on a retention policy, and enable PGP on the connection
  if the extract carries national identifiers.

## Known limitations

- **Hires only.** `ActionCode` defaults to `HIRE`. Rehires and conversions need
  their own action codes and, for a rehire, the existing person's
  `PersonNumber` rather than a new one.
- **No manager hierarchy.** `ManagerFlag` is carried, but the reporting
  relationship (`WorkerManager`) is not loaded. A manager who is themselves in
  the same file may not exist yet when the assignment loads. Load hierarchies
  in a second pass.
- **No payroll, salary, or element entries.** Assignment-level only.
- **Poll ceiling is one hour** at the defaults. A very large acquisition file
  can exceed it; raise `maxPollAttempts` for those runs rather than letting the
  run report `TIMED_OUT`.
- **The reference implementation is stricter about dates than HDL.** Both
  reject anything that is not one of the four accepted formats, which is
  intentional — an ambiguous `03/04/2026` should fail loudly, not load as the
  wrong month.

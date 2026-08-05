# Core HR — New Hire Load: runbook

## Build the archive

```bash
make build            # -> dist/NEW_HIRE_LOAD_01.00.0000.iar
make validate         # structural checks before it touches an instance
make test             # 81 tests: mapping, XSLT parity, status, packaging
```

The build is reproducible: same commit, same bytes, same `sha256`. Record the
checksum with the change ticket, and you can prove later that what is deployed
is what was reviewed.

## Before the first import

1. **Register the source system owner.** In HCM: *Setup and Maintenance →
   Manage Common Lookups → `HRC_SOURCE_SYSTEM_OWNER`*. Add `OIC_NEWHIRE`.
   Without it, every row fails on lookup and the first run reports `FAILED`
   with nothing loaded.
2. **Create the integration user** with:
   - Human Capital Management Integration Specialist
   - HCM Data Loader: Load Data, Import Data, Review Data Set
   - Attachments User (for the UCM upload)
3. **Create the SFTP directories**: `/hcm/newhire/in`, `/hcm/newhire/archive`,
   `/hcm/newhire/reject`.
4. **Capture the SFTP host key fingerprint** and put it in the connection.
5. **Confirm the reference data exists** in the target pod: legal employers,
   business units, jobs, grades, departments, locations, positions. HDL will
   reject an assignment whose `JobCode` does not resolve, and this is the most
   common cause of a first-run failure.

## If the import fails with "path not found"

The archive layout is version-specific and not fully published. Rather than
guessing, take the layout from the instance itself:

1. In the target instance, export any existing integration (any one will do).
2. `python3 tools/compare_to_reference.py that_export.iar`
3. The first section lists paths the instance's export has that ours does not.
   Create them under `src/`, `make build`, re-import.

The artifacts under `src/.../maps/` and `src/.../schemas/` are independent of
the packaging. If the archive route stays blocked, build the flow in the OIC
designer following `flow/NEW_HIRE_LOAD.flow.json` action by action — the XSLTs
import directly into the mapper and the schemas upload as-is — then export the
`.iar` from OIC. That route always works.

## Import into OIC

1. *Integrations → Import*, select the `.iar`.
2. Supply credentials for each of the three connections when prompted — they
   are not in the archive.
3. Test each connection, then activate them.
4. *Actions → Update Property Values*: set `environmentName`, `notifyTo`, the
   directories, and `sourceSystemOwner` for this environment.
5. **Set `importMode` to `IMPORT_ONLY` for the first run.** The data set is
   staged in HCM for inspection without committing anything to Core HR.
6. Activate, with tracing on for the first run.

## First run

```bash
# Dry run locally first — no instance involved.
python3 tools/generate_worker_dat.py \
    --csv hdl/samples/newhire_sample.csv --out /tmp/hdl --zip
```

Then in OIC, submit the schedule ad hoc with a two- or three-row extract.

Check, in order:

1. **OIC monitoring** — the instance completed, and the tracking shows the
   `batchId` and `dataSetName`.
2. **HCM** — *Data Exchange → Import and Load Data*, find the data set. In
   `IMPORT_ONLY` mode it is staged; review the object counts.
3. **The summary file** in the reject directory.
4. **The notification email** — counts should reconcile:
   `SourceRows = Accepted + RejectedInFlight`.

When the staged data set looks right, switch `importMode` to `IMPORT_AND_LOAD`
and re-run.

## Reading the outcome

| Status | Meaning | Action |
|---|---|---|
| `COMPLETED` | Everything loaded | None |
| `COMPLETED_WITH_ERRORS` | Some rows failed in HDL | Fix at source, re-drop the extract |
| `FAILED` | Nothing loaded, or HDL errored | Investigate before re-running |
| `TIMED_OUT` | Polling gave up; load may still be running | **Check HCM before resubmitting** |
| `NOT_STARTED` | HDL never picked the data set up | Check the UCM upload and the account's permissions |

## Re-running a failed load

Safe by design. Every `SourceSystemId` is derived from the employee number, so
re-loading the same person MERGEs onto the existing record rather than creating
a duplicate.

1. Correct the extract at source.
2. Drop it in the inbound directory (any file name matching `NEWHIRE_*.csv`).
3. Let the schedule pick it up, or submit ad hoc.

Rows that already loaded will merge harmlessly. There is no need to strip them
out, and doing so risks missing a correction.

**The one exception is `TIMED_OUT`.** Confirm in HCM that the original data set
is no longer running before resubmitting.

## Troubleshooting

**Every row fails with an invalid-lookup error**
`OIC_NEWHIRE` is missing from `HRC_SOURCE_SYSTEM_OWNER`. See step 1 above.

**`Assignment` rows fail, everything else loads**
Reference data. The `JobCode`, `GradeCode`, `LocationCode`, `DepartmentName` or
`PositionCode` in the extract does not exist in the target pod. The HDL error
report names the attribute.

**`WorkTerms`/`Assignment` fail with an unresolved parent**
The `WorkRelationship` row for that person did not load. Check the `Worker` and
`WorkRelationship` errors first — child failures here are usually downstream
symptoms, not independent problems.

**Columns are shifted in the loaded data**
Should not be possible — `|`, tabs and newlines are replaced on the way in, and
`tests/test_generate_worker_dat.py` covers it. If it happens, the extract is
reaching the parser in an encoding that is not UTF-8.

**Status stays `NOT_STARTED`**
The file reached UCM but HDL did not pick it up. Check the integration user has
*Import Data*, and that the archive is flat — a zip with directory entries is
accepted by UCM and ignored by HDL.

**Nothing runs at all, no email**
An empty inbound directory exits quietly by design (step 40). Confirm the ATS
actually delivered, and that the file matches `filePattern`.

## Changing the mapping

1. Edit **both** `maps/map_canonical_to_hdl.xsl` and
   `tools/generate_worker_dat.py`.
2. `make test` — the parity suite fails if they disagree, which is the point.
3. Bump the version, rebuild, re-import.

Editing only the XSLT will pass the mapping tests and fail parity. Editing only
the Python will pass everything and change nothing in production — which is why
parity is enforced rather than documented.

# Core HR — New Hire Load (HDL via OIC)

Scheduled Oracle Integration Cloud orchestration that reads an ATS new-hire
extract from SFTP, builds HCM Data Loader files for the Worker business object,
loads them into Fusion Core HR, polls the import to completion, and reports the
outcome.

```bash
make test       # 81 tests
make build      # -> dist/NEW_HIRE_LOAD_01.00.0000.iar
make validate   # structural checks before it touches an instance
```

## What's here

```
src/                          exploded .iar — everything below is packaged
  ics.json                    archive table of contents
  icspackage/
    appinstances/             one descriptor per connection (placeholders, no secrets)
    schedule/                 schedule definition
    project/NEW_HIRE_LOAD_01.00.0000/
      PROJECT-INF/project.xml activities and sequence
      ics_project_attributes.properties
      resources/processor_10/resourcegroup_10/
        flow/                 the orchestration, action by action
        maps/                 four XSLT maps
        schemas/              nXSD for the CSV and .dat files, XSD for canonical + summary
        wsdls/                schedule trigger contract

tools/
  build_iar.py                packages src/ into a reproducible .iar
  validate_iar.py             checks an archive before import
  compare_to_reference.py     diffs our layout against a real instance export
  generate_worker_dat.py      reference implementation of the HDL mapping

tests/                        mapping, XSLT parity, status derivation, packaging
hdl/samples/                  sample extract and the .dat files it produces
docs/                         design.md, runbook.md, field-mapping.md
```

## The pipeline

```
NEWHIRE_*.csv  ──nXSD──▶  csv XML
               ──map_csv_to_canonical.xsl──▶   canonical batch
               ──map_canonical_to_hdl.xsl──▶   9 × <Object>.dat
               ──zip──▶  Worker.zip  ──▶  UCM  ──▶  HDL  ──▶  Core HR
```

One source row becomes up to nine HDL rows: `Worker`, `PersonName`,
`PersonEmail`, `PersonPhone`, `PersonLegislativeData`, `PersonAddress`,
`WorkRelationship`, `WorkTerms`, `Assignment` — written in that order, because
HDL resolves a child row's parent by `SourceSystemId`.

See [`docs/field-mapping.md`](docs/field-mapping.md) for the attribute-level
mapping, [`docs/design.md`](docs/design.md) for why it is built this way, and
[`docs/runbook.md`](docs/runbook.md) for importing and operating it.

## Three things worth knowing

**The load is idempotent.** Every `SourceSystemId` is derived from the employee
number — `WKR_100501`, `ASG_100501`. Re-running an extract MERGEs onto the same
records rather than creating a second Jane Doe. Since the recovery procedure
for nearly any failure is "fix and re-run", this is what makes recovery safe.

**`COMPLETED` from HDL is not success.** HDL reports `COMPLETED` whenever the
import process finished, including a run where every row errored. The status
map derives the real outcome from the row counts, so a night when nobody got
hired does not send a green email.

**The mapping is implemented twice, and something checks that.**
`map_canonical_to_hdl.xsl` runs in OIC; `generate_worker_dat.py` is the
readable reference. `tests/test_xslt_parity.py` runs both over the same inputs
and asserts identical bytes — sparse rows, alternative date formats, rejected
rows and all. Change one without the other and the suite fails.

## Try it without an instance

```bash
python3 tools/generate_worker_dat.py \
    --csv hdl/samples/newhire_sample.csv --out /tmp/hdl --zip
```

Produces the nine `.dat` files and a flat `Worker.zip`, exactly as the
integration would.

## Before importing

The archive carries no credentials — OIC does not export secrets and the import
wizard prompts for them. Both the build and the validator refuse an archive
containing key material or a hard-coded password.

Two prerequisites cause almost every first-run failure:

1. `OIC_NEWHIRE` must be registered in `HRC_SOURCE_SYSTEM_OWNER` in HCM.
2. Reference data (`JobCode`, `LocationCode`, `DepartmentName`, …) must exist
   in the target pod.

Set `importMode` to `IMPORT_ONLY` for the first run in any environment: the
data set is staged in HCM for inspection without committing to Core HR. Full
sequence in [`docs/runbook.md`](docs/runbook.md).

## Scope

Hires only, at assignment level. Rehires and conversions need their own action
codes; manager hierarchies, payroll and salary are not loaded. Limitations are
listed in [`docs/design.md`](docs/design.md#known-limitations).

## Verification status

Everything in this repository is tested and green: the mapping, the parity
between the two implementations, the status derivation, and the packaging.

The `.iar` has **not** been round-tripped through an OIC instance here — none
was available. The first build used a layout OIC rejected with "path not
found"; it was missing `ics.json`, `icspackage/appinstances/` and
`PROJECT-INF/project.xml`, and the current layout corrects that. Whether the
correction is sufficient is not something this repository can prove.

**If it still does not import**, do not guess at the layout — get the real one:

```bash
# Export any integration from the target instance, then:
python3 tools/compare_to_reference.py exported_from_instance.iar
```

That prints exactly which paths the instance's own export has that ours does
not. The mapping artifacts under `src/.../maps/` and `src/.../schemas/` are
independent of the packaging and carry over unchanged either way — they also
import directly into the OIC designer if you build the flow there and export
the `.iar` from OIC, which is the route that always works.

# Principal 401(k) Loans — outbound file

Scheduled Oracle Integration Cloud orchestration that runs an HCM Extract of
401(k) loan repayments withheld in the payroll period, retrieves its output
from UCM, formats it into Principal Financial Group's fixed-width loan
repayment file, PGP-encrypts it, and delivers it to their SFTP.

```bash
make test-pfg401k       # 132 tests
make build-pfg401k      # -> dist/PRINCIPAL_401K_LOANS_01.00.0000.iar
make validate-pfg401k   # structural checks before it touches an instance
```

## What's here

```
src/                          exploded .iar — everything below is packaged
  ics.json                    archive table of contents
  icspackage/
    appinstances/             one descriptor per connection (placeholders, no secrets)
    lookups/                  four data mappings, maintained in the OIC console
    schedule/                 schedule definition
    project/PRINCIPAL_401K_LOANS_01.00.0000/
      PROJECT-INF/project.xml activities and sequence
      ics_project_attributes.properties
      resources/processor_10/resourcegroup_10/
        flow/                 the orchestration, action by action
        maps/                 five XSLT maps
        schemas/              extract XSD, canonical XSD, fixed-width nXSD, summary XSD
        wsdls/                schedule trigger contract

hcm-extract/                  the HCM side — not packaged in the .iar
  PRINCIPAL_401K_LOANS_EXTRACT.xml   extract design: data groups, filters, delivery
  fast-formulas/                     five Extract Rule formulas
  bip/                               data model and eText template (fallback route)

tools/
  build_iar.py                packages src/ into a reproducible .iar
  validate_iar.py             checks an archive before import
  generate_principal_file.py  reference implementation of the mapping

tests/                        layout, mapping, XSLT parity, status, packaging
samples/                      sample extract output and the file it produces
docs/                         design, field-mapping, runbook, test-cases,
                              deployment-checklist
```

## The pipeline

```
HCM Extract ──ESS──▶ UCM ──getFile──▶ extract XML
            ──map_extract_to_canonical.xsl──▶  canonical loan batch
            ──map_canonical_to_principal.xsl──▶ 200-char H/D/T records
            ──recount and compare──▶ ──PGP──▶ Principal SFTP (.tmp, then rename)
```

One loan becomes one detail record. Not one participant — a participant may
hold a general-purpose and a primary-residence loan concurrently, and the two
amortise separately.

See [`docs/field-mapping.md`](docs/field-mapping.md) for the field-level
mapping and the layout tables, [`docs/design.md`](docs/design.md) for why it is
built this way, [`docs/runbook.md`](docs/runbook.md) for importing and
operating it, and
[`docs/deployment-checklist.md`](docs/deployment-checklist.md) for everything
that has to exist in HCM, OIC and at Principal first.

## Read this before using it

**No Principal file specification was supplied with this build.** The layout is
a complete, internally consistent fixed-width design following Principal's
published loan-remittance conventions — record type indicator, contract-keyed
header, one detail per loan, control-total trailer. It is fully tested against
itself. It has not been validated against a specification from Principal,
because none was provided.

Reconcile it before the first certification run. The work is bounded by design:
positions exist only in `map_canonical_to_principal.xsl`, mirrored in
`tools/generate_principal_file.py`, and the parity test fails if the two
drift. [`docs/field-mapping.md`](docs/field-mapping.md#adjusting-to-the-real-spec)
has the four-step procedure.

The same applies to the "Laborlytics" reference build the brief cited as the
gold-standard pattern: it was not attached and is not in this repository. The
conventions here are modelled on
[`core-hr-new-hire-load`](../core-hr-new-hire-load/), the only prior OIC build
present. Deviations from it are listed in
[`docs/design.md`](docs/design.md#deviations-from-the-reference-pattern).

## Four things worth knowing

**The trailer is checked against the file, not derived from it.** Step 140
parses the formatted 200-character records back, recounts them, and compares
against the trailer — whose figures came from the canonical batch, not from the
text. A formatting fault leaves the batch correct and the file corrupt, and
only an independent recount notices. A mismatch delivers nothing: Principal
posts what we send, and unwinding a wrong posting takes weeks.

**Delivery is idempotent, and that is not a nicety.** A rerun after a delivery
that succeeded but whose summary write failed would send the period twice, and
Principal posts both — every participant's loan repaid double. The file name
embeds the contract and the period end date; an existing file for that pair
means the period is already there, and the run reports `ALREADY_DELIVERED`
rather than paging anybody at 05:00.

**A terminated worker with a loan is the most important record in the file.**
The obvious extract filter — assignment status is `ACTIVE` — is wrong in the
direction that costs a participant money: Principal starts the cure period from
the termination date we send, and a worker who drops out of the file the week
they leave has their loan quietly default. `PFG_401K_LOAN_ELIGIBILITY.ff`
filters on the loan, not the employment.

**The mapping is implemented twice, and something checks that.** The XSLT runs
in OIC; `generate_principal_file.py` is the readable reference.
`tests/test_xslt_parity.py` runs both over the same inputs and asserts
identical bytes — awkward decimals, accented names, every reject reason, an
empty file. It registers OIC's `dvm:lookupValue` as a real XPath extension
backed by the packaged lookup XML, so a passing run also proves the maps and
the lookups in the archive agree.

## Try it without an instance

```bash
python3 tools/generate_principal_file.py \
    --extract samples/extract_output_sample.xml --out /tmp/pfg
```

Produces the file exactly as the integration would, prints the counts and the
rejects, and exits non-zero if the trailer and the details disagree.
[`samples/PFG_401K_LOAN_sample.txt`](samples/PFG_401K_LOAN_sample.txt) is that
output, committed, so a layout change shows up as a diff.

The sample extract carries a record for each case the file has to get right:
two concurrent loans, a payoff, a refinance, a mid-period termination, a
suspension, a reversed deduction, a rehire, a zero balance, an accented and
over-long name, and one of each reject reason.

## Before importing

The archive carries no credentials — OIC does not export secrets and the
import wizard prompts for them. Both the build and the validator refuse an
archive containing key material, a hard-coded password, or anything shaped like
a national identifier.

Three prerequisites cause almost every first-run failure:

1. **Import the four lookups before the integration.** `dvm:lookupValue`
   against a lookup that does not exist returns the default on every row rather
   than failing. A file of defaults imports, delivers and reconciles.
2. **The element entry DFF must be deployed and backfilled.** Without a loan
   number on `EEV_ATTRIBUTE1`, every loan rejects.
3. **The ITD balance dimension must be at element-entry level, not
   assignment.** An assignment-level dimension reports the sum of both loans
   against each of a participant's two loans, and looks correct until somebody
   has two.

Set `testProductionFlag=T` and `ssnPolicy=MASKED` in every environment except
production. Full sequence in [`docs/runbook.md`](docs/runbook.md).

## Scope

Loan repayments outbound, one Principal contract per run. Loan originations,
hardship withdrawals, deferral changes and the inbound direction — Principal's
loan setup advice coming back into HCM — are separate interfaces. Interest is
not modelled: Principal amortises from the origination terms they hold.
Limitations are listed in
[`docs/design.md`](docs/design.md#known-limitations).

## Verification status

Everything in this repository is tested and green: the layout, the mapping, the
parity between the two implementations, the status derivation, the
reconciliation, and the packaging. 132 tests.

Two things this repository cannot prove, both stated plainly:

**The `.iar` has not been round-tripped through an OIC instance** — none was
available. The packaging follows the layout corrected in
`core-hr-new-hire-load` (`ics.json`, `icspackage/appinstances/`,
`PROJECT-INF/project.xml`), and adds `icspackage/lookups/`. If it does not
import, do not guess at the layout — export any integration from the target
instance and diff:

```bash
python3 ../core-hr-new-hire-load/tools/compare_to_reference.py exported.iar
```

The maps and schemas under `src/.../maps/` and `src/.../schemas/` are
independent of the packaging and carry over unchanged either way. They also
import directly into the OIC designer if you build the flow there and export
the `.iar` from OIC, which is the route that always works.

**The layout has not been validated against Principal.** See above.

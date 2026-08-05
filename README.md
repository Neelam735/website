# Integrations

Oracle Integration Cloud integrations, built from source and packaged into
importable archives.

| Integration | Description |
|---|---|
| [`core-hr-new-hire-load`](integrations/core-hr-new-hire-load/) | Core HR new-hire load into Fusion HCM via HCM Data Loader |
| [`principal-401k-loans`](integrations/principal-401k-loans/) | 401(k) loan repayments out of Fusion HCM to Principal Financial Group |

## Build

```bash
make test       # run the test suite
make build      # package the .iar files into dist/
make validate   # structural checks on the built archives
make all        # all three
```

Every target also exists per integration — `make test-pfg401k`,
`make build-newhire` — for when you only care about one.

Requires Python 3.9+. `lxml` (`pip install lxml`) enables the XSLT tests; they
skip without it and the rest of the suite still runs.

## Conventions

**Archives are built, not committed.** `dist/` is ignored. Builds are
reproducible — same commit, same bytes, same `sha256` — so record the checksum
with the change ticket and you can prove later that what is deployed is what was
reviewed.

**No credentials in an archive.** OIC does not export secrets; the import
wizard prompts for them. Connection descriptors carry `${PLACEHOLDER}` values,
and both the build and the validator refuse to package key material or a
hard-coded password.

**Transformation logic gets tests.** XSLT is what OIC runs, but it is slow to
iterate on and awkward to assert against. Where a mapping is worth getting
right, it is implemented twice — once as XSLT, once as readable reference code
— with a parity test asserting the two produce identical output.

**Nothing environment-specific in an archive.** Endpoints, paths, recipients
and thresholds are integration properties; data mappings are lookups. If a
value has to differ between environments and is neither, that is a defect —
the archive should be byte-identical in every environment.

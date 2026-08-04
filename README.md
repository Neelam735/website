# Integrations

Oracle Integration Cloud integrations, built from source and packaged into
importable archives.

| Integration | Description |
|---|---|
| [`core-hr-new-hire-load`](integrations/core-hr-new-hire-load/) | Core HR new-hire load into Fusion HCM via HCM Data Loader |

## Build

```bash
make test       # run the test suite
make build      # package the .iar into dist/
make validate   # structural checks on the built archive
make all        # all three
```

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

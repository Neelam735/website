# Oracle integrations and applications

Oracle Integration Cloud integrations built from source and packaged into
importable archives, and Oracle APEX / ATP database components installed from
ordered SQL scripts.

| Integration | Description |
|---|---|
| [`core-hr-new-hire-load`](integrations/core-hr-new-hire-load/) | Core HR new-hire load into Fusion HCM via HCM Data Loader |

| APEX component | Description |
|---|---|
| [`approval-engine`](apex/approval-engine/) | Hierarchy-driven approval routing for APEX on ATP: rule matrix, chain resolver, PL/SQL engine, page build guide |

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

**Database code gets tests too, on both sides of the wire.** SQL and PL/SQL are
checked statically in `make test` — install order, DML against objects that
exist, the published error contract matching what is raised — and behaviourally
by a regression script that runs against the database and exits non-zero on a
failed assertion, so it can gate a deployment.

**Scripts are runnable in order against a fresh schema.** No script depends on
one that follows it, and each component has an `install.sql` that is the only
correct way to run its scripts as a set.

# Hierarchy-driven approval engine

A data-driven approval mechanism for Oracle APEX on Autonomous Transaction
Processing. The approval chain for a document is **resolved at submission time**
by walking the organisational hierarchy and applying an effective-dated rule
matrix. Changing an org chart or a spending threshold is a data change; no
application change, no deployment.

Built against Purchase Requisitions (`DOC_TYPE = 'PR'`), but the document type is
a row in `APPROVAL_DOC_TYPES` — adding Travel, Contracts or Capex is
configuration.

## What it does

- Walks `EMPLOYEES.MANAGER_ID` upward from the requester and stops on the first
  of: authority covers the amount, the rule's ceiling level is reached, or the
  chain-length cap is hit.
- Handles the cases that break naive implementations: inactive managers
  (skip-level), out-of-office delegation with amount caps, self-approval,
  duplicate approvers, management cycles, and requesters with no manager at all.
- Supports sequential steps and parallel groups, both *all-of* and *any-one-of*.
- Shows the requester the resolved chain **before** they submit.
- Tracks SLA per step, sends reminders, and escalates up the management line.
- Logs every action — including refused ones — to an append-only audit table.

## Layout

```
sql/
  install.sql                    driver; runs the numbered scripts in order
  00_drop_all.sql                teardown, for re-running the install
  01_types.sql                   object types behind the pipelined APIs
  02_tables.sql                  tables, constraints, indexes
  03_views.sql                   reporting and diagnostic views
  04_pkg_approval_guard.sql      the "am I inside the engine?" flag
  05_triggers.sql                tamper protection and configuration integrity
  06_pkg_approval_engine.pks     package specification
  07_pkg_approval_engine.pkb     package body
  08_vpd_optional.sql            optional row-level security (not installed by default)
  09_seed.sql                    reference data, 22-person org chart, rule matrix
  90_regression.sql              executable test plan; exits non-zero on failure
docs/
  01-er-model.md                 entities, state machines, how a rule is chosen
  02-apex-build.md               page-by-page build, automations, native-vs-custom
  03-atp-notes.md                what ATP changes, and what to avoid on it
  04-security.md                 authorisation, tamper protection, VPD
  05-test-plan.md                cases, and what is deliberately not covered
  06-design-notes.md             the decisions that could have gone the other way
tests/
  test_sql_structure.py          static checks over the scripts (runs in `make test`)
```

## Install

```bash
export TNS_ADMIN=/path/to/wallet
sqlcl -cloudconfig /path/to/wallet.zip <APP_SCHEMA>/<password>@<db>_tp
SQL> @sql/install.sql
SQL> @sql/90_regression.sql
```

`install.sql` prints a verification block at the end: any `INVALID` object, any
`AMBIGUOUS` rule overlap, or a hierarchy finding you did not expect means stop.

Then follow `docs/02-apex-build.md` to build the pages.

## Reading order

Start with `docs/01-er-model.md` for the shape, then
`sql/06_pkg_approval_engine.pks` for the API surface — the spec carries the
transaction policy and the full error contract. `docs/06-design-notes.md`
explains why the debatable decisions went the way they did.

## Conventions

**Scripts are runnable in order against a fresh schema.** No script depends on
one that follows it, and `install.sql` is the only correct way to run them as a
set. 19c-compatible DDL throughout, so the same files install on ATP 19c and
23ai; `docs/03-atp-notes.md` lists what 23ai would let you simplify.

**Nothing writes approval state except the package.** Not the APEX pages, not a
maintenance script. `05_triggers.sql` enforces it rather than trusting it, and
`90_regression.sql` asserts that the enforcement works.

**Errors are written to be read by the person who hit them.** `ORA-20010` names
the document type, amount, department and date that failed to match a rule, and
says which table to fix. Messages are part of the interface.

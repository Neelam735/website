# Test plan

Every case below is implemented in `sql/90_regression.sql` and runs against the
seeded schema in one transaction, rolled back at the end. The script exits
non-zero if any assertion fails, so it can gate a deployment:

```bash
sqlcl -S <APP_SCHEMA>/<pw>@<db>_tp @sql/90_regression.sql
```

The seed data was designed backwards from this list — `CHEN WEI` is inactive,
`NINA PETROVA` has a zero limit and `INGRID HALVORSEN` has no manager because
those are the cases that break routing engines.

## Chain resolution

| # | Case | Setup | Expected |
|---|---|---|---|
| T1 | **Five-level chain** | Maya (L3) requests 310,000 under `PR-TIER-4` | 6 steps: Aisha → Daniel → Yuki → Tomas → Ada (COO, limit covers) → CFO from the rule. Each its own group |
| T2 | **Skip-level over an inactive manager** | Jonas (L2, Ops) requests 145,000; Chen Wei is inactive | Chen absent from the chain; the walk continues to Sofia rather than stopping |
| T2 | **Delegated approver** | Grace (Controller) has delegated to Elena | Step 4 keeps `ORIGINAL_APPROVER_ID = Grace` and sets `ACTING_APPROVER_ID = Elena`, with `DELEGATION_ID` populated |
| T3 | **Amount above the CEO's limit** | 20,000,000 under `PR-TIER-4` (`REQUIRE_COVERAGE = 'Y'`) | `ORA-20014`, message names the shortfall. Nothing is materialised |
| T4 | **Orphaned requester** | Ingrid has no manager | Rule's `FALLBACK_ROLE_CODE` resolves to the CEO; step is marked `FALLBACK` |
| T5 | **Self-approval prevention** | Grace *is* the Financial Controller and raises her own requisition | The rule step naming her disappears; the chain is still valid and never contains the requester |
| T6 | **Duplicate collapsing** | Yuki has delegated to Daniel, who is already on the chain | Daniel appears exactly once; the collapsed rule step is dropped, not duplicated |
| T18 | **Cumulative authority mode** | Travel request 28,000 under `TRAVEL-STD` (`LIMIT_MODE = 'CUMULATIVE'`, `START_AT_LEVEL = 1`) | Zero-limit managers are included and the summed limits cover the amount |
| T19 | **Preview equals reality** | Preview a draft, then submit it | Same number of steps, same order |

### Not reachable, and that is the point

`ORA-20012` (cycle) cannot be provoked through the API because
`TRG_EMPLOYEES_AIU` refuses to create a cycle and a `CHECK` constraint refuses
self-management — see T15. The resolver still handles it (`CONNECT BY NOCYCLE`
plus `CONNECT_BY_ISCYCLE`) because data can arrive by other routes: a direct
load, a restore, a disabled trigger.

## Execution

| # | Case | Expected |
|---|---|---|
| T7 | **Parallel any-one-of** | With the collapsing delegation disabled, both candidates activate; the first approval sets the other to `SKIPPED` and completes the request |
| T8 | **Parallel all-of** | Both tail approvers activate; one approval leaves the request `PENDING`; the second completes it |
| T12 | **Request info / resume** | Step and request move to `INFO_REQUESTED`, `SLA_DUE_ON` is cleared while the ball is with the requester, and both resume with a fresh SLA |
| T13 | **Reject is terminal** | Rejection without a comment raises `ORA-20004`; with one, the request is `REJECTED` and every open step is `CANCELLED` |
| T21 | **Withdraw is terminal** | Status `WITHDRAWN`; resubmitting raises `ORA-20002` |
| T14 | **Recall and rebuild** | Recall cancels open steps and parks the request; resubmission re-resolves against the current org chart |

## Authorisation and tampering

| # | Case | Expected |
|---|---|---|
| T9 | Assigned approver | `CAN_ACT = 'Y'` |
| T9 | Bystander | `CAN_ACT = 'N'`; calling `APPROVE` raises `ORA-20003` |
| T9 | Administrator | `CAN_ACT = 'N'` — admins reassign, they do not approve |
| T10 | Direct `UPDATE` on `APPROVAL_STEPS` | `ORA-20099` |
| T10 | Direct status change on `APPROVAL_REQUESTS` | `ORA-20099` |
| T10 | `DELETE` from `APPROVAL_AUDIT` | `ORA-20099` |

## Configuration integrity

| # | Case | Expected |
|---|---|---|
| T15 | Introduce a management cycle | `ORA-20031` from `TRG_EMPLOYEES_AIU` |
| T15 | Make someone their own manager | `ORA-02290`, check constraint |
| T16 | Two active rules, same scope and band, same priority | `ORA-20030`; `V_APPROVAL_RULE_OVERLAPS` shows the pair |
| T17 | No rule matches | `ORA-20010` naming the document type, amount, department and date |
| T23 | Delegate an approval to an inactive employee | `ORA-20015`. This one is worth stating: it does not stall a chain, it silently removes an approver from it, because `RESOLVE_DELEGATE` skips inactive delegates and the delegator keeps the step while both parties believe cover is in place |
| T23 | Delegation loop (A covers B while B covers A) | `ORA-20015` |

## SLA

| # | Case | Expected |
|---|---|---|
| T11 | **SLA breach** | Backdate a due date, run `ESCALATE_OVERDUE`; the step moves to the approver's manager, `ESCALATION_COUNT` increments, `ORIGINAL_APPROVER_ID` is preserved |
| T20 | Due date lands on a weekend | Pushed to the next working day |
| T20 | Due date lands on a configured holiday | Pushed past it |
| — | Escalation ceiling reached | `ESCALATE` logs a `WARN` audit row and leaves the step in place — it does not raise, so the sweep continues |
| — | Step actioned between the sweep and `ESCALATE` | Logged as `WARN`, skipped. This race is normal and must not error |

## Audit

| # | Case | Expected |
|---|---|---|
| T22 | Submission, approvals | Present in `APPROVAL_AUDIT` |
| T22 | Refused attempts | Present with `OUTCOME = 'ERROR'` and the Oracle error text |
| T22 | Guard depth | `PKG_APPROVAL_GUARD.ENGINE_DEPTH = 0` after the run — proves no entry point leaked its guard |

## Cases the script does not cover

Stated rather than quietly omitted:

- **Concurrency.** Two approvers acting on the same any-one-of group in the same
  millisecond. The code takes `SELECT ... FOR UPDATE WAIT 5` on the step and the
  request, and maps `ORA-00054` to `ORA-20020` with a retry message, but proving
  it needs two sessions and this pack is single-session. Test it manually with
  two SQLcl sessions before go-live.
- **Volume.** Chain resolution is one hierarchy walk per submission and is
  indexed for it, but nothing here proves behaviour at 10,000 requests/day. Load
  test the inbox view (`V_MY_PENDING_APPROVALS`) specifically — it is the query
  every approver runs on every page view.
- **`APEX_MAIL` delivery.** The outbox is asserted; actual delivery depends on
  OCI Email Delivery configuration and cannot be tested from SQL.
- **Page-level authorisation.** The package functions behind the APEX schemes are
  tested; that the schemes are actually attached to the right pages is a build
  step, and the checklist in `docs/04-security.md` is how you verify it.

## Manual pre-go-live checks

1. Two sessions, same any-one-of group, approve simultaneously → one wins, the
   other gets `ORA-20005` with a readable message, no orphaned `ACTIVE` step.
2. Approve from a phone with the delegation active → the "On behalf of" column
   explains why the item is in the inbox.
3. Stop the ATP instance for a day (or backdate a batch of SLAs), restart, and
   run the escalation sweep repeatedly until it reports zero. Confirm the
   `P_MAX_ROWS` cap keeps each run short.
4. Change a manager in the middle of a live request, then recall and resubmit.
   Confirm the requester is told the chain changed.

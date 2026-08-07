# Security model

Three questions, answered in three different places:

| Question | Enforced by | Where |
|---|---|---|
| Can this user *change* approval state? | database triggers | `05_triggers.sql` |
| Can this user *act on this step*? | `PKG_APPROVAL_ENGINE.CAN_ACT` | package + APEX authorization scheme |
| Can this user *see this request*? | `CAN_VIEW`, optionally VPD | package + `08_vpd_optional.sql` |

The first is not negotiable and does not depend on the UI. The second and third
are enforced in the package and *surfaced* through APEX.

## 1. No state change outside the package

In APEX the parsing schema owns these tables, so it has implicit full DML on
them and there is no grant to revoke. Privileges cannot express "only this
package may write here". Triggers can.

`PKG_APPROVAL_GUARD` holds one session-scoped counter. Every engine entry point
increments it on the way in and decrements it on the way out, including in its
exception handler. The triggers refuse DML when the counter is zero:

```sql
if not pkg_approval_guard.in_engine then
  raise_application_error(-20099, '... only permitted through PKG_APPROVAL_ENGINE');
end if;
```

What each table allows without the engine:

- **`APPROVAL_STEPS`** — nothing. No insert, update or delete, ever.
- **`APPROVAL_REQUESTS`** — insert of a `DRAFT` row and edits while `DRAFT` or
  `RECALLED`, so an ordinary APEX form can create and edit drafts. `STATUS`,
  `CURRENT_GROUP`, `RULE_ID`, `SUBMITTED_ON`, `COMPLETED_ON`, `RECALL_COUNT` and
  `ROW_VERSION` are engine-only in every state.
- **`APPROVAL_AUDIT`** — insert by anyone, update and delete by nobody, including
  the engine. Evidence you can edit is not evidence.

### The honest limitation

Anyone who can execute PL/SQL as the parsing schema can call
`pkg_approval_guard.enter_engine` and then write what they like. This is a
guardrail against application bugs and casual tampering, not against a hostile
DBA. The controls that address that threat are elsewhere: audit rows are written
autonomously (so they survive the rollback of whatever produced them), the audit
table cannot be updated, and on 19.10+/23ai you can promote it to a blockchain
table — see `docs/03-atp-notes.md`. `PKG_APPROVAL_GUARD.ENGINE_DEPTH` is exposed
so a leaked `ENTER_ENGINE` is diagnosable rather than mysterious.

Grant `EXECUTE` on `PKG_APPROVAL_ENGINE` to any schema that needs to submit or
approve, and grant nothing else. Those callers then physically cannot bypass it.

## 2. Who may act

`CAN_ACT(p_step_id, p_username)` returns `'Y'` only when:

1. the step is `ACTIVE` — not pending, not already actioned, not skipped by an
   any-one-of sibling, and
2. the user is the step's `ACTING_APPROVER_ID`, **or** holds a currently valid
   delegation from that approver for this document type, within its amount cap.

Point 2's second clause matters: activation re-resolves delegation, but an
approver who goes out of office *after* their step activated would otherwise
strand the document until the next escalation.

**Administrators deliberately cannot approve.** `IS_ADMIN` grants access to rule
and delegation maintenance and lets someone `REASSIGN` a stuck step — which puts
their name in the audit trail against a visible act — but `CAN_ACT` never returns
`'Y'` for an admin who is not the assigned approver. Separation of duty is the
point of the whole system; an admin bypass would defeat it.

**Requesters cannot approve their own document.** The resolver drops the
requester from the chain (`ALLOW_SELF_APPROVAL = 'N'`, the default), including
when a delegation would hand the document back to them. `REASSIGN` refuses the
requester as a target. `SUBMIT` refuses anyone but the requester, admins
included: submitting on someone's behalf would make the audit trail lie about who
asked.

In APEX, wire this to page 31's page-level authorization scheme
(`CAN_ACT_ON_STEP`). The inline buttons on page 30 are a convenience; the page
that performs the action is the gate. Evaluate the scheme *Once Per Page View*,
never per session — it depends on a page item.

## 3. Who may see

Two levels, and you should pick one deliberately.

### APEX-level (default)

`CAN_VIEW(p_request_id, p_username)` returns `'Y'` for the requester, anyone who
is or was on the chain, and administrators. Use it as page 20's authorization
scheme. Reports use `V_MY_PENDING_APPROVALS`, which filters itself on
`APP_USER` — there is no bind variable to tamper with and no way to widen it from
a URL.

This is sufficient when every path into the data is an APEX page.

### Database-level (VPD, optional)

Install `08_vpd_optional.sql` when the schema is also reachable through ORDS REST
endpoints, a BI tool, or another schema. It adds a `CONTEXT_SENSITIVE` policy on
`APPROVAL_REQUESTS` restricting `SELECT` to requester / chain member / admin.

Three things to know before you switch it on:

1. **The table owner is subject to the policy.** In APEX that owner is the
   parsing schema, so every page is filtered the moment you add it. That is the
   intent, but it will change results you thought were stable.
2. **The engine must not be filtered.** `BUILD_CHAIN` and `ADVANCE` operate on
   the request they were given; a filtered view of it would corrupt the chain.
   The predicate function returns `NULL` (no filter) while
   `PKG_APPROVAL_GUARD.IN_ENGINE` is true.
3. **The predicate reads a context, not a function, per row.** `APEX$APPROVAL` is
   writable only by `APPROVAL_CTX_PKG`, so a user cannot set it to someone else's
   name. Call `approval_ctx_pkg.set_context` from the application's Initialization
   PL/SQL Code.

`ADMIN` on ATP holds `EXEMPT ACCESS POLICY` and sees everything regardless. That
is expected; VPD is not a control against the instance administrator.

## 4. Injection and binding

Everything in the package is static SQL with bind variables. There is no dynamic
SQL anywhere in `PKG_APPROVAL_ENGINE`, so there is nothing to inject into. The
VPD predicate is a fixed string with no concatenated user input — the user name
enters through `SYS_CONTEXT`, not through string building.

In APEX, keep report sources as static SQL with bind variables. If you add a
filter that concatenates a page item into a `WHERE` clause, you have created the
one injection point this design does not have.

## 5. What the audit trail guarantees

Every call to an engine entry point writes an `APPROVAL_AUDIT` row, on success
and on failure, with the actor, the step, the status transition, the client IP
and the APEX session ID. Refused attempts are recorded with `OUTCOME = 'ERROR'`
and the Oracle error — a rejected approval attempt is exactly the row a security
review wants, and it is the row an inline logger would have rolled back.

The autonomous logger has one consequence worth stating plainly: a `SUCCESS` row
records what the engine *did*, and the caller may still roll back the surrounding
transaction. `TO_STATUS` therefore records intent. If you need the log to record
only committed outcomes, log inline instead and accept losing the failure rows —
that trade-off is discussed in `docs/06-design-notes.md`.

## 6. Operational checklist

- [ ] `EXECUTE` on `PKG_APPROVAL_ENGINE` granted only to schemas that need it
- [ ] No `INSERT`/`UPDATE`/`DELETE` grants on `APPROVAL_STEPS` or `APPROVAL_AUDIT`
      to anyone
- [ ] `CAN_ACT_ON_STEP` evaluated *Once Per Page View* on page 31
- [ ] Page 40/50/60 carry the `APPROVAL_ADMIN` scheme at *page* level, not just
      on a button
- [ ] Page 50's `DELEGATOR_ID` column hidden and defaulted, not user-editable
- [ ] `V_APPROVAL_RULE_OVERLAPS` empty of `AMBIGUOUS` rows in production
- [ ] `V_HIERARCHY_HEALTH` checked after every HR feed
- [ ] `APPROVAL_NOTIFICATIONS` monitored for `FAILED`
- [ ] `PKG_APPROVAL_GUARD.ENGINE_DEPTH` returns 0 at the end of the regression run

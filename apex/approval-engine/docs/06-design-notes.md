# Design notes and trade-offs

The decisions in this build that could reasonably have gone the other way.

## 1. The chain is materialised, not computed on demand

`APPROVAL_STEPS` stores the resolved chain as rows. The alternative — resolve the
chain live every time anyone asks "who is next?" — is tempting because it can
never go stale.

Materialising wins for three reasons. An approval is a promise about *who was
asked*, and recomputing it means a mid-flight org change silently rewrites
history. Comments, action timestamps and SLA clocks need somewhere to live, and
they belong on the step. And "everything waiting on the CFO, by cost centre,
ageing" has to be a query against indexed rows, not a function call per document.

The cost is that a chain built on Monday reflects Monday's org chart. That is
handled explicitly rather than pretended away: recall + resubmit re-resolves, and
`BUILD_CHAIN` is public so an administrator can rebuild a stuck request. T14 in
the regression pack asserts both halves of this.

## 2. `INDIVIDUAL` is the default coverage mode, `CUMULATIVE` is available

The requirement says "stop climbing when cumulative `APPROVAL_LIMIT` covers the
document amount". Delegation-of-authority policies in practice almost always mean
*individual* authority: you climb until you reach someone who can personally
authorise the amount. Summing limits implies that three people who can each
approve 10,000 can jointly approve 30,000, which is not how spending authority
usually works — and it produces longer chains for larger amounts, which is
backwards from most policies.

Both are implemented, as `APPROVAL_RULES.LIMIT_MODE`, defaulting to `INDIVIDUAL`.
The seeded requisition rules use `INDIVIDUAL`; the travel rule uses `CUMULATIVE`
so both paths stay exercised by the regression pack. If your policy really is
cumulative, it is one column value, not a code change.

## 3. Autonomous audit logging, and what it costs

Logging is autonomous so that a *refused* action is still recorded. If logging
were inline, every `ORA-20003` would roll back its own evidence, and the security
question this table exists to answer — "who tried?" — would be unanswerable.

The cost is real: a `SUCCESS` audit row can outlive a business transaction the
caller later rolls back. The log records intent, not commitment. Two mitigations
are in the design: `TO_STATUS` names the intended state rather than asserting the
final one, and `OUTCOME` distinguishes success from warnings and errors. If you
need commit-accurate logging, make `LOG_ACTION` non-autonomous and accept losing
the failure rows — but be sure that is the trade you want.

## 4. Triggers for tamper protection, not grants

In APEX the parsing schema owns the tables, so it has implicit DML on them and
there is nothing to revoke. Privileges cannot express "only this package writes
here"; a trigger asking a session-scoped guard flag can.

This is a guardrail against application bugs and casual tampering, not against a
hostile DBA — anyone who can run PL/SQL as the owner can call `ENTER_ENGINE`
first. It is stated plainly in `docs/04-security.md` rather than oversold. The
controls that do address a privileged attacker are the append-only audit table
and, if your auditors need it, promoting it to a blockchain table.

The alternative — putting the runtime tables in a second schema and granting only
`EXECUTE` on the package — is genuinely stronger and is the right answer for a
regulated deployment. It costs you a second schema to manage on ATP and makes
every APEX report go through a view or a synonym. For most builds the triggers
are the better ratio; for a build where an auditor is asking, take the second
schema.

## 5. A notification outbox instead of inline `APEX_MAIL`

Calling `APEX_MAIL.SEND` inside `APPROVE` would mean a mail failure rolls back an
approval, and it would make the package unusable outside an APEX session — from
SQLcl, a REST handler, a scheduler job, the regression pack.

The engine writes to `APPROVAL_NOTIFICATIONS` and an APEX Automation drains it.
Delivery becomes retryable, testable and observable, at the cost of one extra
table and up to five minutes of latency. Approvals are not a five-minute-latency
problem.

## 6. Escalation replaces the approver rather than adding a step

When an SLA breaches, `ESCALATE` re-points the step at the current holder's
manager and increments `ESCALATION_COUNT`. It does not insert a new step.

Replacing keeps the chain the shape the rule described — an escalation is not an
extra approval, it is the same approval performed by someone more senior — and it
keeps `MAX_LEVELS` meaningful. `ORIGINAL_APPROVER_ID` is untouched, so the audit
trail still shows whose authority the step represents, and the comment on the
step records that it was escalated.

The alternative (append a step for the escalation target) gives you a fuller
picture of who was asked and when, at the cost of chains that grow unboundedly
under a slow approver. The audit log already contains that history, so the growth
is not worth it.

## 7. `START_AT_LEVEL` as a separate knob from `MIN_APPROVER_LEVEL`

They look redundant and are not. `MIN_APPROVER_LEVEL` is a floor on where the
chain may *stop*; `START_AT_LEVEL` is a floor on who is *included at all*. A
250,000 requisition should be seen by every manager in the line **and** must
reach a Director — that is `START_AT_LEVEL = 3, MIN_APPROVER_LEVEL = 6`. Folding
them into one column forces you to choose between rubber-stamp steps and losing
the line-management record.

## 8. Only the climb counts towards coverage

`RESOLVE_CHAIN` accumulates authority and evaluates the coverage test for
hierarchy and fallback steps only. Rule steps — the Financial Controller, the CFO
— are additional mandatory approvers bolted onto the chain, not rungs on the
ladder.

The distinction is not cosmetic. A `BEFORE` rule step naming someone who happens
to sit at the rule's `MIN_APPROVER_LEVEL` would otherwise satisfy the coverage
test before the walk started, and the chain would truncate to the requester's
immediate manager. Rule steps still appear in `CUMULATIVE_LIMIT` on the preview
so the requester sees the whole picture; they just do not vote on when to stop
climbing.

## 9. Duplicate collapsing can silently drop a mandatory rule step

If a rule requires the Financial Controller and the Controller is already on the
hierarchy chain, they sign once. Likewise if a delegation resolves a rule step
onto someone already present (regression T6). The step disappears rather than
appearing twice.

This is correct — a second signature from the same person adds nothing — but it
is an interaction between two switches, and it means "mandatory" means *the
authority must be represented*, not *a row must exist*. It is called out here
because it is the behaviour most likely to be reported as a bug.

Turn it off per rule with `COLLAPSE_DUPLICATES = 'N'` if your policy genuinely
requires the same person to sign in two capacities.

## 10. Recall and withdraw are different verbs

Most systems have one "cancel". Splitting them means the state machine can say
what actually happened: `RECALLED` is on the requester's desk and resubmittable,
`WITHDRAWN` is over. The cost is one more status and one more button; the benefit
is that "how many requisitions were abandoned last quarter" is answerable.

## 11. Administrators cannot approve

`CAN_ACT` never returns `'Y'` for an administrator who is not the assigned
approver, and `SUBMIT` refuses anyone but the requester. Admins can maintain
rules and delegations, and can `REASSIGN` a stuck step — an action that puts
their name in the audit trail.

This will generate a support request within a month of go-live ("just approve it
for me"). The answer is `REASSIGN`, and the reason the answer is not "make me an
admin approver" is that separation of duty is the entire point of the system.

## 12. What is deliberately not here

- **Attachments.** Referenced in `docs/03-atp-notes.md` via `DBMS_CLOUD`/Object
  Storage, not implemented — it is orthogonal to routing and depends on your
  bucket layout.
- **A business-object table.** `APPROVAL_REQUESTS.DOC_ID`/`DOC_REF` point at your
  requisition table; the engine deliberately does not own it. `APPROVAL_DOC_TYPES`
  carries the drill-down URL so the detail page can link back.
- **Multi-currency conversion.** `CURRENCY_CODE` is stored and compared, not
  converted. Rules are matched on amount in the request's currency, so a rule
  matrix in mixed currencies needs either one rule set per currency or a
  conversion step before submission. Adding an FX table would be a real feature,
  not a tweak.
- **A REST API.** `GET_PENDING_CURSOR` returns a ref cursor precisely so an ORDS
  handler is a five-line module, but no ORDS definitions are included.

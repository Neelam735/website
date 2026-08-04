# APEX build instructions

Target: APEX 23.2+, Universal Theme (42), parsing schema `<APP_SCHEMA>`, any
authentication scheme. Nothing below depends on how users log in — every check
keys off `APP_USER`, which `EMPLOYEES.APEX_USERNAME` mirrors. If you are on OCI
IAM or SAML SSO, load `APEX_USERNAME` with whatever the IdP puts in `APP_USER`
(usually the email address); the seed data uses short names purely for legibility.

Run `sql/install.sql` first. The pages below assume the views and package exist.

---

## 0. Application-level setup

**Create the application**

- Name: `Requisition Approvals`, Application ID `500`
- Theme: Universal Theme 42, navigation: side menu

**Shared Components → Application Items**

| Name | Scope | Purpose |
|---|---|---|
| `AI_EMPLOYEE_ID` | Application | the logged-in user's `EMPLOYEE_ID`, resolved once |
| `AI_IS_ADMIN` | Application | `Y`/`N`, cached for the session |

**Shared Components → Application Processes**

`SET_USER_CONTEXT`, point *On New Instance (New Session)*:

```sql
begin
  :AI_EMPLOYEE_ID := pkg_approval_engine.employee_id_for(:APP_USER);
  :AI_IS_ADMIN    := pkg_approval_engine.is_admin(:APP_USER);
exception
  when others then
    -- Someone authenticated who is not in the org chart. Let them in far enough
    -- to see a useful message rather than an ORA- error on every page.
    :AI_EMPLOYEE_ID := null;
    :AI_IS_ADMIN    := 'N';
end;
```

> If you install the optional VPD from `sql/08_vpd_optional.sql`, also set
> **Security Attributes → Database Session → Initialization PL/SQL Code** to
> `approval_ctx_pkg.set_context;` and **Cleanup** to `approval_ctx_pkg.clear_context;`.

**Shared Components → Authorization Schemes**

| Name | Type | Definition | Used for |
|---|---|---|---|
| `APPROVAL_ADMIN` | PL/SQL Function Body Returning Boolean | `return nvl(:AI_IS_ADMIN,'N') = 'Y';` | admin pages |
| `IS_REGISTERED_EMPLOYEE` | PL/SQL Expression | `:AI_EMPLOYEE_ID is not null` | everything else |
| `CAN_VIEW_REQUEST` | PL/SQL Expression | `pkg_approval_engine.can_view(:P20_REQUEST_ID, :APP_USER) = 'Y'` | page 20 |
| `CAN_ACT_ON_STEP` | PL/SQL Expression | `pkg_approval_engine.can_act(:P31_STEP_ID, :APP_USER) = 'Y'` | page 31 buttons |
| `IS_REQUEST_OWNER` | PL/SQL Expression | `:AI_EMPLOYEE_ID = :P11_REQUESTER_ID` | page 11 edit/submit |

Set **Evaluation Point** to *Once Per Page View* for `CAN_VIEW_REQUEST` and
`CAN_ACT_ON_STEP` — they take a page item and must not be cached per session.

**Shared Components → Email Templates** (Static IDs matter — the outbox stores
them):

| Static ID | When |
|---|---|
| `APPROVAL_ASSIGNED` | a step became yours |
| `APPROVAL_REMINDER` | SLA approaching |
| `APPROVAL_ESCALATED` | SLA breached, now yours |
| `APPROVAL_APPROVED` | request fully approved |
| `APPROVAL_REJECTED` | request rejected |
| `APPROVAL_INFO_REQUESTED` | approver asked the requester a question |
| `APPROVAL_INFO_PROVIDED` | requester answered |
| `APPROVAL_RECALLED` / `APPROVAL_WITHDRAWN` / `APPROVAL_REASSIGNED` | as named |

Each template's substitution strings must match the JSON keys the engine
queues: `REQUESTREF`, `TITLE`, `AMOUNT`, `CURRENCY`, `REQUESTER`, `PRIORITY`,
`SLADUE`, `MESSAGE`, `REQUESTID`, `STEPID`, `DOCTYPE`, `DOCREF`, `NOTIFYTYPE`.

---

## Page 1 — Home

**Region: "Your approvals" (Cards, or Region Display Selector with two cards)**

Source — badge counts, one query:

```sql
select pkg_approval_engine.pending_count(:APP_USER)                          as pending_count
     , (select count(*) from v_my_pending_approvals where sla_state = 'OVERDUE')  as overdue_count
     , (select count(*) from v_my_pending_approvals where sla_state = 'DUE_SOON') as due_soon_count
     , (select count(*) from approval_requests
         where requester_id = :AI_EMPLOYEE_ID and status in ('DRAFT','RECALLED')) as draft_count
     , (select count(*) from approval_requests
         where requester_id = :AI_EMPLOYEE_ID
           and status in ('PENDING','INFO_REQUESTED'))                       as in_flight_count
  from dual
```

Link each card to page 30 or 10 with the matching filter, e.g.
`f?p=&APP_ID.:30:&SESSION.::NO:RIR:IR_SLA_STATE:OVERDUE`.

**Navigation menu badges** — on the "My Approvals" list entry, set *Badge Value*
to `&PENDING_BADGE.` and populate it from a Before Header page-0 process, or
simply set the List Entry's badge SQL to
`select pkg_approval_engine.pending_count(:APP_USER) from dual`.

---

## Page 10 — My Requests (Interactive Report)

Authorization: `IS_REGISTERED_EMPLOYEE`.

```sql
select request_id, request_ref, doc_type_name, title, amount, currency_code
     , status, priority_code, submitted_on, waiting_on, next_sla_due_on
     , approved_steps || ' / ' || total_steps as progress
     , apex_page.get_url(p_page => 20, p_items => 'P20_REQUEST_ID', p_values => request_id) as detail_url
  from v_approval_requests
 where requester_id = :AI_EMPLOYEE_ID
```

- Column `STATUS`: HTML Expression with a Universal Theme badge —
  `<span class="t-Badge t-Badge--#STATUS_CLASS#">#STATUS#</span>`; add
  `STATUS_CLASS` to the query with a `CASE` (`APPROVED`→`success`,
  `REJECTED`→`danger`, `PENDING`→`warning`, else `default`).
- Button `CREATE` → page 11 in a modal dialog, clearing cache.

---

## Page 11 — Submit a request, with live chain preview

Page mode: **Modal Dialog**. This is the page the requirement's "preview before
submission" lives on.

**Items**

| Item | Type | Notes |
|---|---|---|
| `P11_REQUEST_ID` | Hidden | primary key |
| `P11_REQUESTER_ID` | Hidden | default `&AI_EMPLOYEE_ID.` |
| `P11_DOC_TYPE` | Select List | LOV: `select doc_type_name d, doc_type r from approval_doc_types where active_flag='Y'` |
| `P11_TITLE` | Text Field | required |
| `P11_AMOUNT` | Number Field | required, min 0 |
| `P11_CURRENCY_CODE` | Select List | default `USD` |
| `P11_DEPT_ID` | Select List | defaults from the requester |
| `P11_COST_CENTER` | Select List | cascading on `P11_DEPT_ID` |
| `P11_PRIORITY_CODE` | Radio Group | `LOW/NORMAL/HIGH/URGENT` |
| `P11_DESCRIPTION` | Textarea | |
| `P11_STATUS` | Display Only | |

**Region 1 — "Request" (Form)**

Do **not** use *Form — Automatic Row Processing (DML)* for anything but the
draft. The guard trigger permits a `DRAFT` insert and edits while `DRAFT` or
`RECALLED`, and blocks everything else, so automatic DML will fail loudly the
moment a user edits an in-flight request. Prefer explicit processes:

*Process `SAVE_DRAFT`* (Server-side condition: request is `SAVE` or `SUBMIT`):

```sql
begin
  if :P11_REQUEST_ID is null then
    :P11_REQUEST_ID := pkg_approval_engine.create_request(
        p_doc_type      => :P11_DOC_TYPE
      , p_title         => :P11_TITLE
      , p_amount        => :P11_AMOUNT
      , p_description   => :P11_DESCRIPTION
      , p_currency_code => :P11_CURRENCY_CODE
      , p_dept_id       => :P11_DEPT_ID
      , p_cost_center   => :P11_COST_CENTER
      , p_priority_code => :P11_PRIORITY_CODE
      , p_actor         => :APP_USER);
  else
    update approval_requests
       set title = :P11_TITLE, amount = :P11_AMOUNT, description = :P11_DESCRIPTION
         , currency_code = :P11_CURRENCY_CODE, dept_id = :P11_DEPT_ID
         , cost_center = :P11_COST_CENTER, priority_code = :P11_PRIORITY_CODE
     where request_id = :P11_REQUEST_ID;
  end if;
end;
```

*Process `SUBMIT_REQUEST`* (After `SAVE_DRAFT`; condition: request is `SUBMIT`):

```sql
begin
  pkg_approval_engine.submit(:P11_REQUEST_ID, p_actor => :APP_USER);
end;
```

Success message: `Submitted for approval.` Error handling: leave the default —
the engine's `-20xxx` messages are written to be shown to a user verbatim. Add a
Shared Components → **Error Handling Function** if you want to strip the
`ORA-20014:` prefix; there is a standard one in the APEX docs.

**Region 2 — "Approval chain preview" (Classic Report, template *Value Attribute
Pairs* or *Cards*)**

Source type **SQL Query**, and mark the region **Server-side condition:
`P11_AMOUNT is not null`**:

```sql
select c.step_seq
     , c.group_no
     , c.step_mode
     , c.approver_name
     , c.approver_username
     , e.job_title
     , c.job_level
     , c.approval_limit
     , c.cumulative_limit
     , c.source_code
     , c.note
     , case when c.delegation_id is not null then 'Y' else 'N' end as is_delegated
     , c.covers_amount_yn
  from table(pkg_approval_engine.preview_chain(
               p_doc_type     => :P11_DOC_TYPE
             , p_amount       => to_number(:P11_AMOUNT)
             , p_requester_id => :AI_EMPLOYEE_ID
             , p_dept_id      => to_number(:P11_DEPT_ID)
             , p_cost_center  => :P11_COST_CENTER)) c
  join employees e on e.employee_id = c.approver_id
 order by c.step_seq
```

Region attributes:

- **Page Items to Submit**: `P11_DOC_TYPE, P11_AMOUNT, P11_DEPT_ID, P11_COST_CENTER`
- **Static ID**: `chain_preview` (the Dynamic Action refreshes it by static ID)
- **No Data Found**: *"No approval chain could be resolved. Check the amount and
  cost centre, or contact an approval administrator."*

**Dynamic Action `Refresh preview`**

- Event: **Change**, Selection: *Item(s)* → `P11_DOC_TYPE, P11_AMOUNT, P11_DEPT_ID, P11_COST_CENTER`
- Client-side condition: `P11_AMOUNT` *is not null*
- True action 1: **Refresh** → Region `chain_preview`
- Set the amount item's **Value Change Delay** or add a debounce; without it the
  preview re-resolves on every keystroke, and each refresh is a hierarchy walk.

The preview calls the same `RESOLVE_CHAIN` that submission calls, so what the
requester sees is what they get — unless the org chart changes in between, which
is exactly what the `covers_amount_yn` and `note` columns are there to explain.

**Buttons**: `SAVE` (Request `SAVE`), `SUBMIT` (Request `SUBMIT`, hot), `CANCEL`.
On `SUBMIT` add a **Confirm** dialog: *"Submit for approval? The chain shown will
be created."*

---

## Page 30 — My Pending Approvals (Interactive Report)

Authorization: `IS_REGISTERED_EMPLOYEE`.

Source — the view is self-filtering on `APP_USER`, so no bind is needed and no
one can widen it by tampering with a URL:

```sql
select step_id
     , request_id
     , request_ref
     , doc_type_name
     , title
     , amount
     , currency_code
     , priority_code
     , requester_name
     , dept_name
     , cost_center
     , submitted_on
     , step_seq
     , step_mode
     , sla_due_on
     , hours_remaining
     , sla_state
     , escalation_count
     , acting_for_name
  from v_my_pending_approvals
 order by case sla_state when 'OVERDUE' then 0 when 'DUE_SOON' then 1 else 2 end
        , sla_due_on
```

**Report configuration**

- **Highlight** (saved as a default report): `SLA_STATE = 'OVERDUE'` → row
  background danger; `DUE_SOON` → warning.
- **Column `SLA_STATE`** HTML expression:
  `<span class="t-Badge t-Badge--{CASE}">#SLA_STATE#</span>`.
- **Column `ACTING_FOR_NAME`** heading *"On behalf of"* — the column that tells a
  delegate why this is in their queue at all.
- **Control Break** on `DOC_TYPE_NAME`, **Aggregate** `SUM(AMOUNT)`.
- Saved reports (Alternative/Public): *Overdue*, *Due today*, *Over 50k*.
- **Icon View** or **Cards** region as a second Region Display Selector tab if
  approvers prefer it on mobile.

**Inline Approve / Reject**

Add two link columns rendering buttons:

```
<a href="#" class="t-Button t-Button--small t-Button--success js-approve"
   data-step-id="#STEP_ID#">Approve</a>
<a href="#" class="t-Button t-Button--small t-Button--danger js-reject"
   data-step-id="#STEP_ID#">Reject</a>
```

**Items**: `P30_STEP_ID` (hidden), `P30_COMMENTS` (hidden), `P30_ACTION` (hidden).

**Dynamic Action `Inline approve`**

1. Event **Click**, Selection Type *jQuery Selector*, `.js-approve`
2. True action **Execute JavaScript**:
   ```js
   apex.item('P30_STEP_ID').setValue(this.triggeringElement.dataset.stepId);
   ```
3. True action **Confirm**: *"Approve this request?"* (Style: Success)
4. True action **Execute Server-side Code**, Items to Submit `P30_STEP_ID`:
   ```sql
   begin
     pkg_approval_engine.approve(:P30_STEP_ID, p_actor => :APP_USER);
   end;
   ```
5. True action **Refresh** the report, then **Show Success Message** *"Approved."*
6. On the server-side action set **Wait for Result** = Yes and add an *Error*
   handling true action showing the message — the engine raises `-20003`/`-20005`
   with text meant for the user (for example when a colleague in the same
   any-one-of group approved it a second earlier).

**Dynamic Action `Inline reject`** — identical, but rejection needs a reason, so
route it through page 31 rather than a bare confirm:
`apex.navigation.dialog` to `f?p=&APP_ID.:31:&SESSION.::NO::P31_STEP_ID,P31_ACTION:<id>,REJECT`.

---

## Page 31 — Action dialog (modal)

Page mode **Modal Dialog**. Authorization on the *page*: `CAN_ACT_ON_STEP`.
This is the enforcement point — the report is a convenience, this is the gate.

**Items**: `P31_STEP_ID`, `P31_ACTION` (`APPROVE`/`REJECT`/`INFO`/`REASSIGN`),
`P31_COMMENTS` (Textarea), `P31_TO_EMPLOYEE_ID` (Popup LOV, shown only when
`P31_ACTION = 'REASSIGN'`).

**Region "Request summary"** — read-only, source `v_approval_requests` filtered
by the step's request, so the approver sees what they are signing.

**Region "Chain so far"** — `v_approval_chain` for the same request, so they can
see who has already signed and who comes next.

**Validation**: `P31_COMMENTS` required when `P31_ACTION in ('REJECT','INFO')`.
The package enforces this too (`-20004`); the page validation is for the round
trip, not for safety.

**Process `DO_ACTION`**:

```sql
begin
  case :P31_ACTION
    when 'APPROVE'  then pkg_approval_engine.approve(:P31_STEP_ID, :APP_USER, :P31_COMMENTS);
    when 'REJECT'   then pkg_approval_engine.reject (:P31_STEP_ID, :APP_USER, :P31_COMMENTS);
    when 'INFO'     then pkg_approval_engine.request_info(:P31_STEP_ID, :APP_USER, :P31_COMMENTS);
    when 'REASSIGN' then pkg_approval_engine.reassign(:P31_STEP_ID, :P31_TO_EMPLOYEE_ID, :APP_USER, :P31_COMMENTS);
    else raise_application_error(-20000, 'Unknown action ' || :P31_ACTION);
  end case;
end;
```

Close the dialog on success and refresh page 30's report from the
*Dialog Closed* dynamic action.

---

## Page 20 — Request detail with timeline

Authorization: `CAN_VIEW_REQUEST`.

**Item**: `P20_REQUEST_ID`.

**Region 1 — Header** (Form, read-only, source `v_approval_requests`).

**Region 2 — "Approval chain" (Cards or Classic Report, template *Timeline*)**

```sql
select step_seq
     , group_no
     , step_mode
     , step_status
     , original_approver_name
     , original_approver_title
     , acting_approver_name
     , is_delegated_yn
     , activated_on
     , sla_due_on
     , action_on
     , action_by_username
     , comments
     , escalation_count
     , lane
     , case step_status
         when 'APPROVED' then 'fa-check-circle u-success-text'
         when 'REJECTED' then 'fa-times-circle u-danger-text'
         when 'ACTIVE'   then 'fa-clock-o u-warning-text'
         when 'SKIPPED'  then 'fa-forward u-normal-text'
         else 'fa-circle-o u-normal-text'
       end as icon_class
  from v_approval_chain
 where request_id = :P20_REQUEST_ID
 order by step_seq
```

Render steps sharing a `GROUP_NO` under one heading so parallel groups look
parallel — a "Group 4 — both must approve" sub-header removes most of the
support questions this kind of page generates.

**Region 3 — "History" (Classic Report, template *Timeline*)**

```sql
select event_ts
     , event_code
     , outcome
     , actor_name
     , actor_username
     , from_status
     , to_status
     , comments
     , icon_class
  from v_approval_timeline
 where request_id = :P20_REQUEST_ID
 order by event_ts desc
```

Timeline template mapping: *Date* → `EVENT_TS`, *Title* → `EVENT_CODE`,
*Description* → `COMMENTS`, *Icon* → `ICON_CLASS`, *User* → `ACTOR_NAME`.

**Buttons** (each with a server-side condition on status and requester):
`RECALL`, `WITHDRAW`, `PROVIDE_INFO` — all calling the matching package
procedure, all with Confirm dialogs. `RECALL` should warn explicitly:
*"Recalling cancels the approvals collected so far. Resubmitting rebuilds the
chain from the current org chart."* That is true and it surprises people.

---

## Pages 40/41 — Rule maintenance (admin)

Authorization: `APPROVAL_ADMIN` on the page.

**Page 40 — Interactive Grid on `APPROVAL_RULES`**, editable, with:

- LOVs on `DOC_TYPE`, `DEPT_ID`, `COST_CENTER`, `FALLBACK_ROLE_CODE`,
  `LIMIT_MODE` (`INDIVIDUAL`/`CUMULATIVE`/`NONE`)
- **Master-detail** to page 41 (`APPROVAL_RULE_STEPS`) on `RULE_ID`
- A **"Test this rule"** button opening page 42

`APPROVAL_RULES` has no guard trigger — rules are configuration, and the
ambiguity trigger is the only thing standing between an admin and a coin-flip
routing decision. Surface it: add a region below the grid,

```sql
select rule_code_a, rule_code_b, doc_type, overlap_from, overlap_to, verdict
  from v_approval_rule_overlaps
 order by verdict, rule_code_a
```

with the region title *"Overlapping rules"* and a note that `RESOLVED_BY_PRIORITY`
is fine and `AMBIGUOUS` cannot be saved.

**Page 42 — "Rule simulator"** (this is the page that stops rule changes from
being deployed by hope). Items `P42_DOC_TYPE`, `P42_AMOUNT`, `P42_EMPLOYEE_ID`,
`P42_DEPT_ID`, `P42_COST_CENTER`; one report region:

```sql
select step_seq, group_no, step_mode, source_code, approver_name
     , job_level, approval_limit, cumulative_limit, covers_amount_yn, note
  from table(pkg_approval_engine.preview_chain(
               p_doc_type     => :P42_DOC_TYPE
             , p_amount       => to_number(:P42_AMOUNT)
             , p_requester_id => to_number(:P42_EMPLOYEE_ID)
             , p_dept_id      => to_number(:P42_DEPT_ID)
             , p_cost_center  => :P42_COST_CENTER))
 order by step_seq
```

---

## Page 50 — Delegations

Two audiences, one table:

- **My delegations** (self-service, `IS_REGISTERED_EMPLOYEE`): Interactive Grid
  on `APPROVAL_DELEGATIONS` where `DELEGATOR_ID = :AI_EMPLOYEE_ID`. Set the
  `DELEGATOR_ID` column to *Hidden* with a default of `&AI_EMPLOYEE_ID.` so a
  user cannot create a delegation on someone else's behalf by editing the grid.
- **All delegations** (`APPROVAL_ADMIN`): the same grid unfiltered.

Add a validation: `DELEGATE_ID` must be active and must not be the delegator
(the check constraint catches the second, but a page validation says so nicely).

---

## Page 60 — Hierarchy health (admin)

```sql
select employee_id, employee_no, full_name, job_level, manager_name, active_flag, finding
  from v_hierarchy_health
 where finding <> 'OK'
 order by decode(finding,'CYCLE',0,'ORPHAN',1,'INACTIVE_MANAGER',2,3), full_name
```

Run this after every HR feed. `CYCLE` and `ORPHAN` are the two findings that
turn into `ORA-20011`/`ORA-20012` at submission time, in front of a user.

---

## Automations

Shared Components → **Automations**. All three run as *Scheduled*; set the
**Actions → Execution Chain** to *Stop on Error* and enable **Log Errors**.

### Automation 1 — `SLA_ESCALATION`

- Type: *Scheduled*, Frequency: hourly (`FREQ=HOURLY;INTERVAL=1`)
- Execution: *Always* (the action itself checks whether there is anything to do)
- Action (PL/SQL):

```sql
declare
  l_count pls_integer;
begin
  pkg_approval_engine.escalate_overdue(p_doc_type => null, p_escalated => l_count);
  apex_automation.log_info('Escalated ' || l_count || ' overdue step(s).');
end;
```

### Automation 2 — `SLA_REMINDERS`

- Frequency: hourly, offset 30 minutes from Automation 1 so the two do not
  contend for the same rows

```sql
declare
  l_count pls_integer;
begin
  pkg_approval_engine.send_reminders(p_doc_type => null, p_queued => l_count);
  apex_automation.log_info('Queued ' || l_count || ' reminder(s).');
end;
```

### Automation 3 — `NOTIFICATION_OUTBOX`

- Frequency: every 5 minutes
- Type: *Query* over the outbox, Execution: *For Each Row*
- Query:

```sql
select notification_id, recipient_email, template_static_id, placeholders, attempts
  from approval_notifications
 where status = 'QUEUED'
   and attempts < 5
 order by queued_on
 fetch first 200 rows only
```

- Action (PL/SQL, per row):

```sql
begin
  apex_mail.send(
      p_to                 => :RECIPIENT_EMAIL
    , p_template_static_id => :TEMPLATE_STATIC_ID
    , p_placeholders       => :PLACEHOLDERS);

  update approval_notifications
     set status = 'SENT', sent_on = systimestamp, attempts = attempts + 1
   where notification_id = :NOTIFICATION_ID;
exception
  when others then
    update approval_notifications
       set status     = case when attempts + 1 >= 5 then 'FAILED' else 'QUEUED' end
         , attempts   = attempts + 1
         , last_error = substr(sqlerrm, 1, 4000)
     where notification_id = :NOTIFICATION_ID;
end;
```

Then a final step in the chain: `apex_mail.push_queue;`.

**Why an outbox instead of calling `APEX_MAIL` from the engine.** `APEX_MAIL`
needs an APEX session, which the engine does not have when it is called from
SQLcl, a REST handler or a scheduler job. More importantly a mail failure inside
`APPROVE` would roll back the approval. Queue-then-drain decouples the two, makes
delivery retryable, and gives you a table to look at when someone says they never
got the email.

**Monitoring**: add an admin page over `APPROVAL_NOTIFICATIONS` filtered to
`status = 'FAILED'`, and an Automation *Error* action that mails the admin.

---

## Custom engine versus APEX native Task Definitions

APEX has had **Task Definitions** (Human Tasks) since 21.2 and **Workflows**
since 23.2. They are good, and you should not build what you can configure. The
honest comparison:

### Where native wins

- **Fixed-shape approvals.** "Manager, then Finance" — participants resolved by a
  SQL query, done. No package to own.
- **The Unified Task List.** A supported, accessible, already-built inbox page
  with task details, actions, comments and history. Reproducing it well is most
  of the work in pages 30 and 31 above.
- **Built-in expiration and vacation rules**, task priorities, and delegation via
  `APEX_APPROVAL` without you writing the substitution logic.
- **Upgrades.** Oracle maintains it. Your `PKG_APPROVAL_ENGINE` is yours forever.
- **Workflow Designer (23.2+)** genuinely handles serial and parallel human tasks,
  switches and variables — most static approval graphs fit.

### Where a custom engine wins

- **The chain's *length* is data, not design.** Native workflows model a graph you
  draw at design time. Here the number of steps is whatever the walk up
  `MANAGER_ID` produces for this requester at this amount today — anything from
  one step to eight. Expressing that natively means a loop activity around a task,
  and you end up rebuilding the resolver anyway, minus the SQL access to it.
- **Authority arithmetic.** "Climb until cumulative approval limit covers the
  amount, but never above level 8, and never more than six people" is business
  logic with a shape. It belongs in a package you can unit-test — see
  `sql/90_regression.sql` — not in a workflow condition expression.
- **The chain must be queryable.** Finance wants "show me everything waiting on
  the CFO, by cost centre, ageing". `APPROVAL_STEPS` is a table you can join and
  index. Native task state lives in APEX's dictionary views, which you can query
  but not extend with your own columns.
- **Rules as data, edited by administrators.** `APPROVAL_RULES` is a business
  table with an APEX admin page. Changing a native workflow is an application
  change: export, deploy, release window.
- **Non-APEX callers.** The engine is a database package, so ORDS, a batch job, or
  another schema can submit and approve. Task Definitions are an APEX construct.

### The rule of thumb

If you can draw the approval flow on a whiteboard and it does not change shape
per document, use **native Task Definitions and Workflows**. If the shape is
computed from an org chart and a threshold matrix — which is the requirement this
project was written against — a custom engine is the smaller, more testable
system, and you keep the option of surfacing it *through* the Unified Task List
later by creating one native task per `APPROVAL_STEPS` row.

That hybrid is worth knowing about: keep this resolver for *who and in what
order*, and let native tasks own the inbox UI. You get the data-driven chain and
Oracle's task list, at the cost of keeping two records of one step in sync — a
trade most teams should only make once the custom inbox has proven insufficient.

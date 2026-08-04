--------------------------------------------------------------------------------
-- 06_pkg_approval_engine.pks
--
-- The single writable entry point for the approval runtime. Everything that
-- changes an APPROVAL_REQUESTS or APPROVAL_STEPS row lives here; the triggers in
-- 05_triggers.sql make that a rule rather than a convention.
--
-- Transaction policy
--   No procedure in this package commits. The caller (an APEX page process, an
--   Automation, a REST handler) owns the transaction, so an approval and the
--   business-side update it triggers succeed or fail together. The only
--   exception is LOG_ACTION, which is autonomous - the audit trail must survive
--   the rollback of the thing it is recording.
--
-- Identity policy
--   Every acting procedure takes P_ACTOR. NULL means "the current APEX user",
--   resolved through CURRENT_USERNAME. Passing it explicitly is what lets the
--   regression pack impersonate approvers without an APEX session.
--
-- Error contract
--   -20001  request not found              -20012  hierarchy cycle
--   -20002  invalid state for the action   -20013  self-approval blocked
--   -20003  caller is not the approver     -20014  chain cannot cover the amount
--   -20004  comments are mandatory         -20015  invalid delegation
--   -20005  step is not actionable         -20020  row locked by another session
--   -20010  no rule matched                -20030  ambiguous rule set (trigger)
--   -20011  no approver could be resolved  -20031  hierarchy cycle (trigger)
--                                          -20099  direct DML blocked (trigger)
--------------------------------------------------------------------------------
set define off

create or replace package pkg_approval_engine authid definer as

  --============================================================================
  -- Status vocabulary. Referenced by APEX pages and by the regression pack so
  -- that a literal string appears in exactly one place.
  --============================================================================
  gc_req_draft      constant varchar2(20) := 'DRAFT';
  gc_req_pending    constant varchar2(20) := 'PENDING';
  gc_req_info       constant varchar2(20) := 'INFO_REQUESTED';
  gc_req_approved   constant varchar2(20) := 'APPROVED';
  gc_req_rejected   constant varchar2(20) := 'REJECTED';
  gc_req_recalled   constant varchar2(20) := 'RECALLED';
  gc_req_withdrawn  constant varchar2(20) := 'WITHDRAWN';

  gc_step_pending   constant varchar2(20) := 'PENDING';
  gc_step_active    constant varchar2(20) := 'ACTIVE';
  gc_step_approved  constant varchar2(20) := 'APPROVED';
  gc_step_rejected  constant varchar2(20) := 'REJECTED';
  gc_step_skipped   constant varchar2(20) := 'SKIPPED';
  gc_step_info      constant varchar2(20) := 'INFO_REQUESTED';
  gc_step_cancelled constant varchar2(20) := 'CANCELLED';
  gc_step_reassign  constant varchar2(20) := 'REASSIGNED';

  --============================================================================
  -- Error numbers, exposed so callers can trap them by name.
  --============================================================================
  gc_err_not_found      constant pls_integer := -20001;
  gc_err_bad_state      constant pls_integer := -20002;
  gc_err_not_approver   constant pls_integer := -20003;
  gc_err_need_comment   constant pls_integer := -20004;
  gc_err_step_inactive  constant pls_integer := -20005;
  gc_err_no_rule        constant pls_integer := -20010;
  gc_err_no_approver    constant pls_integer := -20011;
  gc_err_cycle          constant pls_integer := -20012;
  gc_err_self_approval  constant pls_integer := -20013;
  gc_err_no_coverage    constant pls_integer := -20014;
  gc_err_bad_delegation constant pls_integer := -20015;
  gc_err_locked         constant pls_integer := -20020;

  e_not_found     exception;  pragma exception_init(e_not_found,    -20001);
  e_bad_state     exception;  pragma exception_init(e_bad_state,    -20002);
  e_not_approver  exception;  pragma exception_init(e_not_approver, -20003);
  e_no_rule       exception;  pragma exception_init(e_no_rule,      -20010);
  e_no_approver   exception;  pragma exception_init(e_no_approver,  -20011);
  e_no_coverage   exception;  pragma exception_init(e_no_coverage,  -20014);

  --============================================================================
  -- Identity and small helpers
  --============================================================================

  -- APP_USER inside APEX, the schema user outside it. Always upper case.
  function current_username return varchar2;

  -- Employee behind a username. Raises -20001 when the directory has no match,
  -- because "unknown user acted" is never an acceptable audit row.
  function employee_id_for (p_username in varchar2) return number;

  -- SLA due date P_HOURS of *working* time from P_FROM, skipping weekends and
  -- APPROVAL_HOLIDAYS. Deterministic, so it can sit in a virtual column later.
  function sla_due (p_from  in timestamp
                  , p_hours in number) return timestamp;

  --============================================================================
  -- Delegation
  --============================================================================

  -- Who actually acts for P_EMPLOYEE_ID today: follows a delegation chain
  -- (A out, delegates to B; B out, delegates to C) up to GC_MAX_DELEGATION_HOPS
  -- and stops on a loop. Returns P_EMPLOYEE_ID when no delegation applies.
  function effective_approver (p_employee_id in number
                             , p_doc_type    in varchar2 default null
                             , p_amount      in number   default null
                             , p_ref_date    in date     default sysdate) return number;

  --============================================================================
  -- Chain resolution
  --============================================================================

  -- The resolver. Walks EMPLOYEES upward from the requester's manager applying
  -- the matched rule, then splices in the rule's mandatory steps. Pure: reads
  -- the org chart and the rule matrix, writes nothing.
  function resolve_chain (p_doc_type     in  varchar2
                        , p_amount       in  number
                        , p_requester_id in  number
                        , p_dept_id      in  number   default null
                        , p_cost_center  in  varchar2 default null
                        , p_ref_date     in  date     default sysdate
                        , p_rule_id      out number) return approval_chain_nt;

  -- Same, for a saved draft. Pipelined so an APEX region can select from it.
  function preview_chain (p_request_id in number) return approval_chain_nt pipelined;

  -- Same, for values still on the page and not yet saved.
  function preview_chain (p_doc_type     in varchar2
                        , p_amount       in number
                        , p_requester_id in number
                        , p_dept_id      in number   default null
                        , p_cost_center  in varchar2 default null) return approval_chain_nt pipelined;

  -- Materialises the resolved chain into APPROVAL_STEPS. Called by SUBMIT;
  -- exposed separately so an admin page can rebuild a chain after an org change.
  procedure build_chain (p_request_id in number);

  --============================================================================
  -- Request lifecycle
  --============================================================================

  function create_request (p_doc_type      in varchar2
                         , p_title         in varchar2
                         , p_amount        in number
                         , p_requester_id  in number   default null
                         , p_doc_id        in number   default null
                         , p_doc_ref       in varchar2 default null
                         , p_description   in clob     default null
                         , p_currency_code in varchar2 default 'USD'
                         , p_dept_id       in number   default null
                         , p_cost_center   in varchar2 default null
                         , p_priority_code in varchar2 default 'NORMAL'
                         , p_actor         in varchar2 default null) return number;

  procedure submit (p_request_id in number
                  , p_actor      in varchar2 default null
                  , p_comments   in varchar2 default null);

  --============================================================================
  -- Approver actions. Each validates that P_ACTOR owns the step, that the step
  -- is ACTIVE, and that the parent request is still in flight.
  --============================================================================

  procedure approve (p_step_id  in number
                   , p_actor    in varchar2 default null
                   , p_comments in varchar2 default null);

  -- Comments are mandatory: a rejection with no reason is a support ticket.
  procedure reject (p_step_id  in number
                  , p_actor    in varchar2
                  , p_comments in varchar2);

  -- Pauses the step and sends the request back to the requester for an answer
  -- without losing the chain built so far.
  procedure request_info (p_step_id  in number
                        , p_actor    in varchar2
                        , p_comments in varchar2);

  -- The requester answers; the paused step goes back to ACTIVE with a fresh SLA.
  procedure provide_info (p_request_id in number
                        , p_actor      in varchar2 default null
                        , p_comments   in varchar2 default null);

  -- Permanent hand-off of one step to another employee. The original approver
  -- is retained on the row so the audit shows whose authority was used.
  procedure reassign (p_step_id          in number
                    , p_to_employee_id   in number
                    , p_actor            in varchar2 default null
                    , p_comments         in varchar2 default null);

  --============================================================================
  -- Requester actions
  --============================================================================

  -- Pull an in-flight request back to DRAFT for editing. Legal until the final
  -- step approves. Cancels outstanding steps; the chain is rebuilt on resubmit.
  procedure recall (p_request_id in number
                  , p_actor      in varchar2 default null
                  , p_comments   in varchar2 default null);

  -- Abandon the request outright. Terminal - unlike RECALL, there is no way back.
  procedure withdraw (p_request_id in number
                    , p_actor      in varchar2 default null
                    , p_comments   in varchar2 default null);

  --============================================================================
  -- SLA handling. ESCALATE moves one step up the management line of whoever is
  -- currently sitting on it; the batch wrappers are what the APEX Automations
  -- call.
  --============================================================================

  procedure escalate (p_step_id in number
                    , p_actor   in varchar2 default null
                    , p_reason  in varchar2 default null);

  procedure escalate_overdue (p_doc_type  in  varchar2    default null
                            , p_max_rows  in  pls_integer default 500
                            , p_escalated out pls_integer);

  procedure send_reminders (p_doc_type in  varchar2    default null
                          , p_max_rows in  pls_integer default 1000
                          , p_queued   out pls_integer);

  --============================================================================
  -- Inbox / authorisation
  --============================================================================

  -- Actionable steps for a user, including those they hold only as a delegate.
  function get_pending_for_user (p_username in varchar2 default null)
    return approval_pending_nt pipelined;

  -- Ref cursor flavour, for REST handlers and anything that wants a plain
  -- result set rather than a collection scan.
  function get_pending_cursor (p_username in varchar2 default null)
    return sys_refcursor;

  function pending_count (p_username in varchar2 default null) return number;

  -- 'Y' when P_USERNAME may act on P_STEP_ID right now. This is the function
  -- behind the APEX authorisation scheme; it is intentionally cheap enough to
  -- be evaluated per row.
  function can_act (p_step_id  in number
                  , p_username in varchar2 default null) return varchar2;

  -- 'Y' when P_USERNAME may see the request at all: requester, any approver on
  -- the chain (past or present), or an administrator.
  function can_view (p_request_id in number
                   , p_username   in varchar2 default null) return varchar2;

  function is_admin (p_username in varchar2 default null) return varchar2;

  --============================================================================
  -- Audit. Public because the business layer should log its own actions into
  -- the same stream ("PO raised from PR-2026-001042").
  --============================================================================
  procedure log_action (p_request_id  in number
                      , p_action_code in varchar2
                      , p_step_id     in number   default null
                      , p_outcome     in varchar2 default 'SUCCESS'
                      , p_from_status in varchar2 default null
                      , p_to_status   in varchar2 default null
                      , p_actor       in varchar2 default null
                      , p_comments    in varchar2 default null
                      , p_error_code  in number   default null
                      , p_error_msg   in varchar2 default null
                      , p_payload     in clob     default null);

  function version return varchar2;

end pkg_approval_engine;
/

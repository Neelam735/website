--------------------------------------------------------------------------------
-- 01_types.sql
--
-- SQL object types backing the pipelined APIs in PKG_APPROVAL_ENGINE. They are
-- schema-level (not PL/SQL-local) so that APEX regions can select straight out
-- of TABLE(...) without a wrapper view.
--
-- Run as: <APP_SCHEMA>  (the APEX parsing schema)
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- One resolved approval step, as produced by the chain resolver. Used both for
-- the pre-submission preview and as the staging row for the bulk insert into
-- APPROVAL_STEPS.
--------------------------------------------------------------------------------
create or replace type approval_chain_ot as object (
  step_seq             number(3)      -- 1..n, execution order
, group_no             number(3)      -- steps sharing a group run in parallel
, step_mode            varchar2(10)   -- SEQ | ALL | ANY
, source_code          varchar2(12)   -- HIERARCHY | RULE | FALLBACK
, original_approver_id number(9)      -- position holder (authority owner)
, approver_id          number(9)      -- who actually acts (delegate applied)
, approver_name        varchar2(120)
, approver_username    varchar2(100)
, approver_email       varchar2(240)
, job_level            number(2)
, approval_limit       number(14,2)   -- the ORIGINAL approver's limit
, cumulative_limit     number(14,2)   -- running sum down the chain
, delegation_id        number(12)     -- populated when a delegate was applied
, sla_hours            number(4)      -- rule-step override, else the rule default
, covers_amount_yn     char(1)        -- Y once the chain covers the amount
, note                 varchar2(400)  -- human-readable reason for this step
)
/

create or replace type approval_chain_nt as table of approval_chain_ot
/

--------------------------------------------------------------------------------
-- One actionable item in an approver's inbox.
--------------------------------------------------------------------------------
create or replace type approval_pending_ot as object (
  step_id            number(12)
, request_id         number(12)
, request_ref        varchar2(40)
, doc_type           varchar2(30)
, doc_type_name      varchar2(100)
, doc_ref            varchar2(60)
, title              varchar2(200)
, amount             number(14,2)
, currency_code      char(3)
, priority_code      varchar2(10)
, requester_name     varchar2(120)
, requester_username varchar2(100)
, dept_name          varchar2(100)
, cost_center        varchar2(20)
, submitted_on       timestamp
, step_seq           number(3)
, group_no           number(3)
, step_mode          varchar2(10)
, activated_on       timestamp
, sla_due_on         timestamp
, hours_remaining    number
, sla_state          varchar2(10)   -- OK | DUE_SOON | OVERDUE
, escalation_count   number(2)
, acting_for_name    varchar2(120)  -- set when acting as someone's delegate
)
/

create or replace type approval_pending_nt as table of approval_pending_ot
/

--------------------------------------------------------------------------------
-- 09_seed.sql
--
-- Reference data, a 22-person org chart eight levels deep, and a rule matrix for
-- Purchase Requisitions and Travel.
--
-- The org chart deliberately contains three defects, because a routing engine
-- that is only ever tested against a clean hierarchy is untested:
--   * CHEN WEI  is inactive but still has a direct report (skip-level case)
--   * NINA PETROVA has APPROVAL_LIMIT 0 (must be climbed past, not stopped at)
--   * INGRID HALVORSEN has no manager at all (orphan / fallback case)
--
-- Safe to re-run only after 00_drop_all.sql. Explicit IDs are used so the
-- regression pack can reference people by number; the identity columns are
-- re-seeded at the end so ordinary inserts continue from the right value.
--------------------------------------------------------------------------------
set define off

--==============================================================================
-- Reference data
--==============================================================================

insert into departments (dept_id, dept_code, dept_name, parent_dept_id) values (10, 'EXEC', 'Executive',   null);
insert into departments (dept_id, dept_code, dept_name, parent_dept_id) values (20, 'FIN',  'Finance',     10);
insert into departments (dept_id, dept_code, dept_name, parent_dept_id) values (30, 'ENG',  'Engineering', 10);
insert into departments (dept_id, dept_code, dept_name, parent_dept_id) values (40, 'OPS',  'Operations',  10);

insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-1000', 'Executive Office',      10);
insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-2000', 'Finance Shared',        20);
insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-3100', 'Engineering Platform',  30);
insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-3200', 'Engineering Product',   30);
insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-4100', 'Facilities',            40);
insert into cost_centers (cost_center, cc_name,               dept_id) values ('CC-4200', 'Procurement',           40);

insert into approval_doc_types (doc_type, doc_type_name, source_table, url_target) values
  ('PR', 'Purchase Requisition', 'PURCHASE_REQUISITIONS', 'f?p=&APP_ID.:20:&SESSION.::NO::P20_REQUEST_ID:#REQUEST_ID#');
insert into approval_doc_types (doc_type, doc_type_name, source_table, url_target) values
  ('TRAVEL', 'Travel Request', 'TRAVEL_REQUESTS', 'f?p=&APP_ID.:20:&SESSION.::NO::P20_REQUEST_ID:#REQUEST_ID#');

insert into approval_roles (role_code, role_name, description) values
  ('APPROVAL_ADMIN',     'Approval Administrator', 'Maintains rules and delegations; may reassign a stuck step but never approves.');
insert into approval_roles (role_code, role_name, description) values
  ('FINANCE_CONTROLLER', 'Financial Controller',   'Countersigns spend above the departmental tier.');
insert into approval_roles (role_code, role_name, description) values
  ('CFO',                'Chief Financial Officer','Final financial authority below board level.');
insert into approval_roles (role_code, role_name, description) values
  ('CEO',                'Chief Executive Officer','Authority of last resort; fallback for orphaned requesters.');
insert into approval_roles (role_code, role_name, description) values
  ('PROCUREMENT_LEAD',   'Procurement Lead',       'Reviews supplier and contract terms.');

insert into approval_holidays (holiday_date, description) values (date '2026-12-25', 'Christmas Day');
insert into approval_holidays (holiday_date, description) values (date '2026-12-26', 'Boxing Day');
insert into approval_holidays (holiday_date, description) values (date '2027-01-01', 'New Year''s Day');


--==============================================================================
-- Organisation
--
--  L10  Priya Raghavan .................................. CEO
--  L8   +- Marcus Vogel ................................. CFO
--  L7   |  +- Elena Sokolova ............................ VP Finance
--  L6   |     +- Grace Okafor ........................... Financial Controller
--  L8   +- Ada Nwosu .................................... COO
--  L7      +- Tomas Lindqvist .......................... VP Engineering
--  L6      |  +- Yuki Tanaka ............................ Director, Engineering
--  L5      |     +- Daniel Ofori ........................ Senior Manager, Eng
--  L4      |        +- Aisha Rahman ..................... Manager, Engineering
--  L3      |           +- Maya Fernandes ................ Team Lead
--  L2      |              +- Nina Petrova ............... Senior Engineer  (limit 0)
--  L1      |              |  +- Kofi Mensah ............. Engineer
--  L1      |              +- Sara Bergstrom ............. Engineer
--  L7      +- Ravi Menon .................................. VP Operations
--  L6         +- Sofia Bianchi .......................... Director, Operations
--  L5            +- Chen Wei ............................ Manager, Ops  (INACTIVE)
--  L4               +- Lars Eriksen ..................... Manager, Procurement
--  L3                  +- Omar Haddad ................... Team Lead, Ops
--  L2                     +- Jonas Weber ................ Analyst
--  L1                        +- Elif Demir .............. Coordinator
--  L2   (no manager) Ingrid Halvorsen ................... Contractor Liaison (ORPHAN)
--  L4   (no manager) Nadia Croft ........................ Approval Administrator
--==============================================================================

insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (1, 'E-0001', 'Priya Raghavan',  'priya.raghavan@example.com',  'PRAGHAVAN', null, 10, 'Chief Executive Officer',   10, 'CC-1000', 10000000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (2, 'E-0002', 'Marcus Vogel',    'marcus.vogel@example.com',    'MVOGEL',    1,  8, 'Chief Financial Officer',   20, 'CC-2000',  2000000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (3, 'E-0003', 'Ada Nwosu',       'ada.nwosu@example.com',       'ANWOSU',    1,  8, 'Chief Operating Officer',   10, 'CC-1000',  2000000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (4, 'E-0004', 'Elena Sokolova',  'elena.sokolova@example.com',  'ESOKOLOVA', 2,  7, 'VP Finance',                20, 'CC-2000',   750000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (5, 'E-0005', 'Tomas Lindqvist', 'tomas.lindqvist@example.com', 'TLINDQVIST',3,  7, 'VP Engineering',            30, 'CC-3100',   750000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (6, 'E-0006', 'Ravi Menon',      'ravi.menon@example.com',      'RMENON',    3,  7, 'VP Operations',             40, 'CC-4100',   750000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (7, 'E-0007', 'Grace Okafor',    'grace.okafor@example.com',    'GOKAFOR',   4,  6, 'Financial Controller',      20, 'CC-2000',   250000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (8, 'E-0008', 'Yuki Tanaka',     'yuki.tanaka@example.com',     'YTANAKA',   5,  6, 'Director, Engineering',     30, 'CC-3100',   250000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (9, 'E-0009', 'Sofia Bianchi',   'sofia.bianchi@example.com',   'SBIANCHI',  6,  6, 'Director, Operations',      40, 'CC-4100',   250000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (10,'E-0010', 'Daniel Ofori',    'daniel.ofori@example.com',    'DOFORI',    8,  5, 'Senior Manager, Engineering',30,'CC-3100',    75000, 'Y');
-- Inactive with a live direct report: every chain through Lars must skip Chen.
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (11,'E-0011', 'Chen Wei',        'chen.wei@example.com',        'CWEI',      9,  5, 'Manager, Operations',       40, 'CC-4100',    75000, 'N');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (12,'E-0012', 'Aisha Rahman',    'aisha.rahman@example.com',    'ARAHMAN',  10,  4, 'Manager, Engineering',      30, 'CC-3200',    25000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (13,'E-0013', 'Lars Eriksen',    'lars.eriksen@example.com',    'LERIKSEN', 11,  4, 'Manager, Procurement',      40, 'CC-4200',    25000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (14,'E-0014', 'Maya Fernandes',  'maya.fernandes@example.com',  'MFERNANDES',12, 3, 'Team Lead, Engineering',    30, 'CC-3200',     5000, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (15,'E-0015', 'Omar Haddad',     'omar.haddad@example.com',     'OHADDAD',  13,  3, 'Team Lead, Operations',     40, 'CC-4200',     5000, 'Y');
-- Limit 0: a real manager with no spending authority. The climb must pass through.
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (16,'E-0016', 'Nina Petrova',    'nina.petrova@example.com',    'NPETROVA', 14,  2, 'Senior Engineer',           30, 'CC-3200',        0, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (17,'E-0017', 'Jonas Weber',     'jonas.weber@example.com',     'JWEBER',   15,  2, 'Operations Analyst',        40, 'CC-4200',        0, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (18,'E-0018', 'Kofi Mensah',     'kofi.mensah@example.com',     'KMENSAH',  16,  1, 'Engineer',                  30, 'CC-3200',        0, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (19,'E-0019', 'Sara Bergstrom',  'sara.bergstrom@example.com',  'SBERGSTROM',14, 1, 'Engineer',                  30, 'CC-3200',        0, 'Y');
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (20,'E-0020', 'Elif Demir',      'elif.demir@example.com',      'EDEMIR',   17,  1, 'Operations Coordinator',    40, 'CC-4200',        0, 'Y');
-- No manager: exercises the fallback role path.
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (21,'E-0021', 'Ingrid Halvorsen','ingrid.halvorsen@example.com','IHALVORSEN',null,2,'Contractor Liaison',        40, 'CC-4200',        0, 'Y');
-- Administrator, intentionally outside the reporting tree.
insert into employees (employee_id, employee_no, full_name, email, apex_username, manager_id, job_level, job_title, dept_id, cost_center, approval_limit, active_flag) values
  (22,'E-0022', 'Nadia Croft',     'nadia.croft@example.com',     'NCROFT',   null, 4, 'Approval Administrator',    20, 'CC-2000',        0, 'Y');

insert into employee_roles (employee_id, role_code,            dept_id) values (22, 'APPROVAL_ADMIN',     null);
insert into employee_roles (employee_id, role_code,            dept_id) values (7,  'FINANCE_CONTROLLER', null);
insert into employee_roles (employee_id, role_code,            dept_id) values (2,  'CFO',                null);
insert into employee_roles (employee_id, role_code,            dept_id) values (1,  'CEO',                null);
insert into employee_roles (employee_id, role_code,            dept_id) values (13, 'PROCUREMENT_LEAD',   40);


--==============================================================================
-- Rule matrix - Purchase Requisitions
--
-- Bands are disjoint and priority-ordered; scoped rules (department, cost
-- centre) carry a lower PRIORITY number so they win over the global tiers.
-- V_APPROVAL_RULE_OVERLAPS should return zero AMBIGUOUS rows after this runs.
--==============================================================================

insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  100, 'PR-TIER-1', 'Purchase Requisition up to 5,000', 'PR', null, null
, 0, 5000, 100, 'INDIVIDUAL', 3, 3, 10, 3
, 'Y', 'CEO', 24, 8, 8, 2
, date '2026-01-01');

insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  110, 'PR-TIER-2', 'Purchase Requisition 5,000 to 50,000', 'PR', null, null
, 5000, 50000, 100, 'INDIVIDUAL', 3, 4, 10, 4
, 'Y', 'CEO', 24, 8, 8, 2
, date '2026-01-01');

insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  120, 'PR-TIER-3', 'Purchase Requisition 50,000 to 250,000', 'PR', null, null
, 50000, 250000, 100, 'INDIVIDUAL', 3, 6, 10, 6
, 'Y', 'CEO', 16, 6, 6, 2
, date '2026-01-01');

insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  130, 'PR-TIER-4', 'Purchase Requisition above 250,000', 'PR', null, null
, 250000, null, 100, 'INDIVIDUAL', 3, 8, 10, 8
, 'Y', 'CEO', 8, 4, 4, 3
, date '2026-01-01');

-- Engineering capital spend: same money, tighter chain, and either the Director
-- or the VP may clear it (any-one-of). Priority 50 beats the global tiers.
insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  140, 'PR-ENG-CAPEX', 'Engineering capital spend 10,000 to 100,000', 'PR', 30, null
, 10000, 100000, 50, 'INDIVIDUAL', 3, 5, 8, 4
, 'Y', 'CEO', 12, 4, 4, 2
, date '2026-01-01');

-- Procurement cost centre: level-driven only (LIMIT_MODE = NONE), two steps max.
-- This is how you express "we trust the process, not the wallet".
insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  150, 'PR-PROC-FAST', 'Procurement cost centre fast path up to 25,000', 'PR', null, 'CC-4200'
, 0, 25000, 40, 'NONE', 3, 4, 8, 2
, 'N', 'CEO', 8, 3, 3, 1
, date '2026-01-01');

-- Travel: cumulative authority, to show the alternative coverage semantics.
insert into approval_rules (
  rule_id, rule_code, rule_name, doc_type, dept_id, cost_center
, min_amount, max_amount, priority, limit_mode, start_at_level, min_approver_level, top_job_level, max_levels
, require_coverage, fallback_role_code, sla_hours, reminder_hours, escalate_after_hours, max_escalations
, valid_from) values (
  200, 'TRAVEL-STD', 'Travel request, cumulative authority', 'TRAVEL', null, null
, 0, null, 100, 'CUMULATIVE', 1, 3, 8, 4
, 'N', 'CEO', 24, 8, 8, 1
, date '2026-01-01');


--==============================================================================
-- Mandatory rule steps
--==============================================================================

-- Tier 2: the Financial Controller countersigns, after the line chain.
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, role_code, group_no, step_mode, mandatory_yn, sla_hours)
values (1, 110, 10, 'AFTER', 'ROLE', 'FINANCE_CONTROLLER', 1, 'SEQ', 'Y', 24);

-- Tier 3: Controller and CFO in parallel, both required (all-of).
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, role_code, group_no, step_mode, mandatory_yn, sla_hours)
values (2, 120, 10, 'AFTER', 'ROLE', 'FINANCE_CONTROLLER', 1, 'ALL', 'Y', 16);
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, role_code, group_no, step_mode, mandatory_yn, sla_hours)
values (3, 120, 20, 'AFTER', 'ROLE', 'CFO',                1, 'ALL', 'Y', 16);

-- Tier 4: CFO signs last, after the chain has already reached the CEO.
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, role_code, group_no, step_mode, mandatory_yn, sla_hours)
values (4, 130, 10, 'AFTER', 'ROLE', 'CFO', 1, 'SEQ', 'Y', 8);

-- Engineering capex: either the Director or the VP clears it (any-one-of).
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, employee_id, group_no, step_mode, mandatory_yn, sla_hours)
values (5, 140, 10, 'AFTER', 'EMPLOYEE', 8, 1, 'ANY', 'Y', 12);
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, employee_id, group_no, step_mode, mandatory_yn, sla_hours)
values (6, 140, 20, 'AFTER', 'EMPLOYEE', 5, 1, 'ANY', 'Y', 12);

-- Procurement fast path: the Procurement Lead reviews terms first.
insert into approval_rule_steps (rule_step_id, rule_id, step_no, position_code, approver_type, role_code, group_no, step_mode, mandatory_yn, sla_hours)
values (7, 150, 10, 'BEFORE', 'ROLE', 'PROCUREMENT_LEAD', 1, 'SEQ', 'N', 8);


--==============================================================================
-- Delegations
--==============================================================================

-- Grace (Financial Controller) is away for two weeks; Elena covers, uncapped.
insert into approval_delegations (delegation_id, delegator_id, delegate_id, doc_type, valid_from, valid_to, max_amount, reason)
values (1, 7, 4, null, trunc(sysdate) - 1, trunc(sysdate) + 13, null, 'Annual leave');

-- Yuki delegates PR work to Daniel, but only up to 50,000. Above that the step
-- stays with Yuki - this is the case that catches naive delegation code.
insert into approval_delegations (delegation_id, delegator_id, delegate_id, doc_type, valid_from, valid_to, max_amount, reason)
values (2, 8, 10, 'PR', trunc(sysdate) - 1, trunc(sysdate) + 6, 50000, 'Conference travel, capped cover');

commit;


--==============================================================================
-- Re-seed the identity columns past the explicit IDs used above. Without this,
-- the first application insert collides with a hand-seeded key.
--==============================================================================
alter table departments         modify dept_id      generated by default on null as identity start with limit value;
alter table employees           modify employee_id  generated by default on null as identity start with limit value;
alter table approval_rules      modify rule_id      generated by default on null as identity start with limit value;
alter table approval_rule_steps modify rule_step_id generated by default on null as identity start with limit value;
alter table approval_delegations modify delegation_id generated by default on null as identity start with limit value;


--==============================================================================
-- Optional demo traffic. Delete this block for a production install - it exists
-- so the APEX pages have something to render on first login.
--==============================================================================
declare
  l_req number(12);
begin
  -- Kofi (L1, engineering) raises a small requisition: PR-TIER-1.
  l_req := pkg_approval_engine.create_request(
             p_doc_type      => 'PR'
           , p_title         => 'Replacement laptop dock and monitor arm'
           , p_amount        => 480
           , p_doc_ref       => 'REQ-88012'
           , p_actor         => 'KMENSAH');
  pkg_approval_engine.submit(l_req, p_actor => 'KMENSAH');

  -- Sara raises engineering capex: PR-ENG-CAPEX, any-one-of tail group.
  l_req := pkg_approval_engine.create_request(
             p_doc_type      => 'PR'
           , p_title         => 'Build-farm GPU node'
           , p_amount        => 42000
           , p_doc_ref       => 'REQ-88013'
           , p_priority_code => 'HIGH'
           , p_actor         => 'SBERGSTROM');
  pkg_approval_engine.submit(l_req, p_actor => 'SBERGSTROM');

  -- Jonas raises a large operations requisition: PR-TIER-3, parallel all-of tail.
  l_req := pkg_approval_engine.create_request(
             p_doc_type      => 'PR'
           , p_title         => 'Annual facilities maintenance contract'
           , p_amount        => 145000
           , p_doc_ref       => 'REQ-88014'
           , p_actor         => 'JWEBER');
  pkg_approval_engine.submit(l_req, p_actor => 'JWEBER');

  -- And one left in DRAFT so the submit page has something to preview.
  l_req := pkg_approval_engine.create_request(
             p_doc_type      => 'PR'
           , p_title         => 'Lab test rig refresh'
           , p_amount        => 310000
           , p_doc_ref       => 'REQ-88015'
           , p_actor         => 'MFERNANDES');
end;
/

commit;

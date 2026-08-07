--------------------------------------------------------------------------------
-- 90_regression.sql
--
-- Executable form of docs/05-test-plan.md. Run it against a freshly seeded
-- schema; it asserts, prints a summary, and rolls back everything except the
-- audit rows (which are written autonomously and are meant to survive).
--
--   sqlcl> @90_regression.sql
--
-- The last line raises if anything failed, so it can gate a deployment:
--   sqlcl -S ... @90_regression.sql || exit 1
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited

declare
  l_pass pls_integer := 0;
  l_fail pls_integer := 0;

  l_req_5lvl   number(12);
  l_req_par    number(12);
  l_req_any    number(12);
  l_req_orphan number(12);
  l_req_self   number(12);
  l_req_dup    number(12);
  l_req_recall number(12);
  l_req_info   number(12);
  l_req_rej    number(12);

  l_id    number(12);
  l_n     number;
  l_s     varchar2(200);
  l_due   timestamp;

  --------------------------------------------------------------------------
  -- Assertions
  --------------------------------------------------------------------------
  procedure ok (p_name in varchar2, p_ok in boolean, p_detail in varchar2 default null) is
  begin
    if p_ok then
      l_pass := l_pass + 1;
      dbms_output.put_line('  PASS  ' || p_name);
    else
      l_fail := l_fail + 1;
      dbms_output.put_line('* FAIL  ' || p_name || nvl('  [' || p_detail || ']', ''));
    end if;
  end ok;

  procedure eqn (p_name in varchar2, p_actual in number, p_expected in number) is
  begin
    ok(p_name
     , nvl(p_actual, -987654) = nvl(p_expected, -987654)
     , 'expected ' || p_expected || ', got ' || nvl(to_char(p_actual),'NULL'));
  end eqn;

  procedure eqs (p_name in varchar2, p_actual in varchar2, p_expected in varchar2) is
  begin
    ok(p_name
     , nvl(p_actual,'~') = nvl(p_expected,'~')
     , 'expected "' || p_expected || '", got "' || nvl(p_actual,'NULL') || '"');
  end eqs;

  procedure section (p_title in varchar2) is
  begin
    dbms_output.put_line(chr(10) || '== ' || p_title);
  end section;

  --------------------------------------------------------------------------
  -- Helpers
  --------------------------------------------------------------------------
  function step_at (p_request_id in number, p_seq in number) return number is
    l number(12);
  begin
    select step_id into l from approval_steps where request_id = p_request_id and step_seq = p_seq;
    return l;
  exception when no_data_found then return null;
  end step_at;

  function first_active (p_request_id in number) return number is
    l number(12);
  begin
    select min(step_id) into l from approval_steps
     where request_id = p_request_id and status = 'ACTIVE';
    return l;
  end first_active;

  function req_status (p_request_id in number) return varchar2 is
    l varchar2(20);
  begin
    select status into l from approval_requests where request_id = p_request_id;
    return l;
  end req_status;

  function step_status (p_step_id in number) return varchar2 is
    l varchar2(20);
  begin
    select status into l from approval_steps where step_id = p_step_id;
    return l;
  end step_status;

  -- Approve whatever is currently active for a request, as its assigned user.
  procedure approve_current (p_request_id in number) is
  begin
    for s in (select s.step_id, e.apex_username
                from approval_steps s
                join employees e on e.employee_id = s.acting_approver_id
               where s.request_id = p_request_id and s.status = 'ACTIVE'
               order by s.step_seq)
    loop
      pkg_approval_engine.approve(s.step_id, p_actor => s.apex_username, p_comments => 'Regression approval');
    end loop;
  end approve_current;

begin
  dbms_output.put_line('Approval engine regression pack, version '
                       || pkg_approval_engine.version);

  --==========================================================================
  section('T1  Five-level hierarchy chain with a mandatory CFO tail');
  --==========================================================================
  -- Maya (team lead, L3) asks for 310,000. The walk must climb Aisha -> Daniel
  -- -> Yuki -> Tomas -> Ada, stop at the COO whose limit covers it, then add the
  -- CFO required by PR-TIER-4.
  l_req_5lvl := pkg_approval_engine.create_request(
                  p_doc_type => 'PR', p_title => 'T1 lab rig', p_amount => 310000
                , p_actor => 'MFERNANDES');
  pkg_approval_engine.submit(l_req_5lvl, p_actor => 'MFERNANDES');

  select count(*) into l_n from approval_steps where request_id = l_req_5lvl;
  eqn('T1 chain length', l_n, 6);

  select e.employee_no into l_s
    from approval_steps s join employees e on e.employee_id = s.acting_approver_id
   where s.request_id = l_req_5lvl and s.step_seq = 1;
  eqs('T1 first approver is the line manager', l_s, 'E-0012');

  select e.employee_no into l_s
    from approval_steps s join employees e on e.employee_id = s.acting_approver_id
   where s.request_id = l_req_5lvl and s.step_seq = 5;
  eqs('T1 climb stops at the COO', l_s, 'E-0003');

  select source_code into l_s from approval_steps where request_id = l_req_5lvl and step_seq = 6;
  eqs('T1 sixth step comes from the rule', l_s, 'RULE');

  select count(distinct group_no) into l_n from approval_steps where request_id = l_req_5lvl;
  eqn('T1 every step is its own sequential group', l_n, 6);

  eqs('T1 request is pending', req_status(l_req_5lvl), 'PENDING');

  --==========================================================================
  section('T2  Skip-level, delegation substitution, parallel all-of');
  --==========================================================================
  -- Jonas (L2, Operations) asks for 145,000. Chen Wei is inactive and must be
  -- skipped; the Financial Controller step must land on her delegate.
  l_req_par := pkg_approval_engine.create_request(
                 p_doc_type => 'PR', p_title => 'T2 facilities contract', p_amount => 145000
               , p_actor => 'JWEBER');
  pkg_approval_engine.submit(l_req_par, p_actor => 'JWEBER');

  select count(*) into l_n from approval_steps where request_id = l_req_par;
  eqn('T2 chain length', l_n, 5);

  select count(*) into l_n
    from approval_steps s join employees e on e.employee_id = s.original_approver_id
   where s.request_id = l_req_par and e.active_flag = 'N';
  eqn('T2 no inactive manager appears in the chain', l_n, 0);

  select count(*) into l_n
    from approval_steps s join employees e on e.employee_id = s.original_approver_id
   where s.request_id = l_req_par and e.employee_no = 'E-0011';
  eqn('T2 Chen Wei was skipped, not stopped at', l_n, 0);

  select s.original_approver_id, s.acting_approver_id, s.delegation_id
    into l_id, l_n, l_s
    from approval_steps s where s.request_id = l_req_par and s.step_seq = 4;
  eqn('T2 controller step keeps the original approver', l_id, 7);
  eqn('T2 controller step is acted by the delegate', l_n, 4);
  ok ('T2 the delegation is recorded on the step', l_s is not null);

  select count(distinct group_no) into l_n from approval_steps where request_id = l_req_par;
  eqn('T2 the last two steps share one parallel group', l_n, 4);

  select step_mode into l_s from approval_steps where request_id = l_req_par and step_seq = 5;
  eqs('T2 tail group is all-of', l_s, 'ALL');

  --==========================================================================
  section('T3  Amount above the highest authority in the company');
  --==========================================================================
  savepoint before_t3;
  declare
    l_over number(12);
  begin
    l_over := pkg_approval_engine.create_request(
                p_doc_type => 'PR', p_title => 'T3 unaffordable', p_amount => 20000000
              , p_actor => 'KMENSAH');
    pkg_approval_engine.submit(l_over, p_actor => 'KMENSAH');
    ok('T3 submission above the CEO limit is refused', false, 'no error raised');
  exception
    when others then
      eqn('T3 submission above the CEO limit raises -20014', sqlcode, -20014);
      ok ('T3 the error names the shortfall', instr(sqlerrm, 'does not cover') > 0, sqlerrm);
  end;
  rollback to before_t3;

  --==========================================================================
  section('T4  Orphaned requester falls back to the rule role');
  --==========================================================================
  -- Ingrid has no manager. PR-PROC-FAST applies (her cost centre) and names the
  -- CEO as fallback; the optional Procurement Lead step runs first.
  l_req_orphan := pkg_approval_engine.create_request(
                    p_doc_type => 'PR', p_title => 'T4 contractor kit', p_amount => 1000
                  , p_actor => 'IHALVORSEN');
  pkg_approval_engine.submit(l_req_orphan, p_actor => 'IHALVORSEN');

  select count(*) into l_n from approval_steps where request_id = l_req_orphan;
  eqn('T4 orphan still gets a chain', l_n, 2);

  select source_code into l_s from approval_steps where request_id = l_req_orphan and step_seq = 2;
  eqs('T4 second step is the fallback', l_s, 'FALLBACK');

  select e.employee_no into l_s
    from approval_steps s join employees e on e.employee_id = s.acting_approver_id
   where s.request_id = l_req_orphan and s.step_seq = 2;
  eqs('T4 fallback resolved to the CEO', l_s, 'E-0001');

  --==========================================================================
  section('T5  Self-approval is prevented');
  --==========================================================================
  -- Grace IS the Financial Controller. The rule step that would ask her to
  -- countersign her own requisition must disappear, not deadlock.
  l_req_self := pkg_approval_engine.create_request(
                  p_doc_type => 'PR', p_title => 'T5 controller own spend', p_amount => 20000
                , p_actor => 'GOKAFOR');
  pkg_approval_engine.submit(l_req_self, p_actor => 'GOKAFOR');

  select count(*) into l_n
    from approval_steps
   where request_id = l_req_self
     and (original_approver_id = 7 or acting_approver_id = 7);
  eqn('T5 the requester never appears in her own chain', l_n, 0);

  select count(*) into l_n from approval_steps where request_id = l_req_self;
  ok('T5 a chain was still produced', l_n >= 1, 'steps = ' || l_n);

  --==========================================================================
  section('T6  Duplicate approver collapsing');
  --==========================================================================
  -- Yuki has delegated PR work under 50,000 to Daniel, and Daniel is already on
  -- the hierarchy chain. He must sign once, not twice.
  l_req_dup := pkg_approval_engine.create_request(
                 p_doc_type => 'PR', p_title => 'T6 GPU node', p_amount => 42000
               , p_actor => 'SBERGSTROM');
  pkg_approval_engine.submit(l_req_dup, p_actor => 'SBERGSTROM');

  select count(*) into l_n
    from approval_steps where request_id = l_req_dup and acting_approver_id = 10;
  eqn('T6 Daniel appears exactly once', l_n, 1);

  select count(*) into l_n from approval_steps where request_id = l_req_dup;
  eqn('T6 the collapsed any-of group leaves one tail step', l_n, 4);

  --==========================================================================
  section('T7  Parallel any-one-of closes the whole group');
  --==========================================================================
  savepoint before_t7;
  update approval_delegations set active_flag = 'N' where delegation_id = 2;

  l_req_any := pkg_approval_engine.create_request(
                 p_doc_type => 'PR', p_title => 'T7 GPU node, no delegation', p_amount => 42000
               , p_actor => 'SBERGSTROM');
  pkg_approval_engine.submit(l_req_any, p_actor => 'SBERGSTROM');

  select count(*) into l_n from approval_steps where request_id = l_req_any;
  eqn('T7 both any-of candidates are materialised', l_n, 5);

  approve_current(l_req_any);   -- Maya
  approve_current(l_req_any);   -- Aisha
  approve_current(l_req_any);   -- Daniel

  select count(*) into l_n from approval_steps where request_id = l_req_any and status = 'ACTIVE';
  eqn('T7 two approvers are active at once', l_n, 2);

  select step_id into l_id
    from approval_steps where request_id = l_req_any and original_approver_id = 8;
  pkg_approval_engine.approve(l_id, p_actor => 'YTANAKA', p_comments => 'Cleared by the director');

  select status into l_s
    from approval_steps where request_id = l_req_any and original_approver_id = 5;
  eqs('T7 the other candidate is skipped', l_s, 'SKIPPED');
  eqs('T7 the request completes', req_status(l_req_any), 'APPROVED');

  rollback to before_t7;

  --==========================================================================
  section('T8  Parallel all-of waits for everyone');
  --==========================================================================
  approve_current(l_req_par);   -- Omar
  approve_current(l_req_par);   -- Lars
  approve_current(l_req_par);   -- Sofia

  select count(*) into l_n from approval_steps where request_id = l_req_par and status = 'ACTIVE';
  eqn('T8 both tail approvers are active', l_n, 2);

  select step_id into l_id from approval_steps where request_id = l_req_par and step_seq = 4;
  pkg_approval_engine.approve(l_id, p_actor => 'ESOKOLOVA', p_comments => 'Controller cover');
  eqs('T8 one of two is not enough', req_status(l_req_par), 'PENDING');

  select step_id into l_id from approval_steps where request_id = l_req_par and step_seq = 5;
  pkg_approval_engine.approve(l_id, p_actor => 'MVOGEL', p_comments => 'CFO');
  eqs('T8 the second closes the request', req_status(l_req_par), 'APPROVED');

  --==========================================================================
  section('T9  Only the assigned approver can act');
  --==========================================================================
  l_id := first_active(l_req_5lvl);
  eqs('T9 the assignee can act',      pkg_approval_engine.can_act(l_id, 'ARAHMAN'), 'Y');
  eqs('T9 a bystander cannot',        pkg_approval_engine.can_act(l_id, 'KMENSAH'), 'N');
  eqs('T9 an administrator cannot',   pkg_approval_engine.can_act(l_id, 'NCROFT'),  'N');

  savepoint before_t9;
  begin
    pkg_approval_engine.approve(l_id, p_actor => 'KMENSAH');
    ok('T9 approving someone else''s step is refused', false, 'no error raised');
  exception
    when others then
      eqn('T9 approving someone else''s step raises -20003', sqlcode, -20003);
  end;
  rollback to before_t9;

  --==========================================================================
  section('T10  Direct DML on runtime tables is blocked');
  --==========================================================================
  savepoint before_t10;
  begin
    update approval_steps set status = 'APPROVED' where step_id = l_id;
    ok('T10 direct step update is blocked', false, 'update succeeded');
  exception
    when others then
      eqn('T10 direct step update raises -20099', sqlcode, -20099);
  end;
  rollback to before_t10;

  begin
    update approval_requests set status = 'APPROVED' where request_id = l_req_5lvl;
    ok('T10 direct status change is blocked', false, 'update succeeded');
  exception
    when others then
      eqn('T10 direct status change raises -20099', sqlcode, -20099);
  end;
  rollback to before_t10;

  begin
    delete from approval_audit where rownum = 1;
    ok('T10 audit rows cannot be deleted', false, 'delete succeeded');
  exception
    when others then
      eqn('T10 audit delete raises -20099', sqlcode, -20099);
  end;
  rollback to before_t10;

  --==========================================================================
  section('T11  SLA breach escalates to the next manager up');
  --==========================================================================
  l_id := first_active(l_req_5lvl);

  -- Backdate the SLA. This is the one legitimate use of the guard outside the
  -- engine, and it is why ENTER_ENGINE exists as a documented call.
  pkg_approval_guard.enter_engine;
  update approval_steps set sla_due_on = systimestamp - interval '2' hour where step_id = l_id;
  pkg_approval_guard.leave_engine;

  declare
    l_count pls_integer;
  begin
    pkg_approval_engine.escalate_overdue(p_doc_type => 'PR', p_escalated => l_count);
    ok('T11 the sweep escalated at least one step', l_count >= 1, 'escalated = ' || l_count);
  end;

  select acting_approver_id, escalation_count, original_approver_id
    into l_n, l_id, l_s
    from approval_steps where step_id = first_active(l_req_5lvl);
  eqn('T11 the step moved to the manager above', l_n, 10);
  eqn('T11 the escalation was counted', l_id, 1);
  eqn('T11 the original approver is preserved', l_s, 12);

  --==========================================================================
  section('T12  Request info and resume');
  --==========================================================================
  l_req_info := pkg_approval_engine.create_request(
                  p_doc_type => 'PR', p_title => 'T12 monitor', p_amount => 480
                , p_actor => 'KMENSAH');
  pkg_approval_engine.submit(l_req_info, p_actor => 'KMENSAH');
  l_id := first_active(l_req_info);

  pkg_approval_engine.request_info(l_id, 'MFERNANDES', 'Which cost centre is this against?');
  eqs('T12 request is parked', req_status(l_req_info), 'INFO_REQUESTED');
  eqs('T12 step is parked',    step_status(l_id),      'INFO_REQUESTED');

  select sla_due_on into l_due from approval_steps where step_id = l_id;
  ok('T12 the SLA clock stops while the ball is with the requester', l_due is null);

  pkg_approval_engine.provide_info(l_req_info, 'KMENSAH', 'CC-3200.');
  eqs('T12 request resumes', req_status(l_req_info), 'PENDING');
  eqs('T12 step resumes',    step_status(l_id),      'ACTIVE');

  select sla_due_on into l_due from approval_steps where step_id = l_id;
  ok('T12 the SLA clock restarts', l_due is not null);

  --==========================================================================
  section('T13  Reject ends the document');
  --==========================================================================
  l_req_rej := pkg_approval_engine.create_request(
                 p_doc_type => 'PR', p_title => 'T13 rejected spend', p_amount => 145000
               , p_actor => 'JWEBER');
  pkg_approval_engine.submit(l_req_rej, p_actor => 'JWEBER');
  l_id := first_active(l_req_rej);

  savepoint before_t13;
  begin
    pkg_approval_engine.reject(l_id, 'OHADDAD', null);
    ok('T13 a rejection without a reason is refused', false, 'no error raised');
  exception
    when others then
      eqn('T13 rejection without a reason raises -20004', sqlcode, -20004);
  end;
  rollback to before_t13;

  pkg_approval_engine.reject(l_id, 'OHADDAD', 'Budget already committed elsewhere.');
  eqs('T13 request is rejected', req_status(l_req_rej), 'REJECTED');

  select count(*) into l_n
    from approval_steps
   where request_id = l_req_rej and status in ('PENDING','ACTIVE','INFO_REQUESTED');
  eqn('T13 no step is left open', l_n, 0);

  select count(*) into l_n from approval_steps where request_id = l_req_rej and status = 'CANCELLED';
  ok('T13 downstream steps are cancelled', l_n >= 1, 'cancelled = ' || l_n);

  --==========================================================================
  section('T14  Mid-flight org change: in-flight chains are stable, rebuilds are not');
  --==========================================================================
  l_req_recall := pkg_approval_engine.create_request(
                    p_doc_type => 'PR', p_title => 'T14 org change', p_amount => 42000
                  , p_actor => 'SBERGSTROM');
  pkg_approval_engine.submit(l_req_recall, p_actor => 'SBERGSTROM');

  select count(*) into l_n from approval_steps where request_id = l_req_recall;
  eqn('T14 chain built under the old org chart', l_n, 4);

  savepoint before_t14;
  -- Sara is moved to report directly to the Senior Manager.
  update employees set manager_id = 10 where employee_id = 19;

  select count(*) into l_n
    from approval_steps s
   where s.request_id = l_req_recall and s.acting_approver_id = 14;
  eqn('T14 the in-flight chain still contains the old manager', l_n, 1);

  pkg_approval_engine.recall(l_req_recall, 'SBERGSTROM', 'Re-scoping.');
  eqs('T14 recall parks the request', req_status(l_req_recall), 'RECALLED');

  select count(*) into l_n
    from approval_steps where request_id = l_req_recall and status = 'CANCELLED';
  ok('T14 open steps were cancelled on recall', l_n >= 1, 'cancelled = ' || l_n);

  pkg_approval_engine.submit(l_req_recall, p_actor => 'SBERGSTROM');

  select count(*) into l_n
    from approval_steps s
   where s.request_id = l_req_recall and s.status <> 'CANCELLED' and s.acting_approver_id = 14;
  eqn('T14 the rebuilt chain uses the new reporting line', l_n, 0);

  rollback to before_t14;

  --==========================================================================
  section('T15  Cycles cannot be introduced');
  --==========================================================================
  savepoint before_t15;
  begin
    -- Make the CEO report to a team lead who already reports (indirectly) to her.
    update employees set manager_id = 14 where employee_id = 1;
    ok('T15 a management cycle is rejected', false, 'update succeeded');
  exception
    when others then
      eqn('T15 a management cycle raises -20031', sqlcode, -20031);
  end;
  rollback to before_t15;

  begin
    update employees set manager_id = employee_id where employee_id = 12;
    ok('T15 self-management is rejected', false, 'update succeeded');
  exception
    when others then
      ok('T15 self-management violates a check constraint', sqlcode = -2290, sqlerrm);
  end;
  rollback to before_t15;

  --==========================================================================
  section('T16  Ambiguous rules are rejected at maintenance time');
  --==========================================================================
  savepoint before_t16;
  begin
    insert into approval_rules (
      rule_code, rule_name, doc_type, min_amount, max_amount, priority
    , limit_mode, start_at_level, min_approver_level, top_job_level, max_levels, valid_from)
    values (
      'PR-CLASH', 'Deliberate clash with PR-TIER-2', 'PR', 6000, 20000, 100
    , 'INDIVIDUAL', 3, 4, 10, 4, date '2026-01-01');
    ok('T16 an ambiguous rule is rejected', false, 'insert succeeded');
  exception
    when others then
      eqn('T16 an ambiguous rule raises -20030', sqlcode, -20030);
  end;
  rollback to before_t16;

  --==========================================================================
  section('T17  No matching rule is a clear error, not an empty chain');
  --==========================================================================
  savepoint before_t17;
  declare
    l_tr number(12);
  begin
    update approval_rules set valid_from = trunc(sysdate) + 30 where doc_type = 'TRAVEL';
    l_tr := pkg_approval_engine.create_request(
              p_doc_type => 'TRAVEL', p_title => 'T17 conference', p_amount => 2500
            , p_actor => 'KMENSAH');
    pkg_approval_engine.submit(l_tr, p_actor => 'KMENSAH');
    ok('T17 a document with no rule is refused', false, 'no error raised');
  exception
    when others then
      eqn('T17 no matching rule raises -20010', sqlcode, -20010);
  end;
  rollback to before_t17;

  --==========================================================================
  section('T18  Cumulative authority mode');
  --==========================================================================
  -- TRAVEL-STD accumulates limits instead of requiring one approver to cover the
  -- whole amount, and starts at level 1, so the zero-limit senior engineer is in.
  savepoint before_t18;
  declare
    l_tr  number(12);
    l_cum number;
  begin
    l_tr := pkg_approval_engine.create_request(
              p_doc_type => 'TRAVEL', p_title => 'T18 offsite', p_amount => 28000
            , p_actor => 'KMENSAH');
    pkg_approval_engine.submit(l_tr, p_actor => 'KMENSAH');

    select count(*) into l_n from approval_steps where request_id = l_tr;
    ok('T18 cumulative mode produced a chain', l_n >= 1, 'steps = ' || l_n);

    select count(*) into l_n
      from approval_steps s join employees e on e.employee_id = s.original_approver_id
     where s.request_id = l_tr and e.approval_limit = 0;
    ok('T18 a zero-limit manager is included when the rule starts at level 1', l_n >= 1);

    select sum(e.approval_limit) into l_cum
      from approval_steps s join employees e on e.employee_id = s.original_approver_id
     where s.request_id = l_tr;
    ok('T18 the accumulated authority covers the amount', l_cum >= 28000, 'cumulative = ' || l_cum);
  end;
  rollback to before_t18;

  --==========================================================================
  section('T19  Preview matches what submission would build');
  --==========================================================================
  declare
    l_draft number(12);
    l_prev  pls_integer;
  begin
    l_draft := pkg_approval_engine.create_request(
                 p_doc_type => 'PR', p_title => 'T19 preview', p_amount => 145000
               , p_actor => 'JWEBER');

    select count(*) into l_prev from table(pkg_approval_engine.preview_chain(l_draft));
    ok('T19 a draft can be previewed before submission', l_prev = 5, 'preview rows = ' || l_prev);

    pkg_approval_engine.submit(l_draft, p_actor => 'JWEBER');
    select count(*) into l_n from approval_steps where request_id = l_draft;
    eqn('T19 the built chain matches the preview', l_n, l_prev);
  end;

  --==========================================================================
  section('T20  Inbox and SLA arithmetic');
  --==========================================================================
  select count(*) into l_n from table(pkg_approval_engine.get_pending_for_user('DOFORI'));
  ok('T20 the escalated step reaches the new approver''s inbox', l_n >= 1, 'rows = ' || l_n);

  eqn('T20 pending_count agrees with the pipelined inbox'
    , pkg_approval_engine.pending_count('DOFORI'), l_n);

  -- Friday 10:00 plus 24 working hours must not land on a weekend.
  l_due := pkg_approval_engine.sla_due(timestamp '2026-08-07 10:00:00', 24);
  ok('T20 SLA due dates skip the weekend'
   , trunc(cast(l_due as date)) - trunc(cast(l_due as date),'IW') < 5
   , to_char(l_due,'YYYY-MM-DD DY'));

  -- 24 hours from 24 December must clear both public holidays.
  l_due := pkg_approval_engine.sla_due(timestamp '2026-12-24 09:00:00', 24);
  ok('T20 SLA due dates skip configured holidays'
   , trunc(cast(l_due as date)) not in (date '2026-12-25', date '2026-12-26')
   , to_char(l_due,'YYYY-MM-DD DY'));

  --==========================================================================
  section('T21  Withdraw is terminal');
  --==========================================================================
  savepoint before_t21;
  declare
    l_w number(12);
  begin
    l_w := pkg_approval_engine.create_request(
             p_doc_type => 'PR', p_title => 'T21 abandoned', p_amount => 480
           , p_actor => 'KMENSAH');
    pkg_approval_engine.submit(l_w, p_actor => 'KMENSAH');
    pkg_approval_engine.withdraw(l_w, 'KMENSAH', 'No longer needed.');
    eqs('T21 request is withdrawn', req_status(l_w), 'WITHDRAWN');

    begin
      pkg_approval_engine.submit(l_w, p_actor => 'KMENSAH');
      ok('T21 a withdrawn request cannot be resubmitted', false, 'no error raised');
    exception
      when others then
        eqn('T21 resubmitting a withdrawn request raises -20002', sqlcode, -20002);
    end;
  end;
  rollback to before_t21;

  --==========================================================================
  section('T23  Delegations that would quietly break routing are rejected');
  --==========================================================================
  savepoint before_t23;
  begin
    -- Chen Wei is inactive: cover that is not really in place.
    insert into approval_delegations (delegator_id, delegate_id, valid_from, valid_to, reason)
    values (9, 11, trunc(sysdate), trunc(sysdate) + 7, 'T23 inactive proxy');
    ok('T23 a delegation to an inactive employee is rejected', false, 'insert succeeded');
  exception
    when others then
      eqn('T23 an inactive proxy raises -20015', sqlcode, -20015);
  end;
  rollback to before_t23;

  begin
    -- Grace already delegates to Elena; Elena delegating back closes the loop.
    insert into approval_delegations (delegator_id, delegate_id, valid_from, valid_to, reason)
    values (4, 7, trunc(sysdate), trunc(sysdate) + 7, 'T23 loop');
    ok('T23 a delegation loop is rejected', false, 'insert succeeded');
  exception
    when others then
      eqn('T23 a delegation loop raises -20015', sqlcode, -20015);
  end;
  rollback to before_t23;

  --==========================================================================
  section('T22  Everything was audited');
  --==========================================================================
  select count(*) into l_n
    from approval_audit where request_id = l_req_5lvl and action_code = 'SUBMIT';
  ok('T22 submission is in the audit log', l_n >= 1);

  select count(*) into l_n
    from approval_audit where request_id = l_req_par and action_code = 'APPROVE';
  ok('T22 approvals are in the audit log', l_n >= 5, 'approve rows = ' || l_n);

  select count(*) into l_n
    from approval_audit where outcome = 'ERROR' and action_code in ('APPROVE','SUBMIT','REJECT');
  ok('T22 refused attempts are in the audit log too', l_n >= 1, 'error rows = ' || l_n);

  eqn('T22 the guard depth returned to zero', pkg_approval_guard.engine_depth, 0);

  --==========================================================================
  dbms_output.put_line(chr(10) || '================================================');
  dbms_output.put_line('  passed: ' || l_pass || '    failed: ' || l_fail);
  dbms_output.put_line('================================================');

  rollback;

  if l_fail > 0 then
    raise_application_error(-20900, l_fail || ' approval-engine regression assertion(s) failed.');
  end if;
end;
/

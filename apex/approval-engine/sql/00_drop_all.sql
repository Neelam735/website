--------------------------------------------------------------------------------
-- 00_drop_all.sql
--
-- Tears the engine down so install.sql can be re-run. Destructive: it drops the
-- audit log too. Do not point this at anything you would miss.
--
-- Ordering matters (children before parents, and the VPD policy before the
-- function it names). Errors are swallowed per object so a partial install can
-- still be cleaned up.
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited

declare
  procedure try (p_sql in varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('  dropped: ' || p_sql);
  exception
    when others then
      -- -942 table/view, -4043 object, -2289 sequence, -28102 policy, -4080 trigger
      if sqlcode in (-942, -4043, -2289, -28102, -4080) then
        null;
      else
        dbms_output.put_line('  SKIPPED: ' || p_sql || ' -> ' || sqlerrm);
      end if;
  end try;
begin
  -- VPD first: the policy pins the predicate function.
  begin
    dbms_rls.drop_policy(sys_context('userenv','current_schema'), 'APPROVAL_REQUESTS', 'APPROVAL_REQ_READ');
  exception
    when others then null;
  end;

  try('drop package pkg_approval_engine');
  try('drop package pkg_approval_guard');
  try('drop package approval_ctx_pkg');
  try('drop function fn_approval_req_predicate');
  try('drop context apex$approval');

  try('drop view v_my_pending_approvals');
  try('drop view v_approval_timeline');
  try('drop view v_approval_chain');
  try('drop view v_approval_requests');
  try('drop view v_approval_rule_overlaps');
  try('drop view v_hierarchy_health');
  try('drop view v_active_delegations');

  try('drop table approval_notifications purge');
  try('drop table approval_audit         purge');
  try('drop table approval_steps         purge');
  try('drop table approval_requests      purge');
  try('drop table approval_rule_steps    purge');
  try('drop table approval_rules         purge');
  try('drop table approval_delegations   purge');
  try('drop table employee_roles         purge');
  try('drop table employees              purge');
  try('drop table cost_centers           purge');
  try('drop table departments            purge');
  try('drop table approval_doc_types     purge');
  try('drop table approval_roles         purge');
  try('drop table approval_holidays      purge');

  try('drop sequence seq_approval_ref');

  try('drop type approval_chain_nt   force');
  try('drop type approval_chain_ot   force');
  try('drop type approval_pending_nt force');
  try('drop type approval_pending_ot force');

  dbms_output.put_line('Teardown complete.');
end;
/

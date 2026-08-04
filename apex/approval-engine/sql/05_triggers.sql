--------------------------------------------------------------------------------
-- 05_triggers.sql
--
-- Integrity triggers. These are the enforcement half of "no direct status
-- updates outside the package" - grants alone cannot express it, because in
-- APEX the parsing schema IS the owner of these tables and therefore has
-- implicit full DML on them.
--
-- What is allowed without the engine:
--   APPROVAL_REQUESTS  insert of a DRAFT row, and edits to a DRAFT row's own
--                      attributes (so an ordinary APEX form can create drafts).
--                      Status, current_group, rule_id and row_version are
--                      engine-only at all times.
--   APPROVAL_STEPS     nothing.
--   APPROVAL_AUDIT     insert only, by anyone; update and delete by nobody.
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- APPROVAL_REQUESTS
--------------------------------------------------------------------------------
create or replace trigger trg_approval_requests_biu
  before insert or update or delete on approval_requests
  for each row
declare
  procedure deny(p_what in varchar2) is
  begin
    raise_application_error(
      pkg_approval_guard.gc_err_tamper,
      'APPROVAL_REQUESTS: ' || p_what || ' is only permitted through PKG_APPROVAL_ENGINE.');
  end deny;
begin
  if not pkg_approval_guard.in_engine then
    if inserting then
      -- A form may create a draft; it may not conjure a request mid-flight.
      if :new.status <> 'DRAFT' then
        deny('creating a request with status ' || :new.status);
      end if;
    elsif deleting then
      deny('deleting a request');
    else
      -- DRAFT and RECALLED are both "on the requester's desk", so an ordinary
      -- form may edit them. Anything else is in flight and off limits.
      if :old.status not in ('DRAFT','RECALLED') then
        deny('modifying a request once it is in flight');
      end if;
      if nvl(:new.status,'~')        <> nvl(:old.status,'~')
      or nvl(:new.current_group,-1)  <> nvl(:old.current_group,-1)
      or nvl(:new.rule_id,-1)        <> nvl(:old.rule_id,-1)
      or nvl(:new.submitted_on, timestamp '1900-01-01 00:00:00')
         <> nvl(:old.submitted_on, timestamp '1900-01-01 00:00:00')
      or nvl(:new.completed_on, timestamp '1900-01-01 00:00:00')
         <> nvl(:old.completed_on, timestamp '1900-01-01 00:00:00')
      or nvl(:new.row_version,-1)    <> nvl(:old.row_version,-1)
      or nvl(:new.recall_count,-1)   <> nvl(:old.recall_count,-1) then
        deny('changing an engine-managed column');
      end if;
    end if;
  end if;

  if inserting or updating then
    :new.updated_by := nvl(sys_context('APEX$SESSION','APP_USER')
                          ,sys_context('userenv','session_user'));
    :new.updated_on := systimestamp;
  end if;
end;
/

--------------------------------------------------------------------------------
-- APPROVAL_STEPS - engine only, no exceptions.
--------------------------------------------------------------------------------
create or replace trigger trg_approval_steps_biud
  before insert or update or delete on approval_steps
  for each row
begin
  if not pkg_approval_guard.in_engine then
    raise_application_error(
      pkg_approval_guard.gc_err_tamper,
      'APPROVAL_STEPS is maintained exclusively by PKG_APPROVAL_ENGINE. '
      || 'Use APPROVE/REJECT/REASSIGN/ESCALATE rather than updating the row.');
  end if;
end;
/

--------------------------------------------------------------------------------
-- APPROVAL_AUDIT - append only. Applies to the engine too: the log is evidence,
-- and evidence you can edit is not evidence.
--------------------------------------------------------------------------------
create or replace trigger trg_approval_audit_bud
  before update or delete on approval_audit
begin
  raise_application_error(
    pkg_approval_guard.gc_err_tamper,
    'APPROVAL_AUDIT is append-only. Rows cannot be updated or deleted.');
end;
/

--------------------------------------------------------------------------------
-- Rule sanity that a CHECK constraint cannot express (it spans rows).
-- Two active rules with the same doc type, scope, overlapping band AND the same
-- priority make routing non-deterministic. Refuse the row rather than let a
-- coin-flip decide who approves a purchase.
--------------------------------------------------------------------------------
create or replace trigger trg_approval_rules_aiu
  after insert or update on approval_rules
declare
  l_dummy pls_integer;
begin
  begin
    select 1 into l_dummy
      from v_approval_rule_overlaps
     where verdict = 'AMBIGUOUS'
       and rownum = 1;

    raise_application_error(
      -20030,
      'Ambiguous rule set: two active rules share a document type, scope, amount band '
      || 'and priority. Query V_APPROVAL_RULE_OVERLAPS to see the pair.');
  exception
    when no_data_found then
      null;
  end;
end;
/

--------------------------------------------------------------------------------
-- Delegations that look valid but quietly break routing.
--
-- Raises -20015, which PKG_APPROVAL_ENGINE publishes as GC_ERR_BAD_DELEGATION.
-- The literal is used rather than the constant because triggers install before
-- the package spec; tests/test_sql_structure.py asserts the two stay in step.
--------------------------------------------------------------------------------
create or replace trigger trg_approval_delegations_aiu
  after insert or update on approval_delegations
declare
  l_bad pls_integer;
begin
  -- Delegating to someone inactive does not stall a chain, it silently removes
  -- an approver from it: RESOLVE_DELEGATE skips inactive delegates, so the
  -- delegator keeps the step and nobody learns the cover was never in place.
  select count(*)
    into l_bad
    from approval_delegations d
    join employees e on e.employee_id = d.delegate_id
   where d.active_flag = 'Y'
     and e.active_flag = 'N'
     and trunc(sysdate) between d.valid_from and d.valid_to;

  if l_bad > 0 then
    raise_application_error(
      -20015,
      'That delegation names an inactive employee as the proxy. '
      || 'Deactivate the delegation or pick an active delegate.');
  end if;

  -- A delegates to B, B delegates back to A. RESOLVE_DELEGATE tolerates it (it
  -- stops on the loop and keeps the last valid actor) but the result is not what
  -- either party intended, so refuse to store it.
  select count(*)
    into l_bad
    from (
          select connect_by_iscycle as is_cycle
            from v_active_delegations
          connect by nocycle prior delegate_id = delegator_id
         )
   where is_cycle = 1;

  if l_bad > 0 then
    raise_application_error(
      -20015,
      'That delegation creates a loop (A covers for B while B covers for A). '
      || 'Query V_ACTIVE_DELEGATIONS to see the arrangements in force.');
  end if;
end;
/

--------------------------------------------------------------------------------
-- Keep EMPLOYEES honest: no self-management, no cycle introduced by an org
-- change. The self case is a CHECK constraint; a longer cycle needs a query.
--------------------------------------------------------------------------------
create or replace trigger trg_employees_aiu
  after insert or update of manager_id on employees
declare
  l_cycles pls_integer;
begin
  select count(*)
    into l_cycles
    from v_hierarchy_health
   where finding = 'CYCLE'
     and rownum = 1;

  if l_cycles > 0 then
    raise_application_error(
      -20031,
      'That reporting change creates a cycle in the management hierarchy. '
      || 'Query V_HIERARCHY_HEALTH for the employees involved.');
  end if;
end;
/

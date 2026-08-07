--------------------------------------------------------------------------------
-- 08_vpd_optional.sql
--
-- OPTIONAL. Row-level security for APPROVAL_REQUESTS via VPD (DBMS_RLS is fully
-- available on ATP). Not installed by INSTALL.SQL by default - read
-- docs/04-security.md before you turn it on, because it changes the behaviour of
-- every query in the application, including ones you did not write.
--
-- When to bother:
--   * You expose the schema over ORDS/REST, or share it with reporting tools.
--     Then APEX authorisation schemes are not the only door and VPD is worth it.
--   * You do not, and every path in is an APEX page. Then the authorisation
--     schemes in docs/02-apex-build.md give the same protection for far less
--     operational surprise.
--
-- Two things people get wrong:
--   1. The table owner IS subject to its own VPD policy. In APEX that owner is
--      the parsing schema, so switching this on immediately filters every page.
--   2. The engine itself must see all rows. It runs as the owner, so it would be
--      filtered too. That is why the predicate opens up for the engine session
--      via PKG_APPROVAL_GUARD.
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- The predicate reads a namespace rather than calling a PL/SQL function per row.
-- A context set by a trusted package is the only way to make that both fast and
-- unspoofable: only APPROVAL_CTX_PKG can write to it.
--------------------------------------------------------------------------------
create or replace package approval_ctx_pkg authid definer as
  -- Call once per APEX session, from the application's Initialization PL/SQL
  -- Code (Security Attributes -> Database Session).
  procedure set_context;
  procedure clear_context;
end approval_ctx_pkg;
/

create or replace package body approval_ctx_pkg as

  procedure set_context is
  begin
    dbms_session.set_context('APEX$APPROVAL', 'APP_USER', pkg_approval_engine.current_username);
  end set_context;

  procedure clear_context is
  begin
    dbms_session.clear_context('APEX$APPROVAL', null, 'APP_USER');
  end clear_context;

end approval_ctx_pkg;
/

-- Named after the package so only that package may write the namespace.
-- No trailing slash: CREATE CONTEXT is DDL and the semicolon already ran it.
create or replace context apex$approval using approval_ctx_pkg;

create or replace function fn_approval_req_predicate (
    p_schema in varchar2
  , p_object in varchar2) return varchar2 is
  l_user varchar2(100) := pkg_approval_engine.current_username;
begin
  -- Inside an engine call the row set must not be filtered, or BUILD_CHAIN and
  -- ADVANCE would operate on a partial view of their own request.
  if pkg_approval_guard.in_engine then
    return null;
  end if;

  if pkg_approval_engine.is_admin(l_user) = 'Y' then
    return null;
  end if;

  -- Requester, or anyone who is (or was) on the chain. Written as EXISTS on
  -- indexed columns so the predicate stays cheap when merged into user queries.
  return q'[
      requester_id in (select employee_id from employees
                        where apex_username = sys_context('APEX$APPROVAL','APP_USER'))
   or exists (select 1 from approval_steps s
               where s.request_id = approval_requests.request_id
                 and (s.original_approver_id in (select employee_id from employees
                                                  where apex_username = sys_context('APEX$APPROVAL','APP_USER'))
                   or s.acting_approver_id   in (select employee_id from employees
                                                  where apex_username = sys_context('APEX$APPROVAL','APP_USER'))))
  ]';
end fn_approval_req_predicate;
/

--------------------------------------------------------------------------------
-- Attach the policy. CONTEXT_SENSITIVE (not STATIC) because the predicate
-- changes with the session user; not DYNAMIC because it only needs re-evaluating
-- when the context changes, which keeps the cursor cache useful.
--------------------------------------------------------------------------------
begin
  dbms_rls.add_policy(
      object_schema   => sys_context('userenv','current_schema')
    , object_name     => 'APPROVAL_REQUESTS'
    , policy_name     => 'APPROVAL_REQ_READ'
    , function_schema => sys_context('userenv','current_schema')
    , policy_function => 'FN_APPROVAL_REQ_PREDICATE'
    , statement_types => 'SELECT'
    , policy_type     => dbms_rls.context_sensitive
    , update_check    => false);
exception
  when others then
    if sqlcode = -28101 then      -- policy already exists
      null;
    else
      raise;
    end if;
end;
/

--------------------------------------------------------------------------------
-- To remove:
--   begin
--     dbms_rls.drop_policy(sys_context('userenv','current_schema'),
--                          'APPROVAL_REQUESTS', 'APPROVAL_REQ_READ');
--   end;
--   /
--------------------------------------------------------------------------------

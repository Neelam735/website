--------------------------------------------------------------------------------
-- 04_pkg_approval_guard.sql
--
-- A deliberately tiny package holding one piece of session state: "am I inside
-- the approval engine right now?". The tamper triggers in 05_triggers.sql ask it
-- before allowing DML on the runtime tables.
--
-- It is separate from PKG_APPROVAL_ENGINE on purpose:
--   * triggers depend on the guard, the engine depends on the triggers' tables.
--     Splitting them keeps the dependency graph acyclic, so recompiling the
--     engine never invalidates the triggers.
--   * the guard has no business logic to review. Its whole surface is three
--     calls, which is what makes "only the engine writes" auditable.
--
-- Package state is per-session and disappears on session end, so a leaked
-- ENTER_ENGINE cannot outlive the connection. ENGINE_DEPTH is still exposed so a
-- leak is diagnosable rather than mysterious.
--------------------------------------------------------------------------------
set define off

create or replace package pkg_approval_guard authid definer as

  -- Raised by the triggers when someone writes to a runtime table directly.
  gc_err_tamper constant pls_integer := -20099;

  procedure enter_engine;

  procedure leave_engine;

  -- Called from triggers. TRUE only while an engine entry point is on the stack.
  function in_engine return boolean;

  -- Diagnostics: non-zero outside an engine call means a procedure exited
  -- without LEAVE_ENGINE (its exception handler is missing the call).
  function engine_depth return pls_integer;

  -- Emergency valve for data migrations. Requires the caller to already hold a
  -- privileged role; see docs/04-security.md before granting it.
  procedure force_reset;

end pkg_approval_guard;
/

create or replace package body pkg_approval_guard as

  g_depth pls_integer := 0;

  procedure enter_engine is
  begin
    g_depth := g_depth + 1;
  end enter_engine;

  procedure leave_engine is
  begin
    if g_depth > 0 then
      g_depth := g_depth - 1;
    end if;
  end leave_engine;

  function in_engine return boolean is
  begin
    return g_depth > 0;
  end in_engine;

  function engine_depth return pls_integer is
  begin
    return g_depth;
  end engine_depth;

  procedure force_reset is
  begin
    g_depth := 0;
  end force_reset;

end pkg_approval_guard;
/

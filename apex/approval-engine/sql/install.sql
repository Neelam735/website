--------------------------------------------------------------------------------
-- install.sql
--
-- Installs the approval engine into the current schema, in dependency order.
-- Run from this directory as the APEX parsing schema (<APP_SCHEMA>):
--
--   sqlcl> connect <APP_SCHEMA>/<pw>@<tns_alias>_tp
--   sqlcl> @install.sql
--
-- On ATP the connection needs the instance wallet unless you are using a
-- one-way-TLS enabled database; see docs/03-atp-notes.md.
--
-- APEX SQL Workshop cannot follow @@ includes. There, run the numbered files
-- individually in the order listed below.
--
-- Re-running: drop first with @00_drop_all.sql. The scripts do not use
-- CREATE ... IF NOT EXISTS, because that is 23ai-only and this must install on
-- 19c as well.
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

prompt
prompt ============================================================
prompt  Approval engine install
prompt ============================================================

prompt
prompt [1/8] Object types ..........................................
@@01_types.sql

prompt [2/8] Tables, constraints, indexes ..........................
@@02_tables.sql

prompt [3/8] Views .................................................
@@03_views.sql

prompt [4/8] Guard package .........................................
@@04_pkg_approval_guard.sql

prompt [5/8] Integrity triggers ....................................
@@05_triggers.sql

prompt [6/8] Engine package specification ..........................
@@06_pkg_approval_engine.pks

prompt [7/8] Engine package body ...................................
@@07_pkg_approval_engine.pkb

prompt [8/8] Reference and seed data ...............................
@@09_seed.sql

--------------------------------------------------------------------------------
-- Optional: row-level security. Read docs/04-security.md first - it changes the
-- behaviour of every query against APPROVAL_REQUESTS, including APEX's.
--------------------------------------------------------------------------------
-- @@08_vpd_optional.sql

--------------------------------------------------------------------------------
-- Verify. Anything INVALID here means the install did not complete, and the
-- APEX pages built on it will fail at runtime rather than at build time.
--------------------------------------------------------------------------------
whenever sqlerror continue

prompt
prompt ============================================================
prompt  Verification
prompt ============================================================

column object_name format a34
column object_type format a14
column status      format a8

select object_name, object_type, status
  from user_objects
 where object_name in ('PKG_APPROVAL_ENGINE','PKG_APPROVAL_GUARD'
                      ,'APPROVAL_CHAIN_OT','APPROVAL_CHAIN_NT'
                      ,'APPROVAL_PENDING_OT','APPROVAL_PENDING_NT')
    or object_name like 'V\_%' escape '\'
    or object_name like 'APPROVAL\_%' escape '\'
 order by decode(status,'INVALID',0,1), object_type, object_name;

prompt
prompt -- Rule sanity (should be empty):
select rule_code_a, rule_code_b, verdict from v_approval_rule_overlaps where verdict = 'AMBIGUOUS';

prompt
prompt -- Hierarchy findings (ORPHAN/NO_LIMIT_SET are expected in the seed data):
select finding, count(*) as employees from v_hierarchy_health group by finding order by 1;

prompt
prompt -- Seeded demo traffic:
select request_ref, status, amount, waiting_on from v_approval_requests order by request_id;

prompt
prompt Install complete. Next: @90_regression.sql to prove the engine behaves,
prompt then docs/02-apex-build.md to build the pages.
prompt

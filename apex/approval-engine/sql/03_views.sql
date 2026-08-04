--------------------------------------------------------------------------------
-- 03_views.sql
--
-- Reporting views. Every APEX region that only READS should use one of these
-- rather than embedding joins in the page - the page then survives a schema
-- change, and the predicates stay indexable.
--
-- These views reference tables only (no pipelined functions), so they install
-- before the packages and can be re-created independently.
--------------------------------------------------------------------------------
set define off

--------------------------------------------------------------------------------
-- Currently effective delegations, one row per (delegator, doc_type) winner.
-- Overlapping delegations are legal; the most specific doc_type wins, then the
-- most recently created row.
--------------------------------------------------------------------------------
create or replace view v_active_delegations as
select delegation_id
     , delegator_id
     , delegate_id
     , doc_type
     , valid_from
     , valid_to
     , max_amount
     , reason
  from (
        select d.*
             , row_number() over (
                 partition by d.delegator_id, nvl(d.doc_type,'*')
                 order by case when d.doc_type is null then 1 else 0 end
                        , d.created_on desc
                        , d.delegation_id desc) as rn
          from approval_delegations d
         where d.active_flag = 'Y'
           and trunc(sysdate) between d.valid_from and d.valid_to
       )
 where rn = 1;

comment on table v_active_delegations is 'Delegations in force today, de-duplicated to one winner per delegator/doc type.';


--------------------------------------------------------------------------------
-- The materialised chain for a request, denormalised for the timeline region.
--------------------------------------------------------------------------------
create or replace view v_approval_chain as
select s.step_id
     , s.request_id
     , r.request_ref
     , r.doc_type
     , r.status                as request_status
     , s.step_seq
     , s.group_no
     , s.step_mode
     , s.source_code
     , s.status                as step_status
     , s.original_approver_id
     , eo.full_name            as original_approver_name
     , eo.job_title            as original_approver_title
     , eo.job_level
     , eo.approval_limit
     , s.acting_approver_id
     , ea.full_name            as acting_approver_name
     , ea.apex_username        as acting_approver_username
     , ea.email                as acting_approver_email
     , s.delegation_id
     , case when s.delegation_id is not null then 'Y' else 'N' end as is_delegated_yn
     , s.activated_on
     , s.sla_due_on
     , s.action_on
     , s.action_by_username
     , s.comments
     , s.escalation_count
     , case
         when s.status in ('APPROVED','REJECTED','SKIPPED','CANCELLED','REASSIGNED') then 'DONE'
         when s.status = 'ACTIVE' and s.sla_due_on < systimestamp                    then 'OVERDUE'
         when s.status = 'ACTIVE'                                                    then 'CURRENT'
         else 'WAITING'
       end as lane
  from approval_steps s
  join approval_requests r on r.request_id = s.request_id
  join employees eo on eo.employee_id = s.original_approver_id
  join employees ea on ea.employee_id = s.acting_approver_id;


--------------------------------------------------------------------------------
-- Request header with requester / rule / progress, for IRs and cards.
--------------------------------------------------------------------------------
create or replace view v_approval_requests as
select r.request_id
     , r.request_ref
     , r.doc_type
     , dt.doc_type_name
     , r.doc_id
     , r.doc_ref
     , r.title
     , r.amount
     , r.currency_code
     , r.priority_code
     , r.status
     , r.requester_id
     , er.full_name      as requester_name
     , er.apex_username  as requester_username
     , er.email          as requester_email
     , r.dept_id
     , dp.dept_name
     , r.cost_center
     , r.rule_id
     , ru.rule_code
     , ru.rule_name
     , r.current_group
     , r.submitted_on
     , r.completed_on
     , r.recall_count
     , r.row_version
     , (select count(*) from approval_steps s
         where s.request_id = r.request_id
           and s.status not in ('CANCELLED','SKIPPED'))                as total_steps
     , (select count(*) from approval_steps s
         where s.request_id = r.request_id and s.status = 'APPROVED')   as approved_steps
     , (select listagg(e.full_name, ', ') within group (order by s.step_seq)
          from approval_steps s join employees e on e.employee_id = s.acting_approver_id
         where s.request_id = r.request_id and s.status = 'ACTIVE')     as waiting_on
     , (select min(s.sla_due_on) from approval_steps s
         where s.request_id = r.request_id and s.status = 'ACTIVE')     as next_sla_due_on
  from approval_requests r
  join employees          er on er.employee_id = r.requester_id
  join approval_doc_types dt on dt.doc_type    = r.doc_type
  left join departments   dp on dp.dept_id     = r.dept_id
  left join approval_rules ru on ru.rule_id    = r.rule_id;


--------------------------------------------------------------------------------
-- The approver inbox. Source for the "My Pending Approvals" Interactive Report.
--
-- Two ways to be assigned: the step is directly yours, or it belongs to someone
-- whose delegate you currently are and the engine has not yet re-pointed it
-- (activation re-resolves delegation, but a delegation created mid-step should
-- still surface immediately).
--------------------------------------------------------------------------------
create or replace view v_my_pending_approvals as
select c.step_id
     , c.request_id
     , c.request_ref
     , c.doc_type
     , vr.doc_type_name
     , vr.doc_ref
     , vr.title
     , vr.amount
     , vr.currency_code
     , vr.priority_code
     , vr.requester_name
     , vr.requester_username
     , vr.dept_name
     , vr.cost_center
     , vr.submitted_on
     , c.step_seq
     , c.group_no
     , c.step_mode
     , c.activated_on
     , c.sla_due_on
     , round((cast(c.sla_due_on as date) - sysdate) * 24, 1) as hours_remaining
     , case
         when c.sla_due_on is null                                              then 'OK'
         when c.sla_due_on <  systimestamp                                      then 'OVERDUE'
         when c.sla_due_on <  systimestamp + numtodsinterval(4,'hour')          then 'DUE_SOON'
         else 'OK'
       end as sla_state
     , c.escalation_count
     , c.original_approver_name
     , case when c.acting_approver_id <> c.original_approver_id
            then c.original_approver_name end as acting_for_name
     , upper(nvl(sys_context('APEX$SESSION','APP_USER')
                ,sys_context('userenv','session_user'))) as inbox_username
  from v_approval_chain c
  join v_approval_requests vr on vr.request_id = c.request_id
 where c.step_status = 'ACTIVE'
   and (
        c.acting_approver_username = upper(nvl(sys_context('APEX$SESSION','APP_USER')
                                              ,sys_context('userenv','session_user')))
     or exists (
          select 1
            from v_active_delegations d
            join employees ed on ed.employee_id = d.delegate_id
           where d.delegator_id = c.acting_approver_id
             and (d.doc_type is null or d.doc_type = c.doc_type)
             and (d.max_amount is null or d.max_amount >= vr.amount)
             and ed.active_flag = 'Y'
             and ed.apex_username = upper(nvl(sys_context('APEX$SESSION','APP_USER')
                                             ,sys_context('userenv','session_user')))
        )
       );

comment on table v_my_pending_approvals is 'Self-filtering inbox: no bind variable needed, so it is safe as an IR source and cannot leak another approver''s queue.';


--------------------------------------------------------------------------------
-- Unified timeline: chain events and audit events in one stream, for the
-- request detail page. Audit rows carry actions that never produce a step
-- (submit, recall, withdraw, rule evaluation).
--------------------------------------------------------------------------------
create or replace view v_approval_timeline as
select a.request_id
     , a.action_ts                       as event_ts
     , a.action_code                     as event_code
     , a.outcome
     , a.actor_username
     , nvl(e.full_name, a.actor_username) as actor_name
     , a.from_status
     , a.to_status
     , a.comments
     , a.step_id
     , case a.outcome
         when 'ERROR' then 'fa-exclamation-triangle u-danger-text'
         when 'WARN'  then 'fa-exclamation-circle u-warning-text'
         else case a.action_code
                when 'APPROVE'  then 'fa-check-circle u-success-text'
                when 'REJECT'   then 'fa-times-circle u-danger-text'
                when 'SUBMIT'   then 'fa-paper-plane'
                when 'ESCALATE' then 'fa-arrow-up u-warning-text'
                when 'REASSIGN' then 'fa-exchange'
                when 'RECALL'   then 'fa-undo'
                else 'fa-circle-o'
              end
       end as icon_class
  from approval_audit a
  left join employees e on e.employee_id = a.actor_employee_id;


--------------------------------------------------------------------------------
-- Admin diagnostics: rule bands that overlap for the same scope. Overlaps are
-- resolved by PRIORITY, so they are legal - but an unintended one is the most
-- common routing bug, and it is invisible without this.
--------------------------------------------------------------------------------
create or replace view v_approval_rule_overlaps as
select a.rule_id       as rule_id_a
     , a.rule_code     as rule_code_a
     , b.rule_id       as rule_id_b
     , b.rule_code     as rule_code_b
     , a.doc_type
     , a.dept_id
     , a.cost_center
     , greatest(a.min_amount, b.min_amount)                          as overlap_from
     , least(nvl(a.max_amount, 9999999999999), nvl(b.max_amount, 9999999999999)) as overlap_to
     , case when a.priority = b.priority then 'AMBIGUOUS' else 'RESOLVED_BY_PRIORITY' end as verdict
  from approval_rules a
  join approval_rules b
    on b.doc_type = a.doc_type
   and b.rule_id  > a.rule_id
   and nvl(b.dept_id, -1)     = nvl(a.dept_id, -1)
   and nvl(b.cost_center,'*') = nvl(a.cost_center,'*')
   and a.min_amount < nvl(b.max_amount, 9999999999999)
   and b.min_amount < nvl(a.max_amount, 9999999999999)
   and a.valid_from <= nvl(b.valid_to, date '9999-12-31')
   and b.valid_from <= nvl(a.valid_to, date '9999-12-31')
 where a.active_flag = 'Y'
   and b.active_flag = 'Y';


--------------------------------------------------------------------------------
-- Admin diagnostics: hierarchy defects that will break routing at submit time.
-- Run this after every org-chart load.
--------------------------------------------------------------------------------
create or replace view v_hierarchy_health as
select e.employee_id
     , e.employee_no
     , e.full_name
     , e.job_level
     , e.active_flag
     -- CYCLE is tested FIRST and deliberately so: a cycle usually also looks
     -- like an inverted level, and TRG_EMPLOYEES_AIU keys off this column. If a
     -- cosmetic finding shadowed it, the trigger would let a loop through.
     , case
         when exists (select 1 from employees c
                       where c.employee_id = e.employee_id
                       start with c.employee_id = e.manager_id
                     connect by nocycle prior c.manager_id = c.employee_id)
                                                                    then 'CYCLE'
         when e.manager_id is null and e.job_level < 10             then 'ORPHAN'
         when m.employee_id is not null and m.active_flag = 'N'     then 'INACTIVE_MANAGER'
         when m.job_level is not null and m.job_level < e.job_level then 'INVERTED_LEVEL'
         when e.approval_limit = 0 and e.job_level >= 3             then 'NO_LIMIT_SET'
         else 'OK'
       end as finding
     , m.full_name as manager_name
  from employees e
  left join employees m on m.employee_id = e.manager_id;

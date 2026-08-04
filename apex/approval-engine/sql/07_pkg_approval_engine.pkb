--------------------------------------------------------------------------------
-- 07_pkg_approval_engine.pkb
--------------------------------------------------------------------------------
set define off

create or replace package body pkg_approval_engine as

  gc_version               constant varchar2(20) := '1.0.0';
  gc_max_delegation_hops   constant pls_integer  := 5;
  gc_max_holiday_shifts    constant pls_integer  := 21;
  gc_admin_role            constant varchar2(30) := 'APPROVAL_ADMIN';

  -- Diagnostics from the most recent RESOLVE_CHAIN call in this session.
  -- BUILD_CHAIN reads them to decide whether to refuse or merely warn. Session
  -- scoped and reset on every resolve, so they cannot bleed across requests.
  g_last_covered  boolean := false;
  g_last_warning  varchar2(400);
  g_last_rule_id  number(9);

  type t_flags is table of boolean      index by pls_integer;
  type t_keys  is table of varchar2(60) index by pls_integer;

  --============================================================================
  -- Identity helpers
  --============================================================================

  function current_username return varchar2 is
  begin
    -- APEX$SESSION is populated inside an APEX session (page process, Automation,
    -- REST handler running under an APEX context). Outside one - SQLcl, a
    -- scheduler job, the regression pack - fall back to the database user.
    return upper(nvl(sys_context('APEX$SESSION','APP_USER')
                    ,sys_context('userenv','session_user')));
  end current_username;


  function actor_or_current (p_actor in varchar2) return varchar2 is
  begin
    return upper(nvl(p_actor, current_username));
  end actor_or_current;


  function employee_id_for (p_username in varchar2) return number is
    l_id number(9);
  begin
    select employee_id
      into l_id
      from employees
     where apex_username = upper(p_username);
    return l_id;
  exception
    when no_data_found then
      raise_application_error(
        gc_err_not_found,
        'No employee record is mapped to user "' || p_username || '". '
        || 'Add a row to EMPLOYEES with APEX_USERNAME = ' || upper(p_username) || '.');
  end employee_id_for;


  -- Soft variant: NULL rather than an error. Used where a missing mapping is a
  -- legitimate answer (e.g. an administrator who is not in the org chart).
  function employee_id_or_null (p_username in varchar2) return number is
    l_id number(9);
  begin
    select employee_id into l_id from employees where apex_username = upper(p_username);
    return l_id;
  exception
    when no_data_found then
      return null;
  end employee_id_or_null;


  function version return varchar2 is
  begin
    return gc_version;
  end version;


  --============================================================================
  -- SLA arithmetic
  --============================================================================

  function sla_due (p_from in timestamp, p_hours in number) return timestamp is
    l_due   timestamp := p_from + numtodsinterval(nvl(p_hours,24),'hour');
    l_dow   pls_integer;
    l_shift pls_integer := 0;
    l_hol   pls_integer;
  begin
    loop
      -- ISO-week arithmetic rather than TO_CHAR(d,'DY'): NLS-independent.
      -- 0 = Monday .. 5 = Saturday, 6 = Sunday.
      l_dow := trunc(cast(l_due as date)) - trunc(cast(l_due as date),'IW');

      select count(*)
        into l_hol
        from approval_holidays
       where holiday_date = trunc(cast(l_due as date));

      exit when l_dow < 5 and l_hol = 0;
      exit when l_shift >= gc_max_holiday_shifts;   -- refuse to loop forever

      l_due   := l_due + numtodsinterval(1,'day');
      l_shift := l_shift + 1;
    end loop;

    return l_due;
  end sla_due;


  --============================================================================
  -- Audit
  --
  -- Autonomous: an attempted-but-refused approval is exactly the row a security
  -- review wants, and it would be rolled back with the failed transaction if we
  -- logged inline. The trade-off is that a SUCCESS row can outlive a business
  -- transaction the caller later rolls back - hence TO_STATUS records intent.
  -- See docs/06-design-notes.md.
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
                      , p_payload     in clob     default null) is
    pragma autonomous_transaction;
    l_actor    varchar2(100) := actor_or_current(p_actor);
    l_ref      varchar2(40);
    l_doc_type varchar2(30);
    l_emp_id   number(9);
  begin
    begin
      -- The parent transaction's row is invisible here, which is exactly why
      -- APPROVAL_AUDIT carries no foreign keys. NO_DATA_FOUND is normal for the
      -- very first log line of a brand-new request.
      select request_ref, doc_type
        into l_ref, l_doc_type
        from approval_requests
       where request_id = p_request_id;
    exception
      when no_data_found then
        null;
    end;

    l_emp_id := employee_id_or_null(l_actor);

    insert into approval_audit (
        request_id, step_id, request_ref, doc_type, action_code, outcome
      , from_status, to_status, actor_username, actor_employee_id
      , comments, error_code, error_msg, client_ip, apex_session_id, payload)
    values (
        p_request_id, p_step_id, l_ref, l_doc_type, upper(p_action_code), p_outcome
      , p_from_status, p_to_status, l_actor, l_emp_id
      , p_comments, p_error_code, substr(p_error_msg,1,4000)
      , sys_context('userenv','ip_address')
      , to_number(sys_context('APEX$SESSION','APP_SESSION') default null on conversion error)
      , p_payload);

    commit;
  exception
    when others then
      -- Logging must never be the reason an approval fails.
      rollback;
  end log_action;


  --============================================================================
  -- Notification outbox
  --============================================================================

  procedure enqueue_notify (p_request_id  in number
                          , p_notify_type in varchar2
                          , p_employee_id in number
                          , p_step_id     in number   default null
                          , p_template    in varchar2 default null
                          , p_message     in varchar2 default null) is
    l_email    varchar2(240);
    l_user     varchar2(100);
    l_payload  clob;
  begin
    select e.email, e.apex_username
      into l_email, l_user
      from employees e
     where e.employee_id = p_employee_id
       and e.active_flag = 'Y';

    select json_object(
             key 'requestId'   value r.request_id
           , key 'requestRef'  value r.request_ref
           , key 'docType'     value r.doc_type
           , key 'docRef'      value r.doc_ref
           , key 'title'       value r.title
           , key 'amount'      value to_char(r.amount,'FM999G999G990D00')
           , key 'currency'    value r.currency_code
           , key 'requester'   value er.full_name
           , key 'priority'    value r.priority_code
           , key 'stepId'      value p_step_id
           , key 'notifyType'  value p_notify_type
           , key 'message'     value p_message
           , key 'slaDue'      value to_char(s.sla_due_on,'YYYY-MM-DD"T"HH24:MI:SS')
             returning clob)
      into l_payload
      from approval_requests r
      join employees er on er.employee_id = r.requester_id
      left join approval_steps s on s.step_id = p_step_id
     where r.request_id = p_request_id;

    insert into approval_notifications (
        request_id, step_id, notify_type, recipient_email, recipient_username
      , template_static_id, placeholders)
    values (
        p_request_id, p_step_id, p_notify_type, l_email, l_user
      , nvl(p_template, 'APPROVAL_' || p_notify_type), l_payload);
  exception
    when no_data_found then
      -- Inactive or unmapped recipient: record it, do not derail the approval.
      log_action(p_request_id  => p_request_id
               , p_action_code => 'NOTIFY'
               , p_step_id     => p_step_id
               , p_outcome     => 'WARN'
               , p_comments    => 'No active recipient for employee ' || p_employee_id);
  end enqueue_notify;


  --============================================================================
  -- Locking
  --============================================================================

  procedure lock_request (p_request_id in number, p_req out approval_requests%rowtype) is
  begin
    select * into p_req from approval_requests where request_id = p_request_id for update wait 5;
  exception
    when no_data_found then
      raise_application_error(gc_err_not_found, 'Approval request ' || p_request_id || ' does not exist.');
    when others then
      if sqlcode in (-30006, -54) then
        raise_application_error(gc_err_locked,
          'Request ' || p_request_id || ' is being actioned by another user. Try again in a moment.');
      end if;
      raise;
  end lock_request;


  procedure lock_step (p_step_id in number, p_step out approval_steps%rowtype) is
  begin
    select * into p_step from approval_steps where step_id = p_step_id for update wait 5;
  exception
    when no_data_found then
      raise_application_error(gc_err_not_found, 'Approval step ' || p_step_id || ' does not exist.');
    when others then
      if sqlcode in (-30006, -54) then
        raise_application_error(gc_err_locked,
          'Step ' || p_step_id || ' is being actioned by another user. Try again in a moment.');
      end if;
      raise;
  end lock_step;


  --============================================================================
  -- Rule matching
  --============================================================================

  function get_rule (p_doc_type    in varchar2
                   , p_amount      in number
                   , p_dept_id     in number
                   , p_cost_center in varchar2
                   , p_ref_date    in date) return approval_rules%rowtype is
    l_rule approval_rules%rowtype;
  begin
    select *
      into l_rule
      from (
            select r.*
              from approval_rules r
             where r.doc_type    = p_doc_type
               and r.active_flag = 'Y'
               and p_ref_date between r.valid_from and nvl(r.valid_to, date '9999-12-31')
               and p_amount >= r.min_amount
               and (r.max_amount  is null or p_amount < r.max_amount)
               and (r.dept_id     is null or r.dept_id     = p_dept_id)
               and (r.cost_center is null or r.cost_center = p_cost_center)
             -- Priority first, then the most specific scope, then oldest rule.
             order by r.priority
                    , case when r.cost_center is not null then 0 else 1 end
                    , case when r.dept_id     is not null then 0 else 1 end
                    , r.rule_id
           )
     where rownum = 1;

    return l_rule;
  exception
    when no_data_found then
      raise_application_error(
        gc_err_no_rule,
        'No active approval rule matches document type "' || p_doc_type || '", amount '
        || to_char(p_amount,'FM999G999G990D00') || ', department ' || nvl(to_char(p_dept_id),'(any)')
        || ', cost centre ' || nvl(p_cost_center,'(any)') || ' on ' || to_char(p_ref_date,'YYYY-MM-DD')
        || '. Add or extend a row in APPROVAL_RULES.');
  end get_rule;


  --============================================================================
  -- Role and level resolution
  --============================================================================

  function role_holder (p_role_code in varchar2, p_dept_id in number) return number is
    l_id number(9);
  begin
    select employee_id
      into l_id
      from (
            select er.employee_id
              from employee_roles er
              join employees e on e.employee_id = er.employee_id
             where er.role_code   = p_role_code
               and er.active_flag = 'Y'
               and e.active_flag  = 'Y'
               and (er.dept_id is null or er.dept_id = p_dept_id)
             -- A department-scoped holder beats the global one.
             order by case when er.dept_id is not null then 0 else 1 end
                    , e.job_level desc
                    , e.employee_id
           )
     where rownum = 1;

    return l_id;
  exception
    when no_data_found then
      return null;
  end role_holder;


  -- Nearest ancestor of P_REQUESTER_ID at or above P_JOB_LEVEL.
  function level_holder (p_requester_id in number, p_job_level in number) return number is
    l_id number(9);
  begin
    select employee_id
      into l_id
      from (
            select e.employee_id, level as lvl
              from employees e
             where e.active_flag = 'Y'
               and e.job_level  >= p_job_level
             start with e.employee_id = (select manager_id from employees where employee_id = p_requester_id)
           connect by nocycle prior e.manager_id = e.employee_id
             order by lvl
           )
     where rownum = 1;

    return l_id;
  exception
    when no_data_found then
      return null;
  end level_holder;


  --============================================================================
  -- Delegation
  --============================================================================

  procedure resolve_delegate (p_employee_id   in  number
                            , p_doc_type      in  varchar2
                            , p_amount        in  number
                            , p_ref_date      in  date
                            , p_delegate_id   out number
                            , p_delegation_id out number) is
    l_current number(9)    := p_employee_id;
    l_next    number(9);
    l_del     number(12);
    l_hops    pls_integer  := 0;
    l_seen    t_flags;
  begin
    p_delegate_id   := p_employee_id;
    p_delegation_id := null;
    l_seen(p_employee_id) := true;

    loop
      l_hops := l_hops + 1;
      exit when l_hops > gc_max_delegation_hops;

      begin
        select d.delegate_id, d.delegation_id
          into l_next, l_del
          from (
                select dd.delegate_id
                     , dd.delegation_id
                     , row_number() over (
                         order by case when dd.doc_type is null then 1 else 0 end
                                , dd.created_on   desc
                                , dd.delegation_id desc) as rn
                  from approval_delegations dd
                  join employees e on e.employee_id = dd.delegate_id
                 where dd.delegator_id = l_current
                   and dd.active_flag  = 'Y'
                   and p_ref_date between dd.valid_from and dd.valid_to
                   and (dd.doc_type   is null or dd.doc_type   = p_doc_type)
                   and (dd.max_amount is null or p_amount is null or dd.max_amount >= p_amount)
                   and e.active_flag = 'Y'
               ) d
         where d.rn = 1;
      exception
        when no_data_found then
          exit;                                  -- nobody is standing in
      end;

      exit when l_seen.exists(l_next);           -- A -> B -> A: stop, keep the last valid actor

      l_seen(l_next)  := true;
      p_delegate_id   := l_next;
      p_delegation_id := l_del;                  -- the row authorising the final actor
      l_current       := l_next;
    end loop;
  end resolve_delegate;


  function effective_approver (p_employee_id in number
                             , p_doc_type    in varchar2 default null
                             , p_amount      in number   default null
                             , p_ref_date    in date     default sysdate) return number is
    l_delegate   number(9);
    l_delegation number(12);
  begin
    resolve_delegate(p_employee_id, p_doc_type, p_amount, p_ref_date, l_delegate, l_delegation);
    return l_delegate;
  end effective_approver;


  --============================================================================
  -- Chain resolution
  --
  -- Order of business:
  --   1. match a rule
  --   2. splice in the rule's BEFORE steps
  --   3. climb MANAGER_ID until the amount is covered / the rule's ceiling is
  --      reached / the level cap is hit - whichever comes first
  --   4. if the climb produced nobody, use the rule's fallback role
  --   5. splice in the rule's AFTER steps
  --   6. renumber, and collapse parallel groups
  --============================================================================

  function resolve_chain (p_doc_type     in  varchar2
                        , p_amount       in  number
                        , p_requester_id in  number
                        , p_dept_id      in  number   default null
                        , p_cost_center  in  varchar2 default null
                        , p_ref_date     in  date     default sysdate
                        , p_rule_id      out number) return approval_chain_nt is

    l_rule       approval_rules%rowtype;
    l_requester  employees%rowtype;
    l_out        approval_chain_nt := approval_chain_nt();
    l_keys       t_keys;
    l_seen       t_flags;

    l_cum        number(14,2) := 0;
    l_last_level number(2);
    l_last_limit number(14,2);
    l_hier_count pls_integer := 0;
    l_covered    boolean     := false;
    l_cycle      boolean     := false;
    l_warning    varchar2(400);

    l_grp        pls_integer := 0;
    l_prev_key   varchar2(60);

    ----------------------------------------------------------------------------
    -- Appends one approver, applying every exclusion rule in turn. Returns FALSE
    -- when the candidate was filtered out, so the caller knows not to count it
    -- towards coverage.
    ----------------------------------------------------------------------------
    function push (p_original_id in number
                 , p_source      in varchar2
                 , p_note        in varchar2
                 , p_mode        in varchar2 default 'SEQ'
                 , p_group_key   in varchar2 default null
                 , p_sla_hours   in number   default null) return boolean is
      l_emp   employees%rowtype;
      l_actor employees%rowtype;
      l_act   number(9);
      l_del   number(12);
      l_nt    varchar2(400) := p_note;
    begin
      begin
        select * into l_emp from employees where employee_id = p_original_id;
      exception
        when no_data_found then
          return false;
      end;

      -- Skip-level: an inactive manager is not a gate, they are a gap.
      if l_emp.active_flag = 'N' and l_rule.skip_inactive = 'Y' then
        return false;
      end if;

      -- Junior managers below the rule's floor are passed through rather than
      -- asked to rubber-stamp. Only applies to the hierarchy walk; a rule step
      -- naming someone explicitly always stands.
      if p_source = 'HIERARCHY' and l_emp.job_level < l_rule.start_at_level then
        return false;
      end if;

      -- Self-approval: the requester never signs their own document.
      if l_emp.employee_id = p_requester_id and l_rule.allow_self_approval = 'N' then
        return false;
      end if;

      -- Delegation substitution.
      l_act := l_emp.employee_id;
      l_del := null;

      if l_rule.apply_delegations = 'Y' then
        resolve_delegate(l_emp.employee_id, p_doc_type, p_amount, p_ref_date, l_act, l_del);

        if l_act <> l_emp.employee_id then
          -- A proxy must not hand the document back to the person who raised it.
          if l_act = p_requester_id and l_rule.allow_self_approval = 'N' then
            l_act := l_emp.employee_id;
            l_del := null;
            l_nt  := l_nt || ' (delegation ignored: proxy is the requester)';
          else
            l_nt := l_nt || ' (acting for ' || l_emp.full_name || ')';
          end if;
        end if;
      end if;

      -- Duplicate collapsing: one signature per person, at the earliest point
      -- their authority is needed.
      if l_rule.collapse_duplicates = 'Y' and l_seen.exists(l_act) then
        return false;
      end if;

      l_seen(l_act) := true;

      -- Only the climb counts towards coverage. A rule step is an *additional*
      -- mandatory approver, not part of the ladder: letting a BEFORE step (say a
      -- Procurement Lead who happens to sit at the rule's minimum level) satisfy
      -- the coverage test would truncate the management chain to one person.
      if p_source in ('HIERARCHY','FALLBACK') then
        l_cum        := l_cum + l_emp.approval_limit;
        l_last_level := l_emp.job_level;
        l_last_limit := l_emp.approval_limit;

        if not l_covered then
          l_covered := (l_emp.job_level >= l_rule.min_approver_level)
                   and (case l_rule.limit_mode
                          when 'INDIVIDUAL' then case when l_emp.approval_limit >= p_amount then 1 else 0 end
                          when 'CUMULATIVE' then case when l_cum                >= p_amount then 1 else 0 end
                          else 1
                        end = 1);
        end if;
      end if;

      select * into l_actor from employees where employee_id = l_act;

      l_out.extend;
      l_out(l_out.count) := approval_chain_ot(
          step_seq             => null                    -- assigned during renumber
        , group_no             => null
        , step_mode            => p_mode
        , source_code          => p_source
        , original_approver_id => l_emp.employee_id
        , approver_id          => l_act
        , approver_name        => l_actor.full_name
        , approver_username    => l_actor.apex_username
        , approver_email       => l_actor.email
        , job_level            => l_emp.job_level
        , approval_limit       => l_emp.approval_limit
        , cumulative_limit     => l_cum
        , delegation_id        => l_del
        , sla_hours            => nvl(p_sla_hours, l_rule.sla_hours)
        , covers_amount_yn     => case when l_covered then 'Y' else 'N' end
        , note                 => substr(l_nt, 1, 400));

      l_keys(l_out.count) := p_group_key;
      return true;
    end push;

    ----------------------------------------------------------------------------
    -- Mandatory rule steps, spliced before or after the hierarchy chain.
    ----------------------------------------------------------------------------
    procedure add_rule_steps (p_position in varchar2) is
      l_emp_id number(9);
      l_added  boolean;
    begin
      for rs in (select *
                   from approval_rule_steps
                  where rule_id       = l_rule.rule_id
                    and position_code = p_position
                    and active_flag   = 'Y'
                  order by step_no)
      loop
        l_emp_id := case rs.approver_type
                      when 'EMPLOYEE' then rs.employee_id
                      when 'ROLE'     then role_holder(rs.role_code, p_dept_id)
                      when 'LEVEL'    then level_holder(p_requester_id, rs.job_level)
                    end;

        if l_emp_id is null then
          if rs.mandatory_yn = 'Y' then
            raise_application_error(
              gc_err_no_approver,
              'Rule "' || l_rule.rule_code || '" requires a mandatory '
              || lower(rs.approver_type) || ' approver ('
              || coalesce(rs.role_code, to_char(rs.employee_id), 'level ' || rs.job_level)
              || ') but no active employee holds it.');
          end if;
          continue;
        end if;

        l_added := push(
            p_original_id => l_emp_id
          , p_source      => 'RULE'
          , p_note        => 'Required by rule ' || l_rule.rule_code
                             || case rs.approver_type
                                  when 'ROLE'  then ' as ' || rs.role_code
                                  when 'LEVEL' then ' as level ' || rs.job_level || '+'
                                  else ''
                                end
          , p_mode        => rs.step_mode
          , p_group_key   => case when rs.step_mode = 'SEQ'
                                  then null
                                  else p_position || '#' || rs.group_no
                             end
          , p_sla_hours   => rs.sla_hours);
      end loop;
    end add_rule_steps;

  begin
    g_last_covered := false;
    g_last_warning := null;
    g_last_rule_id := null;

    ---------------------------------------------------------------------- rule
    l_rule    := get_rule(p_doc_type, p_amount, p_dept_id, p_cost_center, p_ref_date);
    p_rule_id := l_rule.rule_id;

    begin
      select * into l_requester from employees where employee_id = p_requester_id;
    exception
      when no_data_found then
        raise_application_error(gc_err_not_found, 'Requester ' || p_requester_id || ' is not an employee.');
    end;

    -------------------------------------------------------------- BEFORE steps
    add_rule_steps('BEFORE');

    ----------------------------------------------------------- hierarchy climb
    -- NOCYCLE keeps a corrupt org chart from raising ORA-01436 in front of a
    -- user; CONNECT_BY_ISCYCLE tells us it happened so we can say so.
    for r in (select e.employee_id
                   , connect_by_iscycle as is_cycle
                   , level              as lvl
                from employees e
               start with e.employee_id = l_requester.manager_id
             connect by nocycle prior e.manager_id = e.employee_id
               order by level)
    loop
      if r.is_cycle = 1 then
        l_cycle   := true;
        l_warning := 'Management cycle detected at employee ' || r.employee_id
                     || '; the chain was truncated there. Fix it in V_HIERARCHY_HEALTH.';
      end if;

      if push(p_original_id => r.employee_id
            , p_source      => 'HIERARCHY'
            , p_note        => 'Level ' || r.lvl || ' manager') then

        l_hier_count := l_hier_count + 1;

        -- Stop on the first of: authority covers the amount, the rule's ceiling
        -- level is reached, the chain length cap is hit.
        exit when l_covered;
        exit when l_last_level >= l_rule.top_job_level;
        exit when l_hier_count >= l_rule.max_levels;
      end if;

      exit when l_cycle;
    end loop;

    ------------------------------------------------------- orphan / no manager
    if l_hier_count = 0 then
      if l_rule.fallback_role_code is not null then
        declare
          l_fb number(9) := role_holder(l_rule.fallback_role_code, p_dept_id);
        begin
          if l_fb is not null
             and push(p_original_id => l_fb
                    , p_source      => 'FALLBACK'
                    , p_note        => 'No usable management chain; routed to fallback role '
                                       || l_rule.fallback_role_code) then
            l_warning := nvl(l_warning,
              'Requester has no usable management chain; the rule fallback role was used.');
          end if;
        end;
      end if;

      if l_out.count = 0 then
        raise_application_error(
          gc_err_no_approver,
          case
            when l_cycle then
              'Cannot resolve an approval chain: the management hierarchy above '
              || l_requester.full_name || ' contains a cycle.'
            when l_requester.manager_id is null then
              l_requester.full_name || ' has no manager and rule "' || l_rule.rule_code
              || '" defines no fallback role. Set MANAGER_ID or set FALLBACK_ROLE_CODE.'
            else
              'Every manager above ' || l_requester.full_name
              || ' was excluded (inactive, or the requester themselves). '
              || 'No approver could be resolved.'
          end);
      end if;
    end if;

    if l_cycle and l_out.count = 0 then
      raise_application_error(gc_err_cycle, l_warning);
    end if;

    --------------------------------------------------------------- AFTER steps
    add_rule_steps('AFTER');

    ------------------------------------------------ renumber and group parallel
    for i in 1 .. l_out.count loop
      l_out(i).step_seq := i;

      if l_out(i).step_mode = 'SEQ' or l_keys(i) is null then
        l_grp      := l_grp + 1;
        l_prev_key := null;
      elsif l_keys(i) <> nvl(l_prev_key, '~none~') then
        l_grp      := l_grp + 1;
        l_prev_key := l_keys(i);
      end if;

      l_out(i).group_no := l_grp;
    end loop;

    if not l_covered and l_rule.limit_mode <> 'NONE' then
      l_warning := nvl(l_warning,
        'The resolved chain does not cover ' || to_char(p_amount,'FM999G999G990D00')
        || ': the highest authority reachable under rule "' || l_rule.rule_code
        || '" is ' || to_char(case l_rule.limit_mode when 'CUMULATIVE' then l_cum else l_last_limit end
                             ,'FM999G999G990D00') || '.');
    end if;

    g_last_covered := l_covered;
    g_last_warning := l_warning;
    g_last_rule_id := l_rule.rule_id;

    return l_out;
  end resolve_chain;


  function preview_chain (p_request_id in number) return approval_chain_nt pipelined is
    l_req   approval_requests%rowtype;
    l_chain approval_chain_nt;
    l_rule  number(9);
  begin
    begin
      select * into l_req from approval_requests where request_id = p_request_id;
    exception
      when no_data_found then
        raise_application_error(gc_err_not_found, 'Approval request ' || p_request_id || ' does not exist.');
    end;

    l_chain := resolve_chain(p_doc_type     => l_req.doc_type
                           , p_amount       => l_req.amount
                           , p_requester_id => l_req.requester_id
                           , p_dept_id      => l_req.dept_id
                           , p_cost_center  => l_req.cost_center
                           , p_rule_id      => l_rule);

    for i in 1 .. l_chain.count loop
      pipe row (l_chain(i));
    end loop;

    return;
  end preview_chain;


  function preview_chain (p_doc_type     in varchar2
                        , p_amount       in number
                        , p_requester_id in number
                        , p_dept_id      in number   default null
                        , p_cost_center  in varchar2 default null) return approval_chain_nt pipelined is
    l_chain approval_chain_nt;
    l_rule  number(9);
  begin
    l_chain := resolve_chain(p_doc_type     => p_doc_type
                           , p_amount       => p_amount
                           , p_requester_id => p_requester_id
                           , p_dept_id      => p_dept_id
                           , p_cost_center  => p_cost_center
                           , p_rule_id      => l_rule);

    for i in 1 .. l_chain.count loop
      pipe row (l_chain(i));
    end loop;

    return;
  end preview_chain;


  --============================================================================
  -- Materialisation
  --============================================================================

  procedure build_chain (p_request_id in number) is
    l_req    approval_requests%rowtype;
    l_chain  approval_chain_nt;
    l_rule   number(9);
    l_rows   pls_integer;
  begin
    pkg_approval_guard.enter_engine;

    lock_request(p_request_id, l_req);

    if l_req.status not in (gc_req_draft, gc_req_recalled) then
      raise_application_error(
        gc_err_bad_state,
        'A chain can only be built for a DRAFT or RECALLED request. '
        || l_req.request_ref || ' is ' || l_req.status || '.');
    end if;

    l_chain := resolve_chain(p_doc_type     => l_req.doc_type
                           , p_amount       => l_req.amount
                           , p_requester_id => l_req.requester_id
                           , p_dept_id      => l_req.dept_id
                           , p_cost_center  => l_req.cost_center
                           , p_rule_id      => l_rule);

    -- The rule may forbid routing a document nobody in reach can authorise.
    if not g_last_covered then
      declare
        l_require char(1);
        l_mode    varchar2(12);
      begin
        select require_coverage, limit_mode into l_require, l_mode
          from approval_rules where rule_id = l_rule;

        if l_require = 'Y' and l_mode <> 'NONE' then
          raise_application_error(gc_err_no_coverage, g_last_warning
            || ' Raise an approver''s APPROVAL_LIMIT, add a rule step for a higher authority, '
            || 'or set REQUIRE_COVERAGE = N on the rule.');
        end if;
      end;
    end if;

    -- Rebuild: a recalled request is re-resolved against today's org chart.
    delete from approval_steps where request_id = p_request_id;

    -- Bulk insert straight from the collection; no row-by-row loop.
    insert into approval_steps (
        request_id, step_seq, group_no, step_mode, source_code
      , original_approver_id, acting_approver_id, delegation_id, sla_hours, status)
    select p_request_id, c.step_seq, c.group_no, c.step_mode, c.source_code
         , c.original_approver_id, c.approver_id, c.delegation_id, c.sla_hours, gc_step_pending
      from table(l_chain) c;

    l_rows := sql%rowcount;

    update approval_requests
       set rule_id     = l_rule
         , row_version = row_version + 1
     where request_id  = p_request_id;

    log_action(p_request_id  => p_request_id
             , p_action_code => 'BUILD_CHAIN'
             , p_outcome     => case when g_last_warning is null then 'SUCCESS' else 'WARN' end
             , p_comments    => 'Rule ' || l_rule || ' resolved ' || l_rows || ' step(s). '
                                || g_last_warning);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => p_request_id
               , p_action_code => 'BUILD_CHAIN'
               , p_outcome     => 'ERROR'
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end build_chain;


  --============================================================================
  -- Group activation and advance
  --============================================================================

  procedure activate_group (p_request_id in number
                          , p_group_no   in number
                          , p_actor      in varchar2) is
    l_req approval_requests%rowtype;
  begin
    select * into l_req from approval_requests where request_id = p_request_id;

    for s in (select s.step_id, s.original_approver_id, s.sla_hours
                from approval_steps s
               where s.request_id = p_request_id
                 and s.group_no   = p_group_no
                 and s.status     = gc_step_pending
               order by s.step_seq)
    loop
      declare
        l_act number(9);
        l_del number(12);
      begin
        -- Re-resolve delegation at activation, not at build time: someone may
        -- have gone on leave between submission and their turn.
        resolve_delegate(s.original_approver_id, l_req.doc_type, l_req.amount, sysdate, l_act, l_del);

        update approval_steps
           set status             = gc_step_active
             , acting_approver_id = l_act
             , delegation_id      = l_del
             , activated_on       = systimestamp
             , sla_due_on         = sla_due(systimestamp, s.sla_hours)
             , reminder_sent_on   = null
         where step_id = s.step_id;

        enqueue_notify(p_request_id  => p_request_id
                     , p_notify_type => 'ASSIGNED'
                     , p_employee_id => l_act
                     , p_step_id     => s.step_id);
      end;
    end loop;

    update approval_requests
       set current_group = p_group_no
         , row_version   = row_version + 1
     where request_id = p_request_id;
  end activate_group;


  -- Called once a group completes. Moves to the next group, or closes the request.
  procedure advance (p_request_id in number, p_actor in varchar2) is
    l_next number(3);
    l_req  approval_requests%rowtype;
  begin
    select min(group_no)
      into l_next
      from approval_steps
     where request_id = p_request_id
       and status     = gc_step_pending;

    if l_next is null then
      select * into l_req from approval_requests where request_id = p_request_id;

      update approval_requests
         set status        = gc_req_approved
           , completed_on  = systimestamp
           , current_group = null
           , row_version   = row_version + 1
       where request_id = p_request_id;

      log_action(p_request_id  => p_request_id
               , p_action_code => 'COMPLETE'
               , p_from_status => l_req.status
               , p_to_status   => gc_req_approved
               , p_actor       => p_actor
               , p_comments    => 'All approval steps completed.');

      enqueue_notify(p_request_id  => p_request_id
                   , p_notify_type => 'APPROVED'
                   , p_employee_id => l_req.requester_id);
    else
      activate_group(p_request_id, l_next, p_actor);
    end if;
  end advance;


  -- Cancel every step that has not reached a terminal state.
  procedure cancel_open_steps (p_request_id in number, p_reason in varchar2) is
  begin
    update approval_steps
       set status   = gc_step_cancelled
         , comments = substr(nvl(comments || ' | ', '') || p_reason, 1, 4000)
     where request_id = p_request_id
       and status in (gc_step_pending, gc_step_active, gc_step_info);
  end cancel_open_steps;


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
                         , p_actor         in varchar2 default null) return number is
    l_actor    varchar2(100) := actor_or_current(p_actor);
    l_req_id   number(12);
    l_emp_id   number(9);
    l_dept     number(6)     := p_dept_id;
    l_cc       varchar2(20)  := p_cost_center;
    l_ref      varchar2(40);
  begin
    pkg_approval_guard.enter_engine;

    l_emp_id := nvl(p_requester_id, employee_id_for(l_actor));

    -- Default the routing scope from the requester's own posting.
    if l_dept is null or l_cc is null then
      select nvl(l_dept, e.dept_id), nvl(l_cc, e.cost_center)
        into l_dept, l_cc
        from employees e
       where e.employee_id = l_emp_id;
    end if;

    l_ref := p_doc_type || '-' || to_char(sysdate,'YYYY') || '-'
             || lpad(to_char(seq_approval_ref.nextval), 6, '0');

    insert into approval_requests (
        request_ref, doc_type, doc_id, doc_ref, requester_id, title, description
      , amount, currency_code, dept_id, cost_center, priority_code, status)
    values (
        l_ref, p_doc_type, p_doc_id, p_doc_ref, l_emp_id, p_title, p_description
      , p_amount, p_currency_code, l_dept, l_cc, p_priority_code, gc_req_draft)
    returning request_id into l_req_id;

    log_action(p_request_id  => l_req_id
             , p_action_code => 'CREATE'
             , p_to_status   => gc_req_draft
             , p_actor       => l_actor
             , p_comments    => 'Draft ' || l_ref || ' created.');

    pkg_approval_guard.leave_engine;
    return l_req_id;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => null
               , p_action_code => 'CREATE'
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end create_request;


  procedure submit (p_request_id in number
                  , p_actor      in varchar2 default null
                  , p_comments   in varchar2 default null) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_req   approval_requests%rowtype;
    l_first number(3);
    l_owner varchar2(120);
  begin
    pkg_approval_guard.enter_engine;

    lock_request(p_request_id, l_req);

    if l_req.status not in (gc_req_draft, gc_req_recalled) then
      raise_application_error(
        gc_err_bad_state,
        l_req.request_ref || ' cannot be submitted from status ' || l_req.status
        || '. Only DRAFT and RECALLED requests may be submitted.');
    end if;

    -- Only the requester submits. Admins deliberately cannot: submitting on
    -- someone's behalf would make the audit trail lie about who asked.
    if l_req.requester_id <> employee_id_for(l_actor) then
      select full_name into l_owner from employees where employee_id = l_req.requester_id;
      raise_application_error(
        gc_err_not_approver,
        'Only the requester (' || l_owner || ') may submit ' || l_req.request_ref || '.');
    end if;

    build_chain(p_request_id);

    select min(group_no) into l_first from approval_steps where request_id = p_request_id;

    if l_first is null then
      raise_application_error(gc_err_no_approver,
        'No approval steps were produced for ' || l_req.request_ref || '.');
    end if;

    update approval_requests
       set status       = gc_req_pending
         , submitted_on = systimestamp
         , row_version  = row_version + 1
     where request_id = p_request_id;

    activate_group(p_request_id, l_first, l_actor);

    log_action(p_request_id  => p_request_id
             , p_action_code => 'SUBMIT'
             , p_from_status => l_req.status
             , p_to_status   => gc_req_pending
             , p_actor       => l_actor
             , p_comments    => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => p_request_id
               , p_action_code => 'SUBMIT'
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end submit;


  --============================================================================
  -- Approver actions
  --============================================================================

  -- Shared entry checks for every step action.
  procedure assert_actionable (p_step_id in  number
                             , p_actor   in  varchar2
                             , p_step    out approval_steps%rowtype
                             , p_req     out approval_requests%rowtype) is
  begin
    lock_step(p_step_id, p_step);
    lock_request(p_step.request_id, p_req);

    if p_req.status not in (gc_req_pending, gc_req_info) then
      raise_application_error(
        gc_err_bad_state,
        p_req.request_ref || ' is ' || p_req.status || ' and is no longer in flight.');
    end if;

    if p_step.status <> gc_step_active then
      raise_application_error(
        gc_err_step_inactive,
        'Step ' || p_step_id || ' is ' || p_step.status
        || '. Only an ACTIVE step can be actioned - it may have been escalated, '
        || 'reassigned, or already closed by another approver in the same group.');
    end if;

    if can_act(p_step_id, p_actor) = 'N' then
      raise_application_error(
        gc_err_not_approver,
        'User ' || p_actor || ' is not the current approver for step ' || p_step_id || '.');
    end if;
  end assert_actionable;


  procedure approve (p_step_id  in number
                   , p_actor    in varchar2 default null
                   , p_comments in varchar2 default null) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_step  approval_steps%rowtype;
    l_req   approval_requests%rowtype;
    l_open  pls_integer;
    l_done  boolean;
  begin
    pkg_approval_guard.enter_engine;

    assert_actionable(p_step_id, l_actor, l_step, l_req);

    update approval_steps
       set status             = gc_step_approved
         , action_on          = systimestamp
         , action_by_username = l_actor
         , comments           = p_comments
     where step_id = p_step_id;

    log_action(p_request_id  => l_step.request_id
             , p_action_code => 'APPROVE'
             , p_step_id     => p_step_id
             , p_from_status => gc_step_active
             , p_to_status   => gc_step_approved
             , p_actor       => l_actor
             , p_comments    => p_comments);

    if l_step.step_mode = 'ANY' then
      -- Any-one-of: the first approval closes the whole group.
      update approval_steps
         set status   = gc_step_skipped
           , comments = 'Closed: another approver in this any-one-of group acted.'
       where request_id = l_step.request_id
         and group_no   = l_step.group_no
         and step_id   <> p_step_id
         and status in (gc_step_pending, gc_step_active, gc_step_info);
      l_done := true;
    else
      select count(*)
        into l_open
        from approval_steps
       where request_id = l_step.request_id
         and group_no   = l_step.group_no
         and status in (gc_step_pending, gc_step_active, gc_step_info);
      l_done := (l_open = 0);
    end if;

    if l_done then
      advance(l_step.request_id, l_actor);
    end if;

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'APPROVE'
               , p_step_id     => p_step_id
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end approve;


  procedure reject (p_step_id  in number
                  , p_actor    in varchar2
                  , p_comments in varchar2) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_step  approval_steps%rowtype;
    l_req   approval_requests%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    if p_comments is null or trim(p_comments) is null then
      raise_application_error(gc_err_need_comment,
        'A reason is required when rejecting. Tell the requester what to fix.');
    end if;

    assert_actionable(p_step_id, l_actor, l_step, l_req);

    update approval_steps
       set status             = gc_step_rejected
         , action_on          = systimestamp
         , action_by_username = l_actor
         , comments           = p_comments
     where step_id = p_step_id;

    -- One rejection ends the document. A "send back for rework" flow is RECALL
    -- plus REQUEST_INFO, not a partial rejection.
    cancel_open_steps(l_step.request_id, 'Cancelled: request rejected at step ' || l_step.step_seq || '.');

    update approval_requests
       set status        = gc_req_rejected
         , completed_on  = systimestamp
         , current_group = null
         , row_version   = row_version + 1
     where request_id = l_step.request_id;

    log_action(p_request_id  => l_step.request_id
             , p_action_code => 'REJECT'
             , p_step_id     => p_step_id
             , p_from_status => l_req.status
             , p_to_status   => gc_req_rejected
             , p_actor       => l_actor
             , p_comments    => p_comments);

    enqueue_notify(p_request_id  => l_step.request_id
                 , p_notify_type => 'REJECTED'
                 , p_employee_id => l_req.requester_id
                 , p_step_id     => p_step_id
                 , p_message     => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'REJECT'
               , p_step_id     => p_step_id
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end reject;


  procedure request_info (p_step_id  in number
                        , p_actor    in varchar2
                        , p_comments in varchar2) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_step  approval_steps%rowtype;
    l_req   approval_requests%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    if p_comments is null or trim(p_comments) is null then
      raise_application_error(gc_err_need_comment,
        'State what information you need before pausing the request.');
    end if;

    assert_actionable(p_step_id, l_actor, l_step, l_req);

    -- The step is parked, not closed: the chain is preserved and the SLA clock
    -- stops, because the delay now belongs to the requester.
    update approval_steps
       set status     = gc_step_info
         , comments   = p_comments
         , sla_due_on = null
     where step_id = p_step_id;

    update approval_requests
       set status      = gc_req_info
         , row_version = row_version + 1
     where request_id = l_step.request_id;

    log_action(p_request_id  => l_step.request_id
             , p_action_code => 'REQUEST_INFO'
             , p_step_id     => p_step_id
             , p_from_status => l_req.status
             , p_to_status   => gc_req_info
             , p_actor       => l_actor
             , p_comments    => p_comments);

    enqueue_notify(p_request_id  => l_step.request_id
                 , p_notify_type => 'INFO_REQUESTED'
                 , p_employee_id => l_req.requester_id
                 , p_step_id     => p_step_id
                 , p_message     => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'REQUEST_INFO'
               , p_step_id     => p_step_id
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end request_info;


  procedure provide_info (p_request_id in number
                        , p_actor      in varchar2 default null
                        , p_comments   in varchar2 default null) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_req   approval_requests%rowtype;
    l_rule  approval_rules%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    lock_request(p_request_id, l_req);

    if l_req.status <> gc_req_info then
      raise_application_error(gc_err_bad_state,
        l_req.request_ref || ' is not waiting for information (status ' || l_req.status || ').');
    end if;

    if l_req.requester_id <> employee_id_for(l_actor) then
      raise_application_error(gc_err_not_approver,
        'Only the requester may respond to an information request.');
    end if;

    select * into l_rule from approval_rules where rule_id = l_req.rule_id;

    -- Restart the clock: the approver gets a full SLA from the moment they can
    -- actually act again.
    update approval_steps
       set status     = gc_step_active
         , sla_due_on = sla_due(systimestamp, nvl(sla_hours, l_rule.sla_hours))
         , comments   = substr(nvl(comments || ' | ', '') || 'Requester replied: ' || p_comments, 1, 4000)
     where request_id = p_request_id
       and status     = gc_step_info;

    update approval_requests
       set status      = gc_req_pending
         , row_version = row_version + 1
     where request_id = p_request_id;

    log_action(p_request_id  => p_request_id
             , p_action_code => 'PROVIDE_INFO'
             , p_from_status => gc_req_info
             , p_to_status   => gc_req_pending
             , p_actor       => l_actor
             , p_comments    => p_comments);

    for s in (select step_id, acting_approver_id
                from approval_steps
               where request_id = p_request_id and status = gc_step_active)
    loop
      enqueue_notify(p_request_id  => p_request_id
                   , p_notify_type => 'INFO_PROVIDED'
                   , p_employee_id => s.acting_approver_id
                   , p_step_id     => s.step_id
                   , p_message     => p_comments);
    end loop;

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => p_request_id
               , p_action_code => 'PROVIDE_INFO'
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end provide_info;


  procedure reassign (p_step_id        in number
                    , p_to_employee_id in number
                    , p_actor          in varchar2 default null
                    , p_comments       in varchar2 default null) is
    l_actor  varchar2(100) := actor_or_current(p_actor);
    l_step   approval_steps%rowtype;
    l_req    approval_requests%rowtype;
    l_target employees%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    lock_step(p_step_id, l_step);
    lock_request(l_step.request_id, l_req);

    if l_step.status not in (gc_step_active, gc_step_info) then
      raise_application_error(gc_err_step_inactive,
        'Only an open step can be reassigned; step ' || p_step_id || ' is ' || l_step.status || '.');
    end if;

    -- The current holder may hand it on; so may an administrator, because the
    -- common case is an approver who has left the company.
    if can_act(p_step_id, l_actor) = 'N' and is_admin(l_actor) = 'N' then
      raise_application_error(gc_err_not_approver,
        'Only the current approver or an approval administrator may reassign step ' || p_step_id || '.');
    end if;

    begin
      select * into l_target from employees where employee_id = p_to_employee_id;
    exception
      when no_data_found then
        raise_application_error(gc_err_not_found, 'Employee ' || p_to_employee_id || ' does not exist.');
    end;

    if l_target.active_flag = 'N' then
      raise_application_error(gc_err_bad_state,
        l_target.full_name || ' is inactive and cannot be assigned approvals.');
    end if;

    if p_to_employee_id = l_req.requester_id then
      raise_application_error(gc_err_self_approval,
        'A step cannot be reassigned to the requester.');
    end if;

    update approval_steps
       set acting_approver_id = p_to_employee_id
         , delegation_id      = null
         , source_code        = 'REASSIGN'
         , sla_due_on         = sla_due(systimestamp, sla_hours)
         , reminder_sent_on   = null
         , comments           = substr(nvl(comments || ' | ', '')
                                || 'Reassigned by ' || l_actor
                                || nvl(': ' || p_comments, ''), 1, 4000)
     where step_id = p_step_id;

    log_action(p_request_id  => l_step.request_id
             , p_action_code => 'REASSIGN'
             , p_step_id     => p_step_id
             , p_actor       => l_actor
             , p_comments    => 'Reassigned to ' || l_target.full_name
                                || nvl(' - ' || p_comments, ''));

    enqueue_notify(p_request_id  => l_step.request_id
                 , p_notify_type => 'REASSIGNED'
                 , p_employee_id => p_to_employee_id
                 , p_step_id     => p_step_id
                 , p_message     => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'REASSIGN'
               , p_step_id     => p_step_id
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end reassign;


  --============================================================================
  -- Requester actions
  --============================================================================

  procedure recall (p_request_id in number
                  , p_actor      in varchar2 default null
                  , p_comments   in varchar2 default null) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_req   approval_requests%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    lock_request(p_request_id, l_req);

    if l_req.status not in (gc_req_pending, gc_req_info) then
      raise_application_error(gc_err_bad_state,
        l_req.request_ref || ' cannot be recalled from status ' || l_req.status
        || '. Only an in-flight request can be pulled back.');
    end if;

    if l_req.requester_id <> employee_id_for(l_actor) and is_admin(l_actor) = 'N' then
      raise_application_error(gc_err_not_approver,
        'Only the requester or an approval administrator may recall ' || l_req.request_ref || '.');
    end if;

    -- Notify anyone holding it before the steps disappear from their inbox.
    for s in (select step_id, acting_approver_id
                from approval_steps
               where request_id = p_request_id
                 and status in (gc_step_active, gc_step_info))
    loop
      enqueue_notify(p_request_id  => p_request_id
                   , p_notify_type => 'RECALLED'
                   , p_employee_id => s.acting_approver_id
                   , p_step_id     => s.step_id
                   , p_message     => p_comments);
    end loop;

    cancel_open_steps(p_request_id, 'Cancelled: recalled by requester.');

    update approval_requests
       set status        = gc_req_recalled
         , current_group = null
         , recall_count  = recall_count + 1
         , row_version   = row_version + 1
     where request_id = p_request_id;

    log_action(p_request_id  => p_request_id
             , p_action_code => 'RECALL'
             , p_from_status => l_req.status
             , p_to_status   => gc_req_recalled
             , p_actor       => l_actor
             , p_comments    => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => p_request_id
               , p_action_code => 'RECALL'
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end recall;


  procedure withdraw (p_request_id in number
                    , p_actor      in varchar2 default null
                    , p_comments   in varchar2 default null) is
    l_actor varchar2(100) := actor_or_current(p_actor);
    l_req   approval_requests%rowtype;
  begin
    pkg_approval_guard.enter_engine;

    lock_request(p_request_id, l_req);

    if l_req.status in (gc_req_approved, gc_req_rejected, gc_req_withdrawn) then
      raise_application_error(gc_err_bad_state,
        l_req.request_ref || ' is already ' || l_req.status || ' and cannot be withdrawn.');
    end if;

    if l_req.requester_id <> employee_id_for(l_actor) and is_admin(l_actor) = 'N' then
      raise_application_error(gc_err_not_approver,
        'Only the requester or an approval administrator may withdraw ' || l_req.request_ref || '.');
    end if;

    for s in (select step_id, acting_approver_id
                from approval_steps
               where request_id = p_request_id
                 and status in (gc_step_active, gc_step_info))
    loop
      enqueue_notify(p_request_id  => p_request_id
                   , p_notify_type => 'WITHDRAWN'
                   , p_employee_id => s.acting_approver_id
                   , p_step_id     => s.step_id
                   , p_message     => p_comments);
    end loop;

    cancel_open_steps(p_request_id, 'Cancelled: request withdrawn.');

    update approval_requests
       set status        = gc_req_withdrawn
         , completed_on  = systimestamp
         , current_group = null
         , row_version   = row_version + 1
     where request_id = p_request_id;

    log_action(p_request_id  => p_request_id
             , p_action_code => 'WITHDRAW'
             , p_from_status => l_req.status
             , p_to_status   => gc_req_withdrawn
             , p_actor       => l_actor
             , p_comments    => p_comments);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => p_request_id
               , p_action_code => 'WITHDRAW'
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end withdraw;


  --============================================================================
  -- SLA handling
  --============================================================================

  procedure escalate (p_step_id in number
                    , p_actor   in varchar2 default null
                    , p_reason  in varchar2 default null) is
    l_actor  varchar2(100) := actor_or_current(p_actor);
    l_step   approval_steps%rowtype;
    l_req    approval_requests%rowtype;
    l_rule   approval_rules%rowtype;
    l_target number(9);
    l_act    number(9);
    l_del    number(12);
    l_name   varchar2(120);
  begin
    pkg_approval_guard.enter_engine;

    lock_step(p_step_id, l_step);
    lock_request(l_step.request_id, l_req);

    if l_step.status <> gc_step_active then
      -- Normal race: the approver acted between the sweep and this call.
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'ESCALATE'
               , p_step_id     => p_step_id
               , p_outcome     => 'WARN'
               , p_actor       => l_actor
               , p_comments    => 'Skipped: step is ' || l_step.status || ', not ACTIVE.');
      pkg_approval_guard.leave_engine;
      return;
    end if;

    select * into l_rule from approval_rules where rule_id = l_req.rule_id;

    if l_step.escalation_count >= l_rule.max_escalations then
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'ESCALATE'
               , p_step_id     => p_step_id
               , p_outcome     => 'WARN'
               , p_actor       => l_actor
               , p_comments    => 'Escalation ceiling (' || l_rule.max_escalations
                                  || ') reached; leaving the step where it is.');
      pkg_approval_guard.leave_engine;
      return;
    end if;

    -- Climb from whoever currently holds it, skipping inactive managers, and
    -- never landing on the requester.
    begin
      select employee_id
        into l_target
        from (
              select e.employee_id, level as lvl
                from employees e
               where e.active_flag  = 'Y'
                 and e.employee_id <> l_req.requester_id
                 and e.employee_id <> l_step.acting_approver_id
               start with e.employee_id = (select manager_id from employees
                                            where employee_id = l_step.acting_approver_id)
             connect by nocycle prior e.manager_id = e.employee_id
               order by lvl
             )
       where rownum = 1;
    exception
      when no_data_found then
        log_action(p_request_id  => l_step.request_id
                 , p_action_code => 'ESCALATE'
                 , p_step_id     => p_step_id
                 , p_outcome     => 'WARN'
                 , p_actor       => l_actor
                 , p_comments    => 'No escalation target above the current approver; step left in place.');
        pkg_approval_guard.leave_engine;
        return;
    end;

    resolve_delegate(l_target, l_req.doc_type, l_req.amount, sysdate, l_act, l_del);

    update approval_steps
       set acting_approver_id = l_act
         , delegation_id      = l_del
         , escalation_count   = escalation_count + 1
         , sla_due_on         = sla_due(systimestamp, l_rule.sla_hours)
         , reminder_sent_on   = null
         , comments           = substr(nvl(comments || ' | ', '')
                                || 'Escalated after SLA breach'
                                || nvl(': ' || p_reason, ''), 1, 4000)
     where step_id = p_step_id;

    select full_name into l_name from employees where employee_id = l_act;

    log_action(p_request_id  => l_step.request_id
             , p_action_code => 'ESCALATE'
             , p_step_id     => p_step_id
             , p_actor       => l_actor
             , p_comments    => 'Escalated to ' || l_name
                                || ' (attempt ' || (l_step.escalation_count + 1) || ')');

    enqueue_notify(p_request_id  => l_step.request_id
                 , p_notify_type => 'ESCALATED'
                 , p_employee_id => l_act
                 , p_step_id     => p_step_id
                 , p_message     => p_reason);

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      log_action(p_request_id  => l_step.request_id
               , p_action_code => 'ESCALATE'
               , p_step_id     => p_step_id
               , p_outcome     => 'ERROR'
               , p_actor       => l_actor
               , p_error_code  => sqlcode
               , p_error_msg   => sqlerrm);
      raise;
  end escalate;


  procedure escalate_overdue (p_doc_type  in  varchar2    default null
                            , p_max_rows  in  pls_integer default 500
                            , p_escalated out pls_integer) is
    type t_ids is table of number(12) index by pls_integer;
    l_ids t_ids;
  begin
    p_escalated := 0;

    select step_id
      bulk collect into l_ids
      from (
            select s.step_id
              from approval_steps    s
              join approval_requests r on r.request_id = s.request_id
              join approval_rules    u on u.rule_id    = r.rule_id
             where s.status      = gc_step_active
               and s.sla_due_on  < systimestamp
               and s.escalation_count < u.max_escalations
               and r.status      = gc_req_pending
               and (p_doc_type is null or r.doc_type = p_doc_type)
             order by s.sla_due_on
           )
     where rownum <= p_max_rows;

    for i in 1 .. l_ids.count loop
      begin
        escalate(p_step_id => l_ids(i)
               , p_actor   => 'SYSTEM'
               , p_reason  => 'Automatic escalation: SLA elapsed.');
        p_escalated := p_escalated + 1;
      exception
        when others then
          -- One bad step must not stop the sweep; ESCALATE already logged it.
          null;
      end;
    end loop;
  end escalate_overdue;


  procedure send_reminders (p_doc_type in  varchar2    default null
                          , p_max_rows in  pls_integer default 1000
                          , p_queued   out pls_integer) is
    type t_step_rec is record (step_id number(12), request_id number(12), approver_id number(9));
    type t_steps    is table of t_step_rec index by pls_integer;
    l_steps t_steps;
  begin
    p_queued := 0;

    select step_id, request_id, acting_approver_id
      bulk collect into l_steps
      from (
            select s.step_id, s.request_id, s.acting_approver_id
              from approval_steps    s
              join approval_requests r on r.request_id = s.request_id
              join approval_rules    u on u.rule_id    = r.rule_id
             where s.status = gc_step_active
               and s.reminder_sent_on is null
               and u.reminder_hours is not null
               and s.sla_due_on is not null
               -- Inside the reminder window, but not yet overdue: an overdue
               -- step is the escalation sweep's problem, not the reminder's.
               and s.sla_due_on - numtodsinterval(u.reminder_hours,'hour') <= systimestamp
               and s.sla_due_on > systimestamp
               and (p_doc_type is null or r.doc_type = p_doc_type)
             order by s.sla_due_on
           )
     where rownum <= p_max_rows;

    pkg_approval_guard.enter_engine;

    for i in 1 .. l_steps.count loop
      enqueue_notify(p_request_id  => l_steps(i).request_id
                   , p_notify_type => 'REMINDER'
                   , p_employee_id => l_steps(i).approver_id
                   , p_step_id     => l_steps(i).step_id);
    end loop;

    forall i in 1 .. l_steps.count
      update approval_steps
         set reminder_sent_on = systimestamp
       where step_id = l_steps(i).step_id;

    p_queued := l_steps.count;

    pkg_approval_guard.leave_engine;
  exception
    when others then
      pkg_approval_guard.leave_engine;
      raise;
  end send_reminders;


  --============================================================================
  -- Inbox and authorisation
  --============================================================================

  function get_pending_for_user (p_username in varchar2 default null)
    return approval_pending_nt pipelined is
    l_user varchar2(100) := actor_or_current(p_username);
  begin
    for r in (
      select s.step_id, s.request_id, r.request_ref, r.doc_type, dt.doc_type_name
           , r.doc_ref, r.title, r.amount, r.currency_code, r.priority_code
           , er.full_name as requester_name, er.apex_username as requester_username
           , dp.dept_name, r.cost_center, r.submitted_on
           , s.step_seq, s.group_no, s.step_mode, s.activated_on, s.sla_due_on
           , round((cast(s.sla_due_on as date) - sysdate) * 24, 1) as hours_remaining
           , case
               when s.sla_due_on is null                                     then 'OK'
               when s.sla_due_on <  systimestamp                             then 'OVERDUE'
               when s.sla_due_on <  systimestamp + numtodsinterval(4,'hour') then 'DUE_SOON'
               else 'OK'
             end as sla_state
           , s.escalation_count
           , case when s.acting_approver_id <> s.original_approver_id
                  then eo.full_name end as acting_for_name
        from approval_steps    s
        join approval_requests r  on r.request_id  = s.request_id
        join approval_doc_types dt on dt.doc_type  = r.doc_type
        join employees         er on er.employee_id = r.requester_id
        join employees         eo on eo.employee_id = s.original_approver_id
        join employees         ea on ea.employee_id = s.acting_approver_id
        left join departments  dp on dp.dept_id     = r.dept_id
       where s.status = gc_step_active
         and ( ea.apex_username = l_user
            or exists (select 1
                         from v_active_delegations d
                         join employees ed on ed.employee_id = d.delegate_id
                        where d.delegator_id = s.acting_approver_id
                          and (d.doc_type   is null or d.doc_type   = r.doc_type)
                          and (d.max_amount is null or d.max_amount >= r.amount)
                          and ed.active_flag   = 'Y'
                          and ed.apex_username = l_user) )
       order by case when s.sla_due_on < systimestamp then 0 else 1 end
              , s.sla_due_on nulls last
              , r.amount desc)
    loop
      pipe row (approval_pending_ot(
          r.step_id, r.request_id, r.request_ref, r.doc_type, r.doc_type_name
        , r.doc_ref, r.title, r.amount, r.currency_code, r.priority_code
        , r.requester_name, r.requester_username, r.dept_name, r.cost_center
        , r.submitted_on, r.step_seq, r.group_no, r.step_mode, r.activated_on
        , r.sla_due_on, r.hours_remaining, r.sla_state, r.escalation_count
        , r.acting_for_name));
    end loop;

    return;
  end get_pending_for_user;


  function get_pending_cursor (p_username in varchar2 default null) return sys_refcursor is
    l_cur  sys_refcursor;
    l_user varchar2(100) := actor_or_current(p_username);
  begin
    open l_cur for
      select * from table(pkg_approval_engine.get_pending_for_user(l_user));
    return l_cur;
  end get_pending_cursor;


  function pending_count (p_username in varchar2 default null) return number is
    l_user  varchar2(100) := actor_or_current(p_username);
    l_count number;
  begin
    select count(*)
      into l_count
      from approval_steps    s
      join approval_requests r  on r.request_id  = s.request_id
      join employees         ea on ea.employee_id = s.acting_approver_id
     where s.status = gc_step_active
       and ( ea.apex_username = l_user
          or exists (select 1
                       from v_active_delegations d
                       join employees ed on ed.employee_id = d.delegate_id
                      where d.delegator_id = s.acting_approver_id
                        and (d.doc_type   is null or d.doc_type   = r.doc_type)
                        and (d.max_amount is null or d.max_amount >= r.amount)
                        and ed.active_flag   = 'Y'
                        and ed.apex_username = l_user) );
    return l_count;
  end pending_count;


  function is_admin (p_username in varchar2 default null) return varchar2 is
    l_user  varchar2(100) := actor_or_current(p_username);
    l_count pls_integer;
  begin
    select count(*)
      into l_count
      from employee_roles er
      join employees      e on e.employee_id = er.employee_id
     where er.role_code     = gc_admin_role
       and er.active_flag   = 'Y'
       and e.active_flag    = 'Y'
       and e.apex_username  = l_user;

    return case when l_count > 0 then 'Y' else 'N' end;
  end is_admin;


  function can_act (p_step_id  in number
                  , p_username in varchar2 default null) return varchar2 is
    l_user   varchar2(100) := actor_or_current(p_username);
    l_status varchar2(20);
    l_acting number(9);
    l_uname  varchar2(100);
    l_type   varchar2(30);
    l_amount number(14,2);
    l_count  pls_integer;
  begin
    select s.status, s.acting_approver_id, ea.apex_username, r.doc_type, r.amount
      into l_status, l_acting, l_uname, l_type, l_amount
      from approval_steps    s
      join approval_requests r  on r.request_id  = s.request_id
      join employees         ea on ea.employee_id = s.acting_approver_id
     where s.step_id = p_step_id;

    if l_status <> gc_step_active then
      return 'N';
    end if;

    if l_uname = l_user then
      return 'Y';
    end if;

    -- A delegation created after the step was activated still counts, so an
    -- approver going out of office mid-step does not strand the document.
    select count(*)
      into l_count
      from v_active_delegations d
      join employees ed on ed.employee_id = d.delegate_id
     where d.delegator_id = l_acting
       and (d.doc_type   is null or d.doc_type   = l_type)
       and (d.max_amount is null or d.max_amount >= l_amount)
       and ed.active_flag   = 'Y'
       and ed.apex_username = l_user;

    -- Note: administrators are deliberately NOT granted CAN_ACT. They can
    -- REASSIGN a stuck step, which leaves a name in the audit trail; they
    -- cannot quietly approve on someone else's behalf.
    return case when l_count > 0 then 'Y' else 'N' end;
  exception
    when no_data_found then
      return 'N';
  end can_act;


  function can_view (p_request_id in number
                   , p_username   in varchar2 default null) return varchar2 is
    l_user  varchar2(100) := actor_or_current(p_username);
    l_count pls_integer;
  begin
    if is_admin(l_user) = 'Y' then
      return 'Y';
    end if;

    select count(*)
      into l_count
      from approval_requests r
     where r.request_id = p_request_id
       and ( exists (select 1 from employees e
                      where e.employee_id   = r.requester_id
                        and e.apex_username = l_user)
          or exists (select 1
                       from approval_steps s
                       join employees e
                         on e.employee_id in (s.original_approver_id, s.acting_approver_id)
                      where s.request_id    = r.request_id
                        and e.apex_username = l_user) );

    return case when l_count > 0 then 'Y' else 'N' end;
  end can_view;

end pkg_approval_engine;
/

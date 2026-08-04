# Autonomous Transaction Processing notes

What is different about running this on ATP rather than a database you administer
yourself, and what in this codebase was shaped by it.

## Connecting to install the scripts

APEX SQL Workshop works for one-off statements but cannot follow `@@` includes,
so `install.sql` must run from a client. On ATP that means SQLcl or SQL\*Plus
with the instance wallet:

```bash
# Download the wallet from the OCI console (DB Connection -> Download Wallet)
export TNS_ADMIN=/path/to/wallet
sqlcl -cloudconfig /path/to/wallet.zip <APP_SCHEMA>/<password>@<db>_tp
SQL> @install.sql
```

If the instance has **mTLS made optional** (one-way TLS enabled) you can connect
without the wallet using the TLS connection string, which is easier for CI. Both
work; mTLS is the default and the more common configuration.

Service alias matters more than people expect. Use `_tp` for the install and for
APEX; `_tpurgent` gets a higher-priority consumer group and should be reserved
for genuinely urgent work; `_low` gets fewer resources and a lower degree of
parallelism. The APEX/ORDS connection pool on ATP is bound to `TP` by default —
which is where the Automations run too.

Run the numbered files individually in SQL Workshop if you have no client
available; the order is listed at the top of `install.sql`.

## APEX is ORDS-hosted and managed

- APEX and ORDS are patched by Oracle. Do not pin behaviour to a specific APEX
  patch level; this build targets 23.2+ features only.
- You have no `ADMIN` access to the APEX instance administration beyond what the
  ATP console exposes, and no filesystem. Anything that would normally live in a
  directory object (`UTL_FILE`, external tables) has to go elsewhere — see
  attachments below.
- The APEX parsing schema is the object owner. That is why tamper protection in
  this design is **triggers**, not grants: you cannot revoke `UPDATE` from a
  schema on its own tables.

## Mail

`APEX_MAIL` on ATP requires OCI Email Delivery:

1. Create an SMTP credential (Identity → User → SMTP Credentials).
2. Add an approved sender for the `From` address you intend to use.
3. In the ATP console, set the APEX instance SMTP settings to the Email Delivery
   endpoint (port 587, TLS).
4. Grant network ACL access to the SMTP host for the APEX schema — this is
   normally done for you on ATP, but if `apex_mail.push_queue` raises
   `ORA-24247`, this is why:

```sql
begin
  dbms_network_acl_admin.append_host_ace(
      host       => 'smtp.email.<region>.oci.oraclecloud.com'
    , lower_port => 587
    , upper_port => 587
    , ace        => xs$ace_type(privilege_list => xs$name_list('connect')
                              , principal_name => 'APEX_230200'
                              , principal_type => xs_acl.ptype_db));
end;
/
```

Rate limits apply, and they are the reason Automation 3 batches 200 rows and
retries rather than sending inline. **Always Free** instances have tighter limits
still; expect to throttle the outbox drain to a few dozen per run.

`UTL_SMTP` directly is possible but not worth it — you would be reimplementing
queueing, retries and the ACL dance that `APEX_MAIL` already handles.

## Automatic indexing

ATP's automatic indexing runs every 15 minutes and may create, and later drop,
indexes on this schema. Two consequences:

- The manual indexes in `02_tables.sql` are deliberate and should stay. Automatic
  indexing does not consider a table with recent DDL, does not create function
  based indexes, and will not reliably produce the composite index that the inbox
  query needs (`ACTING_APPROVER_ID, STATUS, SLA_DUE_ON`). Explicit indexes on the
  known access paths are still your job.
- If you see an index you did not create, check
  `dba_auto_index_config` / `user_indexes.auto = 'YES'` before deleting it. Do
  not disable automatic indexing to avoid the surprise; it is usually a net win.

Auto-indexing will not fix a missing predicate. The inbox view filters on
`STATUS = 'ACTIVE'` first precisely so the index is selective — the number of
active steps stays small even when `APPROVAL_STEPS` grows to millions.

## Resource management and consumer groups

`escalate_overdue` and `send_reminders` are capped (`p_max_rows`) so an Automation
running in the `TP` consumer group cannot monopolise it after a backlog. On a
1-OCPU Always Free instance, `TP` allows a small number of concurrent statements;
an uncapped sweep over a large backlog will queue user page requests behind it.

If you move the sweeps to DBMS_SCHEDULER instead of APEX Automations, set the job
class to `LOW` so they yield to interactive users.

## Always Free limits worth knowing

| Limit | Effect here |
|---|---|
| 1 OCPU, 20 GB storage | fine for this schema; the audit table is the growth |
| ~2 concurrent `TP` statements | keep Automation batch sizes small |
| Auto-stop after 7 days idle | Automations do not run while stopped; expect gaps |
| No Data Guard / no scaling | not relevant to correctness, relevant to SLA claims |

The 7-day auto-stop is the one that bites: a demo environment that sat over a
holiday will have escalated nothing, and the first sweep after restart will
escalate a fortnight of overdue steps at once. The `p_max_rows` cap keeps that
from becoming an outage; run the sweep repeatedly until it reports zero.

## Attachments in Object Storage

If requisitions carry documents, do not put multi-megabyte BLOBs in
`APPROVAL_REQUESTS`. Put them in OCI Object Storage and keep a reference:

```sql
-- One-time: a credential for the bucket
begin
  dbms_cloud.create_credential(
      credential_name => 'APPROVAL_OBJSTORE'
    , username        => '<oci-user>'
    , password        => '<auth-token>');
end;
/

-- Upload from APEX (APEX_APPLICATION_TEMP_FILES -> Object Storage)
begin
  dbms_cloud.put_object(
      credential_name => 'APPROVAL_OBJSTORE'
    , object_uri      => 'https://objectstorage.<region>.oraclecloud.com/n/<ns>/b/<bucket>/o/'
                         || :P11_REQUEST_ID || '/' || :P11_FILE_NAME
    , contents        => l_blob);
end;
/
```

Store `object_uri` on the request, and generate a **pre-authenticated request**
(PAR) with a short expiry when an approver clicks the link, rather than
proxying the bytes through the database. `DBMS_CLOUD.LIST_OBJECTS` gives you the
attachment list for the detail page.

`DBMS_CLOUD` needs no ACL configuration on ATP — the credential is the
authorisation.

## What to avoid on Autonomous Database

| Avoid | Why | Use instead |
|---|---|---|
| `UTL_FILE` to arbitrary paths | no filesystem; only `DATA_PUMP_DIR` | `DBMS_CLOUD` |
| `UTL_SMTP` for mail | ACL and rate-limit handling you do not want | `APEX_MAIL` |
| `ALTER SYSTEM`, manual tablespaces, `NOLOGGING` | not permitted or silently ignored | managed for you |
| `ORDER`/`NOCACHE` sequences | serialises across RAC instances | `CACHE n NOORDER` (used here) |
| Java stored procedures, external procedures | unsupported | PL/SQL |
| `DBMS_SCHEDULER` external jobs | no OS | Automations or in-database jobs |
| `CREATE DATABASE LINK` without a credential | rejected | `DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK` |
| 23ai-only syntax (`IF NOT EXISTS`, SQL domains, `BOOLEAN` columns) | breaks on 19c ATP | plain 19c DDL (used here) |

The scripts in `sql/` use nothing from that left column.

## 23ai, if you are on it

Three things would simplify this codebase and are deliberately *not* used so the
same scripts install on 19c:

- **SQL domains** would replace several `CHECK ... IN (...)` constraints with a
  named, reusable type — `CREATE DOMAIN approval_status_dom AS VARCHAR2(20)`.
- **`BOOLEAN` columns** would replace the `CHAR(1) Y/N` flags.
- **`IF [NOT] EXISTS`** would make `00_drop_all.sql` and the DDL idempotent
  without the PL/SQL wrapper.

**Blockchain tables** are the interesting one. On 19c (19.10+) and 23ai you can
make the audit log physically append-only rather than trigger-enforced:

```sql
create blockchain table approval_audit ( ... )
  no drop until 31 days idle
  no delete until 16 days after insert
  hashing using sha2_512 version v1;
```

That is genuinely stronger than `TRG_APPROVAL_AUDIT_BUD` — no privilege can
delete a row. It is also unforgiving: you cannot drop the table while the
retention holds, which makes it painful in development. Use the trigger in dev
and the blockchain table in production if your auditors ask for it.

# Runbook

## Importing

1. Build and validate:

   ```bash
   make test-pfg401k build-pfg401k validate-pfg401k
   ```

   Record the `sha256` with the change ticket. Builds are reproducible, so it
   proves later that what is deployed is what was reviewed.

2. **Import the four lookups first.** OIC resolves a lookup at runtime, and
   `dvm:lookupValue` against one that does not exist returns the default on
   every row rather than failing. A file of defaults imports, delivers and
   reconciles — and is entirely wrong. Import the `.iar`'s lookups, or create
   them from `src/icspackage/lookups/`, before the first run.

3. Import the archive. The wizard prompts for the credentials the descriptors
   carry as `${PLACEHOLDER}`:

   | Connection | Prompts for |
   |---|---|
   | `HCM_PRINCIPAL_401K` | Pod host, integration user, password |
   | `SFTP_PRINCIPAL_401K` | Principal's host, host key fingerprint, SFTP user, private key alias |
   | `SMTP_NOTIFY` | Nothing |

4. Register Principal's PGP public key in the OIC certificate store under the
   alias in `pgpPublicKeyAlias`. Nothing about the key is in the archive, and
   the build refuses to package one.

5. Set the integration properties (Integration → Actions → Update Property
   Values). The ones that must change per environment:

   | Property | DEV/TEST | PROD |
   |---|---|---|
   | `environmentName` | `DEV` / `TEST` | `PROD` |
   | `testProductionFlag` | `T` | `P` |
   | `ssnPolicy` | `MASKED` | `FULL` |
   | `pgpEncryptionEnabled` | per Principal's certification profile | `Y` |
   | `remoteDirectory` | their test directory | their production directory |
   | `notifyTo`, `notifyBusinessTo` | your addresses | the rotas |

   `testProductionFlag` defaults to `T` and anything other than an explicit
   `P` is treated as a test transmission. That default is deliberate: a
   misconfigured environment sending a `T` file is a nuisance, sending a `P`
   file posts real money.

6. Activate, then **start the schedule**. Importing an archive does not start
   a schedule; the integration will sit there looking healthy and never run.

### First run in a new environment

Run it by hand before letting the schedule near it:

1. `pgpEncryptionEnabled=N`, `remoteDirectory` pointed at a directory of your
   own, `testProductionFlag=T`.
2. Submit Now with an explicit `runDate`.
3. Fetch the file and check it against
   [`../samples/PFG_401K_LOAN_sample.txt`](../samples/PFG_401K_LOAN_sample.txt):
   record length 200 everywhere, header and trailer contract numbers equal,
   trailer count equal to the number of `D` records.
4. Turn encryption on, point `remoteDirectory` at Principal's certification
   directory, and repeat.
5. Only then start the schedule.

## The email says something went wrong

The subject leads with the verdict. What each one means:

### `OK`

Nothing to do.

### `OK - nothing to send`

No loan repayments in the period, and the policy is `SKIP_SEND`. Normal in a
week with no payroll confirm. If it says this two periods running and you
expect repayments, check that the payroll confirmed — `PFG_401K_PERIOD_DATES`
returns the end-of-time date for an unconfirmed payroll, so the header will
show `47121231`.

### `NO ACTION - duplicate run`

A file for this contract and period is already in Principal's directory.
Nothing was sent, and that is the duplicate guard working. If you genuinely
intended to resend the period, remove the delivered file from their directory
first — and talk to Principal before you do, because they may already have
posted it.

### `ACTION - delivered short`

The file went, but some loans were held back. The rejects are listed in the
email with the employee number, the loan number and the reason. Each is a data
fix in HCM or a lookup row:

| Reason | Fix |
|---|---|
| `MISSING_LOAN_NUMBER` | Populate `EEV_ATTRIBUTE1` on the element entry from Principal's origination advice |
| `UNMAPPED_LOAN_TYPE` | Add the element to the `PFG_401K_LOAN_TYPE` lookup |
| `MISSING_NATIONAL_ID` | Add the primary SSN to the person record |
| `MISSING_NAME` | Fix the person record |
| `AMOUNT_OVERFLOW` | Correct the DFF — almost always a decimal-point slip |
| `MISSING_CONTRACT` | Add the legal employer to `PFG_401K_CONTRACT`, or scope the run |

Fix, then rerun for the same period with `reprocessFlag=N` — the corrected
data has to come out of a fresh extract. The duplicate guard will stop you:
remove the delivered file first, having agreed it with Principal. If the
period is nearly closed, it is usually better to let the next period's file
carry the correction and tell Principal what happened.

### `ACTION - not sent` (reconciliation failed)

The trailer and the formatted file disagree. **Do not rerun** — a rerun
produces the same file. This is a defect in the integration, not the data.

Raise it with integrations. The summary XML in the SFTP archive directory
carries both sets of figures. The usual cause is a change to the layout made
in one of the two implementations and not the other, which `make test-pfg401k`
would have caught.

### `FAILED - not sent`

Check `FaultCategory` in the summary.

**BUSINESS** — extract failed, extract warned, or the output was not in UCM.
The benefits team is already on the email.

- *Extract failed*: check the process results in HCM. Fix, rerun with
  `reprocessFlag=N`.
- *Extract warned*: the extract completed with records in error, so the file
  would be short by exactly those rows. Review the process results before
  rerunning.
- *No UCM document*: the extract's delivery option is misconfigured, or it is
  writing to a different account than `ucmAccount`.
- *Gave up waiting*: **the extract may still be running.** Check it in HCM
  before doing anything. Resubmitting while it runs produces two outputs for
  one period. Once it completes, rerun with `reprocessFlag=Y`.

**TECHNICAL** — connectivity, API or runtime. Fix the platform problem, then
read the summary's `StatusDetail`: it says whether the extract output was
retrieved and therefore whether to rerun with `reprocessFlag=Y` or `N`.

Rerunning with `Y` matters. It reuses the output this run was working from
rather than asking HCM to recompute a period it has already partly reported
on, which can return a different answer if anything was corrected in between.

## Reruns

| Situation | `reprocessFlag` | Why |
|---|---|---|
| Delivery failed, extract succeeded | `Y` | Do not recompute a reported period |
| Data fixed in HCM | `N` | The correction has to come out of a fresh extract |
| Extract failed | `N` | There is no output to reuse |
| Timed out, extract since completed | `Y` | The output exists; a resubmission would duplicate it |

Always pass an explicit `runDate` on a rerun. Blank means today, and today is
not the period you are rerunning.

The extract archive is retained 90 days. Past that, `reprocessFlag=Y` finds
nothing and the run fails at step 65.

## Producing a file without OIC

If OIC is unavailable and Principal needs the file, it can be produced from
HCM alone through the eText template. This route skips the duplicate guard,
the reconciliation, the PGP step and the temp-then-rename handshake, so all
four have to be done by hand.

1. Enable the `Principal 401K Loans eText to UCM` delivery option on the
   extract. **Disable the XML option while you do** — two enabled options
   means two documents in UCM and a step 60 search that can pick the wrong
   one.
2. Submit the extract with the period's effective date, supplying the contract
   number, sender id and test/production flag as report parameters. Check the
   contract number against `PFG_401K_CONTRACT` before you submit; a typo
   routes the file to another employer's plan.
3. Download the output from UCM.
4. Check it by hand: every record 200 characters, header and trailer contract
   numbers equal, trailer count equal to the number of `D` records, trailer
   totals equal to the sum of the detail columns. `python3
   tools/generate_principal_file.py` on the same extract output gives you
   something to diff against.
5. Confirm with Principal that a file for this contract and period has not
   already been delivered.
6. Encrypt with their public key.
7. Upload as `<name>.tmp`, then rename. Do not copy it straight in under the
   final name — their poller will collect it half-written.
8. Re-enable the XML delivery option and disable the eText one.

The layout in the RTF is a second, hand-maintained copy of the mapping
including the loan type codes; treat anything it produces as needing the
checks above.

## Measuring the extract

The extract's threading and chunking figures are a starting point for a
population of roughly 40,000 workers with about 1,800 loans, not a law.

Check them against the real thing: Payroll → Processes and Reports → Process
Results, find the extract run, and compare its elapsed time against the
`expectedRuntimeMinutes` in
[`../hcm-extract/PRINCIPAL_401K_LOANS_EXTRACT.xml`](../hcm-extract/PRINCIPAL_401K_LOANS_EXTRACT.xml).

If it is materially slower:

- **Chunk size** first. 500 is Oracle's figure for a population this size; a
  much larger population wants larger chunks, a much smaller one wants
  smaller.
- **Thread count** second, and only if the pod has the capacity. Threading
  splits on legal employer, so more threads than legal employers buys nothing.
- **Then look at the filters.** The most common cause of a slow payroll
  interface extract is a data group whose criteria do not restrict at the top
  of the hierarchy, so every worker in the pod is walked and discarded.

`maxPollAttempts` of 40 with the default backoff allows a little over three
hours, which is deliberately generous. A run taking fifteen times its baseline
is a pod problem, and the file being late is better than the file being
resubmitted while the first attempt is still running.

## Rotating the SFTP key or Principal's PGP key

Neither is in the archive, so neither needs a rebuild.

- **SFTP key**: register the new key in the OIC certificate store, update
  `privateKeyAlias` on the `SFTP_PRINCIPAL_401K` connection, test the
  connection, run once by hand before the next scheduled run.
- **PGP key**: register the new public key, update the `pgpPublicKeyAlias`
  property. Principal issues a new key with an overlap window — use it, and
  confirm with them that they have decrypted a file with the new key before
  the old one expires. A file encrypted to an expired key is not recoverable
  by us; we hold their public key, not their private one.

The same is true of the archive: step 210 archives the **cleartext** file
deliberately, so a dispute can be answered by reading what we sent.

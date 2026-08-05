# Deployment and migration checklist

Work top to bottom. Each section gates the ones after it — the HCM side has to
exist before the extract can read it, and the extract has to produce output
before the integration has anything to fetch.

## 1. HCM configuration

| # | Item | Where | Done |
|---|---|---|---|
| 1.1 | Loan repayment elements exist, classification `Voluntary Deductions`, named `401k Loan Repayment*` | Payroll → Elements | ☐ |
| 1.2 | Descriptive flexfield context `PFG 401K Loan` on the element entry, with `EEV_ATTRIBUTE1` (loan number), `EEV_ATTRIBUTE2` (origination date), `EEV_ATTRIBUTE3` (original amount) | Setup → Flexfields | ☐ |
| 1.3 | DFF **deployed**, not merely defined | Setup → Deploy Flexfield | ☐ |
| 1.4 | Balance `401k Loan Repayment` with an **element-entry-level** inception-to-date dimension | Payroll → Balance Definitions | ☐ |
| 1.5 | Existing loans backfilled with their loan number, origination date and original amount | Data fix | ☐ |
| 1.6 | Every participant has a primary national identifier of type `SSN` | Person records | ☐ |

1.4 is the one to check twice. An assignment-level ITD dimension reports the
sum of both loans against each of a participant's two concurrent loans, and it
looks correct until somebody has two.

1.5 is usually the largest piece of work in the whole deployment. Without it
every loan rejects with `MISSING_LOAN_NUMBER` on the first run.

## 2. Fast formulas

Compile in this order; the extract will not validate before they exist.

| # | Formula | Type | Done |
|---|---|---|---|
| 2.1 | `PFG_401K_PERIOD_DATES` | Extract Rule | ☐ |
| 2.2 | `PFG_401K_LOAN_ELIGIBILITY` | Extract Rule | ☐ |
| 2.3 | `PFG_401K_LOAN_BALANCE` | Extract Rule | ☐ |
| 2.4 | `PFG_401K_LOAN_PAYOFF` | Extract Rule | ☐ |
| 2.5 | `PFG_401K_LOAN_STATUS` | Extract Rule | ☐ |

Source is in [`../hcm-extract/fast-formulas/`](../hcm-extract/fast-formulas/).
The database item names they reference — `X_401K_LOAN_REPAYMENT_EE_ITD` and
the rest — depend on how the balance in 1.4 was named. Confirm each against
the pod rather than assuming; a `DEFAULT FOR` on a database item that does not
exist compiles and returns the default forever.

## 3. HCM Extract

| # | Item | Where | Done |
|---|---|---|---|
| 3.1 | Extract `Principal 401K Loans Outbound`, code `PFG_401K_LOANS_OUT`, defined per [the design](../hcm-extract/PRINCIPAL_401K_LOANS_EXTRACT.xml) | Data Exchange → Extract Definitions | ☐ |
| 3.2 | Tag names match `loan-extract.xsd` **exactly** | Extract attributes | ☐ |
| 3.3 | Data model `PFG_401K_LOANS_DM` uploaded, scalable mode on | BI catalogue | ☐ |
| 3.4 | Delivery option `Principal 401K Loans XML to UCM` enabled, account and title prefix set | Extract delivery | ☐ |
| 3.5 | eText delivery option present and **disabled** | Extract delivery | ☐ |
| 3.6 | Extract compiled and validated | Data Exchange | ☐ |
| 3.7 | Submitted once by hand; output visible in UCM | Payroll → Submit | ☐ |

3.2 is load-bearing and silent. A renamed tag produces a file with a header, a
trailer and no participants — which reconciles and delivers.

3.5 matters because two enabled delivery options means two UCM documents and a
step 60 search that can pick the wrong one.

## 4. Security

The integration user needs all of these. A missing data-role grant does not
fail anything — it produces a smaller file.

| # | Role or privilege | Purpose | Done |
|---|---|---|---|
| 4.1 | `Human Capital Management Integration Specialist` | Baseline integration access | ☐ |
| 4.2 | `Payroll Interface Coordinator` | Submit and monitor the extract | ☐ |
| 4.3 | `Compensation Administrator` (or equivalent) | Element entry data | ☐ |
| 4.4 | `Attachments User` | UCM read and write | ☐ |
| 4.5 | Privilege `Run Payroll Interface Extract` | ESS submission | ☐ |
| 4.6 | Privilege `Manage Payroll Element Entry` | Element entries and their DFF | ☐ |
| 4.7 | Privilege `View Person National Identifier` | The SSN column | ☐ |
| 4.8 | Privilege `Manage Extract Definition` | Only for the person building the extract | ☐ |
| 4.9 | Payroll data role covering **every** legal employer in `PFG_401K_CONTRACT` | Scope | ☐ |
| 4.10 | Account is a dedicated integration account, not a named person's | A leaver disabling it takes the remittance down | ☐ |
| 4.11 | Password rotation scheduled and someone owns it | Expiry mid-quarter is a silent outage | ☐ |

Verify 4.9 by counting: run the extract for each legal employer separately and
check the totals sum to the all-employer run. A data role missing one employer
is invisible in a single run.

## 5. Principal onboarding

Nothing below is ours to decide. Each is a question for Principal's
implementation contact, and each has a corresponding setting.

| # | Confirm with Principal | Sets | Done |
|---|---|---|---|
| 5.1 | **The file specification** — layout, positions, formats | The whole of `map_canonical_to_principal.xsl`; see [`field-mapping.md`](field-mapping.md#adjusting-to-the-real-spec) | ☐ |
| 5.2 | Contract number per legal employer | `PFG_401K_CONTRACT` | ☐ |
| 5.3 | Sender id | `senderId` | ☐ |
| 5.4 | Layout version | `fileVersion` | ☐ |
| 5.5 | Loan type codes | `PFG_401K_LOAN_TYPE` | ☐ |
| 5.6 | Loan status codes | `PFG_401K_LOAN_STATUS` | ☐ |
| 5.7 | Source codes per payroll | `PFG_401K_SOURCE_CODE` | ☐ |
| 5.8 | File naming convention | Step 130 | ☐ |
| 5.9 | Temp-then-rename, or a trigger file? | `tempSuffix`, `triggerFileEnabled` | ☐ |
| 5.10 | Zero-record handling: empty file or no file? | `zeroRecordPolicy` | ☐ |
| 5.11 | PGP required? Public key and its expiry | `pgpEncryptionEnabled`, `pgpPublicKeyAlias` | ☐ |
| 5.12 | Armored or binary? | `pgpArmored` | ☐ |
| 5.13 | Collection window and expected frequency | The schedule | ☐ |
| 5.14 | SFTP host, port, inbound directory, host key fingerprint | `SFTP_PRINCIPAL_401K` | ☐ |
| 5.15 | Certification directory, distinct from production | `remoteDirectory` per environment | ☐ |
| 5.16 | Where their exception report goes, and who reads it | Operational | ☐ |

5.1 first. Everything else is configuration; that one is code.

## 6. OIC

| # | Item | Done |
|---|---|---|
| 6.1 | `make test-pfg401k build-pfg401k validate-pfg401k` green; `sha256` recorded with the change ticket | ☐ |
| 6.2 | Four lookups imported **before** the integration | ☐ |
| 6.3 | Archive imported; three connections configured and tested | ☐ |
| 6.4 | SFTP host key fingerprint pinned — not left blank | ☐ |
| 6.5 | SFTP private key registered; alias matches the descriptor | ☐ |
| 6.6 | Principal's PGP public key registered under `pgpPublicKeyAlias` | ☐ |
| 6.7 | Integration properties set for this environment | ☐ |
| 6.8 | `testProductionFlag` is `P` **only** in production | ☐ |
| 6.9 | `ssnPolicy` is `FULL` in production, `MASKED` elsewhere | ☐ |
| 6.10 | `notifyTo` and `notifyBusinessTo` point at rotas, not individuals | ☐ |
| 6.11 | Integration activated | ☐ |
| 6.12 | Schedule started — importing does not start it | ☐ |
| 6.13 | Tracking fields visible in the monitor (`runId`, `requestId`, `targetFileName`) | ☐ |

6.4 is not optional in production. Without a pinned fingerprint the first
connection to an impostor host succeeds silently, and this file carries
national identifiers.

## 7. Before the first production run

| # | Item | Done |
|---|---|---|
| 7.1 | SIT cases T1–T24 in [`test-cases.md`](test-cases.md) passed | ☐ |
| 7.2 | Principal has accepted a certification file (U1–U8) | ☐ |
| 7.3 | Principal's reconciliation matched our trailer (U2) — the one that matters | ☐ |
| 7.4 | A dry run in production with `testProductionFlag=T`, delivered to their certification directory | ☐ |
| 7.5 | Rollback agreed: who calls Principal, and how a wrongly posted period is unwound | ☐ |
| 7.6 | Somebody owns the weekly notification and knows what each verdict means | ☐ |
| 7.7 | Runbook read by whoever is on call, not just filed | ☐ |

## 8. Environment migration

Moving between pods and instances, in order:

1. Export the extract definition from the source pod (Data Exchange →
   Export), import into the target. Fast formulas move with it; **database
   item references do not resolve automatically** — recompile each formula in
   the target and check for unresolved items.
2. Upload the data model and, if used, the eText template to the target BI
   catalogue.
3. Rebuild the `.iar` from this repository. Do not export it from the source
   instance: an instance export carries that instance's connection state, and
   the whole point of building from source is that the archive is identical
   everywhere.
4. Import the lookups, then the archive.
5. Set the integration properties for the target environment. Re-check
   `testProductionFlag`, `ssnPolicy`, `remoteDirectory` and the notification
   addresses every time — these are the four that cause an incident when they
   carry over.
6. Re-register the SFTP key and Principal's PGP key. Certificate stores are
   per instance.
7. Run section 7 again in the new environment.

Nothing environment-specific is in the archive, which is what makes 3
possible. If a value needs to differ between environments and is not an
integration property or a lookup row, that is a defect — raise it rather than
editing the archive.

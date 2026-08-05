"""Status derivation in map_status_to_summary.xsl.

A delivery has more outcomes than "worked" and "did not", and collapsing them
is how a feed goes quietly wrong. Each of these asserts one outcome stays
distinct:

    DELIVERED               file sent, trailer and details agree
    DELIVERED_WITH_REJECTS  file sent, but short by the rejected rows
    RECONCILIATION_FAILED   file built and found inconsistent; nothing sent
    ALREADY_DELIVERED       duplicate run, nothing sent, nobody paged
    NO_RECORDS_SKIPPED      nothing to send under a SKIP_SEND policy
    FAILED                  everything else

Skipped when lxml is unavailable, so the suite still runs on a bare
interpreter.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    etree = None

HERE = os.path.dirname(__file__)
MAPS = os.path.join(
    HERE, "..", "src", "icspackage", "project", "PRINCIPAL_401K_LOANS_01.00.0000",
    "resources", "processor_10", "resourcegroup_10", "maps",
)

CAN_NS = "http://xmlns.oracle.com/hcm/principal401k/canonical"
SUM_NS = "http://xmlns.oracle.com/hcm/principal401k/summary"
NOT_NS = "http://xmlns.oracle.com/hcm/principal401k/notification"


def canonical_document(detail_count=2, repayment=25000, outstanding=90000,
                       rejects=()):
    reject_nodes = "".join(f"""
  <Reject>
    <EmployeeId>{employee}</EmployeeId>
    <LoanNumber>LN1</LoanNumber>
    <Reason>{reason}</Reason>
    <Message>{reason} on employee {employee}</Message>
  </Reject>""" for employee, reason in rejects)

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<LoanBatch xmlns="{CAN_NS}">
  <RunId>PFG401K-TEST</RunId>
  <ContractNumber>40012345</ContractNumber>
  <PayPeriodEndDate>20260228</PayPeriodEndDate>
  <CheckDate>20260305</CheckDate>
  <Totals>
    <DetailCount>{detail_count}</DetailCount>
    <TotalRepaymentCents>{repayment}</TotalRepaymentCents>
    <TotalPayoffCents>0</TotalPayoffCents>
    <TotalOutstandingCents>{outstanding}</TotalOutstandingCents>
  </Totals>{reject_nodes}
</LoanBatch>
"""


def summarise(canonical_xml, **params):
    transform = etree.XSLT(etree.parse(
        os.path.join(MAPS, "map_status_to_summary.xsl")))
    defaults = {
        "runId": "PFG401K-TEST",
        "environmentName": "TEST",
        "runStartTime": "2026-03-02T05:00:00Z",
        "runEndTime": "2026-03-02T05:04:00Z",
        "extractName": "Principal 401K Loans Outbound",
        "requestId": "123456",
        "contentId": "UCMFA000123",
        "targetFileName": "PFG_401K_LOAN_40012345_20260228_050000.txt",
    }
    defaults.update(params)
    return transform(
        etree.fromstring(canonical_xml.encode("utf-8")),
        **{key: etree.XSLT.strparam(str(value))
           for key, value in defaults.items()})


def field(summary, name):
    found = summary.getroot().find(f"{{{SUM_NS}}}{name}")
    return (found.text or "") if found is not None else None


def count(summary, name):
    counts = summary.getroot().find(f"{{{SUM_NS}}}Counts")
    found = counts.find(f"{{{SUM_NS}}}{name}")
    return (found.text or "") if found is not None else None


@unittest.skipIf(etree is None, "lxml not installed")
class TestStatusDerivation(unittest.TestCase):

    def test_a_clean_delivery(self):
        summary = summarise(
            canonical_document(),
            deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=25000,
            actualOutstandingCents=90000)
        self.assertEqual(field(summary, "Status"), "DELIVERED")
        self.assertEqual(count(summary, "Reconciled"), "true")

    def test_rejects_downgrade_a_successful_delivery(self):
        """The file went out short. Green would be a lie: the rejected rows
        will not post until somebody fixes the record in HCM."""
        summary = summarise(
            canonical_document(rejects=[("100510", "MISSING_LOAN_NUMBER")]),
            deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=25000,
            actualOutstandingCents=90000)
        self.assertEqual(field(summary, "Status"), "DELIVERED_WITH_REJECTS")
        self.assertEqual(count(summary, "Rejected"), "1")

    def test_a_reconciliation_failure_is_not_just_FAILED(self):
        """It needs its own status because the response differs: a rerun
        produces the same file, so rerunning is the wrong instinct."""
        summary = summarise(
            canonical_document(),
            deliveryStatus="FAILED", faultCategory="BUSINESS",
            faultMessage=("Trailer claims 2 rows totalling 25000 cents; the "
                          "formatted file contains 1 rows totalling 12500 "
                          "cents. Nothing was delivered."),
            actualDetailCount=1, actualRepaymentCents=12500,
            actualOutstandingCents=90000)
        self.assertEqual(field(summary, "Status"), "RECONCILIATION_FAILED")
        self.assertEqual(count(summary, "Reconciled"), "false")

    def test_a_duplicate_run_is_reported_not_failed(self):
        summary = summarise(canonical_document(),
                            deliveryStatus="ALREADY_DELIVERED")
        self.assertEqual(field(summary, "Status"), "ALREADY_DELIVERED")
        self.assertIn("duplicate", field(summary, "StatusDetail"))

    def test_nothing_to_send_under_skip_send(self):
        summary = summarise(canonical_document(detail_count=0, repayment=0,
                                               outstanding=0),
                            deliveryStatus="NO_RECORDS_SKIPPED")
        self.assertEqual(field(summary, "Status"), "NO_RECORDS_SKIPPED")

    def test_a_fault_beats_whatever_the_happy_path_had_reached(self):
        summary = summarise(canonical_document(),
                            deliveryStatus="FAILED",
                            faultCategory="TECHNICAL",
                            faultMessage="Connection refused")
        self.assertEqual(field(summary, "Status"), "FAILED")
        self.assertEqual(field(summary, "FaultCategory"), "TECHNICAL")

    def test_a_run_that_reached_nothing_is_not_started(self):
        summary = summarise(canonical_document())
        self.assertEqual(field(summary, "Status"), "NOT_STARTED")


@unittest.skipIf(etree is None, "lxml not installed")
class TestReconciliationReporting(unittest.TestCase):

    def test_a_count_mismatch_is_not_reconciled(self):
        summary = summarise(canonical_document(detail_count=2),
                            deliveryStatus="DELIVERED",
                            actualDetailCount=1, actualRepaymentCents=25000,
                            actualOutstandingCents=90000)
        self.assertEqual(count(summary, "Reconciled"), "false")

    def test_a_total_mismatch_is_not_reconciled(self):
        summary = summarise(canonical_document(repayment=25000),
                            deliveryStatus="DELIVERED",
                            actualDetailCount=2, actualRepaymentCents=24999,
                            actualOutstandingCents=90000)
        self.assertEqual(count(summary, "Reconciled"), "false")

    def test_a_reconciliation_that_never_ran_says_N_A_not_false(self):
        """A fault before the file was formatted would otherwise be
        indistinguishable from a genuine mismatch, and the two need very
        different responses."""
        summary = summarise(canonical_document(),
                            deliveryStatus="FAILED",
                            faultCategory="TECHNICAL",
                            faultMessage="Extract request failed")
        self.assertEqual(count(summary, "Reconciled"), "N/A")

    def test_a_fault_message_outranks_the_reconciliation_note(self):
        """Both are true; only one is worth the first line of the detail."""
        summary = summarise(canonical_document(),
                            deliveryStatus="FAILED",
                            faultCategory="TECHNICAL",
                            faultMessage="Connection refused by SFTP host")
        self.assertTrue(field(summary, "StatusDetail").startswith(
            "Connection refused by SFTP host"))

    def test_the_defensive_fallback_when_nothing_else_applies(self):
        """Reachable only if the file was delivered without the
        reconciliation step running, which the flow does not do. It is here so
        that state reports itself rather than reading as reconciled."""
        summary = summarise(canonical_document(),
                            deliveryStatus="DELIVERED")
        self.assertEqual(count(summary, "Reconciled"), "N/A")
        self.assertEqual(field(summary, "StatusDetail"),
                         "Reconciliation did not run.")

    def test_both_sides_of_every_comparison_are_reported(self):
        """A reader should be able to see the figures agreed, not be told."""
        summary = summarise(canonical_document(),
                            deliveryStatus="DELIVERED",
                            actualDetailCount=2, actualRepaymentCents=25000,
                            actualOutstandingCents=90000)
        for name in ["TrailerDetailCount", "ActualDetailCount",
                     "TrailerRepaymentCents", "ActualRepaymentCents",
                     "TrailerOutstandingCents", "ActualOutstandingCents"]:
            self.assertIsNotNone(count(summary, name), name)


@unittest.skipIf(etree is None, "lxml not installed")
class TestRerunAdvice(unittest.TestCase):
    """Whether a rerun may reuse the extract output is not something to work
    out at 05:00 from a fault name."""

    def test_a_fault_after_retrieval_advises_reprocess(self):
        summary = summarise(canonical_document(),
                            deliveryStatus="FAILED",
                            faultCategory="TECHNICAL",
                            faultMessage="SFTP write failed",
                            contentId="UCMFA000123",
                            reprocessSafe="true")
        self.assertIn("reprocessFlag=Y", field(summary, "StatusDetail"))

    def test_a_fault_before_retrieval_advises_a_fresh_extract(self):
        summary = summarise(canonical_document(),
                            deliveryStatus="FAILED",
                            faultCategory="BUSINESS",
                            faultMessage="Extract request 123456 failed",
                            contentId="", reprocessSafe="false")
        self.assertIn("reprocessFlag=N", field(summary, "StatusDetail"))


@unittest.skipIf(etree is None, "lxml not installed")
class TestNotification(unittest.TestCase):
    """The email a person actually reads."""

    def notify(self, summary):
        transform = etree.XSLT(etree.parse(
            os.path.join(MAPS, "map_summary_to_notification.xsl")))
        result = transform(summary,
                           environmentName=etree.XSLT.strparam("PROD"))
        root = result.getroot()
        return (root.findtext(f"{{{NOT_NS}}}Subject"),
                root.findtext(f"{{{NOT_NS}}}Body"))

    def test_the_subject_leads_with_the_verdict(self):
        subject, _ = self.notify(summarise(
            canonical_document(), deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=25000,
            actualOutstandingCents=90000))
        self.assertTrue(subject.startswith("[PROD] Principal 401(k) loans: OK"))
        self.assertIn("40012345", subject)
        self.assertIn("20260228", subject)

    def test_a_short_delivery_says_ACTION_in_the_subject(self):
        """Phone previews and mail filters both truncate; the word that has
        to survive truncation is the one that says whether to get up."""
        subject, _ = self.notify(summarise(
            canonical_document(rejects=[("100510", "MISSING_LOAN_NUMBER")]),
            deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=25000,
            actualOutstandingCents=90000))
        self.assertIn("ACTION", subject)

    def test_amounts_are_readable_not_cents(self):
        _, body = self.notify(summarise(
            canonical_document(repayment=499852), deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=499852,
            actualOutstandingCents=90000))
        self.assertIn("4,998.52", body)

    def test_the_body_carries_no_national_identifiers_or_names(self):
        """Email is not an encrypted channel, and this feed exists precisely
        because the data is sensitive."""
        _, body = self.notify(summarise(
            canonical_document(rejects=[("100510", "MISSING_NATIONAL_ID"),
                                        ("100512", "UNMAPPED_LOAN_TYPE")]),
            deliveryStatus="DELIVERED",
            actualDetailCount=2, actualRepaymentCents=25000,
            actualOutstandingCents=90000))
        import re
        self.assertIsNone(re.search(r"\b\d{3}-\d{2}-\d{4}\b", body))
        self.assertIsNone(re.search(r"\b\d{9}\b", body))
        # The employee number is there, because it is what somebody needs to
        # find the record in HCM, and is not a disclosure on its own.
        self.assertIn("100510", body)

    def test_a_reconciliation_failure_says_not_to_rerun(self):
        _, body = self.notify(summarise(
            canonical_document(), deliveryStatus="FAILED",
            faultCategory="BUSINESS",
            faultMessage="Trailer claims 2 rows totalling 25000 cents; the "
                         "formatted file contains 1 rows totalling 12500 "
                         "cents. Nothing was delivered.",
            actualDetailCount=1, actualRepaymentCents=12500,
            actualOutstandingCents=90000))
        self.assertIn("do not rerun", body)

    def test_a_duplicate_run_reads_as_no_action(self):
        subject, body = self.notify(summarise(
            canonical_document(), deliveryStatus="ALREADY_DELIVERED"))
        self.assertIn("NO ACTION", subject)
        self.assertIn("duplicate guard", body)


if __name__ == "__main__":
    unittest.main()

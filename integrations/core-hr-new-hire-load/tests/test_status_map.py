"""Tests for the status-derivation map.

The rule that matters: HDL says COMPLETED whenever the import process
finished, including a run where every row errored. These tests pin down the
translation from HDL's status to the outcome operations actually acts on.
"""

import os
import unittest

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    etree = None

HERE = os.path.dirname(__file__)
MAPS = os.path.join(
    HERE, "..", "src", "icspackage", "project", "NEW_HIRE_LOAD_01.00.0000",
    "resources", "processor_10", "resourcegroup_10", "maps",
)

HCM_NS = "http://xmlns.oracle.com/apps/hcm/dataLoader/status"
SUM_NS = "http://xmlns.oracle.com/hcm/newhire/summary"
NTF_NS = "http://xmlns.oracle.com/hcm/newhire/notification"


def status_doc(import_status, success=0, error=0, message=""):
    root = etree.Element("{%s}DataSetStatus" % HCM_NS, nsmap={"hcm": HCM_NS})
    etree.SubElement(root, "{%s}ImportStatus" % HCM_NS).text = import_status
    etree.SubElement(root, "{%s}ProcessId" % HCM_NS).text = "300000123456789"
    etree.SubElement(root, "{%s}DataSetName" % HCM_NS).text = "Worker.zip"
    etree.SubElement(root, "{%s}SuccessRowCount" % HCM_NS).text = str(success)
    etree.SubElement(root, "{%s}ErrorRowCount" % HCM_NS).text = str(error)
    if message:
        etree.SubElement(root, "{%s}ErrorMessage" % HCM_NS).text = message
    return etree.ElementTree(root)


def to_summary(doc, **params):
    xslt = etree.XSLT(etree.parse(os.path.join(MAPS, "map_status_to_summary.xsl")))
    kwargs = {k: etree.XSLT.strparam(str(v)) for k, v in params.items()}
    return xslt(doc, **kwargs)


def text_at(result, ns, tag):
    node = result.getroot().find(".//{%s}%s" % (ns, tag))
    return None if node is None else (node.text or "")


@unittest.skipIf(etree is None, "lxml not installed")
class TestStatusDerivation(unittest.TestCase):

    def test_clean_run_is_completed(self):
        result = to_summary(status_doc("COMPLETED", success=5, error=0))
        self.assertEqual(text_at(result, SUM_NS, "Status"), "COMPLETED")

    def test_partial_failure_is_flagged_not_hidden(self):
        result = to_summary(status_doc("COMPLETED", success=3, error=2))
        self.assertEqual(text_at(result, SUM_NS, "Status"),
                         "COMPLETED_WITH_ERRORS")

    def test_completed_with_nothing_loaded_is_a_failure(self):
        # The case this map exists for: HDL calls it COMPLETED, but not one
        # hire made it into Core HR.
        result = to_summary(status_doc("COMPLETED", success=0, error=5))
        self.assertEqual(text_at(result, SUM_NS, "Status"), "FAILED")

    def test_hdl_error_is_a_failure(self):
        for raw in ("ERROR", "FAILED"):
            result = to_summary(status_doc(raw, success=0, error=0))
            self.assertEqual(text_at(result, SUM_NS, "Status"), "FAILED", raw)

    def test_still_running_is_in_progress(self):
        result = to_summary(status_doc("IN_PROGRESS"))
        self.assertEqual(text_at(result, SUM_NS, "Status"), "IN_PROGRESS")

    def test_timeout_overrides_whatever_hdl_last_said(self):
        result = to_summary(status_doc("IN_PROGRESS"), timedOut="true")
        self.assertEqual(text_at(result, SUM_NS, "Status"), "TIMED_OUT")

    def test_empty_status_is_not_started(self):
        result = to_summary(status_doc(""))
        self.assertEqual(text_at(result, SUM_NS, "Status"), "NOT_STARTED")

    def test_counts_and_identifiers_carried_through(self):
        result = to_summary(
            status_doc("COMPLETED", success=4, error=1),
            batchId="B1", sourceFileName="NEWHIRE_20260804.csv",
            contentId="UCMFA00123456", sourceRows=6, accepted=5,
            rejectedInFlight=1,
        )
        self.assertEqual(text_at(result, SUM_NS, "BatchId"), "B1")
        self.assertEqual(text_at(result, SUM_NS, "ContentId"), "UCMFA00123456")
        self.assertEqual(text_at(result, SUM_NS, "ProcessId"), "300000123456789")
        self.assertEqual(text_at(result, SUM_NS, "SourceRows"), "6")
        self.assertEqual(text_at(result, SUM_NS, "Accepted"), "5")
        self.assertEqual(text_at(result, SUM_NS, "RejectedInFlight"), "1")
        self.assertEqual(text_at(result, SUM_NS, "LoadedByHdl"), "4")
        self.assertEqual(text_at(result, SUM_NS, "FailedInHdl"), "1")

    def test_hdl_error_details_become_rejects(self):
        doc = status_doc("COMPLETED", success=1, error=1)
        detail = etree.SubElement(doc.getroot(), "{%s}ErrorDetail" % HCM_NS)
        etree.SubElement(detail, "{%s}SourceSystemId" % HCM_NS).text = "WKR_100502"
        etree.SubElement(detail, "{%s}ObjectName" % HCM_NS).text = "Assignment"
        etree.SubElement(detail, "{%s}Message" % HCM_NS).text = "Invalid JobCode"
        result = to_summary(doc)
        rejects = result.getroot().findall("{%s}Reject" % SUM_NS)
        self.assertEqual(len(rejects), 1)
        self.assertEqual(text_at(result, SUM_NS, "Stage"), "HDL")
        self.assertIn("Invalid JobCode", text_at(result, SUM_NS, "Message"))


@unittest.skipIf(etree is None, "lxml not installed")
class TestNotification(unittest.TestCase):

    def notify(self, summary_result, **params):
        xslt = etree.XSLT(etree.parse(
            os.path.join(MAPS, "map_summary_to_notification.xsl")))
        kwargs = {k: etree.XSLT.strparam(str(v)) for k, v in params.items()}
        return xslt(summary_result, **kwargs)

    def test_subject_carries_environment_outcome_and_counts(self):
        summary = to_summary(
            status_doc("COMPLETED", success=4, error=1),
            sourceFileName="NEWHIRE_20260804.csv", rejectedInFlight=2)
        result = self.notify(summary, environmentName="PROD")
        subject = text_at(result, NTF_NS, "Subject")
        self.assertIn("[PROD]", subject)
        self.assertIn("COMPLETED_WITH_ERRORS", subject)
        self.assertIn("4 loaded", subject)
        self.assertIn("3 rejected", subject)  # 1 in HDL + 2 in flight
        self.assertIn("NEWHIRE_20260804.csv", subject)

    def test_clean_run_says_no_action_required(self):
        summary = to_summary(status_doc("COMPLETED", success=5))
        body = text_at(self.notify(summary), NTF_NS, "Body")
        self.assertIn("No action required", body)
        self.assertNotIn("ACTION:", body)

    def test_failure_body_tells_the_reader_what_to_do(self):
        summary = to_summary(status_doc("COMPLETED", success=0, error=5))
        body = text_at(self.notify(summary), NTF_NS, "Body")
        self.assertIn("ACTION:", body)
        self.assertIn("merge rather than duplicate", body)

    def test_timeout_body_warns_against_blind_resubmission(self):
        summary = to_summary(status_doc("IN_PROGRESS"), timedOut="true")
        body = text_at(self.notify(summary), NTF_NS, "Body")
        self.assertIn("loaded twice", body)

    def test_reject_list_is_truncated_with_a_pointer_to_the_full_file(self):
        doc = status_doc("COMPLETED", success=0, error=4)
        for i in range(4):
            detail = etree.SubElement(doc.getroot(), "{%s}ErrorDetail" % HCM_NS)
            etree.SubElement(detail, "{%s}SourceSystemId" % HCM_NS).text = f"WKR_{i}"
            etree.SubElement(detail, "{%s}ObjectName" % HCM_NS).text = "Worker"
            etree.SubElement(detail, "{%s}Message" % HCM_NS).text = "bad"
        summary = to_summary(doc)
        body = text_at(self.notify(summary, maxRejectsShown=2), NTF_NS, "Body")
        self.assertIn("WKR_0", body)
        self.assertNotIn("WKR_3", body)
        self.assertIn("and 2 more", body)

    def test_full_reject_list_shown_when_under_the_cap(self):
        doc = status_doc("COMPLETED", success=0, error=2)
        for i in range(2):
            detail = etree.SubElement(doc.getroot(), "{%s}ErrorDetail" % HCM_NS)
            etree.SubElement(detail, "{%s}SourceSystemId" % HCM_NS).text = f"WKR_{i}"
            etree.SubElement(detail, "{%s}ObjectName" % HCM_NS).text = "Worker"
            etree.SubElement(detail, "{%s}Message" % HCM_NS).text = "bad"
        summary = to_summary(doc)
        body = text_at(self.notify(summary, maxRejectsShown=25), NTF_NS, "Body")
        self.assertIn("WKR_1", body)
        self.assertNotIn("more;", body)


if __name__ == "__main__":
    unittest.main()

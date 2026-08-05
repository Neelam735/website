<?xml version="1.0" encoding="UTF-8"?>
<!--
  Canonical loan batch + run context -> DeliverySummary.

  One map for both the success path (step 220) and the fault handler (F4), so
  a failed run leaves the same shaped record as a successful one and the audit
  trail has no gaps in it. The fault handler passes deliveryStatus='FAILED'
  and a faultCategory; everything else is whatever the run had reached.

  Status is derived, not taken on trust. "The SFTP put returned success" and
  "Principal received the right file" are different claims, and only the
  second one matters at the end of the month. The reconciliation figures are
  carried in the summary next to each other for exactly that reason: a reader
  can see that the trailer's count and the count of formatted rows agreed,
  rather than being told they did.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:can="http://xmlns.oracle.com/hcm/principal401k/canonical"
    xmlns:sum="http://xmlns.oracle.com/hcm/principal401k/summary"
    exclude-result-prefixes="can">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="runId" select="''"/>
  <xsl:param name="environmentName" select="''"/>
  <xsl:param name="runStartTime" select="''"/>
  <xsl:param name="runEndTime" select="''"/>

  <xsl:param name="extractName" select="''"/>
  <xsl:param name="requestId" select="''"/>
  <xsl:param name="contentId" select="''"/>
  <xsl:param name="reprocessed" select="'false'"/>

  <xsl:param name="targetFileName" select="''"/>
  <xsl:param name="archiveFileName" select="''"/>
  <xsl:param name="encrypted" select="'false'"/>
  <xsl:param name="fileSizeBytes" select="0"/>

  <!-- Set by the flow: DELIVERED, DELIVERED_WITH_REJECTS, ALREADY_DELIVERED,
       NO_RECORDS_SKIPPED or FAILED. Empty on a fault that hit before any of
       those were reached. -->
  <xsl:param name="deliveryStatus" select="''"/>
  <xsl:param name="faultCategory" select="''"/>
  <xsl:param name="faultMessage" select="''"/>
  <!-- Whether a rerun can safely use reprocessFlag=Y, i.e. whether the
       extract output that this run was working from still exists in UCM. -->
  <xsl:param name="reprocessSafe" select="'false'"/>

  <xsl:param name="extractedLoans" select="0"/>

  <!-- Recounted from the formatted file by the reconciliation step, not from
       the canonical batch. Where these differ from the Totals below, the file
       and its trailer disagree. -->
  <xsl:param name="actualDetailCount" select="-1"/>
  <xsl:param name="actualRepaymentCents" select="0"/>
  <xsl:param name="actualOutstandingCents" select="0"/>

  <xsl:template match="/">
    <xsl:variable name="totals" select="/can:LoanBatch/can:Totals"/>
    <xsl:variable name="rejects" select="/can:LoanBatch/can:Reject"/>

    <!-- -1 means the reconciliation step never ran, which is the case for
         every fault raised before the file was formatted. Reporting that as
         "reconciled: false" would be indistinguishable from a genuine
         mismatch, so it reports as not-applicable instead. -->
    <xsl:variable name="reconciliationRan" select="number($actualDetailCount) &gt;= 0"/>
    <xsl:variable name="reconciled"
        select="$reconciliationRan
                and number($actualDetailCount) = number($totals/can:DetailCount)
                and number($actualRepaymentCents) = number($totals/can:TotalRepaymentCents)
                and number($actualOutstandingCents) = number($totals/can:TotalOutstandingCents)"/>

    <sum:DeliverySummary>
      <sum:RunId><xsl:value-of select="$runId"/></sum:RunId>
      <sum:EnvironmentName><xsl:value-of select="$environmentName"/></sum:EnvironmentName>
      <sum:RunStartTime><xsl:value-of select="$runStartTime"/></sum:RunStartTime>
      <sum:RunEndTime><xsl:value-of select="$runEndTime"/></sum:RunEndTime>

      <sum:ExtractName><xsl:value-of select="$extractName"/></sum:ExtractName>
      <sum:RequestId><xsl:value-of select="$requestId"/></sum:RequestId>
      <sum:ContentId><xsl:value-of select="$contentId"/></sum:ContentId>
      <sum:Reprocessed><xsl:value-of select="$reprocessed"/></sum:Reprocessed>

      <sum:ContractNumber><xsl:value-of select="/can:LoanBatch/can:ContractNumber"/></sum:ContractNumber>
      <sum:PayPeriodEndDate><xsl:value-of select="/can:LoanBatch/can:PayPeriodEndDate"/></sum:PayPeriodEndDate>
      <sum:CheckDate><xsl:value-of select="/can:LoanBatch/can:CheckDate"/></sum:CheckDate>

      <sum:TargetFileName><xsl:value-of select="$targetFileName"/></sum:TargetFileName>
      <sum:ArchiveFileName><xsl:value-of select="$archiveFileName"/></sum:ArchiveFileName>
      <sum:Encrypted><xsl:value-of select="$encrypted"/></sum:Encrypted>
      <sum:FileSizeBytes><xsl:value-of select="$fileSizeBytes"/></sum:FileSizeBytes>

      <sum:Status>
        <xsl:choose>
          <!-- A fault beats anything the happy path had got as far as
               setting. -->
          <xsl:when test="$faultCategory != '' and $deliveryStatus = 'FAILED'
                          and contains($faultMessage, 'Trailer claims')"
            >RECONCILIATION_FAILED</xsl:when>
          <xsl:when test="$faultCategory != ''">FAILED</xsl:when>
          <xsl:when test="$deliveryStatus = 'NO_RECORDS_SKIPPED'">NO_RECORDS_SKIPPED</xsl:when>
          <xsl:when test="$deliveryStatus = 'ALREADY_DELIVERED'">ALREADY_DELIVERED</xsl:when>
          <!-- Delivered, but the file went out short: rows the extract
               produced did not make it in. Green would be a lie. -->
          <xsl:when test="$deliveryStatus != '' and count($rejects) &gt; 0"
            >DELIVERED_WITH_REJECTS</xsl:when>
          <xsl:when test="$deliveryStatus != ''"><xsl:value-of select="$deliveryStatus"/></xsl:when>
          <xsl:otherwise>NOT_STARTED</xsl:otherwise>
        </xsl:choose>
      </sum:Status>

      <sum:StatusDetail>
        <xsl:choose>
          <xsl:when test="$faultMessage != ''">
            <xsl:value-of select="$faultMessage"/>
            <xsl:choose>
              <xsl:when test="$reprocessSafe = 'true'">
                <xsl:text> Rerun with reprocessFlag=Y to reuse extract output </xsl:text>
                <xsl:value-of select="$contentId"/>
                <xsl:text> rather than asking HCM to recompute the period.</xsl:text>
              </xsl:when>
              <xsl:otherwise>
                <xsl:text> No extract output was retrieved, so a rerun must resubmit the extract (reprocessFlag=N).</xsl:text>
              </xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:when test="$deliveryStatus = 'ALREADY_DELIVERED'">
            <xsl:value-of select="concat('A file for contract ',
                                  /can:LoanBatch/can:ContractNumber,
                                  ' and period ',
                                  /can:LoanBatch/can:PayPeriodEndDate,
                                  ' is already in the remote directory. Nothing was sent; this run was a duplicate.')"/>
          </xsl:when>
          <xsl:when test="$deliveryStatus = 'NO_RECORDS_SKIPPED'">
            <xsl:text>No loan repayments in the period, and zeroRecordPolicy is SKIP_SEND, so no file was sent.</xsl:text>
          </xsl:when>
          <xsl:when test="$reconciled">
            <xsl:value-of select="concat('Delivered ', $totals/can:DetailCount,
                                  ' detail rows; trailer and file agree.')"/>
          </xsl:when>
          <xsl:when test="$reconciliationRan">
            <xsl:text>Trailer and formatted file disagree; see the counts.</xsl:text>
          </xsl:when>
          <xsl:otherwise>
            <xsl:text>Reconciliation did not run.</xsl:text>
          </xsl:otherwise>
        </xsl:choose>
      </sum:StatusDetail>

      <sum:FaultCategory><xsl:value-of select="$faultCategory"/></sum:FaultCategory>

      <sum:Counts>
        <sum:ExtractedLoans><xsl:value-of select="$extractedLoans"/></sum:ExtractedLoans>
        <sum:Rejected><xsl:value-of select="count($rejects)"/></sum:Rejected>
        <sum:TrailerDetailCount><xsl:value-of select="$totals/can:DetailCount"/></sum:TrailerDetailCount>
        <sum:ActualDetailCount><xsl:value-of select="$actualDetailCount"/></sum:ActualDetailCount>
        <sum:TrailerRepaymentCents><xsl:value-of select="$totals/can:TotalRepaymentCents"/></sum:TrailerRepaymentCents>
        <sum:ActualRepaymentCents><xsl:value-of select="$actualRepaymentCents"/></sum:ActualRepaymentCents>
        <sum:TrailerOutstandingCents><xsl:value-of select="$totals/can:TotalOutstandingCents"/></sum:TrailerOutstandingCents>
        <sum:ActualOutstandingCents><xsl:value-of select="$actualOutstandingCents"/></sum:ActualOutstandingCents>
        <sum:Reconciled>
          <xsl:choose>
            <xsl:when test="not($reconciliationRan)">N/A</xsl:when>
            <xsl:when test="$reconciled">true</xsl:when>
            <xsl:otherwise>false</xsl:otherwise>
          </xsl:choose>
        </sum:Reconciled>
      </sum:Counts>

      <!-- Carried through unchanged. They already contain no amounts and no
           identifiers; see map_extract_to_canonical.xsl. -->
      <xsl:for-each select="$rejects">
        <sum:Reject>
          <sum:EmployeeId><xsl:value-of select="can:EmployeeId"/></sum:EmployeeId>
          <sum:LoanNumber><xsl:value-of select="can:LoanNumber"/></sum:LoanNumber>
          <sum:Reason><xsl:value-of select="can:Reason"/></sum:Reason>
          <sum:Message><xsl:value-of select="can:Message"/></sum:Message>
        </sum:Reject>
      </xsl:for-each>
    </sum:DeliverySummary>
  </xsl:template>
</xsl:stylesheet>

<?xml version="1.0" encoding="UTF-8"?>
<!--
  DeliverySummary -> notification email.

  Written for somebody reading it on a phone at 05:15 who needs to know three
  things in the first line: which environment, whether it worked, and whether
  they have to do anything. The detail is underneath for whoever picks it up
  properly later.

  Nothing in the body carries a national identifier, a name, or an individual
  loan balance. Email is not an encrypted channel and this feed exists
  precisely because that data is sensitive; the rejects list carries the
  employee number and the loan number, which are enough to find the record in
  HCM and not enough to be a disclosure on their own. Control totals are
  aggregates and are safe.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:sum="http://xmlns.oracle.com/hcm/principal401k/summary"
    xmlns:not="http://xmlns.oracle.com/hcm/principal401k/notification"
    exclude-result-prefixes="sum">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="environmentName" select="''"/>

  <xsl:template match="/">
    <xsl:variable name="s" select="/sum:DeliverySummary"/>
    <xsl:variable name="status" select="normalize-space($s/sum:Status)"/>
    <xsl:variable name="counts" select="$s/sum:Counts"/>

    <xsl:variable name="env">
      <xsl:choose>
        <xsl:when test="$environmentName != ''"><xsl:value-of select="$environmentName"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$s/sum:EnvironmentName"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <!-- A word, not a status code, and the same word in the subject and the
         first line of the body. Filters and phone previews both truncate, and
         "ACTION" surviving truncation is the point. -->
    <xsl:variable name="headline">
      <xsl:choose>
        <xsl:when test="$status = 'DELIVERED'">OK</xsl:when>
        <xsl:when test="$status = 'NO_RECORDS_SKIPPED'">OK - nothing to send</xsl:when>
        <xsl:when test="$status = 'ALREADY_DELIVERED'">NO ACTION - duplicate run</xsl:when>
        <xsl:when test="$status = 'DELIVERED_WITH_REJECTS'">ACTION - delivered short</xsl:when>
        <xsl:when test="$status = 'RECONCILIATION_FAILED'">ACTION - not sent</xsl:when>
        <xsl:otherwise>FAILED - not sent</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <not:Notification>
      <not:Subject>
        <xsl:value-of select="concat('[', $env, '] Principal 401(k) loans: ',
                              $headline, ' - contract ', $s/sum:ContractNumber,
                              ', period ', $s/sum:PayPeriodEndDate)"/>
      </not:Subject>

      <not:Body>
        <xsl:value-of select="concat($headline, '&#10;&#10;')"/>

        <xsl:value-of select="concat('Run           : ', $s/sum:RunId, '&#10;')"/>
        <xsl:value-of select="concat('Environment   : ', $env, '&#10;')"/>
        <xsl:value-of select="concat('Status        : ', $status, '&#10;')"/>
        <xsl:value-of select="concat('Contract      : ', $s/sum:ContractNumber, '&#10;')"/>
        <xsl:value-of select="concat('Period end    : ', $s/sum:PayPeriodEndDate, '&#10;')"/>
        <xsl:value-of select="concat('Check date    : ', $s/sum:CheckDate, '&#10;')"/>
        <xsl:value-of select="concat('Started       : ', $s/sum:RunStartTime, '&#10;')"/>
        <xsl:value-of select="concat('Finished      : ', $s/sum:RunEndTime, '&#10;&#10;')"/>

        <xsl:if test="normalize-space($s/sum:TargetFileName) != ''">
          <xsl:value-of select="concat('File          : ', $s/sum:TargetFileName, '&#10;')"/>
          <xsl:value-of select="concat('Encrypted     : ', $s/sum:Encrypted, '&#10;')"/>
          <xsl:value-of select="concat('Size (bytes)  : ', $s/sum:FileSizeBytes, '&#10;')"/>
          <xsl:value-of select="concat('Archived as   : ', $s/sum:ArchiveFileName, '&#10;&#10;')"/>
        </xsl:if>

        <xsl:text>Counts&#10;</xsl:text>
        <xsl:value-of select="concat('  Loans extracted     : ', $counts/sum:ExtractedLoans, '&#10;')"/>
        <xsl:value-of select="concat('  Rejected            : ', $counts/sum:Rejected, '&#10;')"/>
        <xsl:value-of select="concat('  Detail rows sent    : ', $counts/sum:ActualDetailCount, '&#10;')"/>
        <xsl:value-of select="concat('  Trailer claims      : ', $counts/sum:TrailerDetailCount, '&#10;')"/>
        <xsl:value-of select="concat('  Reconciled          : ', $counts/sum:Reconciled, '&#10;')"/>
        <xsl:call-template name="money">
          <xsl:with-param name="label" select="'  Total repayments    : '"/>
          <xsl:with-param name="cents" select="$counts/sum:TrailerRepaymentCents"/>
        </xsl:call-template>
        <xsl:call-template name="money">
          <xsl:with-param name="label" select="'  Total outstanding   : '"/>
          <xsl:with-param name="cents" select="$counts/sum:TrailerOutstandingCents"/>
        </xsl:call-template>

        <xsl:if test="$counts/sum:Reconciled = 'false'">
          <xsl:text>&#10;The trailer and the formatted file disagree. Nothing was delivered.&#10;</xsl:text>
          <xsl:text>This is a defect in the integration, not in the data: raise it with&#10;</xsl:text>
          <xsl:text>the integrations team and do not rerun until it is diagnosed, because&#10;</xsl:text>
          <xsl:text>a rerun will produce the same file.&#10;</xsl:text>
        </xsl:if>

        <xsl:if test="normalize-space($s/sum:StatusDetail) != ''">
          <xsl:value-of select="concat('&#10;Detail&#10;  ', $s/sum:StatusDetail, '&#10;')"/>
        </xsl:if>

        <xsl:if test="$s/sum:Reject">
          <xsl:value-of select="concat('&#10;Rejected loans (', count($s/sum:Reject),
                                ') - these were NOT sent to Principal and will not&#10;')"/>
          <xsl:text>post against the participant's loan until the underlying record is&#10;</xsl:text>
          <xsl:text>fixed in HCM and the run is repeated.&#10;&#10;</xsl:text>
          <xsl:for-each select="$s/sum:Reject">
            <xsl:value-of select="concat('  ', sum:Reason, '  employee ', sum:EmployeeId)"/>
            <xsl:if test="normalize-space(sum:LoanNumber) != ''">
              <xsl:value-of select="concat(', loan ', sum:LoanNumber)"/>
            </xsl:if>
            <xsl:value-of select="concat('&#10;    ', sum:Message, '&#10;')"/>
          </xsl:for-each>
        </xsl:if>

        <xsl:if test="$status = 'ALREADY_DELIVERED'">
          <xsl:text>&#10;Nothing was sent because a file for this contract and period is&#10;</xsl:text>
          <xsl:text>already in Principal's directory. This is the duplicate guard doing&#10;</xsl:text>
          <xsl:text>its job; no action is needed unless you expected this period to be&#10;</xsl:text>
          <xsl:text>resent, in which case remove the delivered file first.&#10;</xsl:text>
        </xsl:if>

        <xsl:text>&#10;Full summary: the run summary XML in the SFTP archive directory.&#10;</xsl:text>
      </not:Body>
    </not:Notification>
  </xsl:template>

  <!-- Cents back to a readable amount for the email only. The file carries
       cents; a human reading a total of 4823750 has to do arithmetic to
       notice it is wrong, and the point of putting it in the email is that
       somebody notices. -->
  <xsl:template name="money">
    <xsl:param name="label"/>
    <xsl:param name="cents"/>
    <xsl:variable name="n" select="number(normalize-space($cents))"/>
    <xsl:value-of select="$label"/>
    <xsl:choose>
      <xsl:when test="$n = $n">
        <xsl:value-of select="format-number($n div 100, '#,##0.00')"/>
      </xsl:when>
      <xsl:otherwise><xsl:text>0.00</xsl:text></xsl:otherwise>
    </xsl:choose>
    <xsl:text>&#10;</xsl:text>
  </xsl:template>

</xsl:stylesheet>

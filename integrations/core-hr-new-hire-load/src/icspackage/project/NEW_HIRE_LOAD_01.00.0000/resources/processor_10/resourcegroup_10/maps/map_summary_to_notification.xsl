<?xml version="1.0" encoding="UTF-8"?>
<!--
  LoadSummary -> notification email.

  The subject carries the outcome and the counts, because that is all most
  recipients will read. The body leads with the HDL identifiers so whoever
  picks up a failure can go straight to the import in HCM.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:sum="http://xmlns.oracle.com/hcm/newhire/summary"
    xmlns:ntf="http://xmlns.oracle.com/hcm/newhire/notification"
    exclude-result-prefixes="sum">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="environmentName" select="'DEV'"/>

  <!-- Max reject lines in the body. The full list is always in the summary
       file on FTP; an unbounded email is the one nobody opens. -->
  <xsl:param name="maxRejectsShown" select="25"/>

  <xsl:variable name="nl" select="'&#10;'"/>

  <xsl:template match="/sum:LoadSummary">
    <ntf:Notification>
      <ntf:Subject>
        <xsl:value-of select="concat(
          '[', $environmentName, '] Core HR new hire load ', sum:Status,
          ' - ', sum:Counts/sum:LoadedByHdl, ' loaded, ',
          sum:Counts/sum:FailedInHdl + sum:Counts/sum:RejectedInFlight,
          ' rejected (', sum:SourceFileName, ')')"/>
      </ntf:Subject>

      <ntf:Body>
        <xsl:value-of select="concat(
          'Core HR - New Hire Load (HDL via OIC)', $nl,
          '=======================================', $nl, $nl,
          'Environment   : ', $environmentName, $nl,
          'Outcome       : ', sum:Status, $nl,
          'Batch         : ', sum:BatchId, $nl,
          'Source file   : ', sum:SourceFileName, $nl,
          'Started       : ', sum:RunStartTime, $nl,
          'Finished      : ', sum:RunEndTime, $nl, $nl,
          'HDL data set  : ', sum:DataSetName, $nl,
          'HDL process   : ', sum:ProcessId, $nl,
          'UCM content   : ', sum:ContentId, $nl, $nl,
          'Rows in file          : ', sum:Counts/sum:SourceRows, $nl,
          'Sent to HDL           : ', sum:Counts/sum:Accepted, $nl,
          'Rejected before load  : ', sum:Counts/sum:RejectedInFlight, $nl,
          'Loaded by HDL         : ', sum:Counts/sum:LoadedByHdl, $nl,
          'Failed in HDL         : ', sum:Counts/sum:FailedInHdl, $nl, $nl,
          sum:StatusDetail, $nl)"/>

        <xsl:if test="sum:Reject">
          <xsl:value-of select="concat($nl, 'Rejected records', $nl,
                                       '----------------', $nl)"/>
          <xsl:for-each select="sum:Reject[position() &lt;= $maxRejectsShown]">
            <xsl:value-of select="concat(
              '  [', sum:Stage, '] ',
              'person ', sum:PersonNumber,
              ' (source line ', sum:SourceLineNumber, '): ',
              sum:Message, $nl)"/>
          </xsl:for-each>
          <xsl:if test="count(sum:Reject) &gt; $maxRejectsShown">
            <xsl:value-of select="concat('  ... and ',
              count(sum:Reject) - $maxRejectsShown,
              ' more; see the summary file in the audit directory.', $nl)"/>
          </xsl:if>
        </xsl:if>

        <xsl:choose>
          <xsl:when test="sum:Status = 'COMPLETED'">
            <xsl:value-of select="concat($nl,
              'No action required.', $nl)"/>
          </xsl:when>
          <xsl:when test="sum:Status = 'TIMED_OUT'">
            <xsl:value-of select="concat($nl,
              'ACTION: the load was still running when polling gave up. It may ',
              'yet succeed - check the data set in HCM before resubmitting, or ',
              'the same hires will be loaded twice.', $nl)"/>
          </xsl:when>
          <xsl:otherwise>
            <xsl:value-of select="concat($nl,
              'ACTION: review the rejects above, correct them at source, and ',
              'drop a corrected extract in the inbound directory. Records that ',
              'loaded successfully will merge rather than duplicate on the ',
              'next run.', $nl)"/>
          </xsl:otherwise>
        </xsl:choose>
      </ntf:Body>
    </ntf:Notification>
  </xsl:template>
</xsl:stylesheet>

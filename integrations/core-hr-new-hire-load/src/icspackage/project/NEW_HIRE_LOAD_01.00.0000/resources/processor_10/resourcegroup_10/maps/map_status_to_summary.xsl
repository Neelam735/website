<?xml version="1.0" encoding="UTF-8"?>
<!--
  HCM Data Loader status response -> LoadSummary.

  HDL reports "COMPLETED" whenever the import process finished, including runs
  where every single row errored. Collapsing that into a green run is the
  classic way a new-hire load silently does nothing for a week, so the status
  here is derived from the error counts, not from HDL's process status alone.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:hcm="http://xmlns.oracle.com/apps/hcm/dataLoader/status"
    xmlns:can="http://xmlns.oracle.com/hcm/newhire/canonical"
    xmlns:sum="http://xmlns.oracle.com/hcm/newhire/summary"
    exclude-result-prefixes="hcm can">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="batchId" select="''"/>
  <xsl:param name="sourceFileName" select="''"/>
  <xsl:param name="runStartTime" select="''"/>
  <xsl:param name="runEndTime" select="''"/>
  <xsl:param name="contentId" select="''"/>
  <xsl:param name="sourceRows" select="0"/>
  <xsl:param name="accepted" select="0"/>
  <xsl:param name="rejectedInFlight" select="0"/>

  <!-- Set by the flow when the poll loop hit its ceiling without HDL
       reaching a terminal state. -->
  <xsl:param name="timedOut" select="'false'"/>

  <xsl:template match="/">
    <xsl:variable name="raw" select="normalize-space(//hcm:ImportStatus)"/>
    <xsl:variable name="loaded">
      <xsl:choose>
        <xsl:when test="//hcm:SuccessRowCount">
          <xsl:value-of select="number(//hcm:SuccessRowCount)"/>
        </xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="failed">
      <xsl:choose>
        <xsl:when test="//hcm:ErrorRowCount">
          <xsl:value-of select="number(//hcm:ErrorRowCount)"/>
        </xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <sum:LoadSummary>
      <sum:BatchId><xsl:value-of select="$batchId"/></sum:BatchId>
      <sum:SourceFileName><xsl:value-of select="$sourceFileName"/></sum:SourceFileName>
      <sum:RunStartTime><xsl:value-of select="$runStartTime"/></sum:RunStartTime>
      <sum:RunEndTime><xsl:value-of select="$runEndTime"/></sum:RunEndTime>

      <sum:ContentId><xsl:value-of select="$contentId"/></sum:ContentId>
      <sum:ProcessId><xsl:value-of select="normalize-space(//hcm:ProcessId)"/></sum:ProcessId>
      <sum:DataSetName><xsl:value-of select="normalize-space(//hcm:DataSetName)"/></sum:DataSetName>

      <sum:Status>
        <xsl:choose>
          <xsl:when test="$timedOut = 'true'">TIMED_OUT</xsl:when>
          <xsl:when test="$raw = 'ERROR' or $raw = 'FAILED'">FAILED</xsl:when>
          <!-- Finished, but nothing landed: treat as a failure, not a success
               with a footnote. -->
          <xsl:when test="$raw = 'COMPLETED' and number($loaded) = 0
                          and number($failed) &gt; 0">FAILED</xsl:when>
          <xsl:when test="$raw = 'COMPLETED' and number($failed) &gt; 0"
            >COMPLETED_WITH_ERRORS</xsl:when>
          <xsl:when test="$raw = 'COMPLETED'">COMPLETED</xsl:when>
          <xsl:when test="$raw = ''">NOT_STARTED</xsl:when>
          <xsl:otherwise>IN_PROGRESS</xsl:otherwise>
        </xsl:choose>
      </sum:Status>

      <sum:StatusDetail>
        <xsl:value-of select="concat('HDL reported &quot;', $raw,
                              '&quot; for data set ',
                              normalize-space(//hcm:DataSetName))"/>
        <xsl:if test="normalize-space(//hcm:ErrorMessage) != ''">
          <xsl:value-of select="concat(' - ', normalize-space(//hcm:ErrorMessage))"/>
        </xsl:if>
      </sum:StatusDetail>

      <sum:Counts>
        <sum:SourceRows><xsl:value-of select="$sourceRows"/></sum:SourceRows>
        <sum:Accepted><xsl:value-of select="$accepted"/></sum:Accepted>
        <sum:RejectedInFlight><xsl:value-of select="$rejectedInFlight"/></sum:RejectedInFlight>
        <sum:LoadedByHdl><xsl:value-of select="$loaded"/></sum:LoadedByHdl>
        <sum:FailedInHdl><xsl:value-of select="$failed"/></sum:FailedInHdl>
      </sum:Counts>

      <!-- Rejects this integration caught before the file was built. -->
      <xsl:for-each select="//can:Reject">
        <sum:Reject>
          <sum:SourceLineNumber><xsl:value-of select="can:SourceLineNumber"/></sum:SourceLineNumber>
          <sum:PersonNumber><xsl:value-of select="can:PersonNumber"/></sum:PersonNumber>
          <sum:Stage>IN_FLIGHT</sum:Stage>
          <sum:Message><xsl:value-of select="can:Message"/></sum:Message>
        </sum:Reject>
      </xsl:for-each>

      <!-- Rejects HDL itself raised, from the import error report. -->
      <xsl:for-each select="//hcm:ErrorDetail">
        <sum:Reject>
          <sum:PersonNumber><xsl:value-of select="normalize-space(hcm:SourceSystemId)"/></sum:PersonNumber>
          <sum:Stage>HDL</sum:Stage>
          <sum:Message>
            <xsl:value-of select="concat(normalize-space(hcm:ObjectName), ': ',
                                  normalize-space(hcm:Message))"/>
          </sum:Message>
        </sum:Reject>
      </xsl:for-each>
    </sum:LoadSummary>
  </xsl:template>
</xsl:stylesheet>

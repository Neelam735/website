<?xml version="1.0" encoding="UTF-8"?>
<!--
  Formatted file -> FileCheck. The independent recount.

  This map reads the 200-character records that are about to be delivered and
  counts them, parsing the amounts back out of their columns. Step 140 of the
  flow compares the result against the canonical batch's Totals, which were
  summed from the loan records rather than from this text.

  The separation is the entire point, and it is easy to erase by accident.
  Anything here that consulted the canonical batch - to know how many rows to
  expect, to know where a column starts, to shortcut the parsing - would make
  the two agree by construction, and the comparison would prove nothing. So
  this map takes only the file, and the positions below are written out
  literally rather than shared with the formatting map.

  That duplication is deliberate. It is the same reason a stocktake is done by
  counting the shelves rather than by re-reading the ledger.

  What it catches that a total alone would not: RecordLengths reports the
  distinct lengths in the file. A record that overran or was cut still sums
  correctly if the damage is in a name column, and only its length gives it
  away.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:exsl="http://exslt.org/common"
    xmlns:pfg="http://xmlns.oracle.com/hcm/principal401k/file"
    xmlns:rec="http://xmlns.oracle.com/hcm/principal401k/reconciliation"
    extension-element-prefixes="exsl"
    exclude-result-prefixes="exsl pfg">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <!-- Column positions, stated here independently of the formatting map. -->
  <xsl:variable name="repaymentStart" select="79"/>
  <xsl:variable name="balanceStart" select="103"/>
  <xsl:variable name="amountDigits" select="11"/>

  <xsl:template match="/">
    <xsl:variable name="details"
        select="/pfg:LoanFile/pfg:Line[starts-with(., 'D')]"/>

    <!-- Built into a variable and read back so the parsed amounts can be
         summed as integers with sum(), rather than accumulated by a recursion
         deep enough to hit the template limit on a large file. -->
    <xsl:variable name="parsedRtf">
      <xsl:for-each select="$details">
        <row>
          <repayment>
            <xsl:call-template name="amount-at">
              <xsl:with-param name="line" select="."/>
              <xsl:with-param name="start" select="$repaymentStart"/>
            </xsl:call-template>
          </repayment>
          <balance>
            <xsl:call-template name="amount-at">
              <xsl:with-param name="line" select="."/>
              <xsl:with-param name="start" select="$balanceStart"/>
            </xsl:call-template>
          </balance>
        </row>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="parsed" select="exsl:node-set($parsedRtf)/row"/>

    <rec:FileCheck>
      <rec:ActualDetailCount><xsl:value-of select="count($details)"/></rec:ActualDetailCount>
      <rec:ActualRepaymentCents><xsl:value-of select="sum($parsed/repayment)"/></rec:ActualRepaymentCents>
      <rec:ActualOutstandingCents><xsl:value-of select="sum($parsed/balance)"/></rec:ActualOutstandingCents>
      <rec:RecordLengths>
        <!-- Distinct lengths, space separated. A well-formed file reports
             exactly "200". -->
        <xsl:for-each select="/pfg:LoanFile/pfg:Line">
          <xsl:variable name="length" select="string-length(.)"/>
          <xsl:if test="not(preceding-sibling::pfg:Line[string-length(.) = $length])">
            <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
            <xsl:value-of select="$length"/>
          </xsl:if>
        </xsl:for-each>
      </rec:RecordLengths>
    </rec:FileCheck>
  </xsl:template>

  <!--
    One amount column, read back: digits, then a trailing sign character.

    number('00000025000') is 25000; the leading zeros are harmless. An
    unreadable column yields NaN, which propagates through sum() and makes the
    comparison in step 140 fail - which is the correct outcome. Coercing it to
    zero here would let a corrupt column pass whenever the corruption happened
    to be in a row whose amount was zero anyway.
  -->
  <xsl:template name="amount-at">
    <xsl:param name="line"/>
    <xsl:param name="start"/>
    <xsl:variable name="magnitude"
        select="number(substring($line, $start, $amountDigits))"/>
    <xsl:variable name="sign"
        select="substring($line, $start + $amountDigits, 1)"/>
    <xsl:choose>
      <xsl:when test="$sign = '-'">
        <xsl:value-of select="0 - $magnitude"/>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$magnitude"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

</xsl:stylesheet>

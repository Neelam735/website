<?xml version="1.0" encoding="UTF-8"?>
<!--
  Stage 2 of 2: canonical loan batch -> Principal fixed-width loan repayment
  file.

  This is the only artifact in the repository that knows a field's position.
  Nothing here decides anything about the data: every value arrives already
  cleaned, converted and validated by map_extract_to_canonical.xsl, so each
  line below is a sequence of pad-and-concatenate calls that can be checked
  against the layout table by reading down the file.

  Record length is 200 characters, every record, including the trailer. Lines
  are terminated by the nXSD schema, not here.

  LAYOUT - header (record type H)
    Pos      Len  Field
      1        1  Record type, 'H'
      2- 9     8  Contract number
     10-17     8  File creation date, CCYYMMDD
     18-23     6  File creation time, HHMMSS
     24-33    10  File type, 'LOANREPAY'
     34-41     8  Pay period end date, CCYYMMDD
     42-49     8  Check date, CCYYMMDD
     50-52     3  File version
     53-62    10  Sender id
     63       1   Test/production flag, T or P
     64-200  137  Filler

  LAYOUT - detail (record type D)
    Pos      Len  Field
      1        1  Record type, 'D'
      2-10     9  National identifier, 9 digits
     11-30    20  Employee id
     31-50    20  Last name
     51-65    15  First name
     66        1  Middle initial
     67-76    10  Loan number
     77-78     2  Loan type code
     79-90    12  Loan repayment amount, 11 digits of cents + sign
     91-102   12  Loan payoff amount, same
    103-114   12  Outstanding balance, same
    115-122    8  Pay period end date
    123-130    8  Check date
    131        1  Loan status code
    132-139    8  Loan origination date
    140-147    8  Last payment date, spaces if none
    148-149    2  Source code
    150-157    8  Termination date, spaces if none
    158        1  Termination indicator, Y or N
    159-200   42  Filler

  LAYOUT - trailer (record type T)
    Pos      Len  Field
      1        1  Record type, 'T'
      2- 9     8  Contract number
     10-19    10  Detail record count
     20-34    15  Total repayment amount, 14 digits of cents + sign
     35-49    15  Total payoff amount, same
     50-64    15  Total outstanding balance, same
     65-72     8  File creation date
     73-78     6  File creation time
     79-200  122  Filler

  On amounts: cents, zero-padded, with the sign as a trailing character
  rather than a leading one. A negative repayment is not a defect - a reversed
  or over-collected deduction is remitted back as one, and Principal nets it -
  so the sign has to survive the format. Trailing keeps every digit column in
  the same place whichever sign it carries.

  On the trailer: its figures come from the canonical batch's Totals, which
  were summed from the same values the detail rows were built from, but not
  from the formatted rows themselves. The reconciliation step in the flow
  parses the finished file back and compares. Deriving the trailer from the
  formatted text instead would make the two agree by construction and the
  check would prove nothing.

  The reference implementation of this map is tools/generate_principal_file.py
  and tests/test_xslt_parity.py asserts the two produce identical bytes.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:can="http://xmlns.oracle.com/hcm/principal401k/canonical"
    xmlns:pfg="http://xmlns.oracle.com/hcm/principal401k/file"
    exclude-result-prefixes="can">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="contractNumber" select="''"/>
  <xsl:param name="senderId" select="''"/>
  <xsl:param name="fileVersion" select="'001'"/>
  <xsl:param name="testProductionFlag" select="'T'"/>
  <xsl:param name="fileCreationDate" select="''"/>
  <xsl:param name="fileCreationTime" select="''"/>

  <xsl:variable name="recordLength" select="200"/>
  <xsl:variable name="fileType" select="'LOANREPAY'"/>

  <!-- Pad sources, longer than any field they fill, so a single substring()
       does the job without a loop.

       Whitespace-only text in a stylesheet is stripped unless it sits inside
       xsl:text, which is why the spaces below are wrapped: written as 200
       spaces between the variable's own tags the value is empty, and every
       record comes out unpadded and short. -->
  <xsl:variable name="pad"><xsl:text>                                                                                                                                                                                                        </xsl:text></xsl:variable>
  <xsl:variable name="zeros">00000000000000000000</xsl:variable>

  <xsl:template match="/">
    <pfg:LoanFile>

      <pfg:Line>
        <xsl:call-template name="fix">
          <xsl:with-param name="text">
            <xsl:text>H</xsl:text>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$contractNumber"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileCreationDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileCreationTime"/><xsl:with-param name="n" select="6"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileType"/><xsl:with-param name="n" select="10"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="/can:LoanBatch/can:PayPeriodEndDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="/can:LoanBatch/can:CheckDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileVersion"/><xsl:with-param name="n" select="3"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$senderId"/><xsl:with-param name="n" select="10"/></xsl:call-template>
            <!-- Anything other than an explicit P is a test transmission.
                 Defaulting the other way would let a misconfigured
                 environment post real money. -->
            <xsl:choose>
              <xsl:when test="$testProductionFlag = 'P'">P</xsl:when>
              <xsl:otherwise>T</xsl:otherwise>
            </xsl:choose>
          </xsl:with-param>
        </xsl:call-template>
      </pfg:Line>

      <xsl:for-each select="/can:LoanBatch/can:Loan">
        <pfg:Line>
          <xsl:call-template name="fix">
            <xsl:with-param name="text">
              <xsl:text>D</xsl:text>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:Ssn"/><xsl:with-param name="n" select="9"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:EmployeeId"/><xsl:with-param name="n" select="20"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LastName"/><xsl:with-param name="n" select="20"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:FirstName"/><xsl:with-param name="n" select="15"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:MiddleInitial"/><xsl:with-param name="n" select="1"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LoanNumber"/><xsl:with-param name="n" select="10"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LoanTypeCode"/><xsl:with-param name="n" select="2"/></xsl:call-template>
              <xsl:call-template name="amount"><xsl:with-param name="cents" select="can:RepaymentAmountCents"/><xsl:with-param name="n" select="11"/></xsl:call-template>
              <xsl:call-template name="amount"><xsl:with-param name="cents" select="can:PayoffAmountCents"/><xsl:with-param name="n" select="11"/></xsl:call-template>
              <xsl:call-template name="amount"><xsl:with-param name="cents" select="can:OutstandingBalanceCents"/><xsl:with-param name="n" select="11"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:PayPeriodEndDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:CheckDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LoanStatusCode"/><xsl:with-param name="n" select="1"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LoanOriginationDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:LastPaymentDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:SourceCode"/><xsl:with-param name="n" select="2"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:TerminationDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
              <xsl:call-template name="left"><xsl:with-param name="v" select="can:TerminationIndicator"/><xsl:with-param name="n" select="1"/></xsl:call-template>
            </xsl:with-param>
          </xsl:call-template>
        </pfg:Line>
      </xsl:for-each>

      <pfg:Line>
        <xsl:call-template name="fix">
          <xsl:with-param name="text">
            <xsl:text>T</xsl:text>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$contractNumber"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="right"><xsl:with-param name="v" select="/can:LoanBatch/can:Totals/can:DetailCount"/><xsl:with-param name="n" select="10"/></xsl:call-template>
            <xsl:call-template name="amount"><xsl:with-param name="cents" select="/can:LoanBatch/can:Totals/can:TotalRepaymentCents"/><xsl:with-param name="n" select="14"/></xsl:call-template>
            <xsl:call-template name="amount"><xsl:with-param name="cents" select="/can:LoanBatch/can:Totals/can:TotalPayoffCents"/><xsl:with-param name="n" select="14"/></xsl:call-template>
            <xsl:call-template name="amount"><xsl:with-param name="cents" select="/can:LoanBatch/can:Totals/can:TotalOutstandingCents"/><xsl:with-param name="n" select="14"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileCreationDate"/><xsl:with-param name="n" select="8"/></xsl:call-template>
            <xsl:call-template name="left"><xsl:with-param name="v" select="$fileCreationTime"/><xsl:with-param name="n" select="6"/></xsl:call-template>
          </xsl:with-param>
        </xsl:call-template>
      </pfg:Line>

    </pfg:LoanFile>
  </xsl:template>

  <!-- Pad the assembled record out to the fixed length, and cut it if
       anything overran. A record that is 201 characters long shifts every
       subsequent record by one on a mainframe reading fixed blocks, so the
       cut is a guard rail rather than a formatting choice - and
       tests/test_layout.py asserts nothing ever reaches it. -->
  <xsl:template name="fix">
    <xsl:param name="text"/>
    <xsl:value-of select="substring(concat($text, $pad), 1, $recordLength)"/>
  </xsl:template>

  <!-- Left-justified, space-padded, truncated to the column width. Truncation
       is right for a name - Principal matches on the identifier, and a
       surname clipped at 20 characters still reads - and would be wrong for a
       number, which is why amounts do not come through here. -->
  <xsl:template name="left">
    <xsl:param name="v"/>
    <xsl:param name="n"/>
    <xsl:value-of select="substring(concat(normalize-space($v), $pad), 1, $n)"/>
  </xsl:template>

  <!-- Right-justified, zero-padded. -->
  <xsl:template name="right">
    <xsl:param name="v"/>
    <xsl:param name="n"/>
    <xsl:variable name="s" select="concat($zeros, normalize-space($v))"/>
    <xsl:value-of select="substring($s, string-length($s) - $n + 1, $n)"/>
  </xsl:template>

  <!-- n digits of zero-padded cents, then one sign character. -->
  <xsl:template name="amount">
    <xsl:param name="cents"/>
    <xsl:param name="n"/>
    <!-- A missing or non-numeric value becomes zero rather than the string
         "NaN", which would otherwise be zero-padded into the amount column
         and read by Principal's loader as a number. -->
    <xsl:variable name="raw" select="number(normalize-space($cents))"/>
    <xsl:variable name="value">
      <xsl:choose>
        <xsl:when test="$raw = $raw"><xsl:value-of select="$raw"/></xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="magnitude">
      <xsl:choose>
        <xsl:when test="$value &lt; 0"><xsl:value-of select="0 - $value"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$value"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="right">
      <xsl:with-param name="v" select="$magnitude"/>
      <xsl:with-param name="n" select="$n"/>
    </xsl:call-template>
    <xsl:choose>
      <xsl:when test="$value &lt; 0">-</xsl:when>
      <xsl:otherwise>+</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

</xsl:stylesheet>

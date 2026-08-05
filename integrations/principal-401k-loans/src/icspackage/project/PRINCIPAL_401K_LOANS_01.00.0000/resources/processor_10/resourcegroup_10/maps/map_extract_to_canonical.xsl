<?xml version="1.0" encoding="UTF-8"?>
<!--
  Stage 1 of 2: HCM Extract output -> canonical loan batch.

  Everything that can go wrong with the *data* happens here. By the time
  map_canonical_to_principal.xsl runs, every value is already in the
  representation the file needs and every unusable row has been diverted to a
  Reject, so the formatting map only pads and concatenates. Splitting it this
  way is what makes the fixed-width layout verifiable by reading one table
  instead of by tracing conditionals through it.

  Four things happen:

  1. Flatten. The extract nests G_LOAN under G_EMPLOYEE under
     G_LEGAL_EMPLOYER; the file is a flat list of loans.
  2. Resolve lookups. Loan type, loan status, contract number and source code
     are all data mappings maintained in the OIC console.
  3. Normalise. Amounts become signed integer cents, dates become CCYYMMDD,
     names become upper-case ASCII, national identifiers become nine digits.
  4. Total. The control totals are summed over the accepted loans, in cents,
     as integers.

  On EXSLT: the accepted loans are built into a variable and read back with
  exsl:node-set so the totals can be summed with sum() over integer cents.
  The alternative in XSLT 1.0 is either recursive summation, which blows the
  template depth limit on a large file, or summing the raw decimal amounts as
  doubles and scaling once, which can disagree with the sum of the rounded
  per-row values by a cent. A cent's disagreement between the trailer and the
  details is exactly what the reconciliation step exists to catch, so it must
  not be designed in. libxslt and the Oracle XDK both support EXSLT common.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:exsl="http://exslt.org/common"
    xmlns:dvm="http://xmlns.oracle.com/dvm"
    xmlns:ext="http://xmlns.oracle.com/hcm/principal401k/extract"
    xmlns:can="http://xmlns.oracle.com/hcm/principal401k/canonical"
    extension-element-prefixes="exsl"
    exclude-result-prefixes="exsl dvm ext">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="runId" select="''"/>

  <!-- FULL sends the nine-digit national identifier, which is how Principal
       matches a participant. MASKED sends 00000 plus the last four and is for
       non-production only; a MASKED production file matches nobody. -->
  <xsl:param name="ssnPolicy" select="'FULL'"/>

  <!-- Source code for a payroll with no row in PFG_401K_SOURCE_CODE. Passed
       in from the flow, which reads it from the lookup's DEFAULT row, so the
       fallback is maintained in the same place as the mappings. -->
  <xsl:param name="sourceCodeDefault" select="'RG'"/>

  <!-- Field widths that a value is silently truncated to must be stated where
       the truncation happens; these are the two that reject instead. An
       amount wider than the column cannot be truncated - dropping a leading
       digit turns $150,000.00 into $50,000.00 and it posts. -->
  <xsl:variable name="maxDetailCents" select="99999999999"/>

  <!-- Character tables, as element content so neither the apostrophe in the
       allowed set nor the accented characters need escaping. -->
  <xsl:variable name="foldFrom">abcdefghijklmnopqrstuvwxyzÀÁÂÃÄÅÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝÇàáâãäåèéêëìíîïñòóôõöùúûüýç</xsl:variable>
  <xsl:variable name="foldTo">ABCDEFGHIJKLMNOPQRSTUVWXYZAAAAAAEEEEIIIINOOOOOUUUUYCAAAAAAEEEEIIIINOOOOOUUUUYC</xsl:variable>
  <xsl:variable name="nameAllowed">ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'.</xsl:variable>
  <xsl:variable name="idAllowed">ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-</xsl:variable>
  <xsl:variable name="digits">0123456789</xsl:variable>

  <xsl:template match="/">

    <!-- The file carries one contract number, in the header and the trailer,
         and Principal routes on it. The first legal employer in the extract
         decides it; a loan belonging to an employer that maps to a different
         contract is rejected rather than filed under the wrong plan, because
         a repayment posted to the wrong contract is found by the participant,
         not by us. Splitting into one file per contract is a scoping decision
         made by the extract's legal employer parameter, not here. -->
    <xsl:variable name="firstEmployer"
        select="normalize-space(/ext:DATA_DS/ext:G_LEGAL_EMPLOYER[1]/ext:LEGAL_EMPLOYER_NAME)"/>
    <xsl:variable name="contractNumber"
        select="dvm:lookupValue('PFG_401K_CONTRACT', 'ORACLE_HCM', $firstEmployer,
                                'PRINCIPAL', '')"/>

    <xsl:variable name="periodEnd">
      <xsl:call-template name="to-ccyymmdd">
        <xsl:with-param name="value" select="/ext:DATA_DS/ext:PERIOD_END_DATE"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="checkDate">
      <xsl:call-template name="to-ccyymmdd">
        <xsl:with-param name="value" select="/ext:DATA_DS/ext:CHECK_DATE"/>
      </xsl:call-template>
    </xsl:variable>

    <!-- Built once, then read back as a node-set: the accepted loans are
         needed twice, as output and as the input to the totals. -->
    <xsl:variable name="acceptedRtf">
      <xsl:for-each select="/ext:DATA_DS/ext:G_LEGAL_EMPLOYER/ext:G_EMPLOYEE/ext:G_LOAN">
        <xsl:call-template name="loan">
          <xsl:with-param name="emit" select="'accepted'"/>
          <xsl:with-param name="contractNumber" select="$contractNumber"/>
          <xsl:with-param name="batchPeriodEnd" select="$periodEnd"/>
          <xsl:with-param name="batchCheckDate" select="$checkDate"/>
        </xsl:call-template>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="accepted" select="exsl:node-set($acceptedRtf)/can:Loan"/>

    <can:LoanBatch>
      <can:RunId><xsl:value-of select="$runId"/></can:RunId>
      <can:ContractNumber><xsl:value-of select="$contractNumber"/></can:ContractNumber>
      <can:PayPeriodEndDate><xsl:value-of select="$periodEnd"/></can:PayPeriodEndDate>
      <can:CheckDate><xsl:value-of select="$checkDate"/></can:CheckDate>

      <xsl:copy-of select="$accepted"/>

      <can:Totals>
        <can:DetailCount><xsl:value-of select="count($accepted)"/></can:DetailCount>
        <can:TotalRepaymentCents>
          <xsl:value-of select="sum($accepted/can:RepaymentAmountCents)"/>
        </can:TotalRepaymentCents>
        <can:TotalPayoffCents>
          <xsl:value-of select="sum($accepted/can:PayoffAmountCents)"/>
        </can:TotalPayoffCents>
        <can:TotalOutstandingCents>
          <xsl:value-of select="sum($accepted/can:OutstandingBalanceCents)"/>
        </can:TotalOutstandingCents>
      </can:Totals>

      <xsl:for-each select="/ext:DATA_DS/ext:G_LEGAL_EMPLOYER/ext:G_EMPLOYEE/ext:G_LOAN">
        <xsl:call-template name="loan">
          <xsl:with-param name="emit" select="'rejected'"/>
          <xsl:with-param name="contractNumber" select="$contractNumber"/>
          <xsl:with-param name="batchPeriodEnd" select="$periodEnd"/>
          <xsl:with-param name="batchCheckDate" select="$checkDate"/>
        </xsl:call-template>
      </xsl:for-each>
    </can:LoanBatch>
  </xsl:template>

  <!--
    One loan. Called twice over the same node-set - once emitting the accepted
    Loan, once emitting the Reject - because a row is either one or the other
    and the eligibility test must not be written down twice. Both passes reach
    the same verdict from the same variables.
  -->
  <xsl:template name="loan">
    <xsl:param name="emit"/>
    <xsl:param name="contractNumber"/>
    <xsl:param name="batchPeriodEnd"/>
    <xsl:param name="batchCheckDate"/>

    <xsl:variable name="employee" select="parent::ext:G_EMPLOYEE"/>
    <xsl:variable name="employer" select="$employee/parent::ext:G_LEGAL_EMPLOYER"/>

    <xsl:variable name="employeeId" select="normalize-space($employee/ext:PERSON_NUMBER)"/>

    <xsl:variable name="rawId"
        select="translate(normalize-space($employee/ext:NATIONAL_ID),
                          translate(normalize-space($employee/ext:NATIONAL_ID), $digits, ''), '')"/>

    <xsl:variable name="loanNumber">
      <xsl:call-template name="clean">
        <xsl:with-param name="value" select="ext:LOAN_NUMBER"/>
        <xsl:with-param name="allowed" select="$idAllowed"/>
      </xsl:call-template>
    </xsl:variable>

    <xsl:variable name="lastName">
      <xsl:call-template name="clean">
        <xsl:with-param name="value" select="$employee/ext:LAST_NAME"/>
        <xsl:with-param name="allowed" select="$nameAllowed"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="firstName">
      <xsl:call-template name="clean">
        <xsl:with-param name="value" select="$employee/ext:FIRST_NAME"/>
        <xsl:with-param name="allowed" select="$nameAllowed"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="middleNames">
      <xsl:call-template name="clean">
        <xsl:with-param name="value" select="$employee/ext:MIDDLE_NAMES"/>
        <xsl:with-param name="allowed" select="$nameAllowed"/>
      </xsl:call-template>
    </xsl:variable>

    <xsl:variable name="loanType"
        select="dvm:lookupValue('PFG_401K_LOAN_TYPE', 'ORACLE_HCM',
                                normalize-space(ext:ELEMENT_NAME), 'PRINCIPAL', '')"/>

    <!-- Status has a defined fallback where loan type does not: an unknown
         status still describes a real repayment that Principal can post,
         whereas an unknown loan type would be filed against the wrong
         amortisation schedule. -->
    <xsl:variable name="loanStatus"
        select="dvm:lookupValue('PFG_401K_LOAN_STATUS', 'ORACLE_HCM',
                                normalize-space(ext:LOAN_STATUS), 'PRINCIPAL', 'A')"/>

    <xsl:variable name="sourceCode"
        select="dvm:lookupValue('PFG_401K_SOURCE_CODE', 'ORACLE_HCM',
                                normalize-space(ext:PAYROLL_NAME), 'PRINCIPAL',
                                $sourceCodeDefault)"/>

    <xsl:variable name="employerContract"
        select="dvm:lookupValue('PFG_401K_CONTRACT', 'ORACLE_HCM',
                                normalize-space($employer/ext:LEGAL_EMPLOYER_NAME),
                                'PRINCIPAL', '')"/>

    <xsl:variable name="repaymentCents">
      <xsl:call-template name="to-cents">
        <xsl:with-param name="value" select="ext:REPAYMENT_AMOUNT"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="payoffCents">
      <xsl:call-template name="to-cents">
        <xsl:with-param name="value" select="ext:PAYOFF_AMOUNT"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="outstandingCents">
      <xsl:call-template name="to-cents">
        <xsl:with-param name="value" select="ext:OUTSTANDING_BALANCE"/>
      </xsl:call-template>
    </xsl:variable>

    <!-- The rejection verdict, as one expression evaluated identically on
         both passes. Order matters only for the message: the first failing
         test names the reason. -->
    <xsl:variable name="reason">
      <xsl:choose>
        <xsl:when test="$contractNumber = '' or $employerContract = ''
                        or $employerContract != $contractNumber">MISSING_CONTRACT</xsl:when>
        <xsl:when test="$rawId = ''">MISSING_NATIONAL_ID</xsl:when>
        <xsl:when test="normalize-space($loanNumber) = ''">MISSING_LOAN_NUMBER</xsl:when>
        <xsl:when test="$loanType = ''">UNMAPPED_LOAN_TYPE</xsl:when>
        <xsl:when test="normalize-space($lastName) = ''">MISSING_NAME</xsl:when>
        <xsl:when test="number($repaymentCents) &gt; $maxDetailCents
                        or number($repaymentCents) &lt; -$maxDetailCents
                        or number($payoffCents) &gt; $maxDetailCents
                        or number($payoffCents) &lt; -$maxDetailCents
                        or number($outstandingCents) &gt; $maxDetailCents
                        or number($outstandingCents) &lt; -$maxDetailCents">AMOUNT_OVERFLOW</xsl:when>
        <xsl:otherwise></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <xsl:choose>
      <xsl:when test="$emit = 'accepted' and $reason = ''">
        <can:Loan>
          <!-- Right-aligned into nine digits before anything else looks at
               it: an identifier stored without its leading zero is common in
               records migrated from an older system, and Principal matches on
               the padded form. Masking then takes the last four of a value
               that is always nine characters long, which it would not be if
               the padding came second. -->
          <xsl:variable name="paddedId"
              select="substring(concat('000000000', $rawId),
                                string-length($rawId) + 1, 9)"/>
          <can:Ssn>
            <xsl:choose>
              <xsl:when test="$ssnPolicy = 'MASKED'">
                <xsl:value-of select="concat('00000', substring($paddedId, 6))"/>
              </xsl:when>
              <xsl:otherwise><xsl:value-of select="$paddedId"/></xsl:otherwise>
            </xsl:choose>
          </can:Ssn>
          <can:EmployeeId><xsl:value-of select="$employeeId"/></can:EmployeeId>
          <can:LastName><xsl:value-of select="$lastName"/></can:LastName>
          <can:FirstName><xsl:value-of select="$firstName"/></can:FirstName>
          <can:MiddleInitial><xsl:value-of select="substring(normalize-space($middleNames), 1, 1)"/></can:MiddleInitial>

          <can:LoanNumber><xsl:value-of select="$loanNumber"/></can:LoanNumber>
          <can:LoanTypeCode><xsl:value-of select="$loanType"/></can:LoanTypeCode>
          <can:LoanStatusCode><xsl:value-of select="$loanStatus"/></can:LoanStatusCode>

          <can:RepaymentAmountCents><xsl:value-of select="$repaymentCents"/></can:RepaymentAmountCents>
          <can:PayoffAmountCents><xsl:value-of select="$payoffCents"/></can:PayoffAmountCents>
          <can:OutstandingBalanceCents><xsl:value-of select="$outstandingCents"/></can:OutstandingBalanceCents>

          <!-- The loan's own period wins over the batch's when the extract
               supplies it: an off-cycle correction carried in the same run
               belongs to a different period than the regular deduction, and
               Principal reconciles a repayment against the period it names. -->
          <can:PayPeriodEndDate>
            <xsl:variable name="loanPeriod">
              <xsl:call-template name="to-ccyymmdd">
                <xsl:with-param name="value" select="ext:PERIOD_END_DATE"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="$loanPeriod != ''"><xsl:value-of select="$loanPeriod"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="$batchPeriodEnd"/></xsl:otherwise>
            </xsl:choose>
          </can:PayPeriodEndDate>
          <can:CheckDate>
            <xsl:variable name="loanCheck">
              <xsl:call-template name="to-ccyymmdd">
                <xsl:with-param name="value" select="ext:CHECK_DATE"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="$loanCheck != ''"><xsl:value-of select="$loanCheck"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="$batchCheckDate"/></xsl:otherwise>
            </xsl:choose>
          </can:CheckDate>
          <can:LoanOriginationDate>
            <xsl:call-template name="to-ccyymmdd">
              <xsl:with-param name="value" select="ext:LOAN_ORIGINATION_DATE"/>
            </xsl:call-template>
          </can:LoanOriginationDate>
          <can:LastPaymentDate>
            <xsl:call-template name="to-ccyymmdd">
              <xsl:with-param name="value" select="ext:LAST_PAYMENT_DATE"/>
            </xsl:call-template>
          </can:LastPaymentDate>

          <xsl:variable name="terminationDate">
            <xsl:call-template name="to-ccyymmdd">
              <xsl:with-param name="value" select="$employee/ext:TERMINATION_DATE"/>
            </xsl:call-template>
          </xsl:variable>
          <can:TerminationDate><xsl:value-of select="$terminationDate"/></can:TerminationDate>
          <can:TerminationIndicator>
            <xsl:choose>
              <xsl:when test="$terminationDate != ''">Y</xsl:when>
              <xsl:otherwise>N</xsl:otherwise>
            </xsl:choose>
          </can:TerminationIndicator>

          <can:SourceCode><xsl:value-of select="$sourceCode"/></can:SourceCode>
        </can:Loan>
      </xsl:when>

      <xsl:when test="$emit = 'rejected' and $reason != ''">
        <can:Reject>
          <can:EmployeeId><xsl:value-of select="$employeeId"/></can:EmployeeId>
          <can:LoanNumber><xsl:value-of select="$loanNumber"/></can:LoanNumber>
          <can:Reason><xsl:value-of select="$reason"/></can:Reason>
          <can:Message>
            <!-- No amounts and no identifier in the message: the summary is
                 written to SFTP and quoted in an email, and neither is a
                 place for a participant's balance. -->
            <xsl:choose>
              <xsl:when test="$reason = 'MISSING_CONTRACT'">
                <xsl:value-of select="concat('Legal employer &quot;',
                                      normalize-space($employer/ext:LEGAL_EMPLOYER_NAME),
                                      '&quot; does not map to the contract this file is for. Add it to PFG_401K_CONTRACT, or scope the run to one contract.')"/>
              </xsl:when>
              <xsl:when test="$reason = 'MISSING_NATIONAL_ID'">
                <xsl:text>No national identifier on the person record; Principal cannot match the participant.</xsl:text>
              </xsl:when>
              <xsl:when test="$reason = 'MISSING_LOAN_NUMBER'">
                <xsl:value-of select="concat('Element &quot;',
                                      normalize-space(ext:ELEMENT_NAME),
                                      '&quot; has no loan number on its element entry DFF.')"/>
              </xsl:when>
              <xsl:when test="$reason = 'UNMAPPED_LOAN_TYPE'">
                <xsl:value-of select="concat('Element &quot;',
                                      normalize-space(ext:ELEMENT_NAME),
                                      '&quot; has no row in PFG_401K_LOAN_TYPE.')"/>
              </xsl:when>
              <xsl:when test="$reason = 'MISSING_NAME'">
                <xsl:text>No last name on the person record.</xsl:text>
              </xsl:when>
              <xsl:otherwise>
                <xsl:text>An amount exceeds the 11-digit width of its column. Truncating it would silently drop a leading digit, so the loan is held back.</xsl:text>
              </xsl:otherwise>
            </xsl:choose>
          </can:Message>
        </can:Reject>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <!--
    Decimal string -> signed integer cents, by string surgery rather than
    arithmetic.

    number('12.34') * 100 is 1233.9999999999998 in IEEE 754, and round() saves
    it here but not for every value; more to the point, the same expression in
    Python would round differently often enough to break parity. Splitting on
    the point and concatenating is exact and is trivially reproducible in any
    language.

    A third decimal place is truncated, not rounded. Payroll delivers two, and
    inventing a half-cent that neither HCM nor Principal holds is worse than
    dropping a fraction that should not exist.
  -->
  <xsl:template name="to-cents">
    <xsl:param name="value"/>
    <xsl:variable name="raw" select="translate(normalize-space($value), ',$ ', '')"/>
    <xsl:variable name="negative" select="starts-with($raw, '-')"/>
    <xsl:variable name="unsigned">
      <xsl:choose>
        <xsl:when test="$negative or starts-with($raw, '+')">
          <xsl:value-of select="substring($raw, 2)"/>
        </xsl:when>
        <xsl:otherwise><xsl:value-of select="$raw"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="whole">
      <xsl:choose>
        <xsl:when test="contains($unsigned, '.')">
          <xsl:value-of select="substring-before($unsigned, '.')"/>
        </xsl:when>
        <xsl:otherwise><xsl:value-of select="$unsigned"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="fraction"
        select="substring(concat(substring-after($unsigned, '.'), '00'), 1, 2)"/>
    <xsl:variable name="wholeDigits"
        select="translate($whole, translate($whole, $digits, ''), '')"/>
    <xsl:variable name="magnitude"
        select="number(concat('0', $wholeDigits)) * 100 + number($fraction)"/>
    <xsl:choose>
      <xsl:when test="$negative and $magnitude != 0">
        <xsl:value-of select="0 - $magnitude"/>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$magnitude"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!--
    YYYY-MM-DD (with or without a time part) -> CCYYMMDD. Anything that is not
    a recognisable date becomes empty, and the formatting map pads an empty
    date to spaces where the layout permits one.

    The month and day range checks are not decoration. Stripping separators
    from a date already in the wrong order - 28-02-2026, which is what a
    hand-populated DFF sometimes holds - yields eight digits that look like a
    date and are not; it would reach Principal as 28 February 2026 written as
    the year 2802, and their loader would either reject the file or accept a
    loan originated two millennia hence. Checking the ranges rejects it here,
    where it becomes an empty field rather than a corrupt one.

    A full calendar validation is deliberately not attempted: 20260231 passes
    this and is not a real date. The point is to catch transposed formats, not
    to reimplement a calendar in XSLT 1.0, and Principal validates the date
    properly at their end.
  -->
  <xsl:template name="to-ccyymmdd">
    <xsl:param name="value"/>
    <xsl:variable name="date" select="substring(normalize-space($value), 1, 10)"/>
    <xsl:variable name="compact" select="translate($date, '-/', '')"/>
    <xsl:if test="string-length($compact) = 8
                  and translate($compact, $digits, '') = ''
                  and number(substring($compact, 5, 2)) &gt;= 1
                  and number(substring($compact, 5, 2)) &lt;= 12
                  and number(substring($compact, 7, 2)) &gt;= 1
                  and number(substring($compact, 7, 2)) &lt;= 31">
      <xsl:value-of select="$compact"/>
    </xsl:if>
  </xsl:template>

  <!--
    Upper-case, de-accent, and drop anything outside the allowed set.

    The inner translate() lists the characters of $value that are *not*
    allowed, by deleting the allowed ones; the outer translate() then deletes
    exactly those from $value. It is the standard XSLT 1.0 way to express
    "keep only these characters", which the language otherwise cannot say.

    Dropping beats rejecting: an em dash in a surname must not cost somebody
    their loan repayment, but it also must not reach a US-ASCII fixed-width
    file, where a multi-byte character shifts every following column.
  -->
  <xsl:template name="clean">
    <xsl:param name="value"/>
    <xsl:param name="allowed"/>
    <xsl:variable name="folded"
        select="translate(normalize-space($value), $foldFrom, $foldTo)"/>
    <xsl:value-of select="translate($folded, translate($folded, $allowed, ''), '')"/>
  </xsl:template>

</xsl:stylesheet>

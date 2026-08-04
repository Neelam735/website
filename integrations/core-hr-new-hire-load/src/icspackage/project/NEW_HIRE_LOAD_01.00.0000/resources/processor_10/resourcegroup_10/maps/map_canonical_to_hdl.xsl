<?xml version="1.0" encoding="UTF-8"?>
<!--
  Stage 2 of 2: canonical new-hire batch -> one HDL business object .dat file.

  Invoked once per business object with $object set. Nine invocations of one
  map beat nine near-identical maps: the METADATA line and the MERGE line for
  an object sit next to each other here, which is the only way to keep column
  order verifiable by reading.

  The reference implementation of this mapping is tools/generate_worker_dat.py,
  and tests/test_xslt_parity.py asserts the two agree row for row.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:can="http://xmlns.oracle.com/hcm/newhire/canonical"
    xmlns:dat="http://xmlns.oracle.com/hcm/hdl/dat"
    exclude-result-prefixes="can">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <!-- One of: Worker PersonName PersonEmail PersonPhone
       PersonLegislativeData PersonAddress WorkRelationship WorkTerms
       Assignment -->
  <xsl:param name="object" select="'Worker'"/>

  <!-- Must match the Source System Owner registered in HCM under
       Manage Common Lookups -> HRC_SOURCE_SYSTEM_OWNER. -->
  <xsl:param name="sourceSystemOwner" select="'OIC_NEWHIRE'"/>

  <xsl:variable name="eot" select="'4712-12-31'"/>
  <xsl:variable name="sso" select="$sourceSystemOwner"/>

  <xsl:template match="/">
    <dat:DatFile>
      <!-- Rows that survive validation AND contribute a row to this object.
           Computing the set once means the METADATA line is only written when
           there is at least one MERGE to follow it. -->
      <xsl:variable name="rows"
        select="//can:NewHire[
                  normalize-space(can:PersonNumber) != ''
                  and normalize-space(can:Name/can:FirstName) != ''
                  and normalize-space(can:Name/can:LastName) != ''
                  and string-length(normalize-space(can:Employment/can:HireDate)) = 10
                  and substring(normalize-space(can:Employment/can:HireDate), 5, 1) = '-'
                  and substring(normalize-space(can:Employment/can:HireDate), 8, 1) = '-'
                  and translate(normalize-space(can:Employment/can:HireDate),
                                '0123456789', '') = '--'
                  and normalize-space(can:Employment/can:LegalEmployerName) != ''
                  and normalize-space(can:Employment/can:LegislationCode) != ''
                  and (not(can:Demographics/can:DateOfBirth)
                       or (string-length(normalize-space(can:Demographics/can:DateOfBirth)) = 10
                           and substring(normalize-space(can:Demographics/can:DateOfBirth), 8, 1) = '-'
                           and translate(normalize-space(can:Demographics/can:DateOfBirth),
                                         '0123456789', '') = '--'))
                  and not(can:PersonNumber = preceding-sibling::can:NewHire/can:PersonNumber)
                  and (
                       $object != 'PersonEmail'
                       or normalize-space(can:Contact/can:EmailAddress) != '')
                  and (
                       $object != 'PersonPhone'
                       or normalize-space(can:Contact/can:PhoneNumber) != '')
                  and (
                       $object != 'PersonAddress'
                       or normalize-space(can:Address/can:AddressLine1) != '')
                  and (
                       $object != 'PersonLegislativeData'
                       or normalize-space(can:Demographics/can:Sex) != ''
                       or normalize-space(can:Demographics/can:MaritalStatus) != '')
                ]"/>

      <xsl:if test="count($rows) &gt; 0">
        <dat:Line>
          <xsl:call-template name="metadata-line"/>
        </dat:Line>
        <xsl:for-each select="$rows">
          <dat:Line>
            <xsl:call-template name="merge-line"/>
          </dat:Line>
        </xsl:for-each>
      </xsl:if>
    </dat:DatFile>
  </xsl:template>

  <xsl:template name="metadata-line">
    <xsl:choose>
      <xsl:when test="$object = 'Worker'">
        <xsl:text>METADATA|Worker|SourceSystemOwner|SourceSystemId|EffectiveStartDate|EffectiveEndDate|PersonNumber|StartDate|DateOfBirth|CountryOfBirth|TownOfBirth|ActionCode</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'PersonName'">
        <xsl:text>METADATA|PersonName|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|EffectiveStartDate|EffectiveEndDate|LegislationCode|NameType|FirstName|MiddleNames|LastName|Title</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'PersonEmail'">
        <xsl:text>METADATA|PersonEmail|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|DateFrom|DateTo|EmailType|EmailAddress|PrimaryFlag</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'PersonPhone'">
        <xsl:text>METADATA|PersonPhone|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|DateFrom|DateTo|PhoneType|LegislationCode|CountryCodeNumber|AreaCode|PhoneNumber|PrimaryFlag</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'PersonLegislativeData'">
        <xsl:text>METADATA|PersonLegislativeData|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|EffectiveStartDate|EffectiveEndDate|LegislationCode|Sex|MaritalStatus</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'PersonAddress'">
        <xsl:text>METADATA|PersonAddress|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|EffectiveStartDate|EffectiveEndDate|AddressType|AddressLine1|AddressLine2|TownOrCity|Region1|Region2|Country|PostalCode|PrimaryFlag</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'WorkRelationship'">
        <xsl:text>METADATA|WorkRelationship|SourceSystemOwner|SourceSystemId|PersonId(SourceSystemId)|LegalEmployerName|DateStart|WorkerType|PrimaryFlag|LegalEmployerSeniorityDate</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'WorkTerms'">
        <xsl:text>METADATA|WorkTerms|SourceSystemOwner|SourceSystemId|PeriodOfServiceId(SourceSystemId)|PersonId(SourceSystemId)|EffectiveStartDate|EffectiveEndDate|EffectiveSequence|EffectiveLatestChange|AssignmentNumber|AssignmentName|AssignmentType|ActionCode|BusinessUnitShortCode|LegalEmployerName|PrimaryWorkTermsFlag|AssignmentStatusTypeCode</xsl:text>
      </xsl:when>
      <xsl:when test="$object = 'Assignment'">
        <xsl:text>METADATA|Assignment|SourceSystemOwner|SourceSystemId|WorkTermsAssignmentId(SourceSystemId)|PeriodOfServiceId(SourceSystemId)|PersonId(SourceSystemId)|EffectiveStartDate|EffectiveEndDate|EffectiveSequence|EffectiveLatestChange|AssignmentNumber|AssignmentType|ActionCode|BusinessUnitShortCode|LegalEmployerName|PrimaryAssignmentFlag|AssignmentStatusTypeCode|JobCode|GradeCode|DepartmentName|LocationCode|PositionCode|ManagerFlag|NormalHours|Frequency|AssignmentCategory</xsl:text>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="merge-line">
    <xsl:variable name="emp" select="normalize-space(can:PersonNumber)"/>
    <xsl:variable name="hire" select="normalize-space(can:Employment/can:HireDate)"/>
    <xsl:variable name="leg" select="normalize-space(can:Employment/can:LegislationCode)"/>
    <xsl:variable name="employer" select="normalize-space(can:Employment/can:LegalEmployerName)"/>
    <xsl:variable name="action">
      <xsl:choose>
        <xsl:when test="normalize-space(can:Employment/can:ActionCode) != ''">
          <xsl:value-of select="normalize-space(can:Employment/can:ActionCode)"/>
        </xsl:when>
        <xsl:otherwise>HIRE</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <!-- Deterministic surrogate keys. Rerunning the same extract MERGEs onto
         the same records rather than creating duplicate people. -->
    <xsl:variable name="person" select="concat('WKR_', $emp)"/>
    <xsl:variable name="pos" select="concat('POS_', $emp)"/>
    <xsl:variable name="wt" select="concat('WT_', $emp)"/>

    <xsl:variable name="bu" select="normalize-space(can:Employment/can:BusinessUnitShortCode)"/>

    <xsl:choose>
      <xsl:when test="$object = 'Worker'">
        <xsl:value-of select="concat(
          'MERGE|Worker|', $sso, '|', $person, '|', $hire, '|', $eot, '|',
          $emp, '|', $hire, '|',
          normalize-space(can:Demographics/can:DateOfBirth), '|',
          normalize-space(can:Demographics/can:CountryOfBirth), '|',
          normalize-space(can:Demographics/can:TownOfBirth), '|', $action)"/>
      </xsl:when>

      <xsl:when test="$object = 'PersonName'">
        <xsl:value-of select="concat(
          'MERGE|PersonName|', $sso, '|', concat('NAME_', $emp), '|', $person, '|',
          $hire, '|', $eot, '|', $leg, '|GLOBAL|',
          normalize-space(can:Name/can:FirstName), '|',
          normalize-space(can:Name/can:MiddleNames), '|',
          normalize-space(can:Name/can:LastName), '|',
          normalize-space(can:Name/can:Title))"/>
      </xsl:when>

      <xsl:when test="$object = 'PersonEmail'">
        <xsl:value-of select="concat(
          'MERGE|PersonEmail|', $sso, '|', concat('EML_', $emp), '|', $person, '|',
          $hire, '|', $eot, '|W1|',
          normalize-space(can:Contact/can:EmailAddress), '|Y')"/>
      </xsl:when>

      <xsl:when test="$object = 'PersonPhone'">
        <xsl:value-of select="concat(
          'MERGE|PersonPhone|', $sso, '|', concat('PHN_', $emp), '|', $person, '|',
          $hire, '|', $eot, '|W1|', $leg, '|',
          normalize-space(can:Contact/can:PhoneCountryCode), '|',
          normalize-space(can:Contact/can:PhoneAreaCode), '|',
          normalize-space(can:Contact/can:PhoneNumber), '|Y')"/>
      </xsl:when>

      <xsl:when test="$object = 'PersonLegislativeData'">
        <xsl:value-of select="concat(
          'MERGE|PersonLegislativeData|', $sso, '|', concat('LEG_', $emp), '|',
          $person, '|', $hire, '|', $eot, '|', $leg, '|',
          normalize-space(can:Demographics/can:Sex), '|',
          normalize-space(can:Demographics/can:MaritalStatus))"/>
      </xsl:when>

      <xsl:when test="$object = 'PersonAddress'">
        <xsl:variable name="country">
          <xsl:choose>
            <xsl:when test="normalize-space(can:Address/can:Country) != ''">
              <xsl:value-of select="normalize-space(can:Address/can:Country)"/>
            </xsl:when>
            <xsl:otherwise><xsl:value-of select="$leg"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:value-of select="concat(
          'MERGE|PersonAddress|', $sso, '|', concat('ADR_', $emp), '|', $person, '|',
          $hire, '|', $eot, '|HOME|',
          normalize-space(can:Address/can:AddressLine1), '|',
          normalize-space(can:Address/can:AddressLine2), '|',
          normalize-space(can:Address/can:TownOrCity), '|',
          normalize-space(can:Address/can:Region1), '|',
          normalize-space(can:Address/can:Region2), '|',
          $country, '|',
          normalize-space(can:Address/can:PostalCode), '|Y')"/>
      </xsl:when>

      <xsl:when test="$object = 'WorkRelationship'">
        <xsl:variable name="workerType">
          <xsl:choose>
            <xsl:when test="normalize-space(can:Employment/can:WorkerType) != ''">
              <xsl:value-of select="normalize-space(can:Employment/can:WorkerType)"/>
            </xsl:when>
            <xsl:otherwise>E</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:value-of select="concat(
          'MERGE|WorkRelationship|', $sso, '|', $pos, '|', $person, '|',
          $employer, '|', $hire, '|', $workerType, '|Y|', $hire)"/>
      </xsl:when>

      <xsl:when test="$object = 'WorkTerms'">
        <xsl:value-of select="concat(
          'MERGE|WorkTerms|', $sso, '|', $wt, '|', $pos, '|', $person, '|',
          $hire, '|', $eot, '|1|Y|', concat('ET', $emp), '|',
          normalize-space(can:Name/can:LastName), ', ',
          normalize-space(can:Name/can:FirstName),
          '|ET|', $action, '|', $bu, '|', $employer, '|Y|ACTIVE_PROCESS')"/>
      </xsl:when>

      <xsl:when test="$object = 'Assignment'">
        <xsl:variable name="mgr">
          <xsl:choose>
            <xsl:when test="normalize-space(can:Employment/can:ManagerFlag) != ''">
              <xsl:value-of select="normalize-space(can:Employment/can:ManagerFlag)"/>
            </xsl:when>
            <xsl:otherwise>N</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:value-of select="concat(
          'MERGE|Assignment|', $sso, '|', concat('ASG_', $emp), '|', $wt, '|',
          $pos, '|', $person, '|', $hire, '|', $eot, '|1|Y|',
          concat('E', $emp), '|E|', $action, '|', $bu, '|', $employer,
          '|Y|ACTIVE_PROCESS|',
          normalize-space(can:Employment/can:JobCode), '|',
          normalize-space(can:Employment/can:GradeCode), '|',
          normalize-space(can:Employment/can:DepartmentName), '|',
          normalize-space(can:Employment/can:LocationCode), '|',
          normalize-space(can:Employment/can:PositionCode), '|',
          $mgr, '|',
          normalize-space(can:Employment/can:NormalHours), '|',
          normalize-space(can:Employment/can:Frequency), '|',
          normalize-space(can:Employment/can:AssignmentCategory))"/>
      </xsl:when>
    </xsl:choose>
  </xsl:template>
</xsl:stylesheet>

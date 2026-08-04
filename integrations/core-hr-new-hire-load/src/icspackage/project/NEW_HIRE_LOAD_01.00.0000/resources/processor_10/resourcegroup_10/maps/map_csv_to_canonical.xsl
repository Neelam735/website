<?xml version="1.0" encoding="UTF-8"?>
<!--
  Stage 1 of 2: ATS CSV segment -> canonical new-hire batch.

  Everything source-system-specific lives here: column names, date formats,
  and the code translations. Pointing the integration at a different ATS means
  replacing this map only; map_canonical_to_hdl.xsl stays untouched.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:csv="http://xmlns.oracle.com/hcm/newhire/csv"
    xmlns:can="http://xmlns.oracle.com/hcm/newhire/canonical"
    exclude-result-prefixes="csv">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <xsl:param name="batchId" select="'UNSET'"/>
  <xsl:param name="sourceFileName" select="''"/>

  <!-- Offset of the first data row: line 1 is the CSV header. -->
  <xsl:param name="lineOffset" select="1"/>

  <xsl:template match="/">
    <can:NewHireBatch>
      <can:BatchId><xsl:value-of select="$batchId"/></can:BatchId>
      <can:SourceFileName><xsl:value-of select="$sourceFileName"/></can:SourceFileName>
      <xsl:apply-templates select="//csv:NewHire"/>
    </can:NewHireBatch>
  </xsl:template>

  <xsl:template match="csv:NewHire">
    <can:NewHire>
      <can:SourceLineNumber>
        <xsl:value-of select="position() + $lineOffset"/>
      </can:SourceLineNumber>
      <can:PersonNumber>
        <xsl:call-template name="clean">
          <xsl:with-param name="v" select="csv:EmployeeNumber"/>
        </xsl:call-template>
      </can:PersonNumber>

      <can:Name>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'Title'"/>
          <xsl:with-param name="v" select="csv:Title"/>
        </xsl:call-template>
        <can:FirstName>
          <xsl:call-template name="clean">
            <xsl:with-param name="v" select="csv:FirstName"/>
          </xsl:call-template>
        </can:FirstName>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'MiddleNames'"/>
          <xsl:with-param name="v" select="csv:MiddleName"/>
        </xsl:call-template>
        <can:LastName>
          <xsl:call-template name="clean">
            <xsl:with-param name="v" select="csv:LastName"/>
          </xsl:call-template>
        </can:LastName>
      </can:Name>

      <xsl:if test="normalize-space(csv:DateOfBirth) != ''
                 or normalize-space(csv:Gender) != ''
                 or normalize-space(csv:MaritalStatus) != ''">
        <can:Demographics>
          <xsl:if test="normalize-space(csv:DateOfBirth) != ''">
            <can:DateOfBirth>
              <xsl:call-template name="normalize-date">
                <xsl:with-param name="v" select="normalize-space(csv:DateOfBirth)"/>
              </xsl:call-template>
            </can:DateOfBirth>
          </xsl:if>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'Sex'"/>
            <xsl:with-param name="v" select="csv:Gender"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'MaritalStatus'"/>
            <xsl:with-param name="v" select="csv:MaritalStatus"/>
          </xsl:call-template>
        </can:Demographics>
      </xsl:if>

      <xsl:if test="normalize-space(csv:EmailAddress) != ''
                 or normalize-space(csv:PhoneNumber) != ''">
        <can:Contact>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'EmailAddress'"/>
            <xsl:with-param name="v" select="csv:EmailAddress"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'PhoneCountryCode'"/>
            <xsl:with-param name="v" select="csv:PhoneCountryCode"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'PhoneAreaCode'"/>
            <xsl:with-param name="v" select="csv:PhoneAreaCode"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'PhoneNumber'"/>
            <xsl:with-param name="v" select="csv:PhoneNumber"/>
          </xsl:call-template>
        </can:Contact>
      </xsl:if>

      <!-- No AddressLine1 means no address at all: HDL rejects a
           PersonAddress row without one, so suppress the whole block. -->
      <xsl:if test="normalize-space(csv:AddressLine1) != ''">
        <can:Address>
          <can:AddressLine1>
            <xsl:call-template name="clean">
              <xsl:with-param name="v" select="csv:AddressLine1"/>
            </xsl:call-template>
          </can:AddressLine1>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'AddressLine2'"/>
            <xsl:with-param name="v" select="csv:AddressLine2"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'TownOrCity'"/>
            <xsl:with-param name="v" select="csv:City"/>
          </xsl:call-template>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'Region2'"/>
            <xsl:with-param name="v" select="csv:State"/>
          </xsl:call-template>
          <can:Country>
            <xsl:choose>
              <xsl:when test="normalize-space(csv:Country) != ''">
                <xsl:value-of select="normalize-space(csv:Country)"/>
              </xsl:when>
              <xsl:otherwise>
                <xsl:value-of select="normalize-space(csv:LegislationCode)"/>
              </xsl:otherwise>
            </xsl:choose>
          </can:Country>
          <xsl:call-template name="opt">
            <xsl:with-param name="name" select="'PostalCode'"/>
            <xsl:with-param name="v" select="csv:PostalCode"/>
          </xsl:call-template>
        </can:Address>
      </xsl:if>

      <can:Employment>
        <can:HireDate>
          <xsl:call-template name="normalize-date">
            <xsl:with-param name="v" select="normalize-space(csv:HireDate)"/>
          </xsl:call-template>
        </can:HireDate>
        <can:ActionCode>
          <xsl:choose>
            <xsl:when test="normalize-space(csv:ActionCode) != ''">
              <xsl:value-of select="normalize-space(csv:ActionCode)"/>
            </xsl:when>
            <xsl:otherwise>HIRE</xsl:otherwise>
          </xsl:choose>
        </can:ActionCode>
        <can:LegalEmployerName>
          <xsl:call-template name="clean">
            <xsl:with-param name="v" select="csv:LegalEmployerName"/>
          </xsl:call-template>
        </can:LegalEmployerName>
        <can:LegislationCode>
          <xsl:value-of select="translate(normalize-space(csv:LegislationCode),
                                'abcdefghijklmnopqrstuvwxyz',
                                'ABCDEFGHIJKLMNOPQRSTUVWXYZ')"/>
        </can:LegislationCode>
        <can:WorkerType>
          <xsl:choose>
            <xsl:when test="normalize-space(csv:WorkerType) != ''">
              <xsl:value-of select="normalize-space(csv:WorkerType)"/>
            </xsl:when>
            <xsl:otherwise>E</xsl:otherwise>
          </xsl:choose>
        </can:WorkerType>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'BusinessUnitShortCode'"/>
          <xsl:with-param name="v" select="csv:BusinessUnit"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'JobCode'"/>
          <xsl:with-param name="v" select="csv:JobCode"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'GradeCode'"/>
          <xsl:with-param name="v" select="csv:GradeCode"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'DepartmentName'"/>
          <xsl:with-param name="v" select="csv:DepartmentName"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'LocationCode'"/>
          <xsl:with-param name="v" select="csv:LocationCode"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'PositionCode'"/>
          <xsl:with-param name="v" select="csv:PositionCode"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'AssignmentCategory'"/>
          <xsl:with-param name="v" select="csv:AssignmentCategory"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'NormalHours'"/>
          <xsl:with-param name="v" select="csv:NormalHours"/>
        </xsl:call-template>
        <xsl:call-template name="opt">
          <xsl:with-param name="name" select="'Frequency'"/>
          <xsl:with-param name="v" select="csv:Frequency"/>
        </xsl:call-template>
        <can:ManagerFlag>
          <xsl:choose>
            <xsl:when test="normalize-space(csv:ManagerFlag) != ''">
              <xsl:value-of select="normalize-space(csv:ManagerFlag)"/>
            </xsl:when>
            <xsl:otherwise>N</xsl:otherwise>
          </xsl:choose>
        </can:ManagerFlag>
      </can:Employment>
    </can:NewHire>
  </xsl:template>

  <!-- Emit a canonical element only when the source has a value, so empty
       optional elements never reach the HDL map. -->
  <xsl:template name="opt">
    <xsl:param name="name"/>
    <xsl:param name="v"/>
    <xsl:if test="normalize-space($v) != ''">
      <xsl:element name="can:{$name}">
        <xsl:call-template name="clean">
          <xsl:with-param name="v" select="$v"/>
        </xsl:call-template>
      </xsl:element>
    </xsl:if>
  </xsl:template>

  <!-- Strip the characters that would corrupt a pipe-delimited .dat row.
       Done on the way in, so the HDL map can concatenate without escaping. -->
  <xsl:template name="clean">
    <xsl:param name="v"/>
    <xsl:value-of select="normalize-space(translate($v, '|&#9;&#10;&#13;', '    '))"/>
  </xsl:template>

  <!-- Accepts YYYY-MM-DD, YYYYMMDD, DD-MON-YYYY, MM/DD/YYYY. Anything else
       passes through unchanged and is caught by the validation switch in
       map_canonical_to_hdl.xsl, which routes the row to the reject file. -->
  <xsl:template name="normalize-date">
    <xsl:param name="v"/>
    <xsl:choose>
      <!-- YYYY-MM-DD -->
      <xsl:when test="string-length($v) = 10 and substring($v, 5, 1) = '-'">
        <xsl:value-of select="$v"/>
      </xsl:when>
      <!-- YYYYMMDD -->
      <xsl:when test="string-length($v) = 8 and number($v) = number($v)">
        <xsl:value-of select="concat(substring($v, 1, 4), '-',
                                     substring($v, 5, 2), '-',
                                     substring($v, 7, 2))"/>
      </xsl:when>
      <!-- DD-MON-YYYY -->
      <xsl:when test="string-length($v) = 11 and substring($v, 3, 1) = '-'">
        <xsl:variable name="mon"
          select="translate(substring($v, 4, 3),
                  'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')"/>
        <xsl:variable name="mm">
          <xsl:choose>
            <xsl:when test="$mon = 'JAN'">01</xsl:when>
            <xsl:when test="$mon = 'FEB'">02</xsl:when>
            <xsl:when test="$mon = 'MAR'">03</xsl:when>
            <xsl:when test="$mon = 'APR'">04</xsl:when>
            <xsl:when test="$mon = 'MAY'">05</xsl:when>
            <xsl:when test="$mon = 'JUN'">06</xsl:when>
            <xsl:when test="$mon = 'JUL'">07</xsl:when>
            <xsl:when test="$mon = 'AUG'">08</xsl:when>
            <xsl:when test="$mon = 'SEP'">09</xsl:when>
            <xsl:when test="$mon = 'OCT'">10</xsl:when>
            <xsl:when test="$mon = 'NOV'">11</xsl:when>
            <xsl:when test="$mon = 'DEC'">12</xsl:when>
            <xsl:otherwise>XX</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:value-of select="concat(substring($v, 8, 4), '-', $mm, '-',
                                     substring($v, 1, 2))"/>
      </xsl:when>
      <!-- MM/DD/YYYY -->
      <xsl:when test="string-length($v) = 10 and substring($v, 3, 1) = '/'">
        <xsl:value-of select="concat(substring($v, 7, 4), '-',
                                     substring($v, 1, 2), '-',
                                     substring($v, 4, 2))"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$v"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>
</xsl:stylesheet>

<# 
.SYNOPSIS
    CUCM Single Number Reach (SNR) debug tools via AXL.

.DESCRIPTION
    This module is intentionally verbose and debug-friendly.
    All functions are public and each writes output about its own result.

    Key ideas:
      - Initialize-CucmAxlConnection: set server / creds / AXL version
      - Invoke-CucmAxl: send SOAP, return XML
      - Get-CucmUserMobility: get user + mobility + associated RDP names
      - Get-CucmRemoteDestinationProfiles: list all RDPs, filter by name
      - Get-CucmRemoteDestinations: list all RDs, filter by RDP name
      - Enable-CucmUserMobility: enable mobility & timers
      - New-CucmRemoteDestinationProfile: create RDP
      - New-CucmRemoteDestination: create RD
      - New-CucmSnrUser: orchestration to enable SNR
      - Get-CucmSnrUser: orchestration to query SNR

    You can call the low-level functions directly for debugging.
#>

# =========================
# Module-scoped variables
# =========================

$script:AxlUri     = $null
$script:AxlCred    = $null
$script:AxlHeader  = @{}
$script:AxlVersion = "12.5"

# =========================
# Connection + SOAP helper
# =========================

function Initialize-CucmAxlConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CucmServer,
        [Parameter(Mandatory)][string]$AxlUser,
        [Parameter(Mandatory)][string]$AxlPassword,
        [string]$AxlVersion = "12.5"
    )

    $script:AxlVersion = $AxlVersion
    $script:AxlUri     = "https://$($CucmServer):8443/axl/"
    $script:AxlCred    = New-Object System.Management.Automation.PSCredential(
        $AxlUser,
        (ConvertTo-SecureString $AxlPassword -AsPlainText -Force)
    )
    $script:AxlHeader  = @{ SOAPAction = "CUCM:DB ver=$AxlVersion" }

    Write-Host "[Initialize-CucmAxlConnection] AXL URI     : $($script:AxlUri)" -ForegroundColor Cyan
    Write-Host "[Initialize-CucmAxlConnection] AXL Version : $AxlVersion" -ForegroundColor Cyan
}

function Invoke-CucmAxl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BodyXml
    )

    if (-not $script:AxlUri -or -not $script:AxlCred) {
        throw "[Invoke-CucmAxl] AXL connection not initialized. Call Initialize-CucmAxlConnection first."
    }

    $envelope = @"
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            xmlns:axl="http://www.cisco.com/AXL/API/$($script:AxlVersion)">
  <s:Header/>
  <s:Body>
    $BodyXml
  </s:Body>
</s:Envelope>
"@

    Write-Host "[Invoke-CucmAxl] Sending SOAP request..." -ForegroundColor DarkCyan

    $response = Invoke-WebRequest `
        -Uri $script:AxlUri `
        -Method Post `
        -Headers $script:AxlHeader `
        -Credential $script:AxlCred `
        -ContentType 'text/xml; charset=utf-8' `
        -Body $envelope `
        -UseBasicParsing

    [xml]$response.Content
}

function Get-CucmNodeText {
    param(
        [Parameter(Mandatory=$false)]
        $Node
    )

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Xml.XmlElement]) {
        if ($Node.InnerText) {
            return $Node.InnerText
        }
        else {
            return $Node.OuterXml
        }
    }

    return [string]$Node
}


# =========================
# Low-level: USER
# =========================

function Get-CucmUserRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId
    )

$body = @"
<axl:getUser>
  <userid>$UserId</userid>
  <returnedTags>
    <userid/>
    <enableMobility/>
    <maxDeskPickupWaitTime/>
    <remoteDestinationLimit/>
    <primaryExtension>
      <pattern/>
      <routePartitionName/>
    </primaryExtension>
    <associatedRemoteDestinationProfiles>
      <remoteDestinationProfileName/>
    </associatedRemoteDestinationProfiles>
  </returnedTags>
</axl:getUser>
"@

    $xml = Invoke-CucmAxl -BodyXml $body

    $bodyNode = $xml.Envelope.Body.ChildNodes |
        Where-Object { $_.LocalName -eq 'getUserResponse' } |
        Select-Object -First 1

    if (-not $bodyNode) {
        Write-Host "[Get-CucmUserRaw] No getUserResponse found." -ForegroundColor Yellow
        return $null
    }

    $returnNode = $bodyNode.return
    if (-not $returnNode) {
        Write-Host "[Get-CucmUserRaw] getUserResponse has no <return> element." -ForegroundColor Yellow
        return $null
    }

    # Some schemas wrap in <user>, some may not – handle both
    $userNode = $returnNode.user
    if (-not $userNode) {
        # Fallback: treat <return> as the user node itself
        $userNode = $returnNode
    }

    if (-not $userNode) {
        Write-Host "[Get-CucmUserRaw] No <user> node found under <return>." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[Get-CucmUserRaw] getUserResponse received for userid='$UserId' (user node found)." -ForegroundColor Green
    #Write-Host "[Get-CucmUserRaw] <user> XML:" -ForegroundColor DarkCyan
    #Write-Host $userNode.OuterXml -ForegroundColor DarkCyan

    return $userNode
}

function Invoke-CucmApplyLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$RoutePartitionName
    )

$body = @"
<axl:applyLine>
  <pattern>$Pattern</pattern>
  <routePartitionName>$RoutePartitionName</routePartitionName>
</axl:applyLine>
"@

    try {
        Write-Host "[Invoke-CucmApplyLine] Applying config to line $Pattern/$RoutePartitionName..." -ForegroundColor Cyan
        $xml = Invoke-CucmAxl -BodyXml $body

        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[Invoke-CucmApplyLine] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[Invoke-CucmApplyLine] ApplyLine completed for $Pattern on $RoutePartitionName." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[Invoke-CucmApplyLine] Failed to apply line $Pattern on $RoutePartitionName`: $($_.Exception.Message)"
        return $null
    }
}


function Invoke-CucmResetLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$RoutePartitionName
    )

$body = @"
<axl:resetLine>
  <pattern>$Pattern</pattern>
  <routePartitionName>$RoutePartitionName</routePartitionName>
</axl:resetLine>
"@

    try {
        Write-Host "[Invoke-CucmResetLine] Resetting line $Pattern/$RoutePartitionName..." -ForegroundColor Cyan
        $xml = Invoke-CucmAxl -BodyXml $body

        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[Invoke-CucmResetLine] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[Invoke-CucmResetLine] ResetLine completed for $Pattern on $RoutePartitionName." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[Invoke-CucmResetLine] Failed to reset line $Pattern on $RoutePartitionName`: $($_.Exception.Message)"
        return $null
    }
}


function Get-CucmUserMobility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId
    )

    $u = Get-CucmUserRaw -UserId $UserId
    if (-not $u) {
        Write-Host "[Get-CucmUserMobility] No <user> node returned for '$UserId'." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[Get-CucmUserMobility] Dumping child nodes of <user> for inspection..." -ForegroundColor DarkYellow
    foreach ($child in $u.ChildNodes) {
        if ($child.NodeType -eq 'Element') {
            Write-Host ("  Child: {0} = '{1}'" -f $child.LocalName, $child.InnerText) -ForegroundColor DarkYellow
        }
    }

    # Build a simple map of top-level scalar fields from <user>
    $fieldMap = @{}
    foreach ($child in $u.ChildNodes) {
        if ($child.NodeType -eq 'Element') {
            # For simple elements only; nested (like primaryExtension) handled below
            if ($child.HasChildNodes -and $child.ChildNodes.Count -eq 1 -and $child.FirstChild.NodeType -eq 'Text') {
                $fieldMap[$child.LocalName] = $child.InnerText
            }
        }
    }

    # Extract primaryExtension (nested element)
    $primaryExtensionPattern   = $null
    $primaryExtensionPartition = $null

    $primaryNode = $u.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq 'primaryExtension' } | Select-Object -First 1
    if ($primaryNode) {
        foreach ($pChild in $primaryNode.ChildNodes) {
            if ($pChild.NodeType -eq 'Element') {
                switch ($pChild.LocalName) {
                    'pattern'           { $primaryExtensionPattern   = $pChild.InnerText }
                    'routePartitionName'{ $primaryExtensionPartition = $pChild.InnerText }
                }
            }
        }
    }

        # Extract associated RDP names (nested element)
    $rdpNames = @()
    $assocNode = $u.ChildNodes |
        Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq 'associatedRemoteDestinationProfiles' } |
        Select-Object -First 1

    if ($assocNode) {
        # Your CUCM is using <remoteDestinationProfile>, but also handle ...Name just in case
        $rawNames = $assocNode.ChildNodes | Where-Object {
            $_.NodeType -eq 'Element' -and (
                $_.LocalName -eq 'remoteDestinationProfile' -or
                $_.LocalName -eq 'remoteDestinationProfileName'
            )
        }

        foreach ($n in $rawNames) {
            if ($n.InnerText) {
                $rdpNames += [string]$n.InnerText
            }
        }
    }


    # Pull values from the map with sensible defaults
    $userIdVal         = $fieldMap['userid']
    $enableMobilityVal = $fieldMap['enableMobility']
    $maxWaitVal        = $fieldMap['maxDeskPickupWaitTime']
    $limitVal          = $fieldMap['remoteDestinationLimit']

    # Convert to proper types
    $enableMobilityBool = $false
    if ($enableMobilityVal) {
        $enableMobilityBool = [System.Convert]::ToBoolean($enableMobilityVal)
    }

    $maxWaitInt = 0
    if ($maxWaitVal -and ($maxWaitVal -as [int] -ne $null)) {
        $maxWaitInt = [int]$maxWaitVal
    }

    $limitInt = 0
    if ($limitVal -and ($limitVal -as [int] -ne $null)) {
        $limitInt = [int]$limitVal
    }

    $obj = [pscustomobject]@{
        UserId                 = [string]$userIdVal
        EnableMobility         = $enableMobilityBool
        MaxDeskPickupWaitTime  = $maxWaitInt
        RemoteDestinationLimit = $limitInt
        PrimaryExtension       = [string]$primaryExtensionPattern
        PrimaryPartition       = [string]$primaryExtensionPartition
        RdpNames               = $rdpNames
    }

    Write-Host "[Get-CucmUserMobility] Parsed UserId        : '$($obj.UserId)'" -ForegroundColor Green
    Write-Host "[Get-CucmUserMobility] Parsed Mobility      : $($obj.EnableMobility)" -ForegroundColor Green
    Write-Host "[Get-CucmUserMobility] Parsed RDP Names     : $(( $obj.RdpNames -join ', ' ))" -ForegroundColor Green

    $obj
}


function Enable-CucmUserMobility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [int]$MaxDeskPickupWait = 10000,
        [int]$RemoteDestinationLimit = 4
    )

$body = @"
<axl:updateUser>
  <userid>$UserId</userid>
  <enableMobility>true</enableMobility>
  <maxDeskPickupWaitTime>$MaxDeskPickupWait</maxDeskPickupWaitTime>
  <remoteDestinationLimit>$RemoteDestinationLimit</remoteDestinationLimit>
</axl:updateUser>
"@

    $xml = Invoke-CucmAxl -BodyXml $body

    Write-Host "[Enable-CucmUserMobility] Mobility enabled for '$UserId' (MaxWait=$MaxDeskPickupWait, Limit=$RemoteDestinationLimit)." -ForegroundColor Green
    $xml
}

# =========================
# Low-level: RDP
# =========================

function Get-CucmRemoteDestinationProfiles {
    [CmdletBinding()]
    param(
        [string[]]$RdpNames = $null
    )

$body = @"
<axl:listRemoteDestinationProfile>
  <searchCriteria>
    <name>%</name>
  </searchCriteria>
  <returnedTags>
    <name/>
    <description/>
    <devicePoolName/>
    <callingSearchSpaceName/>
    <rerouteCallingSearchSpaceName/>
    <lines>
      <line>
        <index/>
        <dirn>
          <pattern/>
          <routePartitionName/>
        </dirn>
      </line>
    </lines>
  </returnedTags>
</axl:listRemoteDestinationProfile>
"@

    $xml = Invoke-CucmAxl -BodyXml $body

    $bodyNode = $xml.Envelope.Body.ChildNodes |
        Where-Object { $_.LocalName -eq 'listRemoteDestinationProfileResponse' } |
        Select-Object -First 1

    if (-not $bodyNode) {
        Write-Host "[Get-CucmRemoteDestinationProfiles] No listRemoteDestinationProfileResponse found." -ForegroundColor Yellow
        return @()
    }

    $rdps = $bodyNode.return.remoteDestinationProfile
    if (-not $rdps) {
        Write-Host "[Get-CucmRemoteDestinationProfiles] No RDPs returned by CUCM." -ForegroundColor Yellow
        return @()
    }

    if (-not ($rdps -is [System.Array])) {
        $rdps = @($rdps)
    }

    Write-Host "[Get-CucmRemoteDestinationProfiles] Total RDPs returned by CUCM: $($rdps.Count)" -ForegroundColor Cyan

    # Filter by RDP names if provided
    if ($RdpNames -and $RdpNames.Count -gt 0) {
        $rdps = $rdps | Where-Object { $RdpNames -contains (Get-CucmNodeText $_.name) }
        Write-Host "[Get-CucmRemoteDestinationProfiles] Filtered RDPs by name ($($RdpNames -join ', ')): $($rdps.Count)" -ForegroundColor Cyan
    }

    $result = @()

    foreach ($rdp in $rdps) {

        $name        = Get-CucmNodeText $rdp.name
        $desc        = Get-CucmNodeText $rdp.description
        $devicePool  = Get-CucmNodeText $rdp.devicePoolName
        $css         = Get-CucmNodeText $rdp.callingSearchSpaceName
        $rerouteCss  = Get-CucmNodeText $rdp.reroutingCallingSearchSpaceName

        $lines = @()
        if ($rdp.lines.line) {
            if ($rdp.lines.line -is [System.Array]) {
                $lines = $rdp.lines.line
            } else {
                $lines = @($rdp.lines.line)
            }
        }

        if ($lines.Count -eq 0) {
            $result += [pscustomobject]@{
                Name          = $name
                Description   = $desc
                DevicePool    = $devicePool
                Css           = $css
                RerouteCss    = $rerouteCss
                LineIndex     = $null
                LinePattern   = $null
                LinePartition = $null
            }
        }
        else {
            foreach ($ln in $lines) {
                $lineIndex     = Get-CucmNodeText $ln.index
                $linePattern   = Get-CucmNodeText $ln.dirn.pattern
                $linePartition = Get-CucmNodeText $ln.dirn.routePartitionName

                $result += [pscustomobject]@{
                    Name          = $name
                    Description   = $desc
                    DevicePool    = $devicePool
                    Css           = $css
                    RerouteCss    = $rerouteCss
                    LineIndex     = [int]$lineIndex
                    LinePattern   = $linePattern
                    LinePartition = $linePartition
                }
            }
        }
    }

    Write-Host "[Get-CucmRemoteDestinationProfiles] RDP objects created: $($result.Count)" -ForegroundColor Green
    $result
}


function Get-CucmRemoteDestinations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RdpNames
    )

    Write-Host "[Get-CucmRemoteDestinations] Querying all remote destinations..." -ForegroundColor Cyan

    #
    # Use wildcard because CUCM chokes on search by userId and works fine by name=%
    #
$body = @"
<axl:listRemoteDestination>
  <searchCriteria>
    <name>%</name>
  </searchCriteria>
  <returnedTags>
    <name/>
    <destination/>
    <remoteDestinationProfileName/>
    <mobilityCssName/>
    <enableUnifiedMobility/>
    <enableMobileConnect/>
    <enableMoveToMobile/>
    <answerTooSoonTimer/>
    <answerTooLateTimer/>
    <delayBeforeRingingCell/>
  </returnedTags>
</axl:listRemoteDestination>
"@

    $xml = Invoke-CucmAxl -BodyXml $body

    if ($xml.Envelope.Body.Fault) {
        $code = $xml.Envelope.Body.Fault.faultcode
        $msg  = $xml.Envelope.Body.Fault.faultstring
        Write-Error "[Get-CucmRemoteDestinations] Fault: $code - $msg"
        return @()
    }

    # CUCM returns an array or a single object depending on count
    $allRds = $xml.Envelope.Body.listRemoteDestinationResponse.return.remoteDestination
    if (-not $allRds) {
        Write-Host "[Get-CucmRemoteDestinations] CUCM returned zero RDs." -ForegroundColor Yellow
        return @()
    }

    $allCount = ($allRds | Measure-Object).Count
    Write-Host "[Get-CucmRemoteDestinations] Total RDs returned by CUCM: $allCount" -ForegroundColor Green

    $collected = @()

    foreach ($rd in $allRds) {

        $rdRdp = $rd.remoteDestinationProfileName.'#text'
        $rdName = $rd.name
        $dest = $rd.destination

        Write-Host "  [Get-CucmRemoteDestinations] RD '$rdName' is on RDP '$rdRdp'" -ForegroundColor DarkGray

        if ($RdpNames -contains $rdRdp) {
            Write-Host "  -> Match (belongs to requested RDP)" -ForegroundColor Cyan

            $obj = [pscustomobject]@{
                Name                     = $rdName
                Destination              = $dest
                RemoteDestinationProfile = $rdRdp
                MobilityCss              = $rd.mobilityCssName
                EnableUnifiedMobility    = ($rd.enableUnifiedMobility -eq "true")
                EnableMobileConnect      = ($rd.enableMobileConnect -eq "true")
                EnableMoveToMobile       = ($rd.enableMoveToMobile -eq "true")
                AnswerTooSoonTimer       = [int]$rd.answerTooSoonTimer
                AnswerTooLateTimer       = [int]$rd.answerTooLateTimer
                DelayBeforeRingingCell   = [int]$rd.delayBeforeRingingCell
            }

            $collected += $obj
        }
    }

    $filteredCount = ($collected | Measure-Object).Count
    Write-Host "[Get-CucmRemoteDestinations] Filtered RDs by RDP name ($($RdpNames -join ',')):" -ForegroundColor Green
    Write-Host "[Get-CucmRemoteDestinations] RD objects created: $filteredCount" -ForegroundColor Green

    return $collected
}


function New-CucmRemoteDestinationProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$RdpName,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$DevicePool,
        [Parameter(Mandatory)][string]$Css,
        [Parameter(Mandatory)][string]$RerouteCss,
        [Parameter(Mandatory)][string]$DeskDn,
        [Parameter(Mandatory)][string]$DeskDnPartition,

        # Cluster-specific defaults from your Postman output
        [string]$Product  = "Remote Destination Profile",
        [string]$Model    = "Remote Destination Profile",
        [string]$Protocol = "Remote Destination"
    )

$body = @"
<axl:addRemoteDestinationProfile>
  <remoteDestinationProfile>
    <name>$RdpName</name>
    <description>$Description</description>
    <userId>$UserId</userId>

    <product>$Product</product>
    <model>$Model</model>
    <protocol>$Protocol</protocol>

    <devicePoolName>$DevicePool</devicePoolName>
    <callingSearchSpaceName>$Css</callingSearchSpaceName>
    <rerouteCallingSearchSpaceName>$RerouteCss</rerouteCallingSearchSpaceName>

    <lines>
      <line>
        <index>1</index>
        <dirn>
          <pattern>$DeskDn</pattern>
          <routePartitionName>$DeskDnPartition</routePartitionName>
        </dirn>
      </line>
    </lines>
  </remoteDestinationProfile>
</axl:addRemoteDestinationProfile>
"@

    try {
        $xml = Invoke-CucmAxl -BodyXml $body

        # If CUCM returned a SOAP Fault, surface it instead of saying "created"
        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[New-CucmRemoteDestinationProfile] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[New-CucmRemoteDestinationProfile] RDP '$RdpName' created for user '$UserId'." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[New-CucmRemoteDestinationProfile] Failed to create RDP '$RdpName' for user '$UserId': $($_.Exception.Message)"
        return $null
    }
}

# =========================
# Low-level: RD
# =========================
<#--
function New-CucmRemoteDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RdpName,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$DestinationNumber,
        [Parameter(Mandatory)][string]$MobilityCss,
        [Parameter(Mandatory)][string]$DeskDn,
        [Parameter(Mandatory)][string]$DeskDnPartition,
        [int]$AnswerTooSoonTimer = 1500,
        [int]$AnswerTooLateTimer = 19000,
        [int]$DelayBeforeRingingCell = 0
    )

    # Name pattern is up to you; leaving as-is
    $rdName = "RD_${UserId}_MOBILE"

$body = @"
<axl:addRemoteDestination>
  <remoteDestination>
    <name>$rdName</name>
    <destination>$DestinationNumber</destination>

    <!-- This is what CUCM was complaining about -->
    <ownerUserId>$UserId</ownerUserId>

    <remoteDestinationProfileName>$RdpName</remoteDestinationProfileName>
    <mobilityCssName>$MobilityCss</mobilityCssName>

    <enableUnifiedMobility>true</enableUnifiedMobility>
    <enableMobileConnect>true</enableMobileConnect>
    <enableMoveToMobile>true</enableMoveToMobile>

    <answerTooSoonTimer>$AnswerTooSoonTimer</answerTooSoonTimer>
    <answerTooLateTimer>$AnswerTooLateTimer</answerTooLateTimer>
    <delayBeforeRingingCell>$DelayBeforeRingingCell</delayBeforeRingingCell>
    <lineAssociation>
     <lineIdentifier>
      <!-- Specify the Directory Number -->
      <pattern>$DeskDn</pattern>
      <!-- Specify the Route Partition name -->
      <routePartitionName>
       <name>$DeskDnPartition</name>
      </routePartitionName>
     </lineIdentifier>
     <!-- Set the "associated" attribute to "true" to enable the association -->
     <associated>true</associated>
    </lineAssociation>
  </remoteDestination>
</axl:addRemoteDestination>
"@

    try {
        $xml = Invoke-CucmAxl -BodyXml $body

        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[New-CucmRemoteDestination] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[New-CucmRemoteDestination] RD '$rdName' -> '$DestinationNumber' created on RDP '$RdpName' for user '$UserId'." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[New-CucmRemoteDestination] Failed to create RD '$rdName' on '$RdpName' for user '$UserId': $($_.Exception.Message)"
        return $null
    }
}
--#>


function New-CucmRemoteDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RdpName,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$DestinationNumber,
        [Parameter(Mandatory)][string]$MobilityCss,
        [Parameter(Mandatory)][string]$DeskDn,
        [Parameter(Mandatory)][string]$DeskDnPartition,

        # Let you override the RD name, default is same pattern you used in Postman
        [string]$RdName = ("RD_{0}_test" -f $UserId),

        [int]$AnswerTooSoonTimer = 0,
        [int]$AnswerTooLateTimer = 19000,
        [int]$DelayBeforeRingingCell = 0
    )

$body = @"
<axl:addRemoteDestination>
  <remoteDestination>
    <name>$RdName</name>
    <destination>$DestinationNumber</destination>

    <remoteDestinationProfileName>$RdpName</remoteDestinationProfileName>

    <mobilityCssName>$MobilityCss</mobilityCssName>
    <ownerUserId>$UserId</ownerUserId>
    <enableUnifiedMobility>true</enableUnifiedMobility>
    <enableMobileConnect>true</enableMobileConnect>
    <enableMoveToMobile>true</enableMoveToMobile>

    <answerTooSoonTimer>$AnswerTooSoonTimer</answerTooSoonTimer>
    <answerTooLateTimer>$AnswerTooLateTimer</answerTooLateTimer>
    <delayBeforeRingingCell>$DelayBeforeRingingCell</delayBeforeRingingCell>
    <lineAssociation>
     <lineIdentifier>
      <!-- Specify the Directory Number -->
      <pattern>$DeskDn</pattern>
      <!-- Specify the Route Partition name -->
      <routePartitionName>
       <name>$DeskDnPartition</name>
      </routePartitionName>
     </lineIdentifier>
     <!-- Set the "associated" attribute to "true" to enable the association -->
     <associated>true</associated>
    </lineAssociation>
  </remoteDestination>
</axl:addRemoteDestination>
"@

    try {
        $xml = Invoke-CucmAxl -BodyXml $body

        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[New-CucmRemoteDestination] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[New-CucmRemoteDestination] RD '$RdName' -> '$DestinationNumber' created on RDP '$RdpName' for user '$UserId'." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[New-CucmRemoteDestination] Failed to create RD '$RdName' on '$RdpName' for user '$UserId': $($_.Exception.Message)"
        return $null
    }
}


function Set-CucmUserPrimaryExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Partition
    )

$body = @"
<axl:updateUser>
  <userid>$UserId</userid>
  <primaryExtension>
    <pattern>$Pattern</pattern>
    <routePartitionName>$Partition</routePartitionName>
  </primaryExtension>
</axl:updateUser>
"@

    try {
        $xml = Invoke-CucmAxl -BodyXml $body

        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            Write-Error "[Set-CucmUserPrimaryExtension] AXL Fault: $code - $msg - $axl"
            return $null
        }

        Write-Host "[Set-CucmUserPrimaryExtension] Set primary extension $Pattern/$Partition for user '$UserId'." -ForegroundColor Green
        return $xml
    }
    catch {
        Write-Error "[Set-CucmUserPrimaryExtension] Failed to set primary extension for '$UserId': $($_.Exception.Message)"
        return $null
    }
}

function Get-CucmPhoneDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PhoneName
    )

$body = @"
<axl:getPhone>
  <name>$PhoneName</name>
  <returnedTags>
    <name/>
    <description/>
    <ownerUserName/>
    <callingSearchSpaceName/>
    <lines>
      <line>
        <index/>
        <dirn>
          <pattern/>
          <routePartitionName/>
        </dirn>
      </line>
    </lines>
  </returnedTags>
</axl:getPhone>
"@

    $xml = Invoke-CucmAxl -BodyXml $body
    $fault = $xml.Envelope.Body.Fault
    if ($fault) {
        $code = $fault.faultcode
        $msg  = $fault.faultstring
        $axl  = $fault.detail.axlError.axlmessage
        Write-Error "[Get-CucmPhoneDetails] AXL Fault: $code - $msg - $axl"
        return $null
    }

    $phone = $xml.Envelope.Body.getPhoneResponse.return.phone
    if (-not $phone) {
        Write-Host "[Get-CucmPhoneDetails] No <phone> returned for '$PhoneName'." -ForegroundColor Yellow
        return $null
    }

    # Normalize device CSS (CUCM sometimes returns it as an element with #text)
    $deviceCss = $phone.callingSearchSpaceName
    if ($deviceCss -is [System.Xml.XmlElement]) { $deviceCss = $deviceCss.'#text' }

    # Lines can be single node or array
    $lines = @()
    $rawLines = $phone.lines.line
    if ($rawLines) {
        foreach ($ln in @($rawLines)) {
            $pat = $ln.dirn.pattern
            $ptn = $ln.dirn.routePartitionName
            if ($ptn -is [System.Xml.XmlElement]) { $ptn = $ptn.'#text' }

            if ($pat) {
                $lines += [pscustomobject]@{
                    Index     = $ln.index
                    Pattern   = [string]$pat
                    Partition = [string]$ptn
                }
            }
        }
    }

    return [pscustomobject]@{
        PhoneName   = [string]$phone.name
        OwnerUserId = [string]$phone.ownerUserName
        Description = [string]$phone.description
        DeviceCss   = [string]$deviceCss
        Lines       = $lines
    }
}



function Get-CucmLineCss {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$RoutePartitionName
    )

$body = @"
<axl:getLine>
  <pattern>$Pattern</pattern>
  <routePartitionName>$RoutePartitionName</routePartitionName>
  <returnedTags>
    <pattern/>
    <routePartitionName/>
    <callingSearchSpaceName/>
  </returnedTags>
</axl:getLine>
"@

    $xml = Invoke-CucmAxl -BodyXml $body
    $fault = $xml.Envelope.Body.Fault
    if ($fault) {
        # If the line isn't found or permissions block it, return blank but don't explode the whole search
        Write-Host "[Get-CucmLineCss] Warning: Could not read line $Pattern/$RoutePartitionName ($($fault.faultstring))." -ForegroundColor Yellow
        return ""
    }

    $line = $xml.Envelope.Body.getLineResponse.return.line
    if (-not $line) { return "" }

    $css = $line.callingSearchSpaceName
    if ($css -is [System.Xml.XmlElement]) { $css = $css.'#text' }
    return [string]$css
}


function Search-CucmPhones {
    [CmdletBinding()]
    param(
        # Search by DN
        [string]$DnPattern,
        [string]$DnPartition,

        # Search by phone properties (substring match, case-insensitive)
        [string]$DescriptionLike,
        [string]$OwnerLike,
        [string]$PhoneNameLike,

        # Safety knobs
        [int]$MaxPhones = 200
    )

    Write-Host "[Search-CucmPhones] Starting search..." -ForegroundColor Cyan

    $phoneNames = New-Object System.Collections.Generic.HashSet[string]

    #
    # A) If DN search is supplied, find phones by querying the DN’s associated devices
    #
    if ($DnPattern) {
        if (-not $DnPartition) {
            throw "When using -DnPattern, you must also specify -DnPartition (CUCM AXL getLine requires both)."
        }

        Write-Host "[Search-CucmPhones] Finding phones associated with DN $DnPattern/$DnPartition..." -ForegroundColor Cyan

$body = @"
<axl:getLine>
  <pattern>$DnPattern</pattern>
  <routePartitionName>$DnPartition</routePartitionName>
  <returnedTags>
    <associatedDevices>
      <device/>
    </associatedDevices>
  </returnedTags>
</axl:getLine>
"@

        $xml = Invoke-CucmAxl -BodyXml $body
        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            throw "[Search-CucmPhones] getLine failed for $DnPattern/$DnPartition`: $code - $msg - $axl"
        }

        $devices = $xml.Envelope.Body.getLineResponse.return.line.associatedDevices.device
        foreach ($d in @($devices)) {
            if ($d) { [void]$phoneNames.Add([string]$d) }
        }

        Write-Host "[Search-CucmPhones] Found $($phoneNames.Count) phone(s) associated with the DN." -ForegroundColor Green
    }

    #
    # B) If searching by description/owner/phonename, list phones by name=% then filter locally
    #    (avoids CUCM rejecting searchCriteria that it doesn’t like)
    #
    if ($DescriptionLike -or $OwnerLike -or $PhoneNameLike) {

        Write-Host "[Search-CucmPhones] Listing phones (name=%) and filtering locally..." -ForegroundColor Cyan

$body = @"
<axl:listPhone>
  <searchCriteria>
    <name>%</name>
  </searchCriteria>
  <returnedTags>
    <name/>
    <description/>
    <ownerUserName/>
  </returnedTags>
</axl:listPhone>
"@

        $xml = Invoke-CucmAxl -BodyXml $body
        $fault = $xml.Envelope.Body.Fault
        if ($fault) {
            $code = $fault.faultcode
            $msg  = $fault.faultstring
            $axl  = $fault.detail.axlError.axlmessage
            throw "[Search-CucmPhones] listPhone failed: $code - $msg - $axl"
        }

        $phones = $xml.Envelope.Body.listPhoneResponse.return.phone
        $count = (@($phones) | Measure-Object).Count
        Write-Host "[Search-CucmPhones] Total phones returned: $count" -ForegroundColor Green

        foreach ($p in @($phones)) {
            $name = [string]$p.name
            $desc = [string]$p.description
            $own  = [string]$p.ownerUserName

            if ($PhoneNameLike -and ($name -notmatch [regex]::Escape($PhoneNameLike))) { continue }
            if ($DescriptionLike -and ($desc -notmatch [regex]::Escape($DescriptionLike))) { continue }
            if ($OwnerLike -and ($own -notmatch [regex]::Escape($OwnerLike))) { continue }

            if ($name) { [void]$phoneNames.Add($name) }
        }

        Write-Host "[Search-CucmPhones] Filtered phones matched: $($phoneNames.Count)" -ForegroundColor Green
    }

    if ($phoneNames.Count -eq 0) {
        Write-Host "[Search-CucmPhones] No phones matched." -ForegroundColor Yellow
        return @()
    }

    #
    # C) Expand each phone to full details (including DN + Partition + CSS)
    #
    $results = @()
    $n = 0

    foreach ($pn in $phoneNames) {
        $n++
        if ($n -gt $MaxPhones) {
            Write-Host "[Search-CucmPhones] MaxPhones limit reached ($MaxPhones). Stopping expansion." -ForegroundColor Yellow
            break
        }

        Write-Host "[Search-CucmPhones] Reading phone $n/$($phoneNames.Count): $pn" -ForegroundColor DarkGray

        $ph = Get-CucmPhoneDetails -PhoneName $pn
        if (-not $ph) { continue }

        $lineDetails = @()
        foreach ($ln in $ph.Lines) {
            $dnCss = ""
            if ($ln.Pattern -and $ln.Partition) {
                $dnCss = Get-CucmLineCss -Pattern $ln.Pattern -RoutePartitionName $ln.Partition
            }

            $lineDetails += [pscustomobject]@{
                Pattern   = $ln.Pattern
                Partition = $ln.Partition
                LineCss   = $dnCss
            }
        }

        $results += [pscustomobject]@{
            PhoneName   = $ph.PhoneName
            OwnerUserId = $ph.OwnerUserId
            Description = $ph.Description
            DeviceCss   = $ph.DeviceCss
            DNs         = $lineDetails
        }
    }

    return $results
}


# =========================
# High-level orchestration
# =========================

function New-CucmSnrUser {
    [CmdletBinding()]
    param(
        # CUCM connection
        [Parameter(Mandatory)][string]$CucmServer,
        [Parameter(Mandatory)][string]$AxlUser,
        [Parameter(Mandatory)][string]$AxlPassword,
        [string]$AxlVersion = "12.5",

        # User + line
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$DeskDn,
        [Parameter(Mandatory)][string]$DeskDnPartition,

        # Mobile
        [Parameter(Mandatory)][string]$MobileNumber,

        # RDP/RD names (override if you want a different pattern)
        [string]$RdpName = ("RDP_Teams_{0}" -f $UserId),
        [string]$RdName  = ("RD_{0}_test"    -f $UserId),

        # Common CUCM params
        [string]$DevicePool        = "Default",
        [string]$MobilityCss       = "LdCSS-NonFAC",
        [string]$RerouteCss        = "LdCSS-NonFAC",
        [int]$MaxDeskPickupWaitTime = 10000,
        [int]$RemoteDestinationLimit = 4,
        [int]$AnswerTooSoonTimer     = 0,
        [int]$AnswerTooLateTimer     = 19000,
        [int]$DelayBeforeRingingCell = 0
    )

    Write-Host "[New-CucmSnrUser] Initializing AXL connection..." -ForegroundColor Cyan
    Initialize-CucmAxlConnection -CucmServer $CucmServer -AxlUser $AxlUser -AxlPassword $AxlPassword -AxlVersion $AxlVersion

    #
    # 1. Enable mobility on the user
    #
    Write-Host "[New-CucmSnrUser] Enabling mobility for user '$UserId'..." -ForegroundColor Cyan
    Enable-CucmUserMobility -UserId $UserId -MaxDeskPickupWait $MaxDeskPickupWaitTime -RemoteDestinationLimit $RemoteDestinationLimit

    #
    # 2. Ensure primary extension is set
    #
   # Write-Host "[New-CucmSnrUser] Setting primary extension $DeskDn/$DeskDnPartition for '$UserId'..." -ForegroundColor Cyan
   # Set-CucmUserPrimaryExtension -UserId $UserId -Pattern $DeskDn -Partition $DeskDnPartition

    #
    # 3. Create RDP for the user/line
    #
    Write-Host "[New-CucmSnrUser] Creating RDP '$RdpName' for '$UserId'..." -ForegroundColor Cyan
    New-CucmRemoteDestinationProfile `
        -UserId $UserId `
        -RdpName $RdpName `
        -Description "Teams SNR for $UserId" `
        -DevicePool $DevicePool `
        -Css $MobilityCss `
        -RerouteCss $RerouteCss `
        -DeskDn $DeskDn `
        -DeskDnPartition $DeskDnPartition | Out-Null

    #
    # 4. Create RD for the mobile
    #
    Write-Host "[New-CucmSnrUser] Creating RD '$RdName' ($MobileNumber) on RDP '$RdpName'..." -ForegroundColor Cyan
    New-CucmRemoteDestination `
        -RdpName $RdpName `
        -UserId $UserId `
        -DestinationNumber $MobileNumber `
        -MobilityCss $MobilityCss `
        -RdName $RdName `
        -AnswerTooSoonTimer $AnswerTooSoonTimer `
        -AnswerTooLateTimer $AnswerTooLateTimer `
        -DeskDn $DeskDn `
        -DeskDnPartition $DeskDnPartition `
        -DelayBeforeRingingCell $DelayBeforeRingingCell | Out-Null

    # 5. Apply + reset line

    #Write-Host "[New-CucmSnrUser] Applying and resetting line $DeskDn/$DeskDnPartition..." -ForegroundColor Cyan
   # Invoke-CucmApplyLine -Pattern $DeskDn -RoutePartitionName $DeskDnPartition | Out-Null
   # Invoke-CucmResetLine -Pattern $DeskDn -RoutePartitionName $DeskDnPartition | Out-Null

   
   
    #
    # 6. Return a full snapshot so you can verify
    #
    Write-Host "[New-CucmSnrUser] Fetching final SNR state for '$UserId'..." -ForegroundColor Cyan
    $result = Get-CucmSnrUser `
        -CucmServer $CucmServer `
        -AxlUser $AxlUser `
        -AxlPassword $AxlPassword `
        -AxlVersion $AxlVersion `
        -UserId $UserId

    return $result
}


function Get-CucmSnrUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CucmServer,
        [Parameter(Mandatory)][string]$AxlUser,
        [Parameter(Mandatory)][string]$AxlPassword,
        [string]$AxlVersion = "12.5",
        [Parameter(Mandatory)][string]$UserId
    )

    Initialize-CucmAxlConnection -CucmServer $CucmServer -AxlUser $AxlUser -AxlPassword $AxlPassword -AxlVersion $AxlVersion

    Write-Host "[Get-CucmSnrUser] Querying SNR / mobility for '$UserId'..." -ForegroundColor Magenta

    $userMobility = Get-CucmUserMobility -UserId $UserId

    if (-not $userMobility -or -not $userMobility.UserId) {
        Write-Host "[Get-CucmSnrUser] User '$UserId' not found or returned empty userid." -ForegroundColor Yellow
        return $null
    }

    $rdpNames = $userMobility.RdpNames
    if (-not $rdpNames -or $rdpNames.Count -eq 0) {
        $fallback = "RDP_$UserId"
        Write-Host "[Get-CucmSnrUser] No associated RDPs on user; falling back to name '$fallback'." -ForegroundColor Yellow
        $rdpNames = @($fallback)
    }

    $rdps = Get-CucmRemoteDestinationProfiles -RdpNames $rdpNames
    $rds  = Get-CucmRemoteDestinations       -RdpNames $rdpNames

    $rdpCount = if ($rdps) { $rdps.Count } else { 0 }
    $rdCount  = if ($rds)  { $rds.Count }  else { 0 }

    Write-Host "[Get-CucmSnrUser] Final RDP count: $rdpCount" -ForegroundColor Magenta
    Write-Host "[Get-CucmSnrUser] Final RD count : $rdCount"  -ForegroundColor Magenta

    [pscustomobject]@{
        UserMobility       = $userMobility
        RDPs               = $rdps
        RemoteDestinations = $rds
    }
}


# =========================
# Export everything (all public)
# =========================

Export-ModuleMember -Function *

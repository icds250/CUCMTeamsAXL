# CUCM Single Number Reach (SNR) and Teams Enterprise Voice Automation

This repository contains PowerShell modules to automate Cisco CUCM Single Number Reach (SNR) using AXL and to enable Microsoft Teams Enterprise Voice in a repeatable and debuggable way.

Modules included:
- CUCM-RemoteDestinations.psm1
- Enable Teams.psm1
## Function reference

### CUCM-RemoteDestinations.psm1

| Function | Purpose |
|---|---|
| `Initialize-CucmAxlConnection` | Set CUCM AXL endpoint, version, and auth context for subsequent calls. |
| `Invoke-CucmAxl` | Send a SOAP request to CUCM AXL and return parsed XML (includes debug output). |
| `Get-CucmNodeText` | Helper to safely read node text from CUCM XML responses. |
| `Get-CucmUserRaw` | Fetch raw CUCM user XML via getUser (used for troubleshooting). |
| `Invoke-CucmApplyLine` | Apply config changes for a directory number (DN) in CUCM. |
| `Invoke-CucmResetLine` | Reset a directory number (DN) in CUCM. |
| `Get-CucmUserMobility` | Return mobility status, primary extension, and associated RDP names for a CUCM user. |
| `Enable-CucmUserMobility` | Enable mobility for a CUCM user and set timers and limits. |
| `Get-CucmRemoteDestinationProfiles` | List Remote Destination Profiles (RDPs), optionally filtered by name. |
| `Get-CucmRemoteDestinations` | List Remote Destinations (RDs), optionally filtered by RDP name. |
| `New-CucmRemoteDestinationProfile` | Create an RDP for a user and associate a desk DN and CSS values. |
| `New-CucmRemoteDestination` | Create an RD on an RDP for a destination number (includes ownerUserId). |
| `Set-CucmUserPrimaryExtension` | Set a CUCM user primary extension (pattern and partition). |
| `Get-CucmPhoneDetails` | Get phone owner, description, device CSS, and line list (DN and partition). |
| `Get-CucmLineCss` | Get the calling search space (CSS) configured on a specific DN. |
| `Search-CucmPhones` | Search phones by DN, owner, description, or phone name and return full line/CSS info. |
| `New-CucmSnrUser` | Orchestrate end-to-end CUCM SNR provisioning (mobility, primary DN, RDP, RD). |
| `Get-CucmSnrUser` | Get a combined snapshot of user mobility, RDPs, and RDs for troubleshooting. |

### Enable Teams.psm1

| Function | Purpose |
|---|---|
| `Enable-TeamsEnterpriseVoiceUser` | Enable Teams Enterprise Voice: assign number, dial plan, voice routing policy, and voicemail-related policies. |


## Requirements

- PowerShell 5.1 or PowerShell 7+
- Cisco CUCM 12.5 with AXL enabled
- AXL user with permissions for users, lines, phones, RDPs, and RDs
- MicrosoftTeams PowerShell module
- Teams admin permissions and voice licensing

## Authentication

### CUCM AXL

```powershell
$axlCred = Get-Credential -Message "Enter CUCM AXL credentials"

Initialize-CucmAxlConnection `
  -CucmServer "cucm-pub.example.com" `
  -AxlUser $axlCred.UserName `
  -AxlPassword ($axlCred.GetNetworkCredential().Password) `
  -AxlVersion "12.5"
```

### Microsoft Teams

```powershell
Connect-MicrosoftTeams
```

## Bulk onboarding via CSV

### CSV format

Create a CSV file named snr-users.csv:

```csv
UserId,Upn,DeskDn,DeskDnPartition,MobileNumberE164,MobileDestinationDigits,RdpName,RdName,DevicePool,Css,RerouteCss,MobilityCss,TenantDialPlan,VoiceRoutingPolicy,TeamsCallingPolicy,OnlineVoicemailPolicy,PhoneNumberType
testuser,testuser@test.ca,2463,ExtensionsPart,+11235812463,11235812463,RDP_Teams_testuser,RD_Teams_11235812463,Default,LdCSS,LdCSS,LdCSS,DialPlan,DR,CallingPolicy-VoicemailEnabled,TranscriptionDisabled,DirectRouting
```

Notes:
- MobileNumberE164 is used by Teams and must be E.164 format.
- MobileDestinationDigits is used by CUCM Remote Destinations.
- PhoneNumberType must match Teams supported values.

## Bulk CUCM SNR provisioning

```powershell
Import-Module .\CUCM-RemoteDestinations.psm1

$axlCred = Get-Credential -Message "Enter CUCM AXL credentials"

Initialize-CucmAxlConnection `
  -CucmServer "cucm-pub.example.com" `
  -AxlUser $axlCred.UserName `
  -AxlPassword ($axlCred.GetNetworkCredential().Password) `
  -AxlVersion "12.5"

$rows = Import-Csv .\snr-users.csv

foreach ($r in $rows) {
    Enable-CucmUserMobility -UserId $r.UserId
    Set-CucmUserPrimaryExtension -UserId $r.UserId -Pattern $r.DeskDn -Partition $r.DeskDnPartition

    New-CucmRemoteDestinationProfile `
      -UserId $r.UserId `
      -RdpName $r.RdpName `
      -DevicePool $r.DevicePool `
      -Css $r.Css `
      -RerouteCss $r.RerouteCss `
      -DeskDn $r.DeskDn `
      -DeskDnPartition $r.DeskDnPartition

    New-CucmRemoteDestination `
      -RdpName $r.RdpName `
      -UserId $r.UserId `
      -DestinationNumber $r.MobileDestinationDigits `
      -MobilityCss $r.MobilityCss `
      -RdName $r.RdName
}
```

Optional if CUCM requires it:

```powershell
Invoke-CucmApplyLine -Pattern $r.DeskDn -RoutePartitionName $r.DeskDnPartition
Invoke-CucmResetLine -Pattern $r.DeskDn -RoutePartitionName $r.DeskDnPartition
```

## Bulk Teams Enterprise Voice provisioning

```powershell
Import-Module ".\Enable Teams.psm1"

Connect-MicrosoftTeams

$rows = Import-Csv .\snr-users.csv

foreach ($r in $rows) {
    Enable-TeamsEnterpriseVoiceUser `
      -Identity $r.Upn `
      -PhoneNumberE164 $r.MobileNumberE164 `
      -PhoneNumberType $r.PhoneNumberType `
      -TenantDialPlan $r.TenantDialPlan `
      -VoiceRoutingPolicy $r.VoiceRoutingPolicy `
      -TeamsCallingPolicy $r.TeamsCallingPolicy `
      -OnlineVoicemailPolicy $r.OnlineVoicemailPolicy `
      -EnableVoicemail
}
```

## Notes

- CUCM 12.5 requires rerouteCallingSearchSpaceName, not reroutingCallingSearchSpaceName.
- Many AXL fields are silently ignored if incorrect. Always read back config.
- CUCM may not apply SNR changes until the DN is applied or reset.

## Disclaimer

This module is not affiliated with Cisco or Microsoft. Test before production use.

function Enable-TeamsEnterpriseVoiceUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,            # UPN recommended (user@domain.com)
        [Parameter(Mandatory)][string]$PhoneNumberE164,     # +16045551234 (or OperatorConnect format)
        [Parameter(Mandatory)]
        [ValidateSet("DirectRouting","CallingPlan","OperatorConnect","TeamsPhoneMobile")]
        [string]$PhoneNumberType,

        [string]$TenantDialPlan,                            # e.g. "Canada-DialPlan"
        [string]$VoiceRoutingPolicy,                        # e.g. "DR-Canada-Policy"
        [string]$TeamsCallingPolicy,                        # optional: policy that allows voicemail
        [string]$OnlineVoicemailPolicy,                     # optional: e.g. "TranscriptionDisabled"  

        [switch]$EnableVoicemail                            # if set, enforce policies that allow voicemail
    )

    # --- Connect (assumes you already authenticated elsewhere, but we’ll be safe) ---
    if (-not (Get-Module MicrosoftTeams -ListAvailable)) {
        throw "MicrosoftTeams PowerShell module not found. Install-Module MicrosoftTeams"
    }

    # If you want this function to also connect automatically, uncomment:
    # Connect-MicrosoftTeams

    Write-Host "[Enable-TeamsEnterpriseVoiceUser] Assigning phone number and enabling Enterprise Voice..." -ForegroundColor Cyan

    # Assigning a phone number sets EnterpriseVoiceEnabled automatically (per Microsoft). 
    Set-CsPhoneNumberAssignment -Identity $Identity -PhoneNumber $PhoneNumberE164 -PhoneNumberType $PhoneNumberType

    # --- Dial plan ---
    if ($TenantDialPlan) {
        Write-Host "[Enable-TeamsEnterpriseVoiceUser] Granting tenant dial plan '$TenantDialPlan'..." -ForegroundColor Cyan
        Grant-CsTenantDialPlan -Identity $Identity -PolicyName $TenantDialPlan  # 
    }

    # --- Voice routing (Direct Routing scenarios) ---
    if ($VoiceRoutingPolicy) {
        Write-Host "[Enable-TeamsEnterpriseVoiceUser] Granting voice routing policy '$VoiceRoutingPolicy'..." -ForegroundColor Cyan
        Grant-CsOnlineVoiceRoutingPolicy -Identity $Identity -PolicyName $VoiceRoutingPolicy  # 
    }

    # --- Voicemail gating (Teams) ---
    if ($EnableVoicemail) {
        # 1) Teams Calling Policy must allow voicemail (AllowVoicemail = UserOverride or AlwaysEnabled). 
        if ($TeamsCallingPolicy) {
            Write-Host "[Enable-TeamsEnterpriseVoiceUser] Granting Teams Calling Policy '$TeamsCallingPolicy' (should allow voicemail)..." -ForegroundColor Cyan
            Grant-CsTeamsCallingPolicy -Identity $Identity -PolicyName $TeamsCallingPolicy
        }
        else {
            Write-Host "[Enable-TeamsEnterpriseVoiceUser] NOTE: No TeamsCallingPolicy provided. Ensure user's assigned calling policy allows voicemail (AllowVoicemail)." -ForegroundColor Yellow
        }

        # 2) Optionally assign an Online Voicemail Policy (transcription, etc.) 
        if ($OnlineVoicemailPolicy) {
            Write-Host "[Enable-TeamsEnterpriseVoiceUser] Granting Online Voicemail Policy '$OnlineVoicemailPolicy'..." -ForegroundColor Cyan
            Grant-CsOnlineVoicemailPolicy -Identity $Identity -PolicyName $OnlineVoicemailPolicy
        }
    }

    Write-Host "[Enable-TeamsEnterpriseVoiceUser] Done for $Identity" -ForegroundColor Green

    # Return a quick verification snapshot
    [pscustomobject]@{
        Identity            = $Identity
        PhoneNumber         = $PhoneNumberE164
        PhoneNumberType     = $PhoneNumberType
        TenantDialPlan      = $TenantDialPlan
        VoiceRoutingPolicy  = $VoiceRoutingPolicy
        TeamsCallingPolicy  = $TeamsCallingPolicy
        OnlineVoicemailPolicy = $OnlineVoicemailPolicy
        VoicemailRequested  = [bool]$EnableVoicemail
    }
}


# =========================
# Export everything (all public)
# =========================

Export-ModuleMember -Function *
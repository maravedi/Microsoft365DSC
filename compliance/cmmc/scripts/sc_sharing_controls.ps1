#requires -Modules Microsoft.Online.SharePoint.PowerShell, MicrosoftTeams, ExchangeOnlineManagement
<#
.SYNOPSIS
Hardens SharePoint Online, OneDrive, Teams, and Exchange sharing pathways for GCC High tenants per CMMC / NIST 800-171 R2 SC & MP requirements.

.DESCRIPTION
Applies least-privilege external collaboration rules, link protections, domain allow/block lists, Teams federation restrictions, and disables automatic forwarding to reduce data exfiltration risk.

.PARAMETER context
Hashtable containing:
    admin_upn           - Work account with SharePoint/Teams/Exchange admin rights.
    spo_admin_url       - SharePoint admin URL (https://tenant-admin.sharepoint.us).
    sharing_mode        - Optional SharingCapability (Default ExistingExternalUserSharingOnly).
    allowed_domains     - Optional allow list for external sharing.
    blocked_domains     - Optional deny list override.
    default_link_scope  - Optional default link type (Direct | Internal).

.NOTES
Targets SC.L2-3.13.1, SC.L2-3.13.8, SC.L2-3.13.16, MP.L2-3.8.3.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$context
)

$ErrorActionPreference = 'Stop'

function Get-CmmcSharingContext {
    param(
        [hashtable]$input_object
    )

    $required = @('admin_upn', 'spo_admin_url')
    foreach ($key in $required) {
        if (-not $input_object[$key]) {
            throw "Context missing '$key'."
        }
    }

    return @{
        admin_upn          = [string]$input_object.admin_upn
        spo_admin_url      = [string]$input_object.spo_admin_url
        sharing_mode       = if ($input_object.sharing_mode) { [string]$input_object.sharing_mode } else { 'ExistingExternalUserSharingOnly' }
        allowed_domains    = @($input_object.allowed_domains)
        blocked_domains    = @($input_object.blocked_domains)
        default_link_scope = if ($input_object.default_link_scope) { [string]$input_object.default_link_scope } else { 'Direct' }
    }
}

function Write-CmmcSharingLog {
    param(
        [string]$control_id,
        [string]$action,
        [string]$status = 'success',
        [string]$details
    )

    $payload = [pscustomobject]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        module     = 'sc_sharing_controls'
        control_id = $control_id
        action     = $action
        status     = $status
        details    = $details
    }
    Write-Host ($payload | ConvertTo-Json -Compress)
    return $payload
}

function Connect-CmmcSharePoint {
    param(
        [hashtable]$ctx
    )

    if (-not (Get-SPOSite -Limit 1 -ErrorAction SilentlyContinue)) {
        Connect-SPOService -Url $ctx.spo_admin_url | Out-Null
    }
}

function Connect-CmmcTeams {
    param(
        [hashtable]$ctx
    )

    if (-not (Get-CsTenant -ErrorAction SilentlyContinue)) {
        Connect-MicrosoftTeams -AccountId $ctx.admin_upn -TeamsEnvironmentName 'GccHigh' | Out-Null
    }
}

function Connect-CmmcExchangeSharing {
    param(
        [hashtable]$ctx
    )

    if (-not (Get-PSSession | Where-Object { $_.ComputerName -match 'ps\.outlook' })) {
        Connect-ExchangeOnline -UserPrincipalName $ctx.admin_upn -ShowBanner:$false -ExchangeEnvironmentName O365USGovGCCHigh | Out-Null
    }
}

function Configure-CmmcSharePointTenant {
    param(
        [hashtable]$ctx
    )

    $spoParams = @{
        SharingCapability                               = $ctx.sharing_mode
        RequireAcceptingAccountMatchInvitedAccount      = $true
        DefaultSharingLinkType                          = $ctx.default_link_scope
        PreventExternalUsersFromResharing               = $true
        ShowPeoplePickerSuggestionsForGuestUsers        = $false
        FilePickerExternalImageSearchEnabled            = $false
        ConditionalAccessPolicy                         = 'AllowLimitedAccess'
    }

    if ($ctx.allowed_domains -and $ctx.allowed_domains.Count -gt 0) {
        $spoParams.SharingDomainRestrictionMode = 'AllowList'
        $spoParams.SharingAllowedDomainList     = ($ctx.allowed_domains -join ',')
    } elseif ($ctx.blocked_domains -and $ctx.blocked_domains.Count -gt 0) {
        $spoParams.SharingDomainRestrictionMode = 'BlockList'
        $spoParams.SharingBlockedDomainList     = ($ctx.blocked_domains -join ',')
    }

    Set-SPOTenant @spoParams | Out-Null
    Set-SPOTenantSyncClientRestriction -Enable $true -DomainGuids @() -BlockMacSync $true -ExcludedFileExtensions 'exe','dll','ps1' | Out-Null

    return Write-CmmcSharingLog -control_id 'SC.L2-3.13.16' -action 'SharePoint/OneDrive Sharing' -details 'Applied restricted sharing configuration.'
}

function Configure-CmmcTeamsPolicies {
    param(
        [hashtable]$ctx
    )

    Set-CsTeamsClientConfiguration -AllowAudioConferencing:$false -AllowPrivateCalling $false -ContentPin $true | Out-Null
    Set-CsTeamsMeetingPolicy -Identity Global -AllowAnonymousUsersToStartMeeting $false -AllowOutlookAddIn $true -ScreenSharingMode 'SingleApplication' | Out-Null
    Set-CsTeamsMessagingPolicy -Identity Global -AllowUserDeleteMessage $false -AllowOwnerDeleteMessage $true -ReadReceiptsEnabled 'UserPreference' -AllowRemoveUser $false | Out-Null
    Set-CsTenantFederationConfiguration -AllowFederatedUsers $false -AllowPublicUsers $false -AllowTeamsConsumer $false | Out-Null

    return Write-CmmcSharingLog -control_id 'SC.L2-3.13.8' -action 'Teams Federation' -details 'Disabled external federation and tightened messaging policies.'
}

function Configure-CmmcExchangeForwarding {
    param(
        [hashtable]$ctx
    )

    Set-RemoteDomain Default -AutoForwardEnabled $false -AutoReplyEnabled $true -DeliveryReportEnabled $true | Out-Null
    Set-TransportConfig -ExternalPostmasterAddress $ctx.admin_upn -JournalingReportNdrTo $ctx.admin_upn | Out-Null

    return Write-CmmcSharingLog -control_id 'SC.L2-3.13.1' -action 'Exchange Auto-Forward' -details 'Disabled automatic external forwarding on default remote domain.'
}

$ctx = Get-CmmcSharingContext -input_object $context
Connect-CmmcSharePoint -ctx $ctx
Connect-CmmcTeams -ctx $ctx
Connect-CmmcExchangeSharing -ctx $ctx

$results = @()
$results += Configure-CmmcSharePointTenant -ctx $ctx
$results += Configure-CmmcTeamsPolicies -ctx $ctx
$results += Configure-CmmcExchangeForwarding -ctx $ctx

return @{
    family  = 'SC/MP'
    outcome = $results
}

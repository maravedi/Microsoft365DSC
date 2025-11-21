Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stubRoot = Join-Path -Path $repoRoot -ChildPath '.graph_stubs'
if (-not (Test-Path -Path $stubRoot))
{
    New-Item -Path $stubRoot -ItemType Directory -Force | Out-Null
}
$env:PSModulePath = '{0}{1}{2}' -f $stubRoot, [IO.Path]::PathSeparator, $env:PSModulePath

$msclaManifest = Join-Path -Path $repoRoot -ChildPath 'MSCloudLoginAssistant/Modules/MSCloudLoginAssistant/MSCloudLoginAssistant.psd1'
$m365Manifest = Join-Path -Path $repoRoot -ChildPath 'Modules/Microsoft365DSC/Microsoft365DSC.psd1'

$Global:M365DSCSkipDependenciesValidation = $true

Import-Module -Name $msclaManifest -Force
Import-Module -Name $m365Manifest -Force

$m365Module = Get-Module -Name Microsoft365DSC
$m365UtilModule = Get-Module -Name M365DSCUtil
& $m365Module { $Script:M365DSCRequiredModules = @() }
if ($null -ne $m365UtilModule)
{
    & $m365UtilModule { $Script:M365DSCRequiredModules = @() }
}

Reset-MSCloudLoginConnectionProfileContext

$gcchInfo = [pscustomobject]@{
    tenant_region_scope     = 'USGov'
    tenant_region_sub_scope = 'USGov'
    token_endpoint          = 'https://login.microsoftonline.us/contoso.onmicrosoft.us/oauth2/v2.0/token'
}

$msclaModule = Get-Module -Name MSCloudLoginAssistant
& $msclaModule {
    param($cloudInfo)
    $Script:CloudEnvironmentInfo = $cloudInfo
    $Script:MSCloudLoginTriedGetEnvironment = $true
} $gcchInfo

function Set-TestCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    return [pscredential]::new($UserName, $securePassword)
}

function Connect-MicrosoftTeams {
    [CmdletBinding()]
    param(
        [string]$ApplicationId,
        [string]$TenantId,
        [string]$CertificateThumbprint,
        [PSCredential]$Credential,
        [object[]]$AccessTokens,
        [hashtable]$EndpointUris,
        [string]$TeamsEnvironmentName
    )

    $script:teamsInvocation = $PSBoundParameters
}

function Disconnect-MicrosoftTeams {
    [CmdletBinding()]
    param()
}

function Get-CsTeamsCallingPolicy {
    [CmdletBinding()]
    param()

    return $null
}

function Get-PSSession {
    [CmdletBinding()]
    param()

    return @()
}

function Connect-ExchangeOnline {
    [CmdletBinding()]
    param(
        [PSCredential]$Credential,
        [string]$AppId,
        [string]$Organization,
        [string]$CertificateThumbprint,
        [string]$ConnectionUri,
        [string]$AzureADAuthorizationEndpointUri,
        [string]$ExchangeEnvironmentName,
        [switch]$SkipLoadingCmdletHelp,
        [switch]$ShowBanner,
        [switch]$ShowProgress,
        [hashtable]$CommandName,
        [string]$DelegatedOrganization,
        [switch]$ManagedIdentity,
        [string]$AccessToken
    )

    $script:exoInvocation = $PSBoundParameters
}

function Disconnect-ExchangeOnline {
    [CmdletBinding()]
    param(
        [switch]$Confirm
    )
}

function Import-PSSession {
    [CmdletBinding()]
    param(
        $Session,
        [switch]$DisableNameChecking,
        [switch]$AllowClobber
    )

    return 'ProxyModule'
}

$credential = Set-TestCredential -UserName 'automation@contoso.onmicrosoft.us' -Password 'Pass!word1'
$tenantId = 'contoso.onmicrosoft.us'

$teamsResult = New-M365DSCConnection -Workload 'MicrosoftTeams' -InboundParameters @{
    Credential = $credential
    TenantId   = $tenantId
} -SkipModuleReload $true
$teamsProfile = Get-MSCloudLoginConnectionProfile -Workload 'MicrosoftTeams'
if ($null -eq $teamsProfile)
{
    $teamsProfile = & $msclaModule { $Script:MSCloudLoginConnectionProfile.Teams.Clone() }
}

$exoResult = New-M365DSCConnection -Workload 'ExchangeOnline' -InboundParameters @{
    Credential = $credential
    TenantId   = $tenantId
} -SkipModuleReload $true
$exoProfile = Get-MSCloudLoginConnectionProfile -Workload 'ExchangeOnline'

$report = [ordered]@{
    teams_connection_mode        = $teamsResult
    teams_environment_name       = $teamsProfile.EnvironmentName
    teams_authentication_type    = $teamsProfile.AuthenticationType
    teams_parameter_snapshot     = $script:teamsInvocation
    exchange_connection_mode     = $exoResult
    exchange_environment_name    = $exoProfile.EnvironmentName
    exchange_exo_environment     = $exoProfile.ExchangeEnvironmentName
    exchange_authentication_type = $exoProfile.AuthenticationType
    exchange_parameter_snapshot  = $script:exoInvocation
}

$report | ConvertTo-Json -Depth 4

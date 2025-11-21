#requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
Enables auditing, logging, and evidence retention in Exchange Online / Purview for GCC High tenants to align with CMMC / NIST 800-171 R2 AU controls.

.DESCRIPTION
Turns on Unified Audit Log ingestion, mailbox auditing (admin/delegate/owner), extended retention, and advanced audit policies. Uses Exchange Online and Security & Compliance PowerShell without DSC.

.PARAMETER context
Hashtable containing:
    admin_upn           - Work account with compliance permissions.
    log_retention_days  - Desired audit log age (default 365).
    mailbox_scope       - Optional array of SMTP addresses to scope mailbox auditing (defaults to all user mailboxes).
    workload_filters    - Optional list of workloads for Unified Audit retention rules.

.NOTES
Targets AU.L2-3.3.1, AU.L2-3.3.2, AU.L2-3.3.7, AU.L2-3.3.8, IR.L2-3.6.1 evidence needs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$context
)

$ErrorActionPreference = 'Stop'

function Get-CmmcAuditContext {
    [CmdletBinding()]
    param(
        [hashtable]$input_object
    )

    if (-not $input_object.admin_upn) {
        throw "Context missing 'admin_upn'."
    }

    return @{
        admin_upn          = [string]$input_object.admin_upn
        log_retention_days = if ($input_object.log_retention_days) { [int]$input_object.log_retention_days } else { 365 }
        mailbox_scope      = @($input_object.mailbox_scope)
        workload_filters   = if ($input_object.workload_filters) { @($input_object.workload_filters) } else { @('Exchange', 'SharePoint', 'AzureActiveDirectory') }
    }
}

function Write-CmmcAuditLog {
    param(
        [string]$control_id,
        [string]$action,
        [string]$status = 'success',
        [string]$details
    )

    $payload = [pscustomobject]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        module     = 'au_audit_accountability'
        control_id = $control_id
        action     = $action
        status     = $status
        details    = $details
    }
    Write-Host ($payload | ConvertTo-Json -Compress)
    return $payload
}

function Connect-CmmcExchange {
    param(
        [hashtable]$ctx
    )

    if (-not (Get-PSSession | Where-Object { $_.ComputerName -match 'ps\.outlook' })) {
        Connect-ExchangeOnline -UserPrincipalName $ctx.admin_upn -ShowBanner:$false -ExchangeEnvironmentName O365USGovGCCHigh | Out-Null
    }
}

function Connect-CmmcCompliance {
    param(
        [hashtable]$ctx
    )

    if (-not (Get-PSSession | Where-Object { $_.ComputerName -match 'compliance\.office365\.us' })) {
        Connect-IPPSSession -UserPrincipalName $ctx.admin_upn `
            -ConnectionUri 'https://ps.compliance.protection.office365.us/powershell-liveid/' `
            -AzureADAuthorizationEndpointUri 'https://login.microsoftonline.us/common' | Out-Null
    }
}

function Enable-CmmcUnifiedAuditLog {
    param(
        [hashtable]$ctx
    )

    Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled:$true -TestCmdletLoggingEnabled:$true -AdminAuditLogEnabled:$true | Out-Null
    return Write-CmmcAuditLog -control_id 'AU.L2-3.3.1' -action 'Unified Audit Log' -details 'Unified audit log ingestion enabled.'
}

function Enable-CmmcMailboxAuditing {
    param(
        [hashtable]$ctx
    )

    Set-OrganizationConfig -AuditDisabled $false | Out-Null
    $auditOwnerActions    = @('HardDelete','SoftDelete','Update','MoveToDeletedItems','Move')
    $auditAdminActions    = @('Copy','Create','FolderBind','HardDelete','MessageBind','Move','SendAs','SendOnBehalf','Update')
    $auditDelegateActions = @('CalendarAccess','FolderBind','HardDelete','MessageBind','SendAs','SendOnBehalf','SoftDelete')

    $mailboxes = if ($ctx.mailbox_scope -and $ctx.mailbox_scope.Count -gt 0) {
        $ctx.mailbox_scope
    } else {
        (Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox | Select-Object -ExpandProperty PrimarySmtpAddress)
    }

    foreach ($mailbox in $mailboxes) {
        Set-Mailbox -Identity $mailbox `
            -AuditEnabled $true `
            -AuditOwner $auditOwnerActions `
            -AuditAdmin $auditAdminActions `
            -AuditDelegate $auditDelegateActions `
            -AuditLogAgeLimit (New-TimeSpan -Days $ctx.log_retention_days) `
            -Confirm:$false | Out-Null
    }

    return Write-CmmcAuditLog -control_id 'AU.L2-3.3.2' -action 'Mailbox Auditing' -details "Enabled mailbox auditing for $($mailboxes.Count) mailboxes."
}

function Set-CmmcUnifiedAuditRetention {
    param(
        [hashtable]$ctx
    )

    $policyName = 'CMMC-All-Workloads'
    $policy = Get-UnifiedAuditLogRetentionPolicy -Identity $policyName -ErrorAction SilentlyContinue
    if ($policy) {
        Set-UnifiedAuditLogRetentionPolicy -Identity $policyName -RetentionDuration $ctx.log_retention_days -Workload $ctx.workload_filters | Out-Null
        return Write-CmmcAuditLog -control_id 'AU.L2-3.3.7' -action 'Audit Retention' -details "Updated retention to $($ctx.log_retention_days) days."
    }

    New-UnifiedAuditLogRetentionPolicy -Name $policyName -Workload $ctx.workload_filters -Action 'All' -RetentionDuration $ctx.log_retention_days | Out-Null
    return Write-CmmcAuditLog -control_id 'AU.L2-3.3.7' -action 'Audit Retention' -details 'Created new retention policy.'
}

function Enable-CmmcAdvancedAudit {
    param(
        [hashtable]$ctx
    )

    Set-AdminAuditLogConfig -LogLevel Verbose | Out-Null
    return Write-CmmcAuditLog -control_id 'AU.L2-3.3.8' -action 'Advanced Audit' -details 'Elevated audit log verbosity.'
}

$ctx = Get-CmmcAuditContext -input_object $context
Connect-CmmcExchange -ctx $ctx
Connect-CmmcCompliance -ctx $ctx

$results = @()
$results += Enable-CmmcUnifiedAuditLog -ctx $ctx
$results += Enable-CmmcMailboxAuditing -ctx $ctx
$results += Set-CmmcUnifiedAuditRetention -ctx $ctx
$results += Enable-CmmcAdvancedAudit -ctx $ctx

return @{
    family  = 'AU'
    outcome = $results
}

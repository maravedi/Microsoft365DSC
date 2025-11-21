#requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Beta.Identity.SignIns
<#
.SYNOPSIS
Configures Azure AD (Entra ID) conditional access and identity protection controls for GCC High tenants targeting CMMC / NIST 800-171 R2 AC & IA requirements.

.DESCRIPTION
Implements baseline policies that enforce phishing-resistant MFA for privileged roles, block legacy protocols, enforce session controls, and harden authentication method policies. Uses Microsoft Graph in the US Gov High cloud without relying on DSC.

.PARAMETER context
Hashtable containing:
    tenant_id                - Directory tenant GUID.
    admin_upn                - Work account used to authenticate.
    privileged_role_ids      - Array of directory role IDs (e.g., Global Administrator) requiring stricter controls.
    break_glass_upns         - Array of emergency accounts excluded from CA.
    trusted_location_ids     - Optional array of named locations that are compliant (GUIDs).
    sign_in_frequency_hours  - Optional sign-in frequency (default 8 hours).
    conditional_access_state - Optional CA policy state (enabled | enabledForReportingButNotEnforced).
    authentication_strength  - Optional authentication strength policy ID for phishing-resistant MFA.

.NOTES
Maps primarily to controls AC.L2-3.1.1, AC.L2-3.1.2, AC.L2-3.1.5, AC.L2-3.1.18, IA.L2-3.5.3, IA.L2-3.5.7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$context
)

$ErrorActionPreference = 'Stop'

function Get-CmmcAccessControlContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$input_object
    )

    $required = @('tenant_id', 'admin_upn', 'privileged_role_ids', 'break_glass_upns')
    foreach ($key in $required) {
        if (-not ($input_object.ContainsKey($key) -and $null -ne $input_object[$key] -and $input_object[$key].Count -ne 0)) {
            throw "Context missing required key '$key'."
        }
    }

    return @{
        tenant_id               = [string]$input_object.tenant_id
        admin_upn               = [string]$input_object.admin_upn
        privileged_role_ids     = @($input_object.privileged_role_ids)
        break_glass_upns        = @($input_object.break_glass_upns)
        trusted_location_ids    = @($input_object.trusted_location_ids)
        fido2_allow_list        = @($input_object.fido2_allow_list)
        sign_in_frequency_hours = if ($input_object.sign_in_frequency_hours) { [int]$input_object.sign_in_frequency_hours } else { 8 }
        conditional_access_state= if ($input_object.conditional_access_state) { [string]$input_object.conditional_access_state } else { 'enabled' }
        authentication_strength = $input_object.authentication_strength
    }
}

function Write-CmmcLog {
    param(
        [string]$control_id,
        [string]$action,
        [string]$status = 'success',
        [string]$details
    )

    $payload = [pscustomobject]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        module     = 'ac_access_control'
        control_id = $control_id
        action     = $action
        status     = $status
        details    = $details
    }
    Write-Host ($payload | ConvertTo-Json -Compress)
    return $payload
}

function Connect-CmmcGraph {
    param(
        [hashtable]$ctx
    )

    $scopes = @(
        'Policy.ReadWrite.ConditionalAccess',
        'Directory.ReadWrite.All',
        'AuditLog.Read.All'
    )

    if (-not (Get-MgContext)) {
        Connect-MgGraph -TenantId $ctx.tenant_id -Environment 'USGovHigh' -Scopes $scopes | Out-Null
    }

    Select-MgProfile -Name beta
}

function Set-CmmcSecurityDefaults {
    param(
        [hashtable]$ctx
    )

    $policy = Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy
    if ($policy.IsEnabled) {
        Update-MgPolicyIdentitySecurityDefaultEnforcementPolicy -IsEnabled:$false | Out-Null
        return Write-CmmcLog -control_id 'AC.L2-3.1.2' -action 'Disable Security Defaults' -details 'Disabled Azure AD security defaults to allow granular CA policies.'
    }

    return Write-CmmcLog -control_id 'AC.L2-3.1.2' -action 'Disable Security Defaults' -status 'skipped' -details 'Already disabled.'
}

function Upsert-CmmcConditionalAccessPolicy {
    param(
        [string]$displayName,
        [hashtable]$body
    )

    $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$displayName'" -ErrorAction SilentlyContinue
    if ($existing) {
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $existing.Id -BodyParameter $body | Out-Null
        return 'updated'
    }

    New-MgIdentityConditionalAccessPolicy -BodyParameter $body | Out-Null
    return 'created'
}

function Set-CmmcMfaForPrivilegedRoles {
    param(
        [hashtable]$ctx
    )

    $policyBody = @{
        displayName = 'CMMC - Require MFA for Privileged Roles'
        state       = $ctx.conditional_access_state
        conditions  = @{
            users = @{
                includeRoles  = $ctx.privileged_role_ids
                excludeUsers  = $ctx.break_glass_upns
            }
            platforms = @{
                includePlatforms = @('all')
            }
            clientAppTypes = @('all')
            applications = @{
                includeApplications = @('All')
            }
        }
        grantControls = @{
            operator          = 'AND'
            builtInControls   = @('mfa')
        }
        sessionControls = @{
            signInFrequency = @{
                value     = $ctx.sign_in_frequency_hours
                type      = 'hours'
                isEnabled = $true
            }
        }
    }

    if ($ctx.authentication_strength) {
        $policyBody.grantControls.authenticationStrength = @{
            id = $ctx.authentication_strength
        }
    }

    $result = Upsert-CmmcConditionalAccessPolicy -displayName $policyBody.displayName -body $policyBody
    return Write-CmmcLog -control_id 'IA.L2-3.5.3' -action $policyBody.displayName -details "Policy $result."
}

function Set-CmmcBlockLegacyAuth {
    param(
        [hashtable]$ctx
    )

    $policyBody = @{
        displayName = 'CMMC - Block Legacy Authentication'
        state       = $ctx.conditional_access_state
        conditions  = @{
            users = @{
                includeUsers = @('All')
                excludeUsers = $ctx.break_glass_upns
            }
            clientAppTypes = @('exchangeActiveSync', 'other')
        }
        grantControls = @{
            operator        = 'OR'
            builtInControls = @('block')
        }
    }

    $result = Upsert-CmmcConditionalAccessPolicy -displayName $policyBody.displayName -body $policyBody
    return Write-CmmcLog -control_id 'SC.L2-3.13.8' -action $policyBody.displayName -details "Policy $result."
}

function Set-CmmcRequireMfaOutsideTrustedLocations {
    param(
        [hashtable]$ctx
    )

    if (-not $ctx.trusted_location_ids -or $ctx.trusted_location_ids.Count -eq 0) {
        return Write-CmmcLog -control_id 'AC.L2-3.1.5' -action 'Trusted Location MFA' -status 'skipped' -details 'No trusted locations supplied.'
    }

    $policyBody = @{
        displayName = 'CMMC - Enforce MFA Outside Trusted Locations'
        state       = $ctx.conditional_access_state
        conditions  = @{
            locations = @{
                includeLocations = @('All')
                excludeLocations = $ctx.trusted_location_ids
            }
            users = @{
                includeUsers = @('All')
                excludeUsers = $ctx.break_glass_upns
            }
            clientAppTypes = @('all')
        }
        grantControls = @{
            operator        = 'AND'
            builtInControls = @('mfa')
        }
    }

    $result = Upsert-CmmcConditionalAccessPolicy -displayName $policyBody.displayName -body $policyBody
    return Write-CmmcLog -control_id 'AC.L2-3.1.5' -action $policyBody.displayName -details "Policy $result."
}

function Set-CmmcAuthMethodPolicies {
    param(
        [hashtable]$ctx
    )

    $methods = Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration

    foreach ($method in $methods) {
        switch ($method.Id) {
            'sms' {
                Update-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId $method.Id -BodyParameter @{
                    id        = 'sms'
                    state     = 'disabled'
                } | Out-Null
                Write-CmmcLog -control_id 'IA.L2-3.5.7' -action 'Disable SMS MFA' -details 'Disabled SMS-based MFA to reduce OTP interception risk.' | Out-Null
            }
            'voice' {
                Update-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId $method.Id -BodyParameter @{
                    id        = 'voice'
                    state     = 'disabled'
                } | Out-Null
                Write-CmmcLog -control_id 'IA.L2-3.5.7' -action 'Disable Voice MFA' -details 'Disabled voice calls for MFA.' | Out-Null
            }
            'fido2' {
                $body = @{
                    id        = 'fido2'
                    state     = 'enabled'
                    isAttestationEnforced = $true
                }

                if ($ctx.fido2_allow_list -and $ctx.fido2_allow_list.Count -gt 0) {
                    $body.aaGuids = $ctx.fido2_allow_list
                }

                Update-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId $method.Id -BodyParameter $body | Out-Null
                Write-CmmcLog -control_id 'IA.L2-3.5.3' -action 'Enable FIDO2' -details 'Enabled phishing-resistant security keys.' | Out-Null
            }
            default { continue }
        }
    }

    return @{
        control_id = 'IA.L2-3.5.3'
        action     = 'Authentication Methods Hardened'
        status     = 'success'
    }
}

$ctx = Get-CmmcAccessControlContext -input_object $context
Connect-CmmcGraph -ctx $ctx | Out-Null

$results = @()
$results += Set-CmmcSecurityDefaults -ctx $ctx
$results += Set-CmmcMfaForPrivilegedRoles -ctx $ctx
$results += Set-CmmcBlockLegacyAuth -ctx $ctx
$results += Set-CmmcRequireMfaOutsideTrustedLocations -ctx $ctx
$results += Set-CmmcAuthMethodPolicies -ctx $ctx

return @{
    family  = 'AC/IA'
    outcome = $results
}

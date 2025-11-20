# GCCH/Sovereign Cloud Support Implementation Guide

## Overview

This guide documents the correct implementation of GCCH (Government Community Cloud - High) and other sovereign cloud support in Microsoft365DSC.

## Key Insights

### Environment Parameter Values

**IMPORTANT**: The environment parameter uses MSCloudLoginAssistant's environment values:

- **Global**: Commercial cloud (graph.microsoft.com, login.microsoftonline.com)
- **USGov**: US Government clouds - covers BOTH GCC and GCC High (GCCH)
  - Endpoints: graph.microsoft.us, login.microsoftonline.us  
  - **USGov is the correct value for GCCH tenants** (not a separate "USGovHigh")
- **USGovDoD**: Department of Defense cloud
  - Endpoints: dod-graph.microsoft.us, login.microsoftonline.us
- **China**: Azure China (21Vianet)
  - Endpoints: microsoftgraph.chinacloudapi.cn, login.chinacloudapi.cn
- **Germany**: Microsoft Cloud Germany (being deprecated)

## What Was Implemented

### 1. Core Connection Infrastructure ✅

**File**: `Modules/Microsoft365DSC/Modules/M365DSCUtil.psm1`

#### Added Environment Parameter to New-M365DSCConnection:

```powershell
[Parameter()]
[ValidateSet('Global', 'China', 'USGov', 'USGovDoD', 'Germany')]
[System.String]
$Environment = 'Global'
```

#### Enabled Environment from InboundParameters:

```powershell
# Check if Environment was passed in InboundParameters and use it
if ($InboundParameters.ContainsKey('Environment') -and -not [String]::IsNullOrEmpty($InboundParameters.Environment))
{
    $Environment = $InboundParameters.Environment
    Write-Verbose -Message "Using Environment from InboundParameters: $Environment"
}
```

#### Updated All Connect-M365Tenant Calls:

All 11 calls to `Connect-M365Tenant` now include `-Environment $Environment` parameter, which gets passed to MSCloudLoginAssistant.

###  2. Fixed Hardcoded Endpoints ✅

**File**: `Modules/Microsoft365DSC/Modules/M365DSCPermissions.psm1`

Updated admin consent functionality to dynamically detect government cloud tenants:

```powershell
# Determine login endpoint based on tenant domain (*.us = USGov, *.cn = China)
$loginEndpoint = 'https://login.microsoftonline.com'
if ($tenantid -match '\.us$')
{
    $loginEndpoint = 'https://login.microsoftonline.us'
    Write-Verbose "Detected US Government tenant, using $loginEndpoint"
}
elseif ($tenantid -match '\.cn$')
{
    $loginEndpoint = 'https://login.chinacloudapi.cn'
    Write-Verbose "Detected China tenant, using $loginEndpoint"
}
```

### 3. Proof-of-Concept Resource Implementation ✅

**Resource**: AADApplication

Added Environment parameter to:
- Schema file (.mof)
- All three functions (Get-TargetResource, Set-TargetResource, Test-TargetResource)

## How to Add Environment Support to Additional Resources

###  Step 1: Update the Schema File (.schema.mof)

Add the Environment parameter to the end of the resource class definition:

```mof
[Write, Description("Specifies the cloud environment (Global, USGov for GCC/GCCH, USGovDoD, China, Germany). USGov covers both GCC and GCC High (GCCH) tenants."), ValueMap{"Global","USGov","USGovDoD","China","Germany"}, Values{"Global","USGov","USGovDoD","China","Germany"}] String Environment;
```

**Example location**: Just before the closing `};` of the main resource class.

### Step 2: Update the Resource Module (.psm1)

Add the Environment parameter to ALL THREE functions:

#### Get-TargetResource

Add before the closing `)` of the param block:

```powershell
[Parameter()]
[ValidateSet('Global', 'USGov', 'USGovDoD', 'China', 'Germany')]
[System.String]
$Environment = 'Global'
```

#### Set-TargetResource

Same parameter addition as Get-TargetResource.

#### Test-TargetResource

Same parameter addition as Get-TargetResource.

### Step 3: No Additional Code Changes Needed!

The Environment parameter will automatically flow through `$PSBoundParameters` to `New-M365DSCConnection`, which will pass it to `Connect-M365Tenant`.

**That's it!** The connection infrastructure handles the rest.

## Usage Examples

### Example 1: GCCH Tenant with Certificate Authentication

```powershell
Configuration GCCHConfig {
    Import-DscResource -ModuleName Microsoft365DSC
    
    Node localhost {
        AADApplication 'MyGCCHApp' {
            DisplayName           = 'GCCH Test App'
            Ensure                = 'Present'
            ApplicationId         = '12345678-1234-1234-1234-123456789012'
            TenantId              = 'contoso.onmicrosoft.us'  # Note: .us domain
            CertificateThumbprint = 'A1B2C3D4...'
            Environment           = 'USGov'                     # GCCH uses USGov
        }
    }
}
```

### Example 2: Export from GCCH Tenant

```powershell
Export-M365DSCConfiguration `
    -Components @('AADApplication', 'AADUser') `
    -ApplicationId '12345678-1234-1234-1234-123456789012' `
    -TenantId 'contoso.onmicrosoft.us' `
    -CertificateThumbprint 'A1B2C3D4...'

# Note: Environment detection may be automatic based on TenantId domain
```

### Example 3: Programmatic Resource Invocation

```powershell
$params = @{
    DisplayName           = 'MyApp'
    Ensure                = 'Present'
    ApplicationId         = '12345678-1234-1234-1234-123456789012'
    TenantId              = 'contoso.onmicrosoft.us'
    CertificateThumbprint = 'A1B2C3D4...'
    Environment           = 'USGov'  # Specify GCCH environment
}

$result = Get-TargetResource @params
```

## Environment Detection

### Automatic Detection (Best Practice)

MSCloudLoginAssistant can often automatically detect the environment based on:
- Tenant ID domain (.us for USGov, .cn for China)
- Token endpoints discovered during authentication

### Explicit Specification (Recommended)

For clarity and to avoid ambiguity, explicitly specify the Environment parameter:

```powershell
Environment = 'USGov'  # For GCCH tenants
```

## Testing GCCH Connectivity

### Prerequisite

1. **MSCloudLoginAssistant** v1.1.54+ must be installed
2. Service Principal with appropriate permissions in GCCH tenant
3. Certificate authentication configured

### Test Script

```powershell
# Import the module
Import-Module Microsoft365DSC

# Test connection parameters
$connectionParams = @{
    ApplicationId         = 'your-app-id'
    TenantId              = 'contoso.onmicrosoft.us'
    CertificateThumbprint = 'your-cert-thumbprint'
    Environment           = 'USGov'
}

# Try to retrieve a simple resource
try {
    $aadUser = Get-TargetResource -UserPrincipalName 'testuser@contoso.onmicrosoft.us' @connectionParams
    Write-Host "✅ Successfully connected to GCCH tenant!" -ForegroundColor Green
    Write-Host "Retrieved user: $($aadUser.DisplayName)"
}
catch {
    Write-Host "❌ Connection failed: $_" -ForegroundColor Red
}
```

## Important Notes

### 1. USGov Covers Both GCC and GCCH

- **Do NOT create a separate "USGovHigh" environment**
- USGov in MSCloudLoginAssistant covers:
  - GCC (Government Community Cloud)
  - GCCH (GCC High)
- Both use the same endpoints (*.microsoft.us)

### 2. Tenant Domain Indicates Environment

- **.onmicrosoft.com** = Global/Commercial
- **.onmicrosoft.us** = USGov (GCC/GCCH)  
- **.onmicrosoft.de** = Germany
- **.partner.onmschina.cn** = China

### 3. Not All Services Available in GCCH

Some Microsoft 365 services have limited availability in GCCH:
- Some Viva features
- Some Power Platform connectors
- Preview/beta features

Resources may fail if the underlying service isn't available in GCCH.

### 4. Certificate Authentication Recommended

For production GCCH deployments, use certificate-based authentication with service principals rather than credential-based authentication.

## Resources Updated So Far

### Fully Implemented (1 resource)
- ✅ MSFT_AADApplication

### Pending Updates (504 resources)

All remaining resources need the Environment parameter added following the pattern documented in this guide:

- MSFT_AADUser
- MSFT_AADGroup
- MSFT_EXOAcceptedDomain
- MSFT_TeamsTeam
- ... (and 500+ more)

## Automation Script (Optional)

For bulk updates, a PowerShell script can be created to add the Environment parameter to all resources systematically. Here's the pattern:

```powershell
# Pseudo-code for bulk update
$resources = Get-ChildItem -Path "DSCResources\MSFT_*" -Directory

foreach ($resource in $resources) {
    # 1. Update .schema.mof - add Environment parameter
    # 2. Update .psm1 - add Environment to all 3 functions
    # 3. Validate syntax
}
```

**Note**: Manual review recommended for each resource to ensure compatibility.

## Troubleshooting

### Issue: "Unable to connect to USGov environment"

**Solution**: Verify:
1. MSCloudLoginAssistant is v1.1.54 or later
2. TenantId uses .onmicrosoft.us domain
3. Service principal exists in GCCH tenant (not commercial)
4. Certificate is installed and accessible

### Issue: "Resource doesn't accept Environment parameter"

**Solution**: The resource hasn't been updated yet. Update following this guide or use a resource that supports it (like AADApplication).

### Issue: "Authentication fails with 'Invalid audience'"

**Solution**: Tokens are environment-specific. Ensure you're authenticating against the correct environment endpoints (USGov for GCCH).

## Future Enhancements

### Potential Improvements

1. **Automatic Environment Detection**: Enhance `New-M365DSCConnection` to auto-detect environment from TenantId domain
2. **Resource Generator Updates**: Update ResourceGenerator templates to include Environment parameter by default
3. **Bulk Update Script**: Create tested script to update all 505 resources systematically  
4. **Integration Tests**: Add GCCH-specific integration test suite
5. **Documentation**: Add GCCH examples to each resource's documentation

### Settings.json Considerations

The `supportedEnvironments` array in settings.json files should list which environments the resource supports:

```json
"supportedEnvironments": [
    "Global",
    "USGov"
]
```

**Note**: Most Azure AD, Exchange, Teams, and SPO resources should support USGov (GCCH).

## Related Documentation

- [MSCloudLoginAssistant Documentation](https://github.com/Microsoft/MSCloudLoginAssistant)
- [Microsoft 365 Government Plans](https://learn.microsoft.com/microsoft-365/enterprise/microsoft-365-government-how-to)
- [Office 365 US Government Endpoints](https://learn.microsoft.com/microsoft-365/enterprise/microsoft-365-u-s-government-gcc-high-endpoints)

## Support

For issues or questions:
1. Check this guide first
2. Review MSCloudLoginAssistant documentation  
3. Open an issue at https://github.com/microsoft/Microsoft365DSC/issues

---

**Version**: 1.0  
**Last Updated**: November 2025  
**Status**: Core infrastructure complete, resource updates in progress

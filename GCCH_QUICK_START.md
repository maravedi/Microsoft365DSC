# GCCH Support - Quick Start Guide

## TL;DR

Microsoft365DSC now supports GCCH (GCC High) tenants! Use `Environment = 'USGov'` in your resources.

## What Changed

✅ **Core infrastructure updated** - Connection system now supports environment parameter  
✅ **Hardcoded endpoints fixed** - Dynamic endpoint detection for .us domains  
✅ **Proof-of-concept complete** - AADApplication resource fully supports GCCH  
⏳ **504 resources pending** - Need Environment parameter added (see implementation guide)

## Quick Example

```powershell
Configuration GCCHExample {
    Import-DscResource -ModuleName Microsoft365DSC
    
    Node localhost {
        AADApplication 'MyGCCHApp' {
            DisplayName           = 'GCCH Test App'
            Ensure                = 'Present'
            ApplicationId         = 'your-app-id'
            TenantId              = 'contoso.onmicrosoft.us'  # .us = GCCH
            CertificateThumbprint = 'your-cert-thumbprint'
            Environment           = 'USGov'                     # GCCH = USGov
        }
    }
}
```

## Key Facts

| Environment Value | Cloud Type | Tenant Domain | Graph Endpoint |
|-------------------|------------|---------------|----------------|
| **USGov** | GCC + GCCH | *.onmicrosoft.us | graph.microsoft.us |
| USGovDoD | DoD Cloud | *.onmicrosoft.us | dod-graph.microsoft.us |
| Global | Commercial | *.onmicrosoft.com | graph.microsoft.com |
| China | 21Vianet | *.onmschina.cn | microsoftgraph.chinacloudapi.cn |

**Important**: `USGov` covers BOTH GCC and GCC High (GCCH)!

## What Works Now

✅ Connection infrastructure supports all environments  
✅ MSCloudLoginAssistant handles endpoint routing  
✅ AADApplication resource ready for GCCH  
✅ Dynamic endpoint detection for admin consent

## What Still Needs Work

❌ Most resources (504) don't expose Environment parameter yet  
❌ Need to add Environment to each resource's schema and functions  
❌ See GCCH_IMPLEMENTATION_GUIDE.md for how to update resources

## Files Modified

### Core Files (3)
1. `Modules/Microsoft365DSC/Modules/M365DSCUtil.psm1` - Connection infrastructure
2. `Modules/Microsoft365DSC/Modules/M365DSCPermissions.psm1` - Endpoint detection
3. `Modules/Microsoft365DSC/Microsoft365DSC.psd1` - Module manifest

### Resource Files (2)
1. `DSCResources/MSFT_AADApplication/MSFT_AADApplication.schema.mof` - Schema
2. `DSCResources/MSFT_AADApplication/MSFT_AADApplication.psm1` - Implementation

## Testing

```powershell
# Prerequisites
Install-Module MSCloudLoginAssistant -MinimumVersion 1.1.54

# Test connection
$params = @{
    ApplicationId         = 'your-app-id'
    TenantId              = 'contoso.onmicrosoft.us'
    CertificateThumbprint = 'your-thumbprint'
    Environment           = 'USGov'
}

# Try AADApplication (fully implemented)
Get-TargetResource -DisplayName 'TestApp' @params
```

## Next Steps

### For Users
1. Use AADApplication resource with Environment parameter
2. Wait for other resources to be updated
3. Or contribute by updating resources yourself!

### For Contributors
1. Read GCCH_IMPLEMENTATION_GUIDE.md
2. Pick a resource to update
3. Follow the 3-step pattern:
   - Update .schema.mof
   - Update .psm1 (3 functions)
   - Test!

## Common Issues

**Q: Can I use this with GCC (not GCCH)?**  
A: Yes! `Environment = 'USGov'` works for both GCC and GCCH.

**Q: Do I need to specify Environment for commercial cloud?**  
A: No, it defaults to 'Global' (commercial).

**Q: My resource doesn't have Environment parameter?**  
A: It needs to be updated. See the implementation guide or use AADApplication as a working example.

**Q: Authentication fails with GCCH tenant?**  
A: Verify:
- MSCloudLoginAssistant v1.1.54+  
- TenantId uses .onmicrosoft.us
- Service principal exists in GCCH (not commercial)

## Resources

- **Implementation Guide**: `GCCH_IMPLEMENTATION_GUIDE.md` (detailed technical guide)
- **MSCloudLoginAssistant**: https://github.com/Microsoft/MSCloudLoginAssistant
- **Issues**: https://github.com/microsoft/Microsoft365DSC/issues

---

**Status**: Infrastructure Complete | 1/505 Resources Updated  
**Last Updated**: November 2025

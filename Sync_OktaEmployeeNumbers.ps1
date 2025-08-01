<#
.SYNOPSIS
    Sync employeeNumber from Active Directory to Okta user profile.

.DESCRIPTION
    Fetches all Okta users via /api/v1/users, filters active users without employeeNumber
    and with email not matching an exclusion pattern, then queries Active Directory for
    a matching user and updates employeeNumber using Okta API.

    Sensitive data is provided via environment variables or parameters. No secrets are
    hard‑coded. All tenant‑specific values are parameterized.

.PARAMETER OktaOrg
    The Okta org subdomain, e.g. yourcompany for https://yourcompany.okta.com

.PARAMETER ApiToken
    The API token with permissions to read and update users.

.PARAMETER AdSearchBase
    The Active Directory search base (DN).

.PARAMETER AdEmployeeAttr
    The AD attribute whose value will populate Okta employeeNumber. Default: employeeID.

.PARAMETER EmailExcludePattern
    Wildcard pattern; user emails matching this will be ignored. Default: *bhn.com*

.PARAMETER Limit
    Page size for Okta API calls. Default: 200.

.EXAMPLE
    PS> .\Sync-AdEmployeeIdToOkta.ps1 -OktaOrg contoso \
        -ApiToken $Env:OKTA_TOKEN \
        -AdSearchBase "OU=Users,DC=contoso,DC=local"

.NOTES
    Author: Matthew Baur
    License: MIT
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OktaOrg = $env:OKTA_ORG,

    [Parameter(Mandatory)]
    [string]$ApiToken = $env:OKTA_TOKEN,

    [Parameter(Mandatory)]
    [string]$AdSearchBase = $env:AD_SEARCH_BASE,

    [string]$AdEmployeeAttr = $env:AD_EMPLOYEE_ATTR,

    [string]$EmailExcludePattern = '*bhn.com*',

    [ValidateRange(1,1000)]
    [int]$Limit = 200
)

if (-not $AdEmployeeAttr) { $AdEmployeeAttr = 'employeeID' }

# region Prep
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$commonHeaders = @{
    Authorization = "SSWS $ApiToken"
    Accept        = 'application/json'
    'Content-Type'= 'application/json'
}
$baseUrl = "https://$OktaOrg.okta.com/api/v1/users?limit=$Limit"
# endregion

function Invoke-OktaPagedRequest {
    param([string]$Uri)

    do {
        $response = Invoke-RestMethod -Uri $Uri -Headers $commonHeaders -Method Get -ResponseHeadersVariable respHeaders
        foreach ($item in $response) { $item }

        if ($respHeaders.link -match '<([^>]+)>;\s*rel="next"') {
            $Uri = $matches[1]
        } else { break }
    } while ($true)
}

function Update-OktaUser {
    param(
        [string]$UserId,
        [hashtable]$ProfilePatch
    )
    Invoke-RestMethod -Uri "https://$OktaOrg.okta.com/api/v1/users/$UserId" \
        -Headers $commonHeaders \
        -Method Post \
        -Body ($ProfilePatch | ConvertTo-Json -Depth 3)
}

Write-Verbose "Fetching users from Okta..."
$users = Invoke-OktaPagedRequest -Uri $baseUrl |
    Where-Object {
        $_.status -eq 'ACTIVE' -and
        $_.profile.email -notlike $EmailExcludePattern -and
        [string]::IsNullOrEmpty($_.profile.employeeNumber)
    }

Write-Host "Discovered $($users.Count) Okta users missing employeeNumber."

$usersNotFound = @()
$updateErrors  = @()

foreach ($user in $users) {
    try {
        $escapedName = [ADSI]::EscapeFilterValue($user.profile.displayName)
        $adUser = Get-ADUser -SearchBase $AdSearchBase \
            -SearchScope Subtree \
            -LDAPFilter "(displayName=$escapedName)" \
            -Properties $AdEmployeeAttr

        if ($null -ne $adUser -and $adUser.$AdEmployeeAttr) {
            Update-OktaUser -UserId $user.id -ProfilePatch @{
                profile = @{ employeeNumber = $adUser.$AdEmployeeAttr }
            }
        }
        else {
            $usersNotFound += $user
        }
    } catch {
        $updateErrors += $user
        Write-Warning "Failed to update $($user.profile.login): $_"
    }
}

Write-Host "`n=== Summary ==="
Write-Host "Updated successfully : $($users.Count - $usersNotFound.Count - $updateErrors.Count)"
Write-Host "Not found in AD    : $($usersNotFound.Count)"
Write-Host "Update errors      : $($updateErrors.Count)"

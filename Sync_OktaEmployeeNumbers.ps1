# --- 1) Common parameters / headers (splat)
$commonParams = @{
    Headers = @{
        Authorization = "SSWS $apiToken"
        Accept        = "application/json"
        'Content-Type'= "application/json"
    }
    Method = 'Get'
}

# --- 2) Helper: fetch all pages of Okta users
function Get-OktaUsers {
    param($BaseUrl = 'https://tangocard.okta.com/api/v1/users?limit=200')
    $uri = $BaseUrl
    do {
        # One call to get JSON + headers
        $resp = Invoke-RestMethod -Uri $uri @commonParams -ResponseHeadersVariable respHeaders
        foreach ($user in $resp) { $user }
        # Parse "next" link from headers
        if ($respHeaders.link -match '<([^>]+)>;\s*rel="next"') {
            $uri = $matches[1]
        }
        else {
            break
        }
    } while ($true)
}

# --- 3) Collect and filter users
$allUsers = Get-OktaUsers |
    Where-Object {
        $_.status               -eq 'ACTIVE' -and
        $_.profile.email        -notlike '*bhn.com*' -and
        [string]::IsNullOrEmpty($_.profile.employeeNumber)
    }

# --- 4) Prepare trackers and update params
$usersNotFound = @()
$updateFailed  = @()
$updateParams  = @{
    Headers = $commonParams.Headers
    Method  = 'Post'
}

# --- 5) Loop and sync employeeNumber from AD → Okta
foreach ($user in $allUsers) {
    try {
        # AD search: exact match on DisplayName
        $ad = Get-ADUser `
            -SearchBase 'OU=BHNUsers,DC=bhnetwork,DC=local' `
            -SearchScope Subtree `
            -Filter "DisplayName -eq '$($user.profile.displayName)'" `
            -Properties employeeID

        if ($ad) {
            # Build and send update
            $body = @{ profile = @{ employeeNumber = $ad.employeeID } } | ConvertTo-Json
            Invoke-RestMethod `
                -Uri "https://tangocard.okta.com/api/v1/users/$($user.id)" `
                -Body $body @updateParams
        }
        else {
            # No AD match
            $usersNotFound += $user
        }
    }
    catch {
        # Any error in update
        $updateFailed += $user
    }
}

# --- 6) Summary output
Write-Output "Done. Users not found in AD: $($usersNotFound.Count)"
Write-Output "Updates failed for:    $($updateFailed.Count)"
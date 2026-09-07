function Set-AppServiceAuthProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $CurrentProperties,
        [Parameter(Mandatory = $true)][guid] $ClientId,
        [Parameter(Mandatory = $true)][uri] $Issuer,
        [Parameter(Mandatory = $true)][string] $ScopeUri
    )

    if ($ClientId -eq [guid]::Empty -or -not $Issuer.IsAbsoluteUri -or $Issuer.Scheme -ne 'https') {
        throw 'Easy Auth requires an explicit Entra client ID and an absolute HTTPS issuer.'
    }
    foreach ($section in @('platform', 'globalValidation', 'identityProviders', 'login')) {
        if ($CurrentProperties[$section] -isnot [System.Collections.IDictionary]) {
            throw "The current Easy Auth settings have no valid $section section."
        }
    }
    if ($CurrentProperties['login']['tokenStore'] -isnot [System.Collections.IDictionary]) {
        throw 'The current Easy Auth settings have no valid token store section.'
    }
    if ($null -eq $CurrentProperties['httpSettings']) {
        $CurrentProperties['httpSettings'] = @{}
    }
    if ($CurrentProperties['httpSettings'] -isnot [System.Collections.IDictionary]) {
        throw 'The current Easy Auth HTTP settings are malformed.'
    }
    $id = $ClientId.ToString()
    $CurrentProperties['platform']['enabled'] = $true
    $CurrentProperties['globalValidation']['requireAuthentication'] = $false
    $CurrentProperties['globalValidation']['unauthenticatedClientAction'] = 'AllowAnonymous'
    $CurrentProperties['login']['tokenStore']['enabled'] = $true
    $CurrentProperties['httpSettings']['requireHttps'] = $true
    if ($null -eq $CurrentProperties['identityProviders']['azureActiveDirectory']) {
        $CurrentProperties['identityProviders']['azureActiveDirectory'] = @{}
    }
    $aad = $CurrentProperties['identityProviders']['azureActiveDirectory']
    if ($aad -isnot [System.Collections.IDictionary]) {
        throw 'The current Entra provider settings are malformed.'
    }
    foreach ($section in @('registration', 'login', 'validation')) {
        if ($null -eq $aad[$section]) {
            $aad[$section] = @{}
        }
        if ($aad[$section] -isnot [System.Collections.IDictionary]) {
            throw "The current Entra provider has a malformed $section section."
        }
    }
    if ($null -eq $aad['validation']['defaultAuthorizationPolicy']) {
        $aad['validation']['defaultAuthorizationPolicy'] = @{}
    }
    if ($aad['validation']['defaultAuthorizationPolicy'] -isnot [System.Collections.IDictionary]) {
        throw 'The current Entra authorization policy is malformed.'
    }
    $aad['enabled'] = $true
    $aad['registration']['clientId'] = $id
    $aad['registration']['clientSecretSettingName'] = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
    $aad['registration']['openIdIssuer'] = $Issuer.AbsoluteUri
    $aad['login']['loginParameters'] = @("scope=openid profile email offline_access $ScopeUri")
    $aad['validation']['allowedAudiences'] = @($id, "api://$id")
    $aad['validation']['defaultAuthorizationPolicy']['allowedApplications'] = @($id)
    return $CurrentProperties
}

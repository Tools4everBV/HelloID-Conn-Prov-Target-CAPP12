####################################################################
# HelloID-Conn-Prov-Target-CAPP12-ImportSubPermissions-Manager
# PowerShell V2
####################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Configure, must be the same as the values used in retrieve permissions
$permissionReference = 'manager'
$permissionDisplayName = 'Department manager'

#region functions
function Get-Capp12AuthorizationTokenAndCreateHeaders {
    [CmdletBinding()]
    param()
    try {
        Write-Information 'Creating Access Token'
        $authorizationBody = @{
            grant_type                = 'client_credentials'
            client_id                 = $actionContext.Configuration.ClientId
            client_secret             = $actionContext.Configuration.ClientSecret
            token_expiration_disabled = $false
        }
        $splatInvoke = @{
            Uri         = "$($actionContext.Configuration.BaseUrl)/oauth2/token"
            Method      = 'POST'
            ContentType = 'application/json'
            Body        = $authorizationBody | ConvertTo-Json -Depth 10
        }

        $accessToken = Invoke-RestMethod @splatInvoke

        Write-Information 'Adding Authorization headers'
        $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
        $headers.Add('Authorization', "$($accessToken.token_type) $($accessToken.access_token)")
        $headers.Add('Accept', 'application/json')
        $headers.Add('Content-Type', 'application/json')
        Write-Output $headers
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Resolve-CAPP12Error {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.error
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    Write-Information 'Starting CAPP12 permission entitlement import'

    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $splatImportPermissionParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
        Headers = $headers
        Method  = 'GET'
    }

    $importedPermissionsCsv = Invoke-RestMethod @splatImportPermissionParams
    $unfilteredImportedPermissions = $importedPermissionsCsv | ConvertFrom-Csv -Delimiter ';'

    $importedPermissions = $unfilteredImportedPermissions | Where-Object {
        # Keep when ends_on is empty or a date in the future
        if ([string]::IsNullOrEmpty($_.ends_on))
        { $true }
        else
        { [datetime]::Parse($_.ends_on) -gt [datetime]::Now }
    }

    $splatImportDepartmentsParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/departments"
        Headers = $headers
        Method  = 'GET'
    }

    $groupedPermissions = $importedPermissions | Group-Object -Property department_code -AsHashTable

    $importedDepartmentsCsv = Invoke-RestMethod @splatImportDepartmentsParams
    $importedDepartments = $importedDepartmentsCsv | ConvertFrom-Csv -Delimiter ';'

    foreach ($importedPermission in $groupedPermissions.GetEnumerator()) {
        $permission = @{
            PermissionReference      = @{
                Reference = $permissionReference
            }
            Description              = $permissionDisplayName
            DisplayName              = $permissionDisplayName
            AccountReferences        = $null
            SubPermissionReference   = @{
                Id = $importedPermission.Key
            }
            SubPermissionDisplayName = "$(($importedDepartments | Where-Object { $_.code -eq $importedPermission.Key }).title)"
        }

        # The code below splits a list of permission members into batches of 100
        # Each batch is assigned to $permission.AccountReferences and the permission object will be returned to HelloID for each batch
        # Ensure batching is based on the number of account references to prevent exceeding the maximum limit of 500 account references per batch
        $batchSize = 500
        $members = @($importedPermission.Value.user_code | Where-Object { -not [string]::IsNullOrEmpty($_) })
        for ($i = 0; $i -lt $members.Count; $i += $batchSize) {
            $permission.AccountReferences = $members[$i..([Math]::Min($i + $batchSize - 1, $members.Count - 1))]
            Write-Output $permission
        }
    }
    Write-Information 'CAPP12 permission entitlement import completed'
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import CAPP12 permission entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import CAPP12 permission entitlements. Error: $($ex.Exception.Message)"
    }
}
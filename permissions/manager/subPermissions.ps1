################################################################
# HelloID-Conn-Prov-Target-CAPP12-SubPermissions-Manager
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Mapping lookup values
# Lookup values which are used in the mapping to determine the subPermissions
$PrimaryLookupKey = { $_.Custom.ManagerOf } # Mandatory
# $SecondaryLookupKey = { $_.Department.DisplayName } # Mandatory

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

# Begin
try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    Write-Information "Verifying if a CAPP12 account exists"
    $splatGetUserParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users?code=$($actionContext.References.Account)"
        Headers = $headers
        Method  = 'GET'
    }
    $null = Invoke-RestMethod @splatGetUserParams

    # Collect current permissions
    $currentPermissions = @{}
    foreach ($permission in $actionContext.CurrentPermissions) {
        $currentPermissions[$permission.Reference.Id] = $permission.DisplayName
    }

    # Collect desired permissions
    $desiredPermissions = @{}
    if (-not($actionContext.Operation -eq 'revoke')) {
        $primaryKeys = (($personContext.Person | ForEach-Object $PrimaryLookupKey) -split ',').Trim('"') | Where-Object { -not [string]::IsNullOrEmpty($_) }

        if (($actionContext.Operation -in @('grant', 'update')) -and ($primaryKeys.Count -eq 0 )) {
            throw "No departments found for which this person is a manager in person data. Grant/update permission should not be started for this person."
        }

        foreach ($primaryKey in $primaryKeys) {
            $desiredPermissions[$primaryKey] = $primaryKey
        }
    }

    # Process desired permissions to grant
    foreach ($permission in $desiredPermissions.GetEnumerator()) {
        $outputContext.SubPermissions.Add([PSCustomObject]@{
                DisplayName = $permission.Value
                Reference   = [PSCustomObject]@{
                    Id = $permission.Name
                }
            })

        if (-not $currentPermissions.ContainsKey($permission.Name)) {
            $body = [PSCustomObject]@{
                user_code       = $actionContext.References.Account
                department_code = $permission.Key
                ends_on         = $null
            } | ConvertTo-Json -Depth 10

            $splatWebRequest = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            }
            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
            }

            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'GrantPermission'
                    Message = "Granted access to permission $($permission.Value)"
                    IsError = $false
                })
        }
    }

    # Process current permissions to revoke
    $newCurrentPermissions = @{}
    foreach ($permission in $currentPermissions.GetEnumerator()) {
        if (-not $desiredPermissions.ContainsKey($permission.Name)) {
            $body = [PSCustomObject]@{
                user_code       = $actionContext.References.Account
                department_code = $permission.Key
                ends_on         = (Get-Date).AddDays(-1).ToString('dd-MM-yyyy')
            } | ConvertTo-Json -Depth 10

            $splatWebRequest = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            }
            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
            }

            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = 'RevokePermission'
                    Message = "Revoked access to permission $($permission.Value)"
                    IsError = $false
                })
        }
        else {
            $newCurrentPermissions[$permission.Name] = $permission.Value
        }
    }

    # Process permissions to update
    # if ($actionContext.Operation -eq 'update') {
    #     foreach ($permission in $newCurrentPermissions.GetEnumerator()) {
    #         $body = [PSCustomObject]@{
    #             user_code       = $actionContext.References.Account
    #             department_code = $permission.Key
    #             ends_on         = $null
    #         } | ConvertTo-Json -Depth 10

    #         $splatWebRequest = @{
    #             Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
    #             Headers = $headers
    #             Method  = 'POST'
    #             Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
    #         }
    #         if (-not($actionContext.DryRun -eq $true)) {
    #             $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
    #         }

    #         $outputContext.AuditLogs.Add([PSCustomObject]@{
    #                 Action  = 'UpdatePermission'
    #                 Message = "Updated access to permission $($permission.Value)"
    #                 IsError = $false
    #             })
    #     }
    # }
    $outputContext.Success = $true
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditLogMessage = "Could not manage CAPP12 permissions. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not manage CAPP12 permissions. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
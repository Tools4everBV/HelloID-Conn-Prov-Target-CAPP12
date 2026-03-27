##################################################
# HelloID-Conn-Prov-Target-CAPP12-Delete
# PowerShell V2
##################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
    # Verify if [aRef] has a value
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
    try {            
        $correlatedAccount = Invoke-RestMethod @splatGetUserParams
    }
    catch {
        if ($_.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        elseif ($_.Exception.GetType().FullName -eq 'System.Net.WebException' -and $null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
            
        # In case of a 404 (not found), no account was found
        if ($statusCode -eq 404) {
            Write-Information "CAPP12 account with accountReference: [$($actionContext.References.Account)] not found"
            $correlatedAccount = $null
        }
        else {
            throw
        }
    }
    if ($null -ne $correlatedAccount) {
        $action = 'DeleteAccount'
    }
    else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'DeleteAccount' {
            Write-Information "Disabling CAPP12 account with accountReference: [$($actionContext.References.Account)]"
            
            $body = @{
                code       = $actionContext.References.Account
                email      = $actionContext.Data.email
                adfs_login = $actionContext.Data.adfs_login
                ends_on    = (Get-Date).AddDays(-1).ToString('dd-MM-yyyy')
            } | ConvertTo-Json

            $splatWebRequest = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
                Headers = $headers
                Method  = 'POST'
                Body    = [System.Text.Encoding]::UTF8.GetBytes($body)
            }

            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatWebRequest -Verbose:$false # Always 204
            }
            
            $outputContext.Success = $true
            $outputContext.Data = $body | ConvertFrom-Json
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Delete account [$($actionContext.References.Account)] was successful. Account has been disabled. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "CAPP12 account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "CAPP12 account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditLogMessage = "Could not delete CAPP12 account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not delete CAPP12 account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
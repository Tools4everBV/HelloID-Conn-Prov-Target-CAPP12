#################################################
# HelloID-Conn-Prov-Target-CAPP12-Import
# PowerShell V2
#################################################

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
            if ($null -ne $errorDetailsObject.error) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.error
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    Write-Information 'Starting account entitlement import'

    $actionMessage = 'creating access token'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $actionMessage = 'querying users'

    $splatImportAccountParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
        Headers = $headers
        Method  = 'GET'
    }
    $responseCsv = Invoke-RestMethod @splatImportAccountParams
    $response = $responseCsv | ConvertFrom-Csv -Delimiter ';'
    Write-Information "Queried users. Result count: $($response.Count)"

    $actionMessage = 'importing accounts to HelloID'
    $importedAccountsCount = 0
    if ($response) {
        foreach ($importedAccount in $response) {
            $actionMessage = "importing account [$($importedAccount.code)] to HelloID"
            # Making sure only fieldMapping fields are imported
            $data = @{}
            foreach ($field in $actionContext.ImportFields) {
                $data[$field] = $importedAccount.$field
            }

            # Make sure the AccountReference has a value
            $code = $importedAccount.code
            if ([string]::IsNullOrEmpty($code)) {
                # If code is empty, skip this record as AccountReference is required for the import to work
                continue
            }

            # Make sure the displayName has a value
            $displayName = "$($importedAccount.first_name) $($importedAccount.last_name)".trim()
            if ([string]::IsNullOrEmpty($displayName)) {
                $displayName = $code
            }

            # Make sure the userName has a value
            $userName = $importedAccount.email
            if ([string]::IsNullOrWhiteSpace($userName)) {
                $userName = $code
            }

            # Return the result
            Write-Output @{
                AccountReference = $code
                displayName      = $displayName
                UserName         = $userName
                Enabled          = $false  # Always false since no enable and disable scripts are present.
                Data             = $data
            }
            $importedAccountsCount++
        }
    }
    Write-Information "Account entitlement import completed. Result count: $($importedAccountsCount)"
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditLogMessage = "Error $($actionMessage). Error: $($errorObj.FriendlyMessage)"
        $warningMessage = "Error at Line [$($errorObj.ScriptLineNumber)]: $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Error $($actionMessage). Error: $($ex.Exception.Message)"
        $warningMessage = "Error at Line [$($ex.InvocationInfo.ScriptLineNumber)]: $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    Write-Warning $warningMessage
    Write-Error $auditLogMessage
}
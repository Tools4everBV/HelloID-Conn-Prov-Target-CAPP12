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
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    Write-Information 'Starting CAPP12 account entitlement import'

    $splatImportAccountParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
        Headers = $headers
        Method  = 'GET'
    }
    $responseCsv = Invoke-RestMethod @splatImportAccountParams
    $response = $responseCsv | ConvertFrom-Csv -Delimiter ';'
    if ($response) {
        foreach ($importedAccount in $response) {
            # Making sure only fieldMapping fields are imported
            $data = @{}
            foreach ($field in $actionContext.ImportFields) {
                $data[$field] = $importedAccount.$field
            }

            # Make sure the AccountReference has a value
            $code = $importedAccount.code
            if ([string]::IsNullOrEmpty($code)) {
                # If code is empty, use a combination of MissingUserCode and a timestamp to ensure uniqueness, as AccountReference is required and must be unique for each account
                $code = "MissingUserCode_$(Get-Date -Format 'yyyyMMddHHmmssfff')"
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

            # Set Enabled based on ends_on value, if ends_on is empty or a date in the future, Enabled is true, otherwise false
            $isEnabled = $false
            $endsOn = $importedAccount.ends_on
            if ([string]::IsNullOrEmpty($endsOn)) {
                try {
                    $endsOn = Invoke-RestMethod -Uri "$($actionContext.Configuration.BaseUrl)/api/v1/users?code=$($importedAccount.code)" -Headers $headers -Method 'GET' | Select-Object -ExpandProperty ends_on    
                }
                catch {
                    $endsOn = $null
                }
            }
            
            if ([string]::IsNullOrEmpty($endsOn)) {
                $isEnabled = $true
            }
            elseif ([datetime]::Parse($endsOn) -gt [datetime]::Now) {
                $isEnabled = $true
            }

            # Return the result
            Write-Output @{
                AccountReference = $code
                displayName      = $displayName
                UserName         = $userName
                Enabled          = $isEnabled
                Data             = $data
            }
        }
        Write-Information 'CAPP12 account entitlement import completed'
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import CAPP12 account entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import CAPP12 account entitlements. Error: $($ex.Exception.Message)"
    }
}
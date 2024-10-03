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
    } catch {
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
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
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
        } catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}

function Get-HelloIdStoredAccountData {
    [CmdletBinding()]
    param(
        [string]
        $SystemGuid
    )
    ($personContext.Person.Accounts.PSObject.Properties | Where-Object {
        $_.Value._extension.SystemGuid -eq $SystemGuid
    }).value
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Information "Verifying if a CAPP12 account for [$($personContext.Person.DisplayName)] exists"
    $correlatedAccount = Get-HelloIdStoredAccountData -SystemGuid $actionContext.Data._extension.SystemGuid

    if ($null -ne $correlatedAccount) {
        $correlatedAccount.code = $actionContext.References.Account
        $action = 'DisableAccount'
    } else {
        $action = 'NotFound'
    }

    # Process
    Write-Information "[DryRun = $($actionContext.DryRun)]"
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders
    switch ($action) {
        'DisableAccount' {
            Write-Information "Disabling CAPP12 account with accountReference: [$($actionContext.References.Account)]"
            $correlatedAccount | Add-Member @{
                ends_on = "$((Get-Date).AddDays(-1).ToString('dd-MM-yyyy'))"
            } -Force
            $body = $correlatedAccount | Select-Object * -ExcludeProperty _extension | ConvertTo-Json

            $splatWebRequest = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            }

            if (-not($actionContext.DryRun -eq $true)) {
                $null = Invoke-RestMethod @splatWebRequest -Verbose:$false # Always 204
            }
            $outputContext.data = $correlatedAccount

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'Disable account was successful'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Previous CAPP12 account values for: [$($personContext.Person.DisplayName)] not found, No Stored FieldMapping values"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Could not disable Account  [$($actionContext.References.Account)], Previous CAPP12 account values for: [$($personContext.Person.DisplayName)] not found, No Stored FieldMapping values"
                    IsError = $false
                })
            break
        }
    }
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditMessage = "Could not disable CAPP12 account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not disable CAPP12 account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
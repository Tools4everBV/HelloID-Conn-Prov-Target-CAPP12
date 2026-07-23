##########################################################
# HelloID-Conn-Prov-Target-CAPP12-Resources-Position
# PowerShell V2
##########################################################

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
    Write-Information "Processing [$(($resourceContext.SourceData | Measure-Object).Count)] position resources"
    $outputContext.Success = $true

    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $getPositionsSplat = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
        Headers = $headers
        Method  = 'GET'
    }
    $existingPositions = Invoke-RestMethod @getPositionsSplat | ConvertFrom-Csv -Delimiter ';'
    
    foreach ($resource in $resourceContext.SourceData) {
        try {
            $existingPosition = $existingPositions | Where-Object { $_.code -eq $resource.ExternalId }
            if ($existingPosition.Count -gt 1) {
                Throw "Multiple existing positions found with code [$($resource.ExternalId)]."
            }

            if ($null -eq $existingPosition) {
                $action = 'CreateResource'
            }
            elseif ($existingPosition.title -ne $resource.Name) {
                $action = 'UpdateResource'
            }
            else {
                $action = 'NoChanges'
            }

            switch ($action) {
                { $_ -in @('CreateResource', 'UpdateResource') } {
                    $body = [PSCustomObject]@{
                        code  = $resource.ExternalId
                        title = $resource.Name
                    }

                    if (-not ($actionContext.DryRun -eq $True)) {
                        Write-Information "$action`: [$($resource.ExternalId)] CAPP12 position"

                        $splatPositions = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
                            Headers = $headers
                            Method  = 'POST'
                            Body    = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 10))
                        }
                        $null = Invoke-RestMethod @splatPositions
                    }
                    else {
                        Write-Information "[DryRun] $action`: [$($resource.ExternalId)] CAPP12 position, will be executed during enforcement"
                    }

                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Action  = $action
                            Message = if ($action -eq 'UpdateResource') { "Updated position: [$($resource.ExternalId)]" } else { "Created position: [$($resource.ExternalId)]" }
                            IsError = $false
                        })
                    break
                }
                'NoChanges' {
                    Write-Information "Position [$($resource.ExternalId)] already exists with the same display name. No action needed."
                    break
                }
            }
        }
        catch {
            $outputContext.Success = $false
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditLogMessage = "Could not create or update CAPP12 position. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditLogMessage = "Could not create or update CAPP12 position. Error: $($ex.Exception.Message)"
                Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditLogMessage
                    IsError = $true
                })
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditLogMessage = "Could not create or update CAPP12 position. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create or update CAPP12 position. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
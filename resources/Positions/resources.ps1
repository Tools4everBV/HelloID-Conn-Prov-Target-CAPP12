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
    Write-Information "Creating [$($resourceContext.SourceData.Count)] Positions (before filtering)"
    
    # Only process unique results
    $resourceData = $resourceContext.SourceData | Select-Object -Unique externalId, name
    
    Write-Information "Creating [$($resourceData.Count)] Positions"
    $outputContext.Success = $true

    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    foreach ($resource in $resourceData) {
        try {
            if ([string]::IsNullOrEmpty($resource.externalId) -or [string]::IsNullOrEmpty($resource.name)) {
                Write-Information "Could not create Position [$($resource.externalId), $($resource.name)]"
                continue
            }
            <# Resource creation preview uses a timeout of 30 seconds while actual run has timeout of 10 minutes #>
            $body = [PSCustomObject]@{
                code  = $resource.externalId
                title = $resource.name
            }
            if ($actionContext.DryRun -eq $true) {
                Write-Information "[DryRun] Create [$($body.Code) | $($body.title) ] CAPP12 Position, will be executed during enforcement"
            }
            else {
                $splatPositions = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/positions"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = [System.Text.Encoding]::UTF8.GetBytes(( $body | ConvertTo-Json -Depth 10 ))
                }
                $null = Invoke-RestMethod @splatPositions

                # We have disabled the audit logs because we need to re-execute all assignments with each HelloID run,
                # as we cannot verify the existing objects in the target system.
                # $outputContext.AuditLogs.Add([PSCustomObject]@{
                #         Message = "Created Position: [$($body.Code) | $($body.title) ]"
                #         IsError = $false
                #     })
            }
        }
        catch {
            $outputContext.Success = $false
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Could not create CAPP12 Position. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditMessage = "Could not create CAPP12 Position. Error: $($ex.Exception.Message)"
                Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditMessage
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
        $auditMessage = "Could not create CAPP12 Position. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create CAPP12 Position. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
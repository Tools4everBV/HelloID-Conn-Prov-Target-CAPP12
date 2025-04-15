#################################################
# HelloID-Conn-Prov-Target-CAPP12-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Properties
$departmentLookupValue = { $_.Department.ExternalId }  # Employments
$positionLookupValue = { $_.Title.ExternalId }   # Assignments

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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    $actionList = @()
    $actionList += 'CreateAccount'
    $actionList += 'SetPositions'
    $actionList += 'SetDepartments'
    Write-Information 'Getting the contracts in conditions'
    [array]$desiredContracts = $personContext.Person.Contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($actionContext.DryRun -eq $true) {
        [array]$desiredContracts = $personContext.Person.Contracts
    }
    if ($desiredContracts.length -lt 1) {
        throw 'No Contracts in scope [InConditions] found!'
    }
    if ((($desiredContracts | Select-Object $departmentLookupValue).$departmentLookupValue | Measure-Object).count -ne $desiredContracts.count) {
        throw  "Not all contracts hold a value with the departmentLookupValue [$departmentLookupValue]. Verify your script- or HelloID person mapping."
    }
    if ((($desiredContracts | Select-Object $positionLookupValue).$positionLookupValue | Measure-Object).count -ne $desiredContracts.count) {
        throw  "Not all contracts hold a value with the positionLookupValue [$positionLookupValue]. Verify your script- or HelloID person mapping."
    }

    $desiredPositions = [array](($desiredContracts | Select-Object $positionLookupValue).$positionLookupValue | Select-Object -Unique )
    $desiredDepartments = [array](($desiredContracts | Select-Object $departmentLookupValue).$departmentLookupValue | Select-Object -Unique)

    # Set OutputContext to store the account object.
    $actionContext.Data | Add-Member @{ ends_on = $null } -Force
    $outputContext.Data = $actionContext.Data
    $outputContext.Data._extension.Positions = [array]($desiredPositions)
    $outputContext.Data._extension.Departments = [array]($desiredDepartments)

    # Process
    Write-Information "[DryRun = $($actionContext.DryRun)]"
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders
    foreach ($action in $actionList) {
        try {
            switch ($action) {
                'CreateAccount' {
                    Write-Information 'Creating or Update CAPP12 account'
                    $body = $actionContext.Data | Select-Object * -ExcludeProperty _extension | ConvertTo-Json
                    $splatWebRequest = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
                        Headers = $headers
                        Method  = 'POST'
                        Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                    }

                    if (-not($actionContext.DryRun -eq $true)) {
                        $null = Invoke-RestMethod @splatWebRequest -Verbose:$false # Always 204
                    }
                    $outputContext.AccountReference = $actionContext.Data.code
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "Create or Update account was successful. AccountReference is: [$($outputContext.AccountReference)]"
                            IsError = $false
                        })
                    break
                }
                'SetPositions' {
                    foreach ($position in $desiredPositions) {
                        Write-Information "Setting CAPP12 assignment with position code [$($position)]"
                        $body = [PSCustomObject]@{
                            user_code     = $actionContext.Data.code
                            position_code = $position
                            ends_on       = $null
                        } | ConvertTo-Json
                        $splatWebRequest = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/assignments"
                            Headers = $headers
                            Method  = 'POST'
                            Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                        }
                        if (-not($actionContext.DryRun -eq $true)) {
                            $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
                        }
                        $outputContext.AuditLogs.Add([PSCustomObject]@{
                                Message = "Successfully set active CAPP12 assignment: [$($position)]"
                                IsError = $false
                            })
                    }
                    break
                }
                'SetDepartments' {
                    foreach ($department in $desiredDepartments) {
                        Write-Information "Setting CAPP12 employment with department code [$($department)]"
                        $body = [PSCustomObject]@{
                            user_code       = $actionContext.Data.code
                            department_code = $department
                            ends_on         = $null
                        } | ConvertTo-Json -Depth 10

                        $splatWebRequest = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/employments"
                            Headers = $headers
                            Method  = 'POST'
                            Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                        }
                        if (-not($actionContext.DryRun -eq $true)) {
                            $null = Invoke-RestMethod @splatWebRequest -Verbose:$false
                        }
                        $outputContext.AuditLogs.Add([PSCustomObject]@{
                                Message = "Successfully set active CAPP12 employment: [$($department)]"
                                IsError = $false
                            })
                    }
                    break
                }
            }
        }
        catch {
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Could not create or set positions or department CAPP12 account. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            }
            else {
                $auditMessage = "Could not create or set positions or department CAPP12 account. Error: $($ex.Exception.Message)"
                Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditMessage
                    IsError = $true
                })
        }
    }
    if ( -not ($outputContext.AuditLogs.IsError -contains $true)) {
        $outputContext.Success = $true
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditMessage = "Could not create or correlate CAPP12 account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create or correlate CAPP12 account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}

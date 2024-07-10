#################################################
# HelloID-Conn-Prov-Target-CAPP12-Update
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

function Compare-Array {
    [OutputType([array], [array], [array])] # $Left , $Right, $common
    param(
        [parameter()]
        [AllowEmptyCollection()]
        [string[]]$ReferenceObject,

        [parameter()]
        [AllowEmptyCollection()]
        [string[]]$DifferenceObject
    )
    if ($null -eq $DifferenceObject) {
        $Left = $ReferenceObject
    } elseif ($null -eq $ReferenceObject) {
        $right = $DifferenceObject
    } else {
        $left = [string[]][Linq.Enumerable]::Except($ReferenceObject, $DifferenceObject)
        $right = [string[]][Linq.Enumerable]::Except($DifferenceObject, $ReferenceObject)
        $common = [string[]][Linq.Enumerable]::Intersect($ReferenceObject, $DifferenceObject)
    }
    return $Left , $Right, $common
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
    Write-Information 'Getting the contracts in conditions'
    [array]$desiredContracts = $personContext.Person.Contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($actionContext.DryRun -eq $true) {
        [array]$desiredContracts = $personContext.Person.Contracts
    }
    if ($desiredContracts.length -lt 1) {
        throw 'No Contracts in scope [InConditions] found!'
    }
    Write-Information "Number of desiredContracts $($desiredContracts.count)"
    if ((($desiredContracts | Select-Object $departmentLookupValue).$departmentLookupValue | Measure-Object).count -ne $desiredContracts.count) {
        throw  "Not all contracts hold a value with the departmentLookupValue [$departmentLookupValue]. Verify your script- or HelloID person mapping."
    }
    if ((($desiredContracts | Select-Object $positionLookupValue).$positionLookupValue | Measure-Object).count -ne $desiredContracts.count) {
        throw  "Not all contracts hold a value with the positionLookupValue [$positionLookupValue]. Verify your script- or HelloID person mapping."
    }

    $desiredPositions = [array](($desiredContracts | Select-Object $positionLookupValue).$positionLookupValue | Select-Object -Unique )
    $desiredDepartments = [array](($desiredContracts | Select-Object $departmentLookupValue).$departmentLookupValue | Select-Object -Unique)
    Write-Information "Desired Positions [$($desiredPositions -join ',')]"
    Write-Information "Desired Department [$($desiredDepartments -join ',')]"

    Write-Information "Verifying if a CAPP12 account for [$($personContext.Person.DisplayName)] exists"
    $correlatedAccount = Get-HelloIdStoredAccountData -SystemGuid $actionContext.Data._extension.SystemGuid
    $outputContext.PreviousData = $correlatedAccount

    # Overwrite with stored Properties
    $actionContext.Data.code = $actionContext.References.Account
    $actionContext.Data | Add-Member @{ ends_on = $correlatedAccount.ends_on } -Force

    # Set OutputContext to store the account object.
    $outputContext.Data = $actionContext.Data
    $outputContext.Data._extension.Positions = [array]($desiredPositions)
    $outputContext.Data._extension.Departments = [array]($desiredDepartments)

    $actionList = @()
    if ($null -ne $correlatedAccount) {
        $splatCompareProperties = @{
            ReferenceObject  = @(($outputContext.PreviousData | Select-Object * -ExcludeProperty _extension).PSObject.Properties )
            DifferenceObject = @(($actionContext.Data | Select-Object * -ExcludeProperty _extension).PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
        if ($propertiesChanged) {
            $actionList += 'UpdateAccount'
        } else {
            $actionList += 'NoChanges'
        }
        $revokeDepartments , $grantDepartments , $update = Compare-Array -ReferenceObject $outputContext.PreviousData._extension.Departments -DifferenceObject $outputContext.Data._extension.Departments
        $revokePositions , $grantPositions , $update = Compare-Array -ReferenceObject $outputContext.PreviousData._extension.Positions -DifferenceObject $outputContext.Data._extension.Positions
        if ($grantDepartments.count -gt 0) {
            $actionList += 'AddDepartments'
        }
        if ($revokeDepartments.count -gt 0) {
            $actionList += 'RevokeDepartments'
        }
        if ($grantPositions.count -gt 0) {
            $actionList += 'AddPositions'
        }
        if ($revokePositions.count -gt 0) {
            $actionList += 'RevokePositions'
        }
    } else {
        $action = 'NotFound'
    }

    # # Process
    Write-Information "[DryRun = $($actionContext.DryRun)]"
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders
    foreach ($action in $actionList) {
        try {
            switch ($action) {
                'UpdateAccount' {
                    Write-Information "Updating CAPP12 account with accountReference: [$($actionContext.References.Account)]"
                    Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"
                    $body = $actionContext.Data | Select-Object * -ExcludeProperty _extension | ConvertTo-Json
                    $splatWebRequest = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/users"
                        Headers = $headers
                        Method  = 'POST'
                        Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                    }

                    if (-not($actionContext.DryRun -eq $true)) {
                        # Make sure to test with special characters and if needed; add utf8 encoding.
                        $null = Invoke-RestMethod @splatWebRequest -Verbose:$false # Always 204
                    }

                    $outputContext.Success = $true
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                            IsError = $false
                        })
                    break
                }

                'AddPositions' {
                    foreach ($position in $grantPositions) {
                        Write-Information "Adding CAPP12 assignment with position code [$($position)]"
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
                                Message = "Successfully added CAPP12 assignment: [$($position)]"
                                IsError = $false
                            })
                        break
                    }
                }
                'RevokePositions' {
                    foreach ($position in $revokePositions) {
                        Write-Information "Revoke CAPP12 assignment with position code [$($position)]"
                        $body = [PSCustomObject]@{
                            user_code     = $actionContext.Data.code
                            position_code = $position
                            ends_on       = (Get-Date -Format 'dd-MM-yyyy')
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
                                Message = "Successfully revoked CAPP12 assignment: [$($position)]"
                                IsError = $false
                            })
                        break
                    }
                }
                'AddDepartments' {
                    foreach ($department in $grantDepartments) {
                        Write-Information "Adding CAPP12 employment with department code [$($department)]"
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
                                Message = "Successfully added CAPP12 employment: [$($department)]"
                                IsError = $false
                            })
                    }
                    break
                }
                'RevokeDepartments' {
                    foreach ($department in $revokeDepartments) {
                        Write-Information "Revoke CAPP12 employment with department code [$($department)]"
                        $body = [PSCustomObject]@{
                            user_code       = $actionContext.Data.code
                            department_code = $department
                            ends_on         = (Get-Date -Format 'dd-MM-yyyy')
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
                                Message = "Successfully revoked CAPP12 employment: [$($department)]"
                                IsError = $false
                            })
                    }
                    break
                }

                'NoChanges' {
                    Write-Information "No changes to CAPP12 account with accountReference: [$($actionContext.References.Account)]"
                    $outputContext.Success = $true
                    break
                }

                'NotFound' {
                    Write-Information "Previous CAPP12 account values for: [$($personContext.Person.DisplayName)] not found, No Stored FieldMapping values"
                    $outputContext.Success = $false
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "CAPP12 account with accountReference: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
                            IsError = $true
                        })
                    break
                }
            }
        } catch {
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Could not update or set positions or department CAPP12 account. Error: $($errorObj.FriendlyMessage)"
                Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            } else {
                $auditMessage = "Could not update or set positions or department CAPP12 account. Error: $($ex.Exception.Message)"
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
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditMessage = "Could not update CAPP12 account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update CAPP12 account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}


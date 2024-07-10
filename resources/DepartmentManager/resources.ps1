##########################################################
# HelloID-Conn-Prov-Target-CAPP12-Resources-DepartmentManager
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
#endregion

try {
    Write-Information "Creating [$($resourceContext.SourceData.Count)] DepartmentManager"
    $headers = Get-Capp12AuthorizationTokenAndCreateHeaders

    # Skip contracts that includes no CAPP12Department or CAPP12Manager
    $capp12Departments = $resourceContext.SourceData | Where-Object { (-not [string]::IsNullOrEmpty($_.CAPP12Department)) -and (-not [string]::IsNullOrEmpty($_.CAPP12Manager)) }


    $groupedDepartments = $capp12Departments | Group-Object CAPP12Department
    Write-Information "Filtered department with valid CAPP12 Department data, Processing [$($groupedDepartments.count)] departments of total [$($resourceContext.SourceData.Count)] departments"

    foreach ($resource in $groupedDepartments) {
        try {
            $department = $resource.name
            $manager = ($resource.group | Select-Object -Property CAPP12Manager -Unique).CAPP12Manager
            if ($manager.Count -gt 1) {
                throw "Could not set Manager on Department [$($department)], Multiple Managers found [$((($resource.group | ForEach-Object { $_.CAPP12Manager })  -join ", "))]"
            } elseif ($manager.count -eq 0) {
                throw  "Could not set Manager on Department [$($department)], No Manager found."
            }

            <# Resource creation preview uses a timeout of 30 seconds while actual run has timeout of 10 minutes #>
            $endDate = (Get-Date).AddDays($actionContext.Configuration.ManagerAssignmentTimeOutInDays).ToString('dd-MM-yyyy')
            $body = [PSCustomObject]@{
                user_code       = $manager
                department_code = $department
                ends_on         = $endDate
            }

            if ($actionContext.DryRun -eq $True) {
                Write-Information "[DryRun] Add CAPP12 DepartmentManager [$($department) | $( $manager) ], will be executed during enforcement"
            } else {
                $splatDepartmentManager = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/api/v1/managers"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = [System.Text.Encoding]::UTF8.GetBytes(( $body | ConvertTo-Json -Depth 10 ))
                }
                $null = Invoke-RestMethod @splatDepartmentManager

                # We have disabled the audit logs because we need to re-execute all assignments with each HelloID run,
                # as we cannot verify the existing objects in the target system.
                # $outputContext.AuditLogs.Add([PSCustomObject]@{
                #         Message = "Added CAPP12 DepartmentManager [$($department) | $($manager) ]"
                #         IsError = $false
                #     })
            }
        } catch {
            $outputContext.Success = $false
            $ex = $PSItem
            if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
                $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObj = Resolve-CAPP12Error -ErrorObject $ex
                $auditMessage = "Could not create CAPP12 DepartmentManager. Error: $($errorObj.FriendlyMessage)"
                Write-Information "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            } else {
                $auditMessage = "Could not create CAPP12 DepartmentManager. Error: $($ex.Exception.Message)"
                Write-Information "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
            }
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $auditMessage
                    IsError = $true
                })
        }
    }
    $outputContext.Success = $true
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-CAPP12Error -ErrorObject $ex
        $auditMessage = "Could not create CAPP12 DepartmentManagers. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create CAPP12 DepartmentManagers. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
#####################################################
# HelloID-Conn-Prov-Target-CAPP12-Users-Enable
#
# Version: 1.0.0
#####################################################
# Initialize default values
$c = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$pp = $previousPerson | ConvertFrom-Json
$success = $true # Set to true at start, because only when an error occurs it is set to false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()
$today = Get-Date

# Set debug logging
switch ($($c.isDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}
$InformationPreference = "Continue"
$WarningPreference = "Continue"

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Used to connect to CAPP12 endpoints
$baseUrl = $c.baseurl
$clientId = $c.clientid
$clientSecret = $c.clientsecret

# Account mapping
$enddate = ($p.PrimaryContract.EndDate).ToString('dd-MM-yyyy')
$account = [PSCustomObject]@{
    code       = $p.ExternalId
    email      = $p.Accounts.GoogleGSuite.userName
    first_name = $p.Name.NickName
    last_name  = $p.Custom.surnamecombined
    adfs_login = $p.Accounts.GoogleGSuite.userName
    ends_on    = $enddate
}

# Troubleshooting
# $enddate = $today.AddDays(30).ToString('dd-MM-yyyy')
# $account = [PSCustomObject]@{
#     code       = '99999999'
#     email      = 'TestTools4ever@helloid.com'
#     first_name = 'Test'
#     last_name  = 'Tools4ever'
#     adfs_login = 'TestTools4ever@helloid.com'
#     ends_on    = $enddate
# }
# $dryRun = $false

#region functions
function New-AuthorizationHeaders {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[[String], [String]]])]
    param(
        [parameter(Mandatory)]
        [string]
        $ClientId,

        [parameter(Mandatory)]
        [string]
        $ClientSecret
    )
    try {
        Write-Verbose 'Creating Access Token'

        $authorizationurl = "$baseUrl/oauth2/token"
        $authorizationbody = @{
            "grant_type"                = 'client_credentials'
            "client_id"                 = $ClientId
            "client_secret"             = $ClientSecret
            "token_expiration_disabled" = $false
        } | ConvertTo-Json -Depth 10
        $AccessToken = Invoke-RestMethod -uri $authorizationurl -body $authorizationbody -Method Post -ContentType "application/json"

        Write-Verbose 'Adding Authorization headers'
        $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
        $headers.Add('Authorization', "$($AccessToken.token_type) $($AccessToken.access_token)")
        $headers.Add('Accept', 'application/json')
        $headers.Add('Content-Type', 'application/json')
        Write-Output $headers
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Resolve-HTTPError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId
            MyCommand             = $ErrorObject.InvocationInfo.MyCommand
            RequestUri            = $ErrorObject.TargetObject.RequestUri
            ScriptStackTrace      = $ErrorObject.ScriptStackTrace
            ErrorMessage          = ''
        }
        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $httpErrorObj.ErrorMessage = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            $httpErrorObj.ErrorMessage = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
        }
        Write-Output $httpErrorObj
    }
}
#endregion functions

try {
    $headers = New-AuthorizationHeaders -ClientId $clientId -ClientSecret $clientSecret

    #region user account
    # Create user account
    try {
        Write-Verbose "Setting CAPP12 account with code '$($account.code)'"

        $body = ($account | ConvertTo-Json -Depth 10)
        $splatWebRequest = @{
            Uri     = "$baseUrl/api/v1/users"
            Headers = $headers
            Method  = 'POST'
            Body    = ([System.Text.Encoding]::UTF8.GetBytes($body)) 
        }
        
        if (-not($dryRun -eq $true)) {
            $setAccount = Invoke-RestMethod @splatWebRequest -Verbose:$false

            # Set aRef object for use in futher actions
            $aRef = [PSCustomObject]@{
                id       = $account.code
                userName = $account.email
            }

            $auditLogs.Add([PSCustomObject]@{
                    Action  = "EnableAccount"
                    Message = "Successfully set CAPP12 account $($aRef.userName) ($($aRef.id))"
                    IsError = $false
                })
        }
        else {
            Write-Warning "DryRun: Would set CAPP12 account: $account"
        }
    }
    catch {
        $ex = $PSItem
        if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
            $errorObject = Resolve-HTTPError -Error $ex
    
            $verboseErrorMessage = $errorObject.ErrorMessage
    
            $auditErrorMessage = $errorObject.ErrorMessage
        }
    
        # If error message empty, fall back on $ex.Exception.Message
        if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
            $verboseErrorMessage = $ex.Exception.Message
        }
        if ([String]::IsNullOrEmpty($auditErrorMessage)) {
            $auditErrorMessage = $ex.Exception.Message
        }
    
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"

        $success = $false  
        $auditLogs.Add([PSCustomObject]@{
                Action  = "EnableAccount"
                Message = "Error setting CAPP12 account with with code '$($account.code)'. Error Message: $auditErrorMessage"
                IsError = $True
            })
    }
    #endregion user account

    #region active contracts
    $activeContracts = $p.Contracts | Where-Object { $_.EndDate -ge $today -or $null -eq $_.EndDate }
    foreach ($activeContract in $activeContracts) {
        # Create assigments for active job title
        try {
            Write-Verbose "Setting active CAPP12 assignment with position_code '$($activeContract.Title.ExternalId)'"

            if ([String]::IsNullOrEmpty($activeContract.EndDate)) {
                $enddate = '31-12-2999'
            }
            else {
                $enddate = ($activeContract.EndDate).ToString('dd-MM-yyyy')
            }
            
            $assignment = [PSCustomObject]@{
                user_code     = $account.code
                position_code = $activeContract.Title.ExternalId
                ends_on       = $enddate
            }

            $body = ($assignment | ConvertTo-Json -Depth 10)
            $splatWebRequest = @{
                Uri     = "$baseUrl/api/v1/assignments"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            }
            
            if (-not($dryRun -eq $true)) {
                $setAssignment = Invoke-RestMethod @splatWebRequest -Verbose:$false

                $auditLogs.Add([PSCustomObject]@{
                        Action  = "EnableAccount"
                        Message = "Successfully set active CAPP12 assignment: $assignment"
                        IsError = $false
                    })
            }
            else {
                Write-Warning "DryRun: Would set active CAPP12 assignment: $assignment"
            }
        }
        catch {
            $ex = $PSItem
            if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObject = Resolve-HTTPError -Error $ex
        
                $verboseErrorMessage = $errorObject.ErrorMessage
        
                $auditErrorMessage = $errorObject.ErrorMessage
            }
        
            # If error message empty, fall back on $ex.Exception.Message
            if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                $verboseErrorMessage = $ex.Exception.Message
            }
            if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                $auditErrorMessage = $ex.Exception.Message
            }
        
            Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"
    
            $success = $false  
            $auditLogs.Add([PSCustomObject]@{
                    Action  = "EnableAccount"
                    Message = "Error setting active CAPP12 assignment: $assignment. Error Message: $auditErrorMessage"
                    IsError = $True
                })
        }

        # Create employment for active cost center
        try {
            Write-Verbose "Setting active CAPP12 employment with department_code '$($activeContract.CostCenter.Code)'"

            if ([String]::IsNullOrEmpty($activeContract.EndDate)) {
                $enddate = '31-12-2999'
            }
            else {
                $enddate = ($activeContract.EndDate).ToString('dd-MM-yyyy')
            }
            $employment = [PSCustomObject]@{
                user_code       = $account.code
                department_code = $activeContract.CostCenter.Code
                ends_on         = $enddate
            }

            $body = ($employment | ConvertTo-Json -Depth 10)
            $splatWebRequest = @{
                Uri     = "$baseUrl/api/v1/employments"
                Headers = $headers
                Method  = 'POST'
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
            } 
            
            if (-not($dryRun -eq $true)) {
                $setEmployment = Invoke-RestMethod @splatWebRequest -Verbose:$false

                $auditLogs.Add([PSCustomObject]@{
                        Action  = "EnableAccount"
                        Message = "Successfully set active CAPP12 employment: $employment"
                        IsError = $false
                    })
            }
            else {
                Write-Warning "DryRun: Would set active CAPP12 employment: $employment"
            }
        }
        catch {
            $ex = $PSItem
            if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                $errorObject = Resolve-HTTPError -Error $ex
        
                $verboseErrorMessage = $errorObject.ErrorMessage
        
                $auditErrorMessage = $errorObject.ErrorMessage
            }
        
            # If error message empty, fall back on $ex.Exception.Message
            if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                $verboseErrorMessage = $ex.Exception.Message
            }
            if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                $auditErrorMessage = $ex.Exception.Message
            }
        
            Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"

            $success = $false  
            $auditLogs.Add([PSCustomObject]@{
                    Action  = "EnableAccount"
                    Message = "Error setting active CAPP12 employment: $employment. Error Message: $auditErrorMessage"
                    IsError = $True
                })
        }
    }
    #endregion active contracts

    #region inactive contracts
    $previousContracts = $pp.Contracts
    foreach ($previousContract in $previousContracts) {
        # Set enddate to today of assigment for inactive job title
        if ($previousContract.Title.ExternalId -notin $activeContracts.Title.ExternalId) {
            try {
                Write-Verbose "Setting enddate to today for inactive CAPP12 assignment with position_code '$($previousContract.Title.ExternalId)'"

                $enddate = $today.ToString('dd-MM-yyyy')
                $assignment = [PSCustomObject]@{
                    user_code     = $account.code
                    position_code = $previousContract.Title.ExternalId
                    ends_on       = $enddate
                }

                $body = ($assignment | ConvertTo-Json -Depth 10)
                $splatWebRequest = @{
                    Uri     = "$baseUrl/api/v1/assignments"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                }
                
                if (-not($dryRun -eq $true)) {
                    $setAssignment = Invoke-RestMethod @splatWebRequest -Verbose:$false

                    $auditLogs.Add([PSCustomObject]@{
                            Action  = "EnableAccount"
                            Message = "Successfully set enddate to today for inactive CAPP12 assignment: $assignment"
                            IsError = $false
                        })
                }
                else {
                    Write-Warning "DryRun: Would set enddate to today for inactive CAPP12 assignment: $assignment"
                }
            }
            catch {
                $ex = $PSItem
                if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                    $errorObject = Resolve-HTTPError -Error $ex
            
                    $verboseErrorMessage = $errorObject.ErrorMessage
            
                    $auditErrorMessage = $errorObject.ErrorMessage
                }
            
                # If error message empty, fall back on $ex.Exception.Message
                if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                    $verboseErrorMessage = $ex.Exception.Message
                }
                if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                    $auditErrorMessage = $ex.Exception.Message
                }
            
                Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"
        
                $success = $false  
                $auditLogs.Add([PSCustomObject]@{
                        Action  = "EnableAccount"
                        Message = "Error setting enddate to today for inactive CAPP12 assignment: $assignment. Error Message: $auditErrorMessage"
                        IsError = $True
                    })
            }
        }

        # Set enddate to today of employment for inactive cost center
        if ($previousContract.CostCenter.Code -notin $activeContracts.CostCenter.Code) {
            try {
                Write-Verbose "Setting enddate to today for inactive CAPP12 employment with department_code '$($previousContract.CostCenter.Code)'"

                $enddate = $today.ToString('dd-MM-yyyy')
                $employment = [PSCustomObject]@{
                    user_code       = $account.code
                    department_code = $previousContract.CostCenter.Code
                    ends_on         = $enddate
                }

                $body = ($employment | ConvertTo-Json -Depth 10)
                $splatWebRequest = @{
                    Uri     = "$baseUrl/api/v1/employments"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body))
                } 
                
                if (-not($dryRun -eq $true)) {
                    $setEmployment = Invoke-RestMethod @splatWebRequest -Verbose:$false

                    $auditLogs.Add([PSCustomObject]@{
                            Action  = "EnableAccount"
                            Message = "Successfully set enddate to today for inactive CAPP12 employment: $employment"
                            IsError = $false
                        })
                }
                else {
                    Write-Warning "DryRun: Would set enddate to today for inactive CAPP12 employment: $employment"
                }
            }
            catch {
                $ex = $PSItem
                if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
                    $errorObject = Resolve-HTTPError -Error $ex
            
                    $verboseErrorMessage = $errorObject.ErrorMessage
            
                    $auditErrorMessage = $errorObject.ErrorMessage
                }
            
                # If error message empty, fall back on $ex.Exception.Message
                if ([String]::IsNullOrEmpty($verboseErrorMessage)) {
                    $verboseErrorMessage = $ex.Exception.Message
                }
                if ([String]::IsNullOrEmpty($auditErrorMessage)) {
                    $auditErrorMessage = $ex.Exception.Message
                }
            
                Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($verboseErrorMessage)"

                $success = $false  
                $auditLogs.Add([PSCustomObject]@{
                        Action  = "EnableAccount"
                        Message = "Error setting enddate to today for inactive CAPP12 employment: $employment. Error Message: $auditErrorMessage"
                        IsError = $True
                    })
            }
        }
    }
    #endregion inactive contracts
}
finally {
    # Send results
    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $aRef
        AuditLogs        = $auditLogs
        Account          = $account
    
        # # Optionally return data for use in other systems
        # ExportData = [PSCustomObject]@{
        #     DisplayName = $account.DisplayName
        #     UserName    = $account.UserName
        #     ExternalId  = $accountGuid
        # }
    }

    Write-Output $result | ConvertTo-Json -Depth 10
}
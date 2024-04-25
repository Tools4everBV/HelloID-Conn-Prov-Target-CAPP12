#####################################################
# Initialize default values
$c = $configuration | ConvertFrom-Json

# Retrieve resourceData
$rRef = $resourceContext | ConvertFrom-Json
$success = $true

$auditLogs = [Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Troubleshooting
# $dryRun = $false

# Used to connect to Capp12 endpoints
$baseUrl = $c.baseurl
$clientId = $c.clientid
$clientSecret = $c.clientsecret

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
            "grant_type" =  'client_credentials'
            "client_id" =  $ClientId
            "client_secret" = $ClientSecret
            "scope" =  "api/import"
        } | ConvertTo-Json
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
#endregion functions
if (-Not($dryRun -eq $True)) {
    $headers = New-AuthorizationHeaders -ClientId $clientId -ClientSecret $clientSecret
}

# In preview only the first 10 items of the SourceData are used
foreach ($title in $rRef.SourceData) {
    try {
         
            $resourceobject = [PSCustomObject]@{
                code  = $title.externalID
                title = $title.name
            }

            <# Resource creation preview uses a timeout of 30 seconds
            while actual run has timeout of 10 minutes #>
            Write-Information "Creating Resource $($title.name) ($($title.externalID))"

            if (-Not($dryRun -eq $True)) {
                
                $body = ($resourceobject | ConvertTo-Json -Depth 10)
                $splatWebRequest = @{
                    Uri     = "$baseUrl/api/v1/positions"
                    Headers = $headers
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes($body)) 
                }

                $createdResource = Invoke-RestMethod @splatWebRequest -Verbose:$false

                $success = $True
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Successfully created Resource $($title.name) ($($title.externalID))"
                        Action  = "CreateResource"
                        IsError = $false
                    })
            }
          }        
    catch {
        $success = $false
        $ex = $PSItem
        if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
            $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
            $errorMessageDetail = $null
            $errorObjectConverted = $ex | ConvertFrom-Json -ErrorAction SilentlyContinue
    
            if($null -ne $errorObjectConverted.detail){
                $errorObjectDetail = [regex]::Matches($errorObjectConverted.detail, '\{(.*?)\}').Value
                if($null -ne $errorObjectDetail){
                    $errorDetailConverted = $errorObjectDetail | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if($null -ne $errorDetailConverted){
                        $errorMessageDetail = $errorDetailConverted.title
                    }else{
                        $errorMessageDetail = $errorObjectDetail
                    }
                }else{
                    $errorMessageDetail = $errorObjectConverted.detail
                }
            }else{
                $errorMessageDetail = $ex
            }

            $errorMessage = "Could not create Capp12 Resource $($title.name) ($($title.externalID)). Error: $($errorMessageDetail)"
        }
        else {
            $errorMessage = "Could not create Capp12 Resource $($title.name) ($($title.externalID)). Error: $($ex.Exception.Message)"
        }
    
        $verboseErrorMessage = "Could not create Capp12 Resource $($title.name) ($($title.externalID)). Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error message: $($ex)"
        Write-Verbose $verboseErrorMessage
      
        $auditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                Action  = "CreateResource"
                IsError = $true
            })
    }
}


# Send results
$result = [PSCustomObject]@{
    Success   = $success
    AuditLogs = $auditLogs
}

Write-Output $result | ConvertTo-Json -Depth 10
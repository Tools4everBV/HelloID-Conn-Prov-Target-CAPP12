# Init variables
$xmlPath = "\\server\HelloID\HRCoreExport"
$capp12Path = "C:\HelloID - Ondersteunend\Capp12-testoutput"

function Get-ActiveRecords {
    <#
        .SYNOPSIS
            Filters a generic list of records based on date logic
        .DESCRIPTION
            Filters a generic list of records based on date logic
        .EXAMPLE
            PS C:\> Get-ActiveRecords -AttributeStartDate "begindatum" -AttributeEndDate "einddatum" -ActivePreInDays 30 -ActivePostInDays 30 ([ref]$managers)
        .INPUTS
            AttributeStartDate
            AttributeEndDate
            ActivePreInDays
            ActivePostInDays
            Records
        .OUTPUTS
            Records
        .NOTES
            See github?
    #>
    param(
        [parameter(Mandatory = $true)][String]$AttributeStartDate,
        [parameter(Mandatory = $true)][String]$AttributeEndDate,
        [parameter(Mandatory = $true)][Int]$ActivePreInDays,
        [parameter(Mandatory = $true)][Int]$ActivePostInDays,
        [parameter(Mandatory = $true)][ref]$Records
    )
    $now = (Get-Date).Date
    $Records.value = $Records.value | Where-Object { ([DateTime]$_.$AttributeStartDate).addDays(-$ActivePreInDays) -le $now -and ([string]::IsNullOrEmpty($_.$AttributeEndDate) -or ([DateTime]$_.$AttributeEndDate).addDays($ActivePostInDays) -gt $now) }
}

function Set-EmployeeStartEndDate {
    param(
        [parameter(Mandatory = $true)]$Contracts,    
        [parameter(Mandatory = $true)][ref]$Persons
    )
    $persons.value | Add-Member -MemberType NoteProperty -Name "datum_indienst" -Value $null -Force
    $persons.value | Add-Member -MemberType NoteProperty -Name "datum_uitdienst" -Value $null -Force
    $contractsGrouped = $Contracts | Group-Object persNrDV -AsHashTable 
    
    $persons.value | ForEach-Object  {
        $_.datum_indienst = $contractsGrouped[$_.persNr].begindatumDV | Sort-Object begindatumDV -Unique
        $_.datum_uitdienst = $contractsGrouped[$_.persNr].einddatumDV | Sort-Object -Descending einddatumDV -Unique
    }
}

function Get-RAETXMLFunctions {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)]$FileFilter,
        [parameter(Mandatory = $true)]$Contracts,
        [parameter(Mandatory = $true)][ref]$Functions
    )

    $files = Get-ChildItem -Path $XMLBasePath -Filter $FileFilter | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) { return }

    # Read content as XML
    [xml]$xml = Get-Content $files[0].FullName

    # Process all records
    foreach ($functie in $xml.GetElementsByTagName("functie")) {
        $function = [PSCustomObject]@{}

        foreach ($child in $functie.ChildNodes) {
            $function | Add-Member -MemberType NoteProperty -Name $child.LocalName -Value $child.'#text' -Force
        }

        [void]$Functions.value.Add($function)
    }

    # Only export functions that exist in contracts
    $Functions.value = $Functions.value.Where({$_.FunctieCode -in $Contracts.functiecode})
}

function Get-RAETXMLDepartments {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)]$FileFilter,
        [parameter(Mandatory = $true)]$Contracts,
        [parameter(Mandatory = $true)][ref]$Departments
    )

    $files = Get-ChildItem -Path $XMLBasePath -Filter $FileFilter | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) { return }

    # Read content as XML
    [xml]$xml = Get-Content $files[0].FullName

    # Process all records
    foreach ($afdeling in $xml.GetElementsByTagName("orgEenheid")) {
        $department = [PSCustomObject]@{}

        foreach ($child in $afdeling.ChildNodes) {
            $department | Add-Member -MemberType NoteProperty -Name $child.LocalName -Value $child.'#text' -Force
        }

        [void]$departments.value.Add($department)
    }

    # Only export departments that exist in contracts
    $Departments.value = $Departments.value.Where({$_.orgEenheidID -in $Contracts.orgEenheidOperID})
}

function Get-RAETXMLManagers {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)]$FileFilter,
        [parameter(Mandatory = $true)][ref]$Managers
    )

    $files = Get-ChildItem -Path $XMLBasePath -Filter $FileFilter | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) { return }

    # Read content as XML
    [xml]$xml = Get-Content $files[0].FullName

    # Process all records
    foreach ($roltoewijzing in $xml.GetElementsByTagName("roltoewijzing")) {
        $manager = [PSCustomObject]@{}

        foreach ($child in $roltoewijzing.ChildNodes) {
            $manager | Add-Member -MemberType NoteProperty -Name $child.LocalName -Value $child.'#text' -Force
        }

        [void]$Managers.value.Add($manager)
    }
}

function Get-RAETXMLBAFiles {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)][ref]$Persons,
        [parameter(Mandatory = $true)][ref]$Contracts
    )

    # List all files in the selected folder
    $files = Get-ChildItem -Path $XMLBasePath -Filter "*.xml"

    # Process all files
    foreach ($file in $files) {
        [xml]$xml = Get-Content $file.FullName

        foreach ($werknemer in $xml.GetElementsByTagName("persoon")) {
            $person = [PSCustomObject]@{
                persNr = $werknemer.identificatiePS.persNr;
                voornamen = $werknemer.kenmerken.naamOverig.roepnaam.waarde;
                achternaam = ($werknemer.kenmerken.naamOverig.voorvoegselsAanschrijfnaam.waarde + " " + $werknemer.kenmerken.naamOverig.aanschrijfnaam.waarde).trim(" ")
                #email = $werknemer.contactGegevens.werk.emailAdresWerk.waarde;
            }
            
            [void]$Persons.value.Add($person)
        }
        foreach ($dienstverband in $xml.GetElementsByTagName("dienstverband")) {
            foreach ($inzet in $dienstverband.GetElementsByTagName("inzet")) {
                $position = [PSCustomObject]@{
                    persNrDV = $dienstverband.identificatieDV.PersNrDV;
                    begindatumDV = $dienstverband.periodeDV.begindatum.waarde;
                    einddatumDV = $dienstverband.periodeDV.einddatum.waarde;
                    begindatumIZ = $inzet.periodeIZ.begindatum.waarde;
                    einddatumIZ = $inzet.periodeIZ.einddatum.waarde;
                    orgEenheidOperID = $inzet.identificatieIZ.orgEenheidOperID;
                    functiecode = $inzet.identificatieIZ.funcOper;
                }            
                [void]$Contracts.value.Add($position)
            }
        }
    }
}

function Get-ADAccountData {
    param(
        [parameter(Mandatory = $true)][ref]$Persons
    )
    
    # Get list from AD
    $adUsersWithMail= Get-ADUser -Filter * -Properties EmployeeId, Mail | Where-Object{$_.mail -like "*@*" -and ![string]::IsNullOrEmpty($_.employeeId) }  | Sort-Object EmployeeId -Unique
    $adUsersWithMailGrouped = $adUsersWithMail| Group-Object -Property EmployeeId -AsHashTable
    
    # Add email to persons
    $persons.value | Add-Member -MemberType NoteProperty -Name "email" -Value $null -Force
    $persons.value | ForEach-Object  { 
        $_.email = $adUsersWithMailGrouped[$_.persNr].mail
    }

    # Remove all persons where email is empty (no ad account)
    $Persons.value.Where({![string]::IsNullOrEmpty($_.mail)})
}

# Parsing persons/contracts XML
Write-Verbose -Verbose "Parsing person/contracts files..."
$persons = New-Object System.Collections.Generic.List[System.Object]
$contracts = New-Object System.Collections.Generic.List[System.Object]
Get-RAETXMLBAFiles -XMLBasePath $xmlPath -Persons ([ref]$persons) -Contracts ([ref]$contracts)
Write-Verbose -Verbose "Parsed person/contracts files."


# Employees export
Write-Verbose -Verbose "Employees: parsing input..."
Set-EmployeeStartEndDate -Contracts $contracts -Persons ([ref]$persons)
Get-ActiveRecords -AttributeStartDate "datum_indienst" -AttributeEndDate "datum_uitdienst" -ActivePreInDays 30 -ActivePostInDays 30 -Records ([ref]$persons)
Get-ADAccountData -Persons ([ref]$persons)
$csvEmployees = $persons | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNr } }, email, achternaam, voornamen, datum_uitdienst, @{Name = "adfs_login"; Expression = { $_.email } } | Sort-Object zoekcode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvEmployees | Out-File -FilePath "$capp12Path\medewerkers.csv" 
Write-Verbose -Verbose "Function & OU assignments: parsing input..."

# filter contracts to use only contracts which have a reference to persons (used in multiple exports below)
$contracts = $contracts.Where({$_.persNrDV -in $persons.persNr})

# funcion assignment export
Get-ActiveRecords -AttributeStartDate "begindatumIZ" -AttributeEndDate "einddatumIZ" -ActivePreInDays 30 -ActivePostInDays 30 -Records ([ref]$contracts)

$csvFunctionAssignments = $contracts | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNrDV } }, functiecode, @{Name = "datum_uitdienst"; Expression = { $_.einddatumIZ } } | Sort-Object zoekcode, functiecode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvFunctionAssignments | Out-File -FilePath "$capp12Path\functietoewijzing.csv"
Write-Verbose -Verbose "Function assignments: written output csv to disk."


# department assignment export
$csvOuAssignments = $contracts | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNrDV } },  @{Name = "werkgeverzoekcode"; Expression = { $_.orgEenheidOperID } }, @{Name = "datum_uitdienst"; Expression = { $_.einddatumIZ } } | Sort-Object zoekcode, werkgeverzoekcode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvOuAssignments | Out-File -FilePath "$capp12Path\aanstellingen.csv"
Write-Verbose -Verbose "OU Assignments: written output csv to disk."


# manager export
Write-Verbose -Verbose "Managers: parsing input xml..."
$managers = New-Object System.Collections.Generic.List[System.Object]
Get-RAETXMLManagers -XMLBasePath $xmlPath -FileFilter "Roltoewijzing_*.xml" -Managers ([ref]$managers)
Get-ActiveRecords -AttributeStartDate "begindatum" -AttributeEndDate "einddatum" -ActivePreInDays 30 -ActivePostInDays 30 -Records ([ref]$managers)
$csvManagers = $managers | Where-Object -Property oeRolCode -eq -Value "MGR" | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNr } }, @{Name = "contactzoekcode"; Expression = { $_.orgEenheidID } }, @{Name = "datum_uitdienst"; Expression = { $_.einddatum } } | Sort-Object zoekcode, contactzoekcode | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvManagers | Out-File -FilePath "$capp12Path\leidinggevenden.csv"
Write-Verbose -Verbose "Managers: written output csv to disk."


# function export
Write-Verbose -Verbose "Functions: parsing input xml..."
$functions = New-Object System.Collections.Generic.List[System.Object]
Get-RAETXMLFunctions -XMLBasePath $xmlPath -FileFilter "rst_functie_*.xml"  -Contracts $contracts -Functions ([ref]$functions)
$csvFunctions = $functions | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.FunctieCode } }, @{Name = "functienaam"; Expression = { $_.functieOmschrijving } } | Sort-Object zoekcode -Unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvFunctions | Out-File -FilePath "$capp12Path\functies.csv"
Write-Verbose -Verbose "Functions: written output csv to disk."


# department export
Write-Verbose -Verbose "Departments: parsing input xml ..."
$departments = New-Object System.Collections.Generic.List[System.Object] 
Get-RAETXMLDepartments -XMLBasePath $xmlPath -FileFilter "rst_orgeenheid_*.xml" -Contracts $contracts -Departments ([ref]$departments)
$csvDepartments = $departments | Select-Object -Property @{Name = "werkgeverzoekcode"; Expression = { $_.orgEenheidID } }, @{Name = "werkgevernaam"; Expression = { $_.naamLang } } | Sort-Object werkgeverzoekcode -Unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvDepartments | Out-File -FilePath "$capp12Path\afdelingen.csv"
Write-Verbose -Verbose "Departments: writting output csv."
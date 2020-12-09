# Init variables
$xmlPath = "C:\Users\ricad\OneDrive\Documents\Scripts\CAPP12\dataset"

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
        [parameter(Mandatory = $true)][ref]$functions
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

        [void]$functions.value.Add($function)
    }
}

function Get-RAETXMLDepartments {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)]$FileFilter,
        [parameter(Mandatory = $true)][ref]$departments
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
}
function Get-RAETXMLManagers {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)]$FileFilter,
        [parameter(Mandatory = $true)][ref]$managers
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

        [void]$managers.value.Add($manager)
    }
}
function Get-RAETXMLBAFiles {
    param(
        [parameter(Mandatory = $true)]$XMLBasePath,
        [parameter(Mandatory = $true)][ref]$persons,
        [parameter(Mandatory = $true)][ref]$contracts
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
                email = $werknemer.contactGegevens.werk.emailAdresWerk.waarde;
            }
            
            [void]$persons.value.Add($person)
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
                [void]$contracts.value.Add($position)
            }
        }
    }
}

$contracts = New-Object System.Collections.Generic.List[System.Object]
$persons = New-Object System.Collections.Generic.List[System.Object]
$managers = New-Object System.Collections.Generic.List[System.Object]
$functions = New-Object System.Collections.Generic.List[System.Object]
$departments = New-Object System.Collections.Generic.List[System.Object] 

Write-Verbose -Verbose "Parsing person/contracts files..."
Get-RAETXMLBAFiles -XMLBasePath $xmlPath ([ref]$persons) ([ref]$contracts)
Write-Verbose -Verbose "Parsed person/contracts files."

Write-Verbose -Verbose "Employees: parsing input..."
Set-EmployeeStartEndDate -Contracts $contracts ([ref]$persons)
Get-ActiveRecords -AttributeStartDate "datum_indienst" -AttributeEndDate "datum_uitdienst" -ActivePreInDays 30 -ActivePostInDays 30 ([ref]$persons)
$csvEmployees = $persons | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNr } }, email, achternaam, voornamen, datum_uitdienst, @{Name = "adfs_login"; Expression = { $_.email } } | Sort-Object zoekcode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvEmployees | Out-File -FilePath "$xmlPath\Output\medewerkers.csv" 

Write-Verbose -Verbose "Function assignments / OU assignments: parsing input..."
Get-ActiveRecords -AttributeStartDate "begindatumIZ" -AttributeEndDate "einddatumIZ" -ActivePreInDays 30 -ActivePostInDays 30 ([ref]$contracts)
$csvFunctionAssignments = $contracts | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNrDV } }, functiecode, @{Name = "datum_uitdienst"; Expression = { $_.einddatumIZ } } | Sort-Object zoekcode, functiecode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvFunctionAssignments | Out-File -FilePath "$xmlPath\Output\functietoewijzing.csv"
Write-Verbose -Verbose "Function assignments: written output csv to disk."

$csvOuAssignments = $contracts | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNrDV } },  @{Name = "werkgeverzoekcode"; Expression = { $_.orgEenheidOperID } }, @{Name = "datum_uitdienst"; Expression = { $_.einddatumIZ } } | Sort-Object zoekcode, werkgeverzoekcode -unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvOuAssignments | Out-File -FilePath "$xmlPath\Output\aanstellingen.csv"
Write-Verbose -Verbose "OU Assignments: written output csv to disk."

Write-Verbose -Verbose "Managers: parsing input xml..."
Get-RAETXMLManagers -XMLBasePath $xmlPath -FileFilter "Roltoewijzing_*.xml" ([ref]$managers)
Get-ActiveRecords -AttributeStartDate "begindatum" -AttributeEndDate "einddatum" -ActivePreInDays 30 -ActivePostInDays 30 ([ref]$managers)
$csvManagers = $managers | Where-Object -Property oeRolCode -eq -Value "MGR" | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.persNr } }, @{Name = "contactzoekcode"; Expression = { $_.orgEenheidID } }, @{Name = "datum_uitdienst"; Expression = { $_.einddatum } } | Sort-Object zoekcode, contactzoekcode | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvManagers | Out-File -FilePath "$xmlPath\Output\leidinggevenden.csv"
Write-Verbose -Verbose "Managers: written output csv to disk."

Write-Verbose -Verbose "Functions: parsing input xml..."
Get-RAETXMLFunctions -XMLBasePath $xmlPath -FileFilter "rst_functie_*.xml" ([ref]$functions)
$csvFunctions = $functions | Select-Object -Property @{Name = "zoekcode"; Expression = { $_.FunctieCode } }, @{Name = "functienaam"; Expression = { $_.functieOmschrijving } } | Sort-Object zoekcode -Unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvFunctions | Out-File -FilePath "$xmlPath\Output\functies.csv"
Write-Verbose -Verbose "Functions: written output csv to disk."

Write-Verbose -Verbose "Departments: parsing input xml ..."
Get-RAETXMLDepartments -XMLBasePath $xmlPath -FileFilter "rst_orgeenheid_*.xml" ([ref]$departments)
$csvDepartments = $departments | Select-Object -Property @{Name = "werkgeverzoekcode"; Expression = { $_.orgEenheidID } }, @{Name = "werkgevernaam"; Expression = { $_.naamLang } } | Sort-Object werkgeverzoekcode -Unique | ConvertTo-Csv -Delimiter ";" -NoTypeInformation
$csvDepartments | Out-File -FilePath "$xmlPath\Output\afdelingen.csv"
Write-Verbose -Verbose "Departments: writting output csv."
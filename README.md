# HelloID-Conn-Prov-Target-CAPP12

| :information_source: Information |
|:---------------------------|
| This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.       |

<br />

This ended up as a scheduled task for Service Automation.

## Table of contents

- [Introduction](#Introduction)
- [Getting started](#Getting-started)
  + [Connector settings](#Connector-settings)
  + [Prerequisites](#Prerequisites)
  + [Supported PowerShell versions](#Supported-PowerShell-versions)
- [Business logic](#Business-logic)
  + [HR Details](#HR-Details)
  + [AD Details](#AD-Details)
  + [CSV Export data](#CSV-Export-data)
- [Getting help](#Getting-help)
- [HelloID Docs](#HelloID-Docs)

## Introduction

HelloID Service Automation task to export Raet HR data in BintXML format to CSV files which CAPP12 can import.

> CSV Import jobs have to be created in CAPP12 for this connector to work.
 
## Getting started

### Connector settings

The following custom connector settings are available and required:

| Setting     | Description |
| ------------ | ----------- |
| Import BintXML files location | The location of the BintXML files |
| Export CAPP12 CSV file location | The location where the export CSV-files are saved |

### Prerequisites

- This connector requires an On-Premise HelloID Agent
- Using the HelloID On-Premises agent, Windows PowerShell 5.1 must be installed.

### Supported PowerShell versions

The connector is created for Windows PowerShell 5.1. This means that the connector can not be executed in the cloud and requires an On-Premises installation of the HelloID Agent.

> Older versions of Windows PowerShell are not supported.

## Business logic

### HR Details

- All persons with an employment contract that starts in 299 days are included in the report.
- All persons with active employment records are included.
- All persons who are inactive for a maximum of 299 days are included.
- All different function assignments will be included in the report. The employment data is deduplicated based on a hash on the employeeId, jobid, and end date fields. The identities are associated on the employments. Only linked data is used.

### AD Details

- Only the AD accounts with a entered email address are included.
- Only the attributes sAMAccountName, mail and employeeId are retrieved.
- This data is based on the value in the attribute 'employeeId' linked to the HR data. Only the linked data (common) is used.

### CSV Export data

- The complete dataset is written to CSV.
- CSV settings are:
  - Field delimiter: &quot;;&quot;
  - tekst qualifier: &quot;&quot;
  - encoding: &quot;utf-8&quot;
- Six CSV files are generated. The following mapping is used. (All other columns or fields are not included):

| **Bron** | **medewerkers.csv** | **Special mapping logic** |
| --- | --- | --- |
| employeeId | zoekcode | |
| mail | email |   |
| name.formatted | achternaam | Based on naming convention: \<prefix1\> \<lastname1\>-\<prefix2\> \<lastname2\> |
| name.nickName | voornamen |   |
| Placements.when.end | Datum\_uitdienst | Clear when enddate is 00-01-0000 |
| sAMAccountName | adfs\_login |   |

| **Bron** | **afdelingen.csv** | **Special mapping logic** |
| --- | --- | --- |
| ou.id | werkgeverzoekcode | |
| ou.details.description | werkgevernaam |   |

| **Bron** | **aanstellingen.csv** | **Special mapping logic** |
| --- | --- | --- |
| employeeId | Zoekcode | |
| Relation.organizationalUnitId | Werkgeverzoekcode |   |
| Placements.when.end | Datum\_uitdienst | Clear when enddate is 00-01-0000 |

| **Bron** | **functies.csv** | **Special mapping logic** |
| --- | --- | --- |
| function.id | Functiecode | |
| function.details.description | functienaam |   |

| **Bron** | **functietoewijzing.csv** | **Special mapping logic** |
| --- | --- | --- |
| employeeId | Zoekcode | |
| function.id | Functiecode |   |
| Placements.when.end | Datum\_uitdienst | Clear when enddate is 00-01-0000 |

| **Bron** | **leidinggevenden.csv** | **Special mapping logic** |
| --- | --- | --- |
| Relation.managerId | Zoekcode | |
| Id | contactzoekcode |   |
| Placements.when.end | Datum\_uitdienst | Clear when enddate is 00-01-0000 |

## Getting help

> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/hc/en-us/articles/360012518799-How-to-add-a-target-system) pages_

> _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com)_

## HelloID Docs

The official HelloID documentation can be found at: https://docs.helloid.com/

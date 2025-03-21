# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [1.1.1] - 11-02-2025

Fixes:
-   Only one position was set/removed in the create/update script.
-   Resource data was not unique, resulting in unnecessary API calls.
-   The DepartmentManager resource script’s success flag was not set to false when actions failed in the foreach loop.

## [1.1.0] - 04-10-2024

Fixes after first implementation. Feature: removed enable/disable script

## [1.0.0] - 04-07-2024

This is the first official release of _HelloID-Conn-Prov-Target-CAPP12_. This release is based on template version _1.2.0_, with some features from the next release, 1.3?.x. The main feature added from the upcoming release is the integration of the Dryrun message into the main processing flow. Basically, the Dryrun switch has been moved as close as possible to the actual web requests.

### Added


### Changed

### Deprecated

### Removed
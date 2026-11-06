#requires -Version 5.1
[CmdletBinding()]
param([string]$DatabasePath)
$ErrorActionPreference='Stop'
if (-not $DatabasePath) { $DatabasePath=Join-Path $PSScriptRoot 'Directory-Lens.db' }
if (Test-Path -LiteralPath $DatabasePath) { throw 'Database already exists. Use a fresh folder for another customer or lab.' }
. (Join-Path $PSScriptRoot 'Database.ps1')
Invoke-Database (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'schema.sql') -Raw) -Write

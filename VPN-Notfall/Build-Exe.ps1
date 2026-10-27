<#
.SYNOPSIS
    Optional: baut VPN-Notfall.exe aus VPN-Notfall.ps1 (Modul ps2exe aus der PowerShell Gallery).

    GHG-Mapping.ps1 muss weiterhin neben der .exe liegen (oder per Intune installiert sein).
    Hinweis: Mit ps2exe gebaute .exe-Dateien werden von Virenscannern oft faelschlich gemeldet -
    im Zweifel VPN-Notfall.bat verwenden.

.BEISPIEL
    powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

Invoke-ps2exe -inputFile (Join-Path $PSScriptRoot 'VPN-Notfall.ps1') `
    -outputFile (Join-Path $PSScriptRoot 'VPN-Notfall.exe') `
    -title 'GHG VPN-Notfall' -description 'VPN reparieren und Netzlaufwerke neu verbinden'

Write-Host 'Fertig: VPN-Notfall.exe (zusammen mit GHG-Mapping.ps1 weitergeben)' -ForegroundColor Green

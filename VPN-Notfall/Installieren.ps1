<#
.SYNOPSIS
    Installiert das VPN-Notfall-Tool (z.B. als Intune-Win32-App, laeuft als SYSTEM).

    - kopiert VPN-Notfall.bat, VPN-Notfall.ps1 und GHG-Mapping.ps1 nach C:\ProgramData\GHG\VPN-Notfall
    - legt die Verknuepfung "VPN-Notfall" auf dem oeffentlichen Desktop und im Startmenue an

.BEISPIEL
    Installieren:   powershell.exe -NoProfile -ExecutionPolicy Bypass -File Installieren.ps1
    Deinstallieren: powershell.exe -NoProfile -ExecutionPolicy Bypass -File Installieren.ps1 -Deinstallieren
    Erkennung:      Datei C:\ProgramData\GHG\VPN-Notfall\VPN-Notfall.ps1 vorhanden
#>

param([switch]$Deinstallieren)

$ErrorActionPreference = 'Stop'
$Zielordner = Join-Path $env:ProgramData 'GHG\VPN-Notfall'
$Verknuepfungen = @(
    (Join-Path $env:PUBLIC 'Desktop\VPN-Notfall.lnk'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\VPN-Notfall.lnk')
)

if ($Deinstallieren) {
    Remove-Item -LiteralPath $Zielordner -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Verknuepfungen -Force -ErrorAction SilentlyContinue
    exit 0
}

New-Item -ItemType Directory -Path $Zielordner -Force | Out-Null
foreach ($datei in 'VPN-Notfall.bat', 'VPN-Notfall.ps1', 'GHG-Mapping.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $datei) -Destination $Zielordner -Force
}

$shell = New-Object -ComObject WScript.Shell
foreach ($pfad in $Verknuepfungen) {
    $lnk = $shell.CreateShortcut($pfad)
    $lnk.TargetPath = Join-Path $Zielordner 'VPN-Notfall.bat'
    $lnk.WorkingDirectory = $Zielordner
    $lnk.Description = 'VPN reparieren und Netzlaufwerke neu verbinden'
    $lnk.Save()
}
exit 0

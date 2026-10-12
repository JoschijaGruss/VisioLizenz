<#
.SYNOPSIS
    Erstellt die configuration.xml (Schritt 5 der Anleitung) fuer Visio / Project
    mit MAK-Lizenz - ohne das Office-Anpassungstool im Browser.

.BESCHREIBUNG
    Fragt Produkt, Version und MAK-Schluessel ab und schreibt die configuration.xml
    in den Zielordner (Standard: C:\VisioProjectSetup).
    Weitere Produkte/Versionen koennen unten in $Produkte ergaenzt werden.

.BEISPIEL
    powershell -ExecutionPolicy Bypass -File .\New-OfficeConfig.ps1
    powershell -ExecutionPolicy Bypass -File .\New-OfficeConfig.ps1 -Zielordner D:\Test
#>
param(
    [string]$Zielordner = "C:\VisioProjectSetup",
    [string]$Sprache    = "de-de"
)

$ErrorActionPreference = "Stop"

# ---- Produktkatalog: hier spaeter weitere Produkte/Versionen ergaenzen ----
# Channel: LTSC-Volumenlizenzprodukte benoetigen den passenden PerpetualVL-Kanal
# (so erzeugt es auch config.office.com fuer diese Produkte).
$Produkte = [ordered]@{
    "Visio"   = [ordered]@{
        "2024 Standard" = @{ Id = "VisioStd2024Volume";   Channel = "PerpetualVL2024"; Name = "Visio LTSC Standard 2024" }
        "2021 Standard" = @{ Id = "VisioStd2021Volume";   Channel = "PerpetualVL2021"; Name = "Visio LTSC Standard 2021" }
    }
    "Project" = [ordered]@{
        "2024 Standard" = @{ Id = "ProjectStd2024Volume"; Channel = "PerpetualVL2024"; Name = "Project Standard 2024" }
        "2021 Standard" = @{ Id = "ProjectStd2021Volume"; Channel = "PerpetualVL2021"; Name = "Project Standard 2021" }
    }
}

function Select-Option([string]$Titel, [string[]]$Optionen) {
    Write-Host ""
    Write-Host $Titel -ForegroundColor Cyan
    for ($i = 0; $i -lt $Optionen.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Optionen[$i])
    }
    while ($true) {
        $eingabe = Read-Host "Auswahl (1-$($Optionen.Count))"
        $n = 0
        if ([int]::TryParse($eingabe, [ref]$n) -and $n -ge 1 -and $n -le $Optionen.Count) {
            return $Optionen[$n - 1]
        }
        Write-Host "Ungueltige Auswahl." -ForegroundColor Yellow
    }
}

# ---- 1. Produkt ----
$produkt = Select-Option "Welches Produkt?" @($Produkte.Keys)

# ---- 2. Version ----
$version = Select-Option "Welche Version von $produkt?" @($Produkte[$produkt].Keys)
$auswahl = $Produkte[$produkt][$version]

# ---- 3. MAK-Schluessel ----
Write-Host ""
while ($true) {
    $key = (Read-Host "MAK-Schluessel eingeben (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)").Trim().ToUpper()
    if ($key -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { break }
    Write-Host "Format ungueltig, bitte erneut eingeben." -ForegroundColor Yellow
}

# ---- 4. configuration.xml erzeugen ----
$xml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$($auswahl.Channel)">
    <Product ID="$($auswahl.Id)" PIDKEY="$key">
      <Language ID="$Sprache" />
      <ExcludeApp ID="OneDrive" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Updates Enabled="TRUE" />
  <Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
"@

if (-not (Test-Path $Zielordner)) { New-Item -ItemType Directory -Path $Zielordner | Out-Null }
$pfad = Join-Path $Zielordner "configuration.xml"
$xml | Set-Content -Path $pfad -Encoding UTF8

Write-Host ""
Write-Host "Fertig: $pfad" -ForegroundColor Green
Write-Host "Produkt : $($auswahl.Name) ($($auswahl.Id))"
Write-Host "Kanal   : $($auswahl.Channel)"
Write-Host "Sprache : $Sprache"
Write-Host ""
Get-Content $pfad

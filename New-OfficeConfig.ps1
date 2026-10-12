<#
.SYNOPSIS
    Erstellt direkt die configuration.xml fuer Visio Standard / Project Standard (MAK).

    Fest eingestellt: 64-Bit, SemiAnnual, Deutsch, ohne OneDrive, Firma "GHG St. Gallen".
    Abgefragt wird nur: Produkt (Visio/Project), Jahr (2024/2021) und MAK-Schluessel.

.BEISPIEL
    powershell -ExecutionPolicy Bypass -File .\New-OfficeConfig.ps1
#>

$ErrorActionPreference = "Stop"
$Zielordner = "C:\VisioProjectSetup"

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

$produkt = Select-Option "Welches Produkt?" @("Visio", "Project")
$jahr    = Select-Option "Welches Jahr?"    @("2024", "2021")

Write-Host ""
while ($true) {
    $key = (Read-Host "MAK-Schluessel eingeben (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)").Trim().ToUpper()
    if ($key -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { break }
    Write-Host "Format ungueltig, bitte erneut eingeben." -ForegroundColor Yellow
}

$productId = "${produkt}Std${jahr}Volume"   # z.B. VisioStd2024Volume / ProjectStd2021Volume
$configId  = [guid]::NewGuid().ToString()

$xml = @"
<Configuration ID="$configId">
  <Add OfficeClientEdition="64" Channel="SemiAnnual">
    <Product ID="$productId" PIDKEY="$key">
      <Language ID="de-de" />
      <ExcludeApp ID="OneDrive" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Updates Enabled="TRUE" />
  <AppSettings>
    <Setup Name="Company" Value="GHG St. Gallen" />
  </AppSettings>
  <Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
"@

if (-not (Test-Path $Zielordner)) { New-Item -ItemType Directory -Path $Zielordner | Out-Null }
$pfad = Join-Path $Zielordner "configuration.xml"
$xml | Set-Content -Path $pfad -Encoding UTF8

Write-Host ""
Write-Host "Fertig: $pfad  ($productId)" -ForegroundColor Green
Write-Host ""
Get-Content $pfad

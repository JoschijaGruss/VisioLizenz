<#
.SYNOPSIS
    Netzlaufwerke und Drucker verbinden (Intune-Plattformskript), robust fuer Always On VPN.

.DESCRIPTION
    Als SYSTEM ausgefuehrt (Intune: "Dieses Skript mit den Anmeldeinformationen des
    angemeldeten Benutzers ausfuehren" = Nein, "64-Bit-PowerShell" = Ja):
      - kopiert sich nach C:\ProgramData\GHG\Mapping\GHG-Mapping.ps1
      - legt die geplante Aufgabe \GHG\GHG-Mapping an. Sie laeuft als angemeldeter Benutzer
        bei der Anmeldung, bei jeder neuen Netzwerkverbindung und bei jedem VPN-Verbindungsaufbau.

    Als Benutzer ausgefuehrt (durch die Aufgabe oder durch VPN-Notfall.ps1):
      - wartet, bis der Domain Controller erreichbar ist (VPN aufgebaut)
      - liest alle Gruppen des Benutzers aus dem AD (auch verschachtelte)
      - verbindet die Laufwerke aus $driveMappingJson und die Drucker ueber die Druckergruppen

    Log: %LOCALAPPDATA%\GHG\Logs\Mapping.log (Benutzer)
         C:\ProgramData\GHG\Logs\Mapping-Install.log (SYSTEM)

.PARAMETER NurLaden
    Nur Einstellungen und Funktionen laden (fuer VPN-Notfall.ps1), nichts ausfuehren.

.PARAMETER WartenSekunden
    So lange wird auf den Domain Controller (VPN) gewartet.
#>

[CmdletBinding()]
param(
    [switch]$NurLaden,
    [int]$WartenSekunden = 120
)

###########################################################################################
# Einstellungen
###########################################################################################

# AD-Domain fest eintragen: $env:USERDNSDOMAIN ist auf Entra-joined Geraeten leer
$Domain = 'ghg.local'

# Laufwerke im Format des IntuneDriveMapping-Generators (JSON kann 1:1 eingefuegt werden).
# GroupFilter: Gruppenname, mehrere mit Komma getrennt, leer = alle Benutzer.
# Pfade mit FQDN angeben (server.ghg.local statt server), sonst klappt es ueber VPN oft nicht.
# Beispiel:
#   { "Path": "\\\\scghgfs01.ghg.local\\Daten", "DriveLetter": "S", "Label": "Daten", "GroupFilter": "" },
#   { "Path": "\\\\scghgfs01.ghg.local\\Home$\\%USERNAME%", "DriveLetter": "H", "Label": "Home", "GroupFilter": "" }
$driveMappingJson = @'
[
]
'@

# $false = Windows versucht beim Anmelden nicht, Laufwerke wiederherzustellen, solange das VPN
# noch nicht steht (keine roten X / "nicht verfuegbar"). Die Aufgabe verbindet sie ohnehin
# bei jeder Anmeldung und jedem VPN-Aufbau neu.
$LaufwerkePersistent = $false

# Drucker: Gruppen, deren Name mit einem dieser Praefixe beginnt, sind Druckergruppen.
# Freigabename des Druckers = Beschreibung der Gruppe im AD.
# Gruppenname endet auf "default" = Standarddrucker.
$PrintServer = '\\scghgpsv01.ghg.local'
$PrinterGroupPrefixes = @(
    'GHG_BR_', 'CP_A_', 'CP_B_', 'CP_C_', 'CP_D_', 'CP_E_', 'GHG_GE_', 'GHG_MA_', 'GHG_RO_', 'GHGP',
    'GHG_TE_', 'GHG_RI_', 'GHG-GE-PR', 'GHG-CP-PR', 'GHG-HP-PR', 'GHG-SO-PR', 'GHG-TE-PR',
    'GHG-RI-PR', 'GHG-BR-PR', 'GHG-RO-PR', 'GHG-MA-PR'
)

# Geplante Aufgabe und Installationsordner
$TaskName   = 'GHG-Mapping'
$TaskPath   = '\GHG\'
$InstallDir = Join-Path $env:ProgramData 'GHG\Mapping'

# Alte Aufgaben, die dieses Skript ersetzt (werden bei der Installation entfernt),
# z.B. 'IntuneDriveMapping' - erst eintragen, wenn $driveMappingJson vollstaendig ist!
$AlteAufgaben = @()

###########################################################################################
# Funktionen
###########################################################################################

$MappingSkript = $PSCommandPath

function Test-RunningAsSystem {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
}

if (Test-RunningAsSystem) { $LogDatei = Join-Path $env:ProgramData 'GHG\Logs\Mapping-Install.log' }
else { $LogDatei = Join-Path $env:LOCALAPPDATA 'GHG\Logs\Mapping.log' }

function Write-Log {
    param(
        [string]$Text,
        [ValidateSet('Info', 'OK', 'Warnung', 'Fehler')][string]$Typ = 'Info'
    )
    $farbe = @{ Info = 'Gray'; OK = 'Green'; Warnung = 'Yellow'; Fehler = 'Red' }[$Typ]
    Write-Host "  $Text" -ForegroundColor $farbe
    try {
        $ordner = Split-Path $LogDatei
        if (-not (Test-Path $ordner)) { New-Item -ItemType Directory -Path $ordner -Force | Out-Null }
        if ((Test-Path $LogDatei) -and (Get-Item $LogDatei).Length -gt 1MB) { Move-Item $LogDatei "$LogDatei.alt" -Force }
        $zeile = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Typ, $Text
        Add-Content -Path $LogDatei -Value $zeile -Encoding UTF8
    }
    catch { }
}

function Test-Port {
    param([string]$Ziel, [int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $versuch = $client.BeginConnect($Ziel, $Port, $null, $null)
        if (-not $versuch.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($versuch)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-ServerAusPfad([string]$Pfad) {
    ($Pfad.TrimStart('\') -split '\\')[0]
}

function Test-UncPfad([string]$Pfad) {
    # Erst SMB-Port pruefen - Test-Path allein haengt ohne VPN bis zu einer Minute
    (Test-Port (Get-ServerAusPfad $Pfad) 445) -and (Test-Path -LiteralPath $Pfad)
}

function Test-DomainErreichbar {
    # DNS-Name der Domain liefert die Domain Controller, LDAP-Port 389 pruefen
    try { $adressen = [System.Net.Dns]::GetHostAddresses($Domain) } catch { return $false }
    foreach ($ip in $adressen) {
        if (Test-Port $ip.IPAddressToString 389 1500) { return $true }
    }
    return $false
}

function Wait-Domain([int]$Sekunden) {
    $ende = (Get-Date).AddSeconds($Sekunden)
    while ($true) {
        if (Test-DomainErreichbar) { return $true }
        if ((Get-Date) -ge $ende) { return $false }
        Start-Sleep -Seconds 5
    }
}

function ConvertTo-LdapWert([string]$Wert) {
    # Sonderzeichen fuer LDAP-Filter escapen (z.B. "CN=Muster\, Hans" -> Backslash)
    $Wert.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

function Get-AdGruppen {
    # Alle Gruppen des angemeldeten Benutzers inkl. verschachtelter Gruppen: Name, Beschreibung
    $sucher = New-Object System.DirectoryServices.DirectorySearcher
    $sucher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Domain")
    $sucher.PageSize = 1000

    $benutzer = $null
    $upn = whoami.exe /upn 2>$null
    if ($LASTEXITCODE -eq 0 -and $upn) {
        $sucher.Filter = "(&(objectCategory=user)(userPrincipalName=$(ConvertTo-LdapWert $upn.Trim())))"
        $benutzer = $sucher.FindOne()
    }
    if (-not $benutzer) {
        $sucher.Filter = "(&(objectCategory=user)(sAMAccountName=$(ConvertTo-LdapWert $env:USERNAME)))"
        $benutzer = $sucher.FindOne()
    }
    if (-not $benutzer) { throw "Benutzer $env:USERNAME wurde im AD ($Domain) nicht gefunden." }

    $dn = [string]$benutzer.Properties['distinguishedname'][0]
    # LDAP_MATCHING_RULE_IN_CHAIN liefert auch verschachtelte Gruppen
    $sucher.Filter = "(&(objectCategory=group)(member:1.2.840.113556.1.4.1941:=$(ConvertTo-LdapWert $dn)))"
    [void]$sucher.PropertiesToLoad.Add('name')
    [void]$sucher.PropertiesToLoad.Add('description')
    foreach ($treffer in $sucher.FindAll()) {
        [pscustomobject]@{
            Name         = [string]$treffer.Properties['name'][0]
            Beschreibung = [string]$treffer.Properties['description'][0]
        }
    }
}

function Get-Laufwerke {
    # Alle konfigurierten Laufwerke (noch ohne Gruppenfilter)
    foreach ($eintrag in ($driveMappingJson | ConvertFrom-Json)) {
        [pscustomobject]@{
            Buchstabe = ([string]$eintrag.DriveLetter).Trim().TrimEnd(':').ToUpper()
            Pfad      = [Environment]::ExpandEnvironmentVariables([string]$eintrag.Path).TrimEnd('\')
            Label     = [string]$eintrag.Label
            Gruppen   = @(@($eintrag.GroupFilter) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
}

function Select-FuerBenutzer($Laufwerke, $Gruppen) {
    $namen = @($Gruppen | ForEach-Object { $_.Name })
    $Laufwerke | Where-Object {
        $_.Gruppen.Count -eq 0 -or @($_.Gruppen | Where-Object { $namen -contains $_ }).Count -gt 0
    }
}

function Connect-Laufwerk($Laufwerk) {
    $lw   = "$($Laufwerk.Buchstabe):"
    $pfad = $Laufwerk.Pfad

    if (-not (Test-UncPfad $pfad)) {
        Write-Log "$pfad ist nicht erreichbar (VPN getrennt, Server aus oder keine Berechtigung) - $lw bleibt unveraendert." Fehler
        return $false
    }

    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$lw'" -ErrorAction SilentlyContinue
    if ($disk -and $disk.DriveType -ne 4) {
        Write-Log "$lw ist durch ein lokales Laufwerk (z.B. USB-Stick) belegt - $pfad wird nicht verbunden." Fehler
        return $false
    }

    $ist = Get-SmbMapping -LocalPath $lw -ErrorAction SilentlyContinue
    if ($ist -and $ist.RemotePath.TrimEnd('\') -eq $pfad -and $ist.Status -eq 'OK' -and (Test-Path -LiteralPath "$lw\")) {
        Write-Log "$lw -> $pfad ist verbunden." OK
        return $true
    }

    # Getrennte, "gemerkte" oder falsche Zuordnung entfernen und neu verbinden.
    # net use ueber cmd, damit Fehlermeldungen nicht als PowerShell-Fehler auflaufen.
    $null = cmd.exe /c "net use $lw /delete /y 2>&1"
    $persistent = if ($LaufwerkePersistent) { 'yes' } else { 'no' }
    $ausgabe = cmd.exe /c "net use $lw `"$pfad`" /persistent:$persistent 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $text = (($ausgabe | Out-String) -replace '\s+', ' ').Trim()
        if ($text -match '\b1219\b') {
            $text += ' -> Es besteht schon eine Verbindung zu diesem Server mit anderen Anmeldedaten (VPN-Notfall: "Harte Reparatur").'
        }
        Write-Log "$lw -> $pfad FEHLER: $text" Fehler
        return $false
    }

    if ($Laufwerk.Label) {
        try { (New-Object -ComObject Shell.Application).NameSpace("$lw\").Self.Name = $Laufwerk.Label } catch { }
    }
    Write-Log "$lw -> $pfad neu verbunden." OK
    return $true
}

function Set-Standarddrucker([string]$Drucker) {
    # Sonst setzt "Windows verwaltet Standarddrucker" den Drucker wieder zurueck
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord -ErrorAction SilentlyContinue
    $p = Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $Drucker }
    if ($p) {
        $null = Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter
        Write-Log "Standarddrucker: $Drucker" OK
    }
}

function Connect-Drucker($Gruppen) {
    $druckerGruppen = @($Gruppen | Where-Object {
            $name = $_.Name
            @($PrinterGroupPrefixes | Where-Object { $name -like "$_*" }).Count -gt 0
        })
    if (-not $druckerGruppen) { Write-Log 'Keine Druckergruppen fuer diesen Benutzer.'; return }

    $vorhanden = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($gruppe in $druckerGruppen) {
        if (-not $gruppe.Beschreibung) {
            Write-Log "Druckergruppe $($gruppe.Name) hat keine Beschreibung (= Freigabename) im AD." Warnung
            continue
        }
        $drucker = '{0}\{1}' -f $PrintServer.TrimEnd('\'), $gruppe.Beschreibung.Trim()
        if ($vorhanden -contains $drucker) {
            Write-Log "Drucker $drucker ist vorhanden." OK
        }
        else {
            try {
                Add-Printer -ConnectionName $drucker -ErrorAction Stop
                Write-Log "Drucker $drucker verbunden." OK
            }
            catch {
                Write-Log "Drucker $drucker FEHLER: $($_.Exception.Message)" Fehler
                continue
            }
        }
        if ($gruppe.Name -like '*default') { Set-Standarddrucker $drucker }
    }
}

function Invoke-Mapping([int]$WartenSekunden = 120) {
    Write-Log "=== Mapping gestartet ($env:USERNAME auf $env:COMPUTERNAME) ==="
    if (-not (Wait-Domain $WartenSekunden)) {
        Write-Log "Domain $Domain nach $WartenSekunden s nicht erreichbar (VPN nicht verbunden?). Die Aufgabe startet automatisch erneut, sobald das VPN verbunden ist." Fehler
        return $false
    }
    try { $gruppen = @(Get-AdGruppen) }
    catch {
        Write-Log "AD-Gruppen konnten nicht gelesen werden: $($_.Exception.Message)" Fehler
        return $false
    }
    Write-Log "$($gruppen.Count) AD-Gruppen gelesen."

    $alleOk = $true
    foreach ($laufwerk in (Select-FuerBenutzer (Get-Laufwerke) $gruppen)) {
        if (-not (Connect-Laufwerk $laufwerk)) { $alleOk = $false }
    }
    Connect-Drucker $gruppen
    Write-Log '=== Mapping beendet ==='
    return $alleOk
}

function New-EreignisTrigger([string]$Log, [string]$Quelle, [int]$Id) {
    $klasse = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $klasse -ClientOnly
    $trigger.Enabled = $true
    $trigger.Delay = 'PT5S'
    $trigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"$Log`"><Select Path=`"$Log`">*[System[Provider[@Name='$Quelle'] and EventID=$Id]]</Select></Query></QueryList>"
    $trigger
}

function Install-Aufgabe {
    Write-Log '=== Installation als SYSTEM ==='
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $ziel = Join-Path $InstallDir 'GHG-Mapping.ps1'
    Copy-Item -LiteralPath $MappingSkript -Destination $ziel -Force

    foreach ($alt in $AlteAufgaben) {
        Get-ScheduledTask -TaskName $alt -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
        Write-Log "Alte Aufgabe $alt entfernt."
    }

    # conhost --headless: kein aufblitzendes PowerShell-Fenster
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $aktion = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
        -Argument "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$ziel`""

    $anmeldung = New-ScheduledTaskTrigger -AtLogOn
    $anmeldung.Delay = 'PT10S'
    $trigger = @(
        $anmeldung
        # Neue Netzwerkverbindung (WLAN, LAN, VPN-Adapter)
        New-EreignisTrigger 'Microsoft-Windows-NetworkProfile/Operational' 'Microsoft-Windows-NetworkProfile' 10000
        # VPN-Verbindung aufgebaut
        New-EreignisTrigger 'Application' 'RasClient' 20225
    )

    $benutzer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $aktion -Trigger $trigger `
        -Principal $benutzer -Settings $einstellungen -Force | Out-Null
    Write-Log "Aufgabe $TaskPath$TaskName angelegt ($ziel)." OK

    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

###########################################################################################
# Start
###########################################################################################

if ($NurLaden) { return }

if (Test-RunningAsSystem) {
    try { Install-Aufgabe }
    catch { Write-Log "Installation fehlgeschlagen: $($_.Exception.Message)" Fehler; exit 1 }
}
else {
    $null = Invoke-Mapping -WartenSekunden $WartenSekunden
}

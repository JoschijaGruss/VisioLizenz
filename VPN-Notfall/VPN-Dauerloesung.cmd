<# : Batch-Teil - startet den PowerShell-Teil dieser Datei
@echo off
set "VPN_FIX_DATEI=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:VPN_FIX_DATEI))"
exit /b
#>

###########################################################################################
# GHG VPN-Dauerloesung - EINMAL ausfuehren, danach laeuft alles automatisch (auch nach Neustart)
#
# Kern: Always On VPN dauerhaft auf ein festes Protokoll stellen (5 = nur SSTP).
#   Seit KB5124008 / KB5124012 haengt das VPN, wenn das Profil zwischen IKEv2 und SSTP
#   wechseln darf (VPNStrategy 0, 6, 8, 14). Mit festem SSTP steht das VPN ausserdem frueher -
#   dadurch finden auch die Intune-Laufwerke die Server wieder.
#
# Dazu: Windows stellt Netzlaufwerke bei der Anmeldung nicht mehr selbst wieder her
#   (RestoreConnection = 0) - sonst bleiben sie "nicht verfuegbar", wenn das VPN noch fehlt.
#   Reserve: Sobald das VPN steht, werden kaputte/gemerkte Laufwerke neu verbunden und die
#   Intune-Laufwerkszuordnung (DriveMapping) noch einmal ausgefuehrt.
#
# Geplante Aufgaben (Aufgabenplanung, Ordner \GHG\):
#   VPN-Fix System     SYSTEM     Systemstart, alle 15 Min., VPN-Fehler -> VPN-Profile "alle Benutzer"
#   VPN-Fix Benutzer   Benutzer   Anmeldung, alle 15 Min., VPN-Fehler   -> eigenes VPN-Profil
#   VPN-Fix Laufwerke  Benutzer   Anmeldung, VPN verbunden              -> Laufwerke (Reserve)
#
# Start:   Doppelklick (fragt nach Adminrechten) -> [1] Einrichten -> ab- und wieder anmelden
# Intune:  in VPN-Dauerloesung.ps1 umbenennen, als Plattformskript verteilen (als SYSTEM, 64-Bit)
# Logs:    C:\ProgramData\GHG\VPN-Fix\Logs\System.log, %LOCALAPPDATA%\GHG\Logs\VPN-Fix.log
###########################################################################################

###########################################################################################
# Einstellungen
###########################################################################################

$Einstellungen = [ordered]@{
    # Nur dieses VPN-Profil bearbeiten, leer = alle VPN-Profile
    VpnName                       = ''
    # Festes Protokoll: 'SSTP' (5, funktioniert bei euch) oder 'IKEv2' (7)
    Protokoll                     = 'SSTP'
    # Windows soll Netzlaufwerke bei der Anmeldung nicht selbst wiederherstellen (RestoreConnection = 0)
    LaufwerkeNichtWiederherstellen = $true
    # Reserve: nach dem VPN-Aufbau Laufwerke pruefen und Intune-Zuordnung ausfuehren
    LaufwerkeReserve              = $true
    # AD-Domain - daran wird erkannt, ob das Firmennetz (VPN) erreichbar ist
    Domain                        = 'ghg.local'
    # So lange wird nach Anmeldung/VPN-Aufbau auf das Firmennetz gewartet
    WartenSekunden                = 120
    # Geplante Aufgaben der Intune-Laufwerkszuordnung, deren Skript ausgefuehrt wird
    MappingAufgaben               = @('*DriveMapping*')
}

$Ordner   = Join-Path $env:ProgramData 'GHG\VPN-Fix'
$TaskPath = '\GHG\'
$NetzwerkProvider = 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider'

###########################################################################################
# Skript fuer die geplanten Aufgaben (wird nach C:\ProgramData\GHG\VPN-Fix\VPN-Fix.ps1 geschrieben)
###########################################################################################

$WorkerCode = @'
<#
    GHG VPN-Fix - ausgefuehrt von den geplanten Aufgaben \GHG\VPN-Fix * (eingerichtet durch VPN-Dauerloesung.cmd)
    -Modus System     VPN-Profile "alle Benutzer" (ProgramData) auf festes Protokoll
    -Modus Vpn        eigenes VPN-Profil auf festes Protokoll
    -Modus Laufwerke  auf Firmennetz warten, kaputte/gemerkte Laufwerke neu verbinden, Intune-Zuordnung
#>
param(
    [ValidateSet('System', 'Vpn', 'Laufwerke')][string]$Modus = 'Vpn',
    [switch]$NurLaden
)

$Ordner      = Join-Path $env:ProgramData 'GHG\VPN-Fix'
$PbkAlle     = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$PbkBenutzer = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

try { $E = Get-Content -LiteralPath (Join-Path $Ordner 'Einstellungen.json') -Raw -ErrorAction Stop | ConvertFrom-Json }
catch { $E = $null }

if ($Modus -eq 'System') { $LogDatei = Join-Path $Ordner 'Logs\System.log' }
else { $LogDatei = Join-Path $env:LOCALAPPDATA 'GHG\Logs\VPN-Fix.log' }

function Write-Log([string]$Text) {
    try {
        $logOrdner = Split-Path $LogDatei
        if (-not (Test-Path $logOrdner)) { New-Item -ItemType Directory -Path $logOrdner -Force | Out-Null }
        if ((Test-Path $LogDatei) -and (Get-Item $LogDatei).Length -gt 1MB) { Move-Item $LogDatei "$LogDatei.alt" -Force }
        $zeile = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Modus, $Text
        Add-Content -Path $LogDatei -Value $zeile -Encoding UTF8
    }
    catch { }
}

# ---------------------------------------------------------------- VPN-Profil (rasphone.pbk)

function Read-TextDatei([string]$Pfad) {
    # Liest eine Textdatei und merkt sich die Kodierung, damit sie unveraendert zurueckgeschrieben wird
    $leser = New-Object System.IO.StreamReader($Pfad, [Text.Encoding]::Default, $true)
    try {
        $text = $leser.ReadToEnd()
        [pscustomobject]@{ Text = $text; Kodierung = $leser.CurrentEncoding }
    }
    finally { $leser.Close() }
}

function Get-PbkEintraege([string]$Datei) {
    # VPN-Profile (Type=2) mit aktueller VPNStrategy (fehlt die Zeile: 0 = automatisch)
    if (-not (Test-Path -LiteralPath $Datei)) { return }
    $eintraege = @()
    foreach ($zeile in ((Read-TextDatei $Datei).Text -split "`r?`n")) {
        if ($zeile -match '^\[(.+)\]\s*$') {
            $eintraege += [pscustomobject]@{ Name = $Matches[1]; Datei = $Datei; Typ = 0; Strategie = 0 }
        }
        elseif ($eintraege -and $zeile -match '^Type=(\d+)') { $eintraege[-1].Typ = [int]$Matches[1] }
        elseif ($eintraege -and $zeile -match '^VPNStrategy=(\d+)') { $eintraege[-1].Strategie = [int]$Matches[1] }
    }
    $eintraege | Where-Object { $_.Typ -eq 2 -and (-not $E.VpnName -or $_.Name -eq $E.VpnName) }
}

function Set-PbkStrategie([string]$Datei, [string[]]$ProfilNamen, [int]$Wert) {
    $inhalt = Read-TextDatei $Datei
    $zeilen = $inhalt.Text -split "`r?`n"
    $imProfil = $false
    $geaendert = 0
    for ($i = 0; $i -lt $zeilen.Count; $i++) {
        if ($zeilen[$i] -match '^\[(.+)\]\s*$') { $imProfil = $ProfilNamen -contains $Matches[1] }
        elseif ($imProfil -and $zeilen[$i] -match '^VPNStrategy=\d+') {
            $zeilen[$i] = "VPNStrategy=$Wert"
            $geaendert++
        }
    }
    if ($geaendert -eq 0) { return $false }
    # Einmalige Sicherung des Originalzustands
    $sicherung = "$Datei.vor-VPN-Fix"
    if (-not (Test-Path -LiteralPath $sicherung)) { Copy-Item -LiteralPath $Datei -Destination $sicherung }
    [System.IO.File]::WriteAllText($Datei, ($zeilen -join "`r`n"), $inhalt.Kodierung)
    return $true
}

function Repair-Pbk([string]$Datei) {
    # Profile mit Fallback (alles ausser 1/3/5/7 = genau ein Protokoll) auf das feste Protokoll stellen.
    # Gibt die geaenderten Profile zurueck.
    $ziel = if ($E.Protokoll -eq 'IKEv2') { 7 } else { 5 }
    $betroffen = @(Get-PbkEintraege $Datei | Where-Object { $_.Strategie -notin 1, 3, 5, 7 })
    if (-not $betroffen) { return }
    try {
        if (Set-PbkStrategie $Datei @($betroffen | ForEach-Object { $_.Name }) $ziel) {
            foreach ($b in $betroffen) { Write-Log "VPN-Profil '$($b.Name)': VPNStrategy $($b.Strategie) -> $ziel" }
            $betroffen
        }
    }
    catch { Write-Log "FEHLER beim Aendern von ${Datei}: $($_.Exception.Message)" }
}

function Connect-Vpn($VpnProfile) {
    # Haengt eine Verbindung noch mit dem alten Protokoll, mit dem neuen neu aufbauen
    foreach ($profil in $VpnProfile) {
        $verbindung = Get-VpnConnection -Name $profil.Name -ErrorAction SilentlyContinue
        if (-not $verbindung -or $verbindung.ConnectionStatus -eq 'Connected') { continue }
        $null = cmd.exe /c "rasdial `"$($profil.Name)`" /disconnect 2>&1"
        Start-Sleep -Seconds 2
        $null = cmd.exe /c "rasdial `"$($profil.Name)`" /phonebook:`"$($profil.Datei)`" 2>&1"
        Write-Log "VPN '$($profil.Name)' neu verbunden (rasdial Exitcode $LASTEXITCODE)."
    }
}

# ---------------------------------------------------------------- Firmennetz

function Test-Port([string]$Ziel, [int]$Port, [int]$TimeoutMs = 2000) {
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

function Get-ServerAusPfad([string]$Pfad) { ($Pfad.TrimStart('\') -split '\\')[0] }

function Test-UncPfad([string]$Pfad) {
    # Erst SMB-Port pruefen - Test-Path allein haengt ohne VPN bis zu einer Minute
    (Test-Port (Get-ServerAusPfad $Pfad) 445) -and (Test-Path -LiteralPath $Pfad)
}

function Test-DomainErreichbar {
    try { $adressen = [System.Net.Dns]::GetHostAddresses($E.Domain) } catch { return $false }
    foreach ($ip in $adressen) { if (Test-Port $ip.IPAddressToString 389 1500) { return $true } }
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

# ---------------------------------------------------------------- Laufwerke (Reserve)

function Get-LaufwerkListe {
    # Verbundene/getrennte Laufwerke plus gemerkte (HKCU\Network), die Windows nicht wiederhergestellt hat
    $liste = [ordered]@{}
    foreach ($z in @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath })) {
        $liste[$z.LocalPath.ToUpper()] = [pscustomobject]@{ Pfad = $z.RemotePath.TrimEnd('\'); Status = [string]$z.Status }
    }
    foreach ($eintrag in @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $lw = "$($eintrag.PSChildName.ToUpper()):"
        $pfad = (Get-ItemProperty -LiteralPath $eintrag.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($pfad -and -not $liste.Contains($lw)) { $liste[$lw] = [pscustomobject]@{ Pfad = $pfad.TrimEnd('\'); Status = 'gemerkt' } }
    }
    $liste
}

function Repair-Laufwerke {
    $liste = Get-LaufwerkListe
    foreach ($lw in @($liste.Keys)) {
        $pfad = $liste[$lw].Pfad
        $status = $liste[$lw].Status
        if ($status -eq 'OK' -and (Test-Port (Get-ServerAusPfad $pfad) 445) -and (Test-Path -LiteralPath "$lw\")) { continue }
        if (-not (Test-UncPfad $pfad)) { Write-Log "$lw -> $pfad nicht erreichbar, bleibt unveraendert."; continue }
        $null = cmd.exe /c "net use $lw /delete /y 2>&1"
        $ausgabe = cmd.exe /c "net use $lw `"$pfad`" /persistent:yes 2>&1"
        if ($LASTEXITCODE -eq 0) { Write-Log "$lw -> $pfad neu verbunden (war: $status)." }
        else { Write-Log "$lw -> $pfad FEHLER: $((($ausgabe | Out-String) -replace '\s+', ' ').Trim())" }
    }
}

function Invoke-IntuneMapping {
    # Skript der Intune-Zuordnungsaufgabe als dieser Benutzer ausfuehren - jetzt ist das VPN da
    $aufgaben = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.TaskName
            @($E.MappingAufgaben | Where-Object { $name -like $_ }).Count -gt 0
        })
    foreach ($aufgabe in $aufgaben) {
        $skript = $null
        foreach ($aktion in $aufgabe.Actions) {
            if ("$($aktion.Arguments)" -match '([A-Za-z]:\\[^"]+?\.ps1)') { $skript = $Matches[1] }
        }
        if ($skript -and (Test-Path -LiteralPath $skript)) {
            $prozess = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$skript`"" -WindowStyle Hidden -PassThru
            if ($prozess.WaitForExit(180000)) { Write-Log "Intune-Zuordnung $($aufgabe.TaskName) ausgefuehrt." }
            else { Write-Log "Intune-Zuordnung $($aufgabe.TaskName) laeuft nach 3 Minuten noch." }
        }
        else {
            try { Start-ScheduledTask -InputObject $aufgabe -ErrorAction Stop; Write-Log "Aufgabe $($aufgabe.TaskName) gestartet." }
            catch { Write-Log "Aufgabe $($aufgabe.TaskName) FEHLER: $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------- Ablauf

if ($NurLaden) { return }
if (-not $E) { Write-Log "Einstellungen.json fehlt in $Ordner."; exit 1 }

switch ($Modus) {
    'System' {
        $null = Repair-Pbk $PbkAlle
    }
    'Vpn' {
        $geaendert = @(Repair-Pbk $PbkBenutzer)
        if ($geaendert) { Connect-Vpn $geaendert }
    }
    'Laufwerke' {
        $geaendert = @(Repair-Pbk $PbkBenutzer)
        if ($geaendert) { Connect-Vpn $geaendert }
        if (-not (Wait-Domain $E.WartenSekunden)) { return }
        Repair-Laufwerke
        Invoke-IntuneMapping
    }
}
'@

###########################################################################################
# Einrichtung
###########################################################################################

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Info([string]$Text, [string]$Farbe = 'Gray') { Write-Host "  $Text" -ForegroundColor $Farbe }

function New-EreignisTrigger([string]$Log, [string]$Quelle, [int]$Id, [string]$Verzoegerung = 'PT5S') {
    $klasse = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $klasse -ClientOnly
    $trigger.Enabled = $true
    $trigger.Delay = $Verzoegerung
    $trigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"$Log`"><Select Path=`"$Log`">*[System[Provider[@Name='$Quelle'] and EventID=$Id]]</Select></Query></QueryList>"
    $trigger
}

function New-WorkerAktion([string]$Modus, [switch]$System) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumente = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Ordner 'VPN-Fix.ps1')`" -Modus $Modus"
    if ($System) { return New-ScheduledTaskAction -Execute $ps -Argument $argumente }
    # conhost --headless: kein aufblitzendes Fenster beim Benutzer
    New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument "--headless `"$ps`" $argumente"
}

function Remove-Aufgaben {
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'VPN-Fix*' } |
        Unregister-ScheduledTask -Confirm:$false
}

function Install-VpnFix {
    Write-Info 'Richte VPN-Dauerloesung ein ...' Cyan
    Remove-Aufgaben

    # Ordner nur fuer SYSTEM/Administratoren beschreibbar - die SYSTEM-Aufgabe fuehrt das Skript daraus aus
    New-Item -ItemType Directory -Path $Ordner -Force | Out-Null
    $null = icacls.exe $Ordner /setowner '*S-1-5-32-544' /T /C
    $null = icacls.exe $Ordner /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
    $null = icacls.exe "$Ordner\*" /reset /T /C
    New-Item -ItemType Directory -Path (Join-Path $Ordner 'Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Ordner 'VPN-Fix.ps1') -Value $WorkerCode -Encoding ASCII
    $Einstellungen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Ordner 'Einstellungen.json') -Encoding ASCII

    # Laufwerke bei der Anmeldung nicht wiederherstellen (alter Wert wird fuer "Entfernen" gemerkt)
    if ($Einstellungen.LaufwerkeNichtWiederherstellen) {
        $vorherDatei = Join-Path $Ordner 'RestoreConnection-vorher.txt'
        if (-not (Test-Path $vorherDatei)) {
            $vorher = (Get-ItemProperty $NetzwerkProvider -ErrorAction SilentlyContinue).RestoreConnection
            Set-Content -LiteralPath $vorherDatei -Value ([string]$vorher) -Encoding ASCII
        }
        Set-ItemProperty -Path $NetzwerkProvider -Name RestoreConnection -Value 0 -Type DWord
    }

    $einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $benutzer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $alle15 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
    $vpnFehler = New-EreignisTrigger 'Application' 'RasClient' 20227

    # SYSTEM: VPN-Profile "alle Benutzer"
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix System' -Force -Action (New-WorkerAktion System -System) `
        -Trigger @((New-ScheduledTaskTrigger -AtStartup), $alle15, $vpnFehler) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
        -Settings $einstellungen | Out-Null

    # Benutzer: eigenes VPN-Profil - Anmeldung (danach alle 15 Minuten) und VPN-Fehler
    $anmeldung = New-ScheduledTaskTrigger -AtLogOn
    $anmeldung.Repetition = $alle15.Repetition
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Benutzer' -Force -Action (New-WorkerAktion Vpn) `
        -Trigger @($anmeldung, $vpnFehler) -Principal $benutzer -Settings $einstellungen | Out-Null

    # Benutzer: Laufwerke als Reserve - Anmeldung und sobald das VPN verbunden ist
    if ($Einstellungen.LaufwerkeReserve) {
        $spaeter = New-ScheduledTaskTrigger -AtLogOn
        $spaeter.Delay = 'PT30S'
        Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Laufwerke' -Force -Action (New-WorkerAktion Laufwerke) `
            -Trigger @($spaeter, (New-EreignisTrigger 'Application' 'RasClient' 20225 'PT10S')) `
            -Principal $benutzer -Settings $einstellungen | Out-Null
    }

    Start-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix System' -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Benutzer' -ErrorAction SilentlyContinue

    Write-Info "Eingerichtet: $Ordner" Green
    Write-Info "Aufgaben: $($TaskPath)VPN-Fix System / Benutzer$(if ($Einstellungen.LaufwerkeReserve) { ' / Laufwerke' })" Green
    if ($Einstellungen.LaufwerkeNichtWiederherstellen) { Write-Info 'Windows stellt Netzlaufwerke bei der Anmeldung nicht mehr selbst wieder her.' Green }
    Write-Info 'Jetzt einmal ab- und wieder anmelden (oder neu starten) - danach laeuft alles automatisch.' Yellow
}

function Show-Status {
    Write-Info 'Geplante Aufgaben:' Cyan
    $aufgaben = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'VPN-Fix*' })
    if (-not $aufgaben) { Write-Info 'nicht eingerichtet' Yellow }
    foreach ($a in $aufgaben) {
        $info = $a | Get-ScheduledTaskInfo
        Write-Info ("{0}: {1}, zuletzt {2} (Ergebnis {3})" -f $a.TaskName, $a.State, $info.LastRunTime, $info.LastTaskResult)
    }

    $wert = (Get-ItemProperty $NetzwerkProvider -ErrorAction SilentlyContinue).RestoreConnection
    Write-Info "RestoreConnection: $(if ($wert -eq 0) { '0 (Laufwerke werden nicht bei der Anmeldung wiederhergestellt)' } else { 'Windows-Standard' })" Cyan

    # Funktionen des Aufgaben-Skripts laden, um die VPN-Profile auszulesen
    . ([scriptblock]::Create($WorkerCode)) -NurLaden
    $E = $Einstellungen | ConvertTo-Json | ConvertFrom-Json
    Write-Info 'VPN-Profile (VPNStrategy: 5 = nur SSTP, 7 = nur IKEv2, 0/6/8/14 = Fallback = Fehler):' Cyan
    $dateien = @($PbkAlle) + @(Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Network\Connections\Pbk\rasphone.pbk' })
    foreach ($datei in $dateien) {
        try { $vpnProfile = @(Get-PbkEintraege $datei) } catch { Write-Info "$datei nicht lesbar" Yellow; continue }
        foreach ($profil in $vpnProfile) {
            $farbe = if ($profil.Strategie -in 1, 3, 5, 7) { 'Green' } else { 'Yellow' }
            Write-Info ("{0}: VPNStrategy={1}   ({2})" -f $profil.Name, $profil.Strategie, $datei) $farbe
        }
    }
    $log = Join-Path $Ordner 'Logs\System.log'
    if (Test-Path $log) {
        Write-Info 'Letzte Eintraege System.log:' Cyan
        Get-Content $log -Tail 10 | ForEach-Object { Write-Info $_ DarkGray }
    }
    Write-Info 'Benutzer-Log: %LOCALAPPDATA%\GHG\Logs\VPN-Fix.log' DarkGray
}

function Uninstall-VpnFix {
    Remove-Aufgaben
    # RestoreConnection auf den Wert vor der Einrichtung zuruecksetzen
    $vorherDatei = Join-Path $Ordner 'RestoreConnection-vorher.txt'
    if (Test-Path $vorherDatei) {
        $vorher = (Get-Content -LiteralPath $vorherDatei -Raw).Trim()
        if ($vorher -match '^\d+$') { Set-ItemProperty -Path $NetzwerkProvider -Name RestoreConnection -Value ([int]$vorher) -Type DWord }
        else { Remove-ItemProperty -Path $NetzwerkProvider -Name RestoreConnection -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $Ordner -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info 'Aufgaben und Dateien entfernt, RestoreConnection zurueckgesetzt.' Green
    Write-Info 'Die VPN-Profile bleiben auf dem festen Protokoll (Original: rasphone.pbk.vor-VPN-Fix im Pbk-Ordner).' Yellow
}

###########################################################################################
# Start
###########################################################################################

$IstSystem = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
$PbkAlle = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

# Intune (SYSTEM): ohne Rueckfrage einrichten
if ($IstSystem) {
    try { Install-VpnFix; exit 0 }
    catch { Write-Output "Einrichtung fehlgeschlagen: $($_.Exception.Message)"; exit 1 }
}

# Ohne Adminrechte: dieselbe Datei mit Adminrechten (UAC) neu starten
if (-not (Test-Admin)) {
    $datei = $env:VPN_FIX_DATEI
    if (-not $datei) { Write-Host 'Bitte als Administrator ausfuehren.' -ForegroundColor Red; Read-Host 'Enter'; exit 1 }
    # Ein Admin-Fenster sieht keine Netzlaufwerke des Benutzers -> Datei vorher lokal kopieren
    if ($datei -like '\\*' -or (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($datei))).DriveType -eq 'Network') {
        $kopie = Join-Path $env:TEMP 'VPN-Dauerloesung.cmd'
        Copy-Item -LiteralPath $datei -Destination $kopie -Force
        $datei = $kopie
    }
    $code = "`$env:VPN_FIX_DATEI = '$($datei -replace "'", "''")'; iex ([IO.File]::ReadAllText(`$env:VPN_FIX_DATEI))"
    $kodiert = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $kodiert" -Verb RunAs -ErrorAction Stop }
    catch { Write-Host 'Adminrechte wurden nicht erteilt.' -ForegroundColor Red; Read-Host 'Enter' }
    exit
}

$Host.UI.RawUI.WindowTitle = 'GHG VPN-Dauerloesung'
while ($true) {
    Write-Host ''
    Write-Host '  ===== GHG VPN-Dauerloesung =====' -ForegroundColor Cyan
    Write-Host '  [1] Einrichten / aktualisieren (empfohlen)'
    Write-Host '  [2] Status anzeigen'
    Write-Host '  [3] Entfernen (wenn Microsoft den Fehler behoben hat)'
    Write-Host '  [Enter] Beenden'
    switch (Read-Host '  Auswahl') {
        '1' { try { Install-VpnFix } catch { Write-Info "FEHLER: $($_.Exception.Message)" Red } }
        '2' { Show-Status }
        '3' { Uninstall-VpnFix }
        ''  { exit }
    }
}

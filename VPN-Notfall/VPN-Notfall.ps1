<#
.SYNOPSIS
    VPN-Notfall: Always On VPN reparieren und Netzlaufwerke/Drucker neu verbinden.

    - Workaround fuer den Always-On-VPN-Fehler nach den Windows-11-Updates ab September 2026
      (KB5124008 / KB5124012): automatische Protokollwahl (VPNStrategy=0) in rasphone.pbk
      auf ein festes Protokoll (SSTP oder IKEv2) umstellen, VPN neu verbinden.
    - Laufwerke und Drucker mit GHG-Mapping.ps1 neu verbinden (alte/getrennte Zuordnungen
      werden entfernt).
    - Diagnose: VPN-Profile, Dienste, belegte IKEv2-Ports, Erreichbarkeit, Laufwerksstatus.

    NICHT "Als Administrator ausfuehren" - Laufwerke werden sonst fuer den Explorer unsichtbar
    verbunden. Wo Adminrechte noetig sind, fragt das Tool selbst (UAC).

.BEISPIEL
    VPN-Notfall.bat              (Doppelklick, Menue)
    VPN-Notfall.bat -Auto        (alles reparieren ohne Menue)
#>

[CmdletBinding()]
param(
    [switch]$Auto,
    # Intern: Teilschritte, die das Tool mit Adminrechten in einem zweiten Fenster startet
    [ValidateSet('PbkSetzen', 'RasManNeustart')][string]$Aktion,
    [int]$Strategie = 5,
    [string]$Namen = ''
)

###########################################################################################
# Einstellungen
###########################################################################################

# Name des VPN-Profils, leer = alle VPN-Profile
$VpnName = ''

# Dieses Protokoll wird zuerst versucht, klappt es nicht, das andere ('SSTP' oder 'IKEv2')
$StandardProtokoll = 'SSTP'

# So lange wird nach dem Neuverbinden auf das Firmennetz gewartet
$VpnWartenSekunden = 45

# Updates mit dem bekannten Always-On-VPN-Fehler
$ProblemUpdates = @('KB5124008', 'KB5124012')

###########################################################################################
# Vorbereitung
###########################################################################################

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

# Pfad des Tools (als .ps1 oder mit ps2exe als .exe gebaut)
$SelbstPfad = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$Ordner = Split-Path -Parent $SelbstPfad

# Laufwerks-/Druckereinstellungen und Funktionen aus GHG-Mapping.ps1 laden.
# Bevorzugt die per Intune installierte Version (aktuelle Konfiguration).
$MappingDatei = @(
    (Join-Path $env:ProgramData 'GHG\Mapping\GHG-Mapping.ps1'),
    (Join-Path $Ordner 'GHG-Mapping.ps1')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $MappingDatei) {
    Write-Host 'GHG-Mapping.ps1 nicht gefunden (muss im selben Ordner liegen).' -ForegroundColor Red
    Read-Host 'Enter zum Beenden'
    exit 1
}
. $MappingDatei -NurLaden

$Protokolle = [ordered]@{ SSTP = 5; IKEv2 = 7; Automatisch = 0 }
$PbkBenutzer = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$PbkAlle     = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

###########################################################################################
# Hilfsfunktionen
###########################################################################################

function Write-Titel([string]$Text) {
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Select-Option([string]$Titel, [string[]]$Optionen) {
    # Gibt den Index (ab 0) der gewaehlten Option zurueck
    Write-Host ''
    Write-Host $Titel -ForegroundColor Cyan
    for ($i = 0; $i -lt $Optionen.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $Optionen[$i])
    }
    while ($true) {
        $eingabe = Read-Host "Auswahl (1-$($Optionen.Count))"
        $n = 0
        if ([int]::TryParse($eingabe, [ref]$n) -and $n -ge 1 -and $n -le $Optionen.Count) { return $n - 1 }
        Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow
    }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-AlsAdmin([string]$Argumente) {
    # Startet dieses Tool mit Adminrechten (UAC) fuer einen Teilschritt und wartet darauf
    if ($SelbstPfad -like '*.ps1') {
        $datei = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $Argumente = "-NoProfile -ExecutionPolicy Bypass -File `"$SelbstPfad`" $Argumente"
    }
    else { $datei = $SelbstPfad }
    try {
        $prozess = Start-Process -FilePath $datei -ArgumentList $Argumente -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return ($prozess.ExitCode -eq 0)
    }
    catch {
        Write-Log "Adminrechte wurden nicht erteilt: $($_.Exception.Message)" Fehler
        return $false
    }
}

function Read-TextDatei([string]$Pfad) {
    # Liest eine Textdatei und merkt sich die Kodierung, damit sie unveraendert zurueckgeschrieben wird
    $leser = New-Object System.IO.StreamReader($Pfad, [Text.Encoding]::Default, $true)
    try {
        $text = $leser.ReadToEnd()
        [pscustomobject]@{ Text = $text; Kodierung = $leser.CurrentEncoding }
    }
    finally { $leser.Close() }
}

function Get-StrategieText([int]$Wert) {
    switch ($Wert) {
        0       { 'Automatisch (vom Fehler betroffen)' }
        5       { 'nur SSTP' }
        6       { 'SSTP zuerst, mit Fallback (betroffen)' }
        7       { 'nur IKEv2' }
        8       { 'IKEv2 zuerst, mit Fallback (betroffen)' }
        14      { 'IKEv2 zuerst, mit Fallback (betroffen)' }
        default { "VPNStrategy=$Wert" }
    }
}

function Test-StrategieBetroffen([int]$Wert) {
    # Nur Werte mit genau einem Protokoll sind nicht betroffen (1 PPTP, 3 L2TP, 5 SSTP, 7 IKEv2)
    $Wert -notin 1, 3, 5, 7
}

###########################################################################################
# VPN
###########################################################################################

function Get-VpnEintraege {
    # VPN-Profile (Type=2) aus beiden Telefonbuechern mit aktueller VPNStrategy
    foreach ($pbk in @(@{ Art = 'Benutzer'; Pfad = $PbkBenutzer }, @{ Art = 'Alle Benutzer'; Pfad = $PbkAlle })) {
        if (-not (Test-Path -LiteralPath $pbk.Pfad)) { continue }
        $eintraege = @()
        foreach ($zeile in ((Read-TextDatei $pbk.Pfad).Text -split "`r?`n")) {
            if ($zeile -match '^\[(.+)\]\s*$') {
                $eintraege += [pscustomobject]@{ Name = $Matches[1]; Art = $pbk.Art; Datei = $pbk.Pfad; Typ = 0; Strategie = 0 }
            }
            elseif ($eintraege -and $zeile -match '^Type=(\d+)') { $eintraege[-1].Typ = [int]$Matches[1] }
            elseif ($eintraege -and $zeile -match '^VPNStrategy=(\d+)') { $eintraege[-1].Strategie = [int]$Matches[1] }
        }
        $eintraege | Where-Object { $_.Typ -eq 2 -and (-not $VpnName -or $_.Name -eq $VpnName) }
    }
}

function Get-VpnStatus([string]$Name) {
    $verbindung = Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue
    if (-not $verbindung) { $verbindung = Get-VpnConnection -Name $Name -AllUserConnection -ErrorAction SilentlyContinue }
    if ($verbindung) { [string]$verbindung.ConnectionStatus } else { 'unbekannt' }
}

function Set-PbkStrategie([string]$Datei, [string[]]$ProfilNamen, [int]$Wert) {
    # Setzt VPNStrategy fuer die angegebenen Profile in rasphone.pbk (mit Sicherungskopie)
    try {
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
        if ($geaendert -eq 0) {
            Write-Log "Keine VPNStrategy-Zeile fuer $($ProfilNamen -join ', ') in $Datei gefunden." Warnung
            return $false
        }
        Copy-Item -LiteralPath $Datei -Destination ('{0}.bak_{1}' -f $Datei, (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
        [System.IO.File]::WriteAllText($Datei, ($zeilen -join "`r`n"), $inhalt.Kodierung)
        Write-Log "VPN-Protokoll fuer $($ProfilNamen -join ', '): $(Get-StrategieText $Wert)" OK
        return $true
    }
    catch {
        Write-Log "rasphone.pbk konnte nicht geaendert werden: $($_.Exception.Message)" Fehler
        return $false
    }
}

function Set-VpnProtokoll($Eintraege, [int]$Wert) {
    $alleOk = $true
    foreach ($gruppe in ($Eintraege | Group-Object Datei)) {
        $profilNamen = @($gruppe.Group | ForEach-Object { $_.Name })
        if ($gruppe.Name -eq $PbkAlle -and -not (Test-Admin)) {
            Write-Log "$($profilNamen -join ', ') gilt fuer alle Benutzer - Adminrechte noetig (UAC-Abfrage)." Warnung
            $ok = Start-AlsAdmin "-Aktion PbkSetzen -Strategie $Wert -Namen `"$($profilNamen -join '|')`""
            if ($ok) { Write-Log "VPN-Protokoll fuer $($profilNamen -join ', '): $(Get-StrategieText $Wert)" OK }
        }
        else { $ok = Set-PbkStrategie $gruppe.Name $profilNamen $Wert }
        if (-not $ok) { $alleOk = $false }
    }
    return $alleOk
}

function Connect-Vpn($Eintraege) {
    foreach ($e in $Eintraege) {
        Write-Log "VPN '$($e.Name)' trennen und neu verbinden ..."
        $null = cmd.exe /c "rasdial `"$($e.Name)`" /disconnect 2>&1"
        Start-Sleep -Seconds 2
        $ausgabe = cmd.exe /c "rasdial `"$($e.Name)`" /phonebook:`"$($e.Datei)`" 2>&1"
        if ($LASTEXITCODE -eq 0) { Write-Log "'$($e.Name)' verbunden." OK }
        else {
            Write-Log "rasdial: $((($ausgabe | Out-String) -replace '\s+', ' ').Trim())" Warnung
            Write-Log 'Always On verbindet meist von selbst neu - sonst Taskleiste > Netzwerk > VPN > Verbinden.'
        }
    }
}

function Wait-Firmennetz([int]$Sekunden) {
    Write-Log "Warte bis zu $Sekunden s auf das Firmennetz ..."
    if (Wait-Domain $Sekunden) { Write-Log 'Firmennetz erreichbar.' OK; return $true }
    Write-Log "Firmennetz nach $Sekunden s nicht erreichbar." Fehler
    return $false
}

###########################################################################################
# Diagnose
###########################################################################################

function Get-TestServer {
    $server = @(Get-Laufwerke | ForEach-Object { Get-ServerAusPfad $_.Pfad }) + (Get-ServerAusPfad $PrintServer)
    $server | Sort-Object -Unique
}

function Show-Laufwerke {
    $zuordnungen = @(Get-SmbMapping -ErrorAction SilentlyContinue)
    $konfig = @(Get-Laufwerke)
    if (-not $konfig) { Write-Log 'In GHG-Mapping.ps1 sind keine Laufwerke eingetragen ($driveMappingJson).' Warnung }

    $meine = $null
    if ($konfig -and (Test-DomainErreichbar)) {
        try { $meine = @(Select-FuerBenutzer $konfig @(Get-AdGruppen) | ForEach-Object { $_.Buchstabe }) } catch { }
    }

    foreach ($lw in $konfig) {
        $ist = $zuordnungen | Where-Object { $_.LocalPath -eq "$($lw.Buchstabe):" } | Select-Object -First 1
        if ($null -ne $meine -and $meine -notcontains $lw.Buchstabe) {
            Write-Log "$($lw.Buchstabe): $($lw.Pfad) - nicht zugeteilt (Gruppe $($lw.Gruppen -join ', '))"
            continue
        }
        $unc = Test-UncPfad $lw.Pfad
        $laufwerkOk = $ist -and $ist.Status -eq 'OK' -and $ist.RemotePath.TrimEnd('\') -eq $lw.Pfad -and $unc -and (Test-Path -LiteralPath "$($lw.Buchstabe):\")
        $status = if ($ist) { "$($ist.Status) -> $($ist.RemotePath)" } else { 'nicht verbunden' }
        $typ = if ($laufwerkOk) { 'OK' } elseif ($unc) { 'Warnung' } else { 'Fehler' }
        Write-Log ("{0}: {1} | Laufwerk: {2} | Pfad direkt erreichbar: {3}" -f $lw.Buchstabe, $lw.Pfad, $status, $(if ($unc) { 'ja' } else { 'nein' })) $typ
        if ($unc -and -not $laufwerkOk) {
            Write-Log '   -> Pfad geht, Laufwerk nicht: Zuordnung ist veraltet/getrennt - [2] oder [6] verbindet neu.' Warnung
        }
        if ((Get-ServerAusPfad $lw.Pfad) -notmatch '\.') {
            Write-Log '   -> Pfad ohne FQDN (z.B. server.ghg.local) - ueber VPN oft nicht aufloesbar.' Warnung
        }
    }
    foreach ($z in ($zuordnungen | Where-Object { @($konfig | ForEach-Object { "$($_.Buchstabe):" }) -notcontains $_.LocalPath })) {
        Write-Log "$($z.LocalPath) $($z.RemotePath) ($($z.Status)) - nicht in GHG-Mapping.ps1 eingetragen"
    }
}

function Show-Diagnose {
    Write-Titel 'System'
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Log "$env:COMPUTERNAME, Benutzer $env:USERDOMAIN\$env:USERNAME, Windows $($os.DisplayVersion) (Build $($os.CurrentBuild).$($os.UBR))"
    $beitritt = @((dsregcmd.exe /status) -match '^\s*(AzureAdJoined|DomainJoined)\s*:' | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    if ($beitritt) { Write-Log "Geraet: $($beitritt -join ', ')" }
    if (Test-Admin) { Write-Log 'Tool laeuft MIT Adminrechten - so verbundene Laufwerke sieht der Explorer nicht!' Warnung }
    $installiert = @(Get-HotFix -Id $ProblemUpdates -ErrorAction SilentlyContinue)
    if ($installiert) { Write-Log "Update mit VPN-Fehler installiert: $(($installiert | ForEach-Object { $_.HotFixID }) -join ', ')" Warnung }
    else { Write-Log "$($ProblemUpdates -join ' / ') nicht gefunden (spaetere kumulative Updates koennen den Fehler trotzdem enthalten)." }

    Write-Titel 'VPN-Profile'
    $vpn = @(Get-VpnEintraege)
    if (-not $vpn) { Write-Log 'Keine VPN-Profile gefunden.' Warnung }
    foreach ($e in $vpn) {
        $typ = if (Test-StrategieBetroffen $e.Strategie) { 'Warnung' } else { 'OK' }
        Write-Log ("{0} [{1}]: {2}, Status: {3}" -f $e.Name, $e.Art, (Get-StrategieText $e.Strategie), (Get-VpnStatus $e.Name)) $typ
    }
    foreach ($dienst in @(Get-Service -Name RasMan, IKEEXT, SstpSvc -ErrorAction SilentlyContinue)) {
        $typ = if ($dienst.Name -eq 'RasMan' -and $dienst.Status -ne 'Running') { 'Warnung' } else { 'Info' }
        Write-Log "Dienst $($dienst.Name): $($dienst.Status)" $typ
    }
    foreach ($ep in @(Get-NetUDPEndpoint -LocalPort 500, 4500 -ErrorAction SilentlyContinue)) {
        $prozess = Get-Process -Id $ep.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($prozess) { $prozess.ProcessName } else { "PID $($ep.OwningProcess)" }
        if ($name -ne 'svchost') {
            Write-Log "UDP-Port $($ep.LocalPort) ist durch '$name' belegt - blockiert IKEv2 ('Port wird bereits verwendet')." Warnung
        }
    }

    Write-Titel 'Firmennetz'
    if (Test-DomainErreichbar) { Write-Log "Domain Controller ($Domain) erreichbar." OK }
    else { Write-Log "Domain Controller ($Domain) NICHT erreichbar - VPN nicht verbunden?" Fehler }
    foreach ($server in Get-TestServer) {
        if (Test-Port $server 445) { Write-Log "$server (SMB) erreichbar." OK } else { Write-Log "$server (SMB) NICHT erreichbar." Fehler }
    }

    Write-Titel 'Laufwerke'
    Show-Laufwerke

    Write-Titel 'Hinweise'
    $verknuepft = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLinkedConnections
    Write-Log "EnableLinkedConnections: $(if ($verknuepft -eq 1) { 'an' } else { 'aus - Laufwerke aus Admin-Fenstern sind im Explorer unsichtbar' })"
    $gespeichert = @(cmdkey.exe /list)
    foreach ($server in Get-TestServer) {
        if ($gespeichert -match [regex]::Escape($server.Split('.')[0])) {
            Write-Log "Gespeicherte Anmeldedaten fuer $server in der Anmeldeinformationsverwaltung - koennen veraltet sein (Fehler 1219 / Zugriff verweigert)." Warnung
        }
    }
    $offline = Get-CimInstance -ClassName Win32_OfflineFilesCache -ErrorAction SilentlyContinue
    if ($offline -and $offline.Enabled) { Write-Log 'Offlinedateien sind aktiv - Laufwerke koennen nach VPN-Abbruch "offline" haengen bleiben.' Warnung }

    Write-Titel "Letzte Eintraege $LogDatei"
    if (Test-Path $LogDatei) { Get-Content $LogDatei -Tail 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
}

###########################################################################################
# Reparaturen
###########################################################################################

function Invoke-AllesReparieren {
    Write-Titel 'Schritt 1/4: VPN-Profile pruefen'
    $vpn = @(Get-VpnEintraege)
    if (-not $vpn) { Write-Log 'Keine VPN-Profile gefunden.' Warnung }
    foreach ($e in $vpn) { Write-Log ("{0} [{1}]: {2}, Status: {3}" -f $e.Name, $e.Art, (Get-StrategieText $e.Strategie), (Get-VpnStatus $e.Name)) }
    $betroffen = @($vpn | Where-Object { Test-StrategieBetroffen $_.Strategie })
    $protokoll = $StandardProtokoll
    if ($betroffen) {
        Write-Log "Automatische Protokollwahl gefunden -> wird auf $protokoll umgestellt (Workaround fuer den Windows-Update-Fehler)." Warnung
        $null = Set-VpnProtokoll $betroffen $Protokolle[$protokoll]
    }
    else { Write-Log 'Kein Profil mit automatischer Protokollwahl.' OK }

    Write-Titel 'Schritt 2/4: VPN-Verbindung'
    if ($betroffen -or -not (Test-DomainErreichbar)) {
        $verbinden = @($vpn | Where-Object { $betroffen.Name -contains $_.Name -or (Get-VpnStatus $_.Name) -ne 'Connected' })
        if (-not $verbinden) { $verbinden = $vpn }
        Connect-Vpn $verbinden
        $ok = Wait-Firmennetz $VpnWartenSekunden
        if (-not $ok -and $betroffen) {
            $protokoll = if ($protokoll -eq 'SSTP') { 'IKEv2' } else { 'SSTP' }
            Write-Log "Keine Verbindung - versuche $protokoll ..." Warnung
            $null = Set-VpnProtokoll $betroffen $Protokolle[$protokoll]
            Connect-Vpn $betroffen
            $ok = Wait-Firmennetz $VpnWartenSekunden
        }
        if (-not $ok) {
            Write-Log 'Firmennetz weiterhin nicht erreichbar. Naechste Schritte:' Fehler
            Write-Log '  [5] VPN-Dienst neu starten  ->  PC neu starten  ->  [7] Update deinstallieren' Fehler
            return
        }
    }
    else { Write-Log 'VPN verbunden, Firmennetz erreichbar.' OK }

    Write-Titel 'Schritt 3/4: DNS-Cache leeren'
    $null = ipconfig.exe /flushdns
    Write-Log 'DNS-Cache geleert.' OK

    Write-Titel 'Schritt 4/4: Laufwerke und Drucker verbinden'
    $null = Invoke-Mapping -WartenSekunden 15
    Write-Titel 'Ergebnis'
    Show-Laufwerke
}

function Invoke-ProtokollWahl {
    $vpn = @(Get-VpnEintraege)
    if (-not $vpn) { Write-Log 'Keine VPN-Profile gefunden.' Warnung; return }
    $optionen = @($vpn | ForEach-Object { '{0} [{1}] - {2}' -f $_.Name, $_.Art, (Get-StrategieText $_.Strategie) }) + 'Alle'
    $wahl = Select-Option 'Welches VPN-Profil?' $optionen
    $ziel = if ($wahl -eq $vpn.Count) { $vpn } else { @($vpn[$wahl]) }
    $namen = @($Protokolle.Keys)
    $texte = @('SSTP (nur SSTP)', 'IKEv2 (nur IKEv2, Pflicht fuer Device Tunnel)', 'Automatisch (Originalzustand, wenn Microsoft den Fehler behoben hat)')
    $protokoll = $namen[(Select-Option 'Welches Protokoll?' $texte)]
    if (Set-VpnProtokoll $ziel $Protokolle[$protokoll]) {
        Connect-Vpn $ziel
        $null = Wait-Firmennetz $VpnWartenSekunden
    }
}

function Restart-RasMan {
    Write-Log 'VPN-Dienst (RasMan) wird neu gestartet - alle VPN-Verbindungen werden kurz getrennt.' Warnung
    if (Test-Admin) {
        try { Restart-Service -Name RasMan -Force -ErrorAction Stop; Write-Log 'RasMan neu gestartet.' OK }
        catch { Write-Log "RasMan: $($_.Exception.Message)" Fehler; return }
    }
    elseif (-not (Start-AlsAdmin '-Aktion RasManNeustart')) { return }
    else { Write-Log 'RasMan neu gestartet.' OK }
    $null = Wait-Firmennetz $VpnWartenSekunden
}

function Invoke-HarteReparatur {
    Write-Log 'ALLE Netzlaufwerke und Netzwerkverbindungen dieses Benutzers werden getrennt (auch selbst verbundene).' Warnung
    if ((Read-Host 'Fortfahren? (j/n)') -ne 'j') { return }
    $null = cmd.exe /c 'net use * /delete /y 2>&1'
    $null = klist.exe purge
    $null = ipconfig.exe /flushdns
    Write-Log 'Laufwerke getrennt, Kerberos-Tickets und DNS-Cache geleert.' OK
    $null = Invoke-Mapping -WartenSekunden 30
    Write-Titel 'Ergebnis'
    Show-Laufwerke
}

function Open-UpdateVerlauf {
    Write-Log "Notloesung: Unter 'Updates deinstallieren' das Update $($ProblemUpdates -join ' bzw. ') entfernen," Warnung
    Write-Log 'PC neu starten und Updates pausieren, bis Microsoft den Fehler behebt (Adminrechte noetig).' Warnung
    Start-Process 'ms-settings:windowsupdate-history'
}

###########################################################################################
# Start
###########################################################################################

# Teilschritte im Admin-Fenster (von Start-AlsAdmin aufgerufen)
if ($Aktion) {
    $ok = $true
    try {
        switch ($Aktion) {
            'PbkSetzen'      { $ok = Set-PbkStrategie $PbkAlle ($Namen -split '\|') $Strategie }
            'RasManNeustart' { Restart-Service -Name RasMan -Force -ErrorAction Stop; Write-Log 'RasMan neu gestartet.' OK }
        }
    }
    catch { Write-Log $_.Exception.Message Fehler; $ok = $false }
    if (-not $ok) { Read-Host 'Fehler - Enter zum Schliessen' }
    exit ([int](-not $ok))
}

$protokollOrdner = Split-Path $LogDatei
try {
    New-Item -ItemType Directory -Path $protokollOrdner -Force | Out-Null
    Get-ChildItem $protokollOrdner -Filter 'VPN-Notfall_*.txt' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
    $null = Start-Transcript -Path (Join-Path $protokollOrdner ('VPN-Notfall_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
}
catch { }

Write-Host ''
Write-Host '  ===== GHG VPN-Notfall =====' -ForegroundColor Cyan
Write-Host "  Konfiguration: $MappingDatei" -ForegroundColor DarkGray

if (Test-Admin) {
    Write-Host ''
    Write-Host '  Das Tool laeuft als Administrator. Laufwerke, die jetzt verbunden werden,' -ForegroundColor Yellow
    Write-Host '  sind im Explorer NICHT sichtbar. Bitte normal per Doppelklick starten.' -ForegroundColor Yellow
    if ((Read-Host '  Trotzdem fortfahren? (j/n)') -ne 'j') { exit }
}

if ($Auto) {
    Invoke-AllesReparieren
    Read-Host "`nFertig - Enter zum Schliessen"
}
else {
    $menue = @(
        'Alles reparieren (empfohlen): VPN-Protokoll, VPN neu verbinden, Laufwerke + Drucker',
        'Nur Laufwerke und Drucker neu verbinden',
        'Diagnose anzeigen',
        'VPN-Protokoll manuell waehlen (SSTP / IKEv2 / Automatisch)',
        'VPN-Dienst (RasMan) neu starten  [Admin]  - bei "Port wird bereits verwendet"',
        'Harte Reparatur Laufwerke: alles trennen, Kerberos-Tickets erneuern, neu verbinden',
        'Windows-Updateverlauf oeffnen (fehlerhaftes Update deinstallieren)  [Admin]',
        'Log-Ordner oeffnen',
        'Beenden'
    )
    while ($true) {
        switch (Select-Option 'Was soll gemacht werden?' $menue) {
            0 { Invoke-AllesReparieren }
            1 { $null = ipconfig.exe /flushdns; $null = Invoke-Mapping -WartenSekunden 30; Write-Titel 'Ergebnis'; Show-Laufwerke }
            2 { Show-Diagnose }
            3 { Invoke-ProtokollWahl }
            4 { Restart-RasMan }
            5 { Invoke-HarteReparatur }
            6 { Open-UpdateVerlauf }
            7 { Start-Process explorer.exe $protokollOrdner }
            8 { try { Stop-Transcript | Out-Null } catch { }; exit }
        }
    }
}

try { Stop-Transcript | Out-Null } catch { }

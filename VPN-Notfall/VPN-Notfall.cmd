<# : Batch-Teil - startet den PowerShell-Teil dieser Datei
@echo off
set "VPN_NOTFALL_DATEI=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:VPN_NOTFALL_DATEI))"
exit /b
#>

###########################################################################################
# GHG VPN-Notfall - eine Datei, Doppelklick genuegt (NICHT "Als Administrator ausfuehren")
#
#  1. Always On VPN reparieren: Profile mit automatischer Protokollwahl (Fehler nach den
#     Windows-11-Updates ab September 2026, KB5124008 / KB5124012) auf SSTP bzw. IKEv2
#     umstellen und neu verbinden
#  2. Getrennte / "nicht verfuegbare" Netzlaufwerke trennen und neu verbinden
#  3. Intune-Laufwerkszuordnung (geplante Aufgabe *DriveMapping*) erneut ausfuehren
#  4. Drucker aus den AD-Druckergruppen verbinden
#
# Protokoll: %LOCALAPPDATA%\GHG\Logs\VPN-Notfall_<Datum>.txt
###########################################################################################

###########################################################################################
# Einstellungen
###########################################################################################

# Name des VPN-Profils, leer = alle VPN-Profile
$VpnName = ''

# Dieses Protokoll wird zuerst versucht, klappt es nicht, das andere ('SSTP' oder 'IKEv2')
$StandardProtokoll = 'SSTP'

# So lange wird nach dem Neuverbinden auf das Firmennetz gewartet
$VpnWartenSekunden = 45

# AD-Domain (zum Pruefen, ob das Firmennetz erreichbar ist, und fuer die Druckergruppen)
$Domain = 'ghg.local'

# Geplante Aufgaben der Intune-Zuordnung, die erneut ausgefuehrt werden
$MappingAufgaben = @('*DriveMapping*', '*PrinterMapping*')

# Laufwerke, die immer verbunden werden sollen (bereits verbundene werden ohnehin repariert), z.B.
#   @{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }
$ZusatzLaufwerke = @()

# Drucker: Gruppen, deren Name mit einem dieser Praefixe beginnt, sind Druckergruppen.
# Freigabename = Beschreibung der Gruppe im AD, Gruppenname endet auf "default" = Standarddrucker.
$PrintServer = '\\scghgpsv01.ghg.local'
$PrinterGroupPrefixes = @(
    'GHG_BR_', 'CP_A_', 'CP_B_', 'CP_C_', 'CP_D_', 'CP_E_', 'GHG_GE_', 'GHG_MA_', 'GHG_RO_', 'GHGP',
    'GHG_TE_', 'GHG_RI_', 'GHG-GE-PR', 'GHG-CP-PR', 'GHG-HP-PR', 'GHG-SO-PR', 'GHG-TE-PR',
    'GHG-RI-PR', 'GHG-BR-PR', 'GHG-RO-PR', 'GHG-MA-PR'
)

# Updates mit dem bekannten Always-On-VPN-Fehler
$ProblemUpdates = @('KB5124008', 'KB5124012')

###########################################################################################
# Allgemeine Hilfsfunktionen
###########################################################################################

$Protokolle  = [ordered]@{ SSTP = 5; IKEv2 = 7; Automatisch = 0 }
$PbkBenutzer = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$PbkAlle     = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

function Write-Log {
    param([string]$Text, [ValidateSet('Info', 'OK', 'Warnung', 'Fehler')][string]$Typ = 'Info')
    $farbe = @{ Info = 'Gray'; OK = 'Green'; Warnung = 'Yellow'; Fehler = 'Red' }[$Typ]
    Write-Host "  $Text" -ForegroundColor $farbe
}

function Write-Titel([string]$Text) {
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-AlsAdmin([string]$Code) {
    # Fuehrt PowerShell-Code in einem Fenster mit Adminrechten aus (UAC) und wartet darauf
    $kodiert = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    try {
        $prozess = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $kodiert" `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return ($prozess.ExitCode -eq 0)
    }
    catch {
        Write-Log 'Adminrechte wurden nicht erteilt.' Fehler
        return $false
    }
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

function Wait-Firmennetz([int]$Sekunden) {
    Write-Log "Warte bis zu $Sekunden s auf das Firmennetz ..."
    $ende = (Get-Date).AddSeconds($Sekunden)
    while ($true) {
        if (Test-DomainErreichbar) { Write-Log 'Firmennetz erreichbar.' OK; return $true }
        if ((Get-Date) -ge $ende) { Write-Log "Firmennetz nach $Sekunden s nicht erreichbar." Fehler; return $false }
        Start-Sleep -Seconds 5
    }
}

###########################################################################################
# VPN
###########################################################################################

function Read-TextDatei {
    # Liest eine Textdatei und merkt sich die Kodierung, damit sie unveraendert zurueckgeschrieben wird
    param([string]$Pfad)
    $leser = New-Object System.IO.StreamReader($Pfad, [Text.Encoding]::Default, $true)
    try {
        $text = $leser.ReadToEnd()
        [pscustomobject]@{ Text = $text; Kodierung = $leser.CurrentEncoding }
    }
    finally { $leser.Close() }
}

function Set-PbkStrategie {
    # Setzt VPNStrategy fuer die angegebenen Profile in rasphone.pbk (mit Sicherungskopie).
    # Laeuft auch allein im Admin-Fenster, darf deshalb nur Read-TextDatei benutzen.
    param([string]$Datei, [string[]]$ProfilNamen, [int]$Wert)
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
    Copy-Item -LiteralPath $Datei -Destination ('{0}.bak_{1}' -f $Datei, (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
    [System.IO.File]::WriteAllText($Datei, ($zeilen -join "`r`n"), $inhalt.Kodierung)
    return $true
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

function Set-VpnProtokoll($Eintraege, [int]$Wert) {
    foreach ($gruppe in ($Eintraege | Group-Object Datei)) {
        $profilNamen = @($gruppe.Group | ForEach-Object { $_.Name })
        $liste = "$($profilNamen -join ', ')"
        if ($gruppe.Name -eq $PbkAlle -and -not (Test-Admin)) {
            # Telefonbuch "alle Benutzer" liegt unter ProgramData -> Adminrechte noetig
            Write-Log "$liste gilt fuer alle Benutzer - Adminrechte noetig (UAC-Abfrage)." Warnung
            $namenCode = ($profilNamen | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            $ok = Invoke-AlsAdmin @"
function Read-TextDatei {${function:Read-TextDatei}}
function Set-PbkStrategie {${function:Set-PbkStrategie}}
try { if (Set-PbkStrategie '$($gruppe.Name -replace "'", "''")' @($namenCode) $Wert) { exit 0 } else { exit 2 } }
catch { Write-Host `$_.Exception.Message -ForegroundColor Red; Read-Host 'Fehler - Enter zum Schliessen'; exit 1 }
"@
        }
        else {
            try { $ok = Set-PbkStrategie $gruppe.Name $profilNamen $Wert }
            catch { Write-Log "rasphone.pbk konnte nicht geaendert werden: $($_.Exception.Message)" Fehler; $ok = $false }
        }
        if ($ok) { Write-Log "VPN-Protokoll fuer ${liste}: $(Get-StrategieText $Wert)" OK }
        else { Write-Log "VPN-Protokoll fuer $liste konnte nicht umgestellt werden." Fehler }
    }
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

function Show-VpnHinweise {
    $installiert = @(Get-HotFix -Id $ProblemUpdates -ErrorAction SilentlyContinue)
    if ($installiert) { Write-Log "Update mit dem VPN-Fehler installiert: $(($installiert | ForEach-Object { $_.HotFixID }) -join ', ')" Warnung }
    foreach ($ep in @(Get-NetUDPEndpoint -LocalPort 500, 4500 -ErrorAction SilentlyContinue)) {
        $prozess = Get-Process -Id $ep.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($prozess) { $prozess.ProcessName } else { "PID $($ep.OwningProcess)" }
        if ($name -ne 'svchost') {
            Write-Log "UDP-Port $($ep.LocalPort) ist durch '$name' belegt - blockiert IKEv2 ('Port wird bereits verwendet')." Warnung
        }
    }
}

function Repair-Vpn {
    $vpn = @(Get-VpnEintraege)
    if (-not $vpn) { Write-Log 'Keine VPN-Profile gefunden.' Warnung }
    foreach ($e in $vpn) {
        Write-Log ("{0} [{1}]: {2}, Status: {3}" -f $e.Name, $e.Art, (Get-StrategieText $e.Strategie), (Get-VpnStatus $e.Name))
    }

    $betroffen = @($vpn | Where-Object { Test-StrategieBetroffen $_.Strategie })
    $protokoll = $StandardProtokoll
    if ($betroffen) {
        Write-Log "Automatische Protokollwahl gefunden -> wird auf $protokoll umgestellt (Workaround fuer den Windows-Update-Fehler)." Warnung
        Set-VpnProtokoll $betroffen $Protokolle[$protokoll]
    }
    elseif (Test-DomainErreichbar) {
        Write-Log 'VPN verbunden, Firmennetz erreichbar.' OK
        return $true
    }

    $verbinden = @($vpn | Where-Object { $betroffen.Name -contains $_.Name -or (Get-VpnStatus $_.Name) -ne 'Connected' })
    if (-not $verbinden) { $verbinden = $vpn }
    Connect-Vpn $verbinden
    $ok = Wait-Firmennetz $VpnWartenSekunden

    if (-not $ok -and $betroffen) {
        $protokoll = if ($protokoll -eq 'SSTP') { 'IKEv2' } else { 'SSTP' }
        Write-Log "Keine Verbindung - versuche $protokoll ..." Warnung
        Set-VpnProtokoll $betroffen $Protokolle[$protokoll]
        Connect-Vpn $betroffen
        $ok = Wait-Firmennetz $VpnWartenSekunden
    }
    if (-not $ok) { Show-VpnHinweise }
    return $ok
}

###########################################################################################
# Laufwerke
###########################################################################################

function Connect-Laufwerk([string]$Buchstabe, [string]$Pfad) {
    $lw = "$($Buchstabe.TrimEnd(':').ToUpper()):"
    $Pfad = $Pfad.TrimEnd('\')

    if (-not (Test-UncPfad $Pfad)) {
        Write-Log "$lw -> $Pfad ist nicht erreichbar (VPN, Server oder Berechtigung) - bleibt unveraendert." Fehler
        return
    }
    $ist = Get-SmbMapping -LocalPath $lw -ErrorAction SilentlyContinue
    if ($ist -and $ist.RemotePath.TrimEnd('\') -eq $Pfad -and $ist.Status -eq 'OK' -and (Test-Path -LiteralPath "$lw\")) {
        Write-Log "$lw -> $Pfad ist in Ordnung." OK
        return
    }

    # Getrennte oder "nicht verfuegbare" Zuordnung entfernen und neu verbinden
    $null = cmd.exe /c "net use $lw /delete /y 2>&1"
    $ausgabe = cmd.exe /c "net use $lw `"$Pfad`" /persistent:yes 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Log "$lw -> $Pfad neu verbunden." OK; return }

    $text = (($ausgabe | Out-String) -replace '\s+', ' ').Trim()
    if ($text -match '\b1219\b') { $text += ' -> Verbindung mit anderen Anmeldedaten vorhanden: unten [1] Harte Reparatur.' }
    Write-Log "$lw -> $Pfad FEHLER: $text" Fehler
}

function Get-LaufwerkListe {
    # Bereits verbundene (auch getrennte) Laufwerke plus $ZusatzLaufwerke: Buchstabe -> Pfad
    $liste = [ordered]@{}
    foreach ($z in @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath })) {
        $liste[$z.LocalPath.TrimEnd(':').ToUpper()] = $z.RemotePath
    }
    foreach ($z in $ZusatzLaufwerke) { $liste[$z.Buchstabe.TrimEnd(':').ToUpper()] = $z.Pfad }
    $liste
}

function Repair-Laufwerke($Liste) {
    if (-not $Liste -or $Liste.Count -eq 0) { Write-Log 'Keine Netzlaufwerke vorhanden.'; return }
    foreach ($buchstabe in @($Liste.Keys)) { Connect-Laufwerk $buchstabe $Liste[$buchstabe] }
}

function Invoke-IntuneMapping {
    # Die geplanten Aufgaben der Intune-Zuordnung suchen und ihr Skript als dieser Benutzer ausfuehren
    $aufgaben = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.TaskName
            @($MappingAufgaben | Where-Object { $name -like $_ }).Count -gt 0
        })
    if (-not $aufgaben) { Write-Log 'Keine Intune-Mapping-Aufgabe auf diesem Geraet gefunden.' Warnung; return }

    foreach ($aufgabe in $aufgaben) {
        $skript = $null
        foreach ($aktion in $aufgabe.Actions) {
            if ("$($aktion.Arguments)" -match '([A-Za-z]:\\[^"]+?\.ps1)') { $skript = $Matches[1] }
        }
        if ($skript -and (Test-Path -LiteralPath $skript)) {
            Write-Log "$($aufgabe.TaskName): fuehre $skript aus ..."
            $prozess = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$skript`"" `
                -WindowStyle Hidden -PassThru
            if ($prozess.WaitForExit(180000)) { Write-Log "$($aufgabe.TaskName) beendet." OK }
            else { Write-Log "$($aufgabe.TaskName) laeuft nach 3 Minuten noch - weiter." Warnung }
        }
        else {
            try {
                Start-ScheduledTask -InputObject $aufgabe -ErrorAction Stop
                Write-Log "Aufgabe $($aufgabe.TaskName) gestartet." OK
                Start-Sleep -Seconds 15
            }
            catch { Write-Log "Aufgabe $($aufgabe.TaskName) konnte nicht gestartet werden: $($_.Exception.Message)" Fehler }
        }
    }
}

###########################################################################################
# Drucker
###########################################################################################

function ConvertTo-LdapWert([string]$Wert) {
    # Sonderzeichen fuer LDAP-Filter escapen (z.B. "CN=Muster\, Hans")
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

function Connect-Drucker {
    try { $gruppen = @(Get-AdGruppen) }
    catch { Write-Log "AD-Gruppen konnten nicht gelesen werden: $($_.Exception.Message)" Fehler; return }

    $druckerGruppen = @($gruppen | Where-Object {
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
        if ($vorhanden -contains $drucker) { Write-Log "Drucker $drucker ist vorhanden." OK }
        else {
            try { Add-Printer -ConnectionName $drucker -ErrorAction Stop; Write-Log "Drucker $drucker verbunden." OK }
            catch { Write-Log "Drucker $drucker FEHLER: $($_.Exception.Message)" Fehler; continue }
        }
        if ($gruppe.Name -like '*default') {
            # Sonst setzt "Windows verwaltet Standarddrucker" den Drucker wieder zurueck
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord -ErrorAction SilentlyContinue
            $p = Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $drucker }
            if ($p) { $null = Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter; Write-Log "Standarddrucker: $drucker" OK }
        }
    }
}

###########################################################################################
# Ergebnis und Zusatzschritte
###########################################################################################

function Show-Ergebnis {
    $zuordnungen = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath })
    if (-not $zuordnungen) { Write-Log 'Keine Netzlaufwerke verbunden.' Warnung }
    foreach ($z in $zuordnungen) {
        $ok = $z.Status -eq 'OK' -and (Test-UncPfad $z.RemotePath) -and (Test-Path -LiteralPath "$($z.LocalPath)\")
        if ($ok) { Write-Log "$($z.LocalPath) -> $($z.RemotePath): OK" OK }
        else { Write-Log "$($z.LocalPath) -> $($z.RemotePath): NICHT erreichbar ($($z.Status))" Fehler }
    }
}

function Invoke-HarteReparatur {
    Write-Log 'Alle Netzlaufwerke werden getrennt, Kerberos-Tickets erneuert und alles neu verbunden.' Warnung
    $liste = Get-LaufwerkListe
    $null = cmd.exe /c 'net use * /delete /y 2>&1'
    $null = klist.exe purge
    $null = ipconfig.exe /flushdns
    Write-Log 'Getrennt, Kerberos-Tickets und DNS-Cache geleert.' OK
    Repair-Laufwerke $liste
    Invoke-IntuneMapping
}

function Restart-RasMan {
    Write-Log 'VPN-Dienst (RasMan) wird neu gestartet - VPN wird kurz getrennt.' Warnung
    if (Invoke-AlsAdmin 'Restart-Service -Name RasMan -Force -ErrorAction Stop') {
        Write-Log 'RasMan neu gestartet.' OK
        $null = Wait-Firmennetz $VpnWartenSekunden
    }
}

function Switch-VpnProtokoll {
    $vpn = @(Get-VpnEintraege)
    if (-not $vpn) { Write-Log 'Keine VPN-Profile gefunden.' Warnung; return }
    Write-Host '  [1] nur SSTP   [2] nur IKEv2   [3] Automatisch (Originalzustand, wenn Microsoft den Fehler behoben hat)'
    $wahl = Read-Host '  Protokoll'
    $protokoll = @{ '1' = 'SSTP'; '2' = 'IKEv2'; '3' = 'Automatisch' }[$wahl]
    if (-not $protokoll) { return }
    Set-VpnProtokoll $vpn $Protokolle[$protokoll]
    Connect-Vpn $vpn
    $null = Wait-Firmennetz $VpnWartenSekunden
}

###########################################################################################
# Ablauf
###########################################################################################

$logOrdner = Join-Path $env:LOCALAPPDATA 'GHG\Logs'
try {
    New-Item -ItemType Directory -Path $logOrdner -Force | Out-Null
    Get-ChildItem $logOrdner -Filter 'VPN-Notfall_*.txt' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
    $null = Start-Transcript -Path (Join-Path $logOrdner ('VPN-Notfall_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
}
catch { }

$Host.UI.RawUI.WindowTitle = 'GHG VPN-Notfall'
Write-Host ''
Write-Host '  ===== GHG VPN-Notfall =====' -ForegroundColor Cyan

if (Test-Admin) {
    Write-Host ''
    Write-Host '  Das Programm laeuft als Administrator. Laufwerke, die jetzt verbunden werden,' -ForegroundColor Yellow
    Write-Host '  sind im Explorer NICHT sichtbar. Bitte normal per Doppelklick starten.' -ForegroundColor Yellow
    if ((Read-Host '  Trotzdem fortfahren? (j/n)') -ne 'j') { exit }
}

Write-Titel 'Schritt 1/4: VPN'
$netzOk = Repair-Vpn
$null = ipconfig.exe /flushdns

Write-Titel 'Schritt 2/4: Netzlaufwerke reparieren'
Repair-Laufwerke (Get-LaufwerkListe)

if ($netzOk) {
    Write-Titel 'Schritt 3/4: Intune-Laufwerkszuordnung erneut ausfuehren'
    Invoke-IntuneMapping
    Write-Titel 'Schritt 4/4: Drucker'
    Connect-Drucker
}
else {
    Write-Titel 'Schritt 3+4: uebersprungen - kein Firmennetz'
}

Write-Titel 'Ergebnis'
if ($netzOk) { Write-Log 'Firmennetz: erreichbar' OK } else { Write-Log 'Firmennetz: NICHT erreichbar' Fehler }
Show-Ergebnis

while ($true) {
    Write-Host ''
    Write-Host 'Falls es noch nicht geht:' -ForegroundColor Cyan
    Write-Host '  [1] Harte Reparatur Laufwerke (alles trennen, Kerberos erneuern, neu verbinden)'
    Write-Host '  [2] VPN-Dienst neu starten  [Admin]  - bei "Port wird bereits verwendet"'
    Write-Host '  [3] VPN-Protokoll selbst waehlen (SSTP / IKEv2 / Automatisch)'
    Write-Host '  [4] Windows-Updateverlauf oeffnen - Update KB5124008/KB5124012 deinstallieren  [Admin]'
    Write-Host '  [5] Log-Ordner oeffnen'
    Write-Host '  [Enter] Beenden'
    switch (Read-Host 'Auswahl') {
        '1' { Invoke-HarteReparatur; Write-Titel 'Ergebnis'; Show-Ergebnis }
        '2' { Restart-RasMan }
        '3' { Switch-VpnProtokoll }
        '4' { Start-Process 'ms-settings:windowsupdate-history' }
        '5' { Start-Process explorer.exe $logOrdner }
        ''  { try { Stop-Transcript | Out-Null } catch { }; exit }
    }
}

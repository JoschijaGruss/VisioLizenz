<# : Batch-Teil - startet den PowerShell-Teil dieser Datei ohne Konsolenfenster
@echo off
set "VPN_HILFE_DATEI=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:VPN_HILFE_DATEI))"
exit /b
#>

###########################################################################################
# GHG VPN-Hilfe - eine Datei fuer alles. Doppelklick oeffnet ein Fenster:
#
#   1. VPN reparieren         VPN-Profil auf festes Protokoll (SSTP) stellen, VPN neu verbinden,
#                             danach automatisch die Laufwerke verbinden
#   2. Laufwerke verbinden    getrennte Laufwerke neu verbinden, Intune-Laufwerkszuordnung
#                             ausfuehren, Drucker verbinden
#   Dauerloesung einrichten   EINMAL pro Geraet: danach passiert das automatisch, auch nach Neustart
#
# Hintergrund: Seit KB5124008 / KB5124012 haengt Always On VPN, wenn das Profil zwischen IKEv2
# und SSTP wechseln darf (VPNStrategy 0, 6, 8, 14). Mit festem SSTP (5) haengt es nicht mehr und
# steht nach der Anmeldung frueher - dann finden auch die Intune-Laufwerke die Server.
#
# Dauerloesung = geplante Aufgaben (Aufgabenplanung, Ordner \GHG\):
#   VPN-Fix System     SYSTEM     Systemstart, alle 15 Min., VPN-Fehler -> VPN-Profile "alle Benutzer"
#   VPN-Fix Benutzer   Benutzer   Anmeldung, alle 15 Min., VPN-Fehler   -> eigenes VPN-Profil
#   VPN-Fix Laufwerke  Benutzer   Anmeldung, VPN verbunden              -> Laufwerke (Reserve)
# und RestoreConnection = 0: Windows stellt Laufwerke nicht mehr vor dem VPN wieder her (keine roten X).
#
# Laufwerke werden IMMER fuer den angemeldeten Benutzer verbunden - auch wenn das Fenster mit
# einem Admin-Konto gestartet wurde (dann ueber eine kurzzeitige Aufgabe als dieser Benutzer).
#
# Intune: in VPN-Hilfe.ps1 umbenennen, als Plattformskript verteilen (als SYSTEM, 64-Bit) -
#         richtet dann die Dauerloesung ohne Fenster ein.
# Logs:   %LOCALAPPDATA%\GHG\Logs\VPN-Fix.log, C:\ProgramData\GHG\VPN-Fix\Logs\System.log
###########################################################################################

###########################################################################################
# Einstellungen
###########################################################################################

$Einstellungen = [ordered]@{
    # Nur dieses VPN-Profil bearbeiten, leer = alle VPN-Profile
    VpnName                        = ''
    # Festes Protokoll: 'SSTP' (5, funktioniert bei euch) oder 'IKEv2' (7)
    Protokoll                      = 'SSTP'
    # Dauerloesung: Windows soll Laufwerke bei der Anmeldung nicht selbst wiederherstellen
    LaufwerkeNichtWiederherstellen = $true
    # Dauerloesung: nach dem VPN-Aufbau Laufwerke pruefen und Intune-Zuordnung ausfuehren
    LaufwerkeReserve               = $true
    # AD-Domain - daran wird erkannt, ob das Firmennetz (VPN) erreichbar ist
    Domain                         = 'ghg.local'
    # So lange wird nach Anmeldung/VPN-Aufbau auf das Firmennetz gewartet
    WartenSekunden                 = 120
    # Geplante Aufgaben der Intune-Laufwerkszuordnung, deren Skript ausgefuehrt wird
    MappingAufgaben                = @('*DriveMapping*', '*PrinterMapping*')
    # Laufwerke, die immer verbunden werden sollen (zusaetzlich zur Intune-Zuordnung), z.B.
    #   @{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }
    ZusatzLaufwerke                = @()
    # Drucker aus den AD-Druckergruppen verbinden
    DruckerVerbinden               = $true
    PrintServer                    = '\\scghgpsv01.ghg.local'
    PrinterGroupPrefixes           = @(
        'GHG_BR_', 'CP_A_', 'CP_B_', 'CP_C_', 'CP_D_', 'CP_E_', 'GHG_GE_', 'GHG_MA_', 'GHG_RO_', 'GHGP',
        'GHG_TE_', 'GHG_RI_', 'GHG-GE-PR', 'GHG-CP-PR', 'GHG-HP-PR', 'GHG-SO-PR', 'GHG-TE-PR',
        'GHG-RI-PR', 'GHG-BR-PR', 'GHG-RO-PR', 'GHG-MA-PR'
    )
}

$Ordner           = Join-Path $env:ProgramData 'GHG\VPN-Fix'
$TaskPath         = '\GHG\'
$NetzwerkProvider = 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider'

###########################################################################################
# Skript fuer die geplanten Aufgaben (wird nach C:\ProgramData\GHG\VPN-Fix\VPN-Fix.ps1
# geschrieben). Das Fenster benutzt dieselben Funktionen.
###########################################################################################

$WorkerCode = @'
<#
    GHG VPN-Fix - ausgefuehrt von den geplanten Aufgaben \GHG\VPN-Fix * und vom Fenster VPN-Hilfe.cmd
    -Modus System        VPN-Profile "alle Benutzer" (ProgramData) auf festes Protokoll
    -Modus Vpn           eigenes VPN-Profil auf festes Protokoll
    -Modus Laufwerke     eigenes VPN-Profil, auf Firmennetz warten, Laufwerke, Intune-Zuordnung, Drucker
    -Modus VpnNeu        wie Laufwerke, VPN vorher neu verbinden (Knopf 1)
    -Modus LaufwerkeNeu  wie Laufwerke, alle Laufwerke vorher trennen, Kerberos-Tickets erneuern
#>
param(
    [ValidateSet('System', 'Vpn', 'Laufwerke', 'VpnNeu', 'LaufwerkeNeu', 'Benutzer', 'Pruefung')][string]$Modus = 'Vpn',
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
    # Im Fenster zusaetzlich anzeigen
    if ($LogAusgabe) { & $LogAusgabe $Text }
}

function Wait-Kurz([int]$Millisekunden) {
    # Warten - im Fenster bleibt die Oberflaeche dabei bedienbar
    $ende = (Get-Date).AddMilliseconds($Millisekunden)
    while ((Get-Date) -lt $ende) {
        if ($UiPumpe) { & $UiPumpe }
        Start-Sleep -Milliseconds 100
    }
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
    if (-not $Datei -or -not (Test-Path -LiteralPath $Datei)) { return }
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

function Get-StrategieText([int]$Wert) {
    switch ($Wert) {
        0       { 'Automatisch (Fehler!)' }
        5       { 'nur SSTP' }
        6       { 'SSTP mit Fallback (Fehler!)' }
        7       { 'nur IKEv2' }
        8       { 'IKEv2 mit Fallback (Fehler!)' }
        14      { 'IKEv2 mit Fallback (Fehler!)' }
        default { "VPNStrategy=$Wert" }
    }
}

function Get-BetroffeneProfile([string]$Datei) {
    # Alles ausser 1/3/5/7 (= genau ein Protokoll) nutzt den fehlerhaften Fallback
    Get-PbkEintraege $Datei | Where-Object { $_.Strategie -notin 1, 3, 5, 7 }
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
    # Betroffene Profile auf das feste Protokoll stellen, gibt die geaenderten Profile zurueck
    $ziel = if ($E.Protokoll -eq 'IKEv2') { 7 } else { 5 }
    $betroffen = @(Get-BetroffeneProfile $Datei)
    if (-not $betroffen) { return }
    try {
        if (Set-PbkStrategie $Datei @($betroffen | ForEach-Object { $_.Name }) $ziel) {
            foreach ($b in $betroffen) { Write-Log "VPN-Profil '$($b.Name)': $(Get-StrategieText $b.Strategie) -> $(Get-StrategieText $ziel)" }
            $betroffen
        }
    }
    catch { Write-Log "FEHLER beim Aendern von ${Datei}: $($_.Exception.Message)" }
}

function Invoke-Rasdial([string]$Argumente) {
    $prozess = Start-Process rasdial.exe -ArgumentList $Argumente -WindowStyle Hidden -PassThru
    $null = $prozess.Handle
    $ende = (Get-Date).AddSeconds(90)
    while (-not $prozess.HasExited -and (Get-Date) -lt $ende) { Wait-Kurz 300 }
    if ($prozess.HasExited) { $prozess.ExitCode } else { -1 }
}

function Connect-BenutzerVpn([switch]$Immer) {
    # VPN neu verbinden: mit -Immer alle Profile, sonst nur nicht verbundene
    foreach ($profil in @(Get-PbkEintraege $PbkBenutzer)) {
        $verbindung = Get-VpnConnection -Name $profil.Name -ErrorAction SilentlyContinue
        if (-not $Immer -and (-not $verbindung -or $verbindung.ConnectionStatus -eq 'Connected')) { continue }
        Write-Log "VPN '$($profil.Name)' wird neu verbunden ..."
        $null = Invoke-Rasdial "`"$($profil.Name)`" /disconnect"
        Wait-Kurz 2000
        $code = Invoke-Rasdial "`"$($profil.Name)`" /phonebook:`"$($profil.Datei)`""
        if ($code -eq 0) { Write-Log "VPN '$($profil.Name)' verbunden." }
        else { Write-Log "VPN-Verbindung meldet Fehler $code - Always On verbindet meist von selbst weiter." }
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
    if (Test-DomainErreichbar) { return $true }
    Write-Log "Warte bis zu $Sekunden s auf das Firmennetz ..."
    $ende = (Get-Date).AddSeconds($Sekunden)
    while ((Get-Date) -lt $ende) {
        Wait-Kurz 5000
        if (Test-DomainErreichbar) { Write-Log 'Firmennetz erreichbar.'; return $true }
    }
    return $false
}

# ---------------------------------------------------------------- Laufwerke

function Connect-NetzLaufwerk([string]$Laufwerk, [string]$Pfad, [string]$Vorher = '') {
    $null = cmd.exe /c "net use $Laufwerk /delete /y 2>&1"
    $ausgabe = cmd.exe /c "net use $Laufwerk `"$Pfad`" /persistent:yes 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Log "$Laufwerk -> $Pfad verbunden.$Vorher"; return }
    $text = (($ausgabe | Out-String) -replace '\s+', ' ').Trim()
    if ($text -match '\b1219\b') { $text += ' (Verbindung mit anderen Anmeldedaten - "Laufwerke vorher komplett trennen" anhaken)' }
    Write-Log "$Laufwerk -> $Pfad FEHLER: $text"
}

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
    # Getrennte / "nicht verfuegbare" / gemerkte Laufwerke mit demselben Pfad neu verbinden
    $liste = Get-LaufwerkListe
    foreach ($lw in @($liste.Keys)) {
        $pfad = $liste[$lw].Pfad
        $status = $liste[$lw].Status
        if ($status -eq 'OK' -and (Test-Port (Get-ServerAusPfad $pfad) 445) -and (Test-Path -LiteralPath "$lw\")) { continue }
        if (-not (Test-UncPfad $pfad)) { Write-Log "$lw -> $pfad nicht erreichbar, bleibt unveraendert."; continue }
        Connect-NetzLaufwerk $lw $pfad " (war: $status)"
    }
    foreach ($soll in @($E.ZusatzLaufwerke)) {
        if (-not $soll) { continue }
        $lw = "$(([string]$soll.Buchstabe).Trim().TrimEnd(':').ToUpper()):"
        if ($liste.Contains($lw)) { continue }
        if (Test-UncPfad $soll.Pfad) { Connect-NetzLaufwerk $lw ([string]$soll.Pfad).TrimEnd('\') }
        else { Write-Log "$lw -> $($soll.Pfad) nicht erreichbar." }
    }
}

function Reset-Laufwerke {
    # Alles trennen, Kerberos-Tickets erneuern, dieselben Laufwerke wieder verbinden
    $liste = Get-LaufwerkListe
    $null = cmd.exe /c 'net use * /delete /y 2>&1'
    $null = klist.exe purge
    $null = ipconfig.exe /flushdns
    Write-Log 'Alle Laufwerke getrennt, Kerberos-Tickets und DNS-Cache geleert.'
    foreach ($lw in @($liste.Keys)) { Connect-NetzLaufwerk $lw $liste[$lw].Pfad }
    Repair-Laufwerke
}

function Invoke-IntuneMapping {
    # Skript der Intune-Zuordnungsaufgaben als dieser Benutzer ausfuehren - jetzt ist das VPN da
    $aufgaben = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.TaskName
            @($E.MappingAufgaben | Where-Object { $name -like $_ }).Count -gt 0
        })
    if (-not $aufgaben) { Write-Log 'Keine Intune-Laufwerkszuordnung (Aufgabe *DriveMapping*) gefunden.'; return }
    foreach ($aufgabe in $aufgaben) {
        $skript = $null
        foreach ($aktion in $aufgabe.Actions) {
            if ("$($aktion.Arguments)" -match '([A-Za-z]:\\[^"]+?\.ps1)') { $skript = $Matches[1] }
        }
        if ($skript -and (Test-Path -LiteralPath $skript)) {
            Write-Log "Intune-Zuordnung $($aufgabe.TaskName) wird ausgefuehrt ..."
            $prozess = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$skript`"" -WindowStyle Hidden -PassThru
            $ende = (Get-Date).AddMinutes(3)
            while (-not $prozess.HasExited -and (Get-Date) -lt $ende) { Wait-Kurz 500 }
            if ($prozess.HasExited) { Write-Log "Intune-Zuordnung $($aufgabe.TaskName) fertig." }
            else { Write-Log "Intune-Zuordnung $($aufgabe.TaskName) laeuft nach 3 Minuten noch." }
        }
        else {
            try { Start-ScheduledTask -InputObject $aufgabe -ErrorAction Stop; Write-Log "Aufgabe $($aufgabe.TaskName) gestartet."; Wait-Kurz 15000 }
            catch { Write-Log "Aufgabe $($aufgabe.TaskName) FEHLER: $($_.Exception.Message)" }
        }
    }
}

function Show-LaufwerkStatus {
    $zuordnungen = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath })
    if (-not $zuordnungen) { Write-Log 'Laufwerke: keine verbunden.'; return }
    foreach ($z in $zuordnungen) {
        $ok = $z.Status -eq 'OK' -and (Test-Port (Get-ServerAusPfad $z.RemotePath) 445) -and (Test-Path -LiteralPath "$($z.LocalPath)\")
        Write-Log ('Laufwerk {0} {1}: {2}' -f $z.LocalPath, $z.RemotePath, $(if ($ok) { 'OK' } else { "NICHT erreichbar ($($z.Status))" }))
    }
}

# ---------------------------------------------------------------- Drucker

function ConvertTo-LdapWert([string]$Wert) {
    $Wert.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

function Get-AdGruppen {
    # Alle Gruppen des Benutzers inkl. verschachtelter Gruppen: Name, Beschreibung
    $sucher = New-Object System.DirectoryServices.DirectorySearcher
    $sucher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$($E.Domain)")
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
    if (-not $benutzer) { throw "Benutzer $env:USERNAME nicht im AD gefunden." }
    $dn = [string]$benutzer.Properties['distinguishedname'][0]
    $sucher.Filter = "(&(objectCategory=group)(member:1.2.840.113556.1.4.1941:=$(ConvertTo-LdapWert $dn)))"
    [void]$sucher.PropertiesToLoad.Add('name')
    [void]$sucher.PropertiesToLoad.Add('description')
    foreach ($treffer in $sucher.FindAll()) {
        [pscustomobject]@{ Name = [string]$treffer.Properties['name'][0]; Beschreibung = [string]$treffer.Properties['description'][0] }
    }
}

function Connect-Drucker {
    try { $gruppen = @(Get-AdGruppen) }
    catch { Write-Log "Drucker: AD-Gruppen nicht lesbar: $($_.Exception.Message)"; return }
    $vorhanden = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($gruppe in $gruppen) {
        $name = $gruppe.Name
        if (@($E.PrinterGroupPrefixes | Where-Object { $name -like "$_*" }).Count -eq 0) { continue }
        if (-not $gruppe.Beschreibung) { Write-Log "Druckergruppe $name ohne Beschreibung im AD."; continue }
        $drucker = '{0}\{1}' -f $E.PrintServer.TrimEnd('\'), $gruppe.Beschreibung.Trim()
        if ($vorhanden -notcontains $drucker) {
            try { Add-Printer -ConnectionName $drucker -ErrorAction Stop; Write-Log "Drucker $drucker verbunden." }
            catch { Write-Log "Drucker $drucker FEHLER: $($_.Exception.Message)"; continue }
        }
        if ($name -like '*default') {
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord -ErrorAction SilentlyContinue
            $p = Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $drucker -and -not $_.Default }
            if ($p) { $null = Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter; Write-Log "Standarddrucker: $drucker" }
        }
    }
}

# ---------------------------------------------------------------- Ablauf

function Invoke-Modus([string]$Modus) {
    switch ($Modus) {
        'System' { $null = Repair-Pbk $PbkAlle }
        { $_ -in 'Vpn', 'Pruefung' } {
            # Nur neu verbinden, wenn das Profil korrigiert wurde (im Buero trennt Always On das VPN absichtlich)
            if (@(Repair-Pbk $PbkBenutzer).Count -gt 0) { Connect-BenutzerVpn }
        }
        { $_ -in 'Laufwerke', 'Benutzer', 'VpnNeu', 'LaufwerkeNeu' } {
            $geaendert = @(Repair-Pbk $PbkBenutzer)
            if ($Modus -eq 'VpnNeu') {
                if ($geaendert -or -not (Test-DomainErreichbar)) { Connect-BenutzerVpn -Immer }
                else { Write-Log 'VPN ist verbunden, Firmennetz erreichbar.' }
            }
            elseif ($geaendert) { Connect-BenutzerVpn }
            if (-not (Wait-Domain $E.WartenSekunden)) {
                Write-Log 'Firmennetz nicht erreichbar - VPN pruefen (Homeoffice: zuerst VPN).'
                return
            }
            if ($Modus -eq 'LaufwerkeNeu') { Reset-Laufwerke } else { Repair-Laufwerke }
            Invoke-IntuneMapping
            if ($E.DruckerVerbinden) { Connect-Drucker }
            Show-LaufwerkStatus
        }
    }
}

if ($NurLaden) { return }
if (-not $E) { Write-Log "Einstellungen.json fehlt in $Ordner."; exit 1 }
Invoke-Modus $Modus
'@

###########################################################################################
# Funktionen laden (Einstellungen aus dieser Datei)
###########################################################################################

. ([scriptblock]::Create($WorkerCode)) -NurLaden
$E = $Einstellungen | ConvertTo-Json -Depth 5 | ConvertFrom-Json

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function New-AufgabenEinstellungen {
    New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
}

function Write-VpnFixDateien {
    # Ordner nur fuer SYSTEM/Administratoren beschreibbar - die SYSTEM-Aufgabe fuehrt das Skript daraus aus
    New-Item -ItemType Directory -Path $Ordner -Force | Out-Null
    $null = icacls.exe $Ordner /setowner '*S-1-5-32-544' /T /C
    $null = icacls.exe $Ordner /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
    $null = icacls.exe "$Ordner\*" /reset /T /C
    New-Item -ItemType Directory -Path (Join-Path $Ordner 'Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Ordner 'VPN-Fix.ps1') -Value $WorkerCode -Encoding ASCII
    $Einstellungen | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Ordner 'Einstellungen.json') -Encoding ASCII
}

function Remove-Aufgaben {
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'VPN-Fix*' } |
        Unregister-ScheduledTask -Confirm:$false
}

function Install-VpnFix {
    Remove-Aufgaben
    Write-VpnFixDateien

    # Laufwerke bei der Anmeldung nicht wiederherstellen (alter Wert wird fuer "Entfernen" gemerkt)
    if ($Einstellungen.LaufwerkeNichtWiederherstellen) {
        $vorherDatei = Join-Path $Ordner 'RestoreConnection-vorher.txt'
        if (-not (Test-Path $vorherDatei)) {
            $vorher = (Get-ItemProperty $NetzwerkProvider -ErrorAction SilentlyContinue).RestoreConnection
            Set-Content -LiteralPath $vorherDatei -Value ([string]$vorher) -Encoding ASCII
        }
        Set-ItemProperty -Path $NetzwerkProvider -Name RestoreConnection -Value 0 -Type DWord
    }

    $einstellungen = New-AufgabenEinstellungen
    $benutzer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $alle15 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
    $vpnFehler = New-EreignisTrigger 'Application' 'RasClient' 20227

    # SYSTEM: VPN-Profile "alle Benutzer" - Systemstart, alle 15 Minuten, VPN-Fehler
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
    Write-Log "Dauerloesung eingerichtet ($Ordner, Aufgaben $($TaskPath)VPN-Fix *)."
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
    Write-Log 'Dauerloesung entfernt. VPN-Profile bleiben auf dem festen Protokoll (Original: rasphone.pbk.vor-VPN-Fix).'
}

###########################################################################################
# Start ohne Fenster: Intune (SYSTEM) und Teilschritte mit Adminrechten
###########################################################################################

$IstSystem = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
if ($IstSystem) {
    try { Install-VpnFix; exit 0 }
    catch { Write-Output "Einrichtung fehlgeschlagen: $($_.Exception.Message)"; exit 1 }
}

if ($env:VPN_HILFE_AKTION) {
    $ok = $true
    try {
        switch ($env:VPN_HILFE_AKTION) {
            'PbkAlle'    { $null = Repair-Pbk $PbkAlle }
            'Einrichten' { Install-VpnFix }
            'Entfernen'  { Uninstall-VpnFix }
        }
    }
    catch { Write-Log "FEHLER: $($_.Exception.Message)"; $ok = $false }
    exit ([int](-not $ok))
}

###########################################################################################
# Fenster
###########################################################################################

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Wer ist angemeldet, wer fuehrt das Programm aus?
$Ich = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Konsole = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if (-not $Konsole) {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer) {
        $besitzer = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if ($besitzer.User) { $Konsole = "$($besitzer.Domain)\$($besitzer.User)" }
    }
}
if (-not $Konsole) { $Konsole = $Ich }
# Direkt = Programm laeuft als angemeldeter Benutzer ohne Adminrechte -> Laufwerke im selben Fenster verbinden
$Direkt = ($Konsole -eq $Ich) -and -not (Test-Admin)

$KonsolenPbk = $PbkBenutzer
$KonsolenLog = $LogDatei
if (-not $Direkt) {
    try {
        $sid = (New-Object Security.Principal.NTAccount($Konsole)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profilPfad = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        $KonsolenPbk = Join-Path $profilPfad 'AppData\Roaming\Microsoft\Network\Connections\Pbk\rasphone.pbk'
        $KonsolenLog = Join-Path $profilPfad 'AppData\Local\GHG\Logs\VPN-Fix.log'
    }
    catch { $KonsolenPbk = $null }
}

function New-Knopf([string]$Text, [int]$X, [int]$Y, [int]$Breite, [int]$Hoehe) {
    $knopf = New-Object System.Windows.Forms.Button
    $knopf.Text = $Text
    $knopf.Location = New-Object System.Drawing.Point($X, $Y)
    $knopf.Size = New-Object System.Drawing.Size($Breite, $Hoehe)
    $form.Controls.Add($knopf)
    $knopf
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GHG VPN-Hilfe'
$form.ClientSize = New-Object System.Drawing.Size(624, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$lblTitel = New-Object System.Windows.Forms.Label
$lblTitel.Text = 'GHG VPN-Hilfe'
$lblTitel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitel.Location = New-Object System.Drawing.Point(16, 10)
$lblTitel.AutoSize = $true
$form.Controls.Add($lblTitel)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(16, 48)
$lblStatus.Size = New-Object System.Drawing.Size(592, 120)
$lblStatus.BorderStyle = 'FixedSingle'
$lblStatus.Padding = New-Object System.Windows.Forms.Padding(6)
$lblStatus.Text = 'Status wird ermittelt ...'
$form.Controls.Add($lblStatus)

$btnVpn = New-Knopf '1.  VPN reparieren' 16 180 292 54
$btnLaufwerke = New-Knopf '2.  Laufwerke verbinden' 316 180 292 54
$btnVpn.Font = $btnLaufwerke.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)

$lblHinweis = New-Object System.Windows.Forms.Label
$lblHinweis.Text = 'Homeoffice: zuerst 1 (verbindet danach auch die Laufwerke).  Im Buero oder wenn das VPN steht: nur 2.'
$lblHinweis.Location = New-Object System.Drawing.Point(16, 240)
$lblHinweis.Size = New-Object System.Drawing.Size(592, 22)
$lblHinweis.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblHinweis)

$chkNeu = New-Object System.Windows.Forms.CheckBox
$chkNeu.Text = 'Laufwerke vorher komplett trennen (wenn 2 allein nicht hilft)'
$chkNeu.Location = New-Object System.Drawing.Point(16, 264)
$chkNeu.Size = New-Object System.Drawing.Size(592, 24)
$form.Controls.Add($chkNeu)

$txtAusgabe = New-Object System.Windows.Forms.TextBox
$txtAusgabe.Multiline = $true
$txtAusgabe.ReadOnly = $true
$txtAusgabe.ScrollBars = 'Vertical'
$txtAusgabe.BackColor = [System.Drawing.Color]::White
$txtAusgabe.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtAusgabe.Location = New-Object System.Drawing.Point(16, 294)
$txtAusgabe.Size = New-Object System.Drawing.Size(592, 214)
$form.Controls.Add($txtAusgabe)

$btnStatus = New-Knopf 'Aktualisieren' 16 518 120 30
$btnDauer = New-Knopf 'Dauerloesung einrichten' 144 518 190 30
$btnEntfernen = New-Knopf 'Dauerloesung entfernen' 342 518 180 30
$btnLog = New-Knopf 'Logs' 530 518 78 30
$Knoepfe = @($btnVpn, $btnLaufwerke, $btnStatus, $btnDauer, $btnEntfernen, $btnLog)

function Add-Ausgabe([string]$Text) {
    $txtAusgabe.AppendText(('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) + "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

# Meldungen der Funktionen im Fenster anzeigen, Fenster beim Warten bedienbar halten
$LogAusgabe = { param($Text) Add-Ausgabe $Text }
$UiPumpe = { [System.Windows.Forms.Application]::DoEvents() }

function Update-Status {
    $zeilen = @("Angemeldet:  $Konsole")
    if ($Direkt) { $zeilen += 'Laufwerke werden fuer diesen Benutzer verbunden.' }
    else { $zeilen += "Programm laeuft als $Ich - Laufwerke werden trotzdem fuer $Konsole verbunden." }

    $vpnProfile = @(try { Get-PbkEintraege $KonsolenPbk } catch { })
    foreach ($profil in $vpnProfile) {
        $status = ''
        if ($Direkt) {
            $verbindung = Get-VpnConnection -Name $profil.Name -ErrorAction SilentlyContinue
            if ($verbindung) { $status = if ($verbindung.ConnectionStatus -eq 'Connected') { 'verbunden, ' } else { 'NICHT verbunden, ' } }
        }
        $zeilen += "VPN '$($profil.Name)':  $status$(Get-StrategieText $profil.Strategie)"
    }
    if (-not $vpnProfile) { $zeilen += 'VPN: kein VPN-Profil gefunden' }

    $netz = Test-DomainErreichbar
    $zeilen += "Firmennetz ($($E.Domain)):  " + $(if ($netz) { 'erreichbar' } else { 'NICHT erreichbar - zuerst 1. VPN reparieren' })
    $dauer = [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix System' -ErrorAction SilentlyContinue)
    $zeilen += 'Dauerloesung:  ' + $(if ($dauer) { 'eingerichtet' } else { 'nicht eingerichtet - unten "Dauerloesung einrichten"' })

    $lblStatus.Text = $zeilen -join "`r`n"
    $lblStatus.ForeColor = if ($netz) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
}

function Invoke-Aktion([scriptblock]$Aktion) {
    foreach ($knopf in $Knoepfe) { $knopf.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { & $Aktion }
    catch { Add-Ausgabe "FEHLER: $($_.Exception.Message)" }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($knopf in $Knoepfe) { $knopf.Enabled = $true }
        Update-Status
    }
}

function Start-AlsAdmin([string]$Aktion) {
    # Diese Datei mit Adminrechten (UAC) fuer einen Teilschritt starten und darauf warten
    $datei = $env:VPN_HILFE_DATEI
    if (-not $datei) { Add-Ausgabe 'Dafuer bitte das Programm als Administrator starten.'; return $false }
    # Ein Admin-Fenster sieht keine Netzlaufwerke des Benutzers -> Datei vorher lokal kopieren
    if ($datei -like '\\*' -or (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($datei))).DriveType -eq 'Network') {
        $kopie = Join-Path $env:TEMP 'VPN-Hilfe.cmd'
        Copy-Item -LiteralPath $datei -Destination $kopie -Force
        $datei = $kopie
    }
    $code = "`$env:VPN_HILFE_DATEI = '$($datei -replace "'", "''")'; `$env:VPN_HILFE_AKTION = '$Aktion'; iex ([IO.File]::ReadAllText(`$env:VPN_HILFE_DATEI))"
    $kodiert = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    try {
        $prozess = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $kodiert" `
            -Verb RunAs -PassThru -ErrorAction Stop
    }
    catch { Add-Ausgabe 'Adminrechte wurden nicht erteilt.'; return $false }
    $null = $prozess.Handle
    while (-not $prozess.HasExited) { Wait-Kurz 300 }
    return ($prozess.ExitCode -eq 0)
}

function Invoke-AlsBenutzer([string]$Modus) {
    # Programm laeuft als Admin: Schritt ueber eine kurzzeitige Aufgabe als angemeldeter Benutzer ausfuehren
    if (-not (Test-Admin)) {
        Add-Ausgabe "Programm laeuft als $Ich, angemeldet ist $Konsole - bitte als angemeldeter Benutzer starten."
        return
    }
    Write-VpnFixDateien
    $position = if ($KonsolenLog -and (Test-Path $KonsolenLog)) { (Get-Item $KonsolenLog).Length } else { 0 }
    $name = 'VPN-Hilfe Jetzt'
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Force -Action (New-WorkerAktion $Modus) `
        -Principal (New-ScheduledTaskPrincipal -UserId $Konsole -LogonType Interactive -RunLevel Limited) `
        -Settings (New-AufgabenEinstellungen) | Out-Null
    $start = Get-Date
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $name
    Add-Ausgabe "Laeuft als $Konsole ..."
    $ende = $start.AddMinutes(8)
    do {
        Wait-Kurz 1000
        # Neue Zeilen aus dem Log des Benutzers anzeigen
        if ($KonsolenLog -and (Test-Path $KonsolenLog)) {
            $strom = New-Object IO.FileStream($KonsolenLog, 'Open', 'Read', 'ReadWrite')
            try {
                if ($strom.Length -lt $position) { $position = 0 }
                $null = $strom.Seek($position, 'Begin')
                $leser = New-Object IO.StreamReader($strom, [Text.Encoding]::UTF8)
                while ($null -ne ($zeile = $leser.ReadLine())) { if ($zeile.Trim()) { Add-Ausgabe ($zeile -replace '^\S+ \S+ \[\w+\] ', '') } }
                $position = $strom.Length
            }
            finally { $strom.Close() }
        }
        $aufgabe = Get-ScheduledTask -TaskPath $TaskPath -TaskName $name
        $info = $aufgabe | Get-ScheduledTaskInfo
        $fertig = $aufgabe.State -ne 'Running' -and $info.LastRunTime -ge $start.AddSeconds(-5)
    } until ($fertig -or (Get-Date) -gt $ende)
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $name -Confirm:$false
}

function Start-Modus([string]$Modus) {
    if ($Direkt) { Invoke-Modus $Modus } else { Invoke-AlsBenutzer $Modus }
}

$btnVpn.Add_Click({
        Invoke-Aktion {
            Add-Ausgabe '----- VPN reparieren -----'
            # VPN-Profile fuer alle Benutzer (selten) brauchen Adminrechte
            if (@(Get-BetroffeneProfile $PbkAlle).Count -gt 0) {
                if (Test-Admin) { $null = Repair-Pbk $PbkAlle }
                elseif (Start-AlsAdmin 'PbkAlle') { Add-Ausgabe 'VPN-Profile fuer alle Benutzer korrigiert.' }
            }
            Start-Modus 'VpnNeu'
            Add-Ausgabe '----- fertig -----'
        }
    })

$btnLaufwerke.Add_Click({
        Invoke-Aktion {
            Add-Ausgabe '----- Laufwerke verbinden -----'
            if ($chkNeu.Checked) { Start-Modus 'LaufwerkeNeu' } else { Start-Modus 'Laufwerke' }
            Add-Ausgabe '----- fertig -----'
        }
    })

$btnStatus.Add_Click({ Invoke-Aktion { if ($Direkt) { Show-LaufwerkStatus } } })

$btnDauer.Add_Click({
        Invoke-Aktion {
            Add-Ausgabe '----- Dauerloesung einrichten -----'
            if (Test-Admin) { Install-VpnFix; $ok = $true } else { $ok = Start-AlsAdmin 'Einrichten' }
            if ($ok) {
                Add-Ausgabe 'Eingerichtet: VPN fest auf SSTP, geprueft bei Start, Anmeldung, alle 15 Min. und bei VPN-Fehlern.'
                Add-Ausgabe 'Windows stellt Laufwerke nicht mehr vor dem VPN wieder her; nach dem VPN-Aufbau werden sie verbunden.'
                Add-Ausgabe 'Jetzt einmal ab- und wieder anmelden - danach laeuft alles automatisch.'
            }
            else { Add-Ausgabe 'Dauerloesung konnte nicht eingerichtet werden.' }
        }
    })

$btnEntfernen.Add_Click({
        $antwort = [System.Windows.Forms.MessageBox]::Show('Dauerloesung wirklich entfernen? (erst wenn Microsoft den VPN-Fehler behoben hat)', 'GHG VPN-Hilfe', 'YesNo', 'Question')
        if ($antwort -ne 'Yes') { return }
        Invoke-Aktion {
            if (Test-Admin) { Uninstall-VpnFix; $ok = $true } else { $ok = Start-AlsAdmin 'Entfernen' }
            if ($ok) { Add-Ausgabe 'Dauerloesung entfernt, RestoreConnection zurueckgesetzt. VPN-Profil bleibt auf SSTP.' }
        }
    })

$btnLog.Add_Click({
        $logOrdner = Split-Path $KonsolenLog
        if (-not (Test-Path $logOrdner)) { New-Item -ItemType Directory -Path $logOrdner -Force | Out-Null }
        Start-Process explorer.exe $logOrdner
    })

$form.Add_Shown({ Invoke-Aktion { if ($Direkt) { Show-LaufwerkStatus } } })
[void]$form.ShowDialog()

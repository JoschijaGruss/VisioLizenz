<# : Batch-Teil - startet den PowerShell-Teil dieser Datei
@echo off
set "VPN_FIX_DATEI=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:VPN_FIX_DATEI))"
exit /b
#>

###########################################################################################
# GHG VPN-Dauerloesung - EINMAL ausfuehren, danach laeuft alles automatisch (auch nach Neustart)
#
# Richtet geplante Aufgaben ein (Ordner \GHG\ in der Aufgabenplanung):
#   VPN-Fix System    (SYSTEM)    Systemstart, alle 15 Min., VPN-Fehler: VPN-Profile fuer
#                                 "alle Benutzer" auf ein festes Protokoll stellen
#   VPN-Fix Benutzer  (Benutzer)  Anmeldung, VPN verbunden, Netzwerkwechsel: eigenes VPN-Profil
#                                 korrigieren, auf Firmennetz warten, getrennte Laufwerke neu
#                                 verbinden, Intune-Laufwerkszuordnung ausfuehren, Drucker verbinden
#   VPN-Fix Pruefung  (Benutzer)  alle 15 Min. und bei VPN-Fehler: VPN-Profil korrigieren
#                                 (Intune/Windows setzen es sonst zurueck), Laufwerke pruefen
#
# Hintergrund: Seit KB5124008 / KB5124012 haengt Always On VPN, wenn das Profil mit Fallback
# arbeitet (VPNStrategy 0, 6, 8, 14). Ein festes Protokoll (5 = nur SSTP) umgeht den Fehler.
# Windows schreibt VPNStrategy nach einem Fallback selbst um - deshalb die regelmaessige Pruefung.
#
# Start:   Doppelklick (fragt nach Adminrechten) -> [1] Einrichten
# Intune:  Datei in VPN-Dauerloesung.ps1 umbenennen, als Plattformskript verteilen
#          (als SYSTEM, 64-Bit) - richtet dann ohne Rueckfrage ein.
# Logs:    C:\ProgramData\GHG\VPN-Fix\Logs\System.log, %LOCALAPPDATA%\GHG\Logs\VPN-Fix.log
###########################################################################################

###########################################################################################
# Einstellungen
###########################################################################################

$Einstellungen = [ordered]@{
    # Nur dieses VPN-Profil bearbeiten, leer = alle VPN-Profile
    VpnName              = ''
    # Festes Protokoll: 'SSTP' (5, funktioniert bei euch) oder 'IKEv2' (7)
    Protokoll            = 'SSTP'
    # AD-Domain - daran wird erkannt, ob das Firmennetz (VPN) erreichbar ist
    Domain               = 'ghg.local'
    # So lange wartet die Aufgabe nach Anmeldung/VPN-Aufbau auf das Firmennetz
    WartenSekunden       = 120
    # Geplante Aufgaben der Intune-Zuordnung, deren Skript nach dem VPN-Aufbau ausgefuehrt wird
    MappingAufgaben      = @('*DriveMapping*', '*PrinterMapping*')
    # Drucker aus den AD-Druckergruppen verbinden
    DruckerVerbinden     = $true
    PrintServer          = '\\scghgpsv01.ghg.local'
    PrinterGroupPrefixes = @(
        'GHG_BR_', 'CP_A_', 'CP_B_', 'CP_C_', 'CP_D_', 'CP_E_', 'GHG_GE_', 'GHG_MA_', 'GHG_RO_', 'GHGP',
        'GHG_TE_', 'GHG_RI_', 'GHG-GE-PR', 'GHG-CP-PR', 'GHG-HP-PR', 'GHG-SO-PR', 'GHG-TE-PR',
        'GHG-RI-PR', 'GHG-BR-PR', 'GHG-RO-PR', 'GHG-MA-PR'
    )
}

$Ordner   = Join-Path $env:ProgramData 'GHG\VPN-Fix'
$TaskPath = '\GHG\'

###########################################################################################
# Skript, das die Aufgaben ausfuehren (wird nach C:\ProgramData\GHG\VPN-Fix\VPN-Fix.ps1 geschrieben)
###########################################################################################

$WorkerCode = @'
<#
    GHG VPN-Fix - wird von den geplanten Aufgaben \GHG\VPN-Fix * ausgefuehrt.
    Eingerichtet durch VPN-Dauerloesung.cmd, Einstellungen in Einstellungen.json.
    -Modus System    VPN-Profile "alle Benutzer" (ProgramData) korrigieren
    -Modus Benutzer  eigenes VPN-Profil, warten auf Firmennetz, Laufwerke, Intune-Zuordnung, Drucker
    -Modus Pruefung  eigenes VPN-Profil, Laufwerke pruefen (nur wenn Firmennetz erreichbar)
#>
param(
    [ValidateSet('System', 'Benutzer', 'Pruefung')][string]$Modus = 'Benutzer',
    [switch]$NurLaden
)

$Ordner      = Join-Path $env:ProgramData 'GHG\VPN-Fix'
$PbkAlle     = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$PbkBenutzer = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

try { $E = Get-Content -LiteralPath (Join-Path $Ordner 'Einstellungen.json') -Raw | ConvertFrom-Json }
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
    $eintraege | Where-Object { $_.Typ -eq 2 }
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
    $betroffen = @(Get-PbkEintraege $Datei | Where-Object {
            (-not $E.VpnName -or $_.Name -eq $E.VpnName) -and $_.Strategie -notin 1, 3, 5, 7
        })
    if (-not $betroffen) { return }
    try {
        if (Set-PbkStrategie $Datei @($betroffen | ForEach-Object { $_.Name }) $ziel) {
            foreach ($b in $betroffen) { Write-Log "VPN-Profil '$($b.Name)': VPNStrategy $($b.Strategie) -> $ziel ($Datei)" }
            $betroffen
        }
    }
    catch { Write-Log "FEHLER beim Aendern von ${Datei}: $($_.Exception.Message)" }
}

function Repair-BenutzerVpn {
    foreach ($profil in @(Repair-Pbk $PbkBenutzer)) {
        # Haengt die Verbindung, mit dem neuen Protokoll neu aufbauen
        $verbindung = Get-VpnConnection -Name $profil.Name -ErrorAction SilentlyContinue
        if ($verbindung -and $verbindung.ConnectionStatus -ne 'Connected') {
            $null = cmd.exe /c "rasdial `"$($profil.Name)`" /disconnect 2>&1"
            Start-Sleep -Seconds 2
            $null = cmd.exe /c "rasdial `"$($profil.Name)`" /phonebook:`"$($profil.Datei)`" 2>&1"
            Write-Log "VPN '$($profil.Name)' neu verbunden (rasdial Exitcode $LASTEXITCODE)."
        }
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

# ---------------------------------------------------------------- Laufwerke

function Repair-Laufwerke {
    # Getrennte / "nicht verfuegbare" Laufwerke mit demselben Pfad neu verbinden
    foreach ($z in @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath })) {
        $lw = $z.LocalPath
        $pfad = $z.RemotePath.TrimEnd('\')
        if ($z.Status -eq 'OK' -and (Test-Port (Get-ServerAusPfad $pfad) 445) -and (Test-Path -LiteralPath "$lw\")) { continue }
        if (-not (Test-UncPfad $pfad)) { Write-Log "$lw -> $pfad nicht erreichbar, bleibt unveraendert ($($z.Status))."; continue }
        $null = cmd.exe /c "net use $lw /delete /y 2>&1"
        $ausgabe = cmd.exe /c "net use $lw `"$pfad`" /persistent:yes 2>&1"
        if ($LASTEXITCODE -eq 0) { Write-Log "$lw -> $pfad neu verbunden (war $($z.Status))." }
        else { Write-Log "$lw -> $pfad FEHLER: $((($ausgabe | Out-String) -replace '\s+', ' ').Trim())" }
    }
}

function Invoke-IntuneMapping {
    # Skript der Intune-Zuordnungsaufgaben als dieser Benutzer ausfuehren (jetzt ist das VPN da)
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
    catch { Write-Log "AD-Gruppen FEHLER: $($_.Exception.Message)"; return }
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

if ($NurLaden) { return }
if (-not $E) { Write-Log "Einstellungen.json fehlt in $Ordner."; exit 1 }

switch ($Modus) {
    'System' {
        $null = Repair-Pbk $PbkAlle
    }
    'Pruefung' {
        Repair-BenutzerVpn
        if (Test-DomainErreichbar) { Repair-Laufwerke }
    }
    'Benutzer' {
        Repair-BenutzerVpn
        if (-not (Wait-Domain $E.WartenSekunden)) {
            Write-Log 'Firmennetz nicht erreichbar - naechster Versuch beim VPN-Aufbau.'
            return
        }
        Repair-Laufwerke
        Invoke-IntuneMapping
        if ($E.DruckerVerbinden) { Connect-Drucker }
        Write-Log 'Laufwerke und Drucker geprueft.'
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

function New-Wiederholung([int]$Minuten) {
    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $Minuten)).Repetition
}

function Install-VpnFix {
    Write-Info 'Richte VPN-Fix ein ...' Cyan

    # Ordner nur fuer SYSTEM/Administratoren beschreibbar - die SYSTEM-Aufgabe fuehrt das Skript daraus aus
    New-Item -ItemType Directory -Path $Ordner -Force | Out-Null
    $null = icacls.exe $Ordner /setowner '*S-1-5-32-544' /T /C
    $null = icacls.exe $Ordner /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
    $null = icacls.exe "$Ordner\*" /reset /T /C
    New-Item -ItemType Directory -Path (Join-Path $Ordner 'Logs') -Force | Out-Null

    $skript = Join-Path $Ordner 'VPN-Fix.ps1'
    Set-Content -LiteralPath $skript -Value $WorkerCode -Encoding ASCII
    $Einstellungen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Ordner 'Einstellungen.json') -Encoding ASCII

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumente = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$skript`" -Modus"
    $einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $benutzer = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    # conhost --headless: kein aufblitzendes Fenster beim Benutzer
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'

    # 1) SYSTEM: VPN-Profile "alle Benutzer"
    $start = New-ScheduledTaskTrigger -AtStartup
    $alle15 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix System' -Force `
        -Action (New-ScheduledTaskAction -Execute $ps -Argument "$argumente System") `
        -Trigger @($start, $alle15, (New-EreignisTrigger 'Application' 'RasClient' 20227)) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
        -Settings $einstellungen | Out-Null

    # 2) Benutzer: nach Anmeldung, VPN-Aufbau und Netzwerkwechsel alles verbinden
    $anmeldung = New-ScheduledTaskTrigger -AtLogOn
    $anmeldung.Delay = 'PT15S'
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Benutzer' -Force `
        -Action (New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" $argumente Benutzer") `
        -Trigger @(
            $anmeldung,
            (New-EreignisTrigger 'Application' 'RasClient' 20225 'PT10S'),
            (New-EreignisTrigger 'Microsoft-Windows-NetworkProfile/Operational' 'Microsoft-Windows-NetworkProfile' 10000 'PT15S')
        ) `
        -Principal $benutzer -Settings $einstellungen | Out-Null

    # 3) Benutzer: alle 15 Minuten und bei VPN-Fehler das Profil pruefen
    $pruefung = New-ScheduledTaskTrigger -AtLogOn
    $pruefung.Repetition = New-Wiederholung 15
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Pruefung' -Force `
        -Action (New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" $argumente Pruefung") `
        -Trigger @($pruefung, (New-EreignisTrigger 'Application' 'RasClient' 20227)) `
        -Principal $benutzer -Settings $einstellungen | Out-Null

    Start-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix System' -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskPath $TaskPath -TaskName 'VPN-Fix Pruefung' -ErrorAction SilentlyContinue

    Write-Info "Eingerichtet: $Ordner" Green
    Write-Info "Aufgaben: $($TaskPath)VPN-Fix System / Benutzer / Pruefung" Green
    Write-Info 'Wirkt ab sofort und nach jedem Neustart. Sicherheitshalber einmal ab- und wieder anmelden.' Green
}

function Show-Status {
    Write-Info 'Geplante Aufgaben:' Cyan
    $aufgaben = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'VPN-Fix*' })
    if (-not $aufgaben) { Write-Info 'nicht eingerichtet' Yellow }
    foreach ($a in $aufgaben) {
        $info = $a | Get-ScheduledTaskInfo
        Write-Info ("{0}: {1}, zuletzt {2} (Ergebnis {3})" -f $a.TaskName, $a.State, $info.LastRunTime, $info.LastTaskResult)
    }

    # Funktionen des Aufgaben-Skripts laden, um die VPN-Profile auszulesen
    . ([scriptblock]::Create($WorkerCode)) -NurLaden
    Write-Info 'VPN-Profile (VPNStrategy: 5 = nur SSTP, 7 = nur IKEv2, 0/6/8/14 = Fallback = betroffen):' Cyan
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
    Write-Info "Benutzer-Log: %LOCALAPPDATA%\GHG\Logs\VPN-Fix.log" DarkGray
}

function Uninstall-VpnFix {
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'VPN-Fix*' } |
        Unregister-ScheduledTask -Confirm:$false
    Remove-Item -LiteralPath $Ordner -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info 'Aufgaben und Dateien entfernt.' Green
    Write-Info 'Die VPN-Profile bleiben auf dem festen Protokoll. Original: rasphone.pbk.vor-VPN-Fix im Pbk-Ordner,' Yellow
    Write-Info 'oder VPN-Notfall.cmd -> [3] -> Automatisch (erst wenn Microsoft den Fehler behoben hat).' Yellow
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
    Write-Host '  [3] Entfernen'
    Write-Host '  [Enter] Beenden'
    switch (Read-Host '  Auswahl') {
        '1' { try { Install-VpnFix } catch { Write-Info "FEHLER: $($_.Exception.Message)" Red } }
        '2' { Show-Status }
        '3' { Uninstall-VpnFix }
        ''  { exit }
    }
}

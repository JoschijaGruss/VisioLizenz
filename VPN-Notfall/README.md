# VPN-Notfall – Always On VPN reparieren + Laufwerke/Drucker neu verbinden

Werkzeug für den Always-On-VPN-Fehler nach den Windows-11-Updates ab September 2026
(KB5124008 / KB5124012, Windows 11 24H2/25H2/26H1): Die Verbindung hängt bei
„Verbindung wird hergestellt“ oder meldet „Der angegebene Port wird bereits verwendet“, wenn
das VPN-Profil auf **automatische Protokollwahl** steht. Außerdem verbindet es die
Netzlaufwerke und Drucker sauber neu.

## Dateien

| Datei | Zweck |
|---|---|
| `VPN-Notfall.bat` | **Doppelklick-Start** (ruft `VPN-Notfall.ps1` mit `-ExecutionPolicy Bypass` auf). `VPN-Notfall.bat -Auto` = alles reparieren ohne Menü |
| `VPN-Notfall.ps1` | Das Programm: Diagnose, VPN-Workaround, neu verbinden |
| `GHG-Mapping.ps1` | Neues Mapping-Skript für Laufwerke **und** Drucker. Wird als Intune-Plattformskript verteilt **und** vom Notfall-Tool benutzt (eine Konfiguration für beides) |
| `Installieren.ps1` | Installation des Notfall-Tools als Intune-Win32-App (Ordner `C:\ProgramData\GHG\VPN-Notfall`, Verknüpfung auf Desktop + Startmenü) |
| `Build-Exe.ps1` | Optional: baut eine `VPN-Notfall.exe` mit ps2exe |

## Das Menü

```
[1] Alles reparieren (empfohlen): VPN-Protokoll, VPN neu verbinden, Laufwerke + Drucker
[2] Nur Laufwerke und Drucker neu verbinden
[3] Diagnose anzeigen
[4] VPN-Protokoll manuell wählen (SSTP / IKEv2 / Automatisch)
[5] VPN-Dienst (RasMan) neu starten  [Admin]  – bei "Port wird bereits verwendet"
[6] Harte Reparatur Laufwerke: alles trennen, Kerberos-Tickets erneuern, neu verbinden
[7] Windows-Updateverlauf öffnen (fehlerhaftes Update deinstallieren)  [Admin]
[8] Log-Ordner öffnen
```

**[1] Alles reparieren** macht:

1. Liest beide Telefonbücher (`%APPDATA%\…\Pbk\rasphone.pbk` = Benutzer-Tunnel,
   `C:\ProgramData\…\Pbk\rasphone.pbk` = alle Benutzer/Device-Tunnel). Steht ein VPN-Profil auf
   `VPNStrategy=0` (automatisch) oder einem Fallback-Wert, wird es auf **SSTP (5)** umgestellt
   (Sicherungskopie `rasphone.pbk.bak_<Datum>` wird angelegt). Für das Telefonbuch „alle
   Benutzer“ kommt eine UAC-Abfrage.
2. Trennt das VPN und verbindet neu, wartet bis der Domain Controller erreichbar ist. Klappt
   SSTP nicht, wird automatisch **IKEv2 (7)** probiert.
3. Leert den DNS-Cache.
4. Verbindet Laufwerke und Drucker neu und zeigt das Ergebnis.

Das Programm **nicht als Administrator starten** – Laufwerke, die aus einem Admin-Fenster
verbunden werden, sieht der Explorer nicht. Wo Adminrechte nötig sind, fragt das Tool selbst.

Jede Sitzung wird protokolliert: `%LOCALAPPDATA%\GHG\Logs\VPN-Notfall_<Datum>.txt`
(Menüpunkt 8). Das Mapping selbst schreibt nach `%LOCALAPPDATA%\GHG\Logs\Mapping.log`.

## Analyse des bisherigen Drucker-/Laufwerk-Mappings

Warum es „manchmal nicht startet“ und warum der volle Pfad geht, das Laufwerk aber nicht:

| # | Problem im bisherigen Skript / Ablauf | Folge | Lösung in `GHG-Mapping.ps1` |
|---|---|---|---|
| 1 | Die Beschreibung verspricht eine geplante Aufgabe „bei jeder Anmeldung“ – **der Code dafür fehlt**. Intune führt das Skript nur einmal aus. | Läuft das Skript, bevor das VPN steht, passiert danach nie wieder etwas. | Als SYSTEM wird die Aufgabe `\GHG\GHG-Mapping` angelegt: Start **bei Anmeldung, bei jeder neuen Netzwerkverbindung (Event 10000) und bei jedem VPN-Aufbau (RasClient 20225)**. |
| 2 | AD-Abfrage (`FindOne()`) läuft sofort und ohne Fehlerbehandlung. | Ohne VPN ist `$user` leer → Fehler → keine Drucker/Laufwerke. | Wartet bis zu 120 s, bis ein Domain Controller (LDAP 389) erreichbar ist; sauberes Log statt Absturz. |
| 3 | `$env:USERDNSDOMAIN` wird für `LDAP://` verwendet. | Auf Entra-joined Geräten / vor dem VPN leer → `LDAP://` ungültig. | Domain fest: `$Domain = 'ghg.local'`. |
| 4 | `Get-ADGroupMembership`, `Test-GroupMembership` und `$PrinterMappingConfig` werden nie benutzt (`$PrinterMappingConfig` existiert nicht, Parametername `$driveMappingConfig` passt nicht). | Toter Code, verschachtelte Gruppen werden nicht erkannt. | Eine Abfrage mit `LDAP_MATCHING_RULE_IN_CHAIN` liefert alle Gruppen inkl. Verschachtelung samt Beschreibung. |
| 5 | Der DN wird ungeschützt in den LDAP-Filter eingesetzt. | Bei Benutzern wie `CN=Muster\, Hans` oder mit Klammern ist der Filter kaputt. | `ConvertTo-LdapWert` escaped `\ * ( )`. |
| 6 | Laufwerke werden dauerhaft (persistent) gespeichert. Beim Anmelden stellt Windows sie wieder her, **bevor** das VPN steht. | Laufwerk bleibt „nicht verfügbar“/rotes X, obwohl `\\server\freigabe` direkt funktioniert. | Vor dem Verbinden wird geprüft: Server erreichbar? Zuordnung zeigt auf den richtigen Pfad und Status OK? Sonst `net use /delete` + neu. Standard **nicht persistent** (`$LaufwerkePersistent`), die Aufgabe verbindet ja bei jedem VPN-Aufbau neu. |
| 7 | Server ohne FQDN (`\\server\…`). | Über VPN wird der Kurzname oft nicht aufgelöst, der volle Name schon. | Pfade mit FQDN eintragen; die Diagnose warnt bei Kurznamen. |
| 8 | Fehler 1219 (Verbindung mit anderen Anmeldedaten) / alte Einträge in der Anmeldeinformationsverwaltung. | Laufwerk lässt sich nicht verbinden, UNC-Pfad geht. | Fehler wird erkannt und erklärt; Notfall-Menü **[6]** trennt alles, erneuert Kerberos-Tickets (`klist purge`) und verbindet neu. Diagnose zeigt gespeicherte Anmeldedaten. |
| 9 | Skript in einem Admin-/SYSTEM-Kontext. | Laufwerke sind im Explorer unsichtbar (UAC trennt die Sitzungen). | Aufgabe läuft als angemeldeter Benutzer ohne Adminrechte; Notfall-Tool warnt bei Adminstart. |
| 10 | „Windows verwaltet Standarddrucker“ ist aktiv. | Standarddrucker wird wieder überschrieben. | `LegacyDefaultPrinterMode = 1` vor dem Setzen. |
| 11 | `Get-WMIObject` (veraltet), Datei ohne BOM mit Umlauten („RenstrÃ¶m“). | Unter PowerShell 7 nicht vorhanden; Umlaute kaputt. | `Get-CimInstance`/`Invoke-CimMethod`; Skripte enthalten nur ASCII-Zeichen. |
| 12 | Unsichtbarer Start fehlte bzw. VBScript-Wrapper (VBScript wird aus Windows entfernt). | Aufblitzendes Fenster oder Skript startet gar nicht. | Start über `conhost.exe --headless powershell.exe …`. |

## Einrichtung

### 1. `GHG-Mapping.ps1` anpassen

- **`$driveMappingJson`**: Die Laufwerke eintragen. Das Format ist dasselbe wie beim
  IntuneDriveMapping-Generator – die JSON aus dem bisherigen Laufwerks-Skript kann 1:1
  übernommen werden. Pfade möglichst mit FQDN (`\\server.ghg.local\…`).
- `$PrintServer`, `$PrinterGroupPrefixes`: aus dem bisherigen Druckerskript übernommen (ohne
  `CN=`; der Vergleich ist jetzt unabhängig von Groß-/Kleinschreibung und berücksichtigt auch
  verschachtelte Gruppen).
- `$AlteAufgaben`: z.B. `'IntuneDriveMapping'` eintragen, damit die alte Aufgabe beim
  Ausrollen entfernt wird – erst, wenn alle Laufwerke in `$driveMappingJson` stehen.

### 2. Intune – Plattformskript

Geräte → Skripts → Hinzufügen → Windows 10 und höher → `GHG-Mapping.ps1`

| Einstellung | Wert |
|---|---|
| Skript mit den Anmeldeinformationen des angemeldeten Benutzers ausführen | **Nein** (als SYSTEM → legt die Aufgabe an) |
| Skriptsignaturprüfung erzwingen | Nein |
| Skript in 64-Bit-PowerShell-Host ausführen | **Ja** |

Das alte Druckerskript danach aus der Zuweisung nehmen (Drucker macht jetzt `GHG-Mapping.ps1`).
Bei jeder Änderung der Konfiguration das Skript in Intune neu hochladen – Intune führt es dann
erneut aus und aktualisiert die Kopie in `C:\ProgramData\GHG\Mapping`.

### 3. Notfall-Tool verteilen

- **Einfach:** Ordner (`VPN-Notfall.bat`, `VPN-Notfall.ps1`, `GHG-Mapping.ps1`) auf das Gerät
  kopieren, `VPN-Notfall.bat` doppelklicken.
- **Intune-Win32-App:** Ordner mit dem Win32 Content Prep Tool packen
  - Installieren: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Installieren.ps1`
  - Deinstallieren: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Installieren.ps1 -Deinstallieren`
  - Erkennung: Datei `C:\ProgramData\GHG\VPN-Notfall\VPN-Notfall.ps1`
  - Installationsverhalten: System

Das Notfall-Tool nimmt die Laufwerks-/Druckerkonfiguration bevorzugt aus der per Intune
installierten `C:\ProgramData\GHG\Mapping\GHG-Mapping.ps1`, sonst aus der Datei daneben.

### 4. Einstellungen in `VPN-Notfall.ps1`

| Variable | Bedeutung |
|---|---|
| `$VpnName` | Nur dieses VPN-Profil bearbeiten (leer = alle) |
| `$StandardProtokoll` | `'SSTP'` oder `'IKEv2'` – wird zuerst versucht |
| `$VpnWartenSekunden` | Wartezeit nach dem Neuverbinden |
| `$ProblemUpdates` | KB-Nummern für die Diagnose |

## VPNStrategy-Werte (rasphone.pbk)

| Wert | Bedeutung |
|---|---|
| 0 | Automatisch – **vom Fehler betroffen** |
| 5 | nur SSTP (nur User-Tunnel) |
| 6 | SSTP zuerst, mit Fallback |
| 7 | nur IKEv2 (Device-Tunnel kann nur IKEv2) |
| 8 / 14 | IKEv2 zuerst, mit Fallback |

Das Tool stellt nur Profile um, die nicht schon auf genau einem Protokoll stehen. Ein
Device-Tunnel (IKEv2) bleibt deshalb unverändert. Mit Menü **[4] → Automatisch** wird der
Originalzustand wiederhergestellt, sobald Microsoft den Fehler behoben hat.

**Wichtig:** Das ist ein Workaround auf dem einzelnen Gerät. Intune kann das Profil beim
nächsten Abgleich wieder auf „Automatisch“ setzen. Die dauerhafte Lösung ist, im
Intune-VPN-Profil den Verbindungstyp von „Automatisch“ auf **IKEv2** oder **SSTP** zu ändern.

# VPN-Notfall und VPN-Dauerlösung

**Eine Datei: `VPN-Notfall.cmd`** – bei VPN- oder Laufwerksproblemen doppelklicken.
Nicht „Als Administrator ausführen“ (sonst sieht der Explorer die Laufwerke nicht);
wo Adminrechte nötig sind, fragt das Programm selbst.

## Was es automatisch macht

1. **VPN** – Steht ein Always-On-VPN-Profil auf automatischer Protokollwahl
   (`VPNStrategy=0` in `rasphone.pbk`), wird es auf **SSTP** umgestellt und neu verbunden;
   klappt das nicht, auf **IKEv2**. Workaround für den Fehler nach den Windows-11-Updates ab
   September 2026 (KB5124008 / KB5124012: „Verbindung wird hergestellt“ bzw. „Port wird
   bereits verwendet“). Vorher wird eine Sicherung `rasphone.pbk.bak_<Datum>` angelegt.
2. **Netzlaufwerke** – Laufwerke, die „nicht verfügbar“/getrennt sind, obwohl der Pfad
   `\\server\freigabe` geht, werden getrennt und mit demselben Pfad neu verbunden.
3. **Intune-Laufwerkszuordnung** – die geplante Aufgabe `*DriveMapping*` /
   `*PrinterMapping*` wird gesucht und ihr Skript erneut ausgeführt.
4. **Drucker** – aus den AD-Druckergruppen (wie im bisherigen Druckerskript, jetzt auch mit
   verschachtelten Gruppen).

Danach zeigt es das Ergebnis und bietet an:

```
[1] Harte Reparatur Laufwerke (alles trennen, Kerberos erneuern, neu verbinden)
[2] VPN-Dienst neu starten  [Admin]
[3] VPN-Protokoll selbst wählen (SSTP / IKEv2 / Automatisch zurück)
[4] Windows-Updateverlauf öffnen - Update deinstallieren  [Admin]
[5] Log-Ordner öffnen
```

Protokoll jeder Ausführung: `%LOCALAPPDATA%\GHG\Logs\VPN-Notfall_<Datum>.txt`

## Dauerlösung: `VPN-Dauerloesung.cmd`

**Einmal ausführen**, danach läuft alles automatisch, auch nach jedem Neustart.
Doppelklick → UAC bestätigen → **[1] Einrichten**. Danach einmal ab- und wieder anmelden.

Es legt in der Aufgabenplanung unter `\GHG\` drei Aufgaben an:

| Aufgabe | läuft als | Wann | Was |
|---|---|---|---|
| `VPN-Fix System` | SYSTEM | Systemstart, alle 15 Min., VPN-Fehler (RasClient 20227) | VPN-Profile „alle Benutzer“ auf festes Protokoll |
| `VPN-Fix Benutzer` | angemeldeter Benutzer | Anmeldung, VPN verbunden (RasClient 20225), Netzwerkwechsel | eigenes VPN-Profil korrigieren, auf Firmennetz warten, getrennte Laufwerke neu verbinden, Intune-Laufwerkszuordnung ausführen, Drucker |
| `VPN-Fix Pruefung` | angemeldeter Benutzer | alle 15 Min., VPN-Fehler | VPN-Profil erneut korrigieren (Windows/Intune setzen es nach einem Fallback zurück), Laufwerke prüfen |

- Festes Protokoll: `Protokoll = 'SSTP'` (5) oder `'IKEv2'` (7), oben in der Datei.
  Profile, die schon auf genau einem Protokoll stehen (z.B. Device-Tunnel = 7), bleiben unverändert.
- Der Originalzustand wird einmalig als `rasphone.pbk.vor-VPN-Fix` gesichert.
- Die Skripte liegen in `C:\ProgramData\GHG\VPN-Fix` (nur Admins/SYSTEM dürfen schreiben).
- Logs: `C:\ProgramData\GHG\VPN-Fix\Logs\System.log` und `%LOCALAPPDATA%\GHG\Logs\VPN-Fix.log`.
- **[2] Status** zeigt Aufgaben, VPNStrategy aller Benutzer und das Log, **[3] Entfernen** löscht alles wieder.
- **Intune:** Datei in `VPN-Dauerloesung.ps1` umbenennen und als Plattformskript verteilen
  (mit Anmeldeinformationen des Benutzers: Nein, 64-Bit: Ja) – richtet dann ohne Rückfrage ein.
- Wenn Microsoft den Fehler wirklich behoben hat: **[3] Entfernen**, danach das Protokoll mit
  `VPN-Notfall.cmd` → [3] → Automatisch zurückstellen.

## Einstellungen (oben in der Datei, mit Editor öffnen)

| Variable | Bedeutung |
|---|---|
| `$VpnName` | nur dieses VPN-Profil bearbeiten (leer = alle) |
| `$StandardProtokoll` | `'SSTP'` oder `'IKEv2'` – wird zuerst versucht |
| `$Domain` | `ghg.local` – daran wird erkannt, ob das Firmennetz erreichbar ist |
| `$ZusatzLaufwerke` | Laufwerke, die immer verbunden werden sollen, z.B. `@{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }` |
| `$PrintServer`, `$PrinterGroupPrefixes` | aus dem bisherigen Druckerskript |

## Warum das bisherige Mapping „manchmal nicht startet“

- Das Druckerskript verspricht eine geplante Aufgabe „bei jeder Anmeldung“, **der Code dafür
  fehlt**. Intune führt es nur einmal aus – steht das VPN da noch nicht, passiert nichts mehr.
- Die AD-Abfrage läuft ohne Warten und ohne Fehlerbehandlung; ohne VPN bricht das Skript ab.
  `$env:USERDNSDOMAIN` ist auf Entra-joined Geräten leer.
- Gespeicherte Laufwerke stellt Windows beim Anmelden wieder her, **bevor** das VPN steht –
  sie bleiben „nicht verfügbar“, obwohl der volle Pfad funktioniert. Genau das repariert
  Schritt 2.
- `Get-ADGroupMembership` / `Test-GroupMembership` werden nie benutzt (`$PrinterMappingConfig`
  existiert nicht) – verschachtelte Gruppen werden nicht erkannt.

**Hinweis:** Die Protokoll-Umstellung gilt nur auf dem Gerät; Intune kann sie beim nächsten
Abgleich zurücksetzen. Dauerhaft: im Intune-VPN-Profil den Verbindungstyp von „Automatisch“
auf IKEv2 oder SSTP stellen.

# GHG VPN-Hilfe

**Eine Datei: `VPN-Hilfe.cmd`** – Doppelklick öffnet ein Fenster mit zwei Knöpfen.

| Knopf | Wann | Was passiert |
|---|---|---|
| **1. VPN reparieren** | Homeoffice, VPN hängt oder fehlt | VPN-Profil auf festes Protokoll **SSTP** stellen, VPN neu verbinden, danach **automatisch die Laufwerke** verbinden |
| **2. Laufwerke verbinden** | VPN steht (oder im Büro), Laufwerke fehlen / „nicht verfügbar“ | getrennte Laufwerke neu verbinden, **Intune-Laufwerkszuordnung (DriveMapping) ausführen**, Drucker verbinden |

- Häkchen **„Laufwerke vorher komplett trennen“**: wenn Knopf 2 allein nicht hilft (alles trennen,
  Kerberos-Tickets erneuern, neu verbinden).
- Die Laufwerke werden **immer für den angemeldeten Benutzer** verbunden – auch wenn du das
  Programm mit deinem Admin-Konto startest. Oben im Fenster steht, für wen.
- **Dauerlösung einrichten** (einmal, braucht Adminrechte): Danach passiert das automatisch bei
  jedem Start, jeder Anmeldung, jedem VPN-Aufbau und alle 15 Minuten – auch nach Neustart.
- **Logs** öffnet `%LOCALAPPDATA%\GHG\Logs` (Datei `VPN-Fix.log`).

## Warum die Laufwerke mit SSTP nicht kommen – einfach erklärt

```
Normal (IKEv2):   Start → Anmeldung → VPN steht schnell → Laufwerks-Aufgabe läuft → Laufwerke da ✔

Mit SSTP:         Start → Anmeldung → Laufwerks-Aufgabe läuft → VPN noch nicht da → Laufwerke ins Leere ✘
                                                              → VPN kommt erst danach (SSTP ist langsamer)
```

Die Intune-Laufwerkszuordnung läuft **einmal direkt nach der Anmeldung**. Kommt das VPN erst
danach, findet sie die Server nicht, und Windows merkt sich die Laufwerke als „nicht verfügbar“.
Der **volle Pfad** (`\\server\freigabe`) funktioniert, weil du ihn **später** eintippst – dann
steht das VPN schon.

**Die Lösung:** Die Laufwerke erst verbinden, **wenn das VPN steht**. Genau das machen Knopf 2
und die Dauerlösung: Sie warten, bis das Firmennetz erreichbar ist, und starten die
Laufwerkszuordnung dann (noch einmal).

## Warum das VPN hängt

Seit den Windows-11-Updates ab September 2026 (KB5124008 / KB5124012) hängt Always On VPN, wenn
das Profil zwischen IKEv2 und SSTP wechseln darf (`VPNStrategy` 0, 6, **8**, 14 in
`%APPDATA%\Microsoft\Network\Connections\Pbk\rasphone.pbk`). Mit einem festen Protokoll
(**5 = nur SSTP**) tritt der Fehler nicht auf. Windows und Intune stellen den Wert manchmal zurück –
deshalb prüft die Dauerlösung ihn alle 15 Minuten. Das Original wird einmalig als
`rasphone.pbk.vor-VPN-Fix` gesichert.

Dauerhaft lässt sich das nur im Intune-VPN-Profil lösen, oder wenn Microsoft den Fehler behebt.
Danach: **Dauerlösung entfernen**.

## Dauerlösung im Detail

Aufgabenplanung, Ordner `\GHG\`:

| Aufgabe | läuft als | Wann | Was |
|---|---|---|---|
| `VPN-Fix System` | SYSTEM | Systemstart, alle 15 Min., VPN-Fehler | VPN-Profile „alle Benutzer“ auf festes Protokoll |
| `VPN-Fix Benutzer` | angemeldeter Benutzer | Anmeldung, **VPN verbunden**, Netzwerkwechsel | VPN-Profil, auf Firmennetz warten, Laufwerke, Intune-Zuordnung, Drucker |
| `VPN-Fix Pruefung` | angemeldeter Benutzer | alle 15 Min., VPN-Fehler | VPN-Profil erneut korrigieren, Laufwerke prüfen |

Skripte liegen in `C:\ProgramData\GHG\VPN-Fix` (nur Admins/SYSTEM dürfen schreiben).

**Für viele Geräte über Intune:** `VPN-Hilfe.cmd` in `VPN-Hilfe.ps1` umbenennen und als
Plattformskript verteilen (mit Anmeldeinformationen des Benutzers: **Nein**, 64-Bit: **Ja**) – richtet
die Dauerlösung dann ohne Fenster ein.

## Einstellungen (oben in der Datei, mit Editor öffnen)

| Einstellung | Bedeutung |
|---|---|
| `VpnName` | nur dieses VPN-Profil bearbeiten (leer = alle) |
| `Protokoll` | `'SSTP'` (5) oder `'IKEv2'` (7) |
| `Domain` | `ghg.local` – daran wird erkannt, ob das Firmennetz erreichbar ist |
| `MappingAufgaben` | Namen der Intune-Zuordnungsaufgaben (`*DriveMapping*`, `*PrinterMapping*`) |
| `ZusatzLaufwerke` | Laufwerke, die immer verbunden werden sollen, z.B. `@{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }` |
| `PrintServer`, `PrinterGroupPrefixes` | aus dem bisherigen Druckerskript |

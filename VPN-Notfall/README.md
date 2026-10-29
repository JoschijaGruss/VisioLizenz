# GHG VPN-Dauerlösung und VPN-Hilfe

| Datei | Wofür | Wie oft |
|---|---|---|
| **`VPN-Dauerloesung.cmd`** | Löst das VPN-Problem dauerhaft (auch nach Neustart) | **einmal** pro Gerät (Adminrechte) |
| **`VPN-Hilfe.cmd`** | Fenster mit zwei Knöpfen, falls doch einmal etwas hängt | bei Bedarf |

## VPN-Dauerlösung (`VPN-Dauerloesung.cmd`)

Doppelklick → UAC bestätigen → **[1] Einrichten** → einmal ab- und wieder anmelden. Fertig.

**Kern – das VPN:** Das VPN-Profil wird dauerhaft auf **nur SSTP** (`VPNStrategy=5`) gestellt.
Damit hängt das VPN nicht mehr (Fehler der Windows-Updates ab September 2026), und es steht
nach der Anmeldung viel früher – deshalb finden auch die Intune-Laufwerke die Server wieder.
Windows oder Intune stellen den Wert manchmal zurück: Er wird bei Start, Anmeldung, alle
15 Minuten und bei jedem VPN-Fehler geprüft und wieder auf 5 gesetzt. In Intune selbst lässt sich
SSTP nicht fest einstellen, deshalb geschieht das lokal.

**Dazu – keine roten X mehr:** Windows stellt Netzlaufwerke bei der Anmeldung nicht mehr selbst
wieder her (`RestoreConnection = 0`). Vorher hat es das versucht, bevor das VPN stand, und die
Laufwerke blieben „nicht verfügbar“.

**Reserve – die Laufwerke:** Sobald das VPN verbunden ist, werden kaputte oder gemerkte Laufwerke
neu verbunden und die Intune-Laufwerkszuordnung (DriveMapping) wird noch einmal ausgeführt.

| Aufgabe (Aufgabenplanung `\GHG\`) | läuft als | Wann | Was |
|---|---|---|---|
| `VPN-Fix System` | SYSTEM | Systemstart, alle 15 Min., VPN-Fehler | VPN-Profile „alle Benutzer“ |
| `VPN-Fix Benutzer` | Benutzer | Anmeldung, alle 15 Min., VPN-Fehler | eigenes VPN-Profil |
| `VPN-Fix Laufwerke` | Benutzer | Anmeldung, **VPN verbunden** | Laufwerke + Intune-Zuordnung (Reserve) |

- **[2] Status** zeigt Aufgaben, `RestoreConnection` und den VPN-Wert aller Benutzer.
- **[3] Entfernen** löscht alles und stellt `RestoreConnection` zurück – erst, wenn Microsoft den
  Fehler behoben hat. Das Original-VPN-Profil liegt als `rasphone.pbk.vor-VPN-Fix` daneben.
- **Viele Geräte über Intune:** in `VPN-Dauerloesung.ps1` umbenennen, als Plattformskript verteilen
  (mit Anmeldeinformationen des Benutzers: **Nein**, 64-Bit: **Ja**).
- Einstellungen oben in der Datei: `Protokoll` (`'SSTP'`/`'IKEv2'`), `VpnName`,
  `LaufwerkeNichtWiederherstellen`, `LaufwerkeReserve`, `Domain`, `MappingAufgaben`.
- Logs: `C:\ProgramData\GHG\VPN-Fix\Logs\System.log`, `%LOCALAPPDATA%\GHG\Logs\VPN-Fix.log`.

## VPN-Hilfe (`VPN-Hilfe.cmd`)

**Eine Datei: `VPN-Hilfe.cmd`** – Doppelklick öffnet ein Fenster mit zwei Knöpfen.

| Knopf | Wann | Was passiert |
|---|---|---|
| **1. VPN reparieren** | Homeoffice, VPN hängt oder fehlt | VPN-Profil auf festes Protokoll **SSTP** stellen, VPN neu verbinden, danach **automatisch die Laufwerke** verbinden |
| **2. Laufwerke verbinden** | VPN steht (oder im Büro), Laufwerke fehlen / „nicht verfügbar“ | getrennte Laufwerke neu verbinden, **Intune-Laufwerkszuordnung (DriveMapping) ausführen**, Drucker verbinden |

- Häkchen **„Laufwerke vorher komplett trennen“**: wenn Knopf 2 allein nicht hilft (alles trennen,
  Kerberos-Tickets erneuern, neu verbinden).
- Die Laufwerke werden **immer für den angemeldeten Benutzer** verbunden – auch wenn du das
  Programm mit deinem Admin-Konto startest. Oben im Fenster steht, für wen.
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
Danach: `VPN-Dauerloesung.cmd` → **[3] Entfernen**.

## Einstellungen von `VPN-Hilfe.cmd` (oben in der Datei)

| Einstellung | Bedeutung |
|---|---|
| `VpnName` | nur dieses VPN-Profil bearbeiten (leer = alle) |
| `Protokoll` | `'SSTP'` (5) oder `'IKEv2'` (7) |
| `Domain` | `ghg.local` – daran wird erkannt, ob das Firmennetz erreichbar ist |
| `MappingAufgaben` | Namen der Intune-Zuordnungsaufgaben (`*DriveMapping*`, `*PrinterMapping*`) |
| `ZusatzLaufwerke` | Laufwerke, die immer verbunden werden sollen, z.B. `@{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }` |
| `PrintServer`, `PrinterGroupPrefixes` | aus dem bisherigen Druckerskript |

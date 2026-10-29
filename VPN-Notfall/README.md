# GHG VPN-Hilfe

**Eine Datei für alles: `VPN-Hilfe.cmd`** – Doppelklick öffnet ein Fenster.

| Knopf | Wann | Was passiert |
|---|---|---|
| **Dauerlösung einrichten** | **einmal pro Gerät** (fragt nach Adminrechten), danach ab- und wieder anmelden | VPN bleibt dauerhaft auf SSTP, Laufwerke kommen nach dem VPN – automatisch, auch nach Neustart |
| **1. VPN reparieren** | Homeoffice, VPN hängt oder fehlt | VPN-Profil auf **nur SSTP**, VPN neu verbinden, danach **automatisch die Laufwerke** |
| **2. Laufwerke verbinden** | VPN steht (oder im Büro), Laufwerke fehlen / „nicht verfügbar“ | Laufwerke neu verbinden, **Intune-Laufwerkszuordnung (DriveMapping) ausführen**, Drucker |

- Häkchen **„Laufwerke vorher komplett trennen“**: wenn Knopf 2 allein nicht hilft (alles trennen,
  Kerberos-Tickets erneuern, neu verbinden).
- Die Laufwerke werden **immer für den angemeldeten Benutzer** verbunden – auch wenn das
  Programm mit dem Admin-Konto gestartet wird. Oben im Fenster steht, für wen.
- **Logs** öffnet `%LOCALAPPDATA%\GHG\Logs` (Datei `VPN-Fix.log`).

## Warum es passiert – einfach erklärt

Seit den Windows-11-Updates ab September 2026 (KB5124008 / KB5124012) hängt Always On VPN, wenn
das Profil zwischen IKEv2 und SSTP wechseln darf (`VPNStrategy` 0, 6, **8**, 14 in
`%APPDATA%\Microsoft\Network\Connections\Pbk\rasphone.pbk`).

```
Bisher (8):   Anmeldung → IKEv2 versucht → scheitert → wartet → SSTP → VPN steht (spät)
              Intune-Laufwerke laufen schon vorher → "nicht verfügbar"

Fest SSTP (5): Anmeldung → SSTP sofort → VPN steht (früh) → Laufwerke finden die Server
```

Der volle Pfad (`\\server\freigabe`) funktioniert, weil du ihn **später** eintippst – dann steht
das VPN schon.

## Was die Dauerlösung macht

1. **VPN (Kern):** Das VPN-Profil wird fest auf **nur SSTP** (5) gestellt und bei Systemstart,
   Anmeldung, alle 15 Minuten und bei jedem VPN-Fehler geprüft – Windows/Intune stellen es sonst
   zurück. In Intune lässt sich SSTP nicht fest einstellen, deshalb geschieht das lokal.
2. **Keine roten X mehr:** Windows stellt Netzlaufwerke bei der Anmeldung nicht mehr selbst wieder
   her, bevor das VPN steht (`RestoreConnection = 0`).
3. **Laufwerke (Reserve):** Sobald das VPN verbunden ist, werden kaputte oder gemerkte Laufwerke
   neu verbunden und die Intune-Laufwerkszuordnung noch einmal ausgeführt.

| Aufgabe (Aufgabenplanung `\GHG\`) | läuft als | Wann | Was |
|---|---|---|---|
| `VPN-Fix System` | SYSTEM | Systemstart, alle 15 Min., VPN-Fehler | VPN-Profile „alle Benutzer“ |
| `VPN-Fix Benutzer` | Benutzer | Anmeldung, alle 15 Min., VPN-Fehler | eigenes VPN-Profil |
| `VPN-Fix Laufwerke` | Benutzer | Anmeldung, **VPN verbunden** | Laufwerke, Intune-Zuordnung, Drucker |

- Skripte: `C:\ProgramData\GHG\VPN-Fix` (nur Admins/SYSTEM dürfen schreiben),
  System-Log: `C:\ProgramData\GHG\VPN-Fix\Logs\System.log`.
- Das Original-VPN-Profil wird einmalig als `rasphone.pbk.vor-VPN-Fix` gesichert.
- **Dauerlösung entfernen** erst, wenn Microsoft den Fehler behoben hat – setzt auch
  `RestoreConnection` zurück.
- **Viele Geräte über Intune:** `VPN-Hilfe.cmd` in `VPN-Hilfe.ps1` umbenennen, als Plattformskript
  verteilen (mit Anmeldeinformationen des Benutzers: **Nein**, 64-Bit: **Ja**) – richtet die
  Dauerlösung ohne Fenster ein.

## Einstellungen (oben in der Datei, mit Editor öffnen)

| Einstellung | Bedeutung |
|---|---|
| `VpnName` | nur dieses VPN-Profil bearbeiten (leer = alle) |
| `Protokoll` | `'SSTP'` (5) oder `'IKEv2'` (7) |
| `LaufwerkeNichtWiederherstellen` | `RestoreConnection = 0` setzen (Dauerlösung) |
| `LaufwerkeReserve` | Aufgabe „VPN-Fix Laufwerke“ anlegen (Dauerlösung) |
| `Domain` | `ghg.local` – daran wird erkannt, ob das Firmennetz erreichbar ist |
| `MappingAufgaben` | Namen der Intune-Zuordnungsaufgaben (`*DriveMapping*`, `*PrinterMapping*`) |
| `ZusatzLaufwerke` | Laufwerke, die immer verbunden werden sollen, z.B. `@{ Buchstabe = 'S'; Pfad = '\\server.ghg.local\Daten' }` |
| `PrintServer`, `PrinterGroupPrefixes` | aus dem bisherigen Druckerskript |

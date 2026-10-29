# VisioLizenz – configuration.xml für Visio / Project (MAK)

Erstellt automatisch die `configuration.xml` für das **Office Deployment Tool (ODT)**,
um **Visio Standard** oder **Project Standard** (2024 oder 2021) mit **MAK-Lizenz** zu installieren.

Ersetzt Schritt 5 + 6 der manuellen Anleitung (Konfiguration auf
[config.office.com](https://config.office.com/deploymentsettings) zusammenklicken und exportieren).

## Dateien

| Datei | Zweck |
|---|---|
| `New-OfficeConfig.ps1` | PowerShell-Skript: fragt Produkt, Jahr und MAK ab und schreibt die `configuration.xml` |
| `Config-erstellen.bat` | Startdatei für Doppelklick; ruft `New-OfficeConfig.ps1` aus **demselben Ordner** mit `-ExecutionPolicy Bypass` auf |
| `README.md` | Diese Beschreibung |

## Benutzung

1. `Config-erstellen.bat` und `New-OfficeConfig.ps1` in denselben Ordner legen.
2. `Config-erstellen.bat` doppelklicken (oder `powershell -ExecutionPolicy Bypass -File .\New-OfficeConfig.ps1`).
3. Abfragen beantworten:
   - Produkt: `Visio` oder `Project`
   - Jahr: `2024` oder `2021`
   - MAK-Schlüssel im Format `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` (wird geprüft, bei Fehler erneut gefragt)
4. Ergebnis: `C:\VisioProjectSetup\configuration.xml`

Keine Adminrechte nötig. Das Skript **installiert und aktiviert nichts** und verbindet sich nicht mit
Microsoft – es schreibt nur die Datei. Es wird also keine MAK-Aktivierung verbraucht.

## Ablauf im Skript (`New-OfficeConfig.ps1`)

1. `Select-Option` zeigt nummerierte Auswahl und wiederholt bis zur gültigen Eingabe → `$produkt`, `$jahr`.
2. MAK wird per `Read-Host` gelesen, getrimmt, in Großbuchstaben gewandelt und gegen
   `^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$` geprüft → `$key`.
3. Produkt-ID wird zusammengesetzt: `"${produkt}Std${jahr}Volume"`, also
   `VisioStd2024Volume`, `VisioStd2021Volume`, `ProjectStd2024Volume` oder `ProjectStd2021Volume`.
4. Neue `Configuration ID` per `[guid]::NewGuid()` (wie beim Export von config.office.com;
   für `setup.exe` nicht relevant).
5. XML wird aus einem Here-String erzeugt (siehe unten).
6. Zielordner `C:\VisioProjectSetup` wird bei Bedarf angelegt.
7. **Backup:** existiert bereits eine `configuration.xml`, wird sie zuerst nach
   `configuration_backup_JJJJMMTT_HHMMSS.xml` kopiert.
8. Datei wird als UTF-8 geschrieben und zur Kontrolle ausgegeben.

## Fest eingestellte Werte

| Einstellung | Wert | XML |
|---|---|---|
| Architektur | 64-Bit | `OfficeClientEdition="64"` |
| Updatekanal | Halbjährlich Enterprise | `Channel="SemiAnnual"` |
| Sprache | Deutsch | `<Language ID="de-de" />` |
| OneDrive Desktop | ausgeschlossen | `<ExcludeApp ID="OneDrive" />` |
| MSI-Versionen entfernen | nein | (kein `<RemoveMSI />`) |
| Lizenz | MAK, automatisch aktivieren | `PIDKEY="…"`, `AUTOACTIVATE=1` |
| Firma | GHG St. Gallen | `<Setup Name="Company" … />` |
| Installationsfenster | sichtbar, EULA akzeptiert | `<Display Level="Full" AcceptEULA="TRUE" />` |

## Erzeugte Datei (Beispiel)

```xml
<Configuration ID="2fef3c8e-1845-4c33-abe7-f3f35d7d0c50">
  <Add OfficeClientEdition="64" Channel="SemiAnnual">
    <Product ID="VisioStd2024Volume" PIDKEY="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX">
      <Language ID="de-de" />
      <ExcludeApp ID="OneDrive" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Updates Enabled="TRUE" />
  <AppSettings>
    <Setup Name="Company" Value="GHG St. Gallen" />
  </AppSettings>
  <Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
```

## Nächste Schritte (noch manuell, nicht im Skript)

Im Ordner `C:\VisioProjectSetup` muss zusätzlich das Office Deployment Tool liegen
(`officedeploymenttool_….exe`, entpackt → `setup.exe`). Dann in einer CMD mit Adminrechten:

```cmd
cd C:\VisioProjectSetup
setup.exe /download configuration.xml
setup.exe /configure configuration.xml
```

Erst `/configure` installiert und aktiviert mit dem MAK (zählt als eine Aktivierung).

## Einbinden in ein anderes Projekt / Anpassen

- Beide Dateien gemeinsam kopieren – die `.bat` erwartet die `.ps1` im selben Ordner (`%~dp0`).
- Zielordner ändern: Variable `$Zielordner` oben im Skript.
- Weitere Jahre/Produkte: Liste in `Select-Option "Welches Jahr?" @("2024", "2021")` bzw.
  `@("Visio", "Project")` erweitern. Die Produkt-ID muss dem Muster `<Produkt>Std<Jahr>Volume`
  entsprechen; sonst die Zeile `$productId = …` anpassen (z. B. Professional: `VisioPro2024Volume`).
- Weitere feste Einstellungen (Sprache, Firma, Kanal …) direkt im XML-Here-String ändern.
- Das Skript ist interaktiv (`Read-Host`). Für eine vollautomatische Nutzung müssten
  Produkt, Jahr und MAK als Parameter übergeben werden.

## Sicherheit

Die `configuration.xml` enthält den MAK-Schlüssel im Klartext. Nicht ins Repository
einchecken und nicht weitergeben (`configuration*.xml` ist in `.gitignore` eingetragen).

## Weitere Tools in diesem Repository

- [`VPN-Notfall/`](VPN-Notfall/README.md) – Always On VPN (Fehler der Windows-11-Updates ab September 2026):
  `VPN-Dauerloesung.cmd` löst es einmalig und dauerhaft, `VPN-Hilfe.cmd` ist ein Fenster mit
  „VPN reparieren“ und „Laufwerke verbinden“ für den angemeldeten Benutzer.

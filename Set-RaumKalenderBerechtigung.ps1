<#
.SYNOPSIS
    Vergibt einer Person Bearbeiter-Rechte (Editor) auf den Kalender einer Raumressource in Exchange Online.

.DESCRIPTION
    - Fragt beim Start die Admin-Anmeldung ab (modernes Login-Fenster, MFA wird unterstuetzt).
    - Ermittelt den echten Namen des Kalenderordners (z. B. "Kalender" bei deutschen Postfaechern).
    - Setzt die Berechtigung "Editor" (Bearbeiter). Editor beinhaltet das Anzeigen aller Details
      sowie Erstellen, Aendern und Loeschen von Terminen.
    - Existiert bereits eine Berechtigung fuer die Person, wird sie angepasst statt neu hinzugefuegt.

.NOTES
    Voraussetzung: Modul ExchangeOnlineManagement (wird bei Bedarf installiert).
    Ausfuehren mit: powershell -ExecutionPolicy Bypass -File .\Set-RaumKalenderBerechtigung.ps1
#>

param(
    [string]$Ressource = 'rosenberg.parkplatz-hospiz@ghg-rosenberg.ch',
    [string]$Benutzer  = 'eveline.spirig@ghg-rosenberg.ch',
    [ValidateSet('Editor', 'PublishingEditor', 'Author', 'Reviewer', 'LimitedDetails')]
    [string]$Berechtigung = 'Editor'
)

$ErrorActionPreference = 'Stop'

# --- Modul pruefen / installieren -------------------------------------------
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host 'Modul ExchangeOnlineManagement wird installiert...' -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

# --- Admin-Anmeldung --------------------------------------------------------
$adminUpn = Read-Host 'Admin-Konto (z. B. admin@ghg-rosenberg.ch)'
Write-Host 'Anmeldefenster wird geoeffnet...' -ForegroundColor Cyan
Connect-ExchangeOnline -UserPrincipalName $adminUpn -ShowBanner:$false

try {
    # --- Kalenderordner ermitteln (Name ist sprachabhaengig) ----------------
    $kalender = Get-MailboxFolderStatistics -Identity $Ressource -FolderScope Calendar |
        Where-Object { $_.FolderType -eq 'Calendar' } |
        Select-Object -First 1
    if (-not $kalender) { throw "Kein Kalenderordner fuer $Ressource gefunden." }

    $ordner = "${Ressource}:\$($kalender.Name)"
    Write-Host "Kalenderordner: $ordner" -ForegroundColor Cyan

    # --- Berechtigung setzen ------------------------------------------------
    $vorhanden = Get-MailboxFolderPermission -Identity $ordner -User $Benutzer -ErrorAction SilentlyContinue

    if ($vorhanden) {
        Write-Host "Vorhandene Berechtigung: $($vorhanden.AccessRights -join ', ') -> wird auf $Berechtigung geaendert" -ForegroundColor Yellow
        Set-MailboxFolderPermission -Identity $ordner -User $Benutzer -AccessRights $Berechtigung | Out-Null
    }
    else {
        Add-MailboxFolderPermission -Identity $ordner -User $Benutzer -AccessRights $Berechtigung | Out-Null
    }

    # --- Kontrolle ----------------------------------------------------------
    Write-Host "`nAktuelle Berechtigungen auf $ordner :" -ForegroundColor Green
    Get-MailboxFolderPermission -Identity $ordner |
        Format-Table User, AccessRights, SharingPermissionFlags -AutoSize
}
catch {
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false
    Read-Host 'Fertig. Enter zum Beenden'
}

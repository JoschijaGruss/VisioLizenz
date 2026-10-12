@echo off
REM Doppelklick: erstellt die configuration.xml (ruft New-OfficeConfig.ps1 im selben Ordner auf)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-OfficeConfig.ps1"
echo.
pause

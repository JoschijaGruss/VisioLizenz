@echo off
REM Doppelklick: GHG VPN-Notfall (ruft VPN-Notfall.ps1 im selben Ordner auf).
REM NICHT "Als Administrator ausfuehren" - sonst sieht der Explorer die Laufwerke nicht.
REM Ohne Menue alles reparieren: VPN-Notfall.bat -Auto
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VPN-Notfall.ps1" %*

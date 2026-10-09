@echo off
rem Opens the Command Center window. Double-click this file (it also puts the icon back on the Desktop).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Command Center.ps1"

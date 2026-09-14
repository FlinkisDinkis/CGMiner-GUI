@echo off
title cgminer GUI
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0cgminer_GUI.ps1"
if errorlevel 1 (
  echo.
  echo The GUI closed with an error.
  pause
)

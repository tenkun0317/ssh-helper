@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-helper.ps1" %*

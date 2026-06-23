@echo off
rem MewCode CLI shim - forwards to the project's venv
"%~dp0.venv\Scripts\python.exe" -m mewcode %*

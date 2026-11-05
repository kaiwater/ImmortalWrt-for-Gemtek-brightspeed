@echo off
setlocal
echo ============================================================
echo  emSign ECC Root CA - G3 intermediate blocking (Windows 10)
echo ============================================================
echo.
echo If the script reports "run as administrator", close this window,
echo right-click run.cmd and choose "Run as administrator".
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0block-emsign-g3.ps1" %*
echo.
pause

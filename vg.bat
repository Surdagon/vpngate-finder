@echo off
title Find-VpnGate
rem Needs administrator rights (the SoftEther client service allows control to admins only)
net session >nul 2>&1 || (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)
echo Usage: vg.bat [-Connect] [-Country US,JP] [-Exclude RU,BY,UA] [-Index N] [-ProbeTimeoutMs 5000]
echo After the scan type a VPN number to connect, or: A = sweep all, B = rescan, C = exit
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Find-VpnGate.ps1" %*
echo.
echo Exit code: %errorlevel%
pause

@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title ESP32-C5 Firmware Recovery

set "FIRMWARE=esp32c5-deauther-merged.bin"

echo ============================================================
echo   ESP32-C5 Deauther - complete flash recovery
echo ============================================================
echo.
echo WARNING: this operation erases the complete ESP32-C5 flash.
echo Close MobaXterm, Arduino Serial Monitor and every serial app.
echo.

if not exist "%FIRMWARE%" (
  echo ERROR: %FIRMWARE% was not found beside this script.
  pause
  exit /b 1
)

echo Detected serial ports:
powershell -NoProfile -Command "Get-CimInstance Win32_SerialPort ^| Select-Object DeviceID,Name ^| Format-Table -AutoSize"
echo.
set /p "ESP_PORT=Enter the ESP32-C5 port, for example COM7: "
if not defined ESP_PORT (
  echo No port entered.
  pause
  exit /b 1
)

where py >nul 2>nul
if not errorlevel 1 (
  set "PYTHON_CMD=py -3"
) else (
  where python >nul 2>nul
  if errorlevel 1 (
    echo.
    echo ERROR: Python 3 was not found.
    echo Install Python from https://www.python.org/downloads/windows/
    echo Enable "Add Python to PATH" during installation, then retry.
    pause
    exit /b 1
  )
  set "PYTHON_CMD=python"
)

echo.
echo Put the board in download mode now:
echo   1. Hold the BOOT button.
echo   2. While holding BOOT, press and release RESET.
echo   3. Release BOOT.
echo.
pause

echo.
echo Installing or updating the official Espressif esptool...
%PYTHON_CMD% -m pip install --user --upgrade esptool
if errorlevel 1 goto :failed

echo.
echo Erasing the complete flash and writing the merged firmware...
%PYTHON_CMD% -m esptool --chip esp32c5 --port "%ESP_PORT%" --baud 115200 --before no-reset --after hard-reset write-flash --erase-all 0x0 "%FIRMWARE%"
if errorlevel 1 goto :failed

echo.
echo ============================================================
echo   FLASH COMPLETED AND VERIFIED
echo ============================================================
echo If the board does not restart automatically, press RESET once.
echo Then open MobaXterm on %ESP_PORT% at 115200 baud.
echo The log must contain: ble: advertising as ESP32C5-Deauther
echo.
pause
exit /b 0

:failed
echo.
echo FLASH FAILED.
echo Check the COM port, close every serial program, put the board
echo back in BOOT/download mode and run this script again.
echo.
pause
exit /b 1

@echo off
setlocal

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found in PATH.
  echo Install Flutter, then reopen this terminal and retry.
  exit /b 1
)

pushd "%~dp0"
call flutter config --enable-windows-desktop
if errorlevel 1 goto :failed

call flutter pub get
if errorlevel 1 goto :failed

call flutter build windows --release
if errorlevel 1 goto :failed

powershell -NoProfile -ExecutionPolicy Bypass -Command "$output = Join-Path (Resolve-Path '..') 'deauther-windows-x64.zip'; if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }; Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath $output -CompressionLevel Optimal"
if errorlevel 1 goto :failed

echo.
echo Portable build created:
echo   %~dp0..\deauther-windows-x64.zip
popd
exit /b 0

:failed
echo.
echo Windows build failed. Run "flutter doctor -v" and verify that
echo Visual Studio Desktop development with C++ is installed.
popd
exit /b 1

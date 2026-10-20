@echo off
if not defined IMAGE_COMPRESSOR_EXE set "IMAGE_COMPRESSOR_EXE=%~dp0dist\win-x64\ImageCompressor.App.exe"
if defined IMAGE_COMPRESSOR_TEST_PROBE (
  call "%IMAGE_COMPRESSOR_TEST_PROBE%" %*
  exit /b %errorlevel%
)
if exist "%IMAGE_COMPRESSOR_EXE%" (
  start "" "%IMAGE_COMPRESSOR_EXE%" %*
  exit /b %errorlevel%
) else (
  start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0image-compressor.ps1"
)
if %errorlevel% neq 0 pause

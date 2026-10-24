@echo off
setlocal DisableDelayedExpansion
set "SELF=%~dp0"

if "%SELF:~0,2%"=="\\" goto :unc
if not "%~2"=="" goto :too_many
set "INSTALLER_DIR=%~dp0installer"
if exist "%INSTALLER_DIR%\Install-ImageCompressor.ps1" goto :installer_found
set "INSTALLER_DIR=%~dp0project\installer"
if not exist "%INSTALLER_DIR%\Install-ImageCompressor.ps1" goto :missing

:installer_found
if not exist "%INSTALLER_DIR%\payload\payload-manifest.json" goto :missing

rem The installer resolves the native OS architecture, not the parent process.
set "RUNTIME=auto"

if defined IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE goto :probe

if "%~1"=="" (
  powershell.exe -STA -NoLogo -NoProfile -File "%INSTALLER_DIR%\Install-ImageCompressor.ps1" -Runtime "%RUNTIME%" -SelectOutputRoot -RevealOutput
) else (
  set "IMAGE_COMPRESSOR_INSTALL_ROOT=%~f1"
  powershell.exe -STA -NoLogo -NoProfile -File "%INSTALLER_DIR%\Install-ImageCompressor.ps1" -Runtime "%RUNTIME%" -OutputRootFromEnvironment -RevealOutput
)
set "EXIT_CODE=%ERRORLEVEL%"
goto :result

:probe
if "%~1"=="" (
  "%IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE%" "%RUNTIME%"
) else (
  set "IMAGE_COMPRESSOR_INSTALL_ROOT=%~f1"
  "%IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE%" "%RUNTIME%"
)
exit /b %ERRORLEVEL%

:result
echo.
if "%EXIT_CODE%"=="3" (
  echo Image Compressor installation/update was cancelled. No files were changed.
  pause
  exit /b 3
)
if not "%EXIT_CODE%"=="0" (
  echo Image Compressor installation/update failed with exit code %EXIT_CODE%.
  echo Review the error above. The previous working installation was restored when possible.
  echo If script execution was denied, follow the README. Do not bypass your execution policy.
  pause
  exit /b %EXIT_CODE%
)
echo Image Compressor installation/update completed successfully.
echo The application was not started automatically.
pause
exit /b 0

:unc
echo UNC paths are not supported. Move this distribution folder to a drive-letter path.
pause
exit /b 4

:too_many
echo Specify at most one installation parent folder.
pause
exit /b 2

:missing
echo Installer files or prebuilt payloads are missing.
echo Source checkouts do not include prebuilt payloads.
echo Download and extract image-compressor-installer.zip from GitHub Releases.
echo https://github.com/Ryoichi-R/image-compressor/releases
pause
exit /b 1


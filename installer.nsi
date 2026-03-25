!define MUI_COMPONENTSPAGE_NODESC
!include "MUI2.nsh"

Name "Rclone Optimized Mount"
OutFile "Rclone-Optimized.exe"
RequestExecutionLevel user
SilentInstall silent

Section "Main"
  SetOutPath "$TEMP"

  File "Rclone-Optimized.ps1"
  File "Run-Rclone.bat"

  ; Execute the batch file silently using cmd.exe
  nsExec::ExecToStack 'cmd.exe /C "$TEMP\Run-Rclone.bat"'

  ; Delete extracted files
  Delete "$TEMP\Rclone-Optimized.ps1"
  Delete "$TEMP\Run-Rclone.bat"
SectionEnd

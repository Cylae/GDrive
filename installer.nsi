!define MUI_COMPONENTSPAGE_NODESC
!include "MUI2.nsh"

Name "Rclone Optimized Mount"
OutFile "Rclone-Optimized.exe"
RequestExecutionLevel user
SilentInstall silent

InstallDir "$LOCALAPPDATA\RcloneMountManager"

Section "Main"
  SetOutPath "$INSTDIR"

  File "Mount-GDrive.ps1"
  File "Run-Rclone.bat"

  ; Create a shortcut on the Desktop to launch the Run-Rclone.bat silently
  CreateShortCut "$DESKTOP\Rclone Mount.lnk" "$INSTDIR\Run-Rclone.bat" "" "$INSTDIR\Run-Rclone.bat" 0 SW_SHOWMINIMIZED

  ; Execute the batch file silently using cmd.exe
  nsExec::ExecToStack 'cmd.exe /C "$INSTDIR\Run-Rclone.bat"'
SectionEnd

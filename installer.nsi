!include "MUI2.nsh"

Name "Outbound Database"
OutFile "outbound_database_installer.exe"
InstallDir "$PROGRAMFILES64\Outbound Database"
ShowInstDetails show
ShowUninstDetails show

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

Section "Install"
  SetOutPath "$INSTDIR"
  ; Copy all files from Flutter release folder
  File /r "build\\windows\\runner\\Release\\*"

  ; Write uninstaller
  WriteUninstaller "$INSTDIR\\uninstall.exe"

  ; Create shortcuts on desktop and start menu
  CreateDirectory "$SMPROGRAMS\\Outbound Database"
  CreateShortCut "$SMPROGRAMS\\Outbound Database\\Outbound Database.lnk" "$INSTDIR\\outbound_database.exe"
  CreateShortCut "$DESKTOP\\Outbound Database.lnk" "$INSTDIR\\outbound_database.exe"
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\\Outbound Database\\Outbound Database.lnk"
  Delete "$DESKTOP\\Outbound Database.lnk"
  RMDir "$SMPROGRAMS\\Outbound Database"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Outbound Database"
SectionEnd

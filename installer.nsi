!include "MUI2.nsh"

Name "Outbound Database"

OutFile "OutboundDatabase-Setup.exe"

InstallDir "$PROGRAMFILES64\Outbound Database"

RequestExecutionLevel admin

Unicode True

SetCompressor /SOLID lzma

VIProductVersion "0.1.0.1"
VIAddVersionKey "ProductName" "Outbound Database"
VIAddVersionKey "FileDescription" "Outbound Database Windows Desktop Application"
VIAddVersionKey "CompanyName" "Outbound Database"
VIAddVersionKey "FileVersion" "0.1.0.1"
VIAddVersionKey "LegalCopyright" "Outbound Database"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

Section "Install"

    SetOutPath "$INSTDIR"

    File /r "installer_payload\*"

    WriteUninstaller "$INSTDIR\uninstall.exe"

    CreateDirectory "$SMPROGRAMS\Outbound Database"

    CreateShortCut \
        "$SMPROGRAMS\Outbound Database\Outbound Database.lnk" \
        "$INSTDIR\outbound_database.exe"

    CreateShortCut \
        "$DESKTOP\Outbound Database.lnk" \
        "$INSTDIR\outbound_database.exe"

    WriteRegStr \
        HKLM \
        "Software\Microsoft\Windows\CurrentVersion\Uninstall\Outbound Database" \
        "DisplayName" \
        "Outbound Database"

    WriteRegStr \
        HKLM \
        "Software\Microsoft\Windows\CurrentVersion\Uninstall\Outbound Database" \
        "UninstallString" \
        "$INSTDIR\uninstall.exe"

    WriteRegStr \
        HKLM \
        "Software\Microsoft\Windows\CurrentVersion\Uninstall\Outbound Database" \
        "DisplayVersion" \
        "0.1.0"

    WriteRegStr \
        HKLM \
        "Software\Microsoft\Windows\CurrentVersion\Uninstall\Outbound Database" \
        "Publisher" \
        "Outbound Database"

SectionEnd


Section "Uninstall"

    Delete "$SMPROGRAMS\Outbound Database\Outbound Database.lnk"

    RMDir "$SMPROGRAMS\Outbound Database"

    Delete "$DESKTOP\Outbound Database.lnk"

    DeleteRegKey \
        HKLM \
        "Software\Microsoft\Windows\CurrentVersion\Uninstall\Outbound Database"

    RMDir /r "$INSTDIR"

SectionEnd

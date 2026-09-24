; ============================================================================
; SCUM Mod Manager FD v2 - NSIS Installer Script (Bilingual: EN + SC)
; Zero-warning build. All LangStrings defined exactly once per language.
; All page text uses !define references before MUI_LANGUAGE, so MUI doesn't
; emit default LangStrings that would later be overridden.
; ============================================================================
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

; ---------------------------------------------------------------------------
; Basic info
; ---------------------------------------------------------------------------
!define APPNAME "SCUM Mod Manager"
!define APPVERSION "2.6.5"
!define APPPUBLISHER "LHuiMeng"
; 对外版（PUBLIC_BUILD）与内部版共用同一脚本：
; - 对外版：安装包名带 _public 后缀；APPURL 指向公开仓库
; - 内部版：原名；APPURL 指向开发仓库
!ifdef PUBLIC_BUILD
!define APPURL "https://github.com/LHuiMeng/SCUM-Mod-Manager-FD"
!define SETUP_OUTFILE "..\build\dist\scum_mod_manager_v${APPVERSION}_public_setup.exe"
!else
!define APPURL "https://github.com/LHuiMeng/SCUM-Mod-Manager-FD"
!define SETUP_OUTFILE "..\build\dist\scum_mod_manager_v${APPVERSION}_setup.exe"
!endif

Name "${APPNAME} v${APPVERSION}"
OutFile "${SETUP_OUTFILE}"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPNAME}" "InstallDir"
RequestExecutionLevel highest
Unicode true

; LZMA compression
SetCompressor /SOLID lzma
SetCompressorDictSize 64

; ---------------------------------------------------------------------------
; MUI configuration
; ---------------------------------------------------------------------------
!define MUI_ABORTWARNING
!define MUI_ICON "..\installer\app_icon.ico"
!define MUI_UNICON "..\installer\app_icon.ico"
!define MUI_LANGDLL_LANGUAGES "English:SimpChinese"
!define MUI_LANGDLL_REGISTRY_ROOT "HKCU"
!define MUI_LANGDLL_REGISTRY_KEY "Software\${APPNAME}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "InstallerLanguage"

!define MUI_WELCOMEPAGE_TITLE "$(WELCOME_TITLE)"
!define MUI_WELCOMEPAGE_TEXT "$(WELCOME_TEXT)"

!define MUI_FINISHPAGE_TITLE "$(FINISH_TITLE)"
!define MUI_FINISHPAGE_TEXT "$(FINISH_TEXT)"
!define MUI_FINISHPAGE_RUN "$INSTDIR\scum_mod_manager.exe"
!define MUI_FINISHPAGE_RUN_TEXT "$(FINISH_RUN)"
!define MUI_FINISHPAGE_CANCEL_ENABLED

!define MUI_UNWELCOMEPAGE_TITLE "$(UNWELCOME_TITLE)"
!define MUI_UNWELCOMEPAGE_TEXT "$(UNWELCOME_TEXT)"

!define MUI_UNCONFIRMPAGE_TEXT_TOP "$(UNCONFIRM_TEXT)"

!define MUI_UNFINISHPAGE_TITLE "$(UNFINISH_TITLE)"
!define MUI_UNFINISHPAGE_TEXT "$(UNFINISH_TEXT)"

!define MUI_TEXT_ABORTWARNING "$(ABORTWARNING)"
!define MUI_UNTEXT_ABORTWARNING "$(UNABORTWARNING)"

; ---------------------------------------------------------------------------
; Pages
; ---------------------------------------------------------------------------
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

; ---------------------------------------------------------------------------
; Languages (last one loaded = silent default)
; ---------------------------------------------------------------------------
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

; ---------------------------------------------------------------------------
; Translations
; ---------------------------------------------------------------------------

; Welcome
LangString WELCOME_TITLE ${LANG_ENGLISH} "${APPNAME} Setup Wizard"
LangString WELCOME_TITLE ${LANG_SIMPCHINESE} "${APPNAME} 安装向导"
LangString WELCOME_TEXT ${LANG_ENGLISH} \
    "This wizard will guide you through the installation of ${APPNAME}.$\r$\n$\r$\n${APPNAME} is a mod manager tool for the SCUM game, featuring a self-drawn dark military UI and a frameless window.$\r$\n$\r$\nClick Next to continue."
LangString WELCOME_TEXT ${LANG_SIMPCHINESE} \
    "本向导将引导您完成 ${APPNAME} 的安装。$\r$\n$\r$\n${APPNAME} 是 SCUM 游戏的模组管理工具,采用军事暗色主题 UI,全自绘无框窗口。$\r$\n$\r$\n点击下一步继续。"

; Finish
LangString FINISH_TITLE ${LANG_ENGLISH} "${APPNAME} Installation Complete"
LangString FINISH_TITLE ${LANG_SIMPCHINESE} "${APPNAME} 安装完成"
LangString FINISH_TEXT ${LANG_ENGLISH} \
    "${APPNAME} has been successfully installed on your computer.$\r$\n$\r$\nClick Close to exit the wizard."
LangString FINISH_TEXT ${LANG_SIMPCHINESE} \
    "${APPNAME} 已成功安装到您的电脑。$\r$\n$\r$\n点击关闭退出安装向导。"
LangString FINISH_RUN ${LANG_ENGLISH} "Launch ${APPNAME} now"
LangString FINISH_RUN ${LANG_SIMPCHINESE} "立即运行 ${APPNAME}"

; Uninstall pages
LangString UNWELCOME_TITLE ${LANG_ENGLISH} "${APPNAME} Uninstall"
LangString UNWELCOME_TITLE ${LANG_SIMPCHINESE} "${APPNAME} 卸载程序"
LangString UNWELCOME_TEXT ${LANG_ENGLISH} \
    "This wizard will uninstall ${APPNAME}.$\r$\n$\r$\nClick Next to continue."
LangString UNWELCOME_TEXT ${LANG_SIMPCHINESE} \
    "本向导将卸载 ${APPNAME}。$\r$\n$\r$\n点击下一步继续。"

LangString UNCONFIRM_TEXT ${LANG_ENGLISH} \
    "Are you sure you want to completely remove ${APPNAME} and all of its components?"
LangString UNCONFIRM_TEXT ${LANG_SIMPCHINESE} \
    "确定要完全移除 ${APPNAME} 及其所有组件吗?"

LangString UNFINISH_TITLE ${LANG_ENGLISH} "${APPNAME} Uninstalled"
LangString UNFINISH_TITLE ${LANG_SIMPCHINESE} "${APPNAME} 已卸载"
LangString UNFINISH_TEXT ${LANG_ENGLISH} \
    "${APPNAME} has been uninstalled.$\r$\n$\r$\nAll user data has been removed, including local mods (~mods) and metadata (mods_meta.json).$\r$\n$\r$\nTo preserve your game path config, please back up config.json beforehand."
LangString UNFINISH_TEXT ${LANG_SIMPCHINESE} \
    "${APPNAME} 已卸载。$\r$\n$\r$\n所有用户数据已一并删除(包括 ~mods 本地模组和 mods_meta 元数据)。$\r$\n$\r$\n如需保留游戏路径配置,请提前备份 config.json。"

; Abort warnings
LangString ABORTWARNING ${LANG_ENGLISH} \
    "Are you sure you want to cancel ${APPNAME} installation?"
LangString ABORTWARNING ${LANG_SIMPCHINESE} \
    "确定要取消 ${APPNAME} 安装吗?"
LangString UNABORTWARNING ${LANG_ENGLISH} \
    "Are you sure you want to cancel ${APPNAME} uninstallation?"
LangString UNABORTWARNING ${LANG_SIMPCHINESE} \
    "确定要取消 ${APPNAME} 卸载吗?"

; Upgrade detection
LangString UPGRADE_TITLE ${LANG_ENGLISH} "${APPNAME} Setup"
LangString UPGRADE_TITLE ${LANG_SIMPCHINESE} "${APPNAME} 安装程序"
LangString UPGRADE_TEXT ${LANG_ENGLISH} \
    "${APPNAME} is already installed at:$\r$\n$0$\r$\n$\r$\nDo you want to overwrite (upgrade) it?"
LangString UPGRADE_TEXT ${LANG_SIMPCHINESE} \
    "${APPNAME} 已经安装在:$\r$\n$0$\r$\n$\r$\n是否覆盖安装(升级)?"

; Section names
LangString SEC_MAIN ${LANG_ENGLISH} "Main Program"
LangString SEC_MAIN ${LANG_SIMPCHINESE} "主程序"
LangString SEC_DESKTOP ${LANG_ENGLISH} "Desktop Shortcut"
LangString SEC_DESKTOP ${LANG_SIMPCHINESE} "桌面快捷方式"
LangString SEC_STARTMENU ${LANG_ENGLISH} "Start Menu Shortcut"
LangString SEC_STARTMENU ${LANG_SIMPCHINESE} "开始菜单快捷方式"

; Uninstall done info
LangString UNINSTALL_DONE ${LANG_ENGLISH} "${APPNAME} has been uninstalled."
LangString UNINSTALL_DONE ${LANG_SIMPCHINESE} "${APPNAME} 已卸载。"

; ---------------------------------------------------------------------------
; .onInit: upgrade detection + language dialog
; ---------------------------------------------------------------------------
Function .onInit
  !insertmacro MUI_LANGDLL_DISPLAY
  ${IfNot} ${Silent}
    ReadRegStr $0 HKCU "Software\${APPNAME}" "InstallDir"
    ${If} $0 != ""
      MessageBox MB_YESNO|MB_ICONQUESTION \
        "$(UPGRADE_TITLE):$\r$\n$(UPGRADE_TEXT)" \
        IDYES +2
      Abort
    ${EndIf}
  ${EndIf}
FunctionEnd

; ---------------------------------------------------------------------------
; Install sections
; ---------------------------------------------------------------------------
Section "$(SEC_MAIN)" SEC_MAIN
  SectionIn RO

  ; ===== v3 架构布局（引导器 + 版本目录） =====
  ; 安装根：引导器（用户入口，永不自我替换）+ updater 兼容壳
  SetOutPath "$INSTDIR"
  File "..\build\windows\x64\runner\Release\scum_mod_manager.exe"
  File "..\build\windows\x64\runner\Release\scum_mod_manager_updater.exe"

  ; versions/<ver>/：应用本体（app exe + DLL + data/）
  SetOutPath "$INSTDIR\versions\${APPVERSION}"
  File "..\build\windows\x64\runner\Release\scum_mod_manager_app.exe"
  File "..\build\windows\x64\runner\Release\flutter_windows.dll"
  ; ★ 必须带目录名（File /r "…\data"）——带 \*.* 会平铺 data 内容，
  ;   破坏 versions/<ver>/data/ 结构（引导器与 installDownloaded 都依赖它）
  File /r "..\build\windows\x64\runner\Release\data"

  ; app.json：版本指针（引导器读它决定启动哪个版本）
  SetOutPath "$INSTDIR"
  FileOpen $0 "$INSTDIR\app.json" w
  FileWrite $0 '{"current":"${APPVERSION}"}'
  FileClose $0

  ; ★ 不清理用户数据：v3 布局用精确 File（引导器 + versions/<ver>/），
  ;   ~mods/config.json/mods_meta.json/ue4ss_runtime 等根本不进包——
  ;   覆盖升级时它们原样保留。历史教训：旧版 File /r + RMDir/Delete 清理
  ;   会在覆盖安装时误删用户配置（config.json 游戏路径等），禁止重演。

  ; Remember install path
  WriteRegStr HKCU "Software\${APPNAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APPNAME}" "Version" "${APPVERSION}"

  ; Control Panel uninstall entry
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "Publisher" "${APPPUBLISHER}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "URLInfoAbout" "${APPURL}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "NoRepair" 1

  ; Installed size (Control Panel display)
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
                 "EstimatedSize" "$0"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "$(SEC_DESKTOP)" SEC_DESKTOP
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\scum_mod_manager.exe" \
                 "" "$INSTDIR\scum_mod_manager.exe" 0
SectionEnd

Section "$(SEC_STARTMENU)" SEC_STARTMENU
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" \
                 "$INSTDIR\scum_mod_manager.exe" \
                 "" "$INSTDIR\scum_mod_manager.exe" 0
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall.lnk" \
                 "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0
SectionEnd

Section -Post
  ${If} ${Silent}
    SetRebootFlag false
  ${EndIf}
SectionEnd

; ---------------------------------------------------------------------------
; Uninstall section
; ---------------------------------------------------------------------------
Section "Uninstall"
  RMDir /r "$INSTDIR"

  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"

  DeleteRegKey HKCU "Software\${APPNAME}"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

  MessageBox MB_ICONINFORMATION|MB_OK "$(UNINSTALL_DONE)"
SectionEnd
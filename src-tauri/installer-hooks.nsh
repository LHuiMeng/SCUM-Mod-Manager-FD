!macro NSIS_HOOK_PREINSTALL
  StrCpy $R9 "$INSTDIR" 1
  StrCmp $R9 "C" scum_mod_desk_reject_c_drive
  Goto scum_mod_desk_install_path_ok

scum_mod_desk_reject_c_drive:
  MessageBox MB_ICONSTOP|MB_OK "SCUM Mod Desk 必须安装到非 C 盘的可写目录，例如 R:\SCUM Mod Desk。请返回上一步修改安装位置。"
  Abort

scum_mod_desk_install_path_ok:
!macroend

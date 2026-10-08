@echo off
title Uninstall ScriptCraft
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\ScriptCraft.lnk" 2>nul
del "%USERPROFILE%\Desktop\ScriptCraft.lnk" 2>nul
rmdir /s /q "%USERPROFILE%\Documents\ScriptCraft" 2>nul
rmdir /s /q "%LOCALAPPDATA%\ScriptCraft" 2>nul
echo Uninstalled.
timeout /t 3 >nul

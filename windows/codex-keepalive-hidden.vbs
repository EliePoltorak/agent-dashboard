' Runs codex-keepalive.ps1 without flashing a console window.
' Used by the 'Codex seat keepalive' scheduled task (every 4 min). Same pattern as app-seat-keepalive-hidden.vbs.
Dim here : here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)   ' the rotator folder: this file sits in it
CreateObject("Wscript.Shell").Run "pwsh -NoProfile -ExecutionPolicy Bypass -File """ & here & "\codex-keepalive.ps1""", 0, False

# personaltools

Small Windows utilities.

## Install-ClaudeAdminMenu.ps1

Adds a **"Run Claude as Administrator"** entry to the Windows Explorer right-click menu.
Registers a shell verb under `HKCU` (no admin rights needed to install) that appears when
you right-click empty space inside a folder, a folder itself, or a drive root. Choosing it
opens an elevated PowerShell console in that folder and starts Claude Code with Remote
Control enabled; the UAC prompt appears at that point.

```powershell
# install
powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1

# see which claude executable would be used, change nothing
powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1 -DetectOnly

# remove the menu entry and the deployed launcher
powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1 -Uninstall
```

Useful switches: `-ClaudePath` to point at a specific executable, `-Label` to change the
menu text, `-NoRemoteControl` to drop the `--remote-control` flag, and
`-NoFolderSessionName` to let Claude generate the session name instead of
`<hostname>-<folder>`.

<#
.SYNOPSIS
    Adds a "Run Claude as Administrator" entry to the Windows Explorer right-click menu.

.DESCRIPTION
    Portable installer - run it on any Windows machine. It locates the installed Claude
    Code executable, then registers a shell verb under HKCU (no admin rights needed to
    install) that appears when you:
      * right-click empty space inside a folder  (Directory\Background)
      * right-click a folder itself              (Directory)
      * right-click a drive root                 (Drive)

    Choosing it opens an elevated PowerShell console in that folder and starts Claude
    Code with Remote Control enabled. A UAC prompt appears at that point - that is where
    the elevation happens.

.PARAMETER Uninstall
    Removes the context menu entry and the deployed launcher.

.PARAMETER DetectOnly
    Report which Claude executable would be used, then exit without changing anything.

.PARAMETER ClaudePath
    Full path to the Claude executable. Auto-detected if omitted.

.PARAMETER Label
    Text shown in the context menu.

.PARAMETER NoRemoteControl
    Start Claude without Remote Control (omits the --remote-control flag).

.PARAMETER NoFolderSessionName
    Do not name the Remote Control session after the folder. By default the session
    is named "<hostname>-<folder>" so it is identifiable at a glance; with this switch
    Claude auto-generates the name instead.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1 -DetectOnly
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-ClaudeAdminMenu.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DetectOnly,
    [string]$ClaudePath,
    [string]$Label = 'Run Claude as Administrator',
    [switch]$NoRemoteControl,
    [switch]$NoFolderSessionName
)

$ErrorActionPreference = 'Stop'

$VerbName    = 'ClaudeCodeAdmin'
$LauncherDir = Join-Path $env:LOCALAPPDATA 'ClaudeContextMenu'
$Launcher    = Join-Path $LauncherDir 'Launch-ClaudeAdmin.ps1'
$Targets     = @(
    'HKCU:\Software\Classes\Directory\Background\shell',  # right-click inside a folder
    'HKCU:\Software\Classes\Directory\shell',             # right-click on a folder
    'HKCU:\Software\Classes\Drive\shell'                  # right-click on a drive
)

# ---------------------------------------------------------------- uninstall --
if ($Uninstall) {
    foreach ($root in $Targets) {
        $key = Join-Path $root $VerbName
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force
            Write-Host "Removed $key"
        }
    }
    if (Test-Path $LauncherDir) {
        Remove-Item -Path $LauncherDir -Recurse -Force
        Write-Host "Removed $LauncherDir"
    }
    Write-Host "`nDone. The context menu entry is gone." -ForegroundColor Green
    return
}

# ================================================================= detection ==

function Get-ClaudeCandidate {
    <#
        Emits candidate paths, best-first. Covers the native installer plus the
        package managers people install Claude Code through. Duplicates and
        non-existent paths are filtered out by the caller.
    #>

    # 1. Whatever is already on PATH - covers shims from any installer, and any
    #    custom location the user set up themselves.
    foreach ($name in 'claude.exe', 'claude.cmd', 'claude.bat', 'claude') {
        foreach ($c in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            if ($c.Source -and $c.CommandType -in 'Application', 'ExternalScript') { $c.Source }
        }
    }

    # 2. Known install directories, whether or not they made it onto PATH.
    $dirs = @(
        (Join-Path $env:USERPROFILE '.local\bin')                # native installer
        (Join-Path $env:LOCALAPPDATA 'Programs\claude')          # native, alt layout
        (Join-Path $env:APPDATA 'npm')                           # npm -g
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')   # winget
        (Join-Path $env:USERPROFILE 'scoop\shims')               # scoop
        (Join-Path $env:USERPROFILE '.bun\bin')                  # bun
        (Join-Path $env:LOCALAPPDATA 'pnpm')                     # pnpm
        (Join-Path $env:LOCALAPPDATA 'Yarn\bin')                 # yarn
        (Join-Path $env:ProgramData 'chocolatey\bin')            # chocolatey
        (Join-Path $env:ProgramFiles 'Claude')
        (Join-Path $env:ProgramFiles 'nodejs')
    )
    if (${env:ProgramFiles(x86)}) { $dirs += (Join-Path ${env:ProgramFiles(x86)} 'Claude') }

    foreach ($dir in $dirs) {
        if (-not $dir) { continue }
        foreach ($file in 'claude.exe', 'claude.cmd', 'claude.bat') {
            Join-Path $dir $file
        }
    }

    # 3. Last resort: ask npm where its global prefix is. Slow, which is why it
    #    comes last - the caller stops as soon as something works.
    $npm = Get-Command npm.cmd, npm -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npm) {
        try {
            $npmOut = & $npm.Source config get prefix 2>$null
            $prefix = "$($npmOut | Select-Object -First 1)".Trim()
            if ($prefix -and (Test-Path $prefix)) {
                foreach ($file in 'claude.exe', 'claude.cmd', 'claude.bat') {
                    Join-Path $prefix $file
                }
            }
        } catch { }
    }
}

function Test-ClaudeExecutable {
    param([string]$Path)
    # The only proof that matters: it runs and reports a version.
    # Capture the whole output BEFORE inspecting it - piping a native command
    # straight into Select-Object -First stops the pipeline early, and then
    # $LASTEXITCODE may never be populated for the process we just ran.
    try {
        $out  = & $Path --version 2>$null
        $code = $LASTEXITCODE
        $first = $out | Select-Object -First 1
        if ($first) { $first = "$first".Trim() }
        # Accept on a clean exit, or on anything that looks like a version
        # string - not every build is guaranteed to exit 0 for --version.
        if ($first -and ($code -eq 0 -or $first -match '\d+\.\d+')) { return $first }
    } catch { }
    return $null
}

$ClaudeVersion = $null

if ($ClaudePath) {
    if (-not (Test-Path $ClaudePath)) { throw "No such file: $ClaudePath" }
    $ClaudePath    = (Resolve-Path $ClaudePath).Path
    $ClaudeVersion = Test-ClaudeExecutable $ClaudePath
    if (-not $ClaudeVersion) {
        Write-Warning "$ClaudePath did not respond to --version; using it anyway."
    }
} else {
    Write-Host 'Looking for an installed Claude Code...'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in Get-ClaudeCandidate) {
        if (-not $candidate -or -not (Test-Path $candidate -PathType Leaf)) { continue }
        $full = (Resolve-Path $candidate).Path
        if (-not $seen.Add($full)) { continue }

        $version = Test-ClaudeExecutable $full
        if ($version) {
            $ClaudePath    = $full
            $ClaudeVersion = $version
            break
        }
        Write-Verbose "Rejected (no version response): $full"
    }
}

if (-not $ClaudePath) {
    throw ("Could not find an installed Claude Code on this machine. Install it from " +
           "https://claude.com/claude-code and re-run this script, or point it at the " +
           "executable directly:  .\Install-ClaudeAdminMenu.ps1 -ClaudePath 'C:\path\to\claude.exe'")
}

Write-Host "Found Claude: $ClaudePath" -ForegroundColor Green
if ($ClaudeVersion) { Write-Host "Version:      $ClaudeVersion" }

# Does this build support Remote Control? Older ones do not.
# Same rule as above: collect the help text first, then search it.
$SupportsRemoteControl = $false
try {
    $help = & $ClaudePath --help 2>$null
    $SupportsRemoteControl = [bool]($help | Select-String -SimpleMatch '--remote-control' -Quiet)
} catch { }

if ($DetectOnly) {
    Write-Host "Remote Control supported: $SupportsRemoteControl"
    Write-Host "`n-DetectOnly was set; nothing was changed." -ForegroundColor Yellow
    return
}

# --------------------------------------------------------------- claude args --
# 'FOLDER' is a placeholder the launcher swaps for the real folder name at runtime.
if ($NoRemoteControl) {
    $ClaudeArgs = ''
    Write-Host 'Remote Control: disabled (-NoRemoteControl)'
} elseif (-not $SupportsRemoteControl) {
    $ClaudeArgs = ''
    Write-Warning 'This Claude build has no --remote-control flag; installing without it.'
} elseif ($NoFolderSessionName) {
    $ClaudeArgs = '--remote-control'
    Write-Host 'Remote Control: enabled, session name auto-generated by Claude'
} else {
    $ClaudeArgs = "--remote-control 'FOLDER'"
    Write-Host 'Remote Control: enabled, session named <hostname>-<folder>'
}

# ------------------------------------------------------- deploy the launcher --
# A context menu verb cannot elevate itself, so it runs this small helper
# unelevated; the helper re-launches PowerShell with -Verb RunAs, which is
# what triggers the UAC prompt.
if (-not (Test-Path $LauncherDir)) { New-Item -ItemType Directory -Path $LauncherDir -Force | Out-Null }

$launcherBody = @'
param([Parameter(Mandatory = $true)][string]$Path)

# Baked in at install time; the fallback keeps the menu working if Claude is
# later upgraded into a different directory.
$claude     = '__CLAUDE_PATH__'
$claudeArgs = '__CLAUDE_ARGS__'

if (-not (Test-Path $claude)) {
    $found = Get-Command claude.exe, claude.cmd, claude -ErrorAction SilentlyContinue |
                 Where-Object { $_.Source } | Select-Object -First 1
    if ($found) { $claude = $found.Source } else { $claude = 'claude' }
}

# %V arrives without a trailing slash except at a drive root ("C:\").
$Path = $Path.Trim('"')
if (-not (Test-Path -LiteralPath $Path)) { $Path = $env:USERPROFILE }

# Remote Control session name: "<hostname>-<folder>", so a session is
# identifiable both by which machine it is on and which folder it opened in.
if ($claudeArgs -match 'FOLDER') {
    $leaf = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $Path -replace '[:\\]', '' }  # drive root
    $leaf = ($leaf -replace '[^\w\.\- ]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'session' }

    $host_ = ($env:COMPUTERNAME -replace '[^\w\.\-]', '').Trim()
    $name  = if ($host_) { "$host_-$leaf" } else { $leaf }

    $claudeArgs = $claudeArgs.Replace('FOLDER', $name)
}

# Doubling ' escapes it for the single-quoted PowerShell literals below.
$inner = "Set-Location -LiteralPath '{0}'; & '{1}' {2}" -f `
             ($Path -replace "'", "''"), ($claude -replace "'", "''"), $claudeArgs

# -EncodedCommand sidesteps every layer of command-line quoting: base64 is a
# single space-free token, so folder names with spaces, quotes or & are safe.
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

# Prefer PowerShell 7 when the machine has it; fall back to Windows PowerShell,
# which is present on every supported Windows version.
$shell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $shell) { $shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

# -NoExit keeps the console open after Claude exits, so errors stay readable
# and you are left at a prompt in the same folder.
try {
    Start-Process -FilePath $shell `
                  -ArgumentList "-NoExit -ExecutionPolicy Bypass -EncodedCommand $encoded" `
                  -WorkingDirectory $Path `
                  -Verb RunAs
} catch {
    # User dismissed the UAC prompt, or elevation was blocked by policy.
    exit 1
}
'@

# Both values land inside single-quoted PowerShell literals in the launcher, so
# any ' in them must be doubled or the generated script will not parse.
$launcherBody = $launcherBody.Replace('__CLAUDE_PATH__', $ClaudePath.Replace("'", "''")).
                              Replace('__CLAUDE_ARGS__', $ClaudeArgs.Replace("'", "''"))
Set-Content -Path $Launcher -Value $launcherBody -Encoding UTF8
Write-Host "Wrote launcher: $Launcher"

# --------------------------------------------------------- register the verb --
# The helper is always started with Windows PowerShell: it is guaranteed to
# exist, so the registry command never breaks on a machine without pwsh.
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# %V = the folder that was right-clicked (or whose background was clicked).
$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Path "%V"' -f $psExe, $Launcher

# A .cmd/.bat shim carries no icon resource, so fall back to a real .exe.
$iconSource = $ClaudePath
if ($ClaudePath -notmatch '\.exe$') {
    $sibling = Join-Path (Split-Path -Parent $ClaudePath) 'claude.exe'
    $iconSource = if (Test-Path $sibling) { $sibling } else { $psExe }
}

foreach ($root in $Targets) {
    $key    = Join-Path $root $VerbName
    $cmdKey = Join-Path $key 'command'

    New-Item -Path $cmdKey -Force | Out-Null

    Set-ItemProperty -Path $key -Name '(Default)'    -Value $Label
    Set-ItemProperty -Path $key -Name 'Icon'         -Value ('{0},0' -f $iconSource)
    Set-ItemProperty -Path $key -Name 'HasLUAShield' -Value ''      # UAC shield overlay
    Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $command

    Write-Host "Registered $key"
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Right-click inside (or on) a folder and choose: $Label"

if ([Environment]::OSVersion.Version.Build -ge 22000) {
    Write-Host "On Windows 11 this lives under 'Show more options' (or press Shift+F10)." -ForegroundColor Yellow
}
Write-Host "To remove: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"

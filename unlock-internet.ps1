# =============================================================================
#  UNLOCK INTERNET  -  zapret (DPI bypass) + TG-WS-Proxy in one terminal
#  live dashboard, colors, streaming process output
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------- fatal-error catcher: never close the window silently --------
trap {
    Write-Host ""
    Write-Host "  [FATAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
    try {
        Write-Host ("  at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line) -ForegroundColor DarkGray
    } catch {}
    try {
        Write-Host ("  script folder: {0}" -f $PSCommandPath) -ForegroundColor DarkGray
    } catch {}
    Write-Host "  Press Enter to close..." -ForegroundColor Yellow
    try { [void](Read-Host) } catch {}
    break
}

# --------------------- Run as administrator (UAC) ---------------------
$__isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__isAdmin -and -not (Test-Path Env:UNLOCK_NOUAC)) {
    $__elevArgs = @(
        '"-NoProfile"', '"-ExecutionPolicy"', '"Bypass"',
        '"-File"', '"' + (Resolve-Path $PSCommandPath).Path + '"'
    )
    try {
        Start-Process powershell.exe -ArgumentList $__elevArgs -Verb RunAs
        exit 0
    } catch {
        Write-Host ""
        Write-Host "  [ERROR] could not elevate to Administrator (UAC declined or account has no rights):" -ForegroundColor Red
        Write-Host ("    $($_.Exception.Message)") -ForegroundColor Red
        Write-Host "  Right-click the .bat and choose 'Run as administrator', or use an admin account." -ForegroundColor Yellow
        Write-Host "  Press Enter to close..." -ForegroundColor Yellow
        try { [void](Read-Host) } catch {}
        exit 1
    }
}

# ------------------------------ UTF-8 terminal ------------------------------
try { $cpi = [int]([System.Text.Encoding]::Default.CodePage)
      chcp 65001 | Out-Null
      [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
      [Console]::BackgroundColor = [System.ConsoleColor]::Black
      [Console]::ForegroundColor = [System.ConsoleColor]::White } catch {}

 # -------- Black background on each rendered frame (main thread) --------
 function Set-BlackBg { try { [Console]::BackgroundColor = [System.ConsoleColor]::Black } catch {} }

 # -------- ANSI: enable VT processing for bright green --------
 function Enable-Vt {
     try {
         # STD_OUTPUT_HANDLE = -11
         $GetConsoleMode = Add-Type -Namespace W -Name C -MemberDef '
             [System.Runtime.InteropServices.DllImport("kernel32.dll")]
             public static extern bool GetConsoleMode(IntPtr h, out uint m);
             [System.Runtime.InteropServices.DllImport("kernel32.dll")]
             public static extern bool SetConsoleMode(IntPtr h, uint m);' -PassThru
          $hOut = [IntPtr](-11)
          $mode = 0
          if ($GetConsoleMode -and $GetConsoleMode::GetConsoleMode($hOut, [ref]$mode)) {
             [void]$GetConsoleMode::SetConsoleMode($hOut, $mode -bor 0x0004)
         }
         $true
     } catch { $false }
 }
 [void](Enable-Vt)
 $BRIGHT_GREEN = "`e[92m"
 $ANSI_RESET   = "`e[0m"

# ------------------------------- Component paths -------------------------------
# Resolve everything RELATIVE to where this script actually lives, and make it work
# no matter what the current working directory is. Primary rule: zapret + tgproxy must
# be in the SAME root folder as the script (the "unlock internet" folder). Fallbacks:
# env var UNLOCK_ROOT, the current dir and its parents (e.g. launched from a subfolder).
# This keeps the tool fully move-proof as long as the folder layout stays intact.
$TestIsRoot = {
    param([string]$dir)
    if (-not $dir) { return $false }
    (Test-Path -LiteralPath (Join-Path $dir "zapret\bin\winws.exe")) -and
    (Test-Path -LiteralPath (Join-Path $dir "tgproxy\proxy\tg_ws_proxy.py"))
}
$DiscoverRoot = {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:UNLOCK_ROOT) { $cands.Add($env:UNLOCK_ROOT) }
    if ($PSCommandPath)   { $cands.Add((Split-Path -Parent $PSCommandPath)) }
    if ($PSScriptRoot)    { $cands.Add($PSScriptRoot) }
    $c = (Get-Location).Path
    while ($c) { $cands.Add($c); $c = Split-Path -Parent $c }
    $seen = @{}
    foreach ($x in $cands) {
        if (-not $x -or $seen.ContainsKey($x)) { continue }
        $seen[$x] = $true
        if (& $TestIsRoot $x) { return $x }
    }
    return $null
}
$ROOT = & $DiscoverRoot
if (-not $ROOT) {
    Write-Host ""
    Write-Host "  [ERROR] layout not found. This tool needs this folder structure:" -ForegroundColor Red
    Write-Host "    <unlock-internet folder>\   (this .ps1 + .bat)" -ForegroundColor DarkGray
    Write-Host "    <unlock-internet folder>\zapret\...\bin\winws.exe" -ForegroundColor DarkGray
    Write-Host "    <unlock-internet folder>\tgproxy\...\proxy\tg_ws_proxy.py" -ForegroundColor DarkGray
    Write-Host ("  Current dir: {0}" -f (Get-Location).Path) -ForegroundColor DarkGray
    Write-Host "  Put 'zapret' and 'tgproxy' IN the same folder as unlock-internet.ps1," -ForegroundColor Yellow
    Write-Host "  or set env UNLOCK_ROOT to the folder that contains them." -ForegroundColor Yellow
    Write-Host "  Press Enter to close..." -ForegroundColor Yellow
    try { [void](Read-Host) } catch {}
    exit 1
}
$ZAPRET     = Join-Path $ROOT "zapret"
$TGPROXY    = Join-Path $ROOT "tgproxy"
$ZAPRET_BIN = Join-Path $ZAPRET "bin"
$ZAPRET_LST = Join-Path $ZAPRET "lists"
$PROXY_PY   = Join-Path $TGPROXY "proxy\tg_ws_proxy.py"
$ZAPRET_BTS = @()
try {
    if (Test-Path -LiteralPath $ZAPRET) {
        $ZAPRET_BTS = @(Get-ChildItem -LiteralPath $ZAPRET -Filter "*.bat" -File |
                        Where-Object { $_.Name -notlike "service*" })
    }
} catch {}
$CFG_JSON   = Join-Path $env:APPDATA "TgWsProxy\config.json"
$PYCANDIDATES = @("python","py -3")

# ---- last-config + autostart ----
$LAST_CFG   = Join-Path $HOME ".unlock-internet-last.json"
$AUTO_KEY   = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$AUTO_NAME  = "UnlockInternet"
$LAST_AUTO  = Join-Path $HOME ".unlock-internet-lastauto.json"

function Get-Prop([object]$obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj.PSObject.Properties.Match($name).Count -gt 0) { return $obj.$name }
    return $null
}
function Save-LastConfig([string]$bat, [string]$hostX, [int]$portX, [string]$secret, [bool]$zapretOn, [bool]$tgOn) {
    $obj = @{
        zapretBat = $bat
        host = $hostX
        port = $portX
        secret = $secret
        zapretRunning = $zapretOn
        tgproxyRunning = $tgOn
    }
    try { $obj | ConvertTo-Json -Compress | Set-Content -LiteralPath $LAST_CFG -Encoding UTF8 } catch {}
}
function Get-LastConfigValues {
    $la = Read-LastConfig
    # Store a full path, BUT resolve by NAME against the live 'zapret' folder so the
    # tool still works after the whole folder is MOVED (old absolute path -> re-rooted).
    $batName = ""
    if ($la -and (Get-Prop $la "zapretBat")) { $batName = (Split-Path -Leaf ([string](Get-Prop $la "zapretBat"))) }
    $bat = ""
    if ($batName) {
        $cand = Join-Path $ZAPRET $batName
        if (Test-Path -LiteralPath $cand) { $bat = $cand }
        elseif (Test-Path -LiteralPath $batName) { $bat = [string]$batName }  # already absolute+valid
        else { $bat = $cand }  # keep best guess; downstream Test-Path will just skip it
    }
    $h = if ($la -and (Get-Prop $la "host")) { [string](Get-Prop $la "host") } else { "127.0.0.1" }
    $port = if ($la -and (Get-Prop $la "port")) { [int](Get-Prop $la "port") } else { 1443 }
    $secret = if ($la -and (Get-Prop $la "secret")) { [string](Get-Prop $la "secret") } else { $null }
    return @{ bat = $bat; batName = $batName; host = $h; port = $port; secret = $secret }
}
function Sync-LastConfig {
    $vals = Get-LastConfigValues
    $zOn = [bool](Get-ZapretRunning)
    $def = Get-TgProxyDefaults
    $h = if ($vals.host) { $vals.host } else { $def.host }
    $p = if ($vals.port) { [int]$vals.port } else { $def.port }
    $tOn = [bool](Get-TgProxyRunning $h $p)
    Save-LastConfig $vals.bat $vals.host $vals.port $vals.secret $zOn $tOn
    Add-Log ("[mgr] last config saved: zapret={0} tg-proxy={1}" -f $(if ($zOn) { "on" } else { "off" }), $(if ($tOn) { "on" } else { "off" })) "DarkGray"
}
function Read-LastConfig {
    if (-not (Test-Path $LAST_CFG)) { return $null }
    try { return (Get-Content -LiteralPath $LAST_CFG -Raw | ConvertFrom-Json) } catch { return $null }
}
function Get-AutoStartState {
    try {
        $v = (Get-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -ErrorAction SilentlyContinue).$AUTO_NAME
        return [bool]$v
    } catch { return $false }
}
function Set-AutoStart([bool]$on) {
    if ($on) {
        # use the DISCOVERED root so the stored path stays valid even after the
        # folder is moved (this only matters when the entry is re-created)
        $here = $ROOT
        # hidden powershell + --autostart
        $cmd = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" --autostart' -f (Join-Path $here "unlock-internet.ps1")
        try { New-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -PropertyType String -Value $cmd -Force | Out-Null
              Write-C "  added to autostart" "Cyan"; return $true } catch { Write-C ("  [X] {0}" -f $_) "Red"; return $false }
    } else {
        try { Remove-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -Force -ErrorAction Stop | Out-Null
              Write-C "  removed from autostart" "Yellow"; return $true } catch { Write-C "  autostart entry not found" "Gray"; return $true }
    }
}

# --------------------------------- Globals ---------------------------------
$Services = @{
    zapret  = $null
    tgproxy = $null
}
$Log   = New-Object System.Collections.Queue
$Spinner   = "/", "-", "\", "|"
$SpinIdx   = 0

# current action (status line under Choice)
$ActiveTask   = ""
$ActiveTaskColor = "White"

function Set-ActiveTask([string]$text, [string]$color = "White") {
    $script:ActiveTask = $text
    $script:ActiveTaskColor = $color
}

# status line under Choice: active action + live state
function Show-StatusLine {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($script:ActiveTask) { $parts.Add($script:ActiveTask) }
    if (Get-ZapretRunning) { $parts.Add("zapret running") } else { $parts.Add("zapret off") }
    $def = Get-TgProxyDefaults
    if (Get-TgProxyRunning $def.host $def.port) { $parts.Add("tg-proxy running") } else { $parts.Add("tg-proxy off") }
    $c = if ($script:ActiveTask) { $script:ActiveTaskColor } else { "Cyan" }
    Write-C ("   status: {0}" -f ($parts -join ", ")) $c
}

# ----------------------------------- Colors -----------------------------------
function Write-C([string]$text = "", [string]$color = "White") {
    try { [Console]::BackgroundColor = [System.ConsoleColor]::Black } catch {}
    Write-Host $text -ForegroundColor $color
}

# print a line from a flat text,color,text,color... array
function Write-ColorParts([object[]]$parts) {
    try { [Console]::BackgroundColor = [System.ConsoleColor]::Black } catch {}
    $i = 0
    while ($i -lt $parts.Count) {
        $txt  = [string]$parts[$i]
        $col  = [string]$parts[$i + 1]
        Write-Host $txt -NoNewline -ForegroundColor $col
        $i += 2
    }
    Write-Host ""
}

# state token: "ON"/"off" and its color
function Get-StateToken([bool]$on) {
    if ($on) { return @{ token = "[ON ]"; color = "Green"; word = "RUNNING" } }
    else     { return @{ token = "[off]"; color = "Red";   word = "stopped" } }
}

# --------- component versions (local) ---------
function Get-ZapretVersion {
    $vfile = Join-Path $ZAPRET ".version"
    if (Test-Path $vfile) {
        $v = ((Get-Content -LiteralPath $vfile | Select-Object -First 1) + "").Trim()
        if ($v) { return $v }
    }
    try {
        $fi = (Get-Item (Join-Path $ZAPRET_BIN "winws.exe")).VersionInfo
        $vv = ("{0} {1}" -f $fi.FileVersion, $fi.ProductVersion).Trim()
        if ($vv -and $vv -ne " ") { return $vv }
    } catch {}
    return "?"
}
function Get-TgProxyVersion {
    $init = Join-Path $TGPROXY "proxy\__init__.py"
    if (Test-Path $init) {
        foreach ($l in (Get-Content -LiteralPath $init | Select-Object -First 10)) {
            if ($l -match '__version__\s*=\s*"([^"]+)"') { return $Matches[1] }
        }
    }
    return "?"
}
# auto-return to menu (pause instead of pressing Enter)
function Pause-Back([int]$ms = 1200) { Start-Sleep -Milliseconds $ms }

function Get-Spin {
    $anyOn = (Get-ZapretRunning) -or
             ((Get-Process -Name "winws" -ErrorAction SilentlyContinue) -ne $null -or
              (Get-Process -Name "python","pythonw" -ErrorAction SilentlyContinue) -ne $null)
    if ($anyOn) {
        $c = $Spinner[$SpinIdx % 4]
        $SpinIdx++
        return $c
    }
    return " "
}

function Get-Uptime([object]$s) {
    if ($null -eq $s -or $null -eq $s.proc) { return "--" }
    $n = (Get-Date).Subtract([datetime]$s.started)
    if ($n.TotalHours -ge 1) { return ("{0}h {1:00}m" -f [int]$n.TotalHours, $n.Minutes) }
    if ($n.TotalMinutes -ge 1) { return ("{0}m {1:00}s" -f [int]$n.TotalMinutes, $n.Seconds) }
    return ("{0}s" -f $n.TotalSeconds)
}

function Add-Log([string]$text, [string]$color) {
    $ts = (Get-Date -Format "HH:mm:ss")
    $Log.Enqueue(@{ ts = $ts; text = $text; color = $color })
    while ($Log.Count -gt 400) { [void]$Log.Dequeue() }
}

function Hook-Streams([System.Diagnostics.Process]$p, [string]$name) {
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $tagOut = "[" + $name + "]"
    $tagErr = "[" + $name + "!]"
    Register-ObjectEvent -InputObject $p -EventName OutputDataReceived `
        -Action {
            $line = $EventArgs.Data
            if ($line) { Add-Log ("{0} {1}" -f $tagOut, $line) "Gray" }
        } -SourceIdentifier ("out_" + $p.Id) | Out-Null
    Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived `
        -Action {
            $line = $EventArgs.Data
            if ($line) { Add-Log ("{0} {1}" -f $tagErr, $line) "Red" }
        } -SourceIdentifier ("err_" + $p.Id) | Out-Null
}

# ----------------------------------- Banner -----------------------------------
function Write-Header([string]$title, [string]$color = "Cyan") {
    $fill = "-" * 44
    Write-C ("   " + $title + " " + $fill) $color
}

# current lock version: "version.txt" (semver, bumped with each release),
# fall back to the GitHub commit sha, then to the local git HEAD, else "dev".
function Get-AppVersion {
    $vFile = Join-Path $ROOT "version.txt"
    if (Test-Path $vFile) {
        $v = (Get-Content -LiteralPath $vFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v -match "^[0-9]+(\.[0-9]+)*$") { return $v }
    }
    $gitSha = $null
    $vGh = Join-Path $ROOT ".version-gh"
    if (Test-Path $vGh) {
        $v = (Get-Content -LiteralPath $vGh -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v -match "^[0-9a-fA-F]{7,}$") { $gitSha = $v.Substring(0, 10) }
    }
    $git = Join-Path $ROOT ".git"
    if (Test-Path $git) {
        try {
            $h = (& git -C $ROOT rev-parse --short HEAD 2>&1 | Out-String).Trim()
            if ($h -match "^[0-9a-fA-F]{7,}$") { $gitSha = $h }
        } catch {}
    }
    if ($gitSha) { return "dev+$gitSha" }
    return "dev"
}

function Draw-Banner {
    cls
    $ver  = Get-AppVersion
    $title = ("UNLOCK INTERNET  v{0}" -f $ver).Trim()
    $pad = " " * 4
    $bar = $title.Length + 8
    $planet = @(
        ("  +" + ("-" * $bar) + "+"),
        ("  |" + $pad + $title + $pad + "|"),
        ("  +" + ("-" * $bar) + "+")
    )
    foreach ($l in $planet) { Write-C $l "Cyan" }
    Write-C ""
}

# ----------------------------- bat-profile parser -----------------------------
function Read-ZapretProfile([string]$bat) {
    $env = @{
        BIN  = ($ZAPRET_BIN + "\")
        LISTS= ($ZAPRET_LST + "\")
    }
    $env.GameFilterTCP = "12"
    $env.GameFilterUDP = "12"
    $gameFlag = Join-Path $ZAPRET "utils\game_filter.enabled"
    if (Test-Path $gameFlag) {
        $mode = (Get-Content -LiteralPath $gameFlag | Select-Object -First 1).Trim().ToLower()
        if    ($mode -eq "all")  { $env.GameFilterTCP = "1024-65535"; $env.GameFilterUDP = "1024-65535" }
        elseif($mode -eq "tcp")  { $env.GameFilterTCP = "1024-65535" }
        elseif($mode -eq "udp")  { $env.GameFilterUDP = "1024-65535" }
    }

    $raw = @(Get-Content -LiteralPath $bat -Encoding UTF8 | ForEach-Object {
        $l = $_.TrimEnd()
        if ($l.EndsWith("^")) { $l.Substring(0, $l.Length - 1).Trim() } else { $l.Trim() }
    })
    $idx = -1
    for ($i = 0; $i -lt $raw.Count; $i++) { if ($raw[$i] -match "winws\.exe") { $idx = $i; break } }
    if ($idx -lt 0) { throw ("winws.exe not found in {0}" -f (Split-Path $bat -Leaf)) }

    $line = $raw[$idx]
    $j = $idx + 1
    while ($j -lt $raw.Count) {
        $nxt = $raw[$j]
        if ($nxt -match "^\s*$") { $j++; continue }
        if ($nxt -match "^(start|exit|goto|echo|pause)\b") { break }
        $line += " " + $nxt
        $j++
    }

    $keyNames = @("LISTS","BIN","GameFilterTCP","GameFilterUDP","GameFilter")
    $subst = {
        param($txt)
        foreach ($k in $keyNames) {
            $repl = $env[$k]
            if ($null -ne $repl) { $txt = $txt.Replace("%$k%", $repl) }
        }
        return $txt
    }

    $toks = [regex]::Split($line, "\s+") | Where-Object { $_ -ne "" }
    $out = @()
    $started = $false
    foreach ($rawTok in $toks) {
        if (-not $started) {
            if ($rawTok -match 'winws\.exe"\s*$') { $started = $true }
            continue
        }
        $t = (& $subst $rawTok)
        if ($t.StartsWith("--")) {
            $eq = $t.IndexOf("=")
            if ($eq -gt 0) {
                $key = $t.Substring(0, $eq)
                $val = $t.Substring($eq + 1)
                if ($val.Length -gt 1 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
                    $val = $val.Substring(1, $val.Length - 2)
                }
                $out += ($key + "=" + $val)
            } else {
                $out += $t
            }
        } else {
            $out += $t
        }
    }
    if ($out.Count -eq 0) { throw "parse error: no arguments extracted" }
    if ($started -eq $false) { throw "winws.exe line not matched" }
    return ,@($out)
}

function Get-ProxyPortOk([string]$hp, [int]$port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ar = $c.BeginConnect($hp, $port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(400, $false)
        if ($ok) { $c.EndConnect($ar); $c.Close(); return $true }
        $c.Close()
    } catch {}
    return $false
}

# --------- Status check by REAL system processes ---------
function Get-TgProxyDefaults {
    $h = "127.0.0.1"; $p = 1443
    if (Test-Path $CFG_JSON) {
        try {
            $cfg = Get-Content -LiteralPath $CFG_JSON -Raw | ConvertFrom-Json
            if ($cfg.host) { $h = [string]$cfg.host }
            if ($cfg.port) { $p = [int]$cfg.port }
        } catch {}
    }
    return @{ host = $h; port = $p }
}

function Get-ZapretRunning {
    # winws.exe is running OR WinDivert service is active
    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) { return $true }
    try {
        $q = (sc.exe query "WinDivert" 2>$null | Out-String)
        if ($q -match "STATE\s+4\s*:.*RUNNING") { return $true }
    } catch {}
    return $false
}

function Get-TgProxyRunning([string]$hp, [int]$port) {
    if (Get-ProxyPortOk $hp $port) { return $true }
    # python process launched with tg_ws_proxy
    foreach ($pr in (Get-Process -Name "python","pythonw" -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pr.Id) -ErrorAction SilentlyContinue).CommandLine
            if ($cmd -match "tg_ws_proxy") { return $true }
        } catch {}
    }
    return $false
}

# -------------------------------- Live dashboard --------------------------------
function Start-Dashboard {
    $sep = "-" * 69
    while ($true) {
        $zap  = $Services.zapret
        $tg   = $Services.tgproxy
        # status by REAL system processes
        $zapOk = Get-ZapretRunning
        $def   = Get-TgProxyDefaults
        $tgOk  = Get-TgProxyRunning $def.host $def.port
        $spin  = Get-Spin

        $lines = New-Object System.Collections.Generic.List[string]
        $col   = New-Object System.Collections.Generic.List[string]
        function Add-Line([string]$t, [string]$c) { $lines.Add($t); $col.Add($c) }

        $portStr = if ($tg) { [string]$tg.port } else { [string]$def.port }

        $now = (Get-Date).ToString("HH:mm:ss")
        Add-Line ("+" + $sep + "+") "Cyan"
        Add-Line ("|  UNLOCK INTERNET  {0}{1} {2}|" -f (" " * 42), $spin, $now) "Cyan"
        Add-Line ("+" + $sep + "+") "Cyan"

        $stZ = if ($zapOk) { "ACTIVE " } else { "stopped" }
        $stT = if ($tgOk) { "ACTIVE " } else { "stopped" }
        $zColor = if ($zapOk) { "Green" } else { "Red" }
        $tColor = if ($tgOk) { "Green" } else { "Red" }
        $zUps = if ($zap) { Get-Uptime $zap } else { "--" }
        $tUps = if ($tg)  { Get-Uptime $tg  } else { "--" }
        Add-Line ("|  zapret   : {0}  uptime {1}" -f $stZ, $zUps) $zColor
        Add-Line ("|  tg-proxy : {0}  uptime {1}  port={2}" -f $stT, $tUps, $portStr) $tColor
        Add-Line ("+-- LOG " + ("-" * 64) + "+") "Cyan"

        $count = [Math]::Min(16, $Log.Count)
        $tail = @()
        foreach ($entry in $Log) { $tail += $entry }
        if ($tail.Count -eq 0) {
             Add-Line ("|  (log is empty)" + (" " * 52) + "|") "DarkGray"
        }
        $shown = $tail | Select-Object -Last $count
        foreach ($entry in $shown) {
            $t = $entry.text
            if ($t.Length -gt 66) { $t = $t.Substring(0, 66) }
            Add-Line ("|  {0} {1}" -f $entry.ts, $t) $entry.color
        }
        Add-Line ("+" + $sep + "+") "Cyan"
        Add-Line ("|  [Q]uit dashboard / [Esc]   {0}{1}" -f (" " * 45), $spin) "DarkGray"
        Add-Line ("+" + $sep + "+") "Cyan"

        cls
        for ($k = 0; $k -lt $lines.Count; $k++) {
            Write-Host $lines[$k] -ForegroundColor $col[$k]
        }
        $key = $Host.UI.RawUI.ReadKey("NoEcho,ThroughPut")
        if ($key.Character -eq "q" -or $key.Character -eq "Q" -or $key.KeyCode -eq "Escape") { break }
        Start-Sleep -Milliseconds 250
    }
}

# --------------------------------- Start ---------------------------------
function Start-Zapret([string]$bat) {
    Set-ActiveTask ("starting zapret ({0})" -f (Split-Path $bat -Leaf)) "Cyan"
    $winws = Join-Path $ZAPRET_BIN "winws.exe"
    if (-not (Test-Path $winws)) {
        Write-C ("  [X] winws.exe not found: {0}" -f $winws) "Red"
        Write-C "      Run as Administrator + extracted distribution required." "Yellow"
        Set-ActiveTask "" 
        return $false
    }
    $argsArr = Read-ZapretProfile $bat
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.WorkingDirectory = $ZAPRET_BIN
    $psi.FileName = $winws
    foreach ($a in $argsArr) {
        # Re-quote values that contain spaces; without this the shell splits
        # paths like "...\unlcock internet\zapret\..." into two args and
        # winws.exe immediately exits with the list file "not found".
        $part = [string]$a
        if ($part -match '=' -and $part -match ' ' -and
            -not ($part.StartsWith('"') -and $part.EndsWith('"'))) {
            $eq = $part.IndexOf('=')
            $part = $part.Substring(0, $eq + 1) + '"' + $part.Substring($eq + 1) + '"'
        }
        $psi.Arguments += " " + $part
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    Write-C ("  starting winws.exe: {0} args, profile [{1}]" -f $argsArr.Count, (Split-Path $bat -Leaf)) "Blue"
    try {
        if (-not $p.Start()) { throw "Start() failed" }
    } catch {
        Write-C "  [X] failed to start: $_" "Red"
        Write-C "      WinDivert requires Administrator. Run launcher elevated." "Yellow"
        Set-ActiveTask "" 
        return $false
    }
    $Services.zapret = @{ proc = $p; started = (Get-Date); pid = $p.Id; bat = $bat }
    # remember profile + current state
    Sync-LastConfig
    Hook-Streams $p "zapret"
    Add-Log ("[mgr] zapret started (pid {0})" -f $p.Id) "White"
    Set-ActiveTask "" 
}

# ------------------------- check / auto-install Python -------------------------
function Refresh-Path {
    try {
        $m = [Environment]::GetEnvironmentVariable("Path","Machine")
        $u = [Environment]::GetEnvironmentVariable("Path","User")
        $env:Path = "$m;$u"
    } catch {}
}

# run a `python -c` snippet and capture output + exit code.
# relaxes $ErrorActionPreference for the duration so a native stderr write
# (e.g. a missing-module traceback) does NOT escalate to a terminating error
# under Set-StrictMode + $ErrorActionPreference='Stop'.
function Get-PyRun([string]$pyCmd, [string]$pyCode) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $out  = ""
    $exit = 1
    try {
        $out  = (& $pyCmd -c $pyCode 2>&1) -join " "
        $exit = $LASTEXITCODE
    } catch {}
    finally {
        $ErrorActionPreference = $prevEap
    }
    return [pscustomobject]@{ Out = $out; Exit = $exit }
}

# returns $true if $cmd runs a real CPython 3.x (not the Windows Store stub)
function Test-PythonCmd([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = (& $cmd -c "import sys; print(sys.version_info.major)" 2>&1) -join " "
        if ($LASTEXITCODE -eq 0 -and $out -match "3") { return $true }
    } catch {}
    return $false
}

# try to find an existing Python; if not — winget, then direct installer.
# returns the command that should be used ("python" / "py") or $null on failure
function Ensure-Python {
    Refresh-Path
    foreach ($c in @("python","py")) {
        if (Test-PythonCmd $c) { return $c }
    }
    Write-C "  [!] python not found — starting automatic install..." "Yellow"

    # 1) winget (preferred)
    $winget = $null
    if (Get-Command winget -ErrorAction SilentlyContinue) { $winget = "winget" }
    if ($winget) {
        Set-ActiveTask "installing Python via winget..." "Cyan"
        Write-C "  winget install Python.Python.3.12 (silent) ..." "Cyan"
        try {
            $p = Start-Process -FilePath $winget -ArgumentList @(
                "install","--id","Python.Python.3.12","--exact",
                "--silent","--accept-package-agreements","--accept-source-agreements"
            ) -Wait -NoNewWindow -PassThru
            Write-C ("  winget exit: {0}" -f $p.ExitCode) "Gray"
        } catch { Write-C ("  winget failed: {0}" -f $_) "Yellow" }
        Refresh-Path
        foreach ($c in @("python","py")) {
            if (Test-PythonCmd $c) {
                Write-C "  [ok] Python installed via winget" "Green"
                return $c
            }
        }
        Write-C "  winget install unavailable / failed — falling back to direct download" "Yellow"
    }

    # 2) direct installer from python.org
    Set-ActiveTask "downloading Python installer (python.org)..." "Cyan"
    $ver = "3.12.9"
    $url = "https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe"
    $tmp = Join-Path $env:TEMP ("python_installer_" + (Get-Random) + ".exe")
    try {
        Write-C "  downloading $ver (~25 MB) ..." "Cyan"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "unlock-internet")
        [void]$wc.DownloadFile($url, $tmp)

        Set-ActiveTask "installing Python silently..." "Cyan"
        Write-C "  running installer (/quiet InstallAllUsers=1 PrependPath=1) ..." "Cyan"
        $pi = Start-Process -FilePath $tmp -ArgumentList @(
            "/quiet","InstallAllUsers=1","PrependPath=1",
            "Include_launcher=1","Include_pip=1","Include_test=0","Shortcuts=1"
        ) -Wait -PassThru
        Write-C ("  installer exit: {0}" -f $pi.ExitCode) "Gray"
    } catch {
        Write-C ("  [X] Python install failed: {0}" -f $_) "Red"
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    Refresh-Path
    foreach ($c in @("python","py")) {
        if (Test-PythonCmd $c) {
            Write-C "  [ok] Python installed" "Green"
            return $c
        }
    }
    Write-C "  [X] python auto-install failed — install manually: https://www.python.org/downloads/" "Red"
    Set-ActiveTask ""
    return $null
}

# make sure a required third-party module is installed (e.g. certifi)
function Ensure-PipModule([string]$pyCmd, [string]$module) {
    $checkOut = ""
    $checkOk = $true
    try { $checkOut = (& $pyCmd -c "import $module" 2>&1) -join " "; $checkOk = ($LASTEXITCODE -eq 0) } catch { $checkOk = $false }
    if ($checkOk) { return }
    Write-C ("  [!] module '{0}' missing — pip install..." -f $module) "Yellow"
    Set-ActiveTask ("pip install {0} ..." -f $module) "Cyan"
    try {
        # ensure pip itself exists (installer with Include_pip=1 does, Store build may not)
        $pipOut = (& $pyCmd -m pip --version 2>&1) -join " "
        if ($LASTEXITCODE -ne 0) {
            Write-C "  pip not present — running ensurepip ..." "Yellow"
            [void](& $pyCmd -m ensurepip --upgrade 2>&1)
        }
        [void](& $pyCmd -m pip install --quiet --disable-pip-version-check $module 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-C ("  [ok] {0} installed" -f $module) "Green"
        } else {
            Write-C ("  [!] pip install {0} failed (proxy may still start if certifi is vendored)" -f $module) "Yellow"
        }
    } catch {
        Write-C ("  [!] pip install {0} failed: {1}" -f $module, $_) "Yellow"
    }
    Set-ActiveTask ""
}

function Start-TgProxy([string]$hostX, [int]$portX, [string]$secret) {
    Set-ActiveTask ("starting tg-proxy at {0}:{1}" -f $hostX, $portX) "Cyan"
    $pyCmd = Ensure-Python
    if ($null -eq $pyCmd) { Set-ActiveTask ""; return $false }
    Ensure-PipModule $pyCmd "certifi"

    $pyArgs = "-u proxy/tg_ws_proxy.py --host {0} --port {1}" -f $hostX, $portX
    if ($pyCmd -eq "py") { $pyArgs = "-3 " + $pyArgs }
    if ($secret) { $pyArgs += (" --secret {0}" -f $secret) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.WorkingDirectory = $TGPROXY
    $psi.FileName = $pyCmd
    $psi.Arguments = $pyArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    Write-C ("  starting tg-ws-proxy at {0}:{1}" -f $hostX, $portX) "Blue"
    try {
        if (-not $p.Start()) { throw "Start() failed" }
    } catch {
        Write-C "  [X] failed to start: $_" "Red"
        Set-ActiveTask ""
        return $false
    }
    $Services.tgproxy = @{ proc = $p; started = (Get-Date); pid = $p.Id; host = $hostX; port = $portX }
    # remember profile + current state
    Sync-LastConfig
    Hook-Streams $p "tgproxy"
    Add-Log ("[mgr] tg-proxy started at {0}:{1} (pid {2})" -f $hostX, $portX, $p.Id) "White"
    Set-ActiveTask ""
}

function Stop-Zapret {
    if (-not $script:ActiveTask) { Set-ActiveTask "stopping zapret..." "Yellow" }
    # 0) the one attached to the launcher
    Stop-Service "zapret"
    # 1) WinDivert* / zapret services (release the driver)
    foreach ($sv in @("WinDivert14", "WinDivert", "zapret")) {
        $q = ""
        try { $q = (sc.exe query $sv 2>$null | Out-String) } catch {}
        if ($q -match "STATE\s+4\s*:.*RUNNING") {
            Write-C ("  stopping service {0} ..." -f $sv) "Yellow"
            (net.exe stop $sv 2>&1 | Out-String) | Out-Null
        }
    }
    # 2) winws.exe via taskkill (reliable by name) + fallback by PID
    $w0 = @(Get-Process -Name "winws" -ErrorAction SilentlyContinue)
    if ($w0.Count -gt 0) {
        try { taskkill /F /IM "winws.exe" 2>&1 | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
        foreach ($p in (Get-Process -Name "winws" -ErrorAction SilentlyContinue)) {
            try { $p.Kill() } catch {}
        }
         Write-C ("  killed {0} winws.exe (including external)" -f $w0.Count) "Yellow"
        Add-Log ("[mgr] killed {0} winws.exe" -f $w0.Count) "Yellow"
    } else {
        Write-C "  winws.exe: none" "Gray"
    }
    # 3) final check
    Start-Sleep -Milliseconds 400
    if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
         Write-C "  [!] winws.exe is still alive — try taskkill /F /IM winws.exe manually" "Red"
    } else {
        Write-C "  zapret stopped" "Yellow"
    }
    Sync-LastConfig
}

function Stop-Tgproxy {
    # 0) the one attached to the launcher
    Stop-Service "tgproxy"
    # 1) external python/pythonw with tg_ws_proxy in the command line
    $killed = 0
    foreach ($pr in (Get-Process -Name "python","pythonw" -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pr.Id) -ErrorAction SilentlyContinue).CommandLine
            if ($cmd -match "tg_ws_proxy") {
                try { $pr.Kill(); Write-C ("  killed external tg-proxy (pid {0})" -f $pr.Id) "Yellow" } catch {}
                $killed++
            }
        } catch {}
    }
    if ($killed -eq 0) { Write-C "  tg-proxy (external): none" "Gray" }
    # 2) final check
    if (Get-TgProxyRunning (Get-TgProxyDefaults).host (Get-TgProxyDefaults).port) {
         Write-C "  [!] tg-proxy is still responding — check the port" "Red"
    } else {
        Write-C "  tg-proxy stopped" "Yellow"
    }
    Sync-LastConfig
}

function Kill-All {
    Stop-Zapret
    Write-C ""
    Stop-Tgproxy
}

function Stop-Service([string]$key) {
    $svc = $Services[$key]
    if ($null -eq $svc -or $null -eq $svc.proc) { Write-C ("  {0}: not running" -f $key) "Gray"; return }
    if ($svc.proc.HasExited) { $msg = "{0}: already exited (pid {1})" -f $key, $svc.pid }
    else {
        try {
            $svc.proc.Kill()
            $svc.proc.WaitForExit(4000) | Out-Null
            $msg = "{0}: stopped (pid {1})" -f $key, $svc.pid
        } catch { $msg = "{0}: stop failed: {1}" -f $key, $_ }
    }
    Write-C ("  " + $msg) "Yellow"
    Add-Log ("[mgr] " + $msg) "Yellow"
}

# ----------------------- unlock-internet update (GitHub) -----------------------
# the launcher repo (github.com/vp-programs/unlock-internet) is PUBLIC, so the
# updater works WITHOUT a token by default. A token is only needed if the repo
# is ever made private again; in that case the resolution order is:
#   1) gh CLI (fastest, already logged in)
#   2) token cached in %HOME%\.gh_token (silent after the first run)
#   3) interactive prompt
function Get-GhToken {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # if the repo is public, no token is needed at all
    if (Get-UiaHeadSha "") { return $null }
    # 1) cached token (no prompts at all)
    $cached = $HOME + "\.gh_token"
    if (Test-Path -LiteralPath $cached) {
        try {
            $t = (Get-Content -LiteralPath $cached -Raw).Trim()
            if ($t -and (Get-UiaHeadSha $t)) { return $t }
        } catch {}
    }
    # 2) gh CLI
    $ghPath = $null
    foreach ($cand in @("C:\Program Files\GitHub CLI\gh.exe", "gh",
                        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\gh.exe")) {
        try {
            $g = Get-Command $cand -ErrorAction SilentlyContinue
            if ($g) { $ghPath = $g.Source; break }
        } catch {}
    }
    if ($ghPath) {
        try {
            $t = (& $ghPath auth token 2>&1 | Out-String).Trim()
            if ($t -match "^[A-Za-z0-9_\-]+$" -and (Get-UiaHeadSha $t)) {
                try { Set-Content -LiteralPath $cached -Value $t -Encoding utf8 } catch {}
                return $t
            }
        } catch {}
    }
    # 3) ask the user
    Write-C "  [!] the repo is now private — a GitHub token is required." "Yellow"
    Write-C "      get one at https://github.com/settings/tokens (scope: repo)" "DarkGray"
    while ($true) {
        $t = (Read-Host "   paste token" -AsSecureString | ConvertFrom-SecureString)
        if (-not $t -or $t.Length -lt 8) { Write-C "  token too short, try again" "Red"; continue }
        if (Get-UiaHeadSha $t) {
            try { Set-Content -LiteralPath $cached -Value $t -Encoding utf8 } catch {}
            Write-C "  [ok] token saved for next time" "Green"
            return $t
        }
        Write-C "  [X] GitHub rejected that token (401/403). try another one." "Red"
    }
}

# HEAD commit of github.com/vp-programs/unlock-internet, or $null if unreachable.
# $token may be "" for public repos (no auth).
function Get-UiaHeadSha([string]$token) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $h = @{ "User-Agent" = "unlock-internet" }
        if ($token) { $h["Authorization"] = "Bearer $token" }
        $c = Invoke-RestMethod -Uri "https://api.github.com/repos/vp-programs/unlock-internet/commits/HEAD" -Headers $h -TimeoutSec 20
        return [string]$c.sha
    } catch { return $null }
}

# downloads the repo tarball at a given sha and flattens it into $dst using the
# built-in Windows tar.exe (libarchive handles .tar.gz). Creates $dst if needed.
function Sync-FolderFromTar([string]$token, [string]$sha, [string]$dst) {
    $tarExe = "tar.exe"
    if (-not (Get-Command $tarExe -ErrorAction SilentlyContinue)) { throw "tar.exe not found (Windows 10+ required)" }
    $tmp  = $env:TEMP + "\uia_" + (Get-Random)
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $tarGz = Join-Path $tmp "repo.tar.gz"
    $work  = Join-Path $tmp "extract"
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $apiBase = "https://api.github.com/repos/vp-programs/unlock-internet/tarball"
    Write-C ("  downloading latest (commit {0}...)" -f $sha.Substring(0, 10)) "Gray"
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "unlock-internet")
    if ($token) { $wc.Headers.Add("Authorization", "Bearer $token") }
    $wc.Headers.Add("Accept", "application/vnd.github+json")
    $wc.DownloadFile("$apiBase/$sha", $tarGz)
    if (-not (Test-Path $tarGz) -or (Get-Item $tarGz).Length -lt 64) { throw "download failed (empty file)" }
    Write-C ("  {0:N1} MB downloaded, extracting..." -f ((Get-Item $tarGz).Length / 1MB)) "Gray"

    & tar.exe -xzf $tarGz -C $work 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed ($LASTEXITCODE)" }
    # the tarball is wrapped in a single top dir: vp-programs-unlock-internet-<sha>/
    $topDir = (Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1).FullName
    if (-not $topDir -or -not (Test-Path $topDir)) { $topDir = $work }
    if (-not (Test-Path (Join-Path $topDir "unlock-internet.ps1"))) { $topDir = $work }

    # copy over the live root. Copy each subtree (skip .git) so we do NOT wipe
    # user files we restore afterwards.
    $copied = 0; $failed = @()
    function Copy-Rel([string]$src, [string]$rel, [string]$base, [string[]]$skip) {
        foreach ($item in (Get-ChildItem -LiteralPath (Join-Path $src $rel) -Force)) {
            $name = $item.Name
            if ($skip -contains $name) { continue }
            $subRel = if ($rel) { $rel + "\" + $name } else { $name }
            if ($item.PSIsContainer) {
                if (-not (Test-Path (Join-Path $base $subRel))) {
                    try { New-Item -ItemType Directory -Path (Join-Path $base $subRel) -Force | Out-Null } catch {}
                }
                Copy-Rel $src $subRel $base $skip
            } else {
                try {
                    $tgt = Join-Path $base $subRel
                    if (-not (Test-Path (Split-Path $tgt -Parent))) { New-Item -ItemType Directory -Path (Split-Path $tgt -Parent) -Force | Out-Null }
                    Copy-Item -LiteralPath $item.FullName -Destination $tgt -Force -ErrorAction Stop
                    $script:uCopied++
                } catch { $script:uFailed += $subRel }
            }
        }
    }
    $script:uCopied = 0; $script:uFailed = @()
    Copy-Rel $topDir "" $dst @(".git")
    $copied = [int]$script:uCopied; $failed = @($script:uFailed)

    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    return @{ copied = $copied; failed = $failed }
}

function Update-UnlockInternet {
    Set-ActiveTask "checking unlock-internet updates..." "Cyan"
    $token = Get-GhToken
    $remote = Get-UiaHeadSha $token
    if (-not $remote) {
        Write-C "  [X] cannot read repository (token invalid?)" "Red"
        Set-ActiveTask ""
        return $false
    }
    $localFile = Join-Path $ROOT ".version-gh"
    $local = ""
    if (Test-Path $localFile) { $local = (Get-Content -LiteralPath $localFile -Raw).Trim() }
    if ($local -eq $remote) {
        Write-C ("  [ok] already up to date ({0}...)" -f $remote.Substring(0, 10)) "Green"
        Add-Log ("[mgr] unlock-internet: up to date") "Green"
        Set-ActiveTask ""
        return $true
    }
    if (-not $local) { $local = "(first run)" }
    Write-C ("  local : {0}" -f $(if ($local.Length -gt 12) { $local.Substring(0, 12) + "..." } else { $local })) "Gray"
    Write-C ("  remote: {0}..." -f $remote.Substring(0, 12)) "Gray"
    $a = (Read-Host "   update? [Y/n]").Trim().ToLower()
    if ($a -and $a -ne "y" -and $a -ne "yes") {
        Write-C "  cancelled" "Yellow"
        Set-ActiveTask ""
        return $false
    }

    # ---- stop everything that holds files ----
    Write-C "  stopping services + unmounting WinDivert..." "Yellow"
    try { Stop-Zapret } catch {}
    try { Stop-Tgproxy } catch {}
    foreach ($sv in @("WinDivert14", "WinDivert")) { try { net.exe stop $sv 2>&1 | Out-Null } catch {} }
    $pwKilled = 0
    foreach ($pp in (Get-Process -Name "powershell" -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pp.Id) -ErrorAction SilentlyContinue).CommandLine
            if ($cmd -and $cmd -match "unlock-internet" -and $pp.Id -ne $PID) {
                $pp.Kill(); $pwKilled++
            }
        } catch {}
    }
    if ($pwKilled) { Write-C ("  killed {0} stray launcher process(es)" -f $pwKilled) "DarkGray" }
    Start-Sleep -Milliseconds 600

    # ---- save user files from local root ----
    $tmp = $env:TEMP + "\uia_keep" + (Get-Random)
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $keepList = @("ipset-all.txt", "list-general-user.txt", "list-exclude-user.txt", "ipset-exclude-user.txt")
    $saved = @()  # each entry: @{ dst = absolute path of the original; name = file name }
    foreach ($f in $keepList) {
        $src = Join-Path $ZAPRET_LST $f
        if (Test-Path $src) {
            $bak = Join-Path $tmp $f
            Copy-Item -LiteralPath $src -Destination $bak -Force
            $saved += @{ name = $f; bak = $bak; dst = (Join-Path $ZAPRET_LST $f) }
        }
    }
    $flagGame = Join-Path $ZAPRET "utils\game_filter.enabled"
    $flagUpd  = Join-Path $ZAPRET "utils\check_updates.enabled"
    $keepFlags = @()
    foreach ($fl in @($flagGame, $flagUpd)) {
        if (Test-Path $fl) {
            $bak = Join-Path $tmp ("flag__" + (Split-Path $fl -Leaf))
            Copy-Item -LiteralPath $fl -Destination $bak -Force
            $keepFlags += @{ dst = $fl; bak = $bak }
        }
    }

    # ---- download + extract ----
    try {
        $res = Sync-FolderFromTar $token $remote $ROOT
        if ($res.failed.Count -gt 0) {
            Write-C ("  [!] could not overwrite {0} file(s): {1}" -f $res.failed.Count, ($res.failed -join ", ")) "Yellow"
            Write-C "      they may be locked by an anti-virus or by the previous launcher instance." "DarkGray"
        }
    } catch {
        Write-C ("  [X] update failed: {0}" -f $_) "Red"
        Set-ActiveTask ""
        return $false
    }

    # ---- restore user files ----
    $restoreFailed = 0
    foreach ($s in $saved) {
        try { Copy-Item -LiteralPath $s.bak -Destination $s.dst -Force -ErrorAction Stop } catch { $restoreFailed++ }
    }
    foreach ($s in $keepFlags) {
        try { Copy-Item -LiteralPath $s.bak -Destination $s.dst -Force -ErrorAction Stop } catch { $restoreFailed++ }
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($restoreFailed -gt 0) {
        Write-C ("  [!] {0} user setting(s) could not be restored" -f $restoreFailed) "Yellow"
    }

    # ---- record the version ----
    try { Set-Content -LiteralPath $localFile -Value $remote -Encoding utf8 } catch {}

    $newVerShown = (Get-AppVersion)
    Write-C ("  [ok] unlock-internet updated to {0}... ({1} files)  ->  v{2}" -f $remote.Substring(0, 10), $res.copied, $newVerShown) "Green"
    Write-C "      restart the launcher to use the new version." "Cyan"
    Add-Log ("[mgr] unlock-internet updated to {0} (v{1})" -f $remote.Substring(0, 10), $newVerShown) "Green"
    Set-ActiveTask ""
    return $true
}

# ------------------------------ zapret auto-update ------------------------------
# downloads the latest release (zip) from Flowseal/zapret-discord-youtube,
# overwrites bin/ lists/ *.bat, preserving user files
function Get-ZapretLatest {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = "https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest"
    try {
        $json = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "unlock-internet" } -TimeoutSec 15
        $tag  = $json.tag_name
        $zip  = ($json.assets | Where-Object { $_.name -like "*.zip" } |
                   Select-Object -First 1).browser_download_url
        @{ tag = $tag; zip = $zip }
    } catch { return $null }
}

function Update-Zapret {
    Set-ActiveTask "updating zapret — fetching latest version..." "Cyan"
    $latest = Get-ZapretLatest
    if (-not $latest -or -not $latest.zip) {
         Write-C "  [X] failed to fetch latest version info (no network?)" "Red"
        Set-ActiveTask ""
        return $false
    }
    $tag = $latest.tag
    Write-C ("  latest zapret version: {0}" -f $tag) "Gray"

    # stop the launcher's zapret so it does not hold the files
    if ($Services.zapret -and $Services.zapret.proc -and -not $Services.zapret.proc.HasExited) {
         Write-C "  stopping zapret before update..." "Yellow"
        Stop-Zapret
        Start-Sleep -Milliseconds 600
    }
    $w0 = @(Get-Process -Name "winws" -ErrorAction SilentlyContinue)
    if ($w0.Count -gt 0) {
        try { taskkill /F /IM "winws.exe" 2>&1 | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
    }
    # unmount the WinDivert driver (frees winDivert64.sys in bin\)
    foreach ($sv in @("WinDivert14", "WinDivert")) {
        try { net.exe stop $sv 2>&1 | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 400

    $tmp   = $env:TEMP + "\zapret_update_" + (Get-Random)
    $zip   = $tmp + "\zapret.zip"
    $d     = $tmp + "\extract"
    New-Item -ItemType Directory -Path $d -Force | Out-Null

     # -------- live progress: single-line redraw --------
    $consoleTop = 0
    try { $consoleTop = [Console]::CursorTop } catch {}
    $canRedraw  = $true
    try { [void][Console]::SetCursorPosition(0, $consoleTop) } catch { $canRedraw = $false }

    function Draw-ProgressLine([string]$label, [int]$percent, [string]$extra = "") {
        $width = 30
        $fill  = [Math]::Max(0, [Math]::Min($width, [int]($width * $percent / 100)))
        $line = ("  {0,-12} [{1}{2}] {3,3}%{4}" -f $label, ("#" * $fill), ("-" * ($width - $fill)), $percent, $extra)
        if ($canRedraw) {
            try {
                [Console]::SetCursorPosition(0, $consoleTop)
                [Console]::Write($line.PadRight(80))
                [Console]::Out.Flush()
            } catch {}
        }
        # if redraw is unavailable — just print every 10%
        elseif ($percent % 10 -eq 0) { try { [Console]::Error.Clear() } catch {} ; Write-C ("   {0}" -f $line) "Cyan" }
    }
    function Clear-ProgressLine {
        if (-not $canRedraw) { return }
        try {
            [Console]::SetCursorPosition(0, $consoleTop)
            $bufW = [Math]::Min(90, [Console]::BufferWidth)
            [Console]::Write((" " * $bufW))
            [Console]::Out.Flush()
            # if the line did not wrap (wrap disabled) — move the cursor ourselves
            if ([Console]::CursorTop -eq $consoleTop) {
                [Console]::SetCursorPosition(0, $consoleTop + 1)
            }
        } catch {}
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Set-ActiveTask ("updating zapret — downloading {0}..." -f $tag) "Cyan"

        # streaming download with progress in one line
        $wc         = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "unlock-internet")
        $script:received   = 0
        $script:totalBytes = 0
        Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged -Action {
            $script:received   = $EventArgs.Position
            if ($EventArgs.Total -gt 0) { $script:totalBytes = $EventArgs.Total }
        } | Out-Null
        $th = $wc.DownloadFileTaskAsync($latest.zip, $zip)
        while (-not $th.IsCompleted) {
            $pct  = if ($script:totalBytes -gt 0) { [int]($script:received / $script:totalBytes * 100) } else { 0 }
            $rxMB = [Math]::Round($script:received / 1MB, 1)
            Draw-ProgressLine "download" $pct ("  {0} MB" -f $rxMB)
            Start-Sleep -Milliseconds 60
        }
        if ($th.IsFaulted) { throw ("download failed: " + $th.Exception.GetBaseException().Message) }
        if (-not (Test-Path $zip)) { throw "download failed: file not saved" }
        Clear-ProgressLine
        Unregister-Event -SourceIdentifier "DownloadProgressChanged" -ErrorAction SilentlyContinue
        $sizeMB = [Math]::Round((Get-Item $zip).Length / 1MB, 1)
        Write-C ("  downloaded {0} MB ({1})" -f $sizeMB, $tag) "Gray"

        Set-ActiveTask "updating zapret — extracting..." "Cyan"
        Draw-ProgressLine "extracting" 0 "   ..."
        Expand-Archive -LiteralPath $zip -DestinationPath $d -Force
        Clear-ProgressLine
        # the single root directory inside the zip
        $root = (Get-ChildItem -LiteralPath $d -Directory | Select-Object -First 1).FullName
        if (-not $root) { throw "root directory not found in archive" }
        if (-not (Test-Path (Join-Path $root "bin"))) { $root = $d }

        # save user files
        $saved = @()
        $keepList = @("ipset-all.txt", "list-general-user.txt", "list-exclude-user.txt", "ipset-exclude-user.txt")
        foreach ($f in $keepList) {
            $src = Join-Path $ZAPRET_LST $f
            if (Test-Path $src) {
                $dst = $tmp + "\keep_" + $f
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $saved += ($f, $dst)
            }
        }
        $gameFlag = Join-Path $ZAPRET "utils\game_filter.enabled"
        $keepGame = $null
        if (Test-Path $gameFlag) {
            $keepGame = $tmp + "\keep_game_filter.enabled"
            Copy-Item -LiteralPath $gameFlag -Destination $keepGame -Force
        }

        Set-ActiveTask "updating zapret — replacing files..." "Cyan"
        $locked = New-Object System.Collections.Generic.List[string]
        # copy files over existing ones (no Remove-Item — safe for locked files)
        function Copy-Tree([string]$src, [string]$dst, [System.Collections.Generic.List[string]]$locked) {
            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            foreach ($dir in (Get-ChildItem -LiteralPath $src -Directory)) {
                Copy-Tree $dir.FullName (Join-Path $dst $dir.Name) $locked
            }
            foreach ($file in (Get-ChildItem -LiteralPath $src -File)) {
                $target = Join-Path $dst $file.Name
                try { Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop }
                catch { $locked.Add($file.Name) }
            }
        }
        Copy-Tree (Join-Path $root "bin")  (Join-Path $ZAPRET "bin")  $locked
        Copy-Tree (Join-Path $root "lists") (Join-Path $ZAPRET "lists") $locked
        if (Test-Path (Join-Path $root "utils")) { Copy-Tree (Join-Path $root "utils") (Join-Path $ZAPRET "utils") $locked }
        # *.bat + LICENSE
        Get-ChildItem -LiteralPath $root -Filter "*.bat" | ForEach-Object {
            try { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ZAPRET $_.Name) -Force -ErrorAction Stop }
            catch { $locked.Add($_.Name) }
        }
        if (Test-Path (Join-Path $root "LICENSE.txt")) {
            try { Copy-Item -LiteralPath (Join-Path $root "LICENSE.txt") -Destination (Join-Path $ZAPRET "LICENSE.txt") -Force -ErrorAction Stop }
            catch { $locked.Add("LICENSE.txt") }
        }

        # restore user files
        for ($i = 0; $i -lt $saved.Count; $i += 2) {
            Copy-Item -LiteralPath $saved[$i + 1] -Destination (Join-Path $ZAPRET_LST $saved[$i]) -Force
        }
        if ($keepGame) {
            New-Item -ItemType Directory -Path (Split-Path $gameFlag -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $keepGame -Destination $gameFlag -Force
        }

        if ($locked.Count -gt 0) {
             Write-C ("  [!] failed to replace {0} locked file(s): {1}" -f $locked.Count, ($locked -join ", ")) "Yellow"
             Write-C "      reboot the system and retry the update (WinDivert driver held the file)" "DarkGray"
         } else {
             Write-C ("  [ok] zapret updated to {0}" -f $tag) "Green"
        }
         Add-Log ("[mgr] zapret updated to {0} ({1} locked)" -f $tag, $locked.Count) "Green"
        try { Set-Content -LiteralPath (Join-Path $ZAPRET ".version") -Value $tag -Encoding UTF8 } catch {}
        if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        return $true
    }
    catch {
         Write-C ("  [X] update failed: {0}" -f $_) "Red"
        Add-Log ("[mgr] zapret update FAILED: {0}" -f $_) "Red"
        return $false
    }
    finally {
        Set-ActiveTask ""
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------- tg-proxy diagnostics -------------------------
# runs the proxy modules in a clean Python process and prints exactly where it
# fails (missing Python, missing module, import error, ...). Safe: read-only.
function Diagnose-TgProxy {
    Set-ActiveTask "diagnosing tg-proxy..." "Cyan"
    Write-C ""

    # 1) python present at all?
    Refresh-Path
    $pyCmd = $null
    foreach ($c in @("python","py")) {
        if (Test-PythonCmd $c) { $pyCmd = $c; break }
    }
    if (-not $pyCmd) {
        Write-C "  [X] PYTHON NOT FOUND. tg-proxy needs CPython 3.x." "Red"
        Write-C "      install: https://www.python.org/downloads/  (tick 'Add python.exe to PATH')" "Yellow"
        Set-ActiveTask ""
        Pause-Back
        return
    }
    $verLine = (Get-PyRun $pyCmd "import sys; print('python %s at %s' % (sys.version.split()[0], sys.executable))").Out.Trim()
    Write-C ("  [ok] {0}" -f $verLine) "Green"

    # 2) required modules importable?
    $modules = @("certifi","ssl","asyncio","socket")
    $optMods = @("cryptography")
    $missed = @()
    foreach ($m in $modules) {
        $r = Get-PyRun $pyCmd "import $m; print('ok')"
        if ($r.Exit -ne 0 -or $r.Out -notmatch "ok") { $missed += $m }
    }
    if ($missed.Count -gt 0) {
        Write-C ("  [X] MISSING MODULES: {0}" -f ($missed -join ", ")) "Red"
        Write-C "      run:  {0} -m pip install certifi" -f $pyCmd "Yellow"
    } else {
        Write-C "  [ok] required modules present (certifi, ssl, asyncio)" "Green"
    }
    foreach ($m in $optMods) {
        $r = Get-PyRun $pyCmd "import $m; print('ok')"
        if ($r.Exit -ne 0 -or $r.Out -notmatch "ok") {
            Write-C ("  [!] optional '{0}' missing (uses ctypes fallback, ok)" -f $m) "DarkYellow"
        } else { Write-C ("  [ok] optional '{0}'" -f $m) "Green" }
    }

    # 3) actually import the proxy package (catches code import errors)
    # write a temp .py (paths with spaces are fine in a file, unlike `python -c`)
    $dprobe = $env:TEMP + "\tgdiag_" + (Get-Random)
    New-Item -ItemType Directory -Path $dprobe -Force | Out-Null
    $impPy = Join-Path $dprobe "import_probe.py"
    $impLines = @(
        'import sys, traceback',
        ('sys.path.insert(0, r"{0}")' -f $TGPROXY),
        'try:',
        '    import proxy.tg_ws_proxy',
        '    print("IMPORT_OK")',
        'except Exception:',
        '    print("IMPORT_FAIL")',
        '    traceback.print_exc()'
    )
    Set-Content -LiteralPath $impPy -Value ($impLines -join "`r`n") -Encoding ASCII
    Write-C "  [..] importing proxy.tg_ws_proxy ..." "Gray"
    $impOut = (& $pyCmd $impPy 2>&1) | Out-String
    if ($impOut -match "IMPORT_OK") {
        Write-C "  [ok] proxy module imports cleanly" "Green"
    } else {
        Write-C "  [X] proxy module import FAILED:" "Red"
        ($impOut -split "`r?`n") | ForEach-Object { if ($_.Trim()) { Write-C ("      {0}" -f $_.TrimStart()) "DarkGray" } }
    }

    # 4) can we bind the port?
    $def = Get-TgProxyDefaults
    Write-C ("  [..] testing bind port {0} ..." -f $def.port) "Gray"
    $bindPy = Join-Path $dprobe "bind_probe.py"
    $bindLines = @(
        'import socket',
        's = socket.socket(socket.AF_INET, socket.SOCK_STREAM)',
        's.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)',
        'try:',
        ('    s.bind(("{0}", {1}))' -f $def.host, $def.port),
        '    print("BIND_OK")',
        'except Exception as e:',
        '    print("BIND_FAIL " + str(e))',
        'finally:',
        '    s.close()'
    )
    Set-Content -LiteralPath $bindPy -Value ($bindLines -join "`r`n") -Encoding ASCII
    $bindOut = (& $pyCmd $bindPy 2>&1) | Out-String
    if ($bindOut -match "BIND_OK") { Write-C "  [ok] port $($def.port) is free/bindable" "Green" }
    else {
        Write-C ("  [X] CANNOT BIND port {0}:  {1}" -f $def.port, ($bindOut.Trim() -replace "`r?`n", " ")) "Red"
        Write-C "      port busy or blocked. close the app holding it, or change the port." "Yellow"
    }

    if (Test-Path $dprobe) { Remove-Item $dprobe -Recurse -Force -ErrorAction SilentlyContinue }

    Set-ActiveTask ""
    Write-C ""
    Pause-Back
}

# ------------------------- zapret settings (from service.bat) -------------------------
# game filter: utils\game_filter.enabled  (all | tcp | udp | missing=off)
function Get-ZGameFilterState {
    $flag = Join-Path $ZAPRET "utils\game_filter.enabled"
    if (-not (Test-Path $flag)) { return @{ state = "disabled"; mode = "" } }
    $m = ((Get-Content -LiteralPath $flag | Select-Object -First 1) + "").Trim().ToLower()
    switch ($m) {
        "all" { return @{ state = "enabled (TCP+UDP)"; mode = "all" } }
        "tcp" { return @{ state = "enabled (TCP)";     mode = "tcp" } }
        default { return @{ state = "enabled (UDP)";  mode = "udp" } }
    }
}
function Set-ZGameFilter([string]$mode) {
    $flag = Join-Path $ZAPRET "utils\game_filter.enabled"
    $dir = Split-Path $flag -Parent
    if ($mode -eq "") {
        if (Test-Path $flag) { Remove-Item -LiteralPath $flag -Force }
    } else {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath $flag -Value $mode -Encoding ASCII
    }
}

# ipset filter: lists\ipset-all.txt (loaded | none | any)
function Get-ZIpsetFilterState {
    $f = Join-Path $ZAPRET_LST "ipset-all.txt"
    if (-not (Test-Path $f)) { return @{ state = "any";       mode = "any" } }
    $lines = @(Get-Content -LiteralPath $f | Where-Object { ($_ + "").Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { return @{ state = "any"; mode = "any" } }
    $raw = (Get-Content -LiteralPath $f -Raw) + ""
    if ($raw -match "203\.0\.113\.113/32") { return @{ state = "none"; mode = "none" } }
    return @{ state = "loaded"; mode = "loaded" }
}
function Set-ZIpsetFilter([string]$mode) {
    $f = Join-Path $ZAPRET_LST "ipset-all.txt"
    $bak = $f + ".backup"
    switch ($mode) {
        "none" {
            if (Test-Path $bak) { Remove-Item -LiteralPath $bak -Force }
            if (Test-Path $f)  { Move-Item -LiteralPath $f -Destination $bak -Force }
            Set-Content -LiteralPath $f -Value "203.0.113.113/32" -Encoding ASCII
        }
        "any" {
            Set-Content -LiteralPath $f -Value "" -Encoding ASCII
        }
        "loaded" {
            if (Test-Path $bak) {
                if (Test-Path $f) { Remove-Item -LiteralPath $f -Force }
                Move-Item -LiteralPath $bak -Destination $f -Force
            } else {
                return $false
            }
        }
    }
    return $true
}

# auto-update check: utils\check_updates.enabled
function Get-ZCheckUpdatesState {
    $flag = Join-Path $ZAPRET "utils\check_updates.enabled"
    $on = Test-Path $flag
    return @{ state = $(if ($on) { "enabled" } else { "disabled" }); on = $on }
}
function Set-ZCheckUpdates([bool]$on) {
    $flag = Join-Path $ZAPRET "utils\check_updates.enabled"
    if ($on) {
        New-Item -ItemType Directory -Path (Split-Path $flag -Parent) -Force | Out-Null
        Set-Content -LiteralPath $flag -Value "ENABLED" -Encoding ASCII
    } elseif (Test-Path $flag) {
        Remove-Item -LiteralPath $flag -Force
    }
}

# run a native command without $ErrorActionPreference='Stop' turning its stderr
# into a terminating error; returns captured output + exit code.
function Invoke-Native {
    param([string]$exe, [string[]]$exeArgs = @())
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $out = ""; $code = 1
    try { $out = (& $exe @exeArgs 2>&1 | Out-String); $code = $LASTEXITCODE } catch {}
    finally { $ErrorActionPreference = $prevEap }
    return [pscustomobject]@{ Out = $out; Code = $code }
}

# replace the ACTIVE_* UDP fake with another .bin from bin\
function Replace-ActiveFakes {
    $disc = Join-Path $ZAPRET_BIN "ACTIVE_DISCORD_UDP.bin"
    $game = Join-Path $ZAPRET_BIN "ACTIVE_GAME_UDP.bin"
    $fakes = @(Get-ChildItem -LiteralPath $ZAPRET_BIN -Filter "*.bin" -File -ErrorAction SilentlyContinue |
               Where-Object { $_.BaseName -notlike "ACTIVE_*" } | Sort-Object Name)
    if ($fakes.Count -eq 0) {
        Write-C "  [X] no .bin fake files in bin\" "Red"
        Write-C "      (download a zapret release that ships fake .bin files)" "Yellow"
        Pause-Back
        return
    }
    $discHash = $(if (Test-Path $disc) { (Get-FileHash -LiteralPath $disc -Algorithm SHA256).Hash } else { $null })
    $gameHash = $(if (Test-Path $game) { (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash } else { $null })
    $curDisc = "not found"; $curGame = "not found"
    foreach ($f in $fakes) {
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        if ($h -eq $discHash) { $curDisc = $f.Name }
        if ($h -eq $gameHash) { $curGame = $f.Name }
    }

    $done = $false
    while (-not $done) {
        Write-C ""
        Write-C "  Fake types:" "Cyan"
        Write-C ("    1. Discord UDP     (current: {0})" -f $curDisc) "White"
        Write-C ("    2. GameFilter UDP  (current: {0})" -f $curGame) "White"
        Write-C "  Fake files:" "Cyan"
        $i = 0
        foreach ($f in $fakes) { $i++; Write-C ("    {0}. {1}" -f $i, $f.Name) "White" }
        Write-C ""
        Write-C "  Enter 'type number'  (e.g. 1 4)   or   0 to exit" "Gray"
        $sel = (Read-Host "  Choice").Trim()
        if ($sel -eq "0" -or $sel -eq "") { $done = $true; break }
        $parts = @($sel -split "\s+" | Where-Object { $_ -ne "" })
        if ($parts.Count -lt 2) {
            Write-C "  need 'type number'" "Yellow"; Pause-Back; continue
        }
        $t = $parts[0]; $n = $parts[1]
        if ($t -notmatch "^[12]$" -or $n -notmatch "^\d+$") {
            Write-C "  invalid choice" "Yellow"; Pause-Back; continue
        }
        $idx = [int]$n
        if ($idx -lt 1 -or $idx -gt $fakes.Count) {
            Write-C "  bad file number" "Yellow"; Pause-Back; continue
        }

        if    ($t -eq "1") { $active = $disc } else { $active = $game }
        $src = $fakes[$idx - 1].FullName
        try {
            Copy-Item -LiteralPath $src -Destination $active -Force
            Write-C ("  [ok] {0} = {1}" -f (Split-Path $active -Leaf), (Split-Path $src -Leaf)) "Green"
            if    ($t -eq "1") { $curDisc = $fakes[$idx - 1].Name }
            else               { $curGame = $fakes[$idx - 1].Name }
            Write-C "      restart zapret to apply" "DarkGray"
        } catch { Write-C ("  [X] {0}" -f $_) "Red" }
        Pause-Back
    }
}

# environment / conflict diagnostics (ported from service.bat p.11)
function Diagnose-Zapret {
    Set-ActiveTask "diagnosing zapret environment..." "Cyan"
    Write-C ""

    $r = Invoke-Native "sc.exe" @("query", "BFE")
    if ($r.Out -match "RUNNING") { Write-C "  [ok] Base Filtering Engine: running" "Green" }
    else                         { Write-C "  [X] Base Filtering Engine NOT running (required)" "Red" }

    $r = Invoke-Native "netsh" @("interface", "tcp", "show", "global")
    $tsLine = (@($r.Out -split "`n" | Where-Object { $_ -match "Timestamp|timestamp" }) | Select-Object -First 1) + ""
    if ($tsLine -match "enabled") { Write-C "  [ok] TCP timestamps: enabled" "Green" }
    else {
        Write-C "  [?] TCP timestamps disabled — enabling..." "Yellow"
        $r = Invoke-Native "netsh" @("interface", "tcp", "set", "global", "timestamps=enabled")
        if ($r.Code -eq 0) { Write-C "  [ok] TCP timestamps enabled" "Green" }
        else               { Write-C "  [X] failed to enable TCP timestamps" "Red" }
    }

    $px = $null
    try { $px = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop } catch {}
    if ($px -and [int]$px.ProxyEnable -eq 1) {
        Write-C ("  [?] System proxy enabled: {0} (make sure it's valid)" -f $px.ProxyServer) "Yellow"
    } else { Write-C "  [ok] System proxy: off" "Green" }

    $allSvc = (Invoke-Native "sc.exe" @("query")).Out

    if (Get-Process -Name "AdguardSvc" -ErrorAction SilentlyContinue) {
        Write-C "  [X] Adguard running — may conflict with Discord" "Red"
    } else { Write-C "  [ok] Adguard: not running" "Green" }

    $conflicts = @("Killer", "TracSrvWrapper", "EPWD", "SmartByte", "GoodbyeDPI", "discordfix_zapret", "winws1", "winws2")
    $found = @()
    foreach ($bad in $conflicts) { if ($allSvc -match $bad) { $found += $bad } }
    if ($found.Count -gt 0) { Write-C ("  [X] conflicting service(s): {0}" -f ($found -join ", ")) "Red" }
    else                    { Write-C "  [ok] no conflicting bypass services" "Green" }

    if ($allSvc -match "Intel" -and $allSvc -match "Connectivity" -and $allSvc -match "Network") {
        Write-C "  [?] Intel Connectivity Network Service found — may conflict with zapret" "Yellow"
    }
    if ($allSvc -match "VPN") {
        Write-C "  [?] VPN service(s) present — disable all VPNs before testing" "Yellow"
    } else { Write-C "  [ok] no VPN services" "Green" }

    try {
        $doh = @((Get-ChildItem "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters" -ErrorAction SilentlyContinue |
                  Get-ItemProperty -ErrorAction SilentlyContinue) | Where-Object { $_.DohFlags -gt 0 })
        if ($doh.Count -gt 0) { Write-C "  [?] Secure DNS (DoH) configured — verify it still works" "Yellow" }
        else                  { Write-C "  [ok] Secure DNS (DoH): none" "Green" }
    } catch { Write-C "  [ok] Secure DNS check: skipped" "Green" }

    if ($ZAPRET -match "OneDrive") { Write-C "  [X] zapret is in a OneDrive folder — move to e.g. C:\zapret" "Red" }
    if ($ZAPRET -match "[\u0400-\u04FF]") { Write-C "  [?] zapret path has Cyrillic characters — may break some tools" "Yellow" }

    if (Get-ChildItem -LiteralPath $ZAPRET_BIN -Filter "*.sys" -ErrorAction SilentlyContinue) {
        Write-C "  [ok] WinDivert driver present" "Green"
    } else {
        Write-C "  [X] WinDivert64.sys NOT found in bin" "Red"
    }

    Set-ActiveTask ""
    Write-C ""
    Pause-Back
}

# run the bundled configuration tests in a separate window
function Run-ZapretTests {
    $test = Join-Path $ZAPRET "utils\test zapret.ps1"
    if (-not (Test-Path $test)) {
        Write-C "  [X] utils\test zapret.ps1 not found" "Red"
        Pause-Back
        return
    }
    Write-C ("  launching: {0}" -f (Split-Path $test -Leaf)) "Cyan"
    try {
        Start-Process "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$test`""
    } catch { Write-C ("  [X] {0}" -f $_) "Red" }
    Pause-Back
}

# ------------------------- UAC: minimize -------------------------
# removes the Y/N elevation prompts (since running as admin).
# Does NOT enable the full secure desktop. Restart processes / the system
# so old processes pick up the new policy.
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
      ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Set-UacMin {
    if (-not (Test-Admin)) {
         Write-C "   [X] administrator privileges required" "Red"
        return $false
    }
    $k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    try {
        Set-ItemProperty -Path $k -Name "ConsentPromptBehaviorAdmin"  -Value 0
        Set-ItemProperty -Path $k -Name "PromptOnSecureDesktop"     -Value 0
        Set-ItemProperty -Path $k -Name "EnableUIA"                 -Value 1
        Set-ItemProperty -Path $k -Name "ConsentPromptBehaviorNonadmin" -Value 0
         Write-C "   [ok] UAC minimized (no more Y/N prompts)" "Cyan"
         Write-C "        restart programs / the system for the policy to take effect" "DarkGray"
        return $true
    } catch {
        Write-C ("   [X] {0}" -f $_) "Red"
        return $false
    }
}

# ------------------------- zapret settings submenu -------------------------
function Show-ZapretSettings {
    while ($true) {
        cls
        Draw-Banner
        $zg  = Get-ZGameFilterState
        $zi  = Get-ZIpsetFilterState
        $zcu = Get-ZCheckUpdatesState
        Write-Header "ZAPRET SETTINGS" "Magenta"
        Write-C ("   [1] Game Filter        (current: {0})" -f $zg.state) "White"
        Write-C ("   [2] IPSet Filter       (current: {0})" -f $zi.state) "White"
        Write-C ("   [3] Auto-Update Check  (current: {0})" -f $zcu.state) "White"
        Write-C "   [4] Replace active fakes (.bin)" "White"
        Write-C "   [5] Diagnose zapret environment (conflicts)" "White"
        Write-C "   [6] Run zapret tests (utils)" "White"
        Write-C ""
        Write-C "   [0] Back to main menu" "Yellow"
        Write-C ""
        $sel = (Read-Host "   Choice").Trim()
        switch ($sel) {
            "1" {
                Write-C ""
                Write-C ("  current: {0}" -f (Get-ZGameFilterState).state) "Gray"
                Write-C "    [0] Off" "White"
                Write-C "    [1] TCP + UDP" "White"
                Write-C "    [2] TCP only" "White"
                Write-C "    [3] UDP only" "White"
                $c = (Read-Host "  Choice").Trim()
                $map = @{ "0"=""; "1"="all"; "2"="tcp"; "3"="udp" }
                if ($map.ContainsKey($c)) {
                    Set-ZGameFilter $map[$c]
                    Write-C ("  [ok] game filter: {0}" -f $(if ($map[$c]) { (Get-ZGameFilterState).state } else { "off" })) "Green"
                    Write-C "      restart zapret to apply" "DarkGray"
                } else { Write-C "  invalid" "Red" }
                Pause-Back
            }
            "2" {
                Write-C ""
                Write-C ("  current: {0}" -f (Get-ZIpsetFilterState).state) "Gray"
                Write-C "    [1] loaded (specific IPs)" "White"
                Write-C "    [2] none (bypass nothing by IP)" "White"
                Write-C "    [3] any (bypass all by IP)" "White"
                $c = (Read-Host "  Choice").Trim()
                $map = @{ "1"="loaded"; "2"="none"; "3"="any" }
                if ($map.ContainsKey($c)) {
                    [void](Set-ZIpsetFilter $map[$c])
                    Write-C ("  [ok] ipset filter: {0}" -f (Get-ZIpsetFilterState).state) "Green"
                    Write-C "      restart zapret to apply" "DarkGray"
                } else { Write-C "  invalid" "Red" }
                Pause-Back
            }
            "3" {
                $st = Get-ZCheckUpdatesState
                $on = -not $st.on
                Set-ZCheckUpdates $on
                $lbl = if ($on) { "enabled" } else { "disabled" }
                Write-C ("  [ok] auto-update check: {0}" -f $lbl) "Green"
                Pause-Back
            }
            "4" {
                Replace-ActiveFakes
            }
            "5" {
                Diagnose-Zapret
            }
            "6" {
                Run-ZapretTests
            }
            "0" { return }
            default { if ($sel -ne "") { Write-C "  invalid choice" "Red"; Start-Sleep 1 } }
        }
    }
}

# ----------------------------------- Menu -----------------------------------
function Main {
    $Host.UI.RawUI.WindowTitle = "UNLOCK INTERNET"

    # on program start — auto-launch zapret + tg-proxy from last config
    if ((Read-LastConfig) -ne $null) {
         Write-C "   [auto] restoring last config (zapret + tg-proxy)..." "Cyan"
        Invoke-AutoLaunch
    }

    while ($true) {
        cls
        Draw-Banner
        # status by REAL system processes
        $zOn = Get-ZapretRunning
        $def = Get-TgProxyDefaults
        $tOn = Get-TgProxyRunning $def.host $def.port
        $zMine = $Services.zapret -and $Services.zapret.proc -and -not $Services.zapret.proc.HasExited
        $tMine = $Services.tgproxy -and $Services.tgproxy.proc -and -not $Services.tgproxy.proc.HasExited
        $zPid = if ($zMine) { "  pid {0}  up {1}" -f $Services.zapret.pid, (Get-Uptime $Services.zapret) } else { "  (external)" }
        $tExt = if (-not $tMine) { "  (external)" } else { "" }
        $tHost = if ($tMine) { $Services.tgproxy.host } else { $def.host }
        $tPort = if ($tMine) { $Services.tgproxy.port } else { $def.port }
         Write-Header "SERVICES" "Cyan"
        $colW = 30  # the column where the version starts (same for both services)
        $stZ = Get-StateToken $zOn
        $zVer = Get-ZapretVersion
        $zTail = ("  {0}{1}" -f $stZ.word, $zPid).PadRight($colW) + "  v" + $zVer
        Write-ColorParts @("   ZAPRET   : ", "White", $stZ.token, $stZ.color, $zTail, "White")
        $stT = Get-StateToken $tOn
        $tVer = Get-TgProxyVersion
        $tBody = if ($tOn) { "  {0}  {1}:{2}" -f $stT.word, $tHost, $tPort } else { "  {0}" -f $stT.word }
        $tTail = $tBody.PadRight($colW) + "  v" + $tVer
        Write-ColorParts @("   TG-PROXY : ", "White", $stT.token, $stT.color, $tTail, "White")
        Write-C ""
        Write-Header "UNLOCK INTERNET SETTINGS" "Magenta"
        $auto = Get-AutoStartState
        $stA = Get-StateToken $auto
        if ($auto) { $aTail = "  enabled (launch with Windows)" }
        else       { $aTail = "  disabled" }
         Write-ColorParts @("   AUTOSTART : ", "White", $stA.token, $stA.color, $aTail, "White")
         $lc = Read-LastConfig
        $lastDesc = "none"
        if ($lc) {
            $zRaw = Get-Prop $lc "zapretRunning"
            $tRaw = Get-Prop $lc "tgproxyRunning"
            $zState = if ($null -eq $zRaw) { "?" } elseif ($zRaw) { "ON" } else { "OFF" }
            $tState = if ($null -eq $tRaw) { "?" } elseif ($tRaw) { "ON" } else { "OFF" }
            $lbat = [string](Get-Prop $lc "zapretBat")
            $lhost = [string](Get-Prop $lc "host")
            $lport = [int](Get-Prop $lc "port")
            $leaf = if ($lbat) { (Split-Path $lbat -Leaf) } else { "no-bat" }
            $lastDesc = ("{0}  +  {1}:{2}" -f $leaf, $lhost, $lport)
            $lastDesc += ("  [zapret {0} | tg-proxy {1}]" -f $zState, $tState)
        }
        Write-C ("   LAST CONF: {0}" -f $lastDesc) "Gray"
        Write-C ""
        Write-Header "ZAPRET SETTINGS" "Magenta"
         $zg = Get-ZGameFilterState
         $gOn = $zg.state -ne "disabled"
         $stG = Get-StateToken $gOn
         Write-ColorParts @("   GAME FILT : ", "White", $stG.token, $stG.color, ("  {0}" -f $zg.state), "White")
         $zi = Get-ZIpsetFilterState
         $stI = Get-StateToken ($zi.state -ne "none")
         Write-ColorParts @("   IPSET     : ", "White", $stI.token, $stI.color, ("  {0}" -f $zi.state), "White")
         $zcu = Get-ZCheckUpdatesState
         $stC = Get-StateToken $zcu.on
         Write-ColorParts @("   AUTOPDATE : ", "White", $stC.token, $stC.color, ("  {0}" -f $zcu.state), "White")
        Write-C ""
        Write-Header "ACTIONS" "White"
        Write-C "   -- services --" "DarkGray"
        Write-C "   [1] Launch ZAPRET  (choose bat-profile)" "Cyan"
        Write-C "   [2] Launch TG-PROXY" "Cyan"
        Write-C "   [3] Stop ZAPRET     (incl. external)" "Yellow"
        Write-C "   [4] Stop TG-PROXY   (incl. external)" "Yellow"
        Write-C ("   [5] Stop everything  (zapret + tg-proxy)") "DarkYellow"
        Write-C "   -- settings --" "DarkGray"
        if ($auto) { Write-C "   [6] Remove from autostart" "White" }
        else       { Write-C "   [6] Launch with Windows (autostart)" "White" }
        Write-C "   [7] UAC: minimize (no Y/N prompts)" "White"
        Write-C "   [8] ZAPRET SETTINGS  (menu of zapret options)" "White"
         Write-C "   -- tools --" "DarkGray"
         Write-C "   [9] Diagnose tg-proxy (why it won't start)" "White"
          Write-C "   [10] Update ZAPRET (download latest release)" "Cyan"
         Write-C "   [11] Update unlock-internet (from GitHub)" "Cyan"
          Write-C "   [12] Live dashboard (Q/Esc to exit)" "Gray"
          Write-C "   -- exit --" "DarkGray"
        Write-C "   [0] Quit" "White"
        Write-C ""
        $sel = (Read-Host "   Choice").Trim()

        switch -Wildcard ($sel) {
            "1" {
                if ($zOn) {
                     Write-C "  zapret is already running" "Yellow"
                    Pause-Back
                    continue
                }
                if ($ZAPRET_BTS.Count -eq 0) {
                    Write-C ("  [X] no .bat profiles in {0}" -f $ZAPRET) "Red"
                    Pause-Back
                    continue
                }
                Write-C ""
                $n = 0
                foreach ($f in $ZAPRET_BTS) {
                    $n++
                    Write-C ("   [{0}] {1}" -f $n, $f.Name) "White"
                }
                $pn = (Read-Host ("   Profile (1-{0})" -f $n) -replace "\s", "").Trim()
                if (($pn -match "^\d+$") -and [int]$pn -ge 1 -and [int]$pn -le $n) {
                    $batPath = $ZAPRET_BTS[[int]$pn - 1].FullName
                    [void](Start-Zapret $batPath)
                }
                Pause-Back
            }
            "2" {
                if ($tOn) {
                     Write-C "  proxy is already running" "Yellow"
                    Pause-Back
                    continue
                }
                $h = "127.0.0.1"; $p = 1443; $s = $null
                if (Test-Path $CFG_JSON) {
                    try {
                        $cfg = Get-Content -LiteralPath $CFG_JSON -Raw | ConvertFrom-Json
                        if ($cfg.host)   { $h = [string]$cfg.host }
                        if ($cfg.port)   { $p = [int]$cfg.port }
                        if ($cfg.secret) { $s = [string]$cfg.secret }
                    } catch {}
                }
                Write-C ("   saved config: host={0} port={1} secret={2}" -f $h, $p, $(if ($s) { "yes" } else { "no" })) "Gray"
                $hn = (Read-Host "   host [$h]").Trim(); if ($hn) { $h = $hn }
                $pp = (Read-Host "   port [$p]").Trim(); if ($pp -match "^\d+$") { $p = [int]$pp }
                $ss = (Read-Host "   secret [$s]").Trim(); if ($ss) { $s = $ss }
                [void](Start-TgProxy $h $p $s)
                Pause-Back
            }
            "3" {
                Write-C "  stopping zapret (incl. external)..." "Yellow"
                Stop-Zapret
                Pause-Back
            }
            "4" {
                Write-C "  stopping tg-proxy (incl. external)..." "Yellow"
                Stop-Tgproxy
                Pause-Back
            }
            "5" {
                Write-C "  stopping everything (incl. external)..." "Yellow"
                Kill-All
                Pause-Back
            }
            "6" {
                $on = -not (Get-AutoStartState)
                if (Set-AutoStart $on) { Add-Log ("[mgr] autostart {0}" -f $(if ($on) { "enabled" } else { "disabled" })) "Cyan" }
                Pause-Back
            }
            "7" {
                [void](Set-UacMin)
                Pause-Back
            }
            "8" {
                Show-ZapretSettings
            }
            "9" {
                [void](Diagnose-TgProxy)
            }
            "10" {
                [void](Update-Zapret)
                Pause-Back
            }
            "11" {
                if (-not (Test-Admin)) {
                    Write-C "  [X] Update unlock-internet needs Administrator (stops running services first)." "Red"
                    Pause-Back
                    continue
                }
                [void](Update-UnlockInternet)
                Pause-Back
            }
            "12" {
                Start-Dashboard
            }
            "0" {
                Write-C "  stopping everything (incl. external)..." "Yellow"
                Kill-All
                return
            }
            default { if ($sel -ne "") { Write-C "  invalid choice" "Red"; Start-Sleep 1 } }
        }
    }
}

# ---------------------- Autostart: launch last config ----------------------
function Invoke-AutoLaunch {
    # launches the saved config from last config (zapret + tg-proxy always)
    $last = Read-LastConfig
    $vals = Get-LastConfigValues
    if (-not $last) { return }

    if ($vals.bat -and (Test-Path $vals.bat)) {
        try { [void](Start-Zapret ([string]$vals.bat)) } catch { }
    }
    try { [void](Start-TgProxy $vals.host $vals.port $vals.secret) } catch { }
}

# ---------------------- Autostart self-repair (move-proof) ----------------------
# If the HKCU autostart entry still points at a path that no longer exists (the
# folder was moved), rewrite it to the DISCOVERED current location so Windows login
# keeps working. Only touches the DB when the stored path is actually missing.
function Repair-AutoStartPath {
    try {
        if (-not (Get-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -ErrorAction SilentlyContinue)) { return }
        $cur = [string](Get-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -ErrorAction SilentlyContinue).$AUTO_NAME
        if (-not $cur) { return }
        # find the .ps1 path inside the stored command
        if ($cur -match '"([^"]+\.ps1)"') {
            $stored = $Matches[1]
            if (-not (Test-Path -LiteralPath $stored)) {
                $fixed = Join-Path $ROOT "unlock-internet.ps1"
                if (Test-Path -LiteralPath $fixed -and ($stored -ne $fixed)) {
                    $newcmd = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" --autostart' -f $fixed
                    New-ItemProperty -Path $AUTO_KEY -Name $AUTO_NAME -PropertyType String -Value $newcmd -Force | Out-Null
                }
            }
        }
    } catch {}
}

# ------------------------------- Entry point -------------------------------
Repair-AutoStartPath
$__args = @()
if ($args -is [array]) { $__args = @($args) } elseif ($null -ne $args) { $__args = @($args) }
if ($__args -contains "--autostart") {
    Invoke-AutoLaunch
    exit 0
}
Main

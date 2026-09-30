# Start-RepairLauncher.ps1 — family repair host launcher (openspec/changes/
# family-repair-host, design D2, spec "家人只要點兩下" + "失敗時家人看得懂該做什麼").
#
# Double-clicked by the family AFTER Install.cmd has run once.
# Must run as the normal user, NEVER elevated (design Risks: an elevated and a
# non-elevated VirtualBox cannot see each other's VMs, so an elevated launch
# would not find the installed VM).
#
# What it does, in order:
#   1. Asks for the Gateway IP and this PC's repair name, offering the last
#      ones as the defaults (stored in gateway-ip.txt / launcher-name.txt
#      next to this script; plain text, not secret).
#   2. Serves them on http://127.0.0.1:<d2Port>/gw (two lines: the IP, then
#      name=<name>) and takes tunnel=up|down on POST /state — the exact
#      contract repair-gateway-fetch and repair-gateway-report expect
#      (defaults 10.0.2.2:18080 seen through NAT).
#   3. Boots the VM headless, shows a "維修連線中，關掉此視窗即中斷" window
#      whose status follows the VM's reports, and sends acpipowerbutton when
#      the window closes.
#
# Why HTTP on loopback (and not guest property / a re-burned ISO): spike
# OUT-spike-repair.md §3(c) — needs no admin (no URL ACL for 127.0.0.1),
# needs nothing installed on either side, is bidirectional, and is not tied
# to a VirtualBox version. NAT exposes host 127.0.0.1 to the VM as 10.0.2.2
# only when the VM is created with --nat-localhostreachable1 on (the
# installer sets it explicitly instead of trusting the default).
#
# Why the port is FIXED (18080) with no fallback: the VM side
# (repair-gateway-fetch, MLP_D2_PORT default 18080) knows exactly one port.
# A launcher that hopped to 18081 on collision would serve an address the VM
# never asks. So a taken port is a loud refusal with a human-readable
# message, not a silent hop.
#
# Why a state FILE between the listener job and the window: the listener runs
# in a background job (its own process) while the WinForms message loop owns
# the foreground thread. The file (key=value lines, temp+move like the VM
# side's atomic write) is the only channel, and it doubles as a log the
# family can show the owner. A report that never arrives is "still
# connecting", never "connected".
#
# Why acpipowerbutton, then poweroff as a last resort: ACPI is what the spike
# (§2) and the live acceptance (OUT-live-repair.md §5) verified — 6 seconds
# to poweroff. A hung VM that ignored ACPI would otherwise keep its reverse
# tunnel up with nobody watching, so after 60 s the launcher cuts it. An
# unattended tunnel is worse than an unclean shutdown (ext4 journals).
#
# Exit codes: 0 ok (window closed and VM is off, or -NoWindow flow clean);
#   1 cancelled at the IP/name prompt or a usage error; 2 VirtualBox/VM missing
#   (run Install first); 3 D2 port taken; 4 VM failed to start.
#
# Limitations (honest list):
#   * PowerShell 5.1 + .NET WinForms only. No window can appear over ssh
#     (session 0); use -NoWindow -GatewayIp <ip> -RepairName <name> -RunSeconds <n>
#     there — it runs the same listener + boot + shutdown flow without any GUI.
#   * The window cannot tell "wrong IP" from "no network" from "rejected
#     key": the VM only reports up/down. After downTimeoutSec of never-up the
#     family is told to ask the owner for a new IP, whatever the cause.
#   * Plain HTTP, no auth (same as the VM side's contract): another program
#     on this machine could serve a wrong IP first (it must win the bind to
#     18080, which this script refuses to share) or post a fake state.
#   * Elevated runs are refused: they would not see the user's VM anyway.
#     -NoWindow bypasses the refusal for ssh testing and logs a warning.
#   * The desktop shortcut hides the console (-WindowStyle Hidden) so the
#     family sees exactly one window; abnormal ends (Ctrl+C, console closed,
#     logoff) are covered best-effort by a PowerShell.Exiting hook that sends
#     the ACPI button without waiting. Taskkill and power loss still bypass
#     it — the next launch then finds the VM running and reuses it.
param(
    [string]$GatewayIp = "",
    [string]$RepairName = "",
    [switch]$NoWindow,
    [int]$RunSeconds = 0,
    [string]$DataDir = "",
    [int]$D2Port = 0
)

$ErrorActionPreference = 'Stop'

# Strict IPv4, byte-identical in spirit to repair-gateway-fetch: four decimal
# octets 0-255, no leading zeros (glibc reads 010 as octal), so an answer can
# never smuggle an option ("-oProxyCommand=") or a newline into ssh's argv.
# Tail is \z for the same trailing-LF reason as the name pattern below.
$IPV4_PATTERN = '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\z'

# Repair name rule (EPHEMERAL-INTERFACE.md item 3: 1-32 char hostname label).
# Checked on BOTH ends (here and repair-gateway-fetch); the VM refuses to
# dial when either line of /gw fails its format, so a bad name can never
# smuggle an option or a newline into ssh's argv.
# The tail is \z, not $: .NET `$` also matches before a trailing LF, so
# "dad-pc`n" would pass with $. The interface text keeps `$` (bash has no
# \z); on LF-free input the two accept the same language, and every entry
# point below Trims first, so both ends always agree.
$REPAIR_NAME_PATTERN = '^[a-z]([a-z0-9-]{0,30}[a-z0-9])?\z'

# Trim parameters up front (same $/LF reason as above; "$x" also turns an
# explicit $null into "").
$GatewayIp = "$GatewayIp".Trim()
$RepairName = "$RepairName".Trim()

function Write-Log([string]$m) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $m
    Add-Content -Path (Join-Path $script:DataDir 'launcher.log') -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:LastNativeRc = 0
function Invoke-Native {
    param([string]$Cmd, [string[]]$Argv)
    # Same guard as the installer's (see Install-RepairHost.ps1): under
    # $ErrorActionPreference='Stop' a native exe writing stderr would
    # terminate us as RemoteException before our exit-code checks run.
    # Get-VMState MUST return 'missing' for an unregistered VM, not throw.
    # NOTE: `& $Cmd @Argv` — never `& @args` (probed live on PS 5.1: the
    # latter joins everything into one command string).
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Cmd @Argv 2>&1 }
    finally { $ErrorActionPreference = $oldEap }
    $script:LastNativeRc = $LASTEXITCODE
    return $out
}

function Find-VBoxManage {
    $c = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path $p) { return $p }
    return ''
}

function Get-VMState([string]$vbm, [string]$vm) {
    $out = Invoke-Native $vbm @('showvminfo', $vm, '--machinereadable')
    if ($script:LastNativeRc -ne 0) { return 'missing' }
    $m = $out | Select-String -Pattern '^VMState="(.*)"$' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return 'unknown'
}

function Read-StateFile([string]$path) {
    # Missing file = no report yet, not an error.
    if (-not (Test-Path $path)) { return $null }
    try { return ConvertFrom-StringData ((Get-Content -Path $path -Raw) -replace "`r", '') }
    catch { return $null }
}

function Prompt-GatewayIp([string]$defaultIp) {
    # A GUI box for the family; ssh/test callers pass -GatewayIp instead.
    # Microsoft.VisualBasic ships with .NET, nothing to install.
    $prompt = '請輸入維修主機的 IP（向家人服務的聯絡人索取）：'
    try {
        Add-Type -AssemblyName 'Microsoft.VisualBasic' -ErrorAction Stop
        $ans = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, '維修連線', $defaultIp)
    } catch {
        # No GUI (ssh session 0): fall back to the console so -NoWindow runs
        # and debugging still work without a second code path for validation.
        if ($defaultIp -ne '') { $prompt = '{0} [預設 {1}]：' -f $prompt, $defaultIp }
        else { $prompt = '{0}：' -f $prompt }
        $ans = Read-Host $prompt
        if (($ans -eq '') -and ($defaultIp -ne '')) { $ans = $defaultIp }
    }
    return $ans
}

function Test-RepairName([string]$n) {
    # Interface item 3 (tail \z, see above). Same pattern the VM side
    # enforces; keep the two in sync (see the Windows got in OUT-*).
    # -cmatch, not -match: PowerShell -match is case-insensitive, so 'Dad-pc'
    # would pass here while the VM side (case-sensitive) refuses to dial —
    # the family would be stuck re-entering a name that can never work.
    return ($n -cmatch $REPAIR_NAME_PATTERN)
}

function Prompt-RepairName([string]$defaultName) {
    # A GUI box for the family; ssh/test callers pass -RepairName instead.
    $prompt = '請輸入這台電腦的名字（向家人服務的聯絡人索取；小寫英文開頭，後面可加小寫英文、數字或 -，例如 dad-pc）：'
    try {
        Add-Type -AssemblyName 'Microsoft.VisualBasic' -ErrorAction Stop
        $ans = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, '維修連線', $defaultName)
    } catch {
        # No GUI (ssh session 0): fall back to the console, same as the IP prompt.
        if ($defaultName -ne '') { $prompt = '{0} [預設 {1}]：' -f $prompt, $defaultName }
        else { $prompt = '{0}：' -f $prompt }
        $ans = Read-Host $prompt
        if (($ans -eq '') -and ($defaultName -ne '')) { $ans = $defaultName }
    }
    return $ans
}

# ---- resolve locations and config -------------------------------------------
if ($DataDir -eq '') { $DataDir = $PSScriptRoot }
$script:DataDir = $DataDir
$ConfigPath = Join-Path $DataDir 'repair-config.json'
$IpPath = Join-Path $DataDir 'gateway-ip.txt'
$NamePath = Join-Path $DataDir 'launcher-name.txt'
$StatePath = Join-Path $DataDir 'launcher-state.txt'
$HttpLogPath = Join-Path $DataDir 'launcher-http.log'
$StopFile = Join-Path $DataDir 'listener-stop.txt'

$cfg = $null
if (Test-Path $ConfigPath) {
    # -Encoding UTF8: same reason as the installer's config read (contact
    # name is usually Chinese; ANSI decode would break ConvertFrom-Json).
    try { $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host ("repair-config.json 讀不懂（{0}），用內建預設值繼續。" -f $_.Exception.Message) }
}
# Fixed VM name (EPHEMERAL-INTERFACE.md item 9): one shared bundle for the
# whole family, installed once per PC. The installer builds exactly this
# name; a cfg.vmName from an old per-node bundle is ignored on purpose.
$VmName = 'mlp-repair-host'
$Port = 18080
$DownTimeoutSec = 300
$ContactName = '使用者'
if ($cfg) {
    if ($cfg.d2Port) { $Port = [int]$cfg.d2Port }
    if ($cfg.downTimeoutSec) { $DownTimeoutSec = [int]$cfg.downTimeoutSec }
    if ($cfg.contactName) { $ContactName = $cfg.contactName }
}
if ($D2Port -ne 0) { $Port = $D2Port }

# ---- must not run elevated (the VM would be invisible) -----------------------
if ((Test-IsAdmin) -and (-not $NoWindow)) {
    $msg = '請不要以「系統管理員身分」執行維修連線（直接點兩下捷徑就好）。以系統管理員執行會看不到安裝好的 VM。'
    try { Add-Type -AssemblyName 'System.Windows.Forms'; [System.Windows.Forms.MessageBox]::Show($msg, '維修連線') | Out-Null }
    catch { Write-Host $msg }
    exit 5
}
if ((Test-IsAdmin) -and ($NoWindow)) {
    # ssh sessions are elevated; the flow below is still the same code.
    Write-Host 'WARNING: running elevated (ssh test mode) — the desktop launch must stay non-elevated.'
}

# ---- VirtualBox and VM must already exist (the installer owns that) ----------
$Vbm = Find-VBoxManage
if ($Vbm -eq '') {
    Write-Host '找不到 VirtualBox（VBoxManage.exe）。請先執行「首次安裝」再點這個捷徑。'
    exit 2
}
$st0 = Get-VMState $Vbm $VmName
if ($st0 -eq 'missing') {
    Write-Host ("找不到 VM「{0}」。請先執行「首次安裝」再點這個捷徑。" -f $VmName)
    exit 2
}

# ---- Gateway IP (ask, defaulting to last time) --------------------------------
if ($GatewayIp -eq '') {
    $last = ''
    if (Test-Path $IpPath) {
        $t = (Get-Content -Path $IpPath -TotalCount 1 -ErrorAction SilentlyContinue)
        if (($t -ne $null) -and ($t -match $IPV4_PATTERN)) { $last = $t.Trim() }
    }
    $GatewayIp = Prompt-GatewayIp $last
    if (($GatewayIp -eq $null) -or ($GatewayIp.Trim() -eq '')) {
        Write-Host '已取消（沒有輸入 IP）。'
        exit 1
    }
    $GatewayIp = $GatewayIp.Trim()
}
if ($GatewayIp -notmatch $IPV4_PATTERN) {
    $msg = ("「{0}」不是 IP 位址（例如 203.0.113.7）。請向「{1}」索取新的 IP 再試一次。" -f $GatewayIp, $ContactName)
    try { Add-Type -AssemblyName 'System.Windows.Forms'; [System.Windows.Forms.MessageBox]::Show($msg, '維修連線') | Out-Null }
    catch { Write-Host $msg }
    exit 1
}
Set-Content -Path $IpPath -Value $GatewayIp -Encoding ASCII
Write-Log ("serving Gateway IP {0} for VM {1}" -f $GatewayIp, $VmName)

# ---- Repair name (ask, defaulting to last time; interface item 3) ------------
if ($RepairName -eq '') {
    if ($NoWindow) {
        # ssh/test mode never prompts: take the remembered name or refuse.
        $t = (Get-Content -Path $NamePath -TotalCount 1 -ErrorAction SilentlyContinue)
        if (($t -ne $null) -and (Test-RepairName $t.Trim())) { $RepairName = $t.Trim() }
        if ($RepairName -eq '') {
            Write-Host '缺少名字：請加 -RepairName 參數（例如 -RepairName dad-pc），或先正常啟動一次記住名字。這行只有測試會看到，家人點捷徑不會看到。'
            exit 1
        }
    } else {
        $lastName = ''
        $t = (Get-Content -Path $NamePath -TotalCount 1 -ErrorAction SilentlyContinue)
        if (($t -ne $null) -and (Test-RepairName $t.Trim())) { $lastName = $t.Trim() }
        while ($true) {
            $RepairName = Prompt-RepairName $lastName
            if (($RepairName -eq $null) -or ($RepairName.Trim() -eq '')) {
                Write-Host '已取消（沒有輸入名字）。'
                exit 1
            }
            $RepairName = $RepairName.Trim()
            if (Test-RepairName $RepairName) { break }
            $msg = ("「{0}」不能當名字：要用小寫英文開頭，後面只能有小寫英文、數字或 -，共 1 到 32 個字（例如 dad-pc）。請重輸一次。" -f $RepairName)
            try { Add-Type -AssemblyName 'System.Windows.Forms'; [System.Windows.Forms.MessageBox]::Show($msg, '維修連線') | Out-Null }
            catch { Write-Host $msg }
        }
    }
}
if (-not (Test-RepairName $RepairName)) {
    Write-Host ("「{0}」不能當名字：要用小寫英文開頭，後面只能有小寫英文、數字或 -，共 1 到 32 個字（例如 dad-pc）。" -f $RepairName)
    exit 1
}
Set-Content -Path $NamePath -Value $RepairName -Encoding ASCII
Write-Log ("repair name {0} for VM {1}" -f $RepairName, $VmName)

# ---- D2 listener job (the launcher side of design D2) -------------------------
# Self-contained on purpose: a job is a fresh process, it cannot see the
# parent's functions. Protocol: GET /gw -> TWO lines (EPHEMERAL-INTERFACE.md
# item 4): the IPv4, then `name=<repair name>` (what repair-gateway-fetch
# parses into gateway.env); POST /state -> 200 'ok', and tunnel=up|down
# updates the state file (what repair-gateway-report sends). Else 404.
$ListenerBlock = {
    param([int]$Port, [string]$ServeIp, [string]$ServeName, [string]$StateFile, [string]$LogFile, [string]$StopFile)
    $ErrorActionPreference = 'Stop'
    function L([string]$m) {
        $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $m
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
    function Save-State([string]$last, [string]$lastUtc, [string]$fetchUtc, [int]$fetches) {
        $content = "SERVED_IP={0}`r`nREPAIR_NAME={1}`r`nLAST_STATE={2}`r`nLAST_STATE_UTC={3}`r`nLAST_FETCH_UTC={4}`r`nFETCH_COUNT={5}`r`n" -f $ServeIp, $ServeName, $last, $lastUtc, $fetchUtc, $fetches
        $tmp = "$StateFile.tmp"
        Set-Content -Path $tmp -Value $content -Encoding ASCII
        Move-Item -Path $tmp -Destination $StateFile -Force
    }
    $l = New-Object System.Net.HttpListener
    # Loopback only: spike §3(c) proved no URL ACL and no admin are needed
    # for 127.0.0.1, while +/* are (correctly) denied.
    $l.Prefixes.Add(("http://127.0.0.1:{0}/" -f $Port))
    try { $l.Start() }
    catch {
        L ("LISTEN FAILED port={0} err={1}" -f $Port, $_.Exception.Message)
        exit 3
    }
    $last = 'none'; $lastUtc = ''; $fetchUtc = ''; $fetches = 0
    Save-State $last $lastUtc $fetchUtc $fetches
    L ("listening on http://127.0.0.1:{0}/ serving gw={1} name={2} pid={3}" -f $Port, $ServeIp, $ServeName, $PID)
    # A stale stop signal from a previous run must not kill this one.
    Remove-Item -Path $StopFile -Force -ErrorAction SilentlyContinue
    try {
        $stop = $false
        while ($l.IsListening -and -not $stop) {
            # Interruptible wait: a blocking GetContext() cannot be woken from
            # outside, and Stop-Job on such a blocked job takes ~120 s
            # (measured live). Polling every 2 s for the stop file keeps the
            # shutdown after window-close instant — otherwise the port stays
            # held and an immediate relaunch falsely reports "port taken".
            $iar = $l.BeginGetContext($null, $null)
            while (-not $iar.AsyncWaitHandle.WaitOne(2000)) {
                if (Test-Path $StopFile) { $stop = $true; break }
            }
            if ($stop) { break }
            $c = $l.EndGetContext($iar)
            $rq = $c.Request; $rs = $c.Response
            $body = ''
            if ($rq.HasEntityBody) {
                $sr = New-Object System.IO.StreamReader($rq.InputStream, $rq.ContentEncoding)
                $body = $sr.ReadToEnd(); $sr.Close()
                if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
            }
            $code = 404; $out = 'not found'
            if (($rq.HttpMethod -eq 'GET') -and ($rq.Url.AbsolutePath -eq '/gw')) {
                $code = 200; $out = ("{0}`r`nname={1}" -f $ServeIp, $ServeName)
                $fetches = $fetches + 1
                $fetchUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                Save-State $last $lastUtc $fetchUtc $fetches
            } elseif (($rq.HttpMethod -eq 'POST') -and ($rq.Url.AbsolutePath -eq '/state')) {
                $code = 200; $out = 'ok'
                if ($body -match 'tunnel=up') { $last = 'up'; $lastUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                elseif ($body -match 'tunnel=down') { $last = 'down'; $lastUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                Save-State $last $lastUtc $fetchUtc $fetches
            }
            L ("{0} {1} from={2} host={3} body=[{4}] -> {5}" -f $rq.HttpMethod, $rq.Url.AbsolutePath, $rq.RemoteEndPoint, $rq.Headers['Host'], $body, $code)
            $b = [System.Text.Encoding]::ASCII.GetBytes($out)
            $rs.StatusCode = $code; $rs.ContentType = 'text/plain'
            $rs.ContentLength64 = $b.Length
            $rs.OutputStream.Write($b, 0, $b.Length); $rs.OutputStream.Close()
        }
    } finally { $l.Stop(); L 'listener stopped' }
}

if (Test-Path $StatePath) { Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue }
$job = Start-Job -ScriptBlock $ListenerBlock -ArgumentList $Port, $GatewayIp, $RepairName, $StatePath, $HttpLogPath, $StopFile
Start-Sleep -Seconds 2
if ($job.State -ne 'Running') {
    # The child died at once — almost always "port in use". Do NOT hop to
    # another port (the VM only knows this one); say so out loud instead.
    $reason = Receive-Job -Job $job 2>&1 | Out-String
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $msg = ("本機的 {0} 埠被別的程式佔用了（維修連線只能用這個埠）。請把佔用的程式關掉或重開機再試；不行就聯絡「{1}」。" -f $Port, $ContactName)
    Write-Host $msg
    Write-Log ("listener failed at once: {0}" -f $reason.Trim())
    exit 3
}
# Prove WE serve the right bytes before the VM asks (its parser is strict):
# the same two-line contract the VM parses (interface item 4).
try {
    $probe = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/gw" -f $Port) -UseBasicParsing -TimeoutSec 5
    $probeLines = ($probe.Content -split "`r?`n")
    if (($probeLines.Count -lt 2) -or ($probeLines[0].Trim() -ne $GatewayIp) -or ($probeLines[1].Trim() -ne ("name={0}" -f $RepairName))) { throw 'wrong body' }
} catch {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Host ("啟動器自己的檢查沒過（{0} 埠回的不是剛輸入的 IP 與名字）。請重試；不行就聯絡「{1}」。" -f $Port, $ContactName)
    Write-Log ("self-probe failed: {0}" -f $_.Exception.Message)
    exit 3
}
Write-Log ("listener up on 127.0.0.1:{0} (job {1})" -f $Port, $job.Id)

function Stop-Listener {
    # Signal first: the job polls the stop file every 2 s and exits by itself,
    # so the shutdown after window-close is instant. Stop-Job stays only as
    # the fallback for a wedged job (measured 120 s on a blocked GetContext —
    # that wait is why the signal exists at all).
    Set-Content -Path $StopFile -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
    $null = Wait-Job -Job $job -Timeout 15
    if ($job.State -eq 'Running') {
        Write-Log 'WARNING: listener job ignored the stop signal — Stop-Job fallback'
        Stop-Job -Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $StopFile -Force -ErrorAction SilentlyContinue
    Write-Log 'listener stopped'
}

function Stop-RepairVM([string]$why) {
    Write-Log ("shutting down VM {0} ({1})" -f $VmName, $why)
    Invoke-Native $Vbm @('controlvm', $VmName, 'acpipowerbutton') | Out-Null
    # ACPI takes ~6 s when the guest is healthy (spike §2, live §5).
    $waited = 0
    while ($waited -lt 60) {
        Start-Sleep -Seconds 2; $waited = $waited + 2
        if ((Get-VMState $Vbm $VmName) -eq 'poweroff') {
            Write-Log ("VM off after {0}s (ACPI)" -f $waited)
            return
        }
    }
    # A hung guest that ignored ACPI would keep its tunnel up unattended —
    # cut it. The disk risk is bounded (ext4 journals); the tunnel risk is not.
    Write-Log 'VM ignored ACPI for 60s — cutting power (hard poweroff, tunnel must not stay up unattended)'
    Invoke-Native $Vbm @('controlvm', $VmName, 'poweroff') | Out-Null
}

# ---- boot ----------------------------------------------------------------------
$st0 = Get-VMState $Vbm $VmName
if ($st0 -eq 'running') {
    Write-Log 'VM already running (previous window may not have closed it) — reusing it'
} else {
    # Array literal (NOT four positionals): probed live on this machine's PS 5.1
    # that multiple positional args into Invoke-Native's [string[]] misbehave
    # (startvm got a usage dump), while the array-literal form runs correctly.
    (Invoke-Native $Vbm @('startvm', $VmName, '--type', 'headless')) | ForEach-Object { Write-Log ("VBoxManage: {0}" -f $_) }
    if ($script:LastNativeRc -ne 0) {
        Stop-Listener
        Write-Host ("VM 開不起來（VBoxManage startvm 失敗）。請重開機再試；不行就聯絡「{0}」。詳細在 data 目錄的 launcher.log。" -f $ContactName)
        exit 4
    }
    Write-Log 'VM start requested (headless)'
}
$BootUtc = (Get-Date).ToUniversalTime()

# Best-effort shutdown for exits that never reach FormClosed (Ctrl+C in a
# visible console, closing a console window, logoff): without this the VM —
# and a tunnel it may hold — would stay up unwatched. Registered only AFTER
# the boot request above, so pre-boot exits never touch the VM. Fires while
# the engine is tearing down, so the action only sends the ACPI button and
# returns: no waiting, no job cleanup. Best-effort by construction — taskkill
# and power loss still bypass it; the next launch then finds the VM running
# and reuses it (see the boot section). Unregistered on the two normal exits
# (FormClosed, end of -NoWindow) so a clean shutdown does not double-send.
$script:ShutdownVbm = $Vbm
$script:ShutdownVm = $VmName
$null = Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
    # Action-local Continue: the engine is tearing down here; nothing may throw.
    $ErrorActionPreference = 'Continue'
    try { & $script:ShutdownVbm 'controlvm' $script:ShutdownVm 'acpipowerbutton' 2>&1 | Out-Null } catch { }
}

function Get-DisplayStatus {
    # Returns a short Chinese line for the window / console.
    # Latching (review fix, option b — the VM contract is untouched): the VM
    # reports up ONCE per connection and stays silent while the tunnel lives
    # (repair-tunnel-launch enters watch_tunnel after `report up`), so there
    # is no freshness to check. "up and the VM still runs" MEANS connected,
    # however old the report is; only a later `down` (tunnel died or a dial
    # failed) or a stopped VM downgrades it. The old "< 90 s" freshness rule
    # turned healthy connections red within minutes — that bug is gone, and
    # with it the only reader of LAST_STATE_UTC's age here.
    $now = (Get-Date).ToUniversalTime()
    $elapsed = [int](($now - $BootUtc).TotalSeconds)
    $vm = Get-VMState $Vbm $VmName
    if (($vm -ne 'running') -and ($vm -ne 'starting')) {
        return ("VM 已停止（{0}）。關掉此視窗後重開即可。" -f $vm)
    }
    $s = Read-StateFile $StatePath
    if (($s -ne $null) -and ($s['LAST_STATE'] -eq 'up')) {
        return '已連上維修通道'
    }
    if ($elapsed -ge $DownTimeoutSec) {
        return ("連不上，請向「{0}」索取新的 IP（已等候 {1} 秒）。拿到新 IP 後關掉此視窗重開。" -f $ContactName, $elapsed)
    }
    return ("連線建立中…（已等候 {0} 秒，請稍候）" -f $elapsed)
}

if ($NoWindow) {
    # ssh / test mode: same listener + boot + shutdown flow, no GUI at all.
    if ($RunSeconds -le 0) { $RunSeconds = 90 }
    Write-Log ("NoWindow mode: watching {0}s" -f $RunSeconds)
    $waited = 0
    while ($waited -lt $RunSeconds) {
        Start-Sleep -Seconds 5; $waited = $waited + 5
        Write-Log ("status: {0}" -f (Get-DisplayStatus))
    }
    Stop-RepairVM 'NoWindow run over'
    Stop-Listener
    try { Unregister-Event -SourceIdentifier 'PowerShell.Exiting' -ErrorAction SilentlyContinue } catch { }
    Write-Log 'NoWindow run done'
    exit 0
}

# ---- status window ---------------------------------------------------------------
# "維修連線中，關掉此視窗即中斷" — closing it IS the disconnect switch.
Add-Type -AssemblyName 'System.Windows.Forms'
Add-Type -AssemblyName 'System.Drawing'
$form = New-Object System.Windows.Forms.Form
$form.Text = '維修連線中'
$form.Size = New-Object System.Drawing.Size(500, 230)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$labelMain = New-Object System.Windows.Forms.Label
$labelMain.Text = '維修連線中，關掉此視窗即中斷'
$labelMain.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 14, [System.Drawing.FontStyle]::Bold)
$labelMain.AutoSize = $true
$labelMain.Location = New-Object System.Drawing.Point(30, 25)
$form.Controls.Add($labelMain)

$labelHint = New-Object System.Windows.Forms.Label
$labelHint.Text = ("對方（{0}）正在連線維修，請不要關機、不要拔網路線。" -f $ContactName)
$labelHint.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 10)
$labelHint.AutoSize = $true
$labelHint.Location = New-Object System.Drawing.Point(30, 70)
$form.Controls.Add($labelHint)

$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Text = '正在啟動…'
$labelStatus.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 11)
$labelStatus.AutoSize = $true
$labelStatus.Location = New-Object System.Drawing.Point(30, 110)
$form.Controls.Add($labelStatus)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    $t = Get-DisplayStatus
    $labelStatus.Text = $t
    if ($t -eq '已連上維修通道') { $labelStatus.ForeColor = [System.Drawing.Color]::DarkGreen }
    elseif ($t.StartsWith('連不上')) { $labelStatus.ForeColor = [System.Drawing.Color]::DarkRed }
    else { $labelStatus.ForeColor = [System.Drawing.Color]::Black }
})
$timer.Start()

# Closing the window shuts the VM down — that is the spec ("關掉這個視窗
# MUST 讓 VM 關機"), not a side effect. Unregistering the Exiting hook first
# so the clean path does not send the ACPI button twice.
$form.Add_FormClosed({
    $timer.Stop()
    try { Unregister-Event -SourceIdentifier 'PowerShell.Exiting' -ErrorAction SilentlyContinue } catch { }
    try { Stop-RepairVM 'window closed' } catch { Write-Log ("shutdown error: {0}" -f $_.Exception.Message) }
    try { Stop-Listener } catch { }
})
Write-Log 'status window open (closing it powers the VM off)'
[void]$form.ShowDialog()
Write-Log 'launcher done'
exit 0

# Install-RepairHost.ps1 — one-time install of a family repair host on Windows
# (openspec/changes/archive/2026-10-01-family-repair-host, tasks 6.1; fixes OUT-live-repair.md §6).
#
# Run ONCE via Install.cmd in the bundle the owner hands over (double-click
# the .cmd — double-clicking this .ps1 itself only opens an editor). It
# asks UAC for elevation a single time ("UAC 按一次「是」"), then:
#   1. makes sure VirtualBox is installed (pinned version, SHA256-verified
#      download when missing),
#   2. puts the image + boot data into a FIXED per-user folder
#      (%LOCALAPPDATA%\MyLinuxPool\repair-host) and locks that
#      folder down,
#   3. creates the VM (named mlp-repair-host; NAT, no port forward,
#      localhostreachable on, serial log, boot data attached),
#   4. drops a desktop shortcut ("維修連線") for the launcher.
#
# Running it AGAIN over an existing mlp-repair-host is not an error: it powers
# the old machine down cleanly, removes it, and builds a new one. That is the
# family's whole procedure for a rotated tunnel key (docs/REPAIR-HOST.md §6).
#
# Why %LOCALAPPDATA%\MyLinuxPool\repair-host and not C:\mlp-*: the live acceptance
# left seed.iso under C:\, which inherits C:\Users ReadAndExecute — every
# local user could read the tunnel private key (OUT-live-repair.md §6 意外 3).
# A folder under the user's own profile is private by default; the icacls
# step below then removes inheritance and grants ONLY this user + SYSTEM, so
# even that default is not trusted blindly. The VM runs as this user, so it
# keeps full access; nobody else on the machine can read the key, the VDI
# (which holds the key after first boot), or the serial log.
#
# Why elevation for the WHOLE install instead of just the ACL step: the
# VirtualBox install itself needs admin, and splitting one double-click into
# "run this part elevated, that part not" is exactly the kind of thing the
# family cannot be asked to do. The launcher (Start-RepairLauncher.ps1)
# stays non-elevated forever — this script refuses to install that habit.
#
# Why clonemedium to VDI + resize 10 GB instead of attaching the .vmdk
# directly: the cloud image is ~2 GB with no free room for journal/systemd
# writes, and this exact path (clone, resize, SATA port 0 + seed ISO on
# port 1) is what the spike and the live acceptance booted (build-vm.ps1).
#
# Why the shortcut uses -ExecutionPolicy Bypass: family machines sit on
# Restricted/RemoteSigned, and an unsigned script from an extracted bundle
# would otherwise die with a policy error nobody there can diagnose. The
# bypass applies to THIS script file only (an argument, not a system
# setting), and the file itself lives in the locked data folder.
#
# Exit codes: 0 installed; 1 usage/cancel; 2 VirtualBox missing and no
#   pinned installer configured; 3 image missing or SHA256 mismatch;
#   4 VM creation/verification failed (or the old machine could not be
#   removed cleanly); 5 the launcher window was still open — nothing changed.
#
# Re-running over an existing machine RE-INSTALLS it (whole new machine; the
# VM holds no state worth keeping). That is the supported way to pick up a
# rotated shared tunnel key: hand the family the new bundle, they double-click
# Install.cmd again (docs/REPAIR-HOST.md §6). Teardown is deliberately narrow:
# it unregisters only $VmName and closemediums only media registered under
# $DataDir, so any other machine on this PC is untouched.
#
# Limitations (honest list):
#   * The launcher window must be closed first: the installer asks (in
#     Chinese) and waits up to 60 s rather than killing the family's process.
#   * Hyper-V coexistence is only WARNed about (VirtualBox falls back to a
#     slower mode); the install continues.
#   * The VirtualBox silent install needs network; without network the family
#     must fetch the pinned installer some other way (URL + SHA256 are in
#     repair-config.json and in the failure message).
#   * Installer downloads are NOT resumed; a broken download is deleted and
#     reported, never kept.
param(
    [string]$PackageDir = "",
    [string]$DataDir = "",
    [string]$ImageSource = "",
    [switch]$SkipVirtualBoxCheck,
    [switch]$SkipImageDownload
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$m) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $m
    if ($script:InstallLog -ne '') { Add-Content -Path $script:InstallLog -Value $line -Encoding UTF8 }
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
    # Run a NATIVE exe (VBoxManage, icacls) whose failure we handle ourselves.
    # With $ErrorActionPreference='Stop', a native exe writing to stderr
    # (VBoxManage "error: Could not find ...", a failing icacls) TERMINATES
    # the script as RemoteException BEFORE our own exit-code checks run —
    # found live: the installer's showvminfo-exists check died exactly this
    # way. So every handled-failure native call goes through here: it runs
    # under 'Continue', returns the output lines, and leaves the exit code in
    # $script:LastNativeRc (read it before running anything else).
    # NOTE: the call MUST be `& $Cmd @Argv`, never `& @args`: probed live on
    # PS 5.1 — `& @args` joins everything into ONE command string
    # ("The term 'C:\...\VBoxManage.exe showvminfo ...' is not recognized"),
    # while `& $Cmd @Argv` splats correctly.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Cmd @Argv 2>&1 }
    finally { $ErrorActionPreference = $oldEap }
    $script:LastNativeRc = $LASTEXITCODE
    return $out
}

if ($PackageDir -eq '') { $PackageDir = $PSScriptRoot }
$script:InstallLog = ''

# ---- elevate once (the family's single UAC "Yes") --------------------------------
if (-not (Test-IsAdmin)) {
    # Re-launch OURSELVES elevated with the same arguments. Quoting is done
    # per-element so a path with spaces survives the round trip.
    $argList = @('-ExecutionPolicy', 'Bypass', '-File', ("`"{0}`"" -f $PSCommandPath))
    if ($PackageDir -ne '') { $argList += @('-PackageDir', ("`"{0}`"" -f $PackageDir)) }
    if ($DataDir -ne '') { $argList += @('-DataDir', ("`"{0}`"" -f $DataDir)) }
    if ($ImageSource -ne '') { $argList += @('-ImageSource', ("`"{0}`"" -f $ImageSource)) }
    if ($SkipVirtualBoxCheck) { $argList += '-SkipVirtualBoxCheck' }
    if ($SkipImageDownload) { $argList += '-SkipImageDownload' }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb 'RunAs' -Wait -PassThru
        exit $proc.ExitCode
    } catch {
        Write-Host '安裝需要系統管理員權限（只問這一次，按「是」即可）。你按了否，安裝沒有做任何事。'
        exit 1
    }
}

# ---- config -----------------------------------------------------------------------
$ConfigPath = Join-Path $PackageDir 'repair-config.json'
$SeedIsoSrc = Join-Path $PackageDir 'seed\seed.iso'
if (-not (Test-Path $SeedIsoSrc)) { $SeedIsoSrc = Join-Path $PackageDir 'seed.iso' }
$LauncherSrc = Join-Path $PackageDir 'Start-RepairLauncher.ps1'

$cfg = $null
if (Test-Path $ConfigPath) {
    # -Encoding UTF8 on purpose: the config carries the contact name, which is
    # usually Chinese. Without it Get-Content decodes as ANSI and a non-ASCII
    # name breaks ConvertFrom-Json (found live: installer died with "Invalid
    # object passed in"). -Encoding UTF8 is BOM-aware both ways, and the
    # packager writes the file with a BOM anyway (see package-repair-host).
    try { $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host ("repair-config.json 讀不懂：{0}" -f $_.Exception.Message); exit 1 }
} else {
    Write-Host '找不到 repair-config.json（安裝包不完整）。請向提供安裝包的人反映。'
    exit 1
}
# No per-node name in this world (EPHEMERAL-INTERFACE.md item 9): one shared
# bundle for the whole family, installed once per PC. config nodeName/vmName
# from old per-node bundles are ignored on purpose — the package-repair-host
# redesign (another ticket) removes them at the source.
$VmName = 'mlp-repair-host'
if ($DataDir -eq '') { $DataDir = Join-Path $env:LOCALAPPDATA 'MyLinuxPool\repair-host' }
# The log file's directory must exist BEFORE the first Write-Log below: with
# $ErrorActionPreference='Stop', Add-Content into a missing directory throws
# and the whole install dies on its very first line (review finding — a
# clean profile has no %LOCALAPPDATA%\MyLinuxPool yet). The ACL section later
# re-asserts the same directory; creating it twice is harmless.
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$script:InstallLog = Join-Path $DataDir 'install.log'

Write-Log ("installing vm={0} to {1}" -f $VmName, $DataDir)

# ---- VirtualBox --------------------------------------------------------------------
function Find-VBoxManage {
    $c = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path $p) { return $p }
    return ''
}

$Vbm = ''
if ($SkipVirtualBoxCheck) {
    Write-Log 'WARNING: -SkipVirtualBoxCheck, trusting VBoxManage on PATH'
    $Vbm = Find-VBoxManage
} else {
    $Vbm = Find-VBoxManage
    if ($Vbm -eq '') {
        # Not installed: fetch the PINNED installer and verify it. A version
        # drift here matters (the VM-side VBoxControl fallback in the spike
        # was version-tied), so "any new version" is not accepted silently.
        if (($cfg.vbox -eq $null) -or ($cfg.vbox.url -eq $null) -or ($cfg.vbox.sha256 -eq $null)) {
            Write-Host '這台電腦沒有 VirtualBox，而且安裝包沒有附下載資訊。請先到 virtualbox.org 安裝 VirtualBox 再重跑安裝。'
            exit 2
        }
        $vboxUrl = $cfg.vbox.url; $vboxSha = $cfg.vbox.sha256
        $dl = Join-Path $env:TEMP 'mlp-virtualbox-installer.exe'
        Write-Log ("VirtualBox missing — downloading {0}" -f $vboxUrl)
        Write-Host '這台電腦沒有 VirtualBox，正在下載（約 100MB）並安裝，請稍候…'
        try { Invoke-WebRequest -Uri $vboxUrl -OutFile $dl -UseBasicParsing } catch {
            Write-Host ("VirtualBox 下載失敗：{0}。請接好網路再重跑安裝。" -f $_.Exception.Message)
            exit 2
        }
        $got = (Get-FileHash -Path $dl -Algorithm SHA256).Hash
        if ($got -ne $vboxSha.ToUpper()) {
            Remove-Item -Path $dl -Force -ErrorAction SilentlyContinue
            Write-Host '下載到的 VirtualBox 安裝檔驗證沒過（SHA256 不合），已刪除。請重跑安裝；一直失敗就聯絡提供安裝包的人。'
            Write-Log ("vbox installer SHA mismatch: got {0}" -f $got)
            exit 2
        }
        Write-Host '驗證通過，正在安裝 VirtualBox…'
        $ip = Start-Process -FilePath $dl -ArgumentList '--silent' -Wait -PassThru
        Remove-Item -Path $dl -Force -ErrorAction SilentlyContinue
        if ($ip.ExitCode -ne 0) {
            Write-Host ("VirtualBox 安裝失敗（rc={0}）。請重跑安裝。" -f $ip.ExitCode)
            exit 2
        }
        $Vbm = Find-VBoxManage
        if ($Vbm -eq '') {
            Write-Host 'VirtualBox 裝好了但找不到 VBoxManage。請重開機再重跑安裝。'
            exit 2
        }
    }
}
if ($Vbm -eq '') { Write-Host '找不到 VBoxManage。請先安裝 VirtualBox 再重跑。'; exit 2 }
Write-Log ("VBoxManage: {0}" -f $Vbm)
try { & $Vbm '--version' 2>&1 | ForEach-Object { Write-Log ("vbox version: {0}" -f $_) } } catch { }

# Hyper-V coexistence only slows VirtualBox down (design Risks); warn, continue.
try {
    $hyp = (bcdedit /enum '{current}' | Select-String -Pattern 'hypervisorlaunchtype\s+(\S+)' | Select-Object -First 1)
    if ($hyp -and ($hyp.Matches[0].Groups[1].Value -ne 'Off')) {
        Write-Log 'WARNING: Hyper-V looks enabled — VirtualBox will run slower, this is expected'
        Write-Host '提醒：這台電腦開著 Hyper-V，VM 會跑得比較慢，這是正常的。'
    }
} catch { Write-Log 'hypervisor check skipped (bcdedit failed)' }

# ---- re-running this script is a SUPPORTED operation: reinstall == whole new machine ----
# Rotating the shared tunnel key means every family PC re-installs the new bundle
# (docs/REPAIR-HOST.md §6), and the family's ONLY tool is a double-click on
# Install.cmd. Refusing here made "換金鑰" need a support phone call, so the
# design decision (PM) is: re-run = throw the machine away and build a new one.
# The VM keeps no state anyone wants (PM), so nothing is lost.
#
# Two live findings make this more than `unregistervm`; see
# OUT-impl-live-fixes.md §3.0 and §3.3.
#
#   1. A running VM must be shut down CLEANLY. ACPI lets mlp-tunnel-repair's
#      on_stop run, which is what removes the Gateway nameplate; a bare poweroff
#      skips it and leaks the nameplate until someone deletes it by hand.
#   2. `unregistervm --delete` does NOT clear VirtualBox's MEDIA REGISTRY. The
#      base .vmdk copy and seed.iso sitting under the data dir stay registered
#      as inaccessible orphans, and the next `clonemedium` then dies with
#      "UUID {00000000-…} does not match the value {…} stored in the media
#      registry". So every registered disk/DVD whose Location is under OUR data
#      dir gets closemedium'd by UUID — and ONLY those: another VM's media (a
#      fam-test machine, the spike image) must survive this script untouched.
function Get-VMState([string]$vbm, [string]$vm) {
    $out = Invoke-Native $vbm @('showvminfo', $vm, '--machinereadable')
    if ($script:LastNativeRc -ne 0) { return 'missing' }
    $m = $out | Select-String -Pattern '^VMState="(.*)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return 'unknown'
}

function Test-D2PortTaken([int]$p) {
    # "Is the launcher's D2 port held?" — a bind probe, not a guess: the port
    # can be some other program's, and the message must cover both.
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

# Registered media, as (uuid, location) pairs. `VBoxManage list hdds` /
# `list dvds` print blank-line-separated blocks of `Key: value` lines; the only
# two keys we need are the UUID (to closemedium it) and the Location (to decide
# whether it is OURS to touch). A block with no Location is an unattached
# medium and is skipped by the caller.
function Get-RegisteredMedia([string]$ListName) {
    $out = Invoke-Native $Vbm @('list', $ListName)
    $res = New-Object System.Collections.ArrayList
    $uuid = ''; $loc = ''
    foreach ($line in $out) {
        $s = [string]$line
        if ($s -match '^UUID:\s+(\S+)') {
            if ($uuid -ne '') { [void]$res.Add(@{ uuid = $uuid; loc = $loc }) }
            $uuid = $Matches[1]; $loc = ''
        } elseif ($s -match '^Location:\s*(.*)$') {
            $loc = $Matches[1].Trim()
        }
    }
    if ($uuid -ne '') { [void]$res.Add(@{ uuid = $uuid; loc = $loc }) }
    return $res
}

$DataRoot = (Resolve-Path -LiteralPath $DataDir).Path.TrimEnd('\') + '\'
$D2Port = 18080
if (($cfg.d2Port) -and ([int]$cfg.d2Port -gt 0)) { $D2Port = [int]$cfg.d2Port }
$ContactName = '維修的人'
if (($cfg.contactName) -and ($cfg.contactName -ne '')) { $ContactName = $cfg.contactName }

$vmState = Get-VMState $Vbm $VmName
if ($vmState -ne 'missing') {
    Write-Host ''
    Write-Host ("偵測到這台電腦已經裝過維修主機，正在換成新的（{0} 沒有要保留的東西）。" -f $VmName)

    # 1. The launcher owns the D2 port. If its window is open the family is
    #    mid-repair, so ASK — never kill their process (the ticket's rule).
    #    Closing the window is also the graceful shutdown path: the launcher's
    #    exit hook sends ACPI and waits for poweroff.
    if (Test-D2PortTaken $D2Port) {
        Write-Host ("請先把「維修連線」的視窗關掉（{0} 埠現在被佔著，那個視窗就是啟動器）。" -f $D2Port)
        Write-Host '關掉之後這裡會自己繼續；我們不會直接把你的視窗關掉。'
        $waited = 0
        while ((Test-D2PortTaken $D2Port) -and ($waited -lt 60)) { Start-Sleep -Seconds 3; $waited += 3 }
        if (Test-D2PortTaken $D2Port) {
            Write-Host ''
            Write-Host ("「維修連線」還開著，重裝取消（什麼都沒改）。請關掉那個視窗再點一次 Install.cmd；" +
                        "如果 port {0} 是別的程式佔的，請先關掉那個程式。仍然不行就聯絡「{1}」。" -f $D2Port, $ContactName)
            Write-Log ("reinstall aborted: D2 port {0} still held after {1}s" -f $D2Port, $waited)
            exit 5
        }
        Write-Log ("D2 port {0} released after {1}s" -f $D2Port, $waited)
    }

    # 2. Clean shutdown, so the Gateway nameplate gets removed. ACPI first (the
    #    guest's own on_stop does the work), 60 s, then poweroff as a last resort.
    $vmState = Get-VMState $Vbm $VmName
    if ($vmState -eq 'running') {
        Write-Host '正在關閉舊的虛擬機器（會順便把 Gateway 上的名字清掉）…'
        $null = Invoke-Native $Vbm @('controlvm', $VmName, 'acpipowerbutton')
        $deadline = (Get-Date).AddSeconds(60)
        do { Start-Sleep -Seconds 3; $vmState = Get-VMState $Vbm $VmName } while (($vmState -eq 'running') -and ((Get-Date) -lt $deadline))
        if ($vmState -eq 'running') {
            Write-Host '它沒有自己關掉，改用強制關機。'
            Write-Log 'ACPI shutdown timed out after 60s — forcing poweroff'
            $null = Invoke-Native $Vbm @('controlvm', $VmName, 'poweroff')
            Start-Sleep -Seconds 5
            $vmState = Get-VMState $Vbm $VmName
        } else { Write-Log ("ACPI shutdown done, state={0}" -f $vmState) }
    }

    # 3. Unregister and delete the machine. --delete removes the media FILES it
    #    knows about; the registry entries for our data dir's copies survive
    #    that, which is exactly what step 4 cleans up.
    Write-Host '正在移除舊的虛擬機器…'
    $out = Invoke-Native $Vbm @('unregistervm', $VmName, '--delete')
    $out | ForEach-Object { Write-Log ("unregistervm: {0}" -f $_) }
    if ($script:LastNativeRc -ne 0) {
        Write-Host '移除舊的虛擬機器失敗，重裝取消。請聯絡提供安裝包的人。'
        Write-Log ("unregistervm --delete failed rc={0}" -f $script:LastNativeRc)
        exit 4
    }

    # 4. Purge OUR orphan media by UUID. Scoped to this data dir on purpose:
    #    fam-test's VM and C:\mlp-spike must come out of this byte-identical.
    foreach ($pair in @(@('hdds', 'disk'), @('dvds', 'dvd'))) {
        foreach ($m in (Get-RegisteredMedia $pair[0])) {
            if ($m.loc -eq '') { continue }
            if (-not $m.loc.StartsWith($DataRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log ("SKIP medium {0} — outside data dir: {1}" -f $m.uuid, $m.loc)
                continue
            }
            $o = Invoke-Native $Vbm @('closemedium', $pair[1], $m.uuid)
            $rc = $script:LastNativeRc
            if ($rc -ne 0) {
                Write-Log ("closemedium {0} {1} rc={2} — retrying with --force" -f $pair[1], $m.uuid, $rc)
                $o = Invoke-Native $Vbm @('closemedium', $pair[1], $m.uuid, '--force')
                $rc = $script:LastNativeRc
            }
            $o | ForEach-Object { Write-Log ("closemedium: {0}" -f $_) }
            if ($rc -ne 0) {
                Write-Host ''
                Write-Host ("清不掉這個資料夾裡殘留的媒體紀錄（{0}，在 {1}），重裝取消。請聯絡「{2}」。" -f $m.uuid, $m.loc, $ContactName)
                Write-Log ("FAIL: could not closemedium {0} {1} at {2} (rc={3})" -f $pair[1], $m.uuid, $m.loc, $rc)
                exit 4
            }
            Write-Log ("released orphan medium {0} {1} at {2}" -f $pair[1], $m.uuid, $m.loc)
        }
    }
}

# ---- data dir + ACL (the OUT-live-repair.md §6 fix) ---------------------------------
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$script:InstallLog = Join-Path $DataDir 'install.log'
# The account name comes from WindowsIdentity, NOT "$env:USERDOMAIN\$env:USERNAME":
# on a workgroup machine USERDOMAIN is the workgroup name (e.g. WORKGROUP),
# which icacls cannot resolve ("No mapping between account names and security
# IDs") — found live. Identity.Name is the real SAM name (MACHINE\user).
$user = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
# Remove inheritance, grant ONLY this user + SYSTEM. Anyone else on this
# machine — including other local users — loses read access to the tunnel
# key in seed.iso and (after first boot) the VDI.
(Invoke-Native 'icacls' @($DataDir, '/inheritance:r', '/grant:r', ("{0}:(OI)(CI)F" -f 'SYSTEM'), ("{0}:(OI)(CI)F" -f $user))) | ForEach-Object { Write-Log ("icacls: {0}" -f $_) }
if ($script:LastNativeRc -ne 0) {
    Write-Host '資料夾權限設定失敗，安裝中止（什麼都還沒建）。請重跑安裝。'
    exit 4
}
Write-Log ("data dir locked to {0} + SYSTEM" -f $user)

# ---- seed + launcher into the locked dir ----------------------------------------------
if (-not (Test-Path $SeedIsoSrc)) {
    Write-Host '安裝包裡找不到 seed.iso（開機資料）。請向提供安裝包的人反映。'
    exit 4
}
Copy-Item -Path $SeedIsoSrc -Destination (Join-Path $DataDir 'seed.iso') -Force
if (-not (Test-Path $LauncherSrc)) {
    Write-Host '安裝包裡找不到 Start-RepairLauncher.ps1。請向提供安裝包的人反映。'
    exit 4
}
Copy-Item -Path $LauncherSrc -Destination (Join-Path $DataDir 'Start-RepairLauncher.ps1') -Force
Copy-Item -Path $ConfigPath -Destination (Join-Path $DataDir 'repair-config.json') -Force
Write-Log 'seed.iso + launcher + config copied into data dir'

# ---- cloud image (download + SHA256, or a local verified copy) --------------------------
$ImageFile = $cfg.image.file
if (($ImageFile -eq $null) -or ($ImageFile -eq '')) { $ImageFile = 'noble-server-cloudimg-amd64.vmdk' }
$ImageDst = Join-Path $DataDir $ImageFile
$ImageSha = $cfg.image.sha256
$ImageUrl = $cfg.image.url

function Test-Sha([string]$path, [string]$want) {
    if (-not (Test-Path $path)) { return $false }
    $got = (Get-FileHash -Path $path -Algorithm SHA256).Hash
    return ($got -eq $want.ToUpper())
}

$haveImage = $false
if (($ImageSource -ne '') -and (Test-Path $ImageSource)) {
    # Test hook (and USB handoff): a local file the operator points at.
    if (-not (Test-Sha $ImageSource $ImageSha)) {
        Write-Host '指定的映像檔 SHA256 不合，拒絕使用。請確認檔案正確再重跑。'
        Write-Log ("image source SHA mismatch: {0}" -f $ImageSource)
        exit 3
    }
    Copy-Item -Path $ImageSource -Destination $ImageDst -Force
    $haveImage = $true
    Write-Log ("image taken from local source {0}" -f $ImageSource)
}
if ((-not $haveImage) -and (Test-Path $ImageDst) -and (Test-Sha $ImageDst $ImageSha)) {
    $haveImage = $true
    Write-Log 'image already present and verified — reusing it'
}
if ((-not $haveImage) -and (Test-Path (Join-Path $PackageDir $ImageFile)) -and ($SkipImageDownload -eq $false)) {
    # --include-image bundles (USB handoff): use the bundled copy after check.
    if (Test-Sha (Join-Path $PackageDir $ImageFile) $ImageSha) {
        Copy-Item -Path (Join-Path $PackageDir $ImageFile) -Destination $ImageDst -Force
        $haveImage = $true
        Write-Log 'image taken from the bundle (included copy, SHA ok)'
    } else {
        Write-Host '安裝包內附的映像檔驗證沒過，已忽略，改為下載。'
        Write-Log 'bundled image SHA mismatch — falling back to download'
    }
}
if ((-not $haveImage) -and $SkipImageDownload) {
    Write-Host '找不到可用的映像檔（且指定了略過下載）。請把映像檔準備好再重跑。'
    exit 3
}
if (-not $haveImage) {
    if (($ImageUrl -eq $null) -or ($ImageUrl -eq '') -or ($ImageSha -eq $null) -or ($ImageSha -eq '')) {
        Write-Host '安裝包沒有映像檔下載資訊。請向提供安裝包的人反映。'
        exit 3
    }
    Write-Host '正在下載 Ubuntu 映像（約 600MB），請稍候…（只做這一次）'
    Write-Log ("downloading image {0}" -f $ImageUrl)
    try { Invoke-WebRequest -Uri $ImageUrl -OutFile $ImageDst -UseBasicParsing } catch {
        Remove-Item -Path $ImageDst -Force -ErrorAction SilentlyContinue
        Write-Host ("映像下載失敗：{0}。請接好網路再重跑安裝（已下載一半的檔案已刪除，不會留壞檔）。" -f $_.Exception.Message)
        exit 3
    }
    if (-not (Test-Sha $ImageDst $ImageSha)) {
        Remove-Item -Path $ImageDst -Force -ErrorAction SilentlyContinue
        Write-Host '下載到的映像驗證沒過（SHA256 不合），已刪除。請重跑安裝；一直失敗就聯絡提供安裝包的人。'
        Write-Log 'downloaded image SHA mismatch — deleted'
        exit 3
    }
    Write-Log 'image downloaded and verified'
}

# ---- VDI + VM (same shape the spike/live acceptance booted) -------------------------------
$Vdi = Join-Path $DataDir ("{0}.vdi" -f $VmName)
$SerialLog = Join-Path $DataDir 'serial.log'
# V takes ONE array argument (call sites pass an array literal like
# V @('clonemedium', ...) — the @() is array construction, not splatting, so
# it arrives as a single [string[]]; a splat-style `V @a` would NOT unpack in
# PS 5.1). It goes through Invoke-Native (see above) so a VBoxManage failure
# surfaces as our own throw with the command line, not as a raw
# RemoteException.
function V {
    param([string[]]$a)
    $out = Invoke-Native -Cmd $Vbm -Argv $a
    $rc = $script:LastNativeRc
    $out | ForEach-Object { Write-Log ("VBoxManage {0}: {1}" -f ($a -join ' '), $_) }
    if ($rc -ne 0) { throw ("VBoxManage {0} failed rc={1}" -f ($a -join ' '), $rc) }
}
try {
    V @('clonemedium', 'disk', $ImageDst, $Vdi, '--format', 'VDI')
    V @('modifymedium', 'disk', $Vdi, '--resize', '10240')
    V @('createvm', '--name', $VmName, '--ostype', 'Ubuntu_64', '--basefolder', $DataDir, '--register')
    # NAT with no port forward; localhostreachable is set EXPLICITLY (the
    # launcher depends on 10.0.2.2 reaching host loopback — spike §3(c)).
    # Serial port to a file = the diagnostic channel (design D2).
    V @('modifyvm', $VmName, '--memory', '2048', '--cpus', '2', '--nic1', 'nat', '--nat-localhostreachable1', 'on', '--uart1', '0x3F8', '4', '--uart-mode1', 'file', $SerialLog, '--audio-enabled', 'off', '--boot1', 'disk', '--boot2', 'none', '--boot3', 'none', '--boot4', 'none')
    V @('storagectl', $VmName, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '2')
    V @('storageattach', $VmName, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $Vdi)
    V @('storageattach', $VmName, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', (Join-Path $DataDir 'seed.iso'))
} catch {
    Write-Host ("VM 建立失敗：{0}。請把 data 目錄的 install.log 給提供安裝包的人看。" -f $_.Exception.Message)
    Write-Log ("VM creation failed: {0}" -f $_.Exception.Message)
    exit 4
}

# ---- verify the shape we just built (fail here, not at 2am during repair) -------------------
$info = Invoke-Native $Vbm @('showvminfo', $VmName, '--machinereadable')
if ($script:LastNativeRc -ne 0) { Write-Host 'VM 建完但讀不到資訊，請重跑安裝。'; exit 4 }
if ($info | Select-String -Pattern '^Forwarding') {
    Write-Host 'VM 不該有任何 port forward 卻出現了，安裝中止。請聯絡提供安裝包的人。'
    Write-Log 'FAIL: VM has Forwarding entries'
    exit 4
}
$vboxFile = ($info | Select-String -Pattern '^CfgFile="(.*)"$' | Select-Object -First 1).Matches[0].Groups[1].Value
$xml = Get-Content -Path $vboxFile -Raw
if ($xml -notmatch 'localhost-reachable="true"') {
    Write-Host 'VM 的 localhostreachable 沒設上，安裝中止。請聯絡提供安裝包的人。'
    Write-Log 'FAIL: localhost-reachable not true in .vbox'
    exit 4
}
Write-Log 'VM verified: NAT, no forwards, localhostreachable=true, seed attached'

# ---- desktop shortcut --------------------------------------------------------------------------
# -WindowStyle Hidden on purpose: the family must see exactly ONE window (the
# status form). A second console window is a second thing they can close, and
# closing the console instead of the form would leave the VM running without
# anyone watching (review finding). The launcher's own transcript still lands
# in launcher.log / launcher-http.log inside the data dir.
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject 'WScript.Shell'
$lnk = $shell.CreateShortcut((Join-Path $desktop '維修連線.lnk'))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = ('-WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $DataDir 'Start-RepairLauncher.ps1'))
$lnk.WorkingDirectory = $DataDir
$lnk.Description = '家人維修連線（點兩下開起維修通道）'
$lnk.Save()
Write-Log ("shortcut on desktop: {0}" -f $lnk.FullName)

Write-Host ''
Write-Host '安裝完成！'
Write-Host '以後要用時，在桌面點兩下「維修連線」，輸入名字與 IP 就可以了。'
Write-Host '（維修時會跳出一個「維修連線中」的視窗，關掉它就斷線。）'
exit 0

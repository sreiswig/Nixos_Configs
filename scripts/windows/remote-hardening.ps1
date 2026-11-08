# Remote-access hardening for Sam's Windows server.
# Not Nix-managed. Run once from an elevated PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\remote-hardening.ps1
# The installer copies itself to C:\ProgramData\remote-self-heal\ and registers
# a SYSTEM scheduled task that re-runs this file with -Check every 2 minutes.
#
# No passwords, Tailscale auth keys, or SSIDs. Auto-login is NOT enabled.

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check
)

$StateDir = 'C:\ProgramData\remote-self-heal'
$FailFile = Join-Path $StateDir 'failures'
$RebootFile = Join-Path $StateDir 'last_reboot'
$LogFile = Join-Path $StateDir 'self-heal.log'
$FailureThreshold = 9
$CooldownSec = 3600
$ScriptFile = $PSCommandPath

function Write-SelfHealLog {
    param([string]$Message)
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    }
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
        $tail = Get-Content -Path $LogFile -Tail 200 -ErrorAction SilentlyContinue
        Set-Content -Path $LogFile -Value $tail
    }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

function Get-UnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Test-Cgnat {
    param([string]$Ip)
    $parts = $Ip.Split('.')
    if ($parts.Count -ne 4) { return $false }
    if ($parts[0] -ne '100') { return $false }
    $o2 = 0
    if (-not [int]::TryParse($parts[1], [ref]$o2)) { return $false }
    return ($o2 -ge 64 -and $o2 -le 127)
}

function Get-TailscaleExe {
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-TailscaleState {
    $result = [ordered]@{
        HasExe  = $false
        Online  = $false
        Backend = ''
        IPv4    = ''
    }
    $exe = Get-TailscaleExe
    if (-not $exe) { return $result }
    $result.HasExe = $true
    $raw = & $exe status --json 2>$null | Out-String
    if ($raw) {
        try {
            $j = $raw | ConvertFrom-Json
            $result.Backend = [string]$j.BackendState
            if ($j.Self -and $j.Self.Online -eq $true) { $result.Online = $true }
        } catch {
            Write-SelfHealLog "tailscale status JSON parse failed: $($_.Exception.Message)"
        }
    }
    $ipRaw = & $exe ip -4 2>$null | Out-String
    $ip = ($ipRaw -split '\r?\n' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+' } | Select-Object -First 1)
    if ($ip) {
        $result.IPv4 = $ip.Trim()
        # Same fallback as the Nix/Spark check: an assigned tailnet IPv4 counts as up.
        $result.Online = $true
    }
    return $result
}

function Get-LanGateway {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })
    foreach ($route in ($routes | Sort-Object RouteMetric, InterfaceMetric)) {
        if ($route.InterfaceAlias -match 'Tailscale') { continue }
        if (Test-Cgnat $route.NextHop) { continue }
        return [string]$route.NextHop
    }
    return $null
}

function Read-Failures {
    if (-not (Test-Path $FailFile)) { return 0 }
    $raw = Get-Content -Path $FailFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $n = 0
    if ($raw -match '^\d+$') { $n = [int]$raw }
    return $n
}

function Test-RebootSuppressed {
    if (-not (Test-Path $RebootFile)) { return $false }
    $raw = Get-Content -Path $RebootFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($raw -notmatch '^\d+$') { return $false }
    $elapsed = (Get-UnixTime) - [int64]$raw
    return ($elapsed -lt $CooldownSec)
}

function Reset-Uplink {
    param($TailscaleExe)
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
        Write-SelfHealLog "reset adapter $($_.Name)"
        try {
            Restart-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction Stop
        } catch {
            Write-SelfHealLog "adapter reset failed for $($_.Name): $($_.Exception.Message)"
        }
    }
    try {
        Restart-Service -Name Tailscale -Force -ErrorAction Stop
        Write-SelfHealLog 'restarted Tailscale service'
    } catch {
        Write-SelfHealLog "Tailscale service restart failed: $($_.Exception.Message)"
    }
    if ($TailscaleExe) {
        $outLog = Join-Path $StateDir 'tailscale-up.out'
        $errLog = Join-Path $StateDir 'tailscale-up.err'
        $proc = Start-Process -FilePath $TailscaleExe -ArgumentList @('up', '--unattended') `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        if (-not $proc.WaitForExit(25000)) {
            try { $proc.Kill() } catch { }
            Write-SelfHealLog 'tailscale up --unattended timed out'
        }
    }
}

function Invoke-SelfHealCheck {
    $ErrorActionPreference = 'Continue'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $ts = Get-TailscaleState
    if (-not $ts.HasExe) {
        Write-SelfHealLog 'tailscale.exe missing; not counting an outage'
        return
    }
    if ($ts.Backend -in @('NeedsLogin', 'NeedsMachineAuth')) {
        Write-SelfHealLog "Tailscale $($ts.Backend); not rebooting. Run: tailscale up --unattended"
        Set-Content -Path $FailFile -Value '0'
        return
    }

    $gw = Get-LanGateway
    $gwOk = $false
    if ($gw) {
        & "$env:SystemRoot\System32\ping.exe" -n 1 -w 3000 $gw | Out-Null
        if ($LASTEXITCODE -eq 0) { $gwOk = $true }
    }

    if ($ts.Online) {
        if ($gwOk) {
            Write-SelfHealLog "OK: Tailscale online, LAN gateway $gw reachable"
        } else {
            Write-SelfHealLog "WARN: LAN gateway unreachable ($(if ($gw) { $gw } else { 'none' })) but Tailscale is online; not escalating"
        }
        Set-Content -Path $FailFile -Value '0'
        return
    }

    $n = (Read-Failures) + 1
    Set-Content -Path $FailFile -Value "$n"
    Write-SelfHealLog "FAIL: Tailscale offline (backend=$($ts.Backend)); gatewayOk=$gwOk gw=$(if ($gw) { $gw } else { 'none' }); consecutive=$n"

    $rebootNow = $false
    if ($n -ge $FailureThreshold) {
        if (Test-RebootSuppressed) {
            Write-SelfHealLog "escalation: reboot suppressed (cooldown ${CooldownSec}s)"
        } else {
            $rebootNow = $true
        }
    }

    if (-not $rebootNow) {
        Write-SelfHealLog 'escalation: reset physical adapters and restart Tailscale'
        Reset-Uplink -TailscaleExe (Get-TailscaleExe)
        return
    }

    Write-SelfHealLog 'escalation: reboot after sustained Tailscale outage'
    Set-Content -Path $RebootFile -Value "$(Get-UnixTime)"
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 60 /f /c 'remote-self-heal: Tailscale offline for about 16 minutes'
}

function Set-NeverSleep {
    Write-Output 'Power: never sleep or hibernate'
    $schemeGuids = @()
    powercfg /L | ForEach-Object {
        if ($_ -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
            $schemeGuids += $Matches[1]
        }
    }
    foreach ($guid in $schemeGuids) {
        foreach ($dc in @('/setacvalueindex', '/setdcvalueindex')) {
            powercfg $dc $guid SUB_SLEEP STANDBYIDLE 0 | Out-Null
            powercfg $dc $guid SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
            powercfg $dc $guid SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
            powercfg $dc $guid SUB_USB USBSELECTIVESUSPEND 0 | Out-Null
            powercfg $dc $guid SUB_PCIEXPRESS ASPM 0 | Out-Null
        }
    }
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-dc 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-dc 0 | Out-Null
    powercfg /change disk-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-dc 0 | Out-Null
    # High performance when that scheme exists; otherwise the current scheme keeps the timeouts above.
    $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if ($schemeGuids -contains $high) {
        powercfg /setactive $high | Out-Null
    } else {
        powercfg /setactive SCHEME_CURRENT | Out-Null
    }
    # Also turns off Fast Startup, so AC restore does a real boot and services start.
    powercfg /hibernate off | Out-Null
}

function Disable-NicPowerSaving {
    Write-Output 'NIC: disable power saving on physical adapters'
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        Write-Output "  $name"
        if (Get-Command Disable-NetAdapterPowerManagement -ErrorAction SilentlyContinue) {
            Disable-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue
        }
        $props = @(Get-NetAdapterAdvancedProperty -Name $name -ErrorAction SilentlyContinue)
        foreach ($prop in $props) {
            if ($prop.DisplayName -notmatch 'Energy|Power Saving|Green Ethernet|Ultra Low Power|EEE') { continue }
            foreach ($val in @('Disabled', 'Off', 'Disable')) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $prop.RegistryKeyword -DisplayValue $val -NoRestart -ErrorAction Stop
                    break
                } catch { }
            }
        }
        if (Test-Path $classRoot) {
            $guid = $_.InterfaceGuid
            Get-ChildItem $classRoot -ErrorAction SilentlyContinue | ForEach-Object {
                $id = $_.GetValue('NetCfgInstanceId')
                if ($id -and ($id -eq $guid)) {
                    # 24 = do not turn the device off to save power.
                    New-ItemProperty -Path $_.PSPath -Name 'PnPCapabilities' -PropertyType DWord -Value 24 -Force | Out-Null
                }
            }
        }
    }
}

function Enable-TailscaleUnattended {
    $exe = Get-TailscaleExe
    if (-not $exe) {
        Write-Warning 'Tailscale is not installed. Install it from https://tailscale.com/download/windows and re-run this script.'
        return
    }
    $svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning 'Tailscale service not found. Re-run after the Tailscale MSI finishes.'
        return
    }
    # Automatic (2), not delayed: the service starts at boot, before any login.
    & sc.exe config Tailscale start= auto | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tailscale' -Name 'DelayedAutostart' -PropertyType DWord -Value 0 -Force | Out-Null
    Set-Service -Name Tailscale -StartupType Automatic
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue
    $outLog = Join-Path $StateDir 'tailscale-up.out'
    $errLog = Join-Path $StateDir 'tailscale-up.err'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $proc = Start-Process -FilePath $exe -ArgumentList @('up', '--unattended') `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    if (-not $proc.WaitForExit(25000)) {
        try { $proc.Kill() } catch { }
        Write-Warning 'tailscale up --unattended timed out. On the console run: tailscale up --unattended'
    } elseif ($proc.ExitCode -ne 0) {
        Write-Warning "tailscale up --unattended exited $($proc.ExitCode). On the console run: tailscale up --unattended"
    }
}

function Set-TailscaleFirewallRule {
    param(
        [string]$DisplayName,
        [int]$Port
    )
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $DisplayName } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -RemoteAddress 100.64.0.0/10 -Profile Any | Out-Null
}

function Enable-RdpOverTailscale {
    param([bool]$Tighten)
    Write-Output 'RDP: enable (NLA on)'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    $rdpTcp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    if (Test-Path $rdpTcp) {
        Set-ItemProperty -Path $rdpTcp -Name 'UserAuthentication' -Value 1
    }
    Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Set-TailscaleFirewallRule -DisplayName 'RDP over Tailscale' -Port 3389
    if ($Tighten) {
        Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
        Write-Output 'RDP firewall limited to Tailscale CGNAT 100.64.0.0/10'
    } else {
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Write-Warning 'Tailscale has no IPv4 yet. RDP stays on the normal firewall rules. Re-run this script after: tailscale up --unattended'
    }
}

function Enable-OpenSshOverTailscale {
    param([bool]$Tighten)
    Write-Output 'OpenSSH Server'
    try {
        $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
        if (-not $cap) { throw 'OpenSSH Server capability not found in the image' }
        if ($cap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        }
    } catch {
        Write-Warning "OpenSSH install failed: $($_.Exception.Message). Install the OpenSSH Server optional feature and re-run."
        return
    }
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name sshd -ErrorAction SilentlyContinue
    Set-TailscaleFirewallRule -DisplayName 'OpenSSH over Tailscale' -Port 22
    if ($Tighten) {
        Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'OpenSSH*' -and $_.DisplayName -ne 'OpenSSH over Tailscale' } |
            Disable-NetFirewallRule
        Write-Output 'OpenSSH firewall limited to Tailscale CGNAT 100.64.0.0/10'
    } else {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        Write-Warning 'Tailscale has no IPv4 yet. OpenSSH stays on its default firewall rule. Re-run after tailscale up --unattended.'
    }
}

function Set-WindowsUpdateNoDaytimeReboot {
    Write-Output 'Windows Update: active hours 08:00-02:00, no auto-reboot while someone is logged on'
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    New-Item -Path $ux -Force | Out-Null
    New-ItemProperty -Path $ux -Name 'ActiveHoursStart' -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $ux -Name 'ActiveHoursEnd' -PropertyType DWord -Value 2 -Force | Out-Null
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    New-Item -Path $pol -Force | Out-Null
    New-ItemProperty -Path $pol -Name 'SetActiveHours' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $pol -Name 'ActiveHoursStart' -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $pol -Name 'ActiveHoursEnd' -PropertyType DWord -Value 2 -Force | Out-Null
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $au -Force | Out-Null
    New-ItemProperty -Path $au -Name 'NoAutoUpdate' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $au -Name 'NoAutoRebootWithLoggedOnUsers' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $au -Name 'AlwaysAutoRebootAtScheduledTime' -PropertyType DWord -Value 0 -Force | Out-Null
}

function Register-SelfHealTask {
    $dest = Join-Path $StateDir 'remote-hardening.ps1'
    $src = $ScriptFile
    if (-not $src) { throw 'Cannot locate this script path to install the scheduled task. Run it with -File.' }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $srcFull = [System.IO.Path]::GetFullPath($src)
    $destFull = [System.IO.Path]::GetFullPath($dest)
    if ($srcFull -ne $destFull) {
        Copy-Item -Force -Path $srcFull -Destination $destFull
    }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest`" -Check"
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
    try {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 2) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
    } catch {
        $trigger = New-ScheduledTaskTrigger -Daily -At '00:05' `
            -RepetitionInterval (New-TimeSpan -Minutes 2) `
            -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 50)
    }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'RemoteNetworkSelfHeal' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'Ping LAN gateway, check Tailscale, reset adapters, reboot after ~16 minutes offline.' `
        -Force | Out-Null
    Write-Output "Scheduled task RemoteNetworkSelfHeal -> $dest -Check"
}

function Show-AutoLogonTradeoff {
    Write-Output ''
    Write-Output 'Auto-login is OFF and this script does not turn it on.'
    Write-Output 'Tailscale, RDP, and OpenSSH run as services at the login screen. They do not need a logged-on desktop.'
    Write-Output 'BIOS "power on after AC loss" is what brings the machine back after a power cut.'
    Write-Output 'AutoAdminLogon stores the account password in the registry in a recoverable form, and anyone at the keyboard gets a session.'
    Write-Output 'It also fights the update setting above: a user who is always logged on will block Windows Update reboots all night.'
    Write-Output 'Set AutoAdminLogon locally only if a GUI program must already be running after power loss. Never put that password in git.'
}

function Install-RemoteHardening {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Re-run from an elevated PowerShell (Run as administrator).'
    }
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-NeverSleep
    Disable-NicPowerSaving
    Enable-TailscaleUnattended
    $ts = Get-TailscaleState
    # Tighten only when Tailscale already has a CGNAT IPv4, so this run cannot
    # lock out LAN RDP/SSH before the tailnet is up.
    $tighten = $false
    if ($ts.IPv4 -and (Test-Cgnat $ts.IPv4)) { $tighten = $true }
    Enable-RdpOverTailscale -Tighten $tighten
    Enable-OpenSshOverTailscale -Tighten $tighten
    Set-WindowsUpdateNoDaytimeReboot
    Register-SelfHealTask
    Show-AutoLogonTradeoff
    Write-Output ''
    Write-Output 'Still do these by hand:'
    Write-Output '  1. If Tailscale is not online:  tailscale up --unattended'
    Write-Output '     Then re-run this script so RDP and OpenSSH are limited to the tailnet.'
    Write-Output '  2. Disable key expiry for this node in the Tailscale admin console.'
    Write-Output '  3. Confirm the physical NIC is Ethernet and Up:  Get-NetAdapter -Physical'
    Write-Output '  4. BIOS: power on after AC loss.'
    Write-Output '  5. Optional: put your SSH public key in the Windows authorized_keys file. Do not commit it.'
    Write-Output '  6. From another tailnet node, test RDP and SSH before you walk away.'
}

if ($Check) {
    Invoke-SelfHealCheck
    exit 0
}

Install-RemoteHardening

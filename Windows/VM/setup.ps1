# Runs once, at the first sign-in of the Bezzle test VM (autounattend.xml's FirstLogonCommands).
# Installs UTM's drivers and tools, turns on SSH with the Mac's key, and sets Windows up for
# building and testing. Everything it does is logged to C:\bezzle-setup.log.

$ErrorActionPreference = 'Continue'
$disk = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript -Path C:\bezzle-setup.log -Append

# UTM's guest tools: the network card's driver above all, then display, clipboard, guest agent.
$tools = Get-ChildItem "$disk\utm-guest-tools-*.exe" | Select-Object -First 1
if ($tools) { Start-Process $tools.FullName -ArgumentList '/S' -Wait }
pnputil /add-driver "$disk\Drivers\*.inf" /subdirs /install | Out-Null

# Never sleep, never hibernate, never turn the screen off: the Mac reaches in at any time.
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

# Developer mode (unpackaged and sideloaded apps), long paths (Swift builds), no lock screen.
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization /v NoLockScreen /t REG_DWORD /d 1 /f
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f

# The VM's own address, which make-vm.sh and win use: 192.168.77.10 on UTM's shared network, whose
# first address is the Mac's (vmnet's DHCP "start" is the host; it hands out .2 to .9).
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress 192.168.77.10 -ErrorAction SilentlyContinue)) {
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress 192.168.77.10 -PrefixLength 24 -DefaultGateway 192.168.77.1 | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses 192.168.77.1
}

# Wait for the network, then the OpenSSH server, which comes from Windows Update.
for ($i = 0; $i -lt 60 -and -not (Test-NetConnection -ComputerName www.microsoft.com -Port 443 -InformationLevel Quiet); $i++) { Start-Sleep 5 }
Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 10; $i++) {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($cap.State -eq 'Installed') { break }
    Add-WindowsCapability -Online -Name $cap.Name
    Start-Sleep 15
}
New-Item -ItemType Directory -Force C:\ProgramData\ssh | Out-Null
Copy-Item "$disk\authorized_keys" C:\ProgramData\ssh\administrators_authorized_keys -Force
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'bezzle-sshd' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'bezzle-sshd' -DisplayName 'OpenSSH Server (Bezzle VM)' -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any
}

Set-Content C:\bezzle-setup-done.txt (Get-Date -Format o)
Stop-Transcript

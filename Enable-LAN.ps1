$ErrorActionPreference = 'Stop'
$name = 'Bus Dashboard - private LAN TCP 8765'
if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -Profile Private -RemoteAddress LocalSubnet | Out-Null
}

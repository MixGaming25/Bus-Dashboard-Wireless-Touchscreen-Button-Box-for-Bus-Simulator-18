param([switch]$TestMode, [int]$Port = 8765, [switch]$LoopbackOnly)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class BusInput {
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION data; }
    [StructLayout(LayoutKind.Explicit)] struct UNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT {
        public ushort vk, scan; public uint flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int x, y; public uint data, flags, time; public UIntPtr extra;
    }
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] input, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mode);
    public static string ForegroundTitle() {
        var s = new System.Text.StringBuilder(512); GetWindowText(GetForegroundWindow(), s, s.Capacity); return s.ToString();
    }
    public static bool IsGame() {
        var h = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(h, out pid);
        string name = "";
        try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
        return name.StartsWith("BusSimulator18", StringComparison.OrdinalIgnoreCase)
            || name.Equals("BusSimulator-Win64-Shipping", StringComparison.OrdinalIgnoreCase)
            || ForegroundTitle().IndexOf("Bus Simulator 18", StringComparison.OrdinalIgnoreCase) >= 0;
    }
    public static bool Tap(ushort vk) {
        var down = new INPUT { type = 1 };
        down.data.keyboard.scan = (ushort)MapVirtualKey(vk, 0);
        down.data.keyboard.flags = 8; // physical scan code, not text input
        var up = down; up.data.keyboard.flags = 8 | 2;
        uint sent = SendInput(1, new INPUT[] { down }, Marshal.SizeOf(typeof(INPUT)));
        try { Thread.Sleep(70); }
        finally { SendInput(1, new INPUT[] { up }, Marshal.SizeOf(typeof(INPUT))); }
        return sent == 1;
    }
}
'@

$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$randomBytes = New-Object byte[] 4
$random.GetBytes($randomBytes)
$random.Dispose()
$token = [string](100000 + ([BitConverter]::ToUInt32($randomBytes, 0) % 900000))
$keys = @{}
foreach ($n in 48..57) { $keys[[string][char]$n] = [uint16]$n }
foreach ($n in 65..90) { $keys[[string][char]$n] = [uint16]$n }
foreach ($n in 1..12) { $keys["F$n"] = [uint16](111 + $n) }
$keys['SPACE'] = [uint16]32
$keys['ENTER'] = [uint16]13
$keys['BACKSPACE'] = [uint16]8
$keys['TAB'] = [uint16]9
$addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress)
$allowedHosts = @('localhost', '127.0.0.1') + $addresses
$bind = [Net.IPAddress]::Any
if ($LoopbackOnly) { $bind = [Net.IPAddress]::Loopback }
$listener = New-Object Net.Sockets.TcpListener($bind, $Port)
$page = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'index.html')).Replace('__TOKEN__', $token)

function Reply($stream, [int]$status, [string]$content, [string]$type = 'application/json; charset=utf-8') {
    $bytes = [Text.Encoding]::UTF8.GetBytes($content)
    $reason = 'OK'
    if ($status -ne 200) { $reason = 'Request rejected' }
    $head = "HTTP/1.1 $status $reason`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`nConnection: close`r`n`r`n"
    $raw = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($raw, 0, $raw.Length)
    $stream.Write($bytes, 0, $bytes.Length)
}

try {
    $listener.Start()
    Write-Host ''
    Write-Host 'BUS DASHBOARD' -ForegroundColor Cyan
    if ($TestMode) { Write-Host 'TEST MODE: taps are logged; no keys are sent.' -ForegroundColor Yellow }
    else { Write-Host 'Keys are sent only while Bus Simulator 18 is the active window.' }
    Write-Host 'Open one of these addresses in Edge on your Surface (same Wi-Fi):'
    foreach ($address in $addresses) { Write-Host "  http://${address}:${Port}/$token" -ForegroundColor Green }
    Write-Host "PC preview: http://127.0.0.1:${Port}/$token"
    Write-Host 'Keep this window open. Close it or press Ctrl+C to stop.'
    Write-Host ''
    while ($true) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $stream.WriteTimeout = 2000
            # Read headers as bytes, so buffering cannot consume the request body.
            $header = New-Object 'System.Collections.Generic.List[byte]'
            while ($header.Count -lt 8192) {
                $b = $stream.ReadByte()
                if ($b -lt 0) { throw 'Connection closed' }
                $header.Add([byte]$b)
                $c = $header.Count
                if ($c -ge 4 -and $header[$c-4] -eq 13 -and $header[$c-3] -eq 10 -and $header[$c-2] -eq 13 -and $header[$c-1] -eq 10) { break }
            }
            if ($header.Count -ge 8192) { Reply $stream 400 '{"error":"Request too large"}'; continue }
            $lines = [Text.Encoding]::ASCII.GetString($header.ToArray()).Split(@("`r`n"), [StringSplitOptions]::None)
            $request = $lines[0].Split(' ')
            if ($request.Length -ne 3 -or -not $request[1].StartsWith('/')) { Reply $stream 400 '{"error":"Bad request"}'; continue }
            $headers = @{}
            foreach ($line in $lines | Select-Object -Skip 1) {
                $pos = $line.IndexOf(':')
                if ($pos -gt 0) { $headers[$line.Substring(0,$pos).ToLowerInvariant()] = $line.Substring($pos+1).Trim() }
            }
            $hostName = ([string]$headers['host'] -split ':')[0]
            if ($allowedHosts -notcontains $hostName) { Reply $stream 403 '{"error":"Host rejected"}'; continue }
            if ($headers.ContainsKey('origin') -and $headers['origin'] -ne "http://$($headers['host'])") { Reply $stream 403 '{"error":"Origin rejected"}'; continue }
            $url = New-Object Uri("http://localhost" + $request[1])
            if ($request[0] -eq 'GET' -and ($url.AbsolutePath -eq '/' -or $url.AbsolutePath -eq "/$token")) {
                if ($url.AbsolutePath -ne "/$token" -and $url.Query -ne "?token=$token") { Reply $stream 403 'Use the complete address printed in the dashboard window.' 'text/plain'; continue }
                Reply $stream 200 $page 'text/html; charset=utf-8'
                continue
            }
            if ($headers['x-dashboard-token'] -ne $token) { Reply $stream 403 '{"error":"Restarted? Reopen the address shown on the PC."}'; continue }
            if ($request[0] -eq 'GET' -and $url.AbsolutePath -eq '/status') {
                $data = @{ testMode = [bool]$TestMode; gameActive = [BusInput]::IsGame(); title = [BusInput]::ForegroundTitle() } | ConvertTo-Json -Compress
                Reply $stream 200 $data
            } elseif ($request[0] -eq 'POST' -and $url.AbsolutePath -eq '/press') {
                $length = 0
                if (-not [int]::TryParse([string]$headers['content-length'], [ref]$length) -or $length -lt 1 -or $length -gt 16) { Reply $stream 400 '{"error":"Bad key request"}'; continue }
                $body = New-Object byte[] $length
                $offset = 0
                while ($offset -lt $length) {
                    $count = $stream.Read($body, $offset, $length-$offset)
                    if ($count -eq 0) { throw 'Incomplete body' }
                    $offset += $count
                }
                $key = [Text.Encoding]::ASCII.GetString($body)
                if (-not $keys.ContainsKey($key)) { Reply $stream 400 '{"error":"Unsupported key"}'; continue }
                if (-not $TestMode -and -not [BusInput]::IsGame()) { Reply $stream 409 '{"error":"Focus Bus Simulator 18 on the PC first."}'; continue }
                if (-not $TestMode -and -not [BusInput]::Tap($keys[$key])) { Reply $stream 500 '{"error":"Windows blocked input. See README."}'; continue }
                Write-Host ("{0:HH:mm:ss}  {1} {2}" -f (Get-Date), $(if ($TestMode) { 'TEST' } else { 'KEY' }), $key)
                Reply $stream 200 '{"ok":true}'
            } else { Reply $stream 404 '{"error":"Unknown action"}' }
        } catch {
            Write-Host ('Request interrupted: ' + $_.Exception.Message) -ForegroundColor DarkGray
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }

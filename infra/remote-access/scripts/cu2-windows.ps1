# CU2: connects the dev client through OpenVPN-GUI and checks the acceptance criteria.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$Remote = Split-Path $PSScriptRoot
$Gui = Join-Path $env:ProgramFiles 'OpenVPN\bin\openvpn-gui.exe'
$Client = 'dev-02'
$ClientIp = '10.8.0.11'
$Failed = 0

function Check($ok, $message) {
    if ($ok) { Write-Host "  [OK] $message" -ForegroundColor Green }
    else { Write-Host "  [FALLO] $message" -ForegroundColor Red; $script:Failed++ }
}

function Wait-For([scriptblock]$Condition, [int]$TimeoutSeconds) {
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $end)
}

Write-Host "`n[PASO] Importando $Client en OpenVPN-GUI y conectando..."
$Config = Join-Path $env:USERPROFILE 'OpenVPN\config'
New-Item -ItemType Directory -Force $Config | Out-Null
$Ovpn = Join-Path $Remote "profiles\$Client.ovpn"
Copy-Item $Ovpn $Config -Force
# A profile with this name imported for all users in an earlier run of the lab has another CA: replace it too.
$AllUsers = Join-Path $env:ProgramFiles "OpenVPN\config\$Client.ovpn"
if (Test-Path $AllUsers) { Copy-Item $Ovpn $AllUsers -Force }
$Tunnel = { Get-NetIPAddress -IPAddress $ClientIp -ErrorAction SilentlyContinue }
if (-not (& $Tunnel)) {
    if (Get-Process openvpn-gui -ErrorAction SilentlyContinue) { & $Gui --command connect $Client }
    else { Start-Process $Gui -ArgumentList '--connect', $Client }
}
$ip = Wait-For $Tunnel 60
Check $ip "El cliente obtuvo $ClientIp en la interfaz '$($ip.InterfaceAlias)'."
if (-not $ip) {
    Write-Host "  No hay tunel: abri el log de $Client en OpenVPN-GUI (clic derecho en el icono > $Client > Mostrar log)."
    exit 1
}

Write-Host "`n[PASO] DNS: el sufijo the-store.internal se resuelve contra 10.8.0.1 (NRPT)..."
$rule = Get-DnsClientNrptPolicy -Effective | Where-Object { $_.Namespace -eq '.the-store.internal' -and $_.NameServers -contains '10.8.0.1' }
Check $rule 'Regla NRPT efectiva: .the-store.internal -> 10.8.0.1.'
foreach ($name in 'ui', 'catalog') {
    $fqdn = "$name.the-store.internal"
    $answer = Wait-For { Resolve-DnsName $fqdn -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object IPAddress } 20
    Check $answer "$fqdn -> $($answer.IPAddress -join ',') (Resolve-DnsName sin -Server)."
}

Write-Host "`n[PASO] La tienda y la API de catalog por nombre..."
$page = curl.exe --noproxy '*' -fsS --max-time 10 http://ui.the-store.internal/home | Out-String
$title = [regex]::Match($page, '<title>(.*?)</title>').Groups[1].Value
Check $title "http://ui.the-store.internal/home responde: '$title'."
$json = curl.exe --noproxy '*' -fsS --max-time 10 http://catalog.the-store.internal/catalog/products | Out-String
$products = try { $json | ConvertFrom-Json } catch { $null }
Check $products "http://catalog.the-store.internal/catalog/products devuelve $(@($products).Count) productos."

Write-Host "`n[PASO] Log de gw-vpn: verificacion del certificado de $Client..."
# ssh.exe rejects a private key that other users can read, so it uses a private copy.
$key = Join-Path $env:TEMP 'the-store-host-key'
Copy-Item (Join-Path $Remote 'profiles\host_admin_ed25519') $key -Force
icacls $key /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
try {
    $log = ssh -i $key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5 -o LogLevel=ERROR home@192.168.100.1 "echo bishbashbosh | sudo -S journalctl -u openvpn-server@the-store -b --no-pager 2>/dev/null | grep -E '203\.0\.113\.50:[0-9]+ VERIFY OK: depth=0, CN=$Client' | tail -n 1"
}
finally { Remove-Item $key -Force }
Check $log "openvpn-server@the-store registro: $log"

Write-Host ''
if ($Failed) { Write-Host "CU2: fallaron $Failed verificaciones." -ForegroundColor Red; exit 1 }
Write-Host "CU2: todas las verificaciones pasaron. $Client sigue conectado: abri http://ui.the-store.internal en el navegador." -ForegroundColor Green

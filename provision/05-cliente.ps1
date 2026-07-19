Param([string]$DcIp = "192.168.56.10", [string]$Domain = "lab.local")
$ErrorActionPreference = "Stop"
function Log($m) { Write-Host "[join] $m" }

$nic = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.56.*' } | Select-Object -First 1
if ($nic) {
  Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses $DcIp
  Log "DNS de la tarjeta privada -> $DcIp"
}

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $Domain) { Log "Ya unido a $Domain; nada que hacer."; return }

$ok = $false
for ($i = 0; $i -lt 30 -and -not $ok; $i++) {
  try { Resolve-DnsName $Domain -ErrorAction Stop | Out-Null; $ok = $true }
  catch { Start-Sleep -Seconds 10 }
}
if (-not $ok) { throw "El dominio $Domain no resuelve; el DC no esta disponible en $DcIp." }

$sec  = ConvertTo-SecureString 'vagrant' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("LAB\vagrant", $sec)
Add-Computer -DomainName $Domain -Credential $cred -Force
Log "Maquina unida a $Domain. Reiniciando para completar la union..."

& shutdown.exe /r /t 5 /c "ad-lab: completar union al dominio"

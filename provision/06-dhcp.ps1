$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "[dhcp] $m" }

# Configuracion declarativa (lab.psd1), con valores por defecto si falta
$cfgFile = Join-Path $PSScriptRoot '..\lab.psd1'
$cfg = if (Test-Path $cfgFile) { Import-PowerShellDataFile -Path $cfgFile } else { @{} }
function Conf($v, $d) { if ($null -ne $v -and "$v" -ne '') { $v } else { $d } }
$dominio      = Conf $cfg.Dominio 'lab.local'
$dhcpCfg      = if ($cfg.Dhcp) { $cfg.Dhcp } else { @{} }
$nombreAmbito = Conf $dhcpCfg.Ambito 'Red del laboratorio'
$rangoInicio  = Conf $dhcpCfg.RangoInicio '192.168.56.100'
$rangoFin     = Conf $dhcpCfg.RangoFin '192.168.56.149'
$mascara      = Conf $dhcpCfg.Mascara '255.255.255.0'
$puertaEnlace = Conf $dhcpCfg.PuertaEnlace '192.168.56.1'
$concesion    = [TimeSpan](Conf $dhcpCfg.DuracionConcesion '0.08:00:00')
$reserva      = $dhcpCfg.Reserva

# El ScopeId de un ambito /24 es la direccion de red del rango
$scopeId = $rangoInicio -replace '\.\d+$', '.0'

# La IP del DC en la red privada: desde ahi sirve DHCP y es el DNS que se anuncia
$nic = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.56.*' } | Select-Object -First 1
if (-not $nic) { throw 'No encuentro la tarjeta de la red privada 192.168.56.x.' }
$dcIp = $nic.IPAddress

# Autorizar el servidor DHCP en AD (Add-DhcpServerInDC, mas abajo) escribe en la
# particion de Configuracion del BOSQUE (CN=NetServices), y eso exige Enterprise
# Admins: Domain Admins no basta. Si falta, el cmdlet aborta con un cripto
# "Failed to initialize directory service resources ... WIN32 5". Se comprueba
# aqui, sobre el token EFECTIVO (no solo la membresia en AD), porque anadir la
# cuenta a un grupo no cuenta hasta reiniciar sesion. En produccion se delegaria
# solo sobre CN=NetServices en vez de conceder Enterprise Admins.
try {
  $eaSid = (Get-ADGroup 'Enterprise Admins' -ErrorAction Stop).SID
  $token = [Security.Principal.WindowsIdentity]::GetCurrent()
  $esEnterpriseAdmin = $token.Groups -contains $eaSid
} catch { $esEnterpriseAdmin = $false }
if (-not $esEnterpriseAdmin) {
  Log 'ERROR: autorizar el servidor DHCP en AD requiere Enterprise Admins.'
  Log '  El registro de autorizacion vive en la particion de Configuracion del'
  Log '  bosque (CN=NetServices), no en el dominio, y Domain Admins no basta.'
  Log '  Ejecuta una vez, como admin del dominio, cierra la sesion y reconecta'
  Log '  (para refrescar el token) y relanza este script:'
  Log "      Add-ADGroupMember 'Enterprise Admins' -Members vagrant"
  exit 10
}

# --- 1. Rol DHCP --------------------------------------------------------------
if ((Get-WindowsFeature -Name DHCP).Installed) {
  Log 'Rol DHCP ya instalado; no reinstalo.'
} else {
  Log 'Instalando el rol DHCP...'
  Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
  Log 'Rol DHCP instalado.'
}

# Post-instalacion: grupos de seguridad del servicio (DHCP Administrators/Users);
# netsh es idempotente aqui (si ya existen, no los duplica).
& netsh dhcp add securitygroups | Out-Null
# Marca el post-install como completado para que Server Manager no pida su asistente.
$smKey = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
if (-not (Test-Path $smKey)) { New-Item -Path $smKey -Force | Out-Null }
Set-ItemProperty -Path $smKey -Name 'ConfigurationState' -Value 2
if ((Get-Service dhcpserver).Status -ne 'Running') { Start-Service dhcpserver }

# El servicio solo escucha en la tarjeta del lab: la NAT de Vagrant no es nuestra
# red y repartir IPs ahi seria pisar el DHCP del propio VirtualBox.
foreach ($b in Get-DhcpServerv4Binding) {
  $debeEscuchar = ($b.IPAddress -eq $dcIp)
  if ($b.BindingState -ne $debeEscuchar) {
    Set-DhcpServerv4Binding -InterfaceAlias $b.InterfaceAlias -BindingState $debeEscuchar
    Log "Binding $($b.InterfaceAlias) ($($b.IPAddress)) -> escuchar: $debeEscuchar"
  }
}

# --- 2. Autorizacion en Active Directory --------------------------------------
# En un dominio, un servidor DHCP no autorizado en AD no sirve concesiones:
# es la proteccion de serie contra servidores DHCP "pirata" (rogue DHCP).
$fqdn = "$env:COMPUTERNAME.$dominio".ToLower()
$autorizado = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue) | Where-Object { $_.IPAddress -eq $dcIp }
if ($autorizado) {
  Log "Servidor ya autorizado en AD ($dcIp); nada que hacer."
} else {
  Add-DhcpServerInDC -DnsName $fqdn -IPAddress $dcIp
  Restart-Service dhcpserver
  Log "Servidor DHCP autorizado en AD como $fqdn ($dcIp)."
}

# --- 3. Ambito de la red del lab ----------------------------------------------
# El rango arranca en .100 para no pisar las IPs estaticas del ecosistema
# (.10 DC, .11/.12 zabbix, .15 RHEL, .20 cliente, .25 GLPI, .30 zabbix-server).
if (Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue) {
  Log "Ambito $scopeId ya existe; no lo duplico."
} else {
  Add-DhcpServerv4Scope -Name $nombreAmbito -StartRange $rangoInicio -EndRange $rangoFin `
    -SubnetMask $mascara -State Active -LeaseDuration $concesion
  Log "Ambito $scopeId creado ($rangoInicio - $rangoFin, concesion $concesion)."
}

# Opciones del ambito: los clientes reciben el DNS del dominio (el propio DC),
# el sufijo DNS y la puerta de enlace. Set-* es idempotente: fija el valor.
# (-Force evita que el cmdlet valide el DNS por red antes de aceptarlo.)
Set-DhcpServerv4OptionValue -ScopeId $scopeId -DnsServer $dcIp -DnsDomain $dominio `
  -Router $puertaEnlace -Force
Log "Opciones del ambito: DNS $dcIp, sufijo $dominio, puerta de enlace $puertaEnlace."

# --- 4. Reserva de ejemplo -----------------------------------------------------
# Una reserva ata una IP concreta a una MAC: el dispositivo se configura igual
# que todos (por DHCP), pero recibe siempre la misma direccion. Es lo tipico
# para impresoras o equipos a los que otros apuntan por IP: direccion estable
# sin tocar el dispositivo y documentada en el servidor, no en un post-it.
if ($reserva -and $reserva.IP) {
  $yaReservada = Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $reserva.IP }
  if ($yaReservada) {
    Log "Reserva $($reserva.IP) ya existe; no la duplico."
  } else {
    Add-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $reserva.IP `
      -ClientId $reserva.MAC -Name $reserva.Nombre -Description 'Reserva de ejemplo (definida en lab.psd1)'
    Log "Reserva creada: $($reserva.Nombre) -> $($reserva.IP) ($($reserva.MAC))."
  }
}

# --- 5. Verificacion -----------------------------------------------------------
# Tres comprobaciones PASS/FAIL, al estilo de auditoria.ps1. El codigo de
# salida es el numero de fallos, para poder consumirlo desde una pipeline.
$checks = New-Object System.Collections.Generic.List[object]
function Check($id, $name, [bool]$ok, $detail) {
  $checks.Add([pscustomobject]@{ Id = $id; Control = $name; Estado = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detalle = $detail })
}

$svc = Get-Service dhcpserver -ErrorAction SilentlyContinue
Check 'DHCP-01' 'Servicio DHCPServer instalado y corriendo' ($svc -and $svc.Status -eq 'Running') "estado: $(if ($svc) { $svc.Status } else { 'no instalado' })"

$enAd = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $dcIp })
Check 'DHCP-02' 'Servidor autorizado en Active Directory' ($enAd.Count -gt 0) "autorizados con $dcIp : $($enAd.Count)"

$sc = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
$dnsOpt = (Get-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 6 -ErrorAction SilentlyContinue).Value
Check 'DHCP-03' 'Ambito activo con DNS apuntando al DC' ($sc -and $sc.State -eq 'Active' -and $dnsOpt -contains $dcIp) "ambito: $(if ($sc) { $sc.State } else { 'no existe' }), DNS: $($dnsOpt -join ',')"

Write-Host ''
Write-Host ("====  VERIFICACION DHCP  ·  {0}  ====" -f $scopeId) -ForegroundColor Cyan
foreach ($r in $checks) {
  $color = if ($r.Estado -eq 'PASS') { 'Green' } else { 'Red' }
  $mark = if ($r.Estado -eq 'PASS') { '[ OK ]' } else { '[FAIL]' }
  Write-Host ("{0}  {1,-8} {2,-44} {3}" -f $mark, $r.Id, $r.Control, $r.Detalle) -ForegroundColor $color
}
$fallos = @($checks | Where-Object Estado -eq 'FAIL').Count
Write-Host ''
if ($fallos -eq 0) { Log 'DHCP operativo: rol instalado, autorizado en AD y ambito activo.' }
else { Log "ATENCION: $fallos comprobacion(es) han fallado." }
exit $fallos

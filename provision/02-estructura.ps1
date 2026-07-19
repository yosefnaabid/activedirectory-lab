$ErrorActionPreference = 'Stop'
$LogDir = 'C:\lab\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory $LogDir -Force | Out-Null }
$report = Join-Path $LogDir 'dc-setup.log'
function Log($m) {
  $l = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $l
  Add-Content -Path $report -Value $l -Encoding UTF8
}

$cfgFile = Join-Path $PSScriptRoot '..\lab.psd1'
$cfg = if (Test-Path $cfgFile) { Import-PowerShellDataFile -Path $cfgFile } else { @{} }
function Conf($v, $d) { if ($null -ne $v -and "$v" -ne '') { $v } else { $d } }
$dominioCfg   = Conf $cfg.Dominio 'lab.local'
$nomUsuarios  = Conf $cfg.OU.Usuarios 'Usuarios'
$nomBajas     = Conf $cfg.OU.Bajas 'Bajas'
$nomGrupos    = Conf $cfg.OU.Grupos 'Grupos'
$homesRuta    = Conf $cfg.HomesRuta 'C:\Homes'
$homesRecurso = Conf $cfg.HomesRecurso 'Homes'
$gpoBaseline  = Conf $cfg.GpoBaseline 'LAB-Baseline'

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole

if ($role -lt 4) {

  try {
    Log "[fase1] Instalando rol AD DS (por si acaso) y promocionando lab.local..."
    Install-WindowsFeature -Name AD-Domain-Services, GPMC -IncludeManagementTools | Out-Null
    Import-Module ADDSDeployment
    $dsrm = ConvertTo-SecureString (Conf $cfg.DsrmPassword 'LabDSRM.2026') -AsPlainText -Force
    Install-ADDSForest `
      -DomainName $dominioCfg `
      -DomainNetbiosName (Conf $cfg.NetBIOS 'LAB') `
      -ForestMode (Conf $cfg.NivelBosque 'WinThreshold') `
      -DomainMode (Conf $cfg.NivelBosque 'WinThreshold') `
      -InstallDns `
      -SafeModeAdministratorPassword $dsrm `
      -NoRebootOnCompletion `
      -Force | Out-Null
    Log "[fase1] Promocion configurada. Reiniciando para completarla..."
  }
  catch {
    Log "[fase1] ERROR: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 3
  & shutdown.exe /r /t 5 /c "ad-lab: completar promocion"
  return
}

try {
  Log "[fase2] Esperando a que Active Directory este disponible..."
  $ok = $false
  for ($i = 0; $i -lt 60 -and -not $ok; $i++) {
    try { Import-Module ActiveDirectory -ErrorAction Stop; Get-ADDomain -ErrorAction Stop | Out-Null; $ok = $true }
    catch { Start-Sleep -Seconds 10 }
  }
  if (-not $ok) { throw "Active Directory no respondio a tiempo." }
  $domainDN = (Get-ADDomain).DistinguishedName
  Log "[fase2] Dominio operativo: $domainDN"

  $nic = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.56.*' } | Select-Object -First 1
  if ($nic) { Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses '127.0.0.1'; Log "[fase2] DNS de la tarjeta del dominio -> 127.0.0.1" }

  $rb = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'"
  if (-not $rb.EnabledScopes) {
    Enable-ADOptionalFeature $rb -Scope ForestOrConfigurationSet -Target (Get-ADForest).Name -Confirm:$false
    Log "[fase2] Papelera de AD habilitada"
  }

  function Ensure-OU($Name, $Path) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
      New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
      Log "[fase2] OU creada: OU=$Name,$Path"
    }
  }
  Ensure-OU $nomUsuarios $domainDN
  Ensure-OU $nomBajas    $domainDN
  Ensure-OU $nomGrupos   $domainDN

  $homes = $homesRuta
  if (-not (Test-Path $homes)) { New-Item -ItemType Directory $homes | Out-Null }
  if (-not (Get-SmbShare -Name $homesRecurso -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $homesRecurso -Path $homes -FullAccess 'Administrators' -ChangeAccess 'Authenticated Users' | Out-Null
    Log "[fase2] Recurso compartido \\$env:COMPUTERNAME\$homesRecurso creado"
  }

  Import-Module GroupPolicy
  if (-not (Get-GPO -Name $gpoBaseline -ErrorAction SilentlyContinue)) {
    New-GPO -Name $gpoBaseline -Comment 'Linea base del laboratorio (definida por codigo)' | Out-Null
    Log "[fase2] GPO $gpoBaseline creada"
  }
  $k = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System'
  Set-GPRegistryValue -Name $gpoBaseline -Key $k -ValueName 'legalnoticecaption' -Type String -Value "Laboratorio $dominioCfg" | Out-Null
  Set-GPRegistryValue -Name $gpoBaseline -Key $k -ValueName 'legalnoticetext' -Type String -Value 'Acceso restringido. Entorno de laboratorio administrado por codigo.' | Out-Null
  try { New-GPLink -Name $gpoBaseline -Target $domainDN -LinkEnabled Yes -ErrorAction Stop | Out-Null; Log "[fase2] GPO enlazada al dominio" }
  catch { Log "[fase2] GPO ya estaba enlazada" }

  if (Test-Path 'C:\lab\scripts\usuarios.ps1') {
    Log "[fase2] Alta inicial de usuarios desde el CSV..."
    & 'C:\lab\scripts\usuarios.ps1' -Accion alta -CsvPath 'C:\lab\scripts\usuarios.csv' *>> $report
  }

  # Grupos declarados en lab.psd1 fuera del ciclo por departamento (p. ej.
  # G-LinuxAdmins, que da sudo en el nodo RHEL). Van despues del alta para
  # poder anadirles miembros del CSV.
  if ($cfg.GruposAdicionales) {
    foreach ($g in $cfg.GruposAdicionales.GetEnumerator()) {
      if (-not (Get-ADGroup -Filter "Name -eq '$($g.Key)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Key -GroupScope Global -GroupCategory Security `
          -Path "OU=$nomGrupos,$domainDN" -Description $g.Value.Descripcion | Out-Null
        Log "[fase2] Grupo adicional creado: $($g.Key)"
      }
      foreach ($m in @($g.Value.Miembros)) {
        $u = Get-ADUser -Filter "SamAccountName -eq '$m'" -ErrorAction SilentlyContinue
        if (-not $u) { Log "[fase2] aviso: el usuario $m no existe; no lo anado a $($g.Key)"; continue }
        if (-not (Get-ADGroupMember -Identity $g.Key | Where-Object { $_.SamAccountName -eq $m })) {
          Add-ADGroupMember -Identity $g.Key -Members $m
          Log "[fase2] $m anadido a $($g.Key)"
        }
      }
    }
  }

  # La cuenta vagrant queda como Domain Admin tras la promocion, pero autorizar
  # el servidor DHCP en AD (06-dhcp.ps1) escribe en la particion de Configuracion
  # del BOSQUE y eso exige Enterprise Admins. Se anade aqui para que el
  # provisioner 'dhcp' funcione sin pasos manuales. Best-effort: si la cuenta que
  # ejecuta esta fase no puede tocar ese grupo protegido, se registra y se sigue;
  # el propio 06-dhcp.ps1 avisa con instrucciones si el privilegio faltara.
  try {
    if (-not (Get-ADGroupMember 'Enterprise Admins' | Where-Object { $_.SamAccountName -eq 'vagrant' })) {
      Add-ADGroupMember -Identity 'Enterprise Admins' -Members 'vagrant' -ErrorAction Stop
      Log "[fase2] vagrant anadido a Enterprise Admins (necesario para autorizar DHCP en AD)"
    }
  } catch {
    Log "[fase2] aviso: no pude anadir vagrant a Enterprise Admins ($($_.Exception.Message)); 06-dhcp.ps1 lo indicara si hace falta"
  }

  if (Test-Path 'C:\lab\provision\04-gpos.ps1') {
    Log "[fase2] Creando GPOs de usuario (panel de control, fondo, mapeo H:)..."
    & 'C:\lab\provision\04-gpos.ps1' *>> $report
  }
  Log "[fase2] CONFIGURACION COMPLETADA."
}
catch {
  Log "[fase2] ERROR: $($_.Exception.Message)"
}
finally {
  try { Unregister-ScheduledTask -TaskName 'LabDCSetup' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

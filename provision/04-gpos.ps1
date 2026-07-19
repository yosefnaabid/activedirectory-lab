Import-Module ActiveDirectory
Import-Module GroupPolicy
function Log($m) { Write-Host "[gpo] $m" }
function Step($name, [scriptblock]$action) {
  try { $ErrorActionPreference = 'Stop'; & $action; Log "OK  · $name" }
  catch { Log "ERR · $name -> $($_.Exception.Message)" }
}

$cfgFile = Join-Path $PSScriptRoot '..\lab.psd1'
$cfg = if (Test-Path $cfgFile) { Import-PowerShellDataFile -Path $cfgFile } else { @{} }
function Conf($v, $d) { if ($null -ne $v -and "$v" -ne '') { $v } else { $d } }
$nomUsuarios  = Conf $cfg.OU.Usuarios 'Usuarios'
$grpEmpleados = Conf $cfg.GrupoEmpleados 'G-Empleados'
$homesRecurso = Conf $cfg.HomesRecurso 'Homes'

$domain      = Get-ADDomain
$domainDN    = $domain.DistinguishedName
$usuariosOU  = "OU=$nomUsuarios,$domainDN"
$netlogon    = Join-Path $env:SystemRoot "SYSVOL\sysvol\$($domain.DNSRoot)\scripts"

function Ensure-GPO($name, $comment) {
  $g = Get-GPO -Name $name -ErrorAction SilentlyContinue
  if (-not $g) { $g = New-GPO -Name $name -Comment $comment }
  try { New-GPLink -Name $name -Target $usuariosOU -LinkEnabled Yes -ErrorAction Stop | Out-Null }
  catch { }
  return $g
}

Step 'GPO LAB-PanelControl-Restringido (oculta el Panel de control)' {
  Ensure-GPO 'LAB-PanelControl-Restringido' 'Restringe el Panel de control a los usuarios (por codigo)' | Out-Null
  Set-GPRegistryValue -Name 'LAB-PanelControl-Restringido' `
    -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
    -ValueName 'NoControlPanel' -Type DWord -Value 1 | Out-Null
}

Step 'GPO LAB-Fondo-Corporativo (fondo de escritorio + estilo)' {
  Ensure-GPO 'LAB-Fondo-Corporativo' 'Fondo de escritorio corporativo (por codigo)' | Out-Null

  $bmp = Join-Path $netlogon 'lab-wallpaper.bmp'
  if (-not (Test-Path $bmp)) {
    Add-Type -AssemblyName System.Drawing
    $w = 1920; $h = 1080
    $img = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($img)
    $g.Clear([System.Drawing.Color]::FromArgb(20, 23, 28))
    $f1 = New-Object System.Drawing.Font('Consolas', 64, [System.Drawing.FontStyle]::Bold)
    $f2 = New-Object System.Drawing.Font('Consolas', 28)
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(217, 142, 50))
    $bd = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(139, 144, 154))
    $g.DrawString($domain.DNSRoot, $f1, $br, 120, 440)
    $g.DrawString('Entorno corporativo - acceso restringido - uso monitorizado', $f2, $bd, 128, 560)
    $img.Save($bmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $g.Dispose(); $img.Dispose()
  }
  $unc = "\\$($domain.DNSRoot)\NETLOGON\lab-wallpaper.bmp"
  $k = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'
  Set-GPRegistryValue -Name 'LAB-Fondo-Corporativo' -Key $k -ValueName 'Wallpaper'      -Type String -Value $unc | Out-Null
  Set-GPRegistryValue -Name 'LAB-Fondo-Corporativo' -Key $k -ValueName 'WallpaperStyle' -Type String -Value '2'  | Out-Null
}

Step 'GPO LAB-Mapeo-Unidad-H (H: -> \\dc01\Homes, filtrado a G-Empleados)' {
  $gpo = Ensure-GPO 'LAB-Mapeo-Unidad-H' 'Mapea H: a \\dc01\Homes para G-Empleados (GPP)'
  $gpoId = "{$($gpo.Id.ToString().ToUpper())}"
  $polDir = Join-Path $env:SystemRoot "SYSVOL\sysvol\$($domain.DNSRoot)\Policies\$gpoId"
  $drvDir = Join-Path $polDir 'User\Preferences\Drives'
  New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
  $uid = "{$([guid]::NewGuid().ToString().ToUpper())}"
  $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
	<Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="H:" status="H:" image="2" changed="2026-01-01 00:00:00" uid="$uid" bypassErrors="1">
		<Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\dc01\$homesRecurso" label="$homesRecurso" persistent="0" useLetter="1" letter="H"/>
	</Drive>
</Drives>
"@
  Set-Content -Path (Join-Path $drvDir 'Drives.xml') -Value $xml -Encoding UTF8

  $cse = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
  $gpoDN = "CN=$gpoId,CN=Policies,CN=System,$domainDN"
  Set-ADObject $gpoDN -Replace @{ gPCUserExtensionNames = $cse }

  Set-GPPermission -Name 'LAB-Mapeo-Unidad-H' -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
  Set-GPPermission -Name 'LAB-Mapeo-Unidad-H' -TargetName $grpEmpleados         -TargetType Group -PermissionLevel GpoApply | Out-Null
}

Log 'GPOs de usuario creadas y enlazadas a la OU Usuarios.'
Log 'El efecto se ve al iniciar sesion un usuario del dominio en el cliente (cli01).'

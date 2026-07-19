$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "[dc-prep] $m" }

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($role -ge 4) { Log "La VM ya es controlador de dominio. Nada que hacer."; exit 0 }

$src = 'C:\vagrant'
if (-not (Test-Path "$src\provision\02-estructura.ps1")) {
  throw "No encuentro los scripts del lab en $src. La carpeta compartida de Vagrant no esta montada."
}
New-Item -ItemType Directory 'C:\lab\provision' -Force | Out-Null
New-Item -ItemType Directory 'C:\lab\scripts'   -Force | Out-Null
Copy-Item "$src\provision\*" 'C:\lab\provision\' -Force
Copy-Item "$src\scripts\*"   'C:\lab\scripts\'   -Force
if (Test-Path "$src\lab.psd1") { Copy-Item "$src\lab.psd1" 'C:\lab\' -Force }
Log "Scripts del lab copiados a C:\lab"

Log "Instalando el rol AD DS y GPMC..."
Install-WindowsFeature -Name AD-Domain-Services, GPMC -IncludeManagementTools | Out-Null

Log "Programando la promocion + configuracion del DC (como SYSTEM, tras reiniciar)..."
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\lab\provision\02-estructura.ps1'
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'LabDCSetup' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

Log "Reiniciando en 20s. La tarea 'LabDCSetup' promocionara y configurara el DC."
& shutdown.exe /r /t 20 /c "ad-lab: preparar promocion de Active Directory"

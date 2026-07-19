[CmdletBinding()]
param(
    [int]$Horas = 24,
    [string]$CsvOut
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$catalogo = @{
    4728 = 'Miembro anadido a grupo global con seguridad'
    4732 = 'Miembro anadido a grupo local con seguridad'
    4740 = 'Cuenta bloqueada'
    4625 = 'Fallo de inicio de sesion'
    4662 = 'Acceso a derechos de replicacion (posible DCSync)'
}
$gruposCriticos = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Administradores'
$replGuids = '1131f6aa-9c07-11d1-f79f-00c04fc2dcd2',
             '1131f6ad-9c07-11d1-f79f-00c04fc2dcd2',
             '89e95b76-444d-4c62-991a-0facbeda640c'
$inicio = (Get-Date).AddHours(-$Horas)

$eventos = Get-WinEvent -FilterHashtable @{
    LogName   = 'Security'
    Id        = @($catalogo.Keys)
    StartTime = $inicio
} -ErrorAction SilentlyContinue

$filas = foreach ($e in $eventos) {
    $msg = $e.Message
    $incluir = $true
    $alerta = ''
    switch ([int]$e.Id) {
        { $_ -in 4728, 4732 } {
            if ($gruposCriticos | Where-Object { $msg -match [regex]::Escape($_) }) { $alerta = 'ALERTA' }
        }
        4662 {
            $esReplicacion = [bool]($replGuids | Where-Object { $msg -match $_ })
            $deMaquina     = $msg -match '[A-Za-z0-9._-]+\$'
            if ($esReplicacion -and -not $deMaquina) { $alerta = 'ALERTA' } else { $incluir = $false }
        }
    }
    if ($incluir) {
        [pscustomobject]@{
            Hora    = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
            Id      = $e.Id
            Evento  = $catalogo[[int]$e.Id]
            Alerta  = $alerta
            Resumen = ($msg -split "`n" | Select-Object -First 1).Trim()
        }
    }
}
$filas = @($filas | Sort-Object Hora)

Write-Host ""
Write-Host ("====  EVENTOS DE SEGURIDAD DE AD  (ultimas {0} h)  ====" -f $Horas) -ForegroundColor Cyan
Write-Host ""
if (-not $filas.Count) {
    Write-Host "Sin eventos de las categorias vigiladas en la ventana." -ForegroundColor Green
} else {
    foreach ($f in $filas) {
        $color = if ($f.Alerta) { 'Red' } elseif ($f.Id -in 4740, 4625) { 'Yellow' } else { 'Gray' }
        Write-Host ("{0}  {1,-6} {2,-6} {3}" -f $f.Hora, $f.Id, $f.Alerta, $f.Evento) -ForegroundColor $color
    }
}

$alertas = @($filas | Where-Object Alerta).Count
Write-Host ""
Write-Host ("RESUMEN: {0} evento(s), {1} alerta(s) sobre grupos privilegiados o replicacion." -f $filas.Count, $alertas) -ForegroundColor $(if ($alertas) { 'Red' } else { 'Green' })

if ($CsvOut) {
    $filas | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8
    Write-Host "Eventos exportados a $CsvOut"
}
exit $alertas

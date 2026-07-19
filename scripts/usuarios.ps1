[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('alta', 'baja', 'recuperar', 'informe')]
    [string]$Accion = 'informe',
    [string]$CsvPath = "$PSScriptRoot\usuarios.csv",
    [string]$Usuario,
    [string]$BajasCsv,
    [string]$Dominio,
    [string]$PasswordInicial
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Import-Module ActiveDirectory

$cfgFile = Join-Path $PSScriptRoot '..\lab.psd1'
$cfg = if (Test-Path $cfgFile) { Import-PowerShellDataFile -Path $cfgFile } else { @{} }
function Conf($v, $d) { if ($null -ne $v -and "$v" -ne '') { $v } else { $d } }
$Dominio         = Conf $Dominio (Conf $cfg.Dominio 'lab.local')
$PasswordInicial = Conf $PasswordInicial (Conf $cfg.PasswordInicial 'Bienvenid@.2026')
$grpEmpleados = Conf $cfg.GrupoEmpleados 'G-Empleados'
$prefijoGrupo = Conf $cfg.PrefijoGrupo 'G-'
$nomUsuarios  = Conf $cfg.OU.Usuarios 'Usuarios'
$nomBajas     = Conf $cfg.OU.Bajas 'Bajas'
$nomGrupos    = Conf $cfg.OU.Grupos 'Grupos'
$homesRuta    = Conf $cfg.HomesRuta 'C:\Homes'
$homesRecurso = Conf $cfg.HomesRecurso 'Homes'

$LogDir = 'C:\lab\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'manage-adusers.log'
function Log {
    param([string]$Msg, [string]$Nivel = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

$dom      = Get-ADDomain
$domainDN = $dom.DistinguishedName
$dcName   = $dom.PDCEmulator.Split('.')[0]
$ouUsuarios = "OU=$nomUsuarios,$domainDN"
$ouBajas    = "OU=$nomBajas,$domainDN"
$ouGrupos   = "OU=$nomGrupos,$domainDN"

function Ensure-OU {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    $existe = try { Get-ADOrganizationalUnit -Identity $dn } catch { $null }
    if (-not $existe) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
        Log "OU creada: $dn"
    }
    return $dn
}

function Ensure-Group {
    param([string]$Name)
    $existe = try { Get-ADGroup -Identity $Name } catch { $null }
    if (-not $existe) {
        New-ADGroup -Name $Name -GroupScope Global -GroupCategory Security -Path $ouGrupos | Out-Null
        Log "Grupo creado: $Name"
    }
}

function Ensure-Home {
    param([string]$Sam)
    $homePath = "$homesRuta\$Sam"
    if (-not (Test-Path $homePath)) { New-Item -ItemType Directory -Path $homePath -Force | Out-Null }
    $daSid = "{0}-512" -f $dom.DomainSID.Value
    icacls $homePath /inheritance:r `
        /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${daSid}:(OI)(CI)F" `
        "$($dom.NetBIOSName)\${Sam}:(OI)(CI)M" | Out-Null
}

[void](Ensure-OU -Name $nomUsuarios -Path $domainDN)
[void](Ensure-OU -Name $nomBajas    -Path $domainDN)
[void](Ensure-OU -Name $nomGrupos   -Path $domainDN)

function Do-Alta {
    if (-not (Test-Path $CsvPath)) { throw "No encuentro el CSV: $CsvPath" }
    $filas = @(Import-Csv -Path $CsvPath -Encoding UTF8)
    Log "Alta desde $CsvPath ($($filas.Count) fila(s))"
    Ensure-Group $grpEmpleados

    $creados = 0; $reincorporados = 0; $saltados = 0
    foreach ($f in $filas) {
        $sam = $f.Usuario.Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($sam)) { continue }

        $existente = try { Get-ADUser -Identity $sam } catch { $null }
        if ($existente -and $existente.DistinguishedName -notlike "*,$ouBajas") {
            Log "  = $sam ya existe, lo dejo"
            $saltados++
            continue
        }

        $depto  = $f.Departamento.Trim()
        $ouDepto = Ensure-OU -Name $depto -Path $ouUsuarios
        Ensure-Group "$prefijoGrupo$depto"

        if ($existente) {
            Set-ADAccountPassword -Identity $sam -Reset `
                -NewPassword (ConvertTo-SecureString $PasswordInicial -AsPlainText -Force)
            Set-ADUser -Identity $sam -Department $depto -Title $f.Puesto.Trim() `
                -ChangePasswordAtLogon $true -Clear Description
            Enable-ADAccount -Identity $sam
            Add-ADGroupMember -Identity "$prefijoGrupo$depto"    -Members $sam
            Add-ADGroupMember -Identity $grpEmpleados -Members $sam
            Move-ADObject -Identity $existente.DistinguishedName -TargetPath $ouDepto
            Ensure-Home $sam
            Log "  ~ $sam reincorporado desde Bajas ($depto)"
            $reincorporados++
            continue
        }

        $nombreCompleto = "{0} {1}" -f $f.Nombre.Trim(), $f.Apellidos.Trim()

        New-ADUser `
            -Name $nombreCompleto `
            -DisplayName $nombreCompleto `
            -GivenName $f.Nombre.Trim() `
            -Surname $f.Apellidos.Trim() `
            -SamAccountName $sam `
            -UserPrincipalName "$sam@$Dominio" `
            -Path $ouDepto `
            -Department $depto `
            -Title $f.Puesto.Trim() `
            -AccountPassword (ConvertTo-SecureString $PasswordInicial -AsPlainText -Force) `
            -HomeDrive 'H:' `
            -HomeDirectory "\\$dcName\$homesRecurso\$sam" `
            -ChangePasswordAtLogon $true `
            -Enabled $true

        Ensure-Home $sam
        Add-ADGroupMember -Identity "$prefijoGrupo$depto"    -Members $sam
        Add-ADGroupMember -Identity $grpEmpleados -Members $sam
        Log "  + $sam creado  ($nombreCompleto - $depto)"
        $creados++
    }
    Log "Alta terminada: $creados creado(s), $reincorporados reincorporado(s), $saltados sin cambios."
}

function Do-Baja {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $targets = @()
    if ($BajasCsv) {
        if (-not (Test-Path $BajasCsv)) { throw "No encuentro el CSV de bajas: $BajasCsv" }
        $targets = @(Import-Csv -Path $BajasCsv -Encoding UTF8).Usuario
    } elseif ($Usuario) {
        $targets = @($Usuario)
    } else {
        throw "Indica -Usuario <sam> (baja individual) o -BajasCsv <archivo> (baja en masa)."
    }

    foreach ($t in $targets) {
        $sam = $t.Trim().ToLower()
        $u = try { Get-ADUser -Identity $sam -Properties MemberOf } catch { $null }
        if (-not $u) { Log "  ! $sam no existe, lo salto" 'WARN'; continue }
        if ($u.DistinguishedName -like "*,$ouBajas") { Log "  = $sam ya estaba de baja"; continue }
        if (-not $PSCmdlet.ShouldProcess($sam, 'baja: deshabilitar, sacar de grupos y mover a Bajas')) { continue }

        Disable-ADAccount -Identity $u
        foreach ($g in $u.MemberOf) {
            try {
                Remove-ADGroupMember -Identity $g -Members $u -Confirm:$false
            } catch {
                Log "  ! no pude sacar a $sam del grupo $g : $($_.Exception.Message)" 'WARN'
            }
        }
        Set-ADUser -Identity $u -Description ("Baja {0}" -f (Get-Date -Format 'yyyy-MM-dd'))
        Move-ADObject -Identity $u.DistinguishedName -TargetPath $ouBajas
        Log "  - $sam dado de baja (deshabilitado, sin grupos, movido a Bajas)"
    }
}

function Do-Recuperar {
    if (-not $Usuario) { throw "Indica -Usuario <sam> (la cuenta borrada a recuperar)." }
    $sam = $Usuario.Trim().ToLower()
    if ($sam -notmatch '^[a-z0-9._-]+$') { throw "SamAccountName no valido: $sam" }

    $activo = try { Get-ADUser -Identity $sam } catch { $null }
    if ($activo) { Log "  = $sam ya existe y esta activo, nada que recuperar"; return }

    $borrado = @(Get-ADObject -Filter { SamAccountName -eq $sam } -IncludeDeletedObjects `
                    -Properties SamAccountName, isDeleted, lastKnownParent |
                 Where-Object { $_.isDeleted })[0]
    if (-not $borrado) { Log "  ! $sam no aparece ni activo ni en la Papelera, no puedo recuperarlo" 'WARN'; return }

    Restore-ADObject -Identity $borrado.DistinguishedName
    Set-ADAccountPassword -Identity $sam -Reset `
        -NewPassword (ConvertTo-SecureString $PasswordInicial -AsPlainText -Force)
    Set-ADUser -Identity $sam -ChangePasswordAtLogon $true
    Enable-ADAccount -Identity $sam
    Log "  ^ $sam recuperado desde la Papelera de AD (restaurado, contrasena reseteada, reactivado)"
}

function Do-Informe {
    $activos = Get-ADUser -SearchBase $ouUsuarios -Filter * -Properties Department, Title, Enabled |
               Select-Object SamAccountName, Name, Department, Title, Enabled
    $bajas   = Get-ADUser -SearchBase $ouBajas -Filter * -Properties Description |
               Select-Object SamAccountName, Name, Description

    Log ("Informe: {0} usuario(s) activo(s), {1} de baja." -f @($activos).Count, @($bajas).Count)
    Write-Host "`n== USUARIOS ACTIVOS (OU=Usuarios) =="
    @($activos) | Sort-Object Department, Name | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "== BAJAS (OU=Bajas) =="
    @($bajas) | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host
}

switch ($Accion) {
    'alta'      { Do-Alta }
    'baja'      { Do-Baja }
    'recuperar' { Do-Recuperar }
    'informe'   { Do-Informe }
}

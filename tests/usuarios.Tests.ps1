BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/usuarios.ps1'

    function Get-ADDomain { }
    function Get-ADOrganizationalUnit { }
    function New-ADOrganizationalUnit { }
    function Get-ADGroup { }
    function New-ADGroup { }
    function Get-ADUser { }
    function New-ADUser { }
    function Get-ADObject { }
    function Restore-ADObject { }
    function Add-ADGroupMember { }
    function Disable-ADAccount { }
    function Enable-ADAccount { }
    function Set-ADAccountPassword { }
    function Remove-ADGroupMember { }
    function Set-ADUser { }
    function Move-ADObject { }
    function icacls { }
}

Describe 'usuarios.ps1' {
    BeforeEach {
        Mock Import-Module { } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-ADDomain { [pscustomobject]@{
                DistinguishedName = 'DC=lab,DC=local'
                PDCEmulator       = 'dc01.lab.local'
                NetBIOSName       = 'LAB'
                DomainSID         = [pscustomobject]@{ Value = 'S-1-5-21-1111111111-2222222222-3333333333' }
            } }
        Mock Get-ADOrganizationalUnit { $null }
        Mock New-ADOrganizationalUnit { }
        Mock Get-ADGroup { $null }
        Mock New-ADGroup { }
        Mock Add-ADGroupMember { }
        Mock New-Item { }
        Mock Add-Content { }
        Mock icacls { }
    }

    Context 'alta desde CSV' {
        BeforeEach {
            $script:csv = Join-Path $TestDrive 'usuarios.csv'
            @('Usuario,Nombre,Apellidos,Departamento,Puesto',
              'tuser,Test,User,IT,Tecnico') | Set-Content -Path $csv
        }

        It 'crea la cuenta cuando el usuario no existe' {
            Mock Get-ADUser { $null }
            Mock New-ADUser { }
            & $ScriptPath -Accion alta -CsvPath $csv
            Should -Invoke New-ADUser -Times 1 -Exactly
            Should -Invoke Add-ADGroupMember -Times 2 -Exactly
        }

        It 'es idempotente: NO recrea una cuenta que ya existe' {
            Mock Get-ADUser { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    DistinguishedName = 'CN=Test User,OU=IT,OU=Usuarios,DC=lab,DC=local'
                } }
            Mock New-ADUser { }
            & $ScriptPath -Accion alta -CsvPath $csv
            Should -Invoke New-ADUser -Times 0 -Exactly
        }

        It 'aplica la ACL restringida a la carpeta home' {
            Mock Get-ADUser { $null }
            Mock New-ADUser { }
            & $ScriptPath -Accion alta -CsvPath $csv
            Should -Invoke icacls -Times 1 -Exactly
        }

        It 'reincorpora una cuenta que estaba en Bajas (recontratacion)' {
            Mock Get-ADUser { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    DistinguishedName = 'CN=Test User,OU=Bajas,DC=lab,DC=local'
                } }
            Mock New-ADUser { }
            Mock Enable-ADAccount { }
            Mock Set-ADAccountPassword { }
            Mock Set-ADUser { }
            Mock Move-ADObject { }
            & $ScriptPath -Accion alta -CsvPath $csv
            Should -Invoke New-ADUser -Times 0 -Exactly
            Should -Invoke Set-ADAccountPassword -Times 1 -Exactly
            Should -Invoke Enable-ADAccount -Times 1 -Exactly
            Should -Invoke Add-ADGroupMember -Times 2 -Exactly
            Should -Invoke Move-ADObject -Times 1 -Exactly
        }
    }

    Context 'recuperar (Papelera de AD)' {
        It 'restaura el objeto borrado, resetea la contrasena y reactiva la cuenta' {
            Mock Get-ADUser { $null }
            Mock Get-ADObject { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    isDeleted         = $true
                    DistinguishedName = 'CN=Test User\0ADEL:...,CN=Deleted Objects,DC=lab,DC=local'
                    lastKnownParent   = 'OU=IT,OU=Usuarios,DC=lab,DC=local'
                } }
            Mock Restore-ADObject { }
            Mock Set-ADAccountPassword { }
            Mock Set-ADUser { }
            Mock Enable-ADAccount { }
            & $ScriptPath -Accion recuperar -Usuario tuser
            Should -Invoke Restore-ADObject      -Times 1 -Exactly
            Should -Invoke Set-ADAccountPassword -Times 1 -Exactly
            Should -Invoke Enable-ADAccount      -Times 1 -Exactly
        }

        It 'no hace nada si la cuenta sigue activa' {
            Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'tuser' } }
            Mock Get-ADObject { }
            Mock Restore-ADObject { }
            & $ScriptPath -Accion recuperar -Usuario tuser
            Should -Invoke Restore-ADObject -Times 0 -Exactly
        }
    }

    Context 'baja (procedimiento repetible)' {
        It 'deshabilita, saca de grupos, describe y mueve a Bajas' {
            Mock Get-ADUser { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    DistinguishedName = 'CN=Test User,OU=IT,OU=Usuarios,DC=lab,DC=local'
                    MemberOf          = @('CN=G-IT,OU=Grupos,DC=lab,DC=local')
                } }
            Mock Disable-ADAccount { }
            Mock Remove-ADGroupMember { }
            Mock Set-ADUser { }
            Mock Move-ADObject { }
            & $ScriptPath -Accion baja -Usuario tuser
            Should -Invoke Disable-ADAccount   -Times 1 -Exactly
            Should -Invoke Remove-ADGroupMember -Times 1 -Exactly
            Should -Invoke Set-ADUser          -Times 1 -Exactly
            Should -Invoke Move-ADObject       -Times 1 -Exactly
        }

        It 'es idempotente: NO re-procesa una cuenta que ya esta en Bajas' {
            Mock Get-ADUser { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    DistinguishedName = 'CN=Test User,OU=Bajas,DC=lab,DC=local'
                    MemberOf          = @()
                } }
            Mock Disable-ADAccount { }
            Mock Move-ADObject { }
            & $ScriptPath -Accion baja -Usuario tuser
            Should -Invoke Disable-ADAccount -Times 0 -Exactly
            Should -Invoke Move-ADObject     -Times 0 -Exactly
        }

        It 'con -WhatIf no ejecuta ningun cambio' {
            Mock Get-ADUser { [pscustomobject]@{
                    SamAccountName    = 'tuser'
                    DistinguishedName = 'CN=Test User,OU=IT,OU=Usuarios,DC=lab,DC=local'
                    MemberOf          = @('CN=G-IT,OU=Grupos,DC=lab,DC=local')
                } }
            Mock Disable-ADAccount { }
            Mock Remove-ADGroupMember { }
            Mock Set-ADUser { }
            Mock Move-ADObject { }
            & $ScriptPath -Accion baja -Usuario tuser -WhatIf
            Should -Invoke Disable-ADAccount    -Times 0 -Exactly
            Should -Invoke Remove-ADGroupMember -Times 0 -Exactly
            Should -Invoke Set-ADUser           -Times 0 -Exactly
            Should -Invoke Move-ADObject        -Times 0 -Exactly
        }
    }
}

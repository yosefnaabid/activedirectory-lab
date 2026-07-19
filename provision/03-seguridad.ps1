Import-Module ActiveDirectory
function Log($m) { Write-Host "[hardening] $m" }
function Step($name, [scriptblock]$action) {
  try { $ErrorActionPreference = 'Stop'; & $action; Log "OK  · $name" }
  catch { Log "ERR · $name -> $($_.Exception.Message)" }
}

$domain = Get-ADDomain

Step 'Politica de contrasenas del dominio (14+, complejidad, bloqueo 5/15min)' {
  Set-ADDefaultDomainPasswordPolicy -Identity $domain.DistinguishedName `
    -MinPasswordLength 14 -ComplexityEnabled $true -PasswordHistoryCount 24 `
    -MinPasswordAge (New-TimeSpan -Days 1) -MaxPasswordAge (New-TimeSpan -Days 90) `
    -LockoutThreshold 5 -LockoutDuration (New-TimeSpan -Minutes 15) -LockoutObservationWindow (New-TimeSpan -Minutes 15)
}

Step 'FGPP reforzada para Domain Admins (20+, bloqueo 3/30min)' {
  if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Admins'" -ErrorAction SilentlyContinue)) {
    New-ADFineGrainedPasswordPolicy -Name 'FGPP-Admins' -Precedence 10 `
      -MinPasswordLength 20 -ComplexityEnabled $true -PasswordHistoryCount 24 `
      -LockoutThreshold 3 -LockoutDuration (New-TimeSpan -Minutes 30) -LockoutObservationWindow (New-TimeSpan -Minutes 30) `
      -MaxPasswordAge (New-TimeSpan -Days 60)
  }
  Add-ADFineGrainedPasswordPolicySubject 'FGPP-Admins' -Subjects 'Domain Admins'
}

Step 'SMBv1 desactivado (servidor)' {
  if ((Get-SmbServerConfiguration).EnableSMB1Protocol) { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force }
}

Step 'Registro: NTLMv2-only, firma SMB, Kerberos AES, LLMNR off' {
  function Set-Reg($p, $n, $v) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force | Out-Null }
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel' 5
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters' 'RequireSecuritySignature' 1
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters' 'SupportedEncryptionTypes' 24
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
}

Step 'Firma LDAP obligatoria (plantilla de seguridad de la DDCP)' {

  $ddcp   = '{6AC1786C-016F-11D2-945F-00C04FB984F9}'
  $polDir = Join-Path $env:SystemRoot "SYSVOL\sysvol\$($domain.DNSRoot)\Policies\$ddcp"
  $secDir = Join-Path $polDir 'MACHINE\Microsoft\Windows NT\SecEdit'
  $inf    = Join-Path $secDir 'GptTmpl.inf'
  New-Item -ItemType Directory -Path $secDir -Force | Out-Null
  if (-not (Test-Path $inf)) {
    '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1' | Set-Content -Path $inf -Encoding Unicode
  }

  $reg   = 'MACHINE\System\CurrentControlSet\Services\NTDS\Parameters\LDAPServerIntegrity=4,2'
  $lines = @(Get-Content $inf | Where-Object { $_ -notmatch 'LDAPServerIntegrity=' })
  if (-not ($lines -match '^\[Registry Values\]')) { $lines += '[Registry Values]' }
  $out   = foreach ($l in $lines) { $l; if ($l -match '^\[Registry Values\]') { $reg } }
  Set-Content -Path $inf -Value $out -Encoding Unicode

  try {
    $gpoDN = "CN=$ddcp,CN=Policies,CN=System,$($domain.DistinguishedName)"
    $new   = [int](Get-ADObject $gpoDN -Properties versionNumber).versionNumber + 65536
    Set-ADObject $gpoDN -Replace @{ versionNumber = $new }
    $gpt = Join-Path $polDir 'GPT.INI'
    if (Test-Path $gpt) { (Get-Content $gpt) -replace '^Version=.*', "Version=$new" | Set-Content $gpt -Encoding ASCII }
  } catch { Log "  aviso: no se pudo subir la version del GPO ($($_.Exception.Message)); gpupdate /force la aplica igual" }

  & gpupdate /target:computer /force | Out-Null
}

Step 'Auditoria avanzada (inicios de sesion, cuentas, Kerberos, DS)' {
  $subs = @('Credential Validation', 'Kerberos Authentication Service', 'Kerberos Service Ticket Operations',
    'Logon', 'Logoff', 'Account Lockout', 'User Account Management', 'Security Group Management',
    'Computer Account Management', 'Directory Service Access', 'Directory Service Changes')
  foreach ($s in $subs) { & auditpol /set /subcategory:"$s" /success:enable /failure:enable | Out-Null }
}

Step 'Cuenta Guest deshabilitada' {
  $g = Get-ADUser -Identity ($domain.DomainSID.Value + '-501') -ErrorAction SilentlyContinue
  if ($g -and $g.Enabled) { Disable-ADAccount -Identity $g }
}

Log 'Baseline aplicado. Reinicia el DC (vagrant reload) para ENFORCE completo de los ajustes de registro.'

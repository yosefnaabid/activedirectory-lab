param([string]$CsvOut)

$ErrorActionPreference = 'Continue'
Import-Module ActiveDirectory

$results = New-Object System.Collections.Generic.List[object]
function Check($id, $name, [bool]$ok, $detail) {
  $results.Add([pscustomobject]@{ Id = $id; Control = $name; Estado = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detalle = $detail })
}
function RegVal($path, $name) { (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name }

$domain = Get-ADDomain

$pp = Get-ADDefaultDomainPasswordPolicy
Check 'PWD-01' 'Longitud minima de contrasena >= 14'      ($pp.MinPasswordLength -ge 14)                                "actual: $($pp.MinPasswordLength)"
Check 'PWD-02' 'Complejidad de contrasena activada'       ($pp.ComplexityEnabled)                                       "actual: $($pp.ComplexityEnabled)"
Check 'PWD-03' 'Historial de contrasenas >= 24'           ($pp.PasswordHistoryCount -ge 24)                             "actual: $($pp.PasswordHistoryCount)"
Check 'PWD-04' 'Bloqueo de cuenta activado (1-10)'        ($pp.LockoutThreshold -ge 1 -and $pp.LockoutThreshold -le 10) "umbral: $($pp.LockoutThreshold)"
Check 'PWD-05' 'Politica reforzada admins (FGPP)'         ([bool]@(Get-ADFineGrainedPasswordPolicy -Filter * -EA SilentlyContinue).Count) "FGPP: $(@(Get-ADFineGrainedPasswordPolicy -Filter * -EA SilentlyContinue).Count)"

$rb = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'"
Check 'REC-01' 'Papelera de AD habilitada'               ([bool]$rb.EnabledScopes)                                     "scopes: $(@($rb.EnabledScopes).Count)"

Check 'NET-01' 'SMBv1 desactivado'                        (-not (Get-SmbServerConfiguration).EnableSMB1Protocol)        "EnableSMB1: $((Get-SmbServerConfiguration).EnableSMB1Protocol)"
$lm = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel'
Check 'NET-02' 'NTLMv2 unicamente (LmCompatibilityLevel=5)' ($lm -eq 5)                                                 "actual: $lm"
$ldap = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' 'LDAPServerIntegrity'
Check 'NET-03' 'Firma LDAP obligatoria'                  ($ldap -eq 2)                                                 "LDAPServerIntegrity: $ldap"
$smbs = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters' 'RequireSecuritySignature'
Check 'NET-04' 'Firma SMB obligatoria (servidor)'        ($smbs -eq 1)                                                 "actual: $smbs"
$krb = RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters' 'SupportedEncryptionTypes'
Check 'NET-05' 'Kerberos solo AES (sin RC4 ni DES)'      ([bool]$krb -and (($krb -band 0x7) -eq 0) -and (($krb -band 0x18) -ne 0)) "SupportedEncTypes: $krb"
$llmnr = RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
Check 'NET-06' 'LLMNR desactivado'                       ($llmnr -eq 0)                                                "EnableMulticast: $llmnr"

$guest = Get-ADUser -Identity ($domain.DomainSID.Value + '-501') -ErrorAction SilentlyContinue
Check 'ACC-01' 'Cuenta Guest deshabilitada'              (-not $guest.Enabled)                                         "Enabled: $($guest.Enabled)"
$da = @(Get-ADGroupMember 'Domain Admins' -Recursive)
Check 'ACC-02' 'Domain Admins reducido (<= 4 miembros)'  ($da.Count -le 4)                                             "miembros: $($da.Count)"

$pne = @(Get-ADUser -Filter 'PasswordNeverExpires -eq $true -and Enabled -eq $true' | Where-Object { $_.SamAccountName -ne 'vagrant' })
Check 'ACC-03' 'Sin cuentas de usuario con pass que nunca expira' ($pne.Count -eq 0)                                   "cuentas: $($pne.Count)"
$cut = (Get-Date).AddDays(-90)
$inact = @(Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonDate | Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt $cut })
Check 'ACC-04' 'Sin cuentas activas inactivas > 90 dias' ($inact.Count -eq 0)                                          "inactivas: $($inact.Count)"

$krbtgt = Get-ADUser krbtgt -Properties PasswordLastSet
$krbAge = [int]((Get-Date) - $krbtgt.PasswordLastSet).TotalDays
Check 'KRB-01' 'krbtgt rotada en el ultimo ano'          ($krbAge -le 365)                                             "edad: $krbAge dias (en un dominio recien creado es un PASS trivial)"
$audCsv = Join-Path $env:TEMP 'adlab-auditpol.csv'
Remove-Item $audCsv -Force -ErrorAction SilentlyContinue
& auditpol /backup /file:$audCsv | Out-Null
$audRow = @(Get-Content $audCsv -ErrorAction SilentlyContinue) -match '0CCE9215-69AE-11D9-BED3-505054503030'
Remove-Item $audCsv -Force -ErrorAction SilentlyContinue
$audVal = 0
if ($audRow) { $audVal = [int](($audRow[0] -split ',')[-1]) }
Check 'AUD-01' 'Auditoria de inicio de sesion activada'  (($audVal -band 1) -eq 1)                                     "subcategoria Logon (por GUID): $audVal"

Write-Host ""
Write-Host ("====  AUDITORIA DE SEGURIDAD DE ACTIVE DIRECTORY  ·  {0}  ====" -f $domain.DNSRoot) -ForegroundColor Cyan
Write-Host ""
foreach ($r in $results) {
  $color = if ($r.Estado -eq 'PASS') { 'Green' } else { 'Red' }
  $mark = if ($r.Estado -eq 'PASS') { '[ OK ]' } else { '[FAIL]' }
  Write-Host ("{0}  {1,-7} {2,-46} {3}" -f $mark, $r.Id, $r.Control, $r.Detalle) -ForegroundColor $color
}
$pass = @($results | Where-Object Estado -eq 'PASS').Count
$total = $results.Count
$pct = [math]::Round(100 * $pass / $total)
Write-Host ""
Write-Host ("RESULTADO: {0}/{1} controles conformes ({2}%)" -f $pass, $total, $pct) -ForegroundColor $(if ($pct -eq 100) { 'Green' } elseif ($pct -ge 60) { 'Yellow' } else { 'Red' })

if ($CsvOut) {
  $results | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8
  Write-Host "Informe exportado a $CsvOut"
}
exit ($total - $pass)

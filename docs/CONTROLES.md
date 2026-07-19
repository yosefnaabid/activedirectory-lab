# Controles de la auditoría y su anclaje al CIS Benchmark

`auditoria.ps1` comprueba 18 controles. Este documento ancla cada uno a su referencia en el CIS Microsoft Windows Server 2022 Benchmark y distingue con honestidad dos cosas que no son lo mismo:

- Controles que corresponden a un ajuste del benchmark CIS (una directiva o clave con su valor recomendado).
- Controles que son buenas prácticas operacionales de AD (higiene de cuentas, resiliencia) que el benchmark no cubre como un ajuste numerado, pero que un administrador aplica igual.

Nota de trazabilidad honesta: aquí se nombra el benchmark y la sección o el nombre exacto del ajuste, que es lo estable. El número de cláusula concreto (por ejemplo 2.3.11.7) y el minor exacto de la versión conviene confirmarlos contra el PDF del benchmark, que está bajo licencia de CIS. Se cita la sección para que la traza sea directa, sin inventar decimales que no pueda sostener.

Benchmark de referencia: CIS Microsoft Windows Server 2022 Benchmark, v3.x (confirmar el minor contra el PDF oficial).

## Contraseñas y bloqueo

| ID | Comprueba | Ajuste CIS / nombre de la directiva | Origen |
|----|-----------|--------------------------------------|--------|
| PWD-01 | Longitud mínima >= 14 | Account Policies > Password Policy: "Minimum password length" (sección 1.1) | CIS |
| PWD-02 | Complejidad activada | "Password must meet complexity requirements" (sección 1.1) | CIS |
| PWD-03 | Historial >= 24 | "Enforce password history" (sección 1.1) | CIS |
| PWD-04 | Umbral de bloqueo 1-10 | Account Lockout Policy: "Account lockout threshold" (sección 1.2) | CIS |
| PWD-05 | FGPP para admins | Política de contraseñas reforzada para cuentas privilegiadas (Fine-Grained Password Policy) | Buenas prácticas |

## Recuperación

| ID | Comprueba | Ajuste CIS / nombre de la directiva | Origen |
|----|-----------|--------------------------------------|--------|
| REC-01 | Papelera de AD habilitada | Capacidad de recuperación de objetos (AD Recycle Bin) | Buenas prácticas |

## Red y protocolos

| ID | Comprueba | Ajuste CIS / nombre de la directiva | Origen |
|----|-----------|--------------------------------------|--------|
| NET-01 | SMBv1 desactivado | "Configure SMB v1 server" / cliente, deshabilitado (sección 18, MS Security Guide) | CIS |
| NET-02 | NTLMv2 únicamente (LmCompatibilityLevel=5) | Security Options: "Network security: LAN Manager authentication level = Send NTLMv2 response only. Refuse LM and NTLM" (sección 2.3.11) | CIS |
| NET-03 | Firma LDAP obligatoria | "Domain controller: LDAP server signing requirements = Require signing" (sección 2.3.5, específica de DC) | CIS |
| NET-04 | Firma SMB obligatoria (servidor) | "Microsoft network server: Digitally sign communications (always) = Enabled" (sección 2.3.9) | CIS |
| NET-05 | Kerberos solo AES (sin RC4 ni DES) | "Network security: Configure encryption types allowed for Kerberos" (sección 2.3.11) | CIS |
| NET-06 | LLMNR desactivado | "Turn off multicast name resolution = Enabled" (sección 18, Administrative Templates > DNS Client) | CIS |

## Cuentas

| ID | Comprueba | Ajuste CIS / nombre de la directiva | Origen |
|----|-----------|--------------------------------------|--------|
| ACC-01 | Guest deshabilitada | "Accounts: Guest account status = Disabled" (sección 2.3.1) | CIS |
| ACC-02 | Domain Admins reducido | Limitar la pertenencia a grupos privilegiados | Buenas prácticas |
| ACC-03 | Sin cuentas de usuario con pass que nunca expira | Higiene de expiración de contraseñas | Buenas prácticas |
| ACC-04 | Sin cuentas activas inactivas > 90 días | Higiene de cuentas obsoletas | Buenas prácticas |

## Kerberos y auditoría

| ID | Comprueba | Ajuste CIS / nombre de la directiva | Origen |
|----|-----------|--------------------------------------|--------|
| KRB-01 | krbtgt rotada en el último año | Rotación periódica de la cuenta krbtgt (recomendación de Microsoft) | Buenas prácticas |
| AUD-01 | Auditoría de inicio de sesión activada | Advanced Audit Policy: "Audit Logon" con Success y Failure (sección 17.x) | CIS |

## Lo que este mapeo deja claro

No todos los buenos controles son una cláusula del benchmark, y decir cuáles sí y cuáles son higiene operacional es parte del criterio. De los 18, doce corresponden a ajustes del CIS Benchmark y seis son buenas prácticas operacionales de AD que el benchmark no numera pero que se aplican igual. Anclar los controles a un marco nombrado y versionado, y ser explícito sobre esta distinción, es más honesto que etiquetar el conjunto entero como "tipo CIS".

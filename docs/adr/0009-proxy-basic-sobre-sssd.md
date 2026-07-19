# ADR 0009 - Autenticación del proxy: Basic sobre PAM/SSSD, con Negotiate documentado

Estado: aceptada

## Contexto

El proxy del nodo RHEL debe autenticar usuarios del dominio. Squid ofrece varias vías contra Active Directory:

- **Negotiate/Kerberos** (`negotiate_kerberos_auth`): SSO real, la contraseña nunca viaja. Exige keytab con SPN `HTTP/fqdn`, clientes dentro del dominio con soporte Kerberos en el navegador y un depurado famoso por sus aristas (SPN duplicados, relojes, delegación).
- **Basic contra LDAP** (`basic_ldap_auth`): bind directo al DC. Funciona, pero duplica configuración de conexión y suele acabar con una cuenta de servicio y su contraseña en `squid.conf`.
- **Basic sobre PAM/SSSD** (`basic_pam_auth` + `pam_sss`): reutiliza la integración que ya dejó `join-domain.sh`. SSSD valida por debajo contra Kerberos/AD, el grupo se evalúa vía NSS (`ext_unix_group_acl`) y no aparece ni un secreto nuevo en la configuración.

## Decisión

Basic sobre PAM/SSSD. La máquina ya es miembro del dominio: el proxy delega en la misma pieza que gestiona los logins del sistema, con cero credenciales de servicio y el grupo de salida (`G-ProxyUsers`) administrado en AD. El `pam.d/squid` solo incluye `pam_sss`: autentican usuarios del dominio, no cuentas locales.

El trade-off va dicho en el propio `squid.conf` generado: **Basic envía `usuario:contraseña` en base64 en cada petición**. En un laboratorio con red privada es aceptable; en producción sería Negotiate/Kerberos (o, como mínimo, Basic únicamente sobre TLS).

## Alternativas descartadas

- Negotiate/Kerberos: es la respuesta correcta en producción y por eso queda documentada como evolución (keytab con `adcli update` o `net ads keytab`, SPN `HTTP/rhel01.lab.local`, `negotiate_kerberos_auth`). Descartada aquí porque su coste de depuración no aporta al objetivo del lab (filtrado autenticado contra el directorio) y porque la demo con `curl -U` deja de ser trivial.
- Basic contra LDAP: descartada por duplicar integración y requerir credenciales de servicio en texto plano en `squid.conf`, justo lo que SSSD evita.
- Proxy sin autenticación (solo ACL por IP): descartada; sin identidad no hay trazabilidad por usuario en el log, que es la mitad del valor de un proxy corporativo.

## Consecuencias

- La pertenencia a `G-ProxyUsers` se gestiona en AD y el proxy la obedece (TTL de 5 minutos en la ACL externa): dar o quitar salida a internet es una operación de directorio, no de servidor.
- Cada línea de `access.log` lleva el usuario autenticado: trazabilidad individual.
- Los clientes no necesitan pertenecer al dominio para usar el proxy (útil en el lab); con Negotiate sí lo necesitarían.
- Si un día se sube a Negotiate, las ACL y la lista de bloqueo se conservan tal cual: solo cambia el `auth_param`.

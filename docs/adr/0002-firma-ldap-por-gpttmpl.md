# ADR 0002 - Forzar la firma LDAP editando el GptTmpl.inf de la DDCP

Estado: aceptada

## Contexto

El baseline de seguridad debe dejar la firma LDAP como obligatoria (`LDAPServerIntegrity=2`). El primer intento fue una GPO de registro que escribía ese valor y se enlazaba al dominio como enforced. La auditoría seguía marcando el control en FAIL: el valor efectivo no cambiaba. Durante un tiempo el informe se quedó en 17/18 (94%) justo por esto.

El motivo es que en un controlador de dominio la firma LDAP no la fija cualquier GPO. La gobierna la Default Domain Controllers Policy (DDCP) a través de sus security settings, y esos ganan a una GPO de registro aunque la enlaces como enforced. Es una jerarquía de precedencia específica de los ajustes de seguridad, no del orden normal de GPOs.

## Decisión

`03-seguridad.ps1` baja al nivel de la plantilla de seguridad: escribe `LDAPServerIntegrity=4,2` en la sección `[Registry Values]` del `GptTmpl.inf` de la DDCP dentro del SYSVOL (GUID fijo de la política `{6AC1786C-016F-11D2-945F-00C04FB984F9}`) y fuerza la reaplicación con `gpupdate /target:computer /force`. Con eso el valor efectivo pasa a 2 y el control cierra: la auditoría llega a 18/18.

## Alternativas descartadas

- GPO de registro enlazada como enforced: es el intento que no funcionó, por la precedencia de los security settings de la DDCP. Descartada por ineficaz.
- Escribir la clave de registro directamente en el DC: cambia el valor hasta el siguiente refresco de directiva, momento en el que la DDCP lo revierte. No es duradero.
- Bumpear el versionNumber del objeto GPO con `Set-ADObject` para forzar el refresco: da "Insufficient access rights" con `LAB\vagrant`, que no tiene control total sobre la DDCP. Se deja como best-effort; `gpupdate /force` reaplica igual.

## Consecuencias

- El control queda cerrado de forma duradera y el lab audita 18/18.
- El hardening depende de la ruta del SYSVOL y del GUID de la DDCP, que son estables y estándar en cualquier bosque.
- El README conserva a propósito el viaje de 94% a 100% con este porqué: documentar por qué un control se resistía y cómo se acabó forzando vale más que enseñar solo el resultado final.

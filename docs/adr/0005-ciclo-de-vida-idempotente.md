# ADR 0005 - Ciclo de vida idempotente: reincorporación y baja con -WhatIf

Estado: aceptada

## Contexto

El alta y la baja de usuarios tienen que ser repetibles sin efectos raros, porque en la práctica se relanzan (un CSV que se corrige y se vuelve a pasar, una baja que se reintenta). Dos casos reales quedaban mal cubiertos:

- La recontratación. Si una cuenta que se dio de baja (movida a la OU Bajas, deshabilitada, sin grupos) reaparece en el CSV de altas, el alta original decía "ya existe, lo dejo" y seguía. El resultado: la cuenta quedaba deshabilitada, sin grupos y en la OU equivocada, pero el alta creía haber hecho su trabajo. Es el caso más común después de un alta y una baja.
- La baja destructiva sin ensayo. Deshabilitar una cuenta y vaciar sus grupos no tenía dry-run posible, aunque la función ya usaba `[CmdletBinding()]`.

## Decisión

- Reincorporación. El alta distingue "existe y activa" de "existe pero en Bajas". En el segundo caso reincorpora: resetea la contraseña, fuerza el cambio al primer inicio, limpia la descripción de baja, reactiva la cuenta, la devuelve a la OU de su departamento y le restaura los grupos. El contador del alta lo reporta aparte (`reincorporado(s)`).
- Baja con -WhatIf. El script y la función `Do-Baja` declaran `SupportsShouldProcess`, y cada baja pasa por `ShouldProcess`. Con `-WhatIf` se ensaya sin tocar nada.
- Filtros por identidad. Las consultas dejan de interpolar el sam en un `-Filter "SamAccountName -eq '$sam'"` (donde un apóstrofo en el CSV rompería la query) y usan `-Identity` con `try/catch`.
- El catch del borrado de grupos deja de ser silencioso: loguea un WARN con el grupo y el mensaje de la excepción.

## Alternativas descartadas

- Tratar la recontratación como un alta nueva (borrar y recrear): pierde el histórico del objeto (SID, fechas, pertenencias previas). Reincorporar el objeto existente es lo correcto.
- Confiar en `[CmdletBinding()]` sin `SupportsShouldProcess`: no habilita `-WhatIf`. El atributo tiene que ir también en la función, o PSScriptAnalyzer avisa (PSShouldProcess).
- Dejar el `catch {}` vacío: enmascara fallos reales. Se creía que protegía del grupo primario, pero el grupo primario ni siquiera aparece en `MemberOf`, así que ese catch solo tapaba errores.

## Consecuencias

- El ciclo de vida cubre el camino real completo, no solo el feliz: alta, baja y recontratación.
- La baja se puede ensayar antes de ejecutarla, que es lo primero que se le pide a una operación destructiva.
- Las cuatro rutas (alta nueva, reincorporación, baja, baja ya hecha) tienen prueba Pester que mockea AD, más el `-WhatIf` sin efectos y la aplicación de la ACL restringida.

# ADR 0006 - Recuperación de objetos borrados vía Papelera de AD

Estado: aceptada

## Contexto

El hardening habilita la Papelera de AD (REC-01), pero tener la papelera habilitada y saber usarla son cosas distintas. Faltaba el escenario de recuperación: borrar un objeto y restaurarlo. Sin él, la papelera es una casilla marcada en la auditoría, no una capacidad demostrada. Es la diferencia entre "activé la papelera" y "sé recuperar una cuenta borrada por error".

Un objeto borrado con la papelera habilitada no se destruye: pasa a estado deleted conservando sus atributos durante el periodo de la papelera, y se puede restaurar a su ubicación original (lastKnownParent). Al restaurarse vuelve deshabilitado y sin contraseña utilizable, así que el playbook no termina en el `Restore-ADObject`: hay que reactivar la cuenta y darle una contraseña.

## Decisión

Se añade `-Accion recuperar -Usuario <sam>` a `usuarios.ps1`. Busca el objeto borrado por `SamAccountName` con `Get-ADObject -IncludeDeletedObjects`, lo restaura con `Restore-ADObject`, y a continuación le pone la contraseña inicial, fuerza el cambio al primer inicio y reactiva la cuenta. Distingue tres situaciones: la cuenta ya existe activa (no hay nada que recuperar), está en la papelera (se restaura) o no aparece en ningún sitio (se avisa).

## Alternativas descartadas

- Recuperar solo con `Restore-ADObject` y parar ahí: la cuenta vuelve deshabilitada y sin contraseña usable, así que el usuario no podría entrar. El playbook completo la deja operativa.
- Recrear la cuenta desde el CSV en vez de restaurar: genera un objeto nuevo con otro SID, se pierden pertenencias e histórico. No es recuperar, es sustituir.
- Depender de un backup de System State (wbadmin) para este caso: es la herramienta para una pérdida mayor (la base de datos, varios objetos, un DC entero), no para restaurar un objeto puntual borrado por error, donde la papelera es directa y sin downtime.

## Consecuencias

- El lab demuestra la papelera de punta a punta: se borra una cuenta y se recupera operativa, con el estado verificable antes y después.
- Queda cubierto el hueco de recuperación a nivel de objeto. El backup y la restauración a nivel de base de datos (System State, restauración autoritativa vs no autoritativa) siguen listados como siguiente paso: son la capa de resiliencia mayor, complementaria a esta.

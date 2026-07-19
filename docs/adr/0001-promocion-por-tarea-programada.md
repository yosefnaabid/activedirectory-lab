# ADR 0001 - Promocionar el DC con una tarea programada, no dentro del provisioner

Estado: aceptada

## Contexto

Promocionar un servidor a controlador de dominio (`Install-ADDSForest`) cambia la identidad de la cuenta local `vagrant`: pasa a ser una cuenta de dominio. Vagrant se comunica con la VM por WinRM usando esa cuenta. Si la promoción ocurre dentro de un provisioner, en cuanto el DC reinicia Vagrant intenta reconectar con la cuenta local, que ya no existe como tal, no puede cerrar su shell y da el `vagrant up` por fallido. Al fallar, Vagrant hace rollback y destruye la VM. El lab no llega a existir.

## Decisión

El provisioner `01-controlador.ps1` no promociona. Solo instala el rol AD DS, copia los scripts a `C:\lab` y registra una tarea programada `LabDCSetup` que corre como SYSTEM al arrancar. Luego reinicia y devuelve el control a Vagrant, que ve un arranque limpio.

La tarea ejecuta `02-estructura.ps1`, que es multi-fase: la fase 1 promociona el bosque y reinicia; la fase 2, ya con el DC en marcha, crea la estructura de OUs, grupos, GPO y da de alta a los usuarios, y al terminar se desregistra. Corre como SYSTEM, así que no depende de ninguna sesión WinRM.

## Alternativas descartadas

- Promocionar dentro del provisioner y confiar en el reinicio de Vagrant: es lo que provoca el rollback destructivo. Descartada por lo anterior.
- Usar un segundo usuario local dedicado para WinRM: no resuelve el problema de fondo (la promoción cambia el modelo de cuentas de toda la máquina) y añade una credencial más que gestionar.
- Provisionar todo a mano tras el `vagrant up`: rompe la premisa del lab, que es reproducible de cero por código.

## Consecuencias

- Un solo `vagrant up` deja el DC operativo y poblado, con dos reinicios de por medio (unos 10 minutos).
- Las operaciones on-demand posteriores (informe, baja, auditoría) necesitan credenciales de dominio: `$env:ADLAB_WINRM_USER='LAB\vagrant'`. Es un efecto secundario real de automatizar AD, no un apaño.
- El flujo es fiel a cómo se automatiza un DC en la práctica: la promoción se orquesta fuera de la sesión que la dispara.

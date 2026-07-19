# ADR 0008 - El nodo RHEL se crea fuera de Vagrant (no hay box oficial de RHEL)

Estado: aceptada

## Contexto

El lab quiere un miembro del dominio que sea Red Hat Enterprise Linux de verdad, no un derivado (Rocky, Alma): el objetivo es el ecosistema real de RHEL (subscription-manager, repos oficiales, SELinux, el temario RHCSA). Pero Red Hat no publica boxes de Vagrant: las imágenes de RHEL se descargan bajo cuenta (la suscripción Developer es gratuita pero personal) y redistribuir una box re-empaquetada va contra los términos de la suscripción. No existe un `vagrant up` legal y reproducible para RHEL como el que usan las otras VMs del lab.

## Decisión

La VM RHEL se crea una vez en VirtualBox desde la ISO oficial (pasos documentados en [`provision/rhel/README.md`](../../provision/rhel/README.md), incluida la variante por `VBoxManage`), se registra con `subscription-manager` (paso manual: la cuenta es personal) y a partir de ahí TODO es código idempotente que corre dentro de la VM: `provision/rhel/join-domain.sh` configura red, DNS, unión al dominio con realmd/sssd, homes automáticos y sudo por grupo de AD; `provision/rhel/squid.sh` monta el proxy. El mismo criterio de honestidad que el ADR 0001: se documenta lo que no se puede automatizar y por qué, en lugar de esconderlo.

## Alternativas descartadas

- Construir una box propia con Packer desde la ISO (kickstart + `vagrant package`): es la evolución elegante y quedaría dentro de la licencia mientras la box no se redistribuya. Descartada por ahora porque exige la ISO bajo cuenta propia y un build largo, y el valor del lab está en la integración con AD, no en la fabricación de la box. Queda como siguiente iteración natural.
- Usar una box comunitaria (`generic/rhel9` y similares): origen no oficial y sin suscripción utilizable; además normaliza justo lo que el lab quiere evitar (un RHEL que no es el de verdad).
- Sustituir RHEL por Rocky/Alma (sí tienen boxes oficiales): descartada porque el objetivo es literalmente RHEL; la mecánica de `realmd/sssd` sería idéntica, pero se perdería `subscription-manager` y el ecosistema Red Hat.

## Consecuencias

- El nodo RHEL no aparece en `vagrant up`: hay tres pasos manuales (crear la VM, instalar RHEL, registrarla) y el resto es script. El README lo dice tal cual.
- La configuración sigue siendo reproducible y verificable: `join-domain.sh` es idempotente y termina con una verificación PASS/FAIL con código de salida, como `auditoria.ps1`.
- La cuenta de equipo del nodo (RHEL01$) y su registro DNS viven en AD, así que el resto del ecosistema (Zabbix, GLPI) puede referirse a él por nombre.

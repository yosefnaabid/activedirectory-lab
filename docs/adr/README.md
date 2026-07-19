# Decisiones de diseño (ADR)

Estas notas registran por qué el lab está hecho como está: no solo la decisión, también las alternativas que se descartaron y a qué obligan a cambio. Son Architecture Decision Records (ADR), un formato ligero para dejar constancia del criterio detrás de cada elección, no solo del resultado.

El objetivo es doble: que el lab sea auditable (cualquiera entiende el porqué sin arqueología del historial de git) y que las decisiones aguanten preguntas. Casi todas nacieron de un problema real que se topó al construir el lab, no de una preferencia estética.

| ADR | Decisión | Estado |
|-----|----------|--------|
| [0001](0001-promocion-por-tarea-programada.md) | Promocionar el DC con una tarea programada, no dentro del provisioner | Aceptada |
| [0002](0002-firma-ldap-por-gpttmpl.md) | Forzar la firma LDAP editando el GptTmpl.inf de la DDCP | Aceptada |
| [0003](0003-acl-de-carpetas-home-por-sid.md) | ACL de las carpetas personales por SID y no por nombre | Aceptada |
| [0004](0004-auditoria-consumible-por-pipeline.md) | Auditoría con código de salida, CSV y checks a prueba de idioma | Aceptada |
| [0005](0005-ciclo-de-vida-idempotente.md) | Ciclo de vida idempotente: reincorporación y baja con -WhatIf | Aceptada |
| [0006](0006-recuperacion-papelera-ad.md) | Recuperación de objetos borrados vía Papelera de AD | Aceptada |
| [0007](0007-parametrizacion-declarativa.md) | Parametrización a un `lab.psd1` declarativo, manteniendo lo imperativo | Aceptada |
| [0008](0008-nodo-rhel-sin-box-oficial.md) | El nodo RHEL se crea fuera de Vagrant (no hay box oficial de RHEL) | Aceptada |
| [0009](0009-proxy-basic-sobre-sssd.md) | Autenticación del proxy: Basic sobre PAM/SSSD, con Negotiate documentado | Aceptada |

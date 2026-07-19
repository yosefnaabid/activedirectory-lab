# ADR 0003 - ACL de las carpetas personales por SID y no por nombre

Estado: aceptada

## Contexto

Cada usuario del alta recibe una carpeta personal en `C:\Homes\<sam>`, expuesta por el recurso `\\dc01\Homes`. El share se creó con acceso Change para Authenticated Users. Si la carpeta de cada usuario hereda los permisos del padre, cualquier usuario autenticado puede leer la carpeta de otro. En un lab cuyo plato fuerte es el endurecimiento y la auditoría, que el propio alta abra ese agujero es una contradicción de fondo.

Hay que separar dos capas: el permiso del recurso compartido (share) y la ACL NTFS de la carpeta. El acceso efectivo es la intersección de ambos. Dejar el share en Change está bien siempre que el NTFS restrinja de verdad quién entra en cada carpeta.

## Decisión

`Ensure-Home`, en `usuarios.ps1`, corta la herencia de la carpeta (`icacls /inheritance:r`) y concede: Modify solo al dueño, Full a SYSTEM, a los administradores locales (BUILTIN\Administrators) y a Domain Admins. La concesión se hace por SID, no por nombre.

Los SID se usan a propósito: `S-1-5-18` (SYSTEM) y `S-1-5-32-544` (Administrators) son invariantes y funcionan en cualquier idioma de Windows; el de Domain Admins se construye desde el SID del dominio (`...-512`). Un `icacls "Administradores:F"` se rompería en un Windows en español.

## Alternativas descartadas

- Heredar del padre: es el agujero de partida. Descartada.
- Conceder solo a Domain Admins además del dueño: se probó y falló en vivo. La cuenta `vagrant` administra el DC a través de BUILTIN\Administrators, no como Domain Admin pleno, así que se quedaba fuera y no podía ni leer la carpeta (`Access is denied`). Por eso la ACL incluye Administrators y Domain Admins.
- Restringir en el permiso del share en vez del NTFS: el NTFS es la capa que viaja con la carpeta y la que se audita objeto a objeto; el share es más grueso. Se restringe donde de verdad manda.

## Consecuencias

- La carpeta de Ana no la lee Diego: el acceso queda en el dueño más las cuentas administrativas.
- La ACL es idempotente y locale-proof; relanzar el alta la reafirma.
- Las carpetas creadas antes de este cambio necesitaron una reparación puntual (`takeown` + el mismo `icacls`) porque nacieron heredando permisos.

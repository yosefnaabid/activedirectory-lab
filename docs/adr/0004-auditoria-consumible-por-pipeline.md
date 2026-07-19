# ADR 0004 - Auditoría con código de salida, CSV y checks a prueba de idioma

Estado: aceptada

## Contexto

`auditoria.ps1` empezó como un informe en consola con colores. Se vendía como verificable y repetible, pero ninguna pipeline podía consumir el resultado: no devolvía código de salida ni exportaba nada, así que era un semáforo bonito, no una herramienta. Además, dos controles tenían defectos que los hacían menos fiables de lo que aparentaban.

## Decisión

Tres cambios para que la auditoría sea consumible por automatización y honesta en lo que comprueba:

1. Código de salida y exportación. El script termina con `exit (total - conformes)`, así que el código de salida es el número de controles fallidos (0 = todo conforme). Con `-CsvOut <ruta>` exporta el informe a CSV. Una pipeline puede ejecutarlo, mirar el código y archivar el CSV.
2. AUD-01 independiente del idioma. La comprobación de la auditoría de inicio de sesión ya no hace match del texto "Success" en la salida de `auditpol /get` (que en un Windows en español es "Correcto" y rompería). Ahora usa `auditpol /backup`, que vuelca un CSV, y localiza la subcategoría Logon por su GUID invariante `0CCE9215-69AE-11D9-BED3-505054503030`, leyendo su valor numérico.
3. NET-05 más estricto. La comprobación de Kerberos solo-AES ahora verifica también los bits DES (`-band 0x7`), no solo el de RC4. Un `SupportedEncryptionTypes` con DES activo ya no pasaría el control.

## Alternativas descartadas

- Dejar el informe solo en consola: no lo consume una pipeline. Descartada.
- Parsear `auditpol /get` por texto: depende del idioma del sistema, justo lo que hay que evitar en un lab pensado en español.
- Comprobar en NET-05 solo el bit de RC4: dejaba pasar DES, una inconsistencia entre lo que el README promete (solo AES) y lo que el control valida.

## Consecuencias

- La auditoría se puede encadenar: la pasada previa al hardening termina con código de salida distinto de cero a propósito, que es lo que quieres para que una pipeline detecte el estado inseguro.
- KRB-01 (rotación de krbtgt) sigue siendo un PASS trivial en un dominio recién creado, porque la cuenta tiene días de vida. No se elimina el control, pero su detalle lo avisa: es honesto sobre lo que de verdad está verificando.

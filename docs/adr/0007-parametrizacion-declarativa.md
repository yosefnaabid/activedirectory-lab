# ADR 0007 - Parametrización a un fichero de config declarativo

Estado: aceptada

## Contexto

Los valores que definen esta instancia del lab (el nombre del dominio, el NetBIOS, las OUs, los grupos, las contraseñas iniciales) estaban repetidos como literales en varios scripts: `02-estructura.ps1` promocionaba `lab.local`, `usuarios.ps1` construía las OUs con los mismos nombres, `04-gpos.ps1` filtraba por el mismo grupo. Cambiar el dominio o renombrar una OU obligaba a tocar varios ficheros y arriesgarse a que uno se quedara atrás. Es datos mezclados con lógica.

La decisión de fondo, antes de esta, fue si migrar a un modelo declarativo puro (DSC o Ansible) o mantener los scripts imperativos y solo separar los datos. Se optó por lo segundo: los scripts imperativos ya funcionan, están verificados y son legibles; el valor que faltaba no era la reescritura, sino sacar los datos a un sitio único.

## Decisión

Un fichero `lab.psd1` en la raíz es la fuente única de la identidad y la estructura de AD: dominio, NetBIOS, nivel funcional, contraseña DSRM, contraseña inicial, nombres de las OUs, grupo de empleados y su prefijo, ruta y nombre del recurso Homes, y el nombre de la GPO base.

Los scripts que crean esos objetos (`02-estructura.ps1`, `usuarios.ps1`, `04-gpos.ps1`) lo leen con `Import-PowerShellDataFile` y una función `Conf` que cae a un valor por defecto si la clave falta, así que un script suelto sin el fichero sigue funcionando. `01-controlador.ps1` copia `lab.psd1` a `C:\lab` para que llegue al DC junto con los scripts. La lógica no cambia; solo el origen de los literales.

## Alternativas descartadas

- Migrar a PowerShell DSC o Ansible: es una reescritura mayor de una cadena de provisioning que ya funciona y está verificada. El review pedía separar datos de lógica, no rehacer el motor. Se descartó por coste sin beneficio proporcional en un lab de este tamaño.
- Meterlo todo, incluida la red, en el mismo fichero: el `Vagrantfile` (Ruby) no lee un `.psd1`, así que la topología (IPs, qué VM) se queda donde es natural, en el `Vagrantfile`. Forzar que Ruby y PowerShell compartieran fichero habría sido más frágil que el reparto por responsabilidades.

## Consecuencias

- Renombrar una OU o cambiar el dominio se hace en un único sitio y se propaga a la creación de la estructura, al alta de usuarios y a las GPOs.
- Queda una frontera honesta: el `Vagrantfile` sigue teniendo la red y le pasa el nombre del dominio como argumento al script de unión del cliente. Es duplicación acotada y consciente, no un descuido: la red es de Vagrant y la identidad de AD es de `lab.psd1`.
- El comportamiento es idéntico al de antes de parametrizar: un `vagrant destroy` y `up` reproduce el mismo lab. Eso se verificó reconstruyendo el DC de cero.

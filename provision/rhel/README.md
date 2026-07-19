# Nodo RHEL: creación de la VM y scripts

Esta carpeta contiene los scripts del miembro RHEL del dominio. La VM se crea **una vez, fuera de Vagrant** (Red Hat no publica boxes oficiales; el porqué completo está en [`docs/adr/0008`](../../docs/adr/0008-nodo-rhel-sin-box-oficial.md)); todo lo demás es código idempotente.

| Script | Qué hace |
|--------|----------|
| `join-domain.sh` | Red estática + DNS al DC, unión a `lab.local` con realmd/sssd, homes automáticos, sudo para `G-LinuxAdmins`. Verificación PASS/FAIL al final. |
| `squid.sh` | Proxy Squid con autenticación de usuarios del dominio (vía PAM/sssd) y filtrado por listas. |
| `blocked-domains.txt` | Lista declarativa de dominios bloqueados por el proxy. |

## 1 · Crear la VM (una vez)

Descarga la ISO de **RHEL 9** (o 10) desde [developers.redhat.com](https://developers.redhat.com/products/rhel/download) con la cuenta gratuita Red Hat Developer.

Con la interfaz de VirtualBox: máquina nueva (tipo *Red Hat 9 x64*, 2 GB RAM, 20 GB disco) con **dos adaptadores de red**: el 1 en NAT (salida a internet) y el 2 en *Solo-anfitrión* (la red `192.168.56.0/24` del lab, el mismo adaptador que usan las demás VMs). O por línea de comandos:

```powershell
VBoxManage createvm --name ad-lab-rhel01 --ostype RedHat9_64 --register
VBoxManage modifyvm ad-lab-rhel01 --memory 2048 --cpus 2 `
  --nic1 nat --nic2 hostonly --hostonlyadapter2 "VirtualBox Host-Only Ethernet Adapter"
VBoxManage createmedium disk --filename "$env:USERPROFILE\VirtualBox VMs\ad-lab-rhel01\rhel01.vdi" --size 20480
VBoxManage storagectl ad-lab-rhel01 --name SATA --add sata --controller IntelAhci
VBoxManage storageattach ad-lab-rhel01 --storagectl SATA --port 0 --device 0 --type hdd `
  --medium "$env:USERPROFILE\VirtualBox VMs\ad-lab-rhel01\rhel01.vdi"
VBoxManage storageattach ad-lab-rhel01 --storagectl SATA --port 1 --device 0 --type dvddrive `
  --medium "C:\ruta\a\rhel-9.x-x86_64-dvd.iso"
VBoxManage startvm ad-lab-rhel01
```

Instala RHEL con el perfil *Server* (sin escritorio), crea tu usuario local y termina la instalación. La red puede quedarse en DHCP durante la instalación: el script la fija después.

## 2 · Registrar la suscripción (manual, una vez)

Dentro de la VM (esto no se automatiza: la cuenta Developer es personal):

```bash
sudo subscription-manager register --username <tu-usuario-developer>
```

## 3 · Unir al dominio (código, idempotente)

Con `dc01` levantado (`vagrant up` en la raíz del repo) y los usuarios del CSV dados de alta:

```bash
# dentro de la VM RHEL; el script llega por scp o directamente del repo:
curl -fsSL -o join-domain.sh https://raw.githubusercontent.com/yosefnaabid/activedirectory-lab/main/provision/rhel/join-domain.sh

sudo AD_ADMIN_PASS='vagrant' bash join-domain.sh
```

La contraseña del administrador del dominio va **por variable de entorno**, nunca en el código. El script termina con su verificación PASS/FAIL; si algo falla, el mensaje dice qué mirar.

## 4 · Verificar a mano

```bash
realm list                      # el dominio, unido y con login permitido
su - amenendez                  # usuario del CSV: primer login crea /home/amenendez
ssh jgarcia@192.168.56.15       # jgarcia es de G-LinuxAdmins...
sudo -l                         # ...y puede sudo (tras cambiar la contraseña inicial)
```

Nota: el primer login interactivo pide cambiar la contraseña inicial (`Bienvenid@.2026`), porque el alta del CSV marca *cambio obligatorio en el primer inicio*. Es la política del lab funcionando, no un error. Y `sudo` pide la contraseña ya cambiada del usuario.

## Siguiente iteración (documentada, no implementada)

La alternativa elegante es construir una box propia con Packer desde la ISO (kickstart + `vagrant package`), legal mientras no se redistribuya. No está incluida aún: exige la ISO bajo cuenta propia y un build largo, y el valor de esta pieza está en la integración con AD. El ADR 0008 recoge el razonamiento completo.

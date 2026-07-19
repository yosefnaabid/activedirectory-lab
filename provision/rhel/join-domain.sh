#!/usr/bin/env bash
#
# join-domain.sh · une el nodo RHEL al dominio lab.local (idempotente)
#
# La VM RHEL se crea fuera de Vagrant (no hay box oficial de RHEL; el porqué,
# en docs/adr/0008-nodo-rhel-sin-box-oficial.md) y este script la configura
# entera: red, descubrimiento del dominio, unión con realmd/sssd, homes
# automáticos y sudo por grupo de AD. Relanzarlo no rompe ni duplica nada.
#
# Uso, dentro de la VM y como root (la contraseña va por variable de entorno,
# nunca en el código):
#
#   sudo AD_ADMIN_PASS='vagrant' bash join-domain.sh
#
# Variables (todas opcionales salvo AD_ADMIN_PASS si aún no está unida):
#   AD_DOMAIN=lab.local         dominio
#   AD_ADMIN_USER=vagrant       cuenta de dominio con derecho a unir equipos
#   AD_ADMIN_PASS=              su contraseña (solo hace falta para la unión)
#   RHEL_IP=192.168.56.15       IP estática del nodo en la red del lab
#   DC_IP=192.168.56.10         IP del DC (será el DNS del nodo)
#   LAB_IFACE=                  interfaz de la red del lab (autodetectada)
#   VERIFY_USER=amenendez       usuario del CSV usado en la verificación
#   SUDO_GROUP=g-linuxadmins    grupo de AD con sudo (en minúsculas, ver 6/7)
#
# Ojo: si estás conectado por SSH a la IP del lab, el paso de red puede
# cortarte la sesión. Entra por la consola de VirtualBox o por la NAT.

set -euo pipefail

AD_DOMAIN="${AD_DOMAIN:-lab.local}"
AD_ADMIN_USER="${AD_ADMIN_USER:-vagrant}"
RHEL_IP="${RHEL_IP:-192.168.56.15}"
DC_IP="${DC_IP:-192.168.56.10}"
LAB_IFACE="${LAB_IFACE:-}"
VERIFY_USER="${VERIFY_USER:-amenendez}"
SUDO_GROUP="${SUDO_GROUP:-g-linuxadmins}"
FQDN="rhel01.${AD_DOMAIN}"

log()  { echo "[join] $*"; }
fail() { echo "[join] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "ejecútame como root:  sudo AD_ADMIN_PASS='...' bash $0"
grep -qi 'red hat enterprise linux' /etc/redhat-release 2>/dev/null \
  || fail "esto no parece RHEL (/etc/redhat-release). El lab usa RHEL a propósito."

# --- 0/7 · registro en Red Hat (paso manual previo) ---------------------------
# Sin registro no hay repos. Es la única parte que no se automatiza aquí:
# la suscripción (Red Hat Developer, gratuita) es personal.
if ! subscription-manager identity >/dev/null 2>&1; then
  fail "la máquina no está registrada en Red Hat. Regístrala primero:
          subscription-manager register --username <tu-usuario-developer>
       (cuenta gratuita en developers.redhat.com) y relanza este script."
fi
log "0/7 · registro de Red Hat: OK"

# --- 1/7 · red: IP estática y DNS del dominio ---------------------------------
# El DNS TIENE que ser el DC: descubrir el dominio son consultas SRV
# (_ldap._tcp.lab.local) que solo conoce el DNS de Active Directory.
if [ -z "${LAB_IFACE}" ]; then
  LAB_IFACE="$(ip -4 -o addr show | awk '/192\.168\.56\./ {print $2; exit}')"
fi
if [ -z "${LAB_IFACE}" ]; then
  # sin IP del lab todavía: la candidata es la ethernet SIN ruta por defecto
  # (la NAT de VirtualBox es la que la tiene)
  default_if="$(ip route show default | awk '{print $5; exit}')"
  LAB_IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: -v d="${default_if}" '$2=="ethernet" && $1!=d {print $1; exit}')"
fi
[ -n "${LAB_IFACE}" ] || fail "no localizo la interfaz de la red del lab; indícala:  LAB_IFACE=enp0s8 bash $0"

LAB_CON="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="${LAB_IFACE}" '$2==d {print $1; exit}')"
if [ -z "${LAB_CON}" ]; then
  nmcli connection add type ethernet ifname "${LAB_IFACE}" con-name lab >/dev/null
  LAB_CON="lab"
fi
# never-default: la salida a internet sigue por la NAT. dns-priority -1: el DNS
# del dominio gana siempre. Y en la NAT se ignora el DNS que regala VirtualBox:
# TODA la resolución pasa por el DC, como en un dominio real (los nombres
# externos los resuelve el DNS del DC de forma recursiva). Efecto colateral
# didáctico: si el DC cae, este nodo se queda sin DNS. Como en la vida real.
nmcli connection modify "${LAB_CON}" \
  ipv4.method manual ipv4.addresses "${RHEL_IP}/24" \
  ipv4.dns "${DC_IP}" ipv4.dns-search "${AD_DOMAIN}" \
  ipv4.dns-priority -1 ipv4.never-default yes
nmcli connection up "${LAB_CON}" >/dev/null

default_if="$(ip route show default | awk '{print $5; exit}')"
if [ -n "${default_if}" ] && [ "${default_if}" != "${LAB_IFACE}" ]; then
  NAT_CON="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="${default_if}" '$2==d {print $1; exit}')"
  if [ -n "${NAT_CON}" ]; then
    nmcli connection modify "${NAT_CON}" ipv4.ignore-auto-dns yes
    nmcli device reapply "${default_if}" >/dev/null 2>&1 || true
  fi
fi

timeout 5 bash -c "echo > /dev/tcp/${DC_IP}/389" 2>/dev/null \
  || fail "no llego al LDAP del DC (${DC_IP}:389). ¿Está dc01 levantado?"
log "1/7 · red del lab en ${LAB_IFACE}: ${RHEL_IP}/24, DNS ${DC_IP}"

# --- 2/7 · hostname ------------------------------------------------------------
# Se fija ANTES de la unión: es el nombre con el que se crea la cuenta de
# equipo en AD (RHEL01$) y el registro A en el DNS del dominio.
if [ "$(hostnamectl --static)" != "${FQDN}" ]; then
  hostnamectl set-hostname "${FQDN}"
  log "2/7 · hostname: ${FQDN}"
else
  log "2/7 · hostname ya es ${FQDN}"
fi

# --- 3/7 · paquetes de integración con AD --------------------------------------
# realmd orquesta la unión; sssd autentica (Kerberos) e identifica (LDAP)
# después; adcli crea la cuenta de equipo; oddjob-mkhomedir fabrica el home
# en el primer login; krb5-workstation trae kinit/klist para diagnosticar.
log "3/7 · instalando paquetes (dnf es idempotente; puede tardar)"
dnf install -y -q realmd sssd sssd-tools adcli oddjob oddjob-mkhomedir \
  samba-common-tools krb5-workstation >/dev/null

# --- 4/7 · descubrir y unir el dominio ------------------------------------------
if realm list 2>/dev/null | grep -q "domain-name: ${AD_DOMAIN}"; then
  log "4/7 · ya unido a ${AD_DOMAIN}; no repito la unión"
else
  realm discover "${AD_DOMAIN}" >/dev/null \
    || fail "realm discover no ve ${AD_DOMAIN}. Revisa /etc/resolv.conf (debe salir ${DC_IP})."
  [ -n "${AD_ADMIN_PASS:-}" ] \
    || fail "define AD_ADMIN_PASS con la contraseña de ${AD_ADMIN_USER} para poder unir:
          sudo AD_ADMIN_PASS='...' bash $0"
  log "4/7 · uniendo al dominio como ${AD_ADMIN_USER}..."
  printf '%s' "${AD_ADMIN_PASS}" | realm join --user="${AD_ADMIN_USER}" "${AD_DOMAIN}"
  log "4/7 · unión completada (cuenta de equipo creada en AD)"
fi

# --- 5/7 · sssd: nombres cortos y home en /home/<usuario> -----------------------
# use_fully_qualified_names=False: en un bosque de UN dominio el nombre corto
# no es ambiguo y es lo que se teclea a diario (login, chown, sudo). En un
# entorno multi-dominio se dejaría en True para evitar colisiones.
# fallback_homedir=/home/%u: homes tipo /home/amenendez, sin @lab.local.
SSSD_CONF=/etc/sssd/sssd.conf
cambiado=0
if grep -q '^use_fully_qualified_names *= *True' "${SSSD_CONF}"; then
  sed -i 's/^use_fully_qualified_names *=.*/use_fully_qualified_names = False/' "${SSSD_CONF}"
  cambiado=1
elif ! grep -q '^use_fully_qualified_names' "${SSSD_CONF}"; then
  sed -i '/^\[domain\//a use_fully_qualified_names = False' "${SSSD_CONF}"
  cambiado=1
fi
if grep -q '^fallback_homedir' "${SSSD_CONF}"; then
  if ! grep -q '^fallback_homedir *= */home/%u$' "${SSSD_CONF}"; then
    sed -i 's|^fallback_homedir *=.*|fallback_homedir = /home/%u|' "${SSSD_CONF}"
    cambiado=1
  fi
else
  sed -i '/^\[domain\//a fallback_homedir = /home/%u' "${SSSD_CONF}"
  cambiado=1
fi
if [ "${cambiado}" -eq 1 ]; then
  sss_cache -E 2>/dev/null || true
  systemctl restart sssd
  log "5/7 · sssd ajustado (nombres cortos, home /home/%u) y reiniciado"
else
  log "5/7 · sssd ya estaba ajustado"
fi

# --- 6/7 · homes automáticos y sudo para el grupo de AD -------------------------
authselect current 2>/dev/null | grep -q 'with-mkhomedir' \
  || authselect enable-feature with-mkhomedir >/dev/null
systemctl enable --now oddjobd >/dev/null 2>&1

# El grupo G-LinuxAdmins existe en AD (lo crea 02-estructura.ps1 desde
# lab.psd1). SSSD con el proveedor AD trata los nombres sin distinguir
# mayúsculas y los sirve en minúsculas: el grupo aparece como g-linuxadmins
# en 'id', y esa es la forma que debe usar el sudoers.
SUDOERS_FILE="/etc/sudoers.d/${SUDO_GROUP}"
if [ ! -f "${SUDOERS_FILE}" ] || ! grep -q "^%${SUDO_GROUP} " "${SUDOERS_FILE}"; then
  printf '%%%s ALL=(ALL) ALL\n' "${SUDO_GROUP}" > "${SUDOERS_FILE}"
  chmod 0440 "${SUDOERS_FILE}"
fi
visudo -cf "${SUDOERS_FILE}" >/dev/null || { rm -f "${SUDOERS_FILE}"; fail "sudoers inválido; lo retiro"; }
log "6/7 · sudo para %${SUDO_GROUP} (${SUDOERS_FILE})"

# --- 7/7 · verificación ----------------------------------------------------------
log "7/7 · verificación final"
FALLOS=0
ok() { echo "[ OK ]  $1"; }
ko() { echo "[FAIL]  $1"; FALLOS=$((FALLOS+1)); }
echo
echo "====  VERIFICACIÓN DEL NODO RHEL EN ${AD_DOMAIN}  ===="

realm list 2>/dev/null | grep -q "domain-name: ${AD_DOMAIN}" \
  && ok "realm list muestra ${AD_DOMAIN}" \
  || ko "realm list no muestra ${AD_DOMAIN}"

systemctl is-active --quiet sssd   && ok "sssd activo"    || ko "sssd no está activo"
systemctl is-active --quiet oddjobd && ok "oddjobd activo (homes automáticos)" || ko "oddjobd no está activo"

if id "${VERIFY_USER}" >/dev/null 2>&1 && id "${VERIFY_USER}@${AD_DOMAIN}" >/dev/null 2>&1; then
  ok "id resuelve a ${VERIFY_USER} (nombre corto y UPN)"
else
  ko "id no resuelve a ${VERIFY_USER} (¿alta del CSV hecha en el DC? prueba: sss_cache -E)"
fi

if getent group "${SUDO_GROUP}" >/dev/null 2>&1; then
  ok "grupo ${SUDO_GROUP} visible vía sssd (miembros: $(getent group "${SUDO_GROUP}" | cut -d: -f4))"
else
  ko "grupo ${SUDO_GROUP} no visible (¿lo creó 02-estructura.ps1 en AD?)"
fi

[ "$(getenforce 2>/dev/null)" = "Enforcing" ] && ok "SELinux en Enforcing" || ko "SELinux no está en Enforcing"
systemctl is-active --quiet firewalld && ok "firewalld activo" || ko "firewalld no está activo"

if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
  ok "reloj sincronizado (NTP)"
else
  ko "reloj SIN sincronizar: Kerberos falla con >5 min de desfase (systemctl restart chronyd)"
fi

echo
if [ "${FALLOS}" -eq 0 ]; then
  log "nodo integrado. Prueba un login:   su - ${VERIFY_USER}    (crea el home al vuelo)"
  log "y el sudo de un admin:  ssh jgarcia@${RHEL_IP} ; sudo -l   (es de G-LinuxAdmins)"
else
  log "ATENCIÓN: ${FALLOS} comprobación(es) fallidas."
fi
exit "${FALLOS}"

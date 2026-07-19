#!/usr/bin/env bash
#
# squid.sh · proxy corporativo en el nodo RHEL, autenticado contra el dominio
#
# Monta Squid con autenticacion Basic de usuarios del dominio (via PAM/SSSD:
# reutiliza la integracion que dejo join-domain.sh, sin credenciales de
# servicio nuevas), salida permitida solo al grupo de AD G-ProxyUsers y
# filtrado por lista declarativa de dominios (blocked-domains.txt).
# El porque de Basic y no Negotiate/Kerberos, con su trade-off, esta en
# docs/adr/0009-proxy-basic-sobre-sssd.md. Idempotente.
#
# Uso (dentro de la VM RHEL, como root, DESPUES de join-domain.sh):
#   sudo bash squid.sh
#
# Variables opcionales:
#   PROXY_PORT=3128            puerto de escucha
#   PROXY_GROUP=g-proxyusers   grupo de AD con salida (minusculas: SSSD)
set -euo pipefail

PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_GROUP="${PROXY_GROUP:-g-proxyusers}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[squid] $*"; }
fail() { echo "[squid] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "ejecutame como root:  sudo bash $0"

# Sin la union al dominio no hay a quien autenticar
realm list 2>/dev/null | grep -q 'domain-name:' \
  || fail "la maquina no esta unida al dominio. Ejecuta antes join-domain.sh."

# --- 1/5 · paquete ------------------------------------------------------------
log "1/5 · instalando squid (dnf es idempotente)"
dnf install -y -q squid >/dev/null

# --- 2/5 · autenticacion PAM -> SSSD -------------------------------------------
# basic_pam_auth valida las credenciales contra el servicio PAM 'squid'.
# Solo pam_sss: aqui autentican los usuarios DEL DOMINIO, no los locales.
PAM_FILE=/etc/pam.d/squid
cat > "${PAM_FILE}" <<'PAM'
#%PAM-1.0
# Autenticacion del proxy contra el dominio via SSSD (provisionado por codigo)
auth     required   pam_sss.so
account  required   pam_sss.so
PAM

# --- 3/5 · lista de dominios bloqueados ----------------------------------------
BLOCKED_DST=/etc/squid/blocked-domains.txt
if [ -f "${SCRIPT_DIR}/blocked-domains.txt" ]; then
  cp -f "${SCRIPT_DIR}/blocked-domains.txt" "${BLOCKED_DST}"
elif [ ! -f "${BLOCKED_DST}" ]; then
  # sin copia del repo a mano: se deja una lista minima operativa
  printf '# lista minima (la declarativa vive en el repo)\n.ejemplo-bloqueado.test\n' > "${BLOCKED_DST}"
fi
log "3/5 · lista de bloqueo en ${BLOCKED_DST} ($(grep -cv '^\s*\(#\|$\)' "${BLOCKED_DST}") dominios)"

# --- 4/5 · squid.conf ----------------------------------------------------------
# Se conserva el original una vez (squid.conf.orig) y se escribe la
# configuracion completa del lab: mas legible y mas facil de razonar que
# parchear con sed la de fabrica.
if [ ! -f /etc/squid/squid.conf.orig ]; then
  cp -n /etc/squid/squid.conf /etc/squid/squid.conf.orig
fi
cat > /etc/squid/squid.conf <<CONF
# /etc/squid/squid.conf · generado por provision/rhel/squid.sh (idempotente)
# El original de fabrica queda en squid.conf.orig

# --- autenticacion Basic contra el dominio (PAM -> SSSD -> Kerberos/AD) ---
# Trade-off documentado en docs/adr/0009: Basic manda user:pass en base64
# en cada peticion; vale para el lab, en produccion seria Negotiate.
auth_param basic program /usr/lib64/squid/basic_pam_auth
auth_param basic children 5 startup=2 idle=1
auth_param basic realm Proxy del laboratorio (usuario del dominio)
auth_param basic credentialsttl 2 hours

# --- ACLs ---
acl localnet src 192.168.56.0/24
acl SSL_ports port 443
acl Safe_ports port 80 443 21 1025-65535
acl CONNECT method CONNECT

# autenticado: cualquier usuario valido del dominio
acl autenticados proxy_auth REQUIRED

# con salida: ademas, miembro del grupo de AD (via NSS/SSSD, por eso el
# nombre va en minusculas). Quitar a alguien del grupo en AD le corta el
# proxy en el siguiente chequeo (ttl=300).
external_acl_type grupo_ad ttl=300 children-max=5 %LOGIN /usr/lib64/squid/ext_unix_group_acl -g ${PROXY_GROUP}
acl con_salida external grupo_ad

# dominios bloqueados: lista declarativa (se evalua antes de resolver DNS)
acl dominios_bloqueados dstdomain "${BLOCKED_DST}"

# --- reglas: el orden importa, gana la primera coincidencia ---
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access deny !autenticados
http_access deny dominios_bloqueados
http_access allow localnet con_salida
http_access deny all

http_port ${PROXY_PORT}

# proxy de control de salida, no de cache (lab)
cache deny all

# logs: quien, cuando, a donde, con que resultado (formato squid nativo)
access_log /var/log/squid/access.log squid
CONF

squid -k parse >/dev/null 2>&1 || { squid -k parse; fail "squid.conf no valida"; }
log "4/5 · squid.conf valida (squid -k parse)"

# --- 5/5 · firewall y servicio --------------------------------------------------
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PROXY_PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi
systemctl enable --now squid >/dev/null 2>&1
systemctl restart squid
log "5/5 · squid activo en el puerto ${PROXY_PORT}"

# --- verificacion ----------------------------------------------------------------
FALLOS=0
ok() { echo "[ OK ]  $1"; }
ko() { echo "[FAIL]  $1"; FALLOS=$((FALLOS+1)); }
echo
echo "====  VERIFICACION DEL PROXY  ===="

systemctl is-active --quiet squid && ok "servicio squid activo" || ko "squid no esta activo"
ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT} " && ok "escuchando en ${PROXY_PORT}" || ko "no escucha en ${PROXY_PORT}"
[ -x /usr/lib64/squid/basic_pam_auth ] && ok "helper basic_pam_auth presente" || ko "falta basic_pam_auth"
[ -x /usr/lib64/squid/ext_unix_group_acl ] && ok "helper ext_unix_group_acl presente" || ko "falta ext_unix_group_acl"
if getent group "${PROXY_GROUP}" >/dev/null 2>&1; then
  ok "grupo ${PROXY_GROUP} visible via sssd (miembros: $(getent group "${PROXY_GROUP}" | cut -d: -f4))"
else
  ko "grupo ${PROXY_GROUP} no visible: crea/reaplica la estructura en el DC (provision estructura)"
fi
[ "$(getenforce 2>/dev/null)" = "Enforcing" ] && ok "SELinux sigue en Enforcing" || ko "SELinux no esta en Enforcing"

echo
if [ "${FALLOS}" -eq 0 ]; then
  log "proxy listo. Pruebas desde cualquier maquina de la red del lab:"
  echo "    curl -x http://192.168.56.15:${PROXY_PORT} http://example.com -I                       # 407 (sin credenciales)"
  echo "    curl -x http://192.168.56.15:${PROXY_PORT} -U amenendez:... http://example.com -I      # 200 (miembro de ${PROXY_GROUP})"
  echo "    curl -x http://192.168.56.15:${PROXY_PORT} -U amenendez:... http://ejemplo-bloqueado.test -I   # 403 (lista de bloqueo)"
  echo "    curl -x http://192.168.56.15:${PROXY_PORT} -U mruiz:...     http://example.com -I      # 403 (autentica, pero sin grupo)"
  echo "    tail -f /var/log/squid/access.log    # cada acceso con su usuario"
else
  log "ATENCION: ${FALLOS} comprobacion(es) fallidas."
fi
exit "${FALLOS}"

#!/usr/bin/env bash
#
# onion-pi setup.sh
# ─────────────────────────────────────────────────────────────────────────────
# Instalador reproducible de un gateway Tor transparente en Raspberry Pi 4.
# Convierte la Pi en un AP WiFi aislado que fuerza todo el tráfico por Tor
# usando bridges (obfs4 + snowflake). Cero cambios en el router del ISP.
#
# Probado en: Raspberry Pi OS Lite (Bookworm), Pi 4 / Pi 5.
#
# USO BÁSICO
#   sudo WIFI_PASS='miPasswordFuerte' ./setup.sh
#
# USO CON BRIDGES OBFS4
#   1. Consigue bridges en https://bridges.torproject.org/  (transport: obfs4)
#   2. Pégalos en ./bridges.txt (una línea "Bridge obfs4 ..." por bridge)
#   3. sudo WIFI_PASS='...' ./setup.sh
#
# VARIABLES (todas opcionales salvo WIFI_PASS):
#   WIFI_PASS         password WPA2 (8-63 chars)              [obligatorio]
#   SSID              nombre de red                           [onion-pi]
#   WIFI_COUNTRY      código país                             [ES]
#   WIFI_CHANNEL      canal 2.4 GHz                           [6]
#   GATEWAY_IP        IP de la Pi en la red interna           [10.10.10.1]
#   SUBNET_MASK_BITS  prefijo CIDR                            [24]
#   DHCP_START/END    rango DHCP                              [.50 / .150]
#   WIFI_IFACE        interfaz AP                             [wlan0]
#   WAN_IFACE         interfaz de salida (router)             [eth0]
#   BRIDGES_FILE      ruta a bridges.txt                      [./bridges.txt]
#   ENABLE_SNOWFLAKE  1 para añadir snowflake como respaldo   [1]
#   ENABLE_FWKNOP     1 para port-knocking SPA en eth0        [1]
#   SSH_PORT          puerto SSH a proteger                   [22]
#
# IDEMPOTENTE: ejecutar dos veces no rompe nada. Backups en /etc/onion-pi-backup-*
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIG
# ============================================================================
# Si hay una instalación previa, preservar SSID/pass actuales para que un
# re-run del setup (manual o vía OTA) no sobreescriba cambios hechos desde
# la web UI a menos que se pase la env var explícitamente.
if [[ -z "${SSID:-}" && -r /etc/hostapd/hostapd.conf ]]; then
  SSID=$(sed -n 's/^ssid=//p' /etc/hostapd/hostapd.conf 2>/dev/null | head -1)
fi
if [[ -z "${WIFI_PASS:-}" && -r /etc/hostapd/hostapd.conf ]]; then
  WIFI_PASS=$(sed -n 's/^wpa_passphrase=//p' /etc/hostapd/hostapd.conf 2>/dev/null | head -1)
fi
SSID="${SSID:-onion-pi}"
WIFI_PASS="${WIFI_PASS:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-ES}"
WIFI_CHANNEL="${WIFI_CHANNEL:-6}"

GATEWAY_IP="${GATEWAY_IP:-10.10.10.1}"
SUBNET_MASK_BITS="${SUBNET_MASK_BITS:-24}"
DHCP_START="${DHCP_START:-10.10.10.50}"
DHCP_END="${DHCP_END:-10.10.10.150}"
DHCP_LEASE="${DHCP_LEASE:-12h}"

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
WAN_IFACE="${WAN_IFACE:-eth0}"

TOR_TRANS_PORT="${TOR_TRANS_PORT:-9040}"
TOR_DNS_PORT="${TOR_DNS_PORT:-5353}"
TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"

BRIDGES_FILE="${BRIDGES_FILE:-./bridges.txt}"
ENABLE_SNOWFLAKE="${ENABLE_SNOWFLAKE:-1}"
ENABLE_FWKNOP="${ENABLE_FWKNOP:-1}"
SSH_PORT="${SSH_PORT:-22}"
# Subredes (separadas por comas, sintaxis nftables) desde las que se
# permite SSH entrante por la WAN. Por defecto vacío: SSH cerrado en eth0
# y solo accesible vía fwknop SPA. Ejemplo: SSH_LAN_CIDR="192.168.1.0/24"
SSH_LAN_CIDR="${SSH_LAN_CIDR:-}"

# Web UI de gestión (status + cambio de SSID/pass/bridges, reboot, OTA).
# Se sirve SOLO desde el AP (10.10.10.x) en GATEWAY_IP:WEBUI_PORT.
# HTTP Basic auth con credenciales generadas en /etc/onion-pi-webui.passwd.
ENABLE_WEBUI="${ENABLE_WEBUI:-1}"
WEBUI_PORT="${WEBUI_PORT:-80}"

# OTA: timer systemd semanal que hace 'git pull && setup.sh' contra OTA_BRANCH.
# Si trabajas activamente en el repo en este host, ponlo a 0 para evitar
# sorpresas.
ENABLE_OTA="${ENABLE_OTA:-1}"
OTA_BRANCH="${OTA_BRANCH:-master}"

# Watchdog: cada N minutos comprueba que DNS+SOCKS pasan por Tor.
# Si fallan, reinicia Tor automáticamente. Si tras el reinicio aún falla,
# marca el estado como error (visible en web UI) para que sepas que
# probablemente los bridges están muertos y hay que actualizarlos.
ENABLE_WATCHDOG="${ENABLE_WATCHDOG:-1}"
WATCHDOG_INTERVAL_MIN="${WATCHDOG_INTERVAL_MIN:-5}"

# Auto-fetch de bridges: cuando el watchdog detecta que Tor no enruta y
# un reinicio no lo arregla, intenta sacar bridges nuevos del Moat builtin
# API (https://bridges.torproject.org/moat/circumvention/builtin) o de la
# lista bundled en bridges_default.txt. Si encuentra alguno vivo, lo aplica
# y reinicia Tor.
ENABLE_BRIDGE_RESCUE="${ENABLE_BRIDGE_RESCUE:-1}"
BRIDGE_RESCUE_KEEP_N="${BRIDGE_RESCUE_KEEP_N:-3}"

BACKUP_DIR="/etc/onion-pi-backup-$(date +%Y%m%d-%H%M%S)"
KEYS_OUT="/root/onion-pi-fwknop-keys.txt"
WEBUI_PASSWD_FILE="/etc/onion-pi-webui.passwd"
WEBUI_INITIALIZED_FLAG="/etc/onion-pi-webui.initialized"
OTA_STATE_FILE="/run/onion-pi-ota-state.json"
WATCHDOG_STATE_FILE="/run/onion-pi-watchdog-state.json"
BRIDGE_RESCUE_LOG="/var/log/onion-pi-bridge-rescue.log"
BUNDLED_BRIDGES_DST="/etc/onion-pi/bridges_default.txt"
STATE_FILE="/etc/onion-pi-installed"

# ============================================================================
# LOGGING
# ============================================================================
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=; GRN=; YEL=; CYN=; BLD=; RST=
fi
log()    { printf "${CYN}[*]${RST} %s\n" "$*"; }
ok()     { printf "${GRN}[+]${RST} %s\n" "$*"; }
warn()   { printf "${YEL}[!]${RST} %s\n" "$*"; }
err()    { printf "${RED}[x]${RST} %s\n" "$*" >&2; }
header() { printf "\n${BLD}${CYN}══ %s ══${RST}\n" "$*"; }

trap 'err "Falló en línea $LINENO (exit=$?)"; exit 1' ERR

# ============================================================================
# PREFLIGHT
# ============================================================================
preflight() {
  header "Preflight"

  [[ $EUID -eq 0 ]] || { err "Ejecuta como root: sudo $0"; exit 1; }

  if [[ -z "$WIFI_PASS" ]]; then
    err "Falta WIFI_PASS. Ejemplo:"
    err "  sudo WIFI_PASS='mipassword' $0"
    exit 1
  fi

  local len=${#WIFI_PASS}
  if (( len < 8 || len > 63 )); then
    err "WIFI_PASS debe tener entre 8 y 63 caracteres (WPA2). Tiene $len."
    exit 1
  fi

  if [[ "$WIFI_PASS" =~ [^[:print:]] ]]; then
    err "WIFI_PASS contiene caracteres no imprimibles."
    exit 1
  fi

  command -v apt-get >/dev/null || { err "Solo soportado en Debian/RPi OS"; exit 1; }

  if ! ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
    err "Interfaz WiFi '$WIFI_IFACE' no existe"; exit 1
  fi

  if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    warn "Interfaz WAN '$WAN_IFACE' no existe. Verifica WAN_IFACE."
  fi

  if [[ ! -f "$BRIDGES_FILE" && "$ENABLE_SNOWFLAKE" != "1" ]]; then
    err "Sin '$BRIDGES_FILE' ni snowflake habilitado, Tor no podrá conectar."
    err "Solución: crea bridges.txt o exporta ENABLE_SNOWFLAKE=1"
    exit 1
  fi

  if [[ ! -f "$BRIDGES_FILE" ]]; then
    warn "No hay '$BRIDGES_FILE' — usando solo snowflake."
  else
    local bcount
    bcount=$(grep -cE '^(Bridge[[:space:]]+(obfs4|snowflake|meek_lite|webtunnel)|(obfs4|snowflake|meek_lite|webtunnel))[[:space:]]' "$BRIDGES_FILE" 2>/dev/null || true)
    if (( bcount == 0 )); then
      if [[ "$ENABLE_SNOWFLAKE" == "1" ]]; then
        warn "'$BRIDGES_FILE' no contiene bridges válidos — usando solo snowflake."
      else
        err  "'$BRIDGES_FILE' no contiene bridges válidos y snowflake está desactivado."
        err  "Solución: pega líneas 'obfs4 ...' o 'Bridge obfs4 ...' en $BRIDGES_FILE,"
        err  "          o exporta ENABLE_SNOWFLAKE=1"
        exit 1
      fi
    else
      ok "Detectados $bcount bridge(s) en $BRIDGES_FILE"
    fi
  fi

  ok "Preflight OK"
}

# ============================================================================
# BACKUP
# ============================================================================
backup_files() {
  header "Backup de configs existentes"
  mkdir -p "$BACKUP_DIR"
  local files=(
    /etc/hostapd/hostapd.conf
    /etc/default/hostapd
    /etc/dnsmasq.conf
    /etc/tor/torrc
    /etc/nftables.conf
    /etc/sysctl.conf
    /etc/fwknop/access.conf
    /etc/fwknop/fwknopd.conf
    /etc/NetworkManager/conf.d/99-onion-pi.conf
  )
  for f in "${files[@]}"; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
  done
  ok "Backups → $BACKUP_DIR"
}

# ============================================================================
# PAQUETES
# ============================================================================
install_packages() {
  header "Instalando paquetes"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  local pkgs=(tor obfs4proxy hostapd dnsmasq nftables iproute2 openssl)
  [[ "$ENABLE_SNOWFLAKE" == "1" ]] && pkgs+=(snowflake-client)
  [[ "$ENABLE_FWKNOP"    == "1" ]] && pkgs+=(fwknop-server)

  for pkg in "${pkgs[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      continue
    fi
    log "  → $pkg"
    if ! apt-get install -y -qq "$pkg" 2>/dev/null; then
      if [[ "$pkg" == "snowflake-client" ]]; then
        warn "snowflake-client no está en repo. Desactivando snowflake."
        warn "  → para tenerlo: compila desde https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake"
        ENABLE_SNOWFLAKE=0
      else
        err "No pude instalar $pkg"; exit 1
      fi
    fi
  done

  systemctl unmask hostapd 2>/dev/null || true
  ok "Paquetes listos"
}

# ============================================================================
# NETWORKMANAGER — marcar wlan0 como no gestionado
# ============================================================================
configure_nm_unmanaged() {
  header "Aislando $WIFI_IFACE de gestores de red"

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "NetworkManager activo → $WIFI_IFACE pasará a unmanaged"
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-onion-pi.conf <<EOF
# Generado por onion-pi setup — no editar
[keyfile]
unmanaged-devices=interface-name:$WIFI_IFACE
EOF
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager
  fi

  # wpa_supplicant y dhcpcd no deben tocar wlan0
  systemctl stop "wpa_supplicant@${WIFI_IFACE}.service" 2>/dev/null || true
  systemctl disable "wpa_supplicant@${WIFI_IFACE}.service" 2>/dev/null || true

  if [[ -f /etc/dhcpcd.conf ]]; then
    if ! grep -q "denyinterfaces $WIFI_IFACE" /etc/dhcpcd.conf; then
      echo "denyinterfaces $WIFI_IFACE" >> /etc/dhcpcd.conf
    fi
  fi

  ok "$WIFI_IFACE liberada"
}

# ============================================================================
# IP estática vía systemd oneshot (independiente de dhcpcd / NM / networkd)
# ============================================================================
configure_static_ip() {
  header "IP estática para $WIFI_IFACE"

  cat > /etc/systemd/system/onion-pi-wlan.service <<EOF
[Unit]
Description=onion-pi static IP for $WIFI_IFACE
Before=hostapd.service dnsmasq.service
After=sys-subsystem-net-devices-${WIFI_IFACE}.device
Wants=sys-subsystem-net-devices-${WIFI_IFACE}.device
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link set $WIFI_IFACE up
ExecStart=/sbin/ip addr flush dev $WIFI_IFACE
ExecStart=/sbin/ip addr add $GATEWAY_IP/$SUBNET_MASK_BITS dev $WIFI_IFACE
ExecStartPost=/sbin/iw dev $WIFI_IFACE set power_save off
ExecStop=/sbin/ip addr flush dev $WIFI_IFACE
ExecStop=/sbin/ip link set $WIFI_IFACE down

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Servicio onion-pi-wlan creado"
}

# ============================================================================
# HOSTAPD
# ============================================================================
configure_hostapd() {
  header "Configurando hostapd (AP $SSID)"

  install -d -m 755 /etc/hostapd
  # Config minimalista para brcmfmac de la Pi 4 (firmware
  # BCM4345/6 v7.45.265, paquete firmware-brcm80211 20250410):
  #   * WPA2-PSK puro con SOLO `rsn_pairwise=CCMP` y `wpa_key_mgmt=WPA-PSK`.
  #   * Sin `wpa_pairwise`, `ieee80211n/d`, `wmm_enabled` — el firmware
  #     responde con `wpa_auth error -52` / `mfp error -52` si los incluyes.
  #   * Sin SAE: aunque el AP arranca con `wpa_key_mgmt=SAE`, la firmware
  #     falla el handshake con `brcmf_cfg80211_external_auth: status=1`,
  #     así que el cliente nunca termina de autenticarse y se le deauth-ea
  #     por inactividad. WPA3 NO funciona aquí, no lo intentes.
  #   * El `ctrl_interface` permite usar `hostapd_cli` para debug.
  #   * Tras cada cambio de config: NO encadenes `systemctl restart hostapd`;
  #     el firmware se degrada. Un reboot limpia.
  cat > /etc/hostapd/hostapd.conf <<EOF
# Generado por onion-pi setup
interface=$WIFI_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$WIFI_CHANNEL
country_code=$WIFI_COUNTRY
auth_algs=1
wpa=2
wpa_passphrase=$WIFI_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF
  chmod 600 /etc/hostapd/hostapd.conf

  if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
  fi

  mkdir -p /etc/systemd/system/hostapd.service.d
  cat > /etc/systemd/system/hostapd.service.d/onion-pi.conf <<EOF
[Unit]
After=onion-pi-wlan.service
Requires=onion-pi-wlan.service
EOF
  systemctl daemon-reload
  ok "hostapd configurado"
}

# ============================================================================
# DNSMASQ (solo DHCP; DNS lo hace Tor)
# ============================================================================
configure_dnsmasq() {
  header "Configurando dnsmasq (solo DHCP)"

  cat > /etc/dnsmasq.conf <<EOF
# Generado por onion-pi setup
interface=$WIFI_IFACE
bind-interfaces
listen-address=$GATEWAY_IP
dhcp-range=$DHCP_START,$DHCP_END,$DHCP_LEASE
dhcp-option=option:router,$GATEWAY_IP
dhcp-option=option:dns-server,$GATEWAY_IP
# DNS desactivado en dnsmasq — los clientes hablarán al :53 del gateway y
# nftables lo redirige al DNSPort de Tor. Sin fugas posibles.
port=0
log-dhcp
EOF

  mkdir -p /etc/systemd/system/dnsmasq.service.d
  cat > /etc/systemd/system/dnsmasq.service.d/onion-pi.conf <<EOF
[Unit]
After=onion-pi-wlan.service
Requires=onion-pi-wlan.service
EOF
  systemctl daemon-reload
  ok "dnsmasq configurado"
}

# ============================================================================
# TOR
# ============================================================================
configure_tor() {
  header "Configurando Tor (TransPort + bridges)"

  local snowflake_bin=""
  if [[ "$ENABLE_SNOWFLAKE" == "1" ]]; then
    snowflake_bin=$(command -v snowflake-client 2>/dev/null || true)
    [[ -z "$snowflake_bin" ]] && { warn "snowflake-client no encontrado"; ENABLE_SNOWFLAKE=0; }
  fi

  {
    cat <<EOF
# Generado por onion-pi setup — $(date)

# ─── Transparent proxy ──────────────────────────────────────────────
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit

TransPort $GATEWAY_IP:$TOR_TRANS_PORT IsolateClientAddr IsolateDestAddr IsolateDestPort
DNSPort   $GATEWAY_IP:$TOR_DNS_PORT
SOCKSPort $GATEWAY_IP:$TOR_SOCKS_PORT IsolateClientAddr IsolateDestAddr IsolateDestPort

# ─── Bridges ────────────────────────────────────────────────────────
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
EOF

    if [[ "$ENABLE_SNOWFLAKE" == "1" ]]; then
      echo "ClientTransportPlugin snowflake exec $snowflake_bin"
    fi

    if [[ -f "$BRIDGES_FILE" ]]; then
      echo ""
      echo "# obfs4 desde $BRIDGES_FILE"
      # Acepta tanto "Bridge obfs4 ..." como "obfs4 ..." (sin prefijo).
      # Ignora comentarios (#) y líneas en blanco.
      while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ ^Bridge[[:space:]] ]]; then
          echo "$line"
        elif [[ "$line" =~ ^(obfs4|snowflake|meek_lite|webtunnel)[[:space:]] ]]; then
          echo "Bridge $line"
        fi
      done < "$BRIDGES_FILE"
    fi

    if [[ "$ENABLE_SNOWFLAKE" == "1" ]]; then
      cat <<'EOF'

# Snowflake (público — broker en CDN77 desde 2024; el viejo en Fastly tiene
# el certificado caducado y falla con x509 cert mismatch).
# Si vuelve a romperse, saca la config nueva de:
#   https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake/-/raw/main/client/torrc
Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://1098762253.rsc.cdn77.org/ fronts=www.cdn77.com,www.phpmyadmin.net ice=stun:stun.l.google.com:19302,stun:stun.antisip.com:3478,stun:stun.bluesip.net:3478,stun:stun.dus.net:3478,stun:stun.epygi.com:3478 utls-imitate=hellorandomizedalpn
EOF
    fi

    cat <<EOF

# ─── Endurecimiento ─────────────────────────────────────────────────
ClientUseIPv6 0
SafeLogging 1
Log notice file /var/log/tor/notices.log
EOF
  } > /etc/tor/torrc

  chown root:root /etc/tor/torrc
  chmod 644 /etc/tor/torrc
  install -d -o debian-tor -g debian-tor -m 750 /var/log/tor 2>/dev/null || \
  install -d -m 755 /var/log/tor
  ok "Tor configurado"
}

# ============================================================================
# NFTABLES — redirect TCP+DNS a Tor, drop el resto, sin forwarding
# ============================================================================
configure_nftables() {
  header "Configurando nftables (kill-switch implícito)"

  cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Generado por onion-pi setup
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded, parameter-problem } limit rate 10/second accept
        ip6 nexthdr icmpv6 limit rate 10/second accept

        iifname "$WAN_IFACE" jump wan_in
        iifname "$WIFI_IFACE" jump lan_in
    }

    chain wan_in {
$( [[ -n "$SSH_LAN_CIDR" ]] && for cidr in ${SSH_LAN_CIDR//,/ }; do
     echo "        iifname \"$WAN_IFACE\" ip saddr $cidr tcp dport $SSH_PORT accept   comment \"SSH LAN $cidr\""
   done )
        # SSH cerrado por defecto desde la WAN.
        # fwknopd añade reglas temporales aquí cuando recibe un SPA válido.
    }

    chain lan_in {
        udp dport 67 accept                                          comment "DHCP"
        tcp dport $TOR_TRANS_PORT accept                             comment "Tor TransPort"
        udp dport $TOR_DNS_PORT accept                               comment "Tor DNSPort UDP"
        tcp dport $TOR_DNS_PORT accept                               comment "Tor DNSPort TCP"
        tcp dport $TOR_SOCKS_PORT accept                             comment "Tor SOCKS"
        tcp dport $SSH_PORT accept                                   comment "SSH LAN"
        tcp dport $WEBUI_PORT accept                                 comment "Web UI"
        udp dport 53 accept                                          comment "DNS pre-redirect"
        tcp dport 53 accept                                          comment "DNS pre-redirect"
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # Sin forwarding. Tor escucha local. Si Tor cae → no hay internet.
        # Esto es el kill-switch implícito.
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
        # DNS al gateway → Tor DNS (debe ir ANTES del bypass para que las
        # queries del cliente al :53 sí se redirijan).
        iifname "$WIFI_IFACE" udp dport 53 redirect to :$TOR_DNS_PORT
        iifname "$WIFI_IFACE" tcp dport 53 redirect to :$TOR_DNS_PORT
        # Tráfico TCP al puerto del web UI en el gateway → pasar sin redirigir.
        # (también SSH al gateway si está abierto en lan_in).
        iifname "$WIFI_IFACE" ip daddr $GATEWAY_IP tcp dport { $WEBUI_PORT, $SSH_PORT } return
        # Resto del TCP del cliente → Tor TransPort.
        iifname "$WIFI_IFACE" meta l4proto tcp redirect to :$TOR_TRANS_PORT
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        # Sin masquerade: nada sale al WAN sin pasar por Tor (proceso local).
    }
}
EOF

  # ip_forward OFF a propósito — Tor es local, no necesitamos forwarding
  if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's|^net.ipv4.ip_forward.*|net.ipv4.ip_forward=0|' /etc/sysctl.conf
  else
    echo 'net.ipv4.ip_forward=0' >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null 2>&1 || true

  # Validar sintaxis antes de aplicar
  nft -c -f /etc/nftables.conf
  ok "nftables configurado y validado"
}

# ============================================================================
# FWKNOP — Port knocking SPA en la interfaz WAN
# ============================================================================
configure_fwknop() {
  [[ "$ENABLE_FWKNOP" != "1" ]] && return 0
  command -v fwknopd >/dev/null || { warn "fwknopd no instalado"; return 0; }

  header "Configurando fwknop (SPA) en $WAN_IFACE"

  install -d -m 700 /etc/fwknop

  local KEY_B64 HMAC_B64
  if [[ -f "$KEYS_OUT" ]] && grep -q '^KEY_BASE64=' "$KEYS_OUT"; then
    log "Reutilizando claves de $KEYS_OUT"
    KEY_B64=$(grep '^KEY_BASE64='      "$KEYS_OUT" | cut -d= -f2-)
    HMAC_B64=$(grep '^HMAC_KEY_BASE64=' "$KEYS_OUT" | cut -d= -f2-)
  else
    KEY_B64=$(openssl rand -base64 16  | tr -d '\n')
    HMAC_B64=$(openssl rand -base64 32 | tr -d '\n')
  fi

  cat > /etc/fwknop/access.conf <<EOF
SOURCE:                 ANY
OPEN_PORTS:             tcp/$SSH_PORT
KEY_BASE64:             $KEY_B64
HMAC_KEY_BASE64:        $HMAC_B64
FW_ACCESS_TIMEOUT:      30
REQUIRE_SOURCE_ADDRESS: Y
EOF
  chmod 600 /etc/fwknop/access.conf

  cat > /etc/fwknop/fwknopd.conf <<EOF
PCAP_INTF             $WAN_IFACE;
ENABLE_NFT_FIREWALL   Y;
NFT_TABLE             inet filter;
NFT_INPUT_CHAIN       wan_in;
PCAP_FILTER           udp port 62201;
EOF
  chmod 600 /etc/fwknop/fwknopd.conf

  cat > "$KEYS_OUT" <<EOF
# Claves fwknop generadas por onion-pi setup
# GUÁRDALAS A BUEN RECAUDO. Para conectar desde tu cliente:
#
#   fwknop -A tcp/$SSH_PORT -a TU_IP_DE_ORIGEN -D <IP_pi_eth0> \\
#          --key-base64 '$KEY_B64' \\
#          --hmac-key-base64 '$HMAC_B64' \\
#          --use-hmac
#   ssh pi@<IP_pi_eth0>

KEY_BASE64=$KEY_B64
HMAC_KEY_BASE64=$HMAC_B64
EOF
  chmod 600 "$KEYS_OUT"
  ok "fwknop listo — claves en $KEYS_OUT"
}

# ============================================================================
# WEB UI — status + cambio de SSID/pass/bridges/reboot/OTA, LAN-only
# ============================================================================
configure_webui() {
  [[ "$ENABLE_WEBUI" != "1" ]] && { warn "Web UI deshabilitada (ENABLE_WEBUI=0)"; return 0; }
  header "Configurando web UI (en http://$GATEWAY_IP:$WEBUI_PORT)"

  # Credenciales: el wizard de onboarding del web UI las establece en el
  # primer acceso. Aquí sólo aseguramos que los ficheros existan con
  # permisos correctos. El wizard se muestra mientras no exista
  # /etc/onion-pi-webui.initialized.
  if [[ ! -f "$WEBUI_PASSWD_FILE" ]]; then
    install -m 600 /dev/null "$WEBUI_PASSWD_FILE"
  fi
  chmod 600 "$WEBUI_PASSWD_FILE"

  if [[ -f "$WEBUI_INITIALIZED_FLAG" ]]; then
    log "Onboarding ya completado (web UI con credenciales del wizard)."
  else
    log "Onboarding pendiente — el wizard se mostrará en http://$GATEWAY_IP:$WEBUI_PORT"
  fi

  install -d -m 755 /usr/local/lib/onion-pi-webui

  # ── App Python (stdlib only) ────────────────────────────────────────
  cat > /usr/local/lib/onion-pi-webui/app.py <<'PYEOF'
#!/usr/bin/env python3
"""onion-pi web UI — status + config. LAN-only, HTTP Basic auth.
Sólo stdlib. Corre como root para poder reescribir hostapd.conf, torrc, etc.
"""
import os, re, json, time, base64, subprocess, html, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PASSWD_FILE       = "/etc/onion-pi-webui.passwd"
ONBOARDING_FLAG   = "/etc/onion-pi-webui.initialized"
HOSTAPD_CONF      = "/etc/hostapd/hostapd.conf"
TORRC             = "/etc/tor/torrc"
BRIDGES_FILE      = "/root/bridges.txt"
LEASES_FILE       = "/var/lib/misc/dnsmasq.leases"
NOTICES_LOG       = "/var/log/tor/notices.log"
OTA_SCRIPT        = "/usr/local/sbin/onion-pi-ota-update.sh"
OTA_STATE_FILE    = "/run/onion-pi-ota-state.json"
WATCHDOG_STATE    = "/run/onion-pi-watchdog-state.json"
WATCHDOG_SCRIPT   = "/usr/local/sbin/onion-pi-watchdog.sh"
REBOOT_REQUIRED   = "/var/run/reboot-required"
REBOOT_FLAG_LOCAL = "/run/onion-pi-needs-reboot"

_ip_cache = {"value": None, "ts": 0}
_ip_lock  = threading.Lock()

def sh(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10, **kw).stdout
    except Exception as e:
        return f"ERR: {e}"

def load_creds():
    c = {}
    try:
        with open(PASSWD_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    c[k] = v
    except Exception:
        pass
    return c

def is_onboarded():
    return os.path.exists(ONBOARDING_FLAG) and load_creds().get("pass")

def save_credentials(user, password):
    with open(PASSWD_FILE, "w") as f:
        f.write(f"user={user}\npass={password}\n")
    os.chmod(PASSWD_FILE, 0o600)

def mark_onboarded():
    with open(ONBOARDING_FLAG, "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
    os.chmod(ONBOARDING_FLAG, 0o600)

def needs_reboot():
    return os.path.exists(REBOOT_REQUIRED) or os.path.exists(REBOOT_FLAG_LOCAL)

def ota_state():
    try:
        with open(OTA_STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"state": "idle", "message": "", "needs_reboot": False}

def watchdog_state():
    try:
        with open(WATCHDOG_STATE) as f:
            return json.load(f)
    except Exception:
        return {"state": "idle", "message": "Watchdog aún no ha corrido",
                "active_clients": 0, "dns_ok": None, "socks_ok": None}

def read_hostapd():
    """Returns dict ssid/passphrase/channel/country_code."""
    out = {}
    try:
        with open(HOSTAPD_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ssid="): out["ssid"] = line[5:]
                elif line.startswith("wpa_passphrase="): out["passphrase"] = line[15:]
                elif line.startswith("channel="): out["channel"] = line[8:]
                elif line.startswith("country_code="): out["country"] = line[13:]
    except Exception:
        pass
    return out

def read_bridges():
    """Return current Bridge lines from torrc (without 'Bridge ' prefix)."""
    out = []
    try:
        with open(TORRC) as f:
            for line in f:
                line = line.strip()
                if line.startswith("Bridge "):
                    out.append(line[7:])
    except Exception:
        pass
    return out

def tor_bootstrap():
    try:
        last = sh(["grep", "Bootstrapped", NOTICES_LOG])
        last = [l for l in last.splitlines() if "Bootstrapped" in l]
        if not last: return "(desconocido)"
        m = re.search(r"Bootstrapped (\d+)%", last[-1])
        return f"{m.group(1)}%" if m else "?"
    except Exception:
        return "(desconocido)"

def service_status(name):
    rc = subprocess.run(["systemctl", "is-active", name],
                         capture_output=True, text=True)
    return rc.stdout.strip()

def clients():
    """Returns list of (mac, ip, hostname) from dnsmasq leases."""
    rows = []
    try:
        with open(LEASES_FILE) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 4:
                    rows.append({"mac": parts[1], "ip": parts[2], "name": parts[3]})
    except Exception:
        pass
    return rows

def tor_public_ip():
    """Cached check.torproject.org/api/ip via SOCKS (5min TTL)."""
    with _ip_lock:
        if time.time() - _ip_cache["ts"] < 300 and _ip_cache["value"]:
            return _ip_cache["value"]
    try:
        out = sh(["curl", "-s", "--max-time", "8",
                  "--socks5-hostname", "127.0.0.1:9050",
                  "https://check.torproject.org/api/ip"])
        data = json.loads(out)
        val = f"{data.get('IP','?')} (Tor={data.get('IsTor', False)})"
    except Exception:
        val = "(no disponible)"
    with _ip_lock:
        _ip_cache["update"] = val
        _ip_cache["value"] = val
        _ip_cache["ts"] = time.time()
    return val

def update_hostapd(new_ssid, new_pass):
    """Reescribe SSID y/o passphrase en hostapd.conf. Devuelve True si cambió."""
    new_ssid = new_ssid.strip()
    new_pass = new_pass.strip()
    changed = False
    with open(HOSTAPD_CONF) as f:
        lines = f.readlines()
    for i, line in enumerate(lines):
        if new_ssid and line.startswith("ssid="):
            if line.strip() != f"ssid={new_ssid}":
                lines[i] = f"ssid={new_ssid}\n"; changed = True
        elif new_pass and line.startswith("wpa_passphrase="):
            if line.strip() != f"wpa_passphrase={new_pass}":
                lines[i] = f"wpa_passphrase={new_pass}\n"; changed = True
    if changed:
        with open(HOSTAPD_CONF, "w") as f:
            f.writelines(lines)
        os.chmod(HOSTAPD_CONF, 0o600)
    return changed

def update_bridges(text):
    """Reescribe la lista de bridges en torrc. Una línea por bridge."""
    new_bridges = []
    for raw in text.replace("\r", "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"): continue
        if line.startswith("Bridge "):
            new_bridges.append(line)
        else:
            new_bridges.append("Bridge " + line)

    with open(TORRC) as f:
        contents = f.read()
    new_content = []
    in_bridge_section = False
    bridges_written = False
    for line in contents.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("Bridge "):
            if not bridges_written:
                for b in new_bridges:
                    new_content.append(b + "\n")
                bridges_written = True
        else:
            new_content.append(line)
    if not bridges_written and new_bridges:
        new_content.append("\n# Bridges (web UI)\n")
        for b in new_bridges:
            new_content.append(b + "\n")
    with open(TORRC, "w") as f:
        f.writelines(new_content)
    return True

def defer_restart(unit, delay=3):
    """Reinicia un servicio en N segundos para que la response llegue antes."""
    subprocess.Popen(["systemd-run", f"--on-active={delay}s",
                       "--unit=onion-pi-deferred-restart-" + unit,
                       "systemctl", "restart", unit])

# ── HTML ────────────────────────────────────────────────────────────
CSS = """
*{box-sizing:border-box}body{font-family:system-ui,sans-serif;margin:0;background:#0e0e10;color:#eaeaea;line-height:1.5}
.container{max-width:920px;margin:0 auto;padding:1.5rem}
h1{margin-top:0;color:#9e7cff}h2{color:#bea0ff;border-bottom:1px solid #2c2c33;padding-bottom:.3rem;margin-top:2rem}
.card{background:#1a1a1f;border:1px solid #2c2c33;border-radius:8px;padding:1rem 1.2rem;margin-bottom:1rem}
.row{display:grid;grid-template-columns:170px 1fr;gap:.5rem 1rem;margin-bottom:.3rem}
.label{color:#888}.ok{color:#7be17b}.bad{color:#ff7a7a}.warn{color:#ffd166}
input[type=text],input[type=password],textarea{width:100%;padding:.5rem;background:#0a0a0c;border:1px solid #333;color:#eaeaea;border-radius:4px;font-family:inherit;font-size:1rem}
textarea{font-family:monospace;font-size:.85rem;min-height:120px}
button{background:#9e7cff;color:#0a0a0c;border:0;padding:.5rem 1rem;border-radius:4px;font-weight:600;cursor:pointer;margin-top:.5rem}
button.danger{background:#ff7a7a}
.muted{color:#888;font-size:.85rem}
table{width:100%;border-collapse:collapse;font-size:.9rem}
td,th{padding:.3rem .5rem;border-bottom:1px solid #2c2c33;text-align:left}
.flash{background:#264a26;border:1px solid #7be17b;color:#cdf2cd;padding:.5rem 1rem;border-radius:4px;margin-bottom:1rem}
"""

def render(flash=None):
    h = read_hostapd()
    boot = tor_bootstrap()
    services = {s: service_status(s) for s in
                ["onion-pi-wlan","nftables","hostapd","dnsmasq","tor","onion-pi-webui"]}
    cs = clients()
    bridges = read_bridges()
    flash_html = f'<div class="flash">{html.escape(flash)}</div>' if flash else ""
    ssid = html.escape(h.get("ssid", ""))
    channel = html.escape(h.get("channel", ""))
    country = html.escape(h.get("country", ""))
    svc_rows = ""
    for s, st in services.items():
        cls = "ok" if st == "active" else "bad"
        svc_rows += f'<tr><td>{s}</td><td class="{cls}">{st}</td></tr>'
    cli_rows = ""
    for c in cs:
        cli_rows += f'<tr><td>{html.escape(c["mac"])}</td><td>{html.escape(c["ip"])}</td><td>{html.escape(c["name"])}</td></tr>'
    if not cli_rows:
        cli_rows = '<tr><td colspan="3" class="muted">(ninguno)</td></tr>'
    bridges_text = html.escape("\n".join(bridges))
    reboot_banner = ""
    if needs_reboot():
        reboot_banner = """<div class="card needs-reboot"><strong>⚠ Hace falta reiniciar la Pi</strong>
<p class="muted">Una actualización requiere un reboot completo (kernel, firmware o cambios de driver). Tus clientes WiFi reconectarán automáticamente cuando vuelva a arrancar.</p>
<form method="post" action="/reboot" onsubmit="return confirm('¿Reiniciar la Pi ahora? Tu sesión se cortará.')"><button type="submit" class="danger">Reiniciar ahora</button></form></div>"""

    wd = watchdog_state()
    wd_state = wd.get("state", "idle")
    wd_msg   = html.escape(wd.get("message", ""))
    wd_when  = html.escape(wd.get("last_check", "—"))
    wd_clients = wd.get("active_clients", 0)
    wd_remediated = wd.get("remediated", False)
    wd_color = {"ok":"ok", "warning":"warn", "error":"bad",
                "idle":"muted"}.get(wd_state, "muted")
    wd_extra = ""
    if wd_state == "error":
        wd_extra = '<p class="muted">El watchdog ya intentó reiniciar Tor y aún así no resuelve. Probablemente tus bridges están muertos o el ISP filtra obfs4. <strong>Edita los bridges abajo y guarda</strong> — sacándolos nuevos en https://bridges.torproject.org/</p>'
    elif wd_state == "warning":
        wd_extra = '<p class="muted">Reparación en curso, espera unos segundos y recarga.</p>'
    elif wd_remediated:
        wd_extra = '<p class="muted">El watchdog tuvo que reiniciar Tor para recuperar la conectividad — vigila si pasa a menudo.</p>'
    wd_banner = f"""<div class="card"><h2>Watchdog · <span class="{wd_color}">{wd_state}</span></h2>
<p>{wd_msg}</p>
{wd_extra}
<p class="muted">Último chequeo: {wd_when} · clientes activos: {wd_clients}</p>
<form method="post" action="/api/watchdog/run" id="wdForm" style="display:inline"><button type="button" id="wdBtn">Ejecutar ahora</button></form>
</div>"""
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>onion-pi · {ssid}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>{CSS}
.needs-reboot{{background:#4a2626;border-color:#ff7a7a}}
.ota-panel{{display:none}}
.ota-panel.show{{display:block}}
.ota-state-running{{color:#ffd166}}
.ota-state-success{{color:#7be17b}}
.ota-state-error{{color:#ff7a7a}}
.ota-state-needs_reboot{{color:#ff7a7a;font-weight:600}}
.spinner{{display:inline-block;width:1em;height:1em;border:2px solid #444;border-top-color:#9e7cff;border-radius:50%;animation:spin 1s linear infinite;vertical-align:middle;margin-right:.4rem}}
@keyframes spin{{to{{transform:rotate(360deg)}}}}
</style></head><body><div class="container">
<h1>onion-pi · {ssid}</h1>
{flash_html}
{reboot_banner}
{wd_banner}
<div class="card ota-panel" id="otaPanel">
  <h2>Actualización OTA</h2>
  <p id="otaMessage" class="muted">—</p>
  <p id="otaMeta" class="muted" style="font-size:.8rem"></p>
</div>
<div class="card"><h2>Estado</h2>
  <div class="row"><span class="label">SSID</span><span>{ssid}</span></div>
  <div class="row"><span class="label">Canal · País</span><span>{channel} · {country}</span></div>
  <div class="row"><span class="label">Tor bootstrap</span><span>{boot}</span></div>
  <div class="row"><span class="label">IP pública (Tor)</span><span class="muted">{html.escape(tor_public_ip())}</span></div>
</div>
<div class="card"><h2>Servicios</h2><table>{svc_rows}</table></div>
<div class="card"><h2>Clientes conectados</h2>
  <table><tr><th>MAC</th><th>IP</th><th>Nombre</th></tr>{cli_rows}</table></div>
<div class="card"><h2>WiFi (SSID / contraseña)</h2>
<form method="post" action="/wifi"><div class="row">
<label class="label" for="ssid">SSID</label><input type="text" id="ssid" name="ssid" value="{ssid}" required minlength="1" maxlength="32"></div>
<div class="row"><label class="label" for="password">Contraseña</label><input type="password" id="password" name="password" placeholder="(dejar en blanco = sin cambio)" minlength="8" maxlength="63"></div>
<button type="submit">Aplicar (reinicia hostapd)</button>
<p class="muted">Cuidado: tu móvil tendrá que reconectar y olvidar la red anterior si cambias la pass.</p></form></div>
<div class="card"><h2>Bridges Tor</h2>
<form method="post" action="/bridges"><textarea name="bridges" placeholder="obfs4 1.2.3.4:443 ...&#10;obfs4 5.6.7.8:9001 ...">{bridges_text}</textarea>
<button type="submit">Guardar y reiniciar Tor</button>
<button type="button" id="autoBridgeBtn" style="background:#3a8a3a">Buscar bridges públicos nuevos</button>
<p class="muted">Una línea por bridge. Admite el formato con o sin prefijo 'Bridge'.<br>
"Buscar nuevos" rota a bridges del pool público (Moat API + lista bundled) — el watchdog lo hace solo cuando detecta fallo, este botón lo dispara a demanda.</p></form></div>
<div class="card"><h2>Mantenimiento</h2>
<button id="otaBtn" type="button">Comprobar OTA ahora</button>
<form method="post" action="/reboot" style="display:inline" onsubmit="return confirm('¿Reiniciar la Pi ahora? Tu sesión se cortará.')"><button type="submit" class="danger">Reiniciar Pi</button></form>
<p class="muted">El OTA hace <code>git pull</code> contra master y reaplica la configuración. Si toca kernel/firmware te avisará para reboot.</p>
</div>
<script>
(function() {{
  var btn = document.getElementById('otaBtn');
  var panel = document.getElementById('otaPanel');
  var msg = document.getElementById('otaMessage');
  var meta = document.getElementById('otaMeta');
  var poller = null;
  function setUI(state) {{
    panel.classList.add('show');
    var spinner = state.state === 'running' ? '<span class="spinner"></span>' : '';
    msg.innerHTML = spinner + '<span class="ota-state-' + state.state + '">[' + state.state + ']</span> ' + (state.message || '');
    var detail = [];
    if (state.before) detail.push('antes: ' + state.before.substring(0,8));
    if (state.after) detail.push('después: ' + state.after.substring(0,8));
    if (state.finished_at) detail.push('terminado: ' + state.finished_at);
    meta.textContent = detail.join(' · ');
    if (state.state === 'needs_reboot' || state.needs_reboot) {{
      setTimeout(function() {{ location.reload(); }}, 1500);
    }} else if (state.state === 'success') {{
      setTimeout(function() {{ location.reload(); }}, 2000);
    }}
  }}
  function poll() {{
    fetch('/api/ota/status').then(function(r) {{ return r.json(); }}).then(function(s) {{
      setUI(s);
      if (s.state === 'running') {{
        // continue polling
      }} else {{
        clearInterval(poller); poller = null;
      }}
    }}).catch(function() {{}});
  }}
  btn.addEventListener('click', function() {{
    btn.disabled = true; btn.textContent = 'OTA en curso...';
    fetch('/api/ota/start', {{method:'POST'}}).then(function() {{
      panel.classList.add('show'); poll();
      if (!poller) poller = setInterval(poll, 2000);
    }});
  }});
  // Si ya hay un OTA en curso al cargar, mostrarlo
  fetch('/api/ota/status').then(function(r){{return r.json();}}).then(function(s){{
    if (s.state && s.state !== 'idle') {{
      setUI(s);
      if (s.state === 'running' && !poller) poller = setInterval(poll, 2000);
    }}
  }});

  // Watchdog: botón "Ejecutar ahora" + auto-refresh cada 15s
  var wdBtn = document.getElementById('wdBtn');
  if (wdBtn) {{
    wdBtn.addEventListener('click', function() {{
      wdBtn.disabled = true; wdBtn.textContent = 'Ejecutando...';
      fetch('/api/watchdog/run', {{method:'POST'}}).then(function(){{
        setTimeout(function(){{ location.reload(); }}, 12000);
      }});
    }});
  }}
  // Bridge auto-fetch
  var abBtn = document.getElementById('autoBridgeBtn');
  if (abBtn) {{
    abBtn.addEventListener('click', function() {{
      if (!confirm('Buscar bridges nuevos en el pool público y rotar Tor a ellos. ¿Continuar?')) return;
      abBtn.disabled = true; abBtn.textContent = 'Buscando y rotando bridges...';
      fetch('/api/bridges/auto-fetch', {{method:'POST'}}).then(function(){{
        setTimeout(function(){{ location.reload(); }}, 15000);
      }});
    }});
  }}
}})();
</script>
</div></body></html>"""

# ── Wizard de onboarding (primer arranque) ───────────────────────────
def render_wizard(error=None):
    h = read_hostapd()
    ssid_now = html.escape(h.get("ssid", "onion-pi"))
    err_html = f'<div class="flash bad">{html.escape(error)}</div>' if error else ""
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>onion-pi · configuración inicial</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>{CSS}
.flash.bad{{background:#4a2626;border-color:#ff7a7a;color:#ffcdcd}}
fieldset{{border:1px solid #2c2c33;border-radius:6px;padding:1rem;margin-bottom:1rem}}
legend{{padding:0 .5rem;color:#9e7cff}}
label{{display:block;margin-bottom:.6rem}}
label span{{display:block;color:#888;font-size:.85rem;margin-bottom:.2rem}}
</style></head><body><div class="container">
<h1>Bienvenido a onion-pi</h1>
<p class="muted">Primer arranque. Establece la contraseña del panel de gestión.
Tu Pi no tendrá acceso de admin hasta que completes este paso.</p>
{err_html}
<form method="post" action="/api/setup">
  <fieldset>
    <legend>Credenciales del panel</legend>
    <label><span>Usuario admin</span>
      <input type="text" name="admin_user" value="admin" required pattern="[A-Za-z0-9._-]{{2,32}}"></label>
    <label><span>Contraseña (mínimo 8 caracteres)</span>
      <input type="password" name="admin_pass" required minlength="8"></label>
    <label><span>Repite contraseña</span>
      <input type="password" name="admin_pass2" required minlength="8"></label>
  </fieldset>
  <fieldset>
    <legend>WiFi (opcional)</legend>
    <p class="muted">Si quieres dejarlo como está, ignora este bloque y la pass actual seguirá funcionando.</p>
    <label><span>SSID</span>
      <input type="text" name="ssid" value="{ssid_now}" maxlength="32"></label>
    <label><span>Nueva contraseña WiFi (vacío = sin cambio)</span>
      <input type="password" name="wifi_pass" minlength="0" maxlength="63"></label>
  </fieldset>
  <button type="submit">Finalizar configuración</button>
</form>
</div></body></html>"""

def handle_setup(form):
    """Validar y aplicar el onboarding. Retorna None si OK, string con error si no."""
    user = form.get("admin_user", [""])[0].strip()
    pw   = form.get("admin_pass", [""])[0]
    pw2  = form.get("admin_pass2", [""])[0]
    if not re.match(r"^[A-Za-z0-9._-]{2,32}$", user):
        return "Usuario inválido (2-32 chars, alfanuméricos)."
    if len(pw) < 8:
        return "La contraseña del admin debe tener al menos 8 caracteres."
    if pw != pw2:
        return "Las contraseñas no coinciden."

    wifi_pass = form.get("wifi_pass", [""])[0]
    if wifi_pass and not (8 <= len(wifi_pass) <= 63):
        return "Pass WiFi inválida (8-63 chars). Déjala vacía para no cambiarla."

    save_credentials(user, pw)
    mark_onboarded()

    ssid = form.get("ssid", [""])[0].strip()
    if update_hostapd(ssid, wifi_pass):
        defer_restart("hostapd", 3)
    return None

def render_wizard_done(wifi_changed):
    extra = ""
    if wifi_changed:
        extra = "<p>Has cambiado la WiFi: tu móvil tendrá que reconectarse al SSID nuevo dentro de unos segundos.</p>"
    return f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>onion-pi · listo</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>{CSS}</style></head><body><div class="container">
<h1>Configuración guardada</h1>
<div class="card"><p>Ya puedes acceder al panel con las credenciales que acabas de establecer.</p>
{extra}
<p><a href="/" style="color:#9e7cff">Ir al panel →</a> (te pedirá usuario/pass)</p></div>
</div></body></html>"""

# ── HTTP server ──────────────────────────────────────────────────────
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # silenciar log estándar — usar journal vía systemd
        pass

    def _auth(self):
        # Durante el onboarding (sin credenciales) permitimos las rutas
        # del wizard sin auth; el resto redirige a /setup.
        path = urlparse(self.path).path
        if not is_onboarded():
            if path in ("/setup", "/api/setup", "/setup/"):
                return True
            self.send_response(303)
            self.send_header("Location", "/setup")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        creds = load_creds()
        expected = base64.b64encode(
            f"{creds.get('user','admin')}:{creds.get('pass','')}".encode()).decode()
        got = self.headers.get("Authorization", "")
        if got != f"Basic {expected}":
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="onion-pi"')
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"401 Unauthorized")
            return False
        return True

    def _html(self, body, status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, where, flash=None):
        # Renderizamos directamente con el flash en lugar de un redirect 303,
        # así no perdemos el mensaje al recargar.
        self._html(render(flash=flash))

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._auth(): return
        p = urlparse(self.path).path
        if p in ("/setup", "/setup/"):
            self._html(render_wizard())
        elif not is_onboarded():
            # cualquier otra ruta durante onboarding va al wizard
            self._html(render_wizard())
        elif p in ("/", "/index.html"):
            self._html(render())
        elif p == "/api/status":
            self._json({
                "ssid": read_hostapd().get("ssid",""),
                "bootstrap": tor_bootstrap(),
                "clients": clients(),
                "public_ip": tor_public_ip(),
                "needs_reboot": needs_reboot(),
            })
        elif p == "/api/ota/status":
            st = ota_state()
            st["needs_reboot"] = st.get("needs_reboot", False) or needs_reboot()
            self._json(st)
        elif p == "/api/watchdog/status":
            self._json(watchdog_state())
        else:
            self.send_error(404)

    def do_POST(self):
        if not self._auth(): return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "ignore")
        form = parse_qs(body, keep_blank_values=True)
        p = urlparse(self.path).path
        if p == "/api/setup":
            err = handle_setup(form)
            if err:
                self._html(render_wizard(error=err))
            else:
                wifi_changed = bool(form.get("wifi_pass", [""])[0])
                self._html(render_wizard_done(wifi_changed))
            return
        # Resto requiere onboarding completo
        if not is_onboarded():
            self._html(render_wizard(error="Completa primero el onboarding."))
            return
        if p == "/wifi":
            ssid = form.get("ssid", [""])[0]
            pw   = form.get("password", [""])[0]
            if pw and not (8 <= len(pw) <= 63):
                return self._redirect("/", "Pass WPA inválida (8-63 chars).")
            changed = update_hostapd(ssid, pw)
            if changed:
                defer_restart("hostapd", 3)
                self._redirect("/", "WiFi actualizada. hostapd se reinicia en 3s.")
            else:
                self._redirect("/", "Sin cambios.")
        elif p == "/bridges":
            text = form.get("bridges", [""])[0]
            update_bridges(text)
            defer_restart("tor@default", 3)
            self._redirect("/", "Bridges guardados. Tor se reinicia en 3s.")
        elif p == "/api/ota/start":
            # Inicializar state file y lanzar OTA en background
            try:
                with open(OTA_STATE_FILE, "w") as f:
                    json.dump({
                        "state": "running",
                        "message": "Lanzando OTA…",
                        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "finished_at": None,
                        "needs_reboot": False,
                    }, f)
            except Exception:
                pass
            subprocess.Popen(["systemd-run", "--unit=onion-pi-ota-manual",
                              "--collect", OTA_SCRIPT])
            self._json({"ok": True})
        elif p == "/api/watchdog/run":
            # Forzar ejecución del watchdog ahora (igual que el timer)
            subprocess.Popen(["systemd-run", "--unit=onion-pi-watchdog-manual",
                              "--collect", WATCHDOG_SCRIPT])
            self._json({"ok": True})
        elif p == "/api/bridges/auto-fetch":
            # Lanzar bridge-rescue manualmente (Moat + bundled, rotación)
            subprocess.Popen(["systemd-run", "--unit=onion-pi-bridge-rescue-manual",
                              "--collect", "/usr/local/sbin/onion-pi-bridge-rescue.sh"])
            self._json({"ok": True})
        elif p == "/reboot" or p == "/api/reboot":
            defer_restart_reboot()
            if p == "/api/reboot":
                self._json({"ok": True, "rebooting": True})
            else:
                self._html("<h1>Reiniciando Pi…</h1>")
        else:
            self.send_error(404)

def defer_restart_reboot():
    subprocess.Popen(["systemd-run", "--on-active=3s", "systemctl", "reboot"])

def main():
    host = os.environ.get("GATEWAY_IP", "10.10.10.1")
    port = int(os.environ.get("WEBUI_PORT", "80"))
    srv = ThreadingHTTPServer((host, port), H)
    print(f"onion-pi-webui escuchando en http://{host}:{port}", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
PYEOF
  chmod 755 /usr/local/lib/onion-pi-webui/app.py

  # ── Systemd unit ────────────────────────────────────────────────────
  cat > /etc/systemd/system/onion-pi-webui.service <<EOF
[Unit]
Description=onion-pi web UI (status + config)
After=network-online.target onion-pi-wlan.service hostapd.service
Wants=network-online.target

[Service]
Type=simple
Environment=GATEWAY_IP=$GATEWAY_IP
Environment=WEBUI_PORT=$WEBUI_PORT
# Atado a la IP del gateway: solo escucha en la red del AP.
# Corre como root porque reescribe /etc/hostapd/hostapd.conf y /etc/tor/torrc
# y reinicia servicios. La autenticación HTTP Basic protege el endpoint.
ExecStart=/usr/bin/python3 /usr/local/lib/onion-pi-webui/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Web UI configurada en http://$GATEWAY_IP:$WEBUI_PORT"
}

# ============================================================================
# OTA — git pull && setup.sh contra OTA_BRANCH, semanal vía systemd timer
# ============================================================================
configure_ota() {
  [[ "$ENABLE_OTA" != "1" ]] && { warn "OTA deshabilitado (ENABLE_OTA=0)"; return 0; }
  header "Configurando OTA updates (rama $OTA_BRANCH)"

  local repo_dir="$(dirname "$(readlink -f "$0")")"

  if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    warn "$repo_dir no es un repo git — omito OTA (clona el repo si quieres OTA)"
    return 0
  fi

  command -v git >/dev/null || apt-get install -y -qq git

  # Si el repo es de otro user (típico: madison cloneó, root ejecuta OTA),
  # git rechaza con 'dubious ownership'. Lo marcamos como seguro para root.
  git config --global --add safe.directory "$repo_dir" 2>/dev/null || true

  cat > /usr/local/sbin/onion-pi-ota-update.sh <<EOF
#!/usr/bin/env bash
# Actualiza onion-pi desde git y re-ejecuta setup.sh idempotente.
# Lanzado manualmente desde la web UI, desde el CLI 'onion-pi-update',
# o automáticamente por el timer semanal.
#
# Escribe el estado del proceso a /run/onion-pi-ota-state.json para que la
# web UI pueda mostrarlo en tiempo real (estado=running/success/error/needs_reboot).
set -uo pipefail
REPO_DIR="$repo_dir"
BRANCH="$OTA_BRANCH"
STATE="$OTA_STATE_FILE"
NEEDS_REBOOT_FLAG="/run/onion-pi-needs-reboot"
STARTED_AT=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_state() {
  local s="\$1" msg="\$2" finished="\${3:-null}" before="\${4:-}" after="\${5:-}" nr="\${6:-false}"
  python3 - "\$s" "\$msg" "\$finished" "\$before" "\$after" "\$nr" "\$STARTED_AT" <<'PY' > "\$STATE.tmp" || true
import json, sys
s, msg, fin, before, after, nr, started = sys.argv[1:8]
json.dump({
  "state": s, "message": msg,
  "started_at": started,
  "finished_at": None if fin == "null" else fin,
  "before": before or None, "after": after or None,
  "needs_reboot": nr == "true",
}, sys.stdout)
PY
  mv -f "\$STATE.tmp" "\$STATE" 2>/dev/null || true
}

fail() {
  write_state error "\$1" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[ota] ERROR: \$1" >&2
  exit 1
}
trap 'fail "Fallo inesperado (línea \$LINENO)"' ERR

write_state running "Comprobando cambios en origin/\$BRANCH..."
cd "\$REPO_DIR" || fail "REPO_DIR no existe (\$REPO_DIR)"

# git como root sobre un repo de otro user requiere safe.directory inline:
# systemd-run no hereda HOME=/root, así que el global gitconfig se ignora.
GIT="git -c safe.directory=\$REPO_DIR"

\$GIT fetch origin "\$BRANCH" --quiet || fail "git fetch falló"
LOCAL=\$(\$GIT rev-parse HEAD)
REMOTE=\$(\$GIT rev-parse "origin/\$BRANCH")
if [[ "\$LOCAL" == "\$REMOTE" ]]; then
  write_state success "Ya estás en la última versión (\${LOCAL:0:8})." "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$LOCAL" "\$REMOTE"
  echo "[ota] al día: \$LOCAL"
  exit 0
fi

echo "[ota] actualización disponible: \$LOCAL → \$REMOTE"
write_state running "Descargando cambios (\${LOCAL:0:8} → \${REMOTE:0:8})..."

# stash de cambios locales para no romper bridges.txt si el user lo editó
\$GIT stash push -u -m "onion-pi-ota pre-update \$(date -Iseconds)" --quiet || true
if ! \$GIT merge --ff-only "origin/\$BRANCH" --quiet; then
  \$GIT stash pop --quiet 2>/dev/null || true
  fail "No se puede hacer fast-forward (hay divergencia con la rama remota)"
fi
\$GIT stash pop --quiet 2>/dev/null || true
chmod +x setup.sh healthcheck.sh 2>/dev/null || true

write_state running "Aplicando configuración nueva (setup.sh)..."
if ! ./setup.sh >> /var/log/onion-pi-ota.log 2>&1; then
  fail "setup.sh falló — revisa /var/log/onion-pi-ota.log"
fi

# Detectar si hace falta reboot
NEEDS_REBOOT=false
if [[ -f /var/run/reboot-required ]]; then
  NEEDS_REBOOT=true
  : >> "\$NEEDS_REBOOT_FLAG"
fi
# Heurística adicional: si el kernel o brcmfmac han sido tocados, mejor reboot.
if dpkg-query -W -f='\${Package} \${Status}\n' linux-image-\\* firmware-brcm80211 2>/dev/null | grep -q "install ok"; then
  if find /lib/modules -maxdepth 1 -type d -newer /run/onion-pi-ota-state.json 2>/dev/null | grep -q .; then
    NEEDS_REBOOT=true
    : >> "\$NEEDS_REBOOT_FLAG"
  fi
fi

NOW=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "\$NEEDS_REBOOT" == "true" ]]; then
  write_state needs_reboot "Actualización aplicada. Hace falta reiniciar para completar." "\$NOW" "\$LOCAL" "\$REMOTE" true
  echo "[ota] OK pero requiere reboot (\$REMOTE)"
else
  write_state success "Actualización aplicada correctamente (\${REMOTE:0:8})." "\$NOW" "\$LOCAL" "\$REMOTE" false
  echo "[ota] OK · \$REMOTE"
fi
EOF
  chmod 755 /usr/local/sbin/onion-pi-ota-update.sh

  # CLI amigable: 'onion-pi-update' (con --check para sólo comprobar)
  cat > /usr/local/bin/onion-pi-update <<'EOF'
#!/usr/bin/env bash
# Wrapper para lanzar el OTA desde shell. Útil cuando estás por SSH.
#
# Uso:
#   onion-pi-update          → tira de origin/master y reaplica config
#   onion-pi-update --check  → sólo dice si hay actualización, no la aplica
#   onion-pi-update --status → muestra el estado del último OTA
set -euo pipefail
SCRIPT=/usr/local/sbin/onion-pi-ota-update.sh
STATE=/run/onion-pi-ota-state.json

case "${1:-}" in
  --status)
    if [[ -f "$STATE" ]]; then
      python3 -c "import json,sys; s=json.load(open('$STATE')); print(f\"[{s.get('state')}] {s.get('message','')}\\nstarted: {s.get('started_at','')}\\nfinished: {s.get('finished_at') or '(en curso)'}\\nbefore: {s.get('before') or '-'}\\nafter:  {s.get('after') or '-'}\\nneeds reboot: {s.get('needs_reboot', False)}\")"
    else
      echo "Sin OTA previo."
    fi
    exit 0
    ;;
  --check)
    REPO_DIR=$(grep '^REPO_DIR=' "$SCRIPT" | head -1 | cut -d'"' -f2)
    BRANCH=$(grep '^BRANCH=' "$SCRIPT" | head -1 | cut -d'"' -f2)
    cd "$REPO_DIR"
    git fetch origin "$BRANCH" --quiet
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/$BRANCH")
    if [[ "$LOCAL" == "$REMOTE" ]]; then
      echo "Ya estás en la última versión: ${LOCAL:0:8}"
      exit 0
    fi
    echo "Hay actualización disponible:"
    echo "  local:  ${LOCAL:0:8}"
    echo "  remoto: ${REMOTE:0:8}"
    echo
    echo "Lanza 'sudo onion-pi-update' para aplicarla."
    exit 0
    ;;
  -h|--help)
    sed -n '2,8p' "$0"
    exit 0
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Necesita root. Reinvocando con sudo..."
  exec sudo "$0" "$@"
fi
exec "$SCRIPT"
EOF
  chmod 755 /usr/local/bin/onion-pi-update

  cat > /etc/systemd/system/onion-pi-ota.service <<EOF
[Unit]
Description=onion-pi OTA update
After=network-online.target tor.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/onion-pi-ota-update.sh
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/onion-pi-ota.timer <<EOF
[Unit]
Description=onion-pi OTA update timer

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  ok "OTA configurado · script /usr/local/sbin/onion-pi-ota-update.sh · timer semanal"
}

# ============================================================================
# WATCHDOG — comprueba periódicamente que DNS+SOCKS pasan por Tor.
#            Si fallan, intenta reparar reiniciando Tor. Reporta a la web UI.
# ============================================================================
configure_watchdog() {
  [[ "$ENABLE_WATCHDOG" != "1" ]] && { warn "Watchdog deshabilitado (ENABLE_WATCHDOG=0)"; return 0; }
  header "Configurando watchdog (cada ${WATCHDOG_INTERVAL_MIN} min)"

  # Necesitamos dig + curl en el path para los tests
  command -v dig  >/dev/null || apt-get install -y -qq dnsutils
  command -v curl >/dev/null || apt-get install -y -qq curl

  cat > /usr/local/sbin/onion-pi-watchdog.sh <<EOF
#!/usr/bin/env bash
# onion-pi watchdog — comprueba que un cliente conectado a este AP saldría
# realmente por Tor. Hace dos tests:
#   1) DNS al puerto Tor DNS del gateway resuelve example.com en <10s
#   2) Curl via SOCKS responde IsTor:true en <15s
# Si alguno falla, reinicia tor@default y reintenta. Si sigue fallando,
# marca el estado como 'error' (la web UI lo muestra como banner) para que
# sepas que probablemente hay bridges muertos / cambio de censura en tu ISP.
#
# Estado en $WATCHDOG_STATE_FILE para que la UI lo lea.
set -uo pipefail
STATE="$WATCHDOG_STATE_FILE"
GATEWAY_IP="$GATEWAY_IP"
TOR_DNS_PORT="$TOR_DNS_PORT"
TOR_SOCKS_PORT="$TOR_SOCKS_PORT"
LOG_TAG="onion-pi-watchdog"
TEST_DOMAIN="\${TEST_DOMAIN:-example.com}"

log() { logger -t "\$LOG_TAG" "\$*"; echo "[\$LOG_TAG] \$*"; }

count_clients() {
  # nº de stations asociadas al AP (limpio, siempre 1 número entero)
  local n
  n=\$( (hostapd_cli -i wlan0 list_sta 2>/dev/null || true) | grep -c "^[0-9a-f][0-9a-f]:")
  echo "\${n:-0}"
}

write_state() {
  python3 - "\$@" <<PY > "\$STATE.tmp" || return
import json, sys, time
state, msg, remediated, clients, dns_ok, socks_ok = sys.argv[1:7]
json.dump({
  "state": state,
  "message": msg,
  "remediated": remediated == "true",
  "last_check": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
  "active_clients": int(clients),
  "dns_ok": dns_ok == "true",
  "socks_ok": socks_ok == "true",
}, sys.stdout)
PY
  mv -f "\$STATE.tmp" "\$STATE" 2>/dev/null || true
}

dns_test() {
  local got
  got=\$(timeout 12 dig +time=10 +tries=1 +short @"\$GATEWAY_IP" -p "\$TOR_DNS_PORT" "\$TEST_DOMAIN" 2>/dev/null | head -1)
  # Aceptar A o AAAA, y solo si parece IP
  [[ "\$got" =~ ^[0-9a-fA-F:.]+\$ ]]
}

socks_test() {
  local out
  out=\$(timeout 20 curl -s --max-time 15 \\
    --socks5-hostname "\$GATEWAY_IP:\$TOR_SOCKS_PORT" \\
    https://check.torproject.org/api/ip 2>/dev/null)
  echo "\$out" | grep -q '"IsTor":true'
}

CLIENTS=\$(count_clients)

# Si no hay clientes, igual comprobamos (mantiene Tor caliente) pero marcamos.
DNS_OK=false; SOCKS_OK=false
dns_test  && DNS_OK=true
socks_test && SOCKS_OK=true

if [[ "\$DNS_OK" == "true" && "\$SOCKS_OK" == "true" ]]; then
  write_state ok "Tor enruta correctamente · DNS y SOCKS OK" false "\$CLIENTS" true true
  log "OK · clients=\$CLIENTS"
  exit 0
fi

log "FALLO inicial · dns=\$DNS_OK socks=\$SOCKS_OK · intentando recuperar"
write_state warning "Detectado fallo (dns=\$DNS_OK socks=\$SOCKS_OK), reiniciando Tor..." true "\$CLIENTS" "\$DNS_OK" "\$SOCKS_OK"

systemctl restart tor@default
# Esperar bootstrap (hasta 60s)
for _ in \$(seq 1 30); do
  sleep 2
  if grep -q "Bootstrapped 100%" /var/log/tor/notices.log 2>/dev/null; then
    break
  fi
done
sleep 3  # asegurar que listeners están listos

DNS_OK=false; SOCKS_OK=false
dns_test  && DNS_OK=true
socks_test && SOCKS_OK=true

if [[ "\$DNS_OK" == "true" && "\$SOCKS_OK" == "true" ]]; then
  write_state ok "Reparado tras reinicio de Tor" true "\$CLIENTS" true true
  log "RECUPERADO · clients=\$CLIENTS"
  exit 0
fi

# Reinicio no fue suficiente: rotamos bridges desde el pool público
if [[ -x /usr/local/sbin/onion-pi-bridge-rescue.sh ]]; then
  log "Restart no arregló, lanzando bridge-rescue (rotación a bridges públicos)"
  write_state warning "Restart no arregló — buscando bridges nuevos del pool público..." true "\$CLIENTS" "\$DNS_OK" "\$SOCKS_OK"
  /usr/local/sbin/onion-pi-bridge-rescue.sh || true
  # Esperar bootstrap tras restart del rescue
  for _ in \$(seq 1 30); do
    sleep 2
    if grep -q "Bootstrapped 100%" /var/log/tor/notices.log 2>/dev/null; then
      break
    fi
  done
  sleep 3
  DNS_OK=false; SOCKS_OK=false
  dns_test  && DNS_OK=true
  socks_test && SOCKS_OK=true
  if [[ "\$DNS_OK" == "true" && "\$SOCKS_OK" == "true" ]]; then
    write_state ok "Reparado rotando a bridges públicos" true "\$CLIENTS" true true
    log "RECUPERADO via bridge-rescue · clients=\$CLIENTS"
    exit 0
  fi
fi

# Aún falla — probablemente Moat no responde + bundled también filtrados
write_state error "Sin recuperación automática posible. Pega bridges privados en la UI (saca nuevos en https://bridges.torproject.org/)." true "\$CLIENTS" "\$DNS_OK" "\$SOCKS_OK"
log "FALLO PERSISTENTE tras bridge-rescue · clients=\$CLIENTS · dns=\$DNS_OK socks=\$SOCKS_OK"
exit 1
EOF
  chmod 755 /usr/local/sbin/onion-pi-watchdog.sh

  cat > /etc/systemd/system/onion-pi-watchdog.service <<EOF
[Unit]
Description=onion-pi connectivity watchdog
After=network-online.target tor.service onion-pi-wlan.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=GATEWAY_IP=$GATEWAY_IP
Environment=TOR_DNS_PORT=$TOR_DNS_PORT
Environment=TOR_SOCKS_PORT=$TOR_SOCKS_PORT
ExecStart=/usr/local/sbin/onion-pi-watchdog.sh
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/onion-pi-watchdog.timer <<EOF
[Unit]
Description=onion-pi watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=${WATCHDOG_INTERVAL_MIN}min
RandomizedDelaySec=30s
Persistent=false

[Install]
WantedBy=timers.target
EOF

  # Estado inicial idle para que la UI lo enseñe desde el primer momento
  if [[ ! -f "$WATCHDOG_STATE_FILE" ]]; then
    install -d -m 755 /run 2>/dev/null || true
    echo '{"state":"idle","message":"Watchdog aún no ha corrido","active_clients":0}' > "$WATCHDOG_STATE_FILE" 2>/dev/null || true
  fi

  systemctl daemon-reload
  ok "Watchdog configurado · cada ${WATCHDOG_INTERVAL_MIN} min · journalctl -u onion-pi-watchdog"
}

# ============================================================================
# BRIDGE RESCUE — cuando Tor no enruta y reinicio no arregla, intentamos
# rotar a bridges públicos frescos (Moat API + lista bundled).
# ============================================================================
configure_bridge_rescue() {
  [[ "$ENABLE_BRIDGE_RESCUE" != "1" ]] && { warn "Bridge rescue deshabilitado"; return 0; }
  header "Instalando bridge rescue"

  # Copiar la lista bundled del repo al sistema (path estable)
  install -d -m 755 "$(dirname "$BUNDLED_BRIDGES_DST")"
  local src="$(dirname "$(readlink -f "$0")")/bridges_default.txt"
  if [[ -f "$src" ]]; then
    install -m 644 "$src" "$BUNDLED_BRIDGES_DST"
    log "Bundled bridges → $BUNDLED_BRIDGES_DST ($(grep -c '^obfs4' "$BUNDLED_BRIDGES_DST") candidatos)"
  else
    warn "$src no encontrado — bridge rescue solo podrá tirar de Moat"
    : > "$BUNDLED_BRIDGES_DST"
  fi

  cat > /usr/local/sbin/onion-pi-bridge-rescue.sh <<EOF
#!/usr/bin/env bash
# onion-pi bridge rescue — cuando los bridges actuales no funcionan, rota a
# bridges públicos. Fuente prioridad:
#   1. Moat builtin API (https://bridges.torproject.org/moat/circumvention/builtin)
#   2. /etc/onion-pi/bridges_default.txt (lista bundled refrescable vía OTA)
#   3. Bridges actuales en /etc/tor/torrc (por si alguno resucitó)
# Para cada candidato, TCP connect con timeout 3s. Toma los primeros N alive,
# reescribe el bloque Bridge obfs4 de torrc y reinicia Tor.
set -uo pipefail
TORRC=/etc/tor/torrc
BUNDLED="$BUNDLED_BRIDGES_DST"
LOG=$BRIDGE_RESCUE_LOG
KEEP=$BRIDGE_RESCUE_KEEP_N
LOG_TAG=onion-pi-bridge-rescue

log() {
  local m="\$*"
  echo "[\$(date +'%F %T')] \$m" >> "\$LOG"
  logger -t "\$LOG_TAG" "\$m"
  echo "[\$LOG_TAG] \$m"
}

# Fetch del Moat builtin API. No requiere captcha, devuelve los obfs4 que
# Tor Browser shipea (~10-15 bridges, rotados por Tor Project).
fetch_moat() {
  local url="https://bridges.torproject.org/moat/circumvention/builtin"
  curl -sS --max-time 15 \\
    -H "Content-Type: application/vnd.api+json" \\
    -X POST -d '{}' \\
    "\$url" 2>/dev/null | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
  for b in d.get('bridges', {}).get('obfs4', []):
    print(b.strip())
except Exception:
  sys.exit(1)
"
}

current_torrc_bridges() {
  grep -E '^Bridge[[:space:]]+obfs4' "\$TORRC" 2>/dev/null | sed 's/^Bridge[[:space:]]\\+//'
}

bundled_bridges() {
  [[ -f "\$BUNDLED" ]] && grep -E '^obfs4' "\$BUNDLED" 2>/dev/null
}

# Devuelve "host:port" de una línea de bridge
parse_hostport() {
  local line="\$1"
  echo "\$line" | awk '{
    for (i=1; i<=NF; i++)
      if (\$i ~ /^[0-9.]+:[0-9]+\$/ || \$i ~ /^\\[[^]]+\\]:[0-9]+\$/) { print \$i; exit }
  }'
}

test_tcp() {
  local hp="\$1"
  local host="\${hp%:*}"
  local port="\${hp##*:}"
  # quitar brackets ipv6 si los hay
  host="\${host#[}"
  host="\${host%]}"
  timeout 3 bash -c "</dev/tcp/\$host/\$port" 2>/dev/null
}

log "Iniciando bridge rescue (target=\$KEEP alive)"

POOL=\$(mktemp)
trap 'rm -f "\$POOL"' EXIT

# 1) Moat fresh
log "Pidiendo bridges al Moat builtin..."
if MOAT_OUT=\$(fetch_moat); then
  echo "\$MOAT_OUT" | grep -E '^obfs4' >> "\$POOL"
  log "Moat respondió con \$(echo "\$MOAT_OUT" | grep -c '^obfs4') bridges"
else
  log "Moat no disponible (probablemente sin internet o ISP filtrando)"
fi

# 2) Bundled
bundled_bridges >> "\$POOL"

# 3) Actuales del torrc (por si alguno se ha recuperado)
current_torrc_bridges >> "\$POOL"

# Dedup
sort -u -o "\$POOL" "\$POOL"
TOTAL=\$(wc -l < "\$POOL")
log "Pool total: \$TOTAL candidatos"

if [[ \$TOTAL -eq 0 ]]; then
  log "Sin candidatos — abortando"
  exit 1
fi

# Probar
ALIVE=()
while IFS= read -r line; do
  [[ -z "\$line" ]] && continue
  HP=\$(parse_hostport "\$line")
  [[ -z "\$HP" ]] && continue
  if test_tcp "\$HP"; then
    log "alive: \$HP"
    ALIVE+=("\$line")
    [[ \${#ALIVE[@]} -ge \$KEEP ]] && break
  else
    log "down:  \$HP"
  fi
done < "\$POOL"

if [[ \${#ALIVE[@]} -eq 0 ]]; then
  log "Ningún candidato responde TCP — abortando"
  exit 1
fi

log "Aplicando \${#ALIVE[@]} bridges nuevos a torrc"
# Reescribir torrc preservando todo lo que NO sea 'Bridge obfs4 ...'
TMP=\$(mktemp)
{
  inserted=0
  while IFS= read -r line; do
    if [[ "\$line" =~ ^Bridge[[:space:]]+obfs4 ]]; then
      if [[ \$inserted -eq 0 ]]; then
        for b in "\${ALIVE[@]}"; do
          if [[ "\$b" =~ ^Bridge[[:space:]] ]]; then echo "\$b"; else echo "Bridge \$b"; fi
        done
        inserted=1
      fi
      continue
    fi
    echo "\$line"
  done < "\$TORRC"
  if [[ \$inserted -eq 0 ]]; then
    echo ""
    echo "# bridges auto-rescue \$(date -Iseconds)"
    for b in "\${ALIVE[@]}"; do
      if [[ "\$b" =~ ^Bridge[[:space:]] ]]; then echo "\$b"; else echo "Bridge \$b"; fi
    done
  fi
} > "\$TMP"
install -m 644 -o root -g root "\$TMP" "\$TORRC"
rm -f "\$TMP"

log "Reiniciando tor@default"
systemctl restart tor@default
log "Done"
EOF
  chmod 755 /usr/local/sbin/onion-pi-bridge-rescue.sh

  # CLI amigable en PATH
  cat > /usr/local/bin/onion-pi-rescue-bridges <<'EOF'
#!/usr/bin/env bash
# Wrapper para rotar bridges públicos a demanda. Útil cuando ves que Tor
# no enruta y no quieres esperar al timer del watchdog.
if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi
exec /usr/local/sbin/onion-pi-bridge-rescue.sh "$@"
EOF
  chmod 755 /usr/local/bin/onion-pi-rescue-bridges

  : > "$BRIDGE_RESCUE_LOG" 2>/dev/null || true
  chmod 644 "$BRIDGE_RESCUE_LOG" 2>/dev/null || true

  ok "Bridge rescue listo · CLI 'onion-pi-rescue-bridges' · pool $BUNDLED_BRIDGES_DST"
}

# ============================================================================
# HEALTHCHECK — servicio que se ejecuta en cada arranque
# ============================================================================
install_healthcheck() {
  header "Instalando healthcheck de arranque"

  local script_src="$(dirname "$(readlink -f "$0")")/healthcheck.sh"
  local script_dst="/usr/local/sbin/onion-pi-healthcheck.sh"

  if [[ ! -f "$script_src" ]]; then
    warn "No se encontró healthcheck.sh junto a setup.sh — omito"
    return 0
  fi

  install -m 755 "$script_src" "$script_dst"

  cat > /etc/systemd/system/onion-pi-healthcheck.service <<EOF
[Unit]
Description=onion-pi boot healthcheck (verifica AP+Tor+nftables)
After=network-online.target tor.service hostapd.service dnsmasq.service nftables.service onion-pi-wlan.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
Environment=WIFI_IFACE=$WIFI_IFACE
Environment=GATEWAY_IP=$GATEWAY_IP
Environment=SUBNET_MASK_BITS=$SUBNET_MASK_BITS
Environment=TOR_TRANS_PORT=$TOR_TRANS_PORT
ExecStartPre=/bin/sleep 5
ExecStart=$script_dst
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable onion-pi-healthcheck.service >/dev/null 2>&1
  ok "onion-pi-healthcheck.service instalado y habilitado"
}

# ============================================================================
# ARRANQUE DE SERVICIOS
# ============================================================================
start_services() {
  header "Habilitando y arrancando servicios"

  systemctl enable nftables onion-pi-wlan.service hostapd dnsmasq tor >/dev/null 2>&1
  [[ "$ENABLE_FWKNOP" == "1" ]] && systemctl enable fwknop-server >/dev/null 2>&1 || true
  [[ "$ENABLE_WEBUI"  == "1" ]] && systemctl enable onion-pi-webui.service >/dev/null 2>&1 || true
  [[ "$ENABLE_OTA"    == "1" && -f /etc/systemd/system/onion-pi-ota.timer ]] && \
      systemctl enable onion-pi-ota.timer >/dev/null 2>&1 || true
  [[ "$ENABLE_WATCHDOG" == "1" && -f /etc/systemd/system/onion-pi-watchdog.timer ]] && \
      systemctl enable onion-pi-watchdog.timer >/dev/null 2>&1 || true

  systemctl restart onion-pi-wlan.service
  systemctl restart nftables
  systemctl restart hostapd
  systemctl restart dnsmasq
  systemctl restart tor
  [[ "$ENABLE_FWKNOP" == "1" ]] && systemctl restart fwknop-server 2>/dev/null || true
  [[ "$ENABLE_WEBUI"  == "1" ]] && systemctl restart onion-pi-webui.service 2>/dev/null || true
  [[ "$ENABLE_OTA"    == "1" && -f /etc/systemd/system/onion-pi-ota.timer ]] && \
      systemctl restart onion-pi-ota.timer 2>/dev/null || true
  [[ "$ENABLE_WATCHDOG" == "1" && -f /etc/systemd/system/onion-pi-watchdog.timer ]] && \
      systemctl restart onion-pi-watchdog.timer 2>/dev/null || true

  ok "Servicios en marcha"
}

# ============================================================================
# VERIFICACIÓN
# ============================================================================
verify() {
  header "Verificación"
  sleep 3

  local failed=0
  local svcs=(nftables onion-pi-wlan hostapd dnsmasq tor)
  [[ "$ENABLE_WEBUI" == "1" ]] && svcs+=(onion-pi-webui)
  for svc in "${svcs[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      ok "$svc activo"
    else
      err "$svc NO activo (journalctl -u $svc)"
      failed=1
    fi
  done

  if ip -4 addr show "$WIFI_IFACE" | grep -q "$GATEWAY_IP"; then
    ok "$WIFI_IFACE tiene IP $GATEWAY_IP"
  else
    err "$WIFI_IFACE NO tiene IP $GATEWAY_IP"; failed=1
  fi

  if ss -tlnp | grep -q ":$TOR_TRANS_PORT.*tor"; then
    ok "Tor escuchando en :$TOR_TRANS_PORT"
  else
    warn "Tor aún no escucha en :$TOR_TRANS_PORT (puede tardar 30-60s)"
  fi

  log "Monitorizando bootstrap de Tor (60s máx)..."
  local boot_ok=0
  for _ in $(seq 1 60); do
    if grep -q "Bootstrapped 100%" /var/log/tor/notices.log 2>/dev/null; then
      ok "Tor bootstrapped al 100%"
      boot_ok=1
      break
    fi
    sleep 1
  done
  if (( boot_ok == 0 )); then
    warn "Tor no llegó al 100% en 60s. Sigue con:"
    warn "  journalctl -u tor -f"
    warn "  tail -f /var/log/tor/notices.log"
    warn "Si se queda atascado, prueba con otros bridges o snowflake."
  fi

  return $failed
}

# ============================================================================
# RESUMEN FINAL
# ============================================================================
summary() {
  header "Listo"
  cat <<EOF

  ${BLD}Red WiFi creada${RST}
    SSID:        $SSID
    Password:    (la que pasaste en WIFI_PASS)
    Gateway:     $GATEWAY_IP/$SUBNET_MASK_BITS
    DHCP:        $DHCP_START — $DHCP_END

  ${BLD}Prueba${RST}
    Conecta un móvil al SSID y abre:
      https://check.torproject.org
      https://ipleak.net

  ${BLD}Logs${RST}
    journalctl -u tor -f
    journalctl -u hostapd -f
    tail -f /var/log/tor/notices.log

  ${BLD}Backup de configs previas${RST}
    $BACKUP_DIR

EOF
  if [[ "$ENABLE_FWKNOP" == "1" && -f "$KEYS_OUT" ]]; then
    cat <<EOF
  ${BLD}fwknop SPA${RST}
    Claves cliente:  $KEYS_OUT
    Ver instrucciones de conexión en ese archivo.

EOF
  fi
  if [[ "$ENABLE_WEBUI" == "1" ]]; then
    if [[ -f "$WEBUI_INITIALIZED_FLAG" ]]; then
      cat <<EOF
  ${BLD}Web UI${RST}
    URL:        http://$GATEWAY_IP:$WEBUI_PORT (desde un cliente del AP)
    Credenciales: las que estableciste en el wizard de onboarding
    Reset wizard: sudo rm $WEBUI_INITIALIZED_FLAG $WEBUI_PASSWD_FILE
                  sudo systemctl restart onion-pi-webui

EOF
    else
      cat <<EOF
  ${BLD}Onboarding pendiente${RST}
    Conecta un cliente al AP (SSID: $SSID) y abre:
      http://$GATEWAY_IP:$WEBUI_PORT
    El wizard te pedirá usuario/contraseña de admin del panel.

EOF
    fi
  fi
  if [[ "$ENABLE_OTA" == "1" && -f /usr/local/sbin/onion-pi-ota-update.sh ]]; then
    cat <<EOF
  ${BLD}OTA${RST}
    CLI:        sudo onion-pi-update           (aplica si hay update)
                onion-pi-update --check        (sólo comprueba)
                onion-pi-update --status       (estado del último OTA)
    Web UI:     botón "Comprobar OTA ahora" con progreso en vivo
    Timer:      systemctl list-timers onion-pi-ota.timer
    Logs:       journalctl -u onion-pi-ota.service · /var/log/onion-pi-ota.log

EOF
  fi
  if [[ "$ENABLE_WATCHDOG" == "1" && -f /usr/local/sbin/onion-pi-watchdog.sh ]]; then
    cat <<EOF
  ${BLD}Watchdog${RST}
    Cada ${WATCHDOG_INTERVAL_MIN} min comprueba que Tor enruta DNS+SOCKS correctamente.
    Si falla, reinicia Tor. Si tras restart sigue fallando, lo marca en la UI.
    Manual:     sudo /usr/local/sbin/onion-pi-watchdog.sh
    Timer:      systemctl list-timers onion-pi-watchdog.timer
    Logs:       journalctl -u onion-pi-watchdog.service · journalctl -t onion-pi-watchdog

EOF
  fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  preflight
  backup_files
  install_packages
  configure_nm_unmanaged
  configure_static_ip
  configure_hostapd
  configure_dnsmasq
  configure_tor
  configure_nftables
  configure_fwknop
  configure_webui
  configure_ota
  configure_watchdog
  configure_bridge_rescue
  install_healthcheck
  start_services
  verify || warn "Verificación con incidencias — revisa los logs"
  date > "$STATE_FILE"
  summary
}

main "$@"

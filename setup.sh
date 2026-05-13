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

BACKUP_DIR="/etc/onion-pi-backup-$(date +%Y%m%d-%H%M%S)"
KEYS_OUT="/root/onion-pi-fwknop-keys.txt"
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
  cat > /etc/hostapd/hostapd.conf <<EOF
# Generado por onion-pi setup
interface=$WIFI_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$WIFI_CHANNEL
country_code=$WIFI_COUNTRY
ieee80211d=1
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$WIFI_PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
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
      grep -E '^Bridge ' "$BRIDGES_FILE" || true
    fi

    if [[ "$ENABLE_SNOWFLAKE" == "1" ]]; then
      cat <<'EOF'

# Snowflake (público — actualiza desde bridges.torproject.org si deja de funcionar)
Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net.global.prod.fastly.net/ fronts=foursquare.com,github.githubassets.com ice=stun:stun.l.google.com:19302 utls-imitate=hellorandomizedalpn
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

        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded, parameter-problem } accept limit rate 10/second
        ip6 nexthdr icmpv6 accept limit rate 10/second

        iifname "$WAN_IFACE" jump wan_in
        iifname "$WIFI_IFACE" jump lan_in
    }

    chain wan_in {
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
        iifname "$WIFI_IFACE" meta l4proto tcp redirect to :$TOR_TRANS_PORT
        iifname "$WIFI_IFACE" udp dport 53 redirect to :$TOR_DNS_PORT
        iifname "$WIFI_IFACE" tcp dport 53 redirect to :$TOR_DNS_PORT
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

  systemctl restart onion-pi-wlan.service
  systemctl restart nftables
  systemctl restart hostapd
  systemctl restart dnsmasq
  systemctl restart tor
  [[ "$ENABLE_FWKNOP" == "1" ]] && systemctl restart fwknop-server 2>/dev/null || true

  ok "Servicios en marcha"
}

# ============================================================================
# VERIFICACIÓN
# ============================================================================
verify() {
  header "Verificación"
  sleep 3

  local failed=0
  for svc in nftables onion-pi-wlan hostapd dnsmasq tor; do
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
  install_healthcheck
  start_services
  verify || warn "Verificación con incidencias — revisa los logs"
  date > "$STATE_FILE"
  summary
}

main "$@"

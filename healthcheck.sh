#!/usr/bin/env bash
#
# onion-pi healthcheck
# ─────────────────────────────────────────────────────────────────────────────
# Se ejecuta en cada arranque (via onion-pi-healthcheck.service).
# Verifica que los componentes críticos están vivos y, si algo falla,
# intenta repararlo de forma idempotente:
#   - Reaplica /etc/nftables.conf si la tabla 'inet filter' no existe
#   - Reinicia servicios caídos
#   - Reasigna la IP estática en wlan0 si falta
#
# NO reinstala paquetes ni reescribe configs. Para eso está setup.sh.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
GATEWAY_IP="${GATEWAY_IP:-10.10.10.1}"
SUBNET_MASK_BITS="${SUBNET_MASK_BITS:-24}"

LOG_TAG="onion-pi-healthcheck"
log() { logger -t "$LOG_TAG" "$*"; echo "[hc] $*"; }

log "Inicio del healthcheck"

# ── 1. IP estática en wlan0 ─────────────────────────────────────────────────
if ! ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q "$GATEWAY_IP"; then
    log "Falta IP $GATEWAY_IP en $WIFI_IFACE → reaplicando onion-pi-wlan"
    systemctl restart onion-pi-wlan.service || log "ERROR: no pude reiniciar onion-pi-wlan"
fi

# ── 2. nftables cargado ─────────────────────────────────────────────────────
if ! nft list table inet filter >/dev/null 2>&1; then
    log "Tabla 'inet filter' ausente → recargando /etc/nftables.conf"
    nft -f /etc/nftables.conf || log "ERROR: nft -f falló"
fi

# ── 3. Servicios críticos ───────────────────────────────────────────────────
for svc in nftables onion-pi-wlan hostapd dnsmasq tor; do
    if ! systemctl is-active --quiet "$svc"; then
        log "$svc inactivo → restart"
        systemctl restart "$svc" || log "ERROR: no pude reiniciar $svc"
    fi
done

# fwknop es opcional
if systemctl list-unit-files fwknop-server.service >/dev/null 2>&1; then
    if ! systemctl is-active --quiet fwknop-server; then
        log "fwknop-server inactivo → restart"
        systemctl restart fwknop-server 2>/dev/null || true
    fi
fi

# ── 4. Tor TransPort escuchando ─────────────────────────────────────────────
TOR_TRANS_PORT="${TOR_TRANS_PORT:-9040}"
if ! ss -tlnp 2>/dev/null | grep -q ":$TOR_TRANS_PORT.*tor"; then
    log "Tor no escucha en :$TOR_TRANS_PORT todavía (puede tardar tras boot)"
fi

log "Healthcheck completo"
exit 0

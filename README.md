# onion-pi

Una Raspberry Pi 4 convertida en un punto de acceso WiFi que mete todo el tráfico de los dispositivos conectados por Tor, sin tocar el router del ISP.

La idea es sencilla: conectas la Pi al router por cable (eth0), la Pi emite su propia red WiFi (wlan0), y cualquier dispositivo que se conecte a esa WiFi sale a internet por Tor. Si Tor se cae, no hay internet, no hay fugas. Eso es lo que llamo "kill-switch implícito": como no hay forwarding en el kernel, lo único que sale al WAN son las conexiones que abre el propio proceso `tor`.

No es un proyecto para "ser anónimo en internet" sin más. Es un proyecto para tener un AP separado en casa donde el tráfico va por Tor por defecto, sin tener que configurar nada en cada dispositivo. Si lo que quieres es anonimato fuerte, usa Tails o Whonix.

## Qué monta exactamente

- `hostapd` levantando un AP WPA2 en `wlan0`
- `dnsmasq` haciendo solo DHCP (el puerto DNS está apagado a propósito)
- `tor` con `TransPort` y `DNSPort` escuchando en la IP del gateway, con bridges obfs4 desde `bridges.txt` y snowflake como respaldo
- `nftables` redirigiendo todo el TCP de los clientes al `TransPort` y todo el DNS al `DNSPort` de Tor; el resto, drop
- `fwknop` (opcional) haciendo port-knocking SPA en `eth0` para que SSH desde fuera esté cerrado hasta que mandes un paquete autenticado
- Un `healthcheck.sh` que corre en cada arranque y reintenta lo que se haya caído

`ip_forward` está deliberadamente a 0. Tor escucha local, los clientes hablan al puerto del gateway, y nftables los redirige. No hace falta NAT.

## Lo que necesitas

- Una Raspberry Pi 4 o 5 con Raspberry Pi OS Lite (Bookworm), instalado limpio
- Cable ethernet al router (eth0 → WAN)
- WiFi interna libre (wlan0 → AP)
- Acceso root

Probado en Pi 4 y Pi 5 con Bookworm. En otras distros Debian-like debería funcionar pero no lo garantizo.

## Instalación

Clona el repo en la Pi y, si vas a usar bridges obfs4 (recomendado), saca unos cuantos en https://bridges.torproject.org/ con transport obfs4 y pégalos en `bridges.txt`. Hay un `bridges.txt.example` con las instrucciones.

Luego:

```
sudo WIFI_PASS='unaPasswordWPA2DeVerdad' ./setup.sh
```

Y se ocupa de todo: instala paquetes, hace backup de las configs que toque, escribe las nuevas, valida la sintaxis de nftables antes de aplicar, arranca los servicios y espera hasta 60 segundos a que Tor llegue al 100% de bootstrap.

Si no quieres bridges obfs4 y prefieres tirar solo de snowflake:

```
sudo WIFI_PASS='...' ENABLE_SNOWFLAKE=1 ./setup.sh
```

(El default ya es `ENABLE_SNOWFLAKE=1`, pero si dejas `bridges.txt` vacío necesitas snowflake o el script se planta en preflight.)

El script es idempotente. Lo puedes correr dos veces, tres, las que quieras. Cada ejecución crea un backup nuevo en `/etc/onion-pi-backup-AAAAMMDD-HHMMSS/` con las configs previas, así que si algo se rompe puedes volver atrás.

## Variables

Todas opcionales menos `WIFI_PASS`:

| Variable | Default | Para qué |
|---|---|---|
| `WIFI_PASS` | — | Password WPA2 (8-63 chars). Obligatorio. |
| `SSID` | `onion-pi` | Nombre de la red |
| `WIFI_COUNTRY` | `ES` | Código de país para regulación de canales |
| `WIFI_CHANNEL` | `6` | Canal 2.4 GHz |
| `GATEWAY_IP` | `10.10.10.1` | IP de la Pi en la red interna |
| `SUBNET_MASK_BITS` | `24` | Prefijo CIDR |
| `DHCP_START` / `DHCP_END` | `.50` / `.150` | Rango de leases |
| `WIFI_IFACE` | `wlan0` | Interfaz del AP |
| `WAN_IFACE` | `eth0` | Interfaz de salida al router |
| `BRIDGES_FILE` | `./bridges.txt` | De dónde leer los obfs4 |
| `ENABLE_SNOWFLAKE` | `1` | Añadir snowflake como respaldo |
| `ENABLE_FWKNOP` | `1` | Activar port-knocking SPA en WAN |
| `SSH_PORT` | `22` | Puerto SSH a proteger con fwknop |

## Cómo se prueba que funciona

Conecta un móvil (o lo que sea) a la red `onion-pi` con la password que pusiste, abre el navegador y entra en:

- https://check.torproject.org → tiene que salir el banner verde de "Congratulations. This browser is configured to use Tor."
- https://ipleak.net → la IP que aparezca debería ser un exit node, y los DNS no deberían filtrarse a tu ISP

Si check.torproject.org dice que NO estás usando Tor, mira los logs antes que nada:

```
journalctl -u tor -f
tail -f /var/log/tor/notices.log
```

Lo más típico cuando los bridges no tiran es que aparezca un `Bootstrapped 10%` y se quede ahí. Saca bridges nuevos y vuelve a correr el setup, o tira solo de snowflake.

## SSH desde fuera con fwknop

Si activas `ENABLE_FWKNOP=1` (es el default), el setup genera unas claves base64 y las deja en `/root/onion-pi-fwknop-keys.txt`. Ese archivo lleva el comando exacto que tienes que correr desde tu cliente: básicamente un `fwknop -A tcp/22 ...` con las claves, y luego ya un `ssh` normal. Mientras nadie mande el paquete SPA correcto, el puerto 22 está cerrado a cal y canto desde el WAN.

Guarda ese archivo bien. Si lo pierdes, lo más rápido es borrarlo y volver a correr el setup, que te regenerará claves nuevas.

## Healthcheck

Hay un servicio systemd (`onion-pi-healthcheck.service`) que se ejecuta en cada arranque y comprueba que:

- `wlan0` tiene la IP del gateway
- La tabla `inet filter` de nftables está cargada
- `nftables`, `onion-pi-wlan`, `hostapd`, `dnsmasq` y `tor` están activos
- `fwknop-server` está vivo si estaba instalado

Si encuentra algo caído, reaplica configs y reinicia el servicio en cuestión. No reinstala nada ni reescribe configs — para eso está `setup.sh`. Los logs van a journal con tag `onion-pi-healthcheck`:

```
journalctl -t onion-pi-healthcheck
```

## Avisos honestos

- Esto no te hace anónimo. Las cookies, las sesiones logueadas, la huella del navegador, el comportamiento... todo eso te sigue identificando aunque la IP cambie.
- Tor es lento para algunas cosas. Streaming en HD por Tor es una experiencia regular. Llamadas, peor.
- Algunas webs bloquean exit nodes. Vas a ver muchos CAPTCHAs en Cloudflare.
- Usar Tor llama la atención en redes que lo monitorizan. Por eso los bridges obfs4 / snowflake — disfrazan el tráfico para que no parezca Tor a primera vista. Pero no es magia.
- Si tu ISP o tu país tienen razones legales o políticas para que esto sea un problema, infórmate antes de encenderlo.

## Estructura del repo

```
setup.sh              instalador principal, idempotente
healthcheck.sh        chequeo + auto-reparación en cada boot
bridges.txt           tus bridges obfs4 (no se commitea)
bridges.txt.example   plantilla con instrucciones
```

`bridges.txt` no debería subirse al repo. Si lo haces público, ponlo en `.gitignore`.

## Desinstalar

No hay script de desinstalación, pero las configs originales están en `/etc/onion-pi-backup-*`. A grandes rasgos, para revertir:

```
sudo systemctl disable --now onion-pi-healthcheck onion-pi-wlan hostapd dnsmasq tor nftables fwknop-server
sudo rm /etc/systemd/system/onion-pi-*.service
sudo rm /etc/systemd/system/hostapd.service.d/onion-pi.conf
sudo rm /etc/systemd/system/dnsmasq.service.d/onion-pi.conf
sudo rm /etc/NetworkManager/conf.d/99-onion-pi.conf
```

Y restaurar a mano los ficheros del backup más reciente. O reflashea la SD, que para eso usas Lite.

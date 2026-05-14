# onion-pi

Una Raspberry Pi 4 convertida en un punto de acceso WiFi que mete todo el tráfico de los dispositivos conectados por Tor, sin tocar el router del ISP.

La idea es sencilla: conectas la Pi al router por cable (eth0), la Pi emite su propia red WiFi (wlan0), y cualquier dispositivo que se conecte a esa WiFi sale a internet por Tor. Si Tor se cae, no hay internet, no hay fugas. Eso es lo que llamo "kill-switch implícito": como no hay forwarding en el kernel, lo único que sale al WAN son las conexiones que abre el propio proceso `tor`.

No es un proyecto para "ser anónimo en internet" sin más. Es un proyecto para tener un AP separado en casa donde el tráfico va por Tor por defecto, sin tener que configurar nada en cada dispositivo. Si lo que quieres es anonimato fuerte, usa Tails o Whonix.

## Qué monta exactamente

- `hostapd` levantando un AP WPA2-PSK en `wlan0` con una config minimalista que esquiva varios bugs del firmware Broadcom de la Pi 4 (ver más abajo)
- `dnsmasq` haciendo solo DHCP (el puerto DNS está apagado a propósito)
- `tor` con `TransPort` y `DNSPort` escuchando en la IP del gateway, con bridges obfs4 desde `bridges.txt` y snowflake como respaldo
- `nftables` redirigiendo todo el TCP de los clientes al `TransPort` y todo el DNS al `DNSPort` de Tor; el resto, drop
- `fwknop` (opcional) haciendo port-knocking SPA en `eth0` para que SSH desde fuera esté cerrado hasta que mandes un paquete autenticado
- Un `healthcheck.sh` que corre en cada arranque y reintenta lo que se haya caído
- Un servicio `onion-pi-wlan.service` que asigna la IP estática de wlan0 y **apaga el power-save del chip** (sin esto los beacons del AP se cortan y el móvil ve la red pero no asocia)

`ip_forward` está deliberadamente a 0. Tor escucha local, los clientes hablan al puerto del gateway, y nftables los redirige. No hace falta NAT.

## Lo que necesitas

- Una Raspberry Pi 4 o 5 con Raspberry Pi OS Lite (Bookworm) o Debian 13 (Trixie), instalado limpio
- Cable ethernet al router (eth0 → WAN)
- WiFi interna libre (wlan0 → AP)
- Acceso root

Probado en Pi 4 con Debian 13 Trixie, kernel `6.12.75+rpt-rpi-v8`, firmware `firmware-brcm80211 20250410-2+rpt1`. En Pi 5 debería funcionar igual (mismo chip Broadcom familia 4345). En otras distros Debian-like debería andar pero no lo garantizo.

## Instalación

Clona el repo en la Pi y, si vas a usar bridges obfs4 (recomendado), saca unos cuantos en https://bridges.torproject.org/ con transport obfs4 y pégalos en `bridges.txt`, **una línea por bridge**. El parser admite los dos formatos que entregan las webs de Tor:

```
Bridge obfs4 1.2.3.4:443 ABCD... cert=... iat-mode=0
obfs4 5.6.7.8:9001 0123... cert=... iat-mode=0
```

Las líneas que empiezan por `#` se ignoran como comentarios. Si dejas el fichero sin un solo bridge válido y no hay snowflake, el preflight aborta con un mensaje claro.

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

> **Importante**: ejecuta el setup conectado **por cable (eth0)**. El script reconfigura `wlan0` como AP cerrado; si estás dentro vía SSH-WiFi te quedas fuera al instante.

## Variables

Todas opcionales menos `WIFI_PASS`:

| Variable | Default | Para qué |
|---|---|---|
| `WIFI_PASS` | — | Password WPA2-PSK (8-63 chars, ASCII imprimible). Obligatorio. |
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
| `SSH_LAN_CIDR` | (vacío) | Subredes separadas por coma con SSH abierto en eth0 sin fwknop. Ej: `192.168.1.0/24` |

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

## SSH abierto desde tu LAN (sin fwknop)

Si lo que quieres es SSH cómodo desde tu propia red doméstica (no desde internet), exporta `SSH_LAN_CIDR` al ejecutar el setup con la subred de tu LAN:

```
sudo WIFI_PASS='...' SSH_LAN_CIDR='192.168.1.0/24' ./setup.sh
```

Puedes pasar varias subredes separadas por comas:

```
SSH_LAN_CIDR='192.168.1.0/24,10.0.0.0/24'
```

Esto añade reglas a la chain `wan_in` que permiten SSH desde esos rangos por eth0 sin pasar por fwknop. fwknop sigue activo y disponible si en el futuro abres el 22 al WAN público.

Si ya tienes el sistema instalado y solo quieres abrirlo ahora mismo, edita `/etc/nftables.conf` añadiendo dentro de `chain wan_in`:

```
iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 22 accept
```

Y aplica con `sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf`. La sesión SSH actual no se cae porque las conexiones en `established,related` ya están exentas en la chain `input`.

## SSH desde fuera con fwknop

Si activas `ENABLE_FWKNOP=1` (es el default), el setup genera unas claves base64 y las deja en `/root/onion-pi-fwknop-keys.txt`. Ese archivo lleva el comando exacto que tienes que correr desde tu cliente: básicamente un `fwknop -A tcp/22 ...` con las claves, y luego ya un `ssh` normal. Mientras nadie mande el paquete SPA correcto, el puerto 22 está cerrado a cal y canto desde el WAN.

Guarda ese archivo bien. Si lo pierdes, lo más rápido es borrarlo y volver a correr el setup, que te regenerará claves nuevas.

## Web UI (status + configuración desde la LAN del AP)

Por defecto el setup levanta un panel web en `http://10.10.10.1` (la IP del gateway), accesible **sólo desde un cliente conectado al WiFi de la Pi**. Las reglas nftables exentan el tráfico hacia el gateway de la redirección a Tor para que puedas abrirla en el navegador.

### Primer arranque: wizard de onboarding

Cuando entras al UI por primera vez, te sale un **wizard de configuración** en `/setup` (no pide auth porque aún no hay admin pass). Te pide:

- Usuario y contraseña del panel de admin
- Opcionalmente: cambiar el SSID y la pass WiFi

Tras finalizarlo, escribe `/etc/onion-pi-webui.initialized` y a partir de ahí todos los accesos requieren las credenciales que pusiste.

Para resetear y volver a ver el wizard (p. ej. si pierdes la contraseña):

```
sudo rm /etc/onion-pi-webui.initialized /etc/onion-pi-webui.passwd
sudo systemctl restart onion-pi-webui
```

Qué muestra:

- Bootstrap actual de Tor (% y estado)
- IP pública vista por Tor (cacheada cada 5 min vía `check.torproject.org`)
- Servicios activos (hostapd, dnsmasq, tor, nftables, webui)
- Clientes conectados con MAC, IP y nombre

Qué puedes cambiar desde la web:

- **SSID y contraseña WiFi** → reescribe `/etc/hostapd/hostapd.conf` y reinicia hostapd con un retraso de 3 s (para que la respuesta llegue antes del corte).
- **Bridges Tor** → reescribe la sección `Bridge ...` de `/etc/tor/torrc` y reinicia Tor.
- **OTA update manual** → lanza `/usr/local/sbin/onion-pi-ota-update.sh` en background.
- **Reboot** → systemd reboot con confirmación.

Las credenciales se generan en el primer `setup.sh` y se guardan en `/etc/onion-pi-webui.passwd`. Salen también impresas al final del setup. Si se borra ese fichero, el siguiente `setup.sh` genera unas nuevas.

Variables:

| Variable | Default | Descripción |
|---|---|---|
| `ENABLE_WEBUI` | `1` | Levantar o no la web UI |
| `WEBUI_PORT` | `80` | Puerto en `10.10.10.1` |

> El proceso corre como **root** porque necesita reescribir `/etc/hostapd/hostapd.conf` y `/etc/tor/torrc`. La protección es HTTP Basic auth + binding exclusivo a la IP del gateway. No expongas este puerto al WAN.

## OTA updates

Si `ENABLE_OTA=1` (default), el setup deja preparados:

- `/usr/local/sbin/onion-pi-ota-update.sh` → hace `git fetch` + `git merge --ff-only` sobre la rama configurada (default `master`), y si hay cambios re-ejecuta `setup.sh` (idempotente). Los SSID/pass actuales se preservan leyendo `/etc/hostapd/hostapd.conf`.
- `/usr/local/bin/onion-pi-update` → wrapper amigable para uso desde shell.
- `onion-pi-ota.timer` → corre el script semanal con jitter de hasta 1 h.
- `/run/onion-pi-ota-state.json` → estado en vivo del proceso (`running`/`success`/`error`/`needs_reboot`) que la web UI consume para mostrarte progreso.

### Desde el shell (CLI)

```
sudo onion-pi-update           # tira la actualización si la hay
onion-pi-update --check        # sólo dice si hay update (no la aplica)
onion-pi-update --status       # estado del último OTA
```

### Desde la web UI

Botón "Comprobar OTA ahora" en el panel. Aparece un cuadro de progreso que se actualiza cada 2 s vía `/api/ota/status` mostrando la fase (`Comprobando cambios...`, `Descargando...`, `Aplicando configuración...`).

Si el OTA detecta que **hace falta reiniciar la Pi** (kernel actualizado, módulos de firmware tocados, o `/var/run/reboot-required` presente), aparece un **banner rojo** arriba con un botón "Reiniciar ahora" — porque algunas cosas (drivers WiFi, kernel) no se pueden cargar sin reboot.

### Variables

| Variable | Default | Descripción |
|---|---|---|
| `ENABLE_OTA` | `1` | Activar timer semanal |
| `OTA_BRANCH` | `master` | Rama de la que tirar |

Si trabajas activamente en el repo en este mismo host, pon `ENABLE_OTA=0` para evitar que un timer te haga reset a lo que haya en master.

### Cómo publicar un update

Como mantenedor, basta con hacer push a la rama `master` (o la que pongas en `OTA_BRANCH`). Cada Pi en el campo:

1. El timer corre semanal (o el user le da al botón "Comprobar OTA ahora").
2. El script hace `git fetch` + `git merge --ff-only`. Si hay divergencia local, aborta para no destruir cambios.
3. Si hay cambios, re-ejecuta `setup.sh` que es idempotente.
4. Si toca kernel/firmware → el state file marca `needs_reboot` y la web UI lo enseña.

## Watchdog y auto-recuperación de bridges

Para que el AP siga útil sin necesidad de meter mano cada vez que un bridge se cae, hay dos servicios encadenados:

### Watchdog (`onion-pi-watchdog.timer`)

Cada `WATCHDOG_INTERVAL_MIN` minutos (default 5) ejecuta dos tests reales:

1. **DNS por Tor**: `dig @gateway -p 5353 example.com` debe resolver en <10 s
2. **SOCKS por Tor**: `curl --socks5-hostname gateway:9050 check.torproject.org/api/ip` debe responder `IsTor:true` en <15 s

Si alguno falla:

1. **Reinicia `tor@default`** y reverifica
2. Si tras restart sigue fallando, llama al **bridge-rescue**
3. Si tras rescue sigue fallando, marca estado `error` en `/run/onion-pi-watchdog-state.json` → la web UI muestra banner rojo con instrucciones

### Bridge rescue (`onion-pi-bridge-rescue.sh`)

Cuando los bridges actuales no responden, rota a bridges públicos:

1. **Pide bridges frescos al Moat builtin API** de Tor Project (`https://bridges.torproject.org/moat/circumvention/builtin`) — devuelve los obfs4 default que shipea Tor Browser, rotados por Tor Project cuando van cayendo
2. Si Moat no responde (por censura o lo que sea), usa **`/etc/onion-pi/bridges_default.txt`** (lista bundled refrescable vía OTA)
3. También considera los bridges actuales del torrc (por si alguno resucitó)
4. Para cada candidato hace **TCP connect con timeout 3 s**
5. Toma los primeros `BRIDGE_RESCUE_KEEP_N` (default 3) alive
6. Reescribe el bloque `Bridge obfs4` de `/etc/tor/torrc` y reinicia Tor

Disparadores:

- **Automático**: lo llama el watchdog cuando el restart de Tor no fue suficiente
- **CLI**: `sudo onion-pi-rescue-bridges`
- **Web UI**: botón verde "Buscar bridges públicos nuevos" en la sección Bridges

Logs en `/var/log/onion-pi-bridge-rescue.log` y `journalctl -t onion-pi-bridge-rescue`.

### Variables relevantes

| Variable | Default | Descripción |
|---|---|---|
| `ENABLE_WATCHDOG` | `1` | Timer del watchdog |
| `WATCHDOG_INTERVAL_MIN` | `5` | Frecuencia del watchdog (min) |
| `ENABLE_BRIDGE_RESCUE` | `1` | Permitir que el watchdog rote bridges automáticamente |
| `BRIDGE_RESCUE_KEEP_N` | `3` | Cuántos bridges alive aplicar |

### Limitaciones

- El pool público es **público**: en países con censura activa de Tor (China, Rusia, Irán) estos bridges están todos bloqueados. Necesitas bridges privados manualmente.
- Si tu ISP en España empieza a filtrar también esos IPs en concreto, el rescue no podrá. La última línea de defensa siempre es: meter bridges privados en el textarea de la web UI.
- El `bridges_default.txt` se refresca por OTA cuando mando un `git push` con la lista nueva (Tor Project los rota cada pocos meses).

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

## Bug del firmware WiFi de la Pi 4 (importante)

El chip Broadcom de la Pi 4 (`BCM4345/6`, firmware Cypress `7.45.265` que trae el paquete `firmware-brcm80211 20250410-2+rpt1`) tiene varios bugs como AP que han condicionado la config de `hostapd`. Si tocas la config, ten esto presente o el AP dejará de arrancar.

1. **Sin parámetros extra**. La única config WPA2-PSK que el firmware acepta es minimalista:
   ```
   wpa=2
   wpa_key_mgmt=WPA-PSK
   rsn_pairwise=CCMP
   ```
   Añadir `wpa_pairwise=CCMP`, `ieee80211n=1`, `ieee80211d=1` o `wmm_enabled=1` dispara `brcmf_configure_wpaie: wpa_auth error -52` en `dmesg` y hostapd no arranca con `Failed to set beacon parameters`.

2. **WPA3 (SAE) no funciona**. El AP arranca con `wpa_key_mgmt=SAE`, pero cuando un cliente intenta autenticarse el firmware aborta el handshake con `brcmf_cfg80211_external_auth: External authentication failed: status=1`. El cliente asocia, no termina la auth, y se le deauth-ea por inactividad. Síntoma confuso: hostapd no loguea errores claros, parece "se conecta y se desconecta sin avisar". No pierdas tiempo con `ieee80211w`/`sae_require_mfp`.

3. **Power-save por defecto rompe los beacons**. `wlan0` arranca con `power_save=on` y el AP emite beacons intermitentes; el móvil ve la red en la lista pero falla al asociar. El servicio `onion-pi-wlan.service` apaga el power-save tras subir la interfaz vía `ExecStartPost=/sbin/iw dev wlan0 set power_save off`. No lo quites.

4. **No recargues `brcmfmac`**. Si el AP entra en estado raro y tienes la tentación de `modprobe -r brcmfmac && modprobe brcmfmac`: **no**. En la Pi 4 el bus SDIO falla al reasociarse, `wlan0` desaparece, y solo vuelve con un reboot completo. Comprobado a las malas.

5. **Reiniciar hostapd muchas veces degrada el firmware**. En el caso 1, si arrancas con la config buena y luego haces varios `systemctl restart hostapd` cambiando parámetros, el firmware puede entrar en un estado donde aparece `mfp error -52` y deja de aceptar configs que antes andaban. La salida es reboot, no más restarts.

Estos bugs se han observado con kernel `6.12.75+rpt-rpi-v8` y firmware `20250410`. Si en un futuro actualizan el paquete `firmware-brcm80211` y el `FWID` cambia (mira con `dmesg | grep brcmf_c_preinit`), puede que se arregle algo — replica las pruebas y, si SAE funciona, valora subir a WPA3.

## Troubleshooting

- **"Veo la red `onion-pi` en el móvil pero no se conecta"** → casi siempre power-save. Verifica con `sudo iw dev wlan0 get power_save` que esté `off`. Si está `on`, mira que `onion-pi-wlan.service` aplicó el `ExecStartPost`.
- **"hostapd no arranca, dice `Failed to set beacon parameters`"** → has tocado la config y has añadido algún parámetro que la firmware rechaza. Mira `dmesg | grep brcmf` para el error concreto. Vuelve a la config minimalista de la sección anterior.
- **"El móvil pone 'conectado, sin internet'"** → revisa que Tor llegó al 100% con `tail -f /var/log/tor/notices.log`. Si está atascado en `Bootstrapped 10%`, los bridges están muertos: saca nuevos en https://bridges.torproject.org/ o tira solo de snowflake.
- **"Quiero ver qué clientes hay y a quién le di IP"** →
  ```
  sudo hostapd_cli -i wlan0 list_sta
  sudo cat /var/lib/misc/dnsmasq.leases
  sudo ss -tnp | grep :9040    # conexiones de clientes hacia el TransPort
  ```
- **"wlan0 ha desaparecido del sistema"** → casi seguro recargaste `brcmfmac`. Reboot y a la próxima no lo hagas.

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

## Replicar la config en otra Pi

Todo lo necesario para arrancar una Pi 4 idéntica está en este repo. Lo que NO se trackea (a propósito) es lo per-instalación: bridges privados, contraseñas, leases, etc. — eso lo regenera `setup.sh` localmente.

**Pasos en la Pi nueva** (Raspberry Pi OS Lite / Debian 13, conectada por cable al router):

```
# 1. Clonar el repo
git clone https://github.com/<tu-fork>/rpi4-hide-traffic.git
cd rpi4-hide-traffic

# 2. Poner los bridges obfs4 privados (recomendado, no obligatorio)
#    Si no, exporta ENABLE_SNOWFLAKE=1 para tirar solo de snowflake.
cp bridges.txt.example bridges.txt
nano bridges.txt   # pega tus bridges aquí

# 3. Lanzar el setup
sudo WIFI_PASS='lacontraseña' ./setup.sh
```

Eso es todo. `setup.sh` se ocupa de:

- Instalar todos los paquetes (`tor obfs4proxy hostapd dnsmasq nftables` + snowflake-client + fwknop-server + dnsutils + curl + git)
- Generar `/etc/hostapd/hostapd.conf` con la SSID/pass (WPA2-PSK minimalista para no chocar con bugs del firmware brcmfmac)
- Generar `/etc/tor/torrc` con bridges desde `bridges.txt` + snowflake
- Generar `/etc/nftables.conf` con kill-switch, redirección a Tor, y reglas de bypass
- Crear todos los servicios systemd: `onion-pi-wlan`, `onion-pi-webui`, `onion-pi-watchdog.timer`, `onion-pi-ota.timer`, `onion-pi-bypass-refresh.timer`, `onion-pi-healthcheck`
- Crear los scripts en `/usr/local/sbin/`: watchdog, bridge-rescue, bypass-refresh, ota-update
- Crear el CLI en `/usr/local/bin/`: `onion-pi-update`, `onion-pi-rescue-bridges`
- Apagar power-save de wlan0 vía systemd drop-in
- Generar `/etc/onion-pi/options.env` con todas las flags toggleables comentadas
- Generar `/etc/onion-pi/bypass.txt` template (vacío salvo comentarios)

**Tras el primer arranque**:

1. Conecta un cliente al SSID nuevo (con la pass que pasaste)
2. Abre `http://10.10.10.1` en el navegador
3. Aparece el **wizard de onboarding** — establece usuario/contraseña de admin del panel
4. Una vez dentro, puedes editar bridges, bypass list, etc. desde la UI

**Activar Discord/Parsec/voz desde el principio en cada Pi nueva**:

Si vas a vender el producto y quieres que todas las Pis tengan UDP bypass por defecto, edita `/etc/onion-pi/options.env` antes del primer arranque, o haz que tu fork del repo edite los defaults en `setup.sh`:

```
sudo sed -i 's/^#ENABLE_BYPASS_ALL_UDP=1/ENABLE_BYPASS_ALL_UDP=1/' /etc/onion-pi/options.env
sudo ./setup.sh
```

**Idempotencia entre runs**: re-ejecutar `setup.sh` (manual o via OTA) preserva:
- SSID y pass WiFi (las lee de `hostapd.conf` existente)
- `bridges.txt` (no se toca)
- `/etc/onion-pi/bypass.txt` (sólo se crea si no existe)
- `/etc/onion-pi/options.env` (sólo se crea si no existe)
- Credenciales del web UI y flag de onboarding
- Claves fwknop generadas

Lo que SÍ se regenera en cada run (con backup en `/etc/onion-pi-backup-AAAAMMDD-HHMMSS/`): `hostapd.conf`, `dnsmasq.conf`, `nftables.conf`, `torrc`, units systemd.

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

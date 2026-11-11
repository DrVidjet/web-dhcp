#!/bin/bash
# web-dhcp: установка / обновление / удаление на Debian 10-13.
#
#   sudo ./start.sh                  спросит интерфейс, порт, DHCP... и запустит службу (systemd + таймер чистки)
#   sudo ./start.sh -y               без вопросов: значения по умолчанию / из прошлой установки / из --answers
#   sudo ./start.sh --answers F      заранее заданные ответы (файл KEY=VALUE, ключи как в .env.example)
#   sudo ./start.sh --uninstall      убрать службу, таймер и свои конфиги dnsmasq (история клиентов остаётся)
#
# Значения по умолчанию: --answers > .env прошлой установки > .env проекта (или .env.example) > встроенные.
# Повторный запуск = обновление. Итоговые настройки - <папка установки>/.env.
# Python запускается только из виртуального окружения <папка установки>/venv.
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
APP=web-dhcp

# ---------------------------------------------------------------- общее
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null && exec sudo bash "$0" "$@"
  echo "Нужен root: su -c 'bash $0 $*'" >&2; exit 1
fi
YES=0; ANSWERS=""; UNINSTALL=0
while [ $# -gt 0 ]; do
  case $1 in
    -y|--yes) YES=1 ;;
    --answers) ANSWERS=$2; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "неизвестный параметр: $1" >&2; exit 1 ;;
  esac
  shift
done

c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_r=$'\e[1;31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
say()  { printf '\n%s==> %s%s\n' "$c_g" "$*" "$c_0"; }
warn() { printf '%s[!] %s%s\n' "$c_y" "$*" "$c_0" >&2; }
die()  { printf '%s[X] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

declare -A PRE=()   # заранее заданные ответы: --answers, затем .env прошлой установки
declare -A PROJ=()  # значения по умолчанию из .env (или .env.example) рядом со start.sh; пустые пропускаются
read_kv() {         # read_kv файл -> PRE[...] (не перетирает уже заданное)
  local k v
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^[[:space:]]*# || $line != *=* ]] && continue
    k=${line%%=*}; v=${line#*=}; k=${k//[[:space:]]/}
    [ -n "$k" ] && [ -z "${PRE[$k]+x}" ] && PRE[$k]=$v
  done < "$1"
}
read_proj() {
  local f=$SRC/.env k v
  [ -f "$f" ] || f=$SRC/.env.example
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^[[:space:]]*# || $line != *=* ]] && continue
    k=${line%%=*}; v=${line#*=}; k=${k//[[:space:]]/}
    [ -n "$k" ] && [ -n "$v" ] && PROJ[$k]=$v
  done < "$f"
}
read_proj
# setting ПЕРЕМЕННАЯ "по умолчанию" - без вопроса (редкие настройки: только из --answers / .env)
setting() { printf -v "$1" '%s' "${PRE[$1]-${PROJ[$1]-$2}}"; }
# ask ПЕРЕМЕННАЯ "вопрос" "по умолчанию"
ask() {
  local var=$1 q=$2 def=${PRE[$1]-${PROJ[$1]-$3}} a
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then a=$def
  else
    read -r -p "$q${def:+ [$def]}: " a || true
    [ -z "$a" ] && a=$def
    [ "$a" = "-" ] && a=""
  fi
  printf -v "$var" '%s' "$a"
}
# ask_yn ПЕРЕМЕННАЯ "вопрос" y|n  -> y|n
ask_yn() {
  local var=$1 q=$2 def=${PRE[$1]-${PROJ[$1]-$3}} a
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then a=$def
  else
    read -r -p "$q [$( [ "$def" = y ] && echo Д/н || echo д/Н )]: " a || true
    case ${a,,} in д|y|да|yes) a=y ;; н|n|нет|no) a=n ;; *) a=$def ;; esac
  fi
  printf -v "$var" '%s' "$a"
}
gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true; }

check_debian() {
  . /etc/os-release
  [ "${ID:-}" = debian ] || [[ " ${ID_LIKE:-} " == *" debian "* ]] || die "Нужен Debian (тут: ${PRETTY_NAME:-?})"
  local dv; dv=$(cut -d. -f1 /etc/debian_version 2>/dev/null)   # у производных (Astra и т.п.) - версия базы Debian
  case $dv in 10|11|12|13) [ "${ID:-}" = debian ] || echo "${PRETTY_NAME:-?} (база Debian $dv)" ;;
    *) warn "Проверено на Debian 10-13, тут ${PRETTY_NAME:-?} ($(cat /etc/debian_version 2>/dev/null)) - пробую" ;; esac
}
APT_UPDATED=0
apt_update() {
  [ "$APT_UPDATED" = 1 ] && return 0
  if ! apt-get update -q; then
    . /etc/os-release
    if [ "${VERSION_CODENAME:-}" = buster ] || [ "${VERSION_CODENAME:-}" = stretch ]; then
      warn "$VERSION_CODENAME больше не на основных зеркалах - переключаю apt на archive.debian.org"
      cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak-$(date +%s)" 2>/dev/null || true
      cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian $VERSION_CODENAME main contrib non-free
deb http://archive.debian.org/debian-security $VERSION_CODENAME/updates main contrib non-free
EOF
      rm -f /etc/apt/sources.list.d/debian.sources
      echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive
      apt-get update -q || die "apt-get update не прошёл"
    else
      die "apt-get update не прошёл - проверьте сеть и /etc/apt/sources.list"
    fi
  fi
  APT_UPDATED=1
}
need_pkgs() {
  local miss=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || miss+=("$p")
  done
  [ ${#miss[@]} = 0 ] && return 0
  say "Ставлю пакеты: ${miss[*]}"
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${miss[@]}"
}
make_venv() {   # make_venv папка
  local v=$1/venv
  if [ -x "$v/bin/python3" ] && "$v/bin/python3" -c 'import sys' 2>/dev/null; then return 0; fi
  rm -rf "$v"
  python3 -m venv "$v" || die "не удалось создать venv в $v"
  echo "создано виртуальное окружение $v ($("$v/bin/python3" -V 2>&1))"
}
host_ips() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
set_shebang() { sed -i "1s|.*|#!$2 -I|" "$1"; }  # set_shebang файл python
iface_cidr() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'; }
default_iface() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
py() { python3 -c "$@"; }

# ---------------------------------------------------------------- ответы
check_debian
[ -n "$ANSWERS" ] && { [ -f "$ANSWERS" ] || die "нет файла $ANSWERS"; read_kv "$ANSWERS"; }

echo "${c_b}web-dhcp — веб-панель клиентов DHCP-сети (dnsmasq)${c_0}"
[ "$YES" = 1 ] || echo "Enter — значение в [скобках], «-» — оставить пустым."
ask INSTALL_DIR "Папка установки" "/opt/$APP"
read_kv "$INSTALL_DIR/.env"
read_kv "$INSTALL_DIR/config.env"   # старое имя файла настроек
ask INSTALL_SERVICE "Имя службы systemd" "$APP"
SERVICE=$INSTALL_SERVICE
UNIT=/etc/systemd/system/$SERVICE.service
PUNIT=/etc/systemd/system/$SERVICE-prune.service
PTIMER=/etc/systemd/system/$SERVICE-prune.timer
DNSCONF=/etc/dnsmasq.d/$SERVICE.conf
HOOKCONF=/etc/dnsmasq.d/$SERVICE-hook.conf

if [ "$UNINSTALL" = 1 ]; then
  say "Удаление $SERVICE"
  systemctl disable --now "$SERVICE" "$SERVICE-prune.timer" 2>/dev/null || true
  rm -f "$UNIT" "$PUNIT" "$PTIMER"
  if [ -f "$DNSCONF" ] || [ -f "$HOOKCONF" ]; then
    rm -f "$DNSCONF" "$HOOKCONF"; systemctl restart dnsmasq 2>/dev/null || true
    echo "убраны $DNSCONF $HOOKCONF (DHCP этой установки выключен)"
  fi
  # адрес интерфейса, если его назначал start.sh
  IF=${PRE[DASH_IFACE]:-}; A=${PRE[INSTALL_DHCP_ADDR]:-}
  if [ -n "$IF" ] && [ -n "$A" ]; then
    if grep -qs "^# $APP (создано start.sh)" "/etc/network/interfaces.d/$IF"; then
      ifdown "$IF" 2>/dev/null || true; rm -f "/etc/network/interfaces.d/$IF"; echo "убран адрес $A ($IF, ifupdown)"
    fi
    if [ -f "/etc/systemd/network/10-$APP-$IF.network" ]; then
      rm -f "/etc/systemd/network/10-$APP-$IF.network"; networkctl reload 2>/dev/null || true; echo "убран адрес $A ($IF, networkd)"
    fi
    if command -v nmcli >/dev/null && nmcli -t -f NAME con show 2>/dev/null | grep -qx "$APP-$IF"; then
      nmcli con delete "$APP-$IF" >/dev/null && echo "убран адрес $A ($IF, NetworkManager)"
    fi
    ip addr del "$A" dev "$IF" 2>/dev/null || true
  fi
  systemctl daemon-reload
  ask_yn DEL_DIR "Удалить папку установки $INSTALL_DIR (код, venv, .env)?" y
  [ "$DEL_DIR" = y ] && rm -rf "$INSTALL_DIR"
  echo "Готово. История клиентов (${PRE[DASH_HOSTS_DIR]:-/var/lib/$APP/hosts}) и подписи не тронуты."
  exit 0
fi

echo "Сетевые интерфейсы:"
for n in $(ls /sys/class/net); do [ "$n" = lo ] && continue; printf '  %-16s %s\n' "$n" "$(iface_cidr "$n")"; done
DEF_IF=$(default_iface || true)
GUESS_IF=""
for n in $(ls /sys/class/net); do
  [ "$n" = lo ] || [ "$n" = "$DEF_IF" ] || [[ $n == docker* || $n == br-* || $n == veth* || $n == virbr* ]] || { GUESS_IF=$n; break; }
done
ask DASH_IFACE "Интерфейс DHCP-сети (клиенты, которых показываем)" "${GUESS_IF:-$DEF_IF}"
[ -e "/sys/class/net/$DASH_IFACE" ] || die "нет интерфейса $DASH_IFACE"
ask DASH_PORT "Порт веб-панели" "8080"
[[ $DASH_PORT =~ ^[0-9]+$ ]] && [ "$DASH_PORT" -ge 1 ] && [ "$DASH_PORT" -le 65535 ] || die "плохой порт: $DASH_PORT"
ask DASH_BIND "Адрес, на котором слушать (0.0.0.0 — все)" "0.0.0.0"

# --- DHCP-сервер
EXIST_DHCP=$(grep -rlsE "^[[:space:]]*dhcp-range" /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null | grep -vxF "$DNSCONF" || true)
if [ -n "$EXIST_DHCP" ]; then
  echo "dnsmasq уже раздаёт DHCP (конфиг: $(echo $EXIST_DHCP)) - его не трогаю, подключу только хук."
  INSTALL_DHCP=n
else
  ask_yn INSTALL_DHCP "Поднять DHCP-сервер (dnsmasq) на $DASH_IFACE?" y
fi
CIDR=$(iface_cidr "$DASH_IFACE")
INSTALL_DHCP_ADDR=${INSTALL_DHCP_ADDR:-}
if [ "$INSTALL_DHCP" = y ]; then
  if [ -z "$CIDR" ]; then
    ask INSTALL_DHCP_ADDR "У $DASH_IFACE нет IPv4. Адрес сервера в этой сети (CIDR)" "10.10.0.1/24"
    CIDR=$INSTALL_DHCP_ADDR
  fi
  py "import ipaddress,sys; ipaddress.ip_interface(sys.argv[1])" "$CIDR" 2>/dev/null || die "плохой адрес: $CIDR"
  read -r R_START R_END MASK <<<"$(py '
import ipaddress, sys
n = ipaddress.ip_interface(sys.argv[1]).network; size = n.num_addresses
lo, hi = (100, min(250, size - 2)) if size >= 256 else (max(2, size // 2), size - 2)
print(n.network_address + lo, n.network_address + hi, n.netmask)' "$CIDR")"
  ask INSTALL_DHCP_START "Начало диапазона адресов" "$R_START"
  ask INSTALL_DHCP_END "Конец диапазона адресов" "$R_END"
  ask INSTALL_DHCP_LEASE "Время аренды" "12h"
  ask INSTALL_DHCP_GATEWAY "Шлюз для клиентов (пусто — не выдавать)" ""
  ask INSTALL_DHCP_DNS "DNS-серверы для клиентов через запятую (пусто — не выдавать)" ""
  ask_yn INSTALL_DHCP_PXE "Отдавать PXE-клиентам опцию 60 «PXEClient» (нужно для proxyDHCP, например iVentoy)?" n
fi

ask DASH_LEASES "Файл аренд dnsmasq" "/var/lib/misc/dnsmasq.leases"
ask DASH_HOSTS_DIR "Папка истории клиентов (пишет хук dnsmasq)" "/var/lib/$APP/hosts"
NETNAME=""
[ -n "$CIDR" ] && NETNAME=$(py "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$CIDR")
ask DASH_TITLE "Заголовок страницы" "${NETNAME:+Сеть $NETNAME}"
[ -z "$DASH_TITLE" ] && DASH_TITLE="DHCP-клиенты"
LAN_IP=""
[ -n "$DEF_IF" ] && LAN_IP=$(iface_cidr "$DEF_IF" | cut -d/ -f1)
ask DASH_SERVER_ADDR "Адрес сервера для шапки (пусто — не показывать)" "$LAN_IP"
ask DASH_IPMI_URL "Ссылка на IPMI этого сервера (пусто — нет)" ""
IV_DEF=""; ss -ltn 2>/dev/null | grep -q ':26000 ' && IV_DEF=26000
ask DASH_IVENTOY_PORT "Порт iVentoy на этом сервере для блока статуса (пусто — нет)" "$IV_DEF"
SH_DEF=""; ss -ltn 2>/dev/null | grep -q ':8081 ' && SH_DEF='http://{host}:8081/'
ask DASH_SHARE_URL "Ссылка «Общая папка» ({host} — адрес страницы; пусто — нет)" "$SH_DEF"
ask DASH_SMB_PATH "Путь Samba-шары для показа (пусто — нет)" ""
ask DASH_PRUNE_HOURS "Забывать клиентов, которых не было в сети N часов (0 — никогда)" "24"
[[ $DASH_PRUNE_HOURS =~ ^[0-9]+$ ]] || die "нужно целое число часов"
setting DASH_PROBE_INTERVAL 60

# ---------------------------------------------------------------- установка
need_pkgs python3 python3-venv iputils-ping iproute2
[ "$INSTALL_DHCP" = y ] && need_pkgs dnsmasq

say "Файлы в $INSTALL_DIR"
install -d -m 755 "$INSTALL_DIR" "$DASH_HOSTS_DIR"
install -m 755 "$SRC/pxe-dash.py" "$SRC/pxe-dhcp-hook" "$SRC/pxe-dash-prune" "$INSTALL_DIR/"
install -m 644 "$SRC/oui.tsv" "$INSTALL_DIR/"
make_venv "$INSTALL_DIR"
for f in pxe-dash.py pxe-dhcp-hook pxe-dash-prune; do set_shebang "$INSTALL_DIR/$f" "$INSTALL_DIR/venv/bin/python3"; done
cfg=$INSTALL_DIR/.env
{
  echo "# $APP: настройки (создано start.sh $(date '+%F %T')). После правки: systemctl restart $SERVICE"
  for k in DASH_PORT DASH_BIND DASH_IFACE DASH_LEASES DASH_HOSTS_DIR DASH_TITLE DASH_SERVER_ADDR DASH_IPMI_URL \
           DASH_IVENTOY_PORT DASH_SHARE_URL DASH_SMB_PATH DASH_PRUNE_HOURS DASH_PROBE_INTERVAL; do echo "$k=${!k}"; done
  echo "# для start.sh (приложение не читает)"
  for k in INSTALL_SERVICE INSTALL_DHCP INSTALL_DHCP_ADDR INSTALL_DHCP_START INSTALL_DHCP_END INSTALL_DHCP_LEASE \
           INSTALL_DHCP_GATEWAY INSTALL_DHCP_DNS INSTALL_DHCP_PXE; do echo "$k=${!k-}"; done
} > "$cfg.tmp"
chmod 644 "$cfg.tmp"; mv "$cfg.tmp" "$cfg"
rm -f "$INSTALL_DIR/config.env"
echo "настройки: $cfg"

# ---------------------------------------------------------------- сеть и dnsmasq
if [ "$INSTALL_DHCP" = y ]; then
  say "DHCP на $DASH_IFACE"
  if [ -n "$INSTALL_DHCP_ADDR" ] && [ -z "$(iface_cidr "$DASH_IFACE")" ]; then
    if [ -f /etc/network/interfaces ] && ! systemctl is-active -q NetworkManager 2>/dev/null; then
      grep -qE '^[[:space:]]*source(-directory)? .*interfaces\.d' /etc/network/interfaces || \
        printf '\nsource /etc/network/interfaces.d/*\n' >> /etc/network/interfaces
      mkdir -p /etc/network/interfaces.d
      printf '# %s (создано start.sh)\nauto %s\niface %s inet static\n    address %s\n' \
        "$APP" "$DASH_IFACE" "$DASH_IFACE" "$INSTALL_DHCP_ADDR" > "/etc/network/interfaces.d/$DASH_IFACE"
      ifup "$DASH_IFACE" 2>/dev/null || { ip link set "$DASH_IFACE" up; ip addr add "$INSTALL_DHCP_ADDR" dev "$DASH_IFACE"; }
      echo "адрес $INSTALL_DHCP_ADDR -> /etc/network/interfaces.d/$DASH_IFACE"
    elif systemctl is-active -q systemd-networkd 2>/dev/null; then
      printf '# %s (создано start.sh)\n[Match]\nName=%s\n\n[Network]\nAddress=%s\nConfigureWithoutCarrier=yes\n' \
        "$APP" "$DASH_IFACE" "$INSTALL_DHCP_ADDR" > "/etc/systemd/network/10-$APP-$DASH_IFACE.network"
      networkctl reload 2>/dev/null || systemctl restart systemd-networkd
      sleep 2; [ -n "$(iface_cidr "$DASH_IFACE")" ] || { ip link set "$DASH_IFACE" up; ip addr add "$INSTALL_DHCP_ADDR" dev "$DASH_IFACE"; }
      echo "адрес $INSTALL_DHCP_ADDR -> /etc/systemd/network/10-$APP-$DASH_IFACE.network"
    elif command -v nmcli >/dev/null && systemctl is-active -q NetworkManager; then
      nmcli con add type ethernet ifname "$DASH_IFACE" con-name "$APP-$DASH_IFACE" ipv4.method manual \
        ipv4.addresses "$INSTALL_DHCP_ADDR" ipv6.method disabled >/dev/null
      nmcli con up "$APP-$DASH_IFACE" >/dev/null 2>&1 || \
        warn "$DASH_IFACE сейчас не поднять (нет линка?) - адрес появится, когда интерфейс подключат"
      echo "адрес $INSTALL_DHCP_ADDR -> NetworkManager ($APP-$DASH_IFACE)"
    else
      ip link set "$DASH_IFACE" up; ip addr add "$INSTALL_DHCP_ADDR" dev "$DASH_IFACE"
      warn "не знаю, как сохранить адрес навсегда (нет ifupdown/NetworkManager) - назначен до перезагрузки"
    fi
  fi
  {
    echo "# $APP: DHCP на $DASH_IFACE (создано start.sh)"
    echo "interface=$DASH_IFACE"
    echo "bind-dynamic"
    echo "port=0"
    echo "dhcp-authoritative"
    echo "dhcp-range=$INSTALL_DHCP_START,$INSTALL_DHCP_END,$MASK,$INSTALL_DHCP_LEASE"
    [ -n "$INSTALL_DHCP_GATEWAY" ] && echo "dhcp-option=option:router,$INSTALL_DHCP_GATEWAY"
    [ -n "$INSTALL_DHCP_DNS" ] && echo "dhcp-option=option:dns-server,$INSTALL_DHCP_DNS"
    echo "dhcp-leasefile=$DASH_LEASES"
    echo "dhcp-script=$INSTALL_DIR/pxe-dhcp-hook"
    if [ "$INSTALL_DHCP_PXE" = y ]; then
      echo "# PXE-клиентам - опция 60 «PXEClient»: загрузчик спросит proxyDHCP (порт 4011) на этом же сервере"
      echo "dhcp-vendorclass=set:pxe,PXEClient"
      echo 'dhcp-option-force=tag:pxe,60,"PXEClient"'
    fi
  } > "$DNSCONF"
  rm -f "$HOOKCONF"
  if ! dnsmasq --test --conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new >/dev/null 2>&1; then
    dnsmasq --test --conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new || true
    die "ошибка в конфиге dnsmasq ($DNSCONF)"
  fi
  systemctl enable dnsmasq >/dev/null 2>&1; systemctl restart dnsmasq
  echo "dnsmasq: $DNSCONF, раздаёт $INSTALL_DHCP_START - $INSTALL_DHCP_END"
else
  rm -f "$DNSCONF"
  if command -v dnsmasq >/dev/null; then
    cur=$(grep -rhsE '^[[:space:]]*dhcp-script[[:space:]]*=' /etc/dnsmasq.conf /etc/dnsmasq.d/ | head -1 | cut -d= -f2- | xargs || true)
    if [ "$cur" = "$INSTALL_DIR/pxe-dhcp-hook" ]; then
      echo "хук уже подключён к dnsmasq"
    elif [ -n "$cur" ]; then
      warn "в dnsmasq уже другой dhcp-script ($cur) - история клиентов (vendor class, «впервые») заполняться не будет"
    else
      echo "dhcp-script=$INSTALL_DIR/pxe-dhcp-hook" > "$HOOKCONF"
      systemctl restart dnsmasq && echo "хук подключён: $HOOKCONF"
    fi
  else
    warn "dnsmasq не установлен - панели нечего показывать, пока аренды не появятся в $DASH_LEASES"
  fi
fi

# ---------------------------------------------------------------- systemd
say "Службы"
cat > "$UNIT" <<UNIT_END
# $APP (создано start.sh). Настройки - $cfg
[Unit]
Description=$APP: DHCP clients web panel (port $DASH_PORT)
After=network-online.target dnsmasq.service
Wants=network-online.target

[Service]
ExecStart=$INSTALL_DIR/venv/bin/python3 -I $INSTALL_DIR/pxe-dash.py
WorkingDirectory=$INSTALL_DIR
DynamicUser=yes
StateDirectory=$SERVICE-labels
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_END
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
if [ "$DASH_PRUNE_HOURS" != 0 ]; then
  cat > "$PUNIT" <<UNIT_END
# $APP (создано start.sh)
[Unit]
Description=$APP: forget DHCP clients offline for more than $DASH_PRUNE_HOURS h

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/venv/bin/python3 -I $INSTALL_DIR/pxe-dash-prune
UNIT_END
  cat > "$PTIMER" <<UNIT_END
# $APP (создано start.sh)
[Unit]
Description=$APP: periodically forget stale DHCP clients

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT_END
  systemctl daemon-reload
  systemctl enable "$SERVICE-prune.timer" >/dev/null 2>&1
  systemctl restart "$SERVICE-prune.timer"
  echo "таймер чистки: $SERVICE-prune.timer (каждые 5 минут)"
else
  systemctl disable --now "$SERVICE-prune.timer" 2>/dev/null || true
  rm -f "$PUNIT" "$PTIMER"; systemctl daemon-reload
fi

# ---------------------------------------------------------------- проверка
say "Проверка"
ok=0
for i in $(seq 1 20); do
  if "$INSTALL_DIR/venv/bin/python3" -c "import urllib.request,sys; urllib.request.urlopen(sys.argv[1], timeout=3)" \
       "http://127.0.0.1:$DASH_PORT/api" 2>/dev/null; then ok=1; break; fi
  sleep 1
done
if [ "$ok" = 1 ]; then
  echo "${c_g}$SERVICE работает${c_0} (python из $INSTALL_DIR/venv)"
else
  systemctl --no-pager -l status "$SERVICE" | tail -15
  die "$SERVICE не отвечает на порту $DASH_PORT"
fi
echo
echo "Адреса:"
for a in $(host_ips); do echo "  http://$a:$DASH_PORT/"; done
echo "Настройки: $cfg   Логи: journalctl -u $SERVICE"

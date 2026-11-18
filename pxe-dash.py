#!/usr/bin/env python3
"""web-dhcp (pxe-dash): веб-страница с клиентами DHCP-сети (аренды dnsmasq).

Показывает аренды dnsmasq, находит BMC/IPMI (IPMI ping на UDP 623), PXE-клиентов (vendor class PXEClient),
кто сейчас в сети (ARP), производителя по MAC, подписи; при желании - статус iVentoy.
Только stdlib python3 (>= 3.7). Настройки - .env рядом со скриптом (пишет start.sh, все ключи - в .env.example) или DASH_*.
"""
import html
import json
import logging
import os
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def load_conf():
    """.env (KEY=VALUE, # - комментарий) рядом со скриптом (старое имя - config.env);
    переменные окружения DASH_* важнее. Пустое значение = не задано."""
    conf = {}
    here = os.path.dirname(os.path.realpath(__file__))
    for path in ([os.environ["DASH_CONF"]] if os.environ.get("DASH_CONF") else
                 [os.path.join(here, ".env"), os.path.join(here, "config.env")]):
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        if v.strip():
                            conf[k.strip()] = v.strip()
            break
        except OSError:
            continue
    conf.update((k, v) for k, v in os.environ.items() if k.startswith("DASH_"))
    return conf


def setup_logging(level):
    """Уровень: ERROR / WARNING / INFO / DEBUG. Вывод - stderr (systemd пишет его в файл лога или журнал);
    в журнал - без времени, его journald ставит сам."""
    lvl = logging.getLevelName(str(level).strip().upper())
    fmt = "%(levelname)s %(message)s" if os.environ.get("JOURNAL_STREAM") else "%(asctime)s %(levelname)s %(message)s"
    logging.basicConfig(level=lvl if isinstance(lvl, int) else logging.INFO, format=fmt, datefmt="%Y-%m-%d %H:%M:%S")
    if not isinstance(lvl, int):
        logging.warning("DASH_LOG_LEVEL=%s - нет такого уровня (ERROR/WARNING/INFO/DEBUG), взят INFO", level)


C = load_conf()
setup_logging(C.get("DASH_LOG_LEVEL", "INFO"))
log = logging.getLogger("pxe-dash")
_warned = set()


def warn_once(key, msg, *args):
    """Предупреждение один раз на ключ (иначе - при каждом обновлении страницы)."""
    if key not in _warned:
        _warned.add(key)
        log.warning(msg, *args)


LISTEN = (C.get("DASH_BIND", "0.0.0.0"), int(C.get("DASH_PORT", "8080")))
IFACE = C.get("DASH_IFACE", "")                      # интерфейс DHCP-сети: по его ARP-таблице - «в сети»
LEASES = C.get("DASH_LEASES", "/var/lib/misc/dnsmasq.leases")
HOSTS_DIR = C.get("DASH_HOSTS_DIR", "/var/lib/web-dhcp/hosts")  # пишет pxe-dhcp-hook
TITLE = C.get("DASH_TITLE", "DHCP-клиенты")
SERVER_ADDR = C.get("DASH_SERVER_ADDR", "")          # показывается в шапке
IPMI_URL = C.get("DASH_IPMI_URL", "")                # ссылка «IPMI сервера» в шапке (пусто - нет)
IVENTOY_PORT = C.get("DASH_IVENTOY_PORT", "")        # порт iVentoy на этом сервере (пусто - блок iVentoy не показывать)
IVENTOY_API = "http://127.0.0.1:%s/iventoy/json" % IVENTOY_PORT
SHARE_URL = C.get("DASH_SHARE_URL", "")              # ссылка «Общая папка»; {host} - адрес, по которому открыта страница
SMB_PATH = C.get("DASH_SMB_PATH", "")                # путь Samba-шары для показа рядом со ссылкой
PROBE_INTERVAL = int(C.get("DASH_PROBE_INTERVAL", "60"))
# подписи строк (MAC -> текст); каталог создаёт systemd (StateDirectory=...)
LABELS = os.path.join(C.get("DASH_LABELS_DIR") or os.environ.get("STATE_DIRECTORY", "/var/lib/web-dhcp-labels"),
                      "labels.json")
labels_lock = threading.Lock()


def read_labels():
    try:
        with open(LABELS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as ex:
        warn_once("labels", "подписи не прочитать (%s): %s", LABELS, ex)
        return {}


def set_label(mac, text):
    mac = mac.lower().strip()
    if len(mac) != 17 or any(c not in "0123456789abcdef:" for c in mac):
        raise ValueError("bad mac")
    text = " ".join(str(text).split())[:100]
    with labels_lock:
        d = read_labels()
        old = d.get(mac, "")
        if text:
            d[mac] = text
        else:
            d.pop(mac, None)
        tmp = LABELS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
        os.replace(tmp, LABELS)
    if text != old:
        return old

# IPMI v1.5 Get Channel Authentication Capabilities (what "ipmitool ping" style tools send)
IPMI_PROBE = bytes.fromhex("0600ff07000000000000000000092018c88100388e04b5")

OUI_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oui.tsv")  # IEEE OUI: "XXXXXX<TAB>name"
# короткие имена для частых производителей (по началу официального названия)
SHORT = (("super micro", "Supermicro"), ("giga-byte", "Gigabyte"), ("dell", "Dell"),
         ("hewlett packard", "HPE"), ("inspur", "Inspur"), ("asustek", "ASUS"),
         ("micro-star", "MSI"), ("asrock", "ASRock"), ("intel", "Intel"), ("lenovo", "Lenovo"),
         ("huawei", "Huawei"), ("realtek", "Realtek"), ("broadcom", "Broadcom"),
         ("mellanox", "Mellanox"), ("tyan", "Tyan"), ("fujitsu", "Fujitsu"), ("cisco", "Cisco"))


def load_oui():
    oui = {}
    try:
        with open(OUI_FILE, encoding="utf-8", errors="replace") as f:
            for line in f:
                k, _, name = line.rstrip("\n").partition("\t")
                low = name.lower()
                oui[k.lower()] = next((v for p, v in SHORT if low.startswith(p)), name.strip())
    except OSError as ex:
        log.warning("база производителей не прочитана (%s): %s", OUI_FILE, ex)
    return oui


OUI = load_oui()

ipmi_cache = {}  # ip -> (is_bmc, checked_at)
iv_state = {"ok": None}  # iVentoy отвечал ли в прошлый раз - пишем в лог только перемены
lock = threading.Lock()


def probe_ipmi(ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    try:
        for _ in range(2):
            s.sendto(IPMI_PROBE, (ip, 623))
            try:
                data, _addr = s.recvfrom(512)
                if data[:4] == b"\x06\x00\xff\x07":
                    return True
            except socket.timeout:
                continue
        return False
    except OSError:
        return False
    finally:
        s.close()


def read_leases():
    leases = {}
    try:
        with open(LEASES) as f:
            for line in f:
                p = line.split()
                # a client can hold several leases: keep the newest one
                if len(p) >= 4 and int(p[0]) > leases.get(p[1].lower(), {}).get("expires", 0):
                    leases[p[1].lower()] = {"expires": int(p[0]), "ip": p[2],
                                            "hostname": "" if p[3] == "*" else p[3]}
    except FileNotFoundError:
        pass
    return leases


def read_hosts():
    hosts = {}
    try:
        names = os.listdir(HOSTS_DIR)
    except FileNotFoundError:
        return hosts
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(HOSTS_DIR, n)) as f:
                h = json.load(f)
            hosts[h["mac"].lower()] = h
        except Exception as ex:
            warn_once("host:" + n, "история клиента %s не прочитана: %s", os.path.join(HOSTS_DIR, n), ex)
            continue
    return hosts


def read_arp():
    arp = {}
    try:
        with open("/proc/net/arp") as f:
            next(f)
            for line in f:
                p = line.split()
                if len(p) >= 6 and (not IFACE or p[5] == IFACE) and p[2] == "0x2":
                    arp[p[0]] = p[3].lower()
    except OSError:
        pass
    return arp


def iventoy_status():
    out, err = {}, None
    for m in ("query_status", "get_dhcp_mode"):
        try:
            req = urllib.request.Request(IVENTOY_API, data=json.dumps({"method": m}).encode(),
                                         headers={"Content-Type": "application/json"})
            out.update(json.load(urllib.request.urlopen(req, timeout=2)))
        except Exception as ex:
            err = ex
    if (err is None) != iv_state["ok"]:
        if err is None:
            log.info("iVentoy (%s) отвечает", IVENTOY_API)
        else:
            log.warning("iVentoy (%s) не отвечает: %s", IVENTOY_API, err)
        iv_state["ok"] = err is None
    return out


def collect():
    leases, hosts, arp, labels = read_leases(), read_hosts(), read_arp(), read_labels()
    now = int(time.time())
    rows = []
    for mac in set(leases) | set(hosts):
        l, h = leases.get(mac, {}), hosts.get(mac, {})
        if not h and not (l and l["expires"] > now):
            continue  # forgotten by pxe-dash-prune, only a stale lease line is left
        ip = l.get("ip") or h.get("ip", "")
        vc = h.get("vendor_class", "")
        with lock:
            is_bmc = ipmi_cache.get(ip, (False, 0))[0]
        if is_bmc:
            kind = "BMC / IPMI"
        elif vc.startswith("PXEClient"):
            kind = "PXE boot"
        else:
            kind = "OS"  # DHCP-клиент без PXEClient (PXE-загрузчик всегда его шлёт)
        rows.append({
            "mac": mac, "label": labels.get(mac, ""), "ip": ip, "kind": kind, "vendor_class": vc,
            "hostname": l.get("hostname") or h.get("hostname") or h.get("supplied_hostname", ""),
            "vendor": OUI.get(mac.replace(":", "")[:6], ""),
            "online": arp.get(ip) == mac,
            "lease": "active" if l and l["expires"] > now else "expired",
            "expires": l.get("expires", 0), "last_seen": h.get("last_seen", 0),
            "first_seen": h.get("first_seen", 0),
        })
    rows.sort(key=lambda r: (r["kind"] != "BMC / IPMI", r["lease"] != "active",
                             tuple(int(x) for x in r["ip"].split(".")) if r["ip"] else ()))
    return rows


def prober():
    while True:
        ips = {r["ip"] for r in collect() if r["ip"] and r["lease"] == "active"}
        try:
            for ip in ips:
                res = probe_ipmi(ip)
                with lock:
                    was = ipmi_cache.get(ip, (None, 0))[0]
                    ipmi_cache[ip] = (res, time.time())
                if res and not was:
                    log.info("BMC/IPMI: %s отвечает на UDP 623", ip)
                elif was and not res:
                    log.info("BMC/IPMI: %s перестал отвечать на UDP 623", ip)
            log.debug("опрос IPMI: адресов %d, BMC %d", len(ips), sum(ipmi_cache[ip][0] for ip in ips))
        except Exception:
            log.exception("опрос IPMI")
        time.sleep(PROBE_INTERVAL)


def fmt_time(ts):
    return time.strftime("%d.%m %H:%M:%S", time.localtime(ts)) if ts else ""


PAGE = """<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<title>{title}</title>
<style>
body{{font-family:system-ui,sans-serif;margin:24px;background:#f6f7f9;color:#222}}
h1{{font-size:20px;margin:0 0 4px}}
.head{{display:flex;justify-content:space-between;align-items:baseline}} .srv{{font-size:15px}} .sub{{color:#666;margin-bottom:16px}}
table{{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px #0002}}
th,td{{padding:7px 10px;border-bottom:1px solid #e5e7eb;text-align:left;font-size:14px}}
th{{background:#eef0f3;font-weight:600}} tr.bmc td{{background:#fff8e6}}
.on{{color:#0a7d2c;font-weight:600}} .off{{color:#999}} .exp{{color:#999}}
.box{{display:inline-block;background:#fff;padding:8px 14px;margin:0 10px 14px 0;box-shadow:0 1px 3px #0002}}
code{{font-size:13px}}
td.lbl{{cursor:pointer;font-weight:600;min-width:90px}} td.lbl:hover{{background:#eaf2fb}}
td.lbl:empty::after{{content:"✎";color:#bbb;font-weight:normal}}
th.s{{cursor:pointer;user-select:none;white-space:nowrap}} th.s:hover{{background:#e2e6ec}}
th.s[data-dir="1"]::after{{content:" ▲"}} th.s[data-dir="-1"]::after{{content:" ▼"}}
.flt{{margin:0 0 10px;font-size:14px}} .flt label{{cursor:pointer}} .flt .cnt{{color:#666;margin-left:10px}}
</style></head><body>
<div class="head"><h1>{title}</h1>
<div class="srv">{srv}</div></div>
<div class="sub">Обновляется каждые 15 секунд. IPMI определяется опросом UDP 623 раз в минуту.</div>
{boxes}<div class="box">Аренд активно: <b>{active}</b>, BMC найдено: <b>{bmcs}</b></div>
<div class="flt"><label><input type="checkbox" id="onlyon"> Только те, что в сети</label><span class="cnt" id="cnt"></span>
<span class="cnt">Сортировка — щелчок по заголовку столбца (ещё раз — в обратную сторону, третий — как было).</span></div>
<table id="t"><thead><tr><th class="s" title="Щелчок по ячейке - изменить подпись">Имя</th><th class="s">Тип</th><th class="s">IP</th><th class="s">MAC</th><th class="s">Производитель</th><th class="s">Hostname</th>
<th class="s">Vendor class</th><th class="s">В сети</th><th class="s">Аренда до</th><th class="s">Последний запрос</th><th class="s">Впервые</th></tr></thead>
<tbody>{rows}</tbody></table>
<script>
let editing = false;
document.querySelectorAll("td.lbl").forEach(td => td.onclick = async () => {{
  editing = true;
  const v = prompt("Подпись для " + td.dataset.mac + " (пусто - убрать):", td.textContent);
  if (v !== null) {{
    const r = await fetch("/api/label", {{method: "POST", headers: {{"Content-Type": "application/json"}},
                                         body: JSON.stringify({{mac: td.dataset.mac, label: v}})}});
    if (r.ok) td.textContent = v.trim().replace(/\\s+/g, " "); else alert("Не сохранилось: HTTP " + r.status);
  }}
  editing = false;
}});
// сортировка и фильтр; состояние в localStorage, чтобы пережить автообновление
const tb = document.querySelector("#t tbody"), ths = [...document.querySelectorAll("#t th.s")];
const orig = [...tb.rows];
const st = JSON.parse(localStorage.getItem("pxeView") || "{{}}");
if (st.onlyOn === undefined) st.onlyOn = true;
const coll = new Intl.Collator("ru", {{numeric: true, sensitivity: "base"}});
const key = (tr, i) => {{ const c = tr.cells[i]; return c ? (c.dataset.v !== undefined ? c.dataset.v : c.textContent.trim()) : ""; }};
function render() {{
  localStorage.setItem("pxeView", JSON.stringify(st));
  ths.forEach((th, i) => th.dataset.dir = i === st.col ? st.dir : "");
  let rows = orig.slice();
  if (st.col !== undefined && st.dir) {{
    rows.sort((a, b) => {{
      const x = key(a, st.col), y = key(b, st.col);
      if (x === "" || y === "") return (x === "") - (y === "");  // пустые всегда внизу
      const nx = Number(x), ny = Number(y);
      const r = (!isNaN(nx) && !isNaN(ny)) ? nx - ny : coll.compare(x, y);
      return r * st.dir;
    }});
  }}
  let shown = 0;
  rows.forEach(tr => {{
    const hide = st.onlyOn && tr.dataset.on === "0";
    tr.style.display = hide ? "none" : "";
    if (!hide && tr.dataset.on !== undefined) shown++;
    tb.appendChild(tr);
  }});
  const total = orig.filter(tr => tr.dataset.on !== undefined).length;
  document.getElementById("cnt").textContent = "показано " + shown + " из " + total;
}}
ths.forEach((th, i) => th.onclick = () => {{
  if (st.col !== i) {{ st.col = i; st.dir = 1; }}
  else if (st.dir === 1) st.dir = -1;
  else {{ delete st.col; delete st.dir; }}
  render();
}});
const cb = document.getElementById("onlyon");
cb.checked = st.onlyOn;
cb.onchange = () => {{ st.onlyOn = cb.checked; render(); }};
render();
setInterval(() => {{ if (!editing) location.reload(); }}, 15000);
</script></body></html>"""

DHCP_MODES = {0: "Internal", 1: "External", 2: "ExternalNet", 3: "Proxy", 4: "ProxyNet"}


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # обрыв соединения клиентом - не ошибка
        ex = sys.exc_info()[1]
        if isinstance(ex, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            log.debug("%s: соединение оборвано: %s", client_address[0], ex)
        else:
            log.exception("%s: ошибка при обработке запроса", client_address[0])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        log.debug("%s %s", self.client_address[0], fmt % a)

    def do_POST(self):
        if self.path != "/api/label":
            self.send_error(404)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 4096:
                raise ValueError("too big")
            d = json.loads(self.rfile.read(n) or b"{}")
            old = set_label(d.get("mac", ""), d.get("label", ""))
            if old is not None:
                log.info("%s: подпись %s: «%s» -> «%s»", self.client_address[0], str(d.get("mac", "")).lower().strip(),
                         old, " ".join(str(d.get("label", "")).split())[:100])
            code, body = 200, b'{"ok": true}'
        except Exception as ex:
            log.warning("%s: подпись не сохранена: %s", self.client_address[0], ex)
            code, body = 400, json.dumps({"error": str(ex)}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        rows = collect()
        if self.path.startswith("/api"):
            body = json.dumps(rows, ensure_ascii=False).encode()
            ctype = "application/json"
        elif self.path in ("/", "/index.html"):
            iv = iventoy_status() if IVENTOY_PORT else {}
            trs = []
            for r in rows:
                e = html.escape
                ip = e(r["ip"])
                if r["kind"] == "BMC / IPMI":
                    ip = '<a href="https://%s/" target="_blank" rel="noopener">%s</a>' % (ip, ip)
                ipv = "".join("%03d" % int(x) for x in r["ip"].split(".")) if r["ip"] else ""
                tv = lambda t: str(t) if t else ""
                trs.append(
                    '<tr class="%s" data-on="%d"><td class="lbl" data-mac="%s">%s</td><td>%s</td><td data-v="%s">%s</td><td><code>%s</code></td><td>%s</td><td>%s</td>'
                    '<td>%s</td><td class="%s" data-v="%d">%s</td><td class="%s" data-v="%s">%s</td><td data-v="%s">%s</td><td data-v="%s">%s</td></tr>' % (
                        "bmc" if r["kind"] == "BMC / IPMI" else "", 1 if r["online"] else 0,
                        e(r["mac"]), e(r["label"]), e(r["kind"]), ipv, ip, e(r["mac"]),
                        e(r["vendor"]), e(r["hostname"]), e(r["vendor_class"]),
                        "on" if r["online"] else "off", 1 if r["online"] else 0, "да" if r["online"] else "нет",
                        "" if r["lease"] == "active" else "exp", tv(r["expires"]), fmt_time(r["expires"]),
                        tv(r["last_seen"]), fmt_time(r["last_seen"]), tv(r["first_seen"]), fmt_time(r["first_seen"])))
            e = html.escape
            host = self.headers.get("Host", "").rsplit(":", 1)[0].strip("[]") or SERVER_ADDR or "127.0.0.1"
            srv = []
            if SERVER_ADDR:
                srv.append("Сервер: <b>%s</b>" % e(SERVER_ADDR))
            if IPMI_URL:
                ipmi_name = urllib.parse.urlsplit(IPMI_URL).hostname or IPMI_URL
                srv.append('IPMI сервера: <a href="%s" target="_blank" rel="noopener"><b>%s</b></a>' % (e(IPMI_URL), e(ipmi_name)))
            boxes = ""
            if IVENTOY_PORT:
                boxes += ('<div class="box">iVentoy: <b>%s</b>, режим DHCP: <b>%s</b> &nbsp;\n'
                          '<a href="http://%s:%s/" target="_blank" rel="noopener">веб-интерфейс iVentoy</a></div>\n') % (
                    e(str(iv.get("status", "нет ответа"))), DHCP_MODES.get(iv.get("dhcp_mode"), "?"), e(host), e(IVENTOY_PORT))
            if SHARE_URL or SMB_PATH:
                boxes += '<div class="box">%s%s</div>\n' % (
                    '<a href="%s" target="_blank" rel="noopener">Общая папка</a>' % e(SHARE_URL.replace("{host}", host)) if SHARE_URL else "Общая папка",
                    ": <code>%s</code>" % e(SMB_PATH) if SMB_PATH else "")
            body = PAGE.format(
                title=e(TITLE), srv=" &nbsp;&nbsp; ".join(srv), boxes=boxes,
                active=sum(r["lease"] == "active" for r in rows),
                bmcs=sum(r["kind"] == "BMC / IPMI" for r in rows),
                rows="\n".join(trs) or '<tr><td colspan="11">Пока нет ни одной аренды</td></tr>',
            ).encode()
            ctype = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    log.info("запуск: %s:%d, интерфейс %s, аренды %s, история %s, уровень лога %s", LISTEN[0], LISTEN[1],
             IFACE or "все", LEASES, HOSTS_DIR, logging.getLevelName(logging.getLogger().level))
    threading.Thread(target=prober, daemon=True).start()
    Server(LISTEN, Handler).serve_forever()

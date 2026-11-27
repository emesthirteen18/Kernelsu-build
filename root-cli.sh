#!/data/data/com.termux/files/usr/bin/bash
set -o pipefail
export RISH_APPLICATION_ID="${RISH_APPLICATION_ID:-com.termux}"
DEPLOY_DIR="$HOME/ksu_deploy_new"

cmd_help() {
    cat <<'USAGE'
Usage: root [command]

Commands:
  (none)          Run hardened deploy.sh (loads root, recovers network, refreshes ReSukiSU)
  status | check  Show live KernelSU, su, SELinux, ReSukiSU, modules, network, watchdog & bridge status
  modules         List installed KernelSU modules
  refresh         Refresh ksud marks and force-stop ReSukiSU so it opens with live status
  net             Run net-recover.sh on demand and show live network status
  verify          Verify file checksums (sha256sums.txt), script syntax, and zero setenforce calls
  logs            Show recent tails of deploy.log, block_a.log, and root-helper.log
  dry-run         Run deploy.sh pre-flight checks without staging or loading
  help            Show this help message
USAGE
}

cmd_status() {
    echo "=== Root & Device Health ($(date '+%Y-%m-%d %H:%M:%S %Z')) ==="
    echo "Kernel:    $(uname -r)"
    echo "Uptime:    $(uptime -p 2>/dev/null || uptime)"
    if pgrep -f "termux-bridge" >/dev/null 2>&1 && pgrep -x "cloudflared" >/dev/null 2>&1; then
        echo "Bridge:    running (termux-bridge + cloudflared)"
    else
        echo "Bridge:    stopped"
    fi
    RISH_CHK="$(timeout -k 2 10 rish -c 'echo ok' </dev/null 2>/dev/null | tr -d '\r\n' || true)"
if [ "$RISH_CHK" != "ok" ]; then
        echo "Shizuku:   NOT RESPONDING"
        return 1
    fi
    echo "Shizuku:   ok"
    timeout -k 3 15 rish -c '
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
if [ -d /sys/module/kernelsu ] || lsmod 2>/dev/null | grep -q "^kernelsu"; then
    echo "KernelSU:  loaded"
else
    echo "KernelSU:  NOT loaded"
fi
SU_OUT="$(su -c id 2>/dev/null | head -n1)"
echo "su:        ${SU_OUT:-unavailable}"
SE_OUT="$(su -c getenforce 2>/dev/null || getenforce 2>/dev/null)"
echo "SELinux:   ${SE_OUT:-unknown}"
PKG="com.resukisu.resukisu"
MGR_PID="$(pidof "$PKG" 2>/dev/null || true)"
if [ -n "$MGR_PID" ]; then
    echo "ReSukiSU:  running (PID $MGR_PID)"
else
    echo "ReSukiSU:  not running (will open fresh)"
fi
if [ -x /data/local/tmp/ksud ]; then
    MOD_CNT="$(su -c "/data/local/tmp/ksud module list" 2>/dev/null | grep -c "\"id\":" || true)"
    echo "Modules:   ${MOD_CNT:-0} installed"
fi
NET_DEV="$(ip route get 1.1.1.1 2>/dev/null | sed -n "s/.* dev \([^ ]*\).*/\1/p" | head -n1)"
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    echo "Network:   online (${NET_DEV:-active})"
else
    echo "Network:   offline (${NET_DEV:-no route})"
fi
WPID="$(cat /data/local/tmp/net-watchdog.pid 2>/dev/null || true)"
if [ -n "$WPID" ] && [ -d "/proc/$WPID" ]; then
    echo "Watchdog:  running (PID $WPID)"
else
    echo "Watchdog:  not running"
fi
' 2>/dev/null
}

cmd_modules() {
    timeout -k 3 15 rish -c '
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
su -c "/data/local/tmp/ksud module list" 2>/dev/null
' 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("No modules returned (is KernelSU loaded?)")
    sys.exit(1)
try:
    mods = json.loads(raw)
except Exception as e:
    print(raw)
    sys.exit(0)
if not mods:
    print("No KernelSU modules installed.")
    sys.exit(0)
for m in mods:
    state = "enabled" if str(m.get("enabled")).lower() == "true" else "disabled"
    name = m.get("name") or m.get("id") or "?"
    ver = m.get("version") or "?"
    print(f"- {name} ({ver}) [{state}]")
'
}

cmd_refresh() {
    timeout -k 3 15 rish -c '
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
su -c "/data/local/tmp/ksud debug mark refresh" >/dev/null 2>&1 || true
am force-stop com.resukisu.resukisu 2>/dev/null || true
echo "[+] Refreshed ksud marks and force-stopped com.resukisu.resukisu."
' 2>/dev/null
}

cmd_net() {
    timeout -k 5 50 rish -c '
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
if [ -x /data/local/tmp/net-recover.sh ]; then
    /data/local/tmp/net-recover.sh
else
    echo "[-] /data/local/tmp/net-recover.sh not staged yet."
    exit 1
fi
NET_DEV="$(ip route get 1.1.1.1 2>/dev/null | sed -n "s/.* dev \([^ ]*\).*/\1/p" | head -n1)"
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    echo "[+] Network online (${NET_DEV:-active})"
else
    echo "[-] Network offline (${NET_DEV:-no route})"
fi
' 2>/dev/null
}

cmd_verify() {
    cd "$DEPLOY_DIR" || exit 1
    echo "=== Verifying $DEPLOY_DIR ==="
    bash -n "$DEPLOY_DIR/deploy.sh" && echo "[+] deploy.sh syntax: OK"
    bash -n "$0" && echo "[+] root CLI syntax: OK"
    SE_CNT="$(grep -c 'setenforce' "$DEPLOY_DIR/deploy.sh" || true)"
    if [ "$SE_CNT" -eq 0 ]; then
        echo "[+] setenforce count in deploy.sh: 0 (safe)"
    else
        echo "[-] WARNING: setenforce count in deploy.sh is $SE_CNT!"
        return 1
    fi
    if [ -f "$DEPLOY_DIR/sha256sums.txt" ]; then
        sha256sum -c "$DEPLOY_DIR/sha256sums.txt"
    else
        echo "[!] No sha256sums.txt found."
    fi
}

cmd_logs() {
    echo "=== Last 20 lines: $DEPLOY_DIR/deploy.log ==="
    tail -n 20 "$DEPLOY_DIR/deploy.log" 2>/dev/null || echo "(none)"
    echo "=== Last 20 lines: $DEPLOY_DIR/block_a.log ==="
    tail -n 20 "$DEPLOY_DIR/block_a.log" 2>/dev/null || echo "(none)"
    echo "=== Last 15 lines: /data/local/tmp/root-helper.log ==="
    timeout -k 2 8 rish -c 'tail -n 15 /data/local/tmp/root-helper.log 2>/dev/null || echo "(none)"' 2>/dev/null || true
}

case "${1:-}" in
    ""|--*)
        cd "$DEPLOY_DIR" || exit 1
        exec ./deploy.sh "$@"
        ;;
    status|check)
        cmd_status
        ;;
    modules|mods)
        cmd_modules
        ;;
    refresh)
        cmd_refresh
        ;;
    net|network)
        cmd_net
        ;;
    verify)
        cmd_verify
        ;;
    logs|log)
        cmd_logs
        ;;
    dry-run)
        cd "$DEPLOY_DIR" || exit 1
        exec ./deploy.sh --dry-run
        ;;
    help|-h|--help)
        cmd_help
        ;;
    *)
        echo "Unknown command: $1" >&2
        cmd_help
        exit 2
        ;;
esac

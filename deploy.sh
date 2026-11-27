#!/data/data/com.termux/files/usr/bin/bash
set -o pipefail
cd "$(dirname "$0")" || exit 1
DEPLOY_DIR="$PWD"
# Termux rish needs this or staging fails with "RISH_APPLICATION_ID is not set"
export RISH_APPLICATION_ID="${RISH_APPLICATION_ID:-com.termux}"

DRY_RUN=0
SKIP_VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-verify) SKIP_VERIFY=1 ;;
        -h|--help)
            echo "Usage: deploy.sh [--dry-run] [--skip-verify]"
            exit 0
            ;;
        *)
            echo "[!] Unknown option: $arg (use --dry-run or --skip-verify)" >&2
            exit 2
            ;;
    esac
done

# [HARDENING] Timestamped run log with automatic rotation (keep newest 10)
LOG_DIR="$DEPLOY_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
RUN_LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
if [ "$DRY_RUN" -eq 0 ]; then
    ls -1t "$LOG_DIR"/deploy-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f 2>/dev/null || true
    exec > >(tee -a "$RUN_LOG" "$DEPLOY_DIR/deploy.log") 2>&1
    echo "=== deploy.sh started $(date) (kernel: $(uname -r)) ==="
fi

# [HARDENING] Atomic concurrency lock so two root runs cannot collide
LOCK_DIR="$DEPLOY_DIR/.deploy.lock"
LOCK_ACQUIRED=0
WAKELOCK_ACQUIRED=0

cleanup_deploy() {
    local rc=$?
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    if [ "$WAKELOCK_ACQUIRED" -eq 1 ]; then
        termux-wake-unlock 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup_deploy EXIT INT TERM

if [ "$DRY_RUN" -eq 0 ]; then
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        LOCK_ACQUIRED=1
    else
        OLD_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "[-] Another deploy.sh run is already active (PID $OLD_PID). Exiting." >&2
            exit 1
        fi
        echo "[!] Clearing stale lock (PID ${OLD_PID:-unknown})."
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" && echo "$$" > "$LOCK_DIR/pid" && LOCK_ACQUIRED=1
    fi
    if command -v termux-wake-lock >/dev/null 2>&1; then
        termux-wake-lock 2>/dev/null && WAKELOCK_ACQUIRED=1 || true
    fi
fi

# [HARDENING] Pre-flight checks (required files, SHA-256 manifest, kernel check, Shizuku check)
echo "[*] Running pre-flight checks..."
MISSING=0
for req in kernelsu.ko stock.ko patch_final.py gen_allowlist.py e-r20 spray ksud; do
    if [ ! -s "$DEPLOY_DIR/$req" ]; then
        echo "[-] Missing or empty required file: $DEPLOY_DIR/$req" >&2
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo "[-] Pre-flight failed: required deploy files are missing." >&2
    exit 1
fi

KREL="$(uname -r 2>/dev/null || true)"
case "$KREL" in
    6.6.127*) echo "[+] Kernel verified: $KREL" ;;
    *) echo "[!] Warning: unexpected kernel '$KREL' (expected 6.6.127*)." ;;
esac

if [ "$SKIP_VERIFY" -eq 0 ] && [ -f "$DEPLOY_DIR/sha256sums.txt" ]; then
    if sha256sum -c "$DEPLOY_DIR/sha256sums.txt" >/dev/null 2>&1; then
        echo "[+] Integrity check passed (sha256sums.txt)."
    else
        echo "[-] Integrity check FAILED for sha256sums.txt! Run 'root verify' for details or pass --skip-verify." >&2
        sha256sum -c "$DEPLOY_DIR/sha256sums.txt" 2>&1 | grep -v ': OK$' || true
        exit 1
    fi
fi

if ! timeout -k 2 10 rish -c 'echo ok' 2>/dev/null | grep -q '^ok$'; then
    echo "[-] Shizuku (rish) is not responding. Start Shizuku and retry." >&2
    exit 1
fi
echo "[+] Shizuku (rish) responsive."

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[+] Dry-run pre-flight passed (no files staged, no kernel changes)."
    exit 0
fi

echo "[*] Staging files to /data/local/tmp via rish..."
rish -c "mkdir -p /data/local/tmp/a"
cat kernelsu.ko     | rish -c 'cat > /data/local/tmp/kernelsu_base.ko'
cat stock.ko        | rish -c 'cat > /data/local/tmp/stock.ko'
cat patch_final.py  | rish -c 'cat > /data/local/tmp/patch_final.py'
cat gen_allowlist.py| rish -c 'cat > /data/local/tmp/gen_allowlist.py'
cat e-r20           | rish -c 'cat > /data/local/tmp/e-r20'
cat spray           | rish -c 'cat > /data/local/tmp/spray'
[ -f ksud ] && cat ksud | rish -c 'cat > /data/local/tmp/ksud && chmod 755 /data/local/tmp/ksud'
# [BOX-PATCH] Stage net-recover/net-watchdog (upstream BLOCK A + helper reference these
# at /data/local/tmp but never stage them). Logging/recovery only; no insmod-order change.
[ -f net-recover.sh ]  && cat net-recover.sh  | rish -c 'cat > /data/local/tmp/net-recover.sh && chmod 755 /data/local/tmp/net-recover.sh'
[ -f net-watchdog.sh ] && cat net-watchdog.sh | rish -c 'cat > /data/local/tmp/net-watchdog.sh && chmod 755 /data/local/tmp/net-watchdog.sh'
rish -c "chmod 755 /data/local/tmp/e-r20 /data/local/tmp/spray"

# [BOX-PATCH] Pre-compute ALLOW_ARGS / PKG / MGR_UID via rish BEFORE insmod.
# After insmod the kernel-domain helper has been observed to lose /system/bin/stat
# and pm, which dropped Termux and ReSukiSU from the allowlist and late-load args.
cat << 'PRECOMPUTE_SH' | rish -c 'cat > /data/local/tmp/ksu-precompute.sh && chmod 755 /data/local/tmp/ksu-precompute.sh && sh /data/local/tmp/ksu-precompute.sh'
#!/system/bin/sh
ALLOW_ARGS=""
for pkg in \
  com.termux \
  com.resukisu.resukisu \
  moe.shizuku.privileged.api \
  com.polygraphene.df.installer \
  com.polygraphene.df.reroot \
  com.rosan.dhizuku \
  com.android.shell \
  foss.chillastro.root.checker.offline \
  com.softwarebakery.drivedroid \
  io.github.capitan0n.droynis \
  com.hijacker \
  su.sniff.cepter \
  com.alexisgordr.icdetector \
  com.merxury.blocker \
  com.werismoln.multibooter \
  io.github.sloppytopp.n0rma \
  com.machiav3lli.fdroid \
  app.fayaz.otgmaster \
  com.emanuelef.remote_capture \
  com.pcapdroid.mitm \
  com.repairdeck.fixit \
  se.norenh.rkfread \
  org.sharkdroid \
  org.simlar \
  de.srlabs.snoopsnitch \
  com.termux.gui \
  com.termux.boot \
  com.termux.api \
  com.valhalla.thor \
  eu.darken.sdmse \
  io.github.nongfsq.usbdebugguard \
  app.pwhs.universalinstaller
do
  if [ "$pkg" = "com.android.shell" ]; then
    uid=2000
  else
    uid=$(stat -c '%u' "/data/user/0/$pkg" 2>/dev/null || true)
    if [ -z "$uid" ]; then
      uid=$(pm list packages -U "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' | head -n1)
    fi
  fi
  if [ -n "$uid" ]; then
    ALLOW_ARGS="$ALLOW_ARGS $pkg:$uid"
  fi
done
PKG=$(pm list packages 2>/dev/null | tr -d '\r' | grep -E 'com\.resukisu\.resukisu|org\.bakasu\.bakasu' | head -n1 | cut -d: -f2)
MGR_UID=""
if [ -n "$PKG" ]; then
  MGR_UID=$(stat -c '%u' "/data/user/0/$PKG" 2>/dev/null || true)
  if [ -z "$MGR_UID" ]; then
    MGR_UID=$(pm list packages -U "$PKG" 2>/dev/null | tr -d '\r' | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' | head -n1)
  fi
fi
umask 022
{
  echo "ALLOW_ARGS='$ALLOW_ARGS'"
  echo "PKG='$PKG'"
  echo "MGR_UID='$MGR_UID'"
} > /data/local/tmp/ksu-precomputed.env
chmod 644 /data/local/tmp/ksu-precomputed.env
echo "[*] precomputed ALLOW_ARGS=$ALLOW_ARGS"
echo "[*] precomputed PKG=$PKG MGR_UID=$MGR_UID"
PRECOMPUTE_SH

cat > r20-root.sh << 'INNER_ROOT_SH'
#!/system/bin/sh
exec >>/data/local/tmp/root-helper.log 2>&1
set -x
id
echo 0 > /proc/sys/kernel/kptr_restrict
cat /proc/kallsyms > /data/local/tmp/kallsyms.txt
/data/data/com.termux/files/usr/bin/python3 /data/local/tmp/patch_final.py

# Load rish-precomputed allowlist/manager IDs, with a pre-insmod fallback
# while /system/bin/stat and pm still work.
ALLOW_ARGS=""
PKG=""
MGR_UID=""
if [ -f /data/local/tmp/ksu-precomputed.env ]; then
  . /data/local/tmp/ksu-precomputed.env
fi
if [ -z "$ALLOW_ARGS" ]; then
  for pkg in \
    com.termux \
    com.resukisu.resukisu \
    moe.shizuku.privileged.api \
    com.polygraphene.df.installer \
    com.polygraphene.df.reroot \
    com.rosan.dhizuku \
    com.android.shell \
    foss.chillastro.root.checker.offline \
    com.softwarebakery.drivedroid \
    io.github.capitan0n.droynis \
    com.hijacker \
    su.sniff.cepter \
    com.alexisgordr.icdetector \
    com.merxury.blocker \
    com.werismoln.multibooter \
    io.github.sloppytopp.n0rma \
    com.machiav3lli.fdroid \
    app.fayaz.otgmaster \
    com.emanuelef.remote_capture \
    com.pcapdroid.mitm \
    com.repairdeck.fixit \
    se.norenh.rkfread \
    org.sharkdroid \
    org.simlar \
    de.srlabs.snoopsnitch \
    com.termux.gui \
    com.termux.boot \
    com.termux.api \
    com.valhalla.thor \
    eu.darken.sdmse \
    io.github.nongfsq.usbdebugguard \
    app.pwhs.universalinstaller
  do
    if [ "$pkg" = "com.android.shell" ]; then
      uid=2000
    else
      uid=$(stat -c '%u' "/data/user/0/$pkg" 2>/dev/null || true)
    fi
    if [ -n "$uid" ]; then
      ALLOW_ARGS="$ALLOW_ARGS $pkg:$uid"
    fi
  done
fi
if [ -z "$PKG" ]; then
  PKG=$(pm list packages 2>/dev/null | grep -E 'com\.resukisu\.resukisu|org\.bakasu\.bakasu' | head -n1 | cut -d: -f2)
fi
if [ -z "$MGR_UID" ] && [ -n "$PKG" ]; then
  MGR_UID=$(stat -c '%u' "/data/user/0/$PKG" 2>/dev/null || true)
fi
mkdir -p /data/adb/ksu 2>/dev/null || true
if [ -f /data/adb/ksu/.allowlist.good ]; then
  cp -f /data/adb/ksu/.allowlist.good /data/adb/ksu/.allowlist
elif [ -n "$ALLOW_ARGS" ]; then
  /data/data/com.termux/files/usr/bin/python3 /data/local/tmp/gen_allowlist.py /data/adb/ksu/.allowlist $ALLOW_ARGS
fi
echo "[*] pre-insmod ALLOW_ARGS=$ALLOW_ARGS PKG=$PKG MGR_UID=$MGR_UID"

# Truncate/recreate the log BEFORE redirecting. Unlinking net-qa.log after
# exec >>"$LOG" sends every later line to a deleted inode.
LOG=/data/local/tmp/net-qa.log
/system/bin/rm -f /data/local/tmp/net-qa.log /data/local/tmp/.ghostlock_ksu.status 2>/dev/null || true
exec >>"$LOG" 2>&1
(
        # Isolate transition+insmod so parent exec_sid is never set
        # Do not rm net-qa.log in here.
# --- BEGIN PRE-EXIT BLOCK B ---
timeout 2 /system/bin/chmod 0755 /data/local/tmp/net-recover.sh /data/local/tmp/net-watchdog.sh 2>/dev/null || true
timeout 2 /system/bin/rm -f /data/local/tmp/net-recover.log 2>/dev/null || true
echo "" > /proc/self/attr/exec 2>/dev/null || true
# --- END PRE-EXIT BLOCK B ---
/system/bin/sh -c '
    echo u:r:vendor_modprobe:s0 > /proc/self/attr/exec
    exec /system/bin/insmod /data/local/tmp/kernelsu_patched.ko allow_shell=1
'
rc=$?
echo "" > /proc/self/attr/exec 2>/dev/null || true
echo "[*] insmod rc=$rc"
[ "$rc" -eq 0 ] || exit "$rc"
)
rc=$?
echo "[*] insmod rc=$rc"
[ "$rc" -eq 0 ] || exit "$rc"
echo "=== POST-INSMOD $(date) ==="
echo "uid=$(id -u) context=$(cat /proc/self/attr/current 2>/dev/null)"
for p in netd wpa_supplicant rild qcrild; do echo -n "$p:"; pidof $p || echo MISSING; done
timeout 5 dmesg | tail -n 100 || true
timeout 5 ip link show || true
timeout 5 ip addr show || true
timeout 5 getprop | grep -E 'net\.|dns|ril|init' || true
echo "=== END ==="

# Apply manager UID now that the sysfs node exists; ksud late-load uses PKG
# resolved before insmod. Radio recovery is left to net-recover.sh (Block A).
if [ -n "$PKG" ] && [ -e /sys/module/kernelsu/parameters/ksu_debug_manager_appid ]; then
  [ -n "$MGR_UID" ] && echo "$MGR_UID" > /sys/module/kernelsu/parameters/ksu_debug_manager_appid
fi

/data/local/tmp/ksud late-load --allow-shell --package-name "$PKG" --kmi android15-6.6
/data/local/tmp/ksud debug mark refresh || true

dmesg | tail -n 20
chmod 644 /data/local/tmp/root-helper.log
# Make logs readable by shell
/system/bin/chmod 0644 /data/local/tmp/net-qa.log /data/local/tmp/root-helper.log /data/local/tmp/.ghostlock_ksu.status 2>/dev/null || true
/system/bin/sync
echo ready > /data/local/tmp/.ksu_deploy_done
chmod 0644 /data/local/tmp/.ksu_deploy_done 2>/dev/null || true
echo ready > /data/local/tmp/.ghostlock_ksu.status


# Persistent logs
cp /data/local/tmp/root-helper.log /sdcard/root-helper.log 2>/dev/null || true
cp /data/local/tmp/net-qa.log /sdcard/net-qa.log 2>/dev/null || true
cp /data/local/tmp/root-helper.log /sdcard/root-helper.log 2>/dev/null || true
cp /data/local/tmp/net-qa.log /sdcard/net-qa.log 2>/dev/null || true
INNER_ROOT_SH
cat r20-root.sh | rish -c 'cat > /data/local/tmp/a/r20-root.sh'
rish -c "chmod 755 /data/local/tmp/a/r20-root.sh"

# Success means the kernelsu module is loaded in the kernel (or our persistent
# post-helper marker exists). Do NOT require `su` here because Block A creates
# /data/local/tmp/su and sets PATH after this loop finishes.
ksu_is_ready() {
    timeout -k 2 10 rish -c '
        if [ -d /sys/module/kernelsu ] || lsmod 2>/dev/null | grep -q "^kernelsu" || [ -f /data/local/tmp/.ksu_deploy_done ]; then
            exit 0
        fi
        exit 1
    ' >/dev/null 2>&1
}

# e-r20 can print "[+] KernelSU module is loaded" and still not exit,
# because leftover exploit threads keep the process (and therefore rish)
# alive. deploy.sh must not wait on rish returning.
stop_pid_tree() {
    local sig="${1:--TERM}"
    local pid="$2"
    local child
    [ -n "$pid" ] || return 0
    [ -d "/proc/$pid" ] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "$pid" 2>/dev/null || true); do
            stop_pid_tree "$sig" "$child"
        done
    fi
    kill "$sig" "$pid" 2>/dev/null || true
}

stop_er20() {
    local pid="$1"
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        echo "[*] e-r20/rish still running after helper ready; stopping it so deploy.sh can exit."
        stop_pid_tree -TERM "$pid"
        command -v pkill >/dev/null 2>&1 && pkill -TERM -f '/data/local/tmp/e-r20' 2>/dev/null || true
        sleep 1
        stop_pid_tree -KILL "$pid"
        command -v pkill >/dev/null 2>&1 && pkill -KILL -f '/data/local/tmp/e-r20' 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

echo "[*] Starting execution loop..."

if ksu_is_ready; then
    echo "[+] KernelSU is already loaded and ready; skipping exploit loop."
else
    ATTEMPT=0
    MAX_ATTEMPTS=8
    READY=0
    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "=== NEW ATTEMPT ${ATTEMPT}/${MAX_ATTEMPTS} $(date) ==="

        # Bound the wait (-k so a SIGTERM-ignoring rish cannot hang us).
        timeout -k 10 180 rish -c 'cd /data/local/tmp && ./e-r20' &
        ER20_PID=$!

        # Do not poll rish during the initial ~25s run so we do not contend
        # with the loader; just check if the process exited cleanly every 2s.
        elapsed=0
        while [ "$elapsed" -lt 180 ]; do
            if ! kill -0 "$ER20_PID" 2>/dev/null; then
                wait "$ER20_PID" 2>/dev/null || true
                sleep 2
                if ksu_is_ready; then
                    echo "[+] KernelSU module is loaded and su uid=0 verified."
                    READY=1
                else
                    echo "[!] Loader exited before KernelSU became ready."
                fi
                break
            fi
            if [ "$elapsed" -ge 26 ] && [ $((elapsed % 6)) -eq 0 ]; then
                if ksu_is_ready; then
                    echo "[+] KernelSU module is loaded and su uid=0 verified."
                    stop_er20 "$ER20_PID"
                    READY=1
                    break
                fi
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done

        if [ "$READY" -eq 1 ]; then
            break
        fi

        if kill -0 "$ER20_PID" 2>/dev/null; then
            echo "[!] Timed out waiting for helper ready; stopping e-r20/rish."
            stop_er20 "$ER20_PID"
        fi
        if ksu_is_ready; then
            echo "[+] KernelSU module is loaded and helper is ready."
            READY=1
            break
        fi
        echo "[!] Not ready yet; retrying..."
        sleep 10
    done

    if [ "$READY" -ne 1 ]; then
        echo "[-] KernelSU did not become ready after ${MAX_ATTEMPTS} attempts." >&2
        exit 1
    fi
fi

# --- BLOCK A: Post-Load Recovery (Timeout-Wrapped rish) ---
LOG_FILE="/data/data/com.termux/files/home/ksu_deploy_new/block_a.log"
echo "[*] Executing post-load Block A... (Logs: $LOG_FILE)"

# timeout -k is required: GNU timeout without -k sends SIGTERM and then
# waits forever if rish ignores it.
timeout -k 5 60 rish -c '
echo "=== BLOCK A START $(date) ==="
touch /data/local/tmp/su && chmod 755 /data/local/tmp/su
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
cd /data/local/tmp || { echo "FATAL: cd failed"; exit 1; }
timeout -k 5 45 /data/local/tmp/net-recover.sh
echo "[-] net-recover.sh rc=$?"
WPID="$(timeout -k 1 2 cat /data/local/tmp/net-watchdog.pid 2>/dev/null)"
if [ -z "$WPID" ] || ! [ -d "/proc/$WPID" ]; then
    nohup setsid /data/local/tmp/net-watchdog.sh </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
fi
echo "[+] Block A complete."
echo "=== BLOCK A END ==="
' > "$LOG_FILE" 2>&1 || true

echo "[*] Block A returned cleanly (via timeout or completion)."

# [BOX-PATCH] Refresh manager app after root + network recovery so it never shows
# a stale pre-root "Not installed" screen, and print a live root + network summary.
timeout -k 5 20 rish -c '
PKG="com.resukisu.resukisu"
[ -f /data/local/tmp/ksu-precompute.env ] && . /data/local/tmp/ksu-precompute.env 2>/dev/null || true
if [ -n "$PKG" ]; then
    am force-stop "$PKG" 2>/dev/null || true
    echo "[+] Refreshed manager app ($PKG) so it opens with live status."
fi
export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
SU_ID="$(su -c id 2>/dev/null | head -n1)"
SE_MODE="$(su -c getenforce 2>/dev/null | head -n1)"
NET_DEV="$(ip route get 1.1.1.1 2>/dev/null | sed -n "s/.* dev \([^ ]*\).*/\1/p" | head -n1)"
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    NET_STATE="online (${NET_DEV:-active})"
else
    NET_STATE="offline (${NET_DEV:-no route}) — check ~/ksu_deploy_new/block_a.log"
fi
echo "[+] Root: ${SU_ID:-unavailable} | SELinux: ${SE_MODE:-unknown} | Network: ${NET_STATE}"
' 2>/dev/null || true

echo "[+] deploy.sh complete."
exit 0

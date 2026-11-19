#!/data/data/com.termux/files/usr/bin/bash
cd "$(dirname "$0")"

echo "[*] Staging files to /data/local/tmp via rish..."
rish -c "mkdir -p /data/local/tmp/a"
cat kernelsu.ko     | rish -c 'cat > /data/local/tmp/kernelsu_base.ko'
cat stock.ko        | rish -c 'cat > /data/local/tmp/stock.ko'
cat patch_final.py  | rish -c 'cat > /data/local/tmp/patch_final.py'
cat gen_allowlist.py| rish -c 'cat > /data/local/tmp/gen_allowlist.py'
cat e-r20           | rish -c 'cat > /data/local/tmp/e-r20'
cat spray           | rish -c 'cat > /data/local/tmp/spray'
[ -f ksud ] && cat ksud | rish -c 'cat > /data/local/tmp/ksud && chmod 755 /data/local/tmp/ksud'
rish -c "chmod 755 /data/local/tmp/e-r20 /data/local/tmp/spray"

cat > r20-root.sh << 'INNER_ROOT_SH'
#!/system/bin/sh
exec >>/data/local/tmp/root-helper.log 2>&1
set -x
id
echo 0 > /proc/sys/kernel/kptr_restrict
cat /proc/kallsyms > /data/local/tmp/kallsyms.txt
/data/data/com.termux/files/usr/bin/python3 /data/local/tmp/patch_final.py
LOG=/data/local/tmp/net-qa.log
exec >>"$LOG" 2>&1
(
        # Isolate transition+insmod so parent exec_sid is never set
/system/bin/rm -f /data/local/tmp/net-qa.log /data/local/tmp/.ghostlock_ksu.status 2>/dev/null || true
# --- BEGIN PRE-EXIT BLOCK B ---
timeout 2 /system/bin/chmod 0755 /data/local/tmp/net-recover.sh /data/local/tmp/net-watchdog.sh 2>/dev/null || true
timeout 2 /system/bin/rm -f /data/local/tmp/net-recover.log 2>/dev/null || true
echo "" > /proc/self/attr/exec 2>/dev/null || true
# --- END PRE-EXIT BLOCK B ---
LOG=/data/local/tmp/net-qa.log
exec >>"$LOG" 2>&1
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
echo "uid=\( (id -u) context= \)(cat /proc/self/attr/current 2>/dev/null)"
for p in netd wpa_supplicant rild qcrild; do echo -n "$p:"; pidof $p || echo MISSING; done
timeout 5 dmesg | tail -n 100 || true
timeout 5 ip link show || true
timeout 5 ip addr show || true
timeout 5 getprop | grep -E 'net\.|dns|ril|init' || true
# Recovery
sleep 1
timeout 5 svc wifi disable; sleep 1; timeout 5 svc wifi enable || true
timeout 5 svc data disable; sleep 1; timeout 5 svc data enable || true
echo "=== END ==="

# Hang-resistant network recovery
sleep 1
timeout 5 svc wifi disable; sleep 1; timeout 5 svc wifi enable || true
timeout 5 svc data disable; sleep 1; timeout 5 svc data enable || true

# Build allowlist from installed packages (UID resolved at runtime)
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
  fi
  if [ -n "$uid" ]; then
    ALLOW_ARGS="$ALLOW_ARGS $pkg:$uid"
  fi
done
if [ -f /data/adb/ksu/.allowlist.good ]; then
  cp -f /data/adb/ksu/.allowlist.good /data/adb/ksu/.allowlist
elif [ -n "$ALLOW_ARGS" ]; then
  /data/data/com.termux/files/usr/bin/python3 /data/local/tmp/gen_allowlist.py /data/adb/ksu/.allowlist $ALLOW_ARGS
fi

PKG=$(pm list packages | grep -E 'com\.resukisu\.resukisu|org\.bakasu\.bakasu' | head -n1 | cut -d: -f2)
if [ -n "$PKG" ] && [ -e /sys/module/kernelsu/parameters/ksu_debug_manager_appid ]; then
  MGR_UID=$(stat -c '%u' "/data/user/0/$PKG" 2>/dev/null || true)
  [ -n "$MGR_UID" ] && echo "$MGR_UID" > /sys/module/kernelsu/parameters/ksu_debug_manager_appid
fi

/data/local/tmp/ksud late-load --allow-shell --package-name "$PKG" --kmi android15-6.6
/data/local/tmp/ksud debug mark refresh || true

dmesg | tail -n 20
chmod 644 /data/local/tmp/root-helper.log
# Non-destructive network resync
/system/bin/svc wifi disable 2>/dev/null || true
/system/bin/svc data disable 2>/dev/null || true
sleep 1
/system/bin/svc wifi enable 2>/dev/null || true
/system/bin/svc data enable 2>/dev/null || true
# Make logs readable by shell
/system/bin/chmod 0644 /data/local/tmp/net-qa.log /data/local/tmp/root-helper.log /data/local/tmp/.ghostlock_ksu.status 2>/dev/null || true
/system/bin/sync
echo ready > /data/local/tmp/.ghostlock_ksu.status


# Persistent logs
cp /data/local/tmp/root-helper.log /sdcard/root-helper.log 2>/dev/null || true
cp /data/local/tmp/net-qa.log /sdcard/net-qa.log 2>/dev/null || true
cp /data/local/tmp/root-helper.log /sdcard/root-helper.log 2>/dev/null || true
cp /data/local/tmp/net-qa.log /sdcard/net-qa.log 2>/dev/null || true
INNER_ROOT_SH
cat r20-root.sh | rish -c 'cat > /data/local/tmp/a/r20-root.sh'
rish -c "chmod 755 /data/local/tmp/a/r20-root.sh"

echo "[*] Starting execution loop..."
while true; do
    echo "=== NEW ATTEMPT $(date) ==="
    rish -c 'cd /data/local/tmp && ./e-r20'
    sleep 3
    if rish -c "grep -q 'insmod rc=0' /data/local/tmp/root-helper.log" 2>/dev/null; then
        echo "SUCCESS! Module loaded."
            # --- BLOCK A: Post-Load Recovery (Timeout-Wrapped rish) ---
            LOG_FILE="/data/data/com.termux/files/home/ksu_deploy_new/block_a.log"
            echo "[*] Executing post-load Block A... (Logs: $LOG_FILE)"
            
            # timeout forces deploy.sh to move on even if rish lingers
            timeout 60 rish -c '
            echo "=== BLOCK A START $(date) ==="
            touch /data/local/tmp/su && chmod 755 /data/local/tmp/su
            export PATH="/data/local/tmp:/system/bin:/system/xbin:/vendor/bin:$PATH"
            cd /data/local/tmp || { echo "FATAL: cd failed"; exit 1; }
            timeout 45 /data/local/tmp/net-recover.sh
            echo "[-] net-recover.sh rc=$?"
            WPID="$(timeout 2 cat /data/local/tmp/net-watchdog.pid 2>/dev/null)"
            if [ -z "$WPID" ] || ! [ -d "/proc/$WPID" ]; then
                nohup setsid /data/local/tmp/net-watchdog.sh </dev/null >/dev/null 2>&1 &
                disown 2>/dev/null || true
            fi
            echo "[+] Block A complete."
            echo "=== BLOCK A END ==="
            ' > "$LOG_FILE" 2>&1 || true
            
            echo "[*] Block A returned cleanly (via timeout or completion)."
            break
        fi
        sleep 10
        done
    
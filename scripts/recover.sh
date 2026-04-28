#!/usr/bin/env bash
# Multi-layer recovery for alioth.
# Usage: recover.sh [--auto-stock] [--reason "what happened"]
# Without --auto-stock: tries to switch active slot to _a only.
# With --auto-stock: also re-flashes original stock images from workspace/stock-images/ if both slots look bad.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="$ROOT/workspace/stock-images"
LOG="$ROOT/runs/recovery-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$ROOT/runs"

auto_stock=0
reason="(unspecified)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-stock) auto_stock=1; shift;;
    --reason) reason="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

log "=== recovery start (reason: $reason) ==="

# Layer A: device is in adb / android
if adb devices | grep -qE "device$"; then
  log "device reachable via adb; rebooting to bootloader"
  adb reboot bootloader || true
  sleep 5
fi

# Wait for fastboot
deadline=$((SECONDS+120))
while ! fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then
    log "FATAL: device not in fastboot after 120s — escalate to user (L5)"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 3
  fi
  sleep 2
done
log "device in fastboot"

# Layer B: switch active slot to _a (cheapest recovery)
log "setting active slot to a"
fastboot --set-active=a 2>&1 | tee -a "$LOG"

# Layer C: re-flash stock _a if requested AND active slot is already a
if (( auto_stock )); then
  if [[ ! -f "$STOCK/boot_a-original.img" ]]; then
    log "FATAL: stock backup missing at $STOCK; cannot recover"
    exit 4
  fi
  log "re-flashing stock boot to slot a"
  fastboot flash boot_a "$STOCK/boot_a-original.img" 2>&1 | tee -a "$LOG"
  if [[ -f "$STOCK/dtbo_a-original.img" ]]; then
    fastboot flash dtbo_a "$STOCK/dtbo_a-original.img" 2>&1 | tee -a "$LOG"
  fi
fi

log "rebooting"
fastboot reboot 2>&1 | tee -a "$LOG"

# Wait for adb back
deadline=$((SECONDS+180))
while ! adb devices | grep -qE "device$"; do
  if (( SECONDS > deadline )); then
    log "FATAL: device did not return to adb in 180s after recovery"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 5
  fi
  sleep 3
done

log "=== recovery complete; device on slot a ==="

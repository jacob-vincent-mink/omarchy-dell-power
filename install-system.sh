#!/bin/bash
# Install (or remove) the system components of io.github.nipsen.dell-power:
#   - /usr/local/bin/dell-charge-limit           (privileged helper)
#   - /usr/share/polkit-1/actions/…dell-power.policy
#   - /etc/systemd/system/dell-power-state.service (boot-time cache priming)
#
# Usage:
#   sudo ./install-system.sh             install
#   sudo ./install-system.sh --uninstall removal

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

HELPER=/usr/local/bin/dell-charge-limit
POLICY=/usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy
UNIT=/etc/systemd/system/dell-power-state.service
UDEV=/etc/udev/rules.d/90-dell-power-energy.rules
SUDOERS=/etc/sudoers.d/dell-power

if [[ ${1:-} == --uninstall ]]; then
  [[ $EUID == 0 ]] || { echo "Re-run with sudo." >&2; exit 1; }
  rm -f "$HELPER"
  rm -f "$POLICY"
  rm -f "$UDEV"
  rm -f "$SUDOERS"
  udevadm control --reload-rules 2>/dev/null || true
  # Restore the kernel default (root-only) on the RAPL energy counters.
  chmod 0400 /sys/class/powercap/intel-rapl*/energy_uj 2>/dev/null || true
  systemctl disable --now dell-power-state.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf /run/dell-power
  echo "System components removed."
  exit 0
fi

[[ $EUID == 0 ]] || { echo "Re-run with sudo (install-system.sh)." >&2; exit 1; }

# The installing user (sudo or pkexec) receives the NOPASSWD rule.
target_user=${SUDO_USER:-}
[[ -z $target_user && -n ${PKEXEC_UID:-} ]] && target_user=$(id -nu "$PKEXEC_UID" 2>/dev/null || true)

install -Dm755 "$HERE/system/dell-charge-limit" "$HELPER"
install -Dm644 "$HERE/system/io.github.nipsen.dell-power.policy" "$POLICY"
install -Dm644 "$HERE/system/dell-power-state.service" "$UNIT"
install -Dm644 "$HERE/system/90-dell-power-energy.rules" "$UDEV"

if [[ -n $target_user && $target_user != "root" ]]; then
  printf '%s ALL=(root) NOPASSWD: %s\n' "$target_user" "$HELPER" > "$SUDOERS"
  chmod 0440 "$SUDOERS"
  visudo -cf "$SUDOERS"
fi

udevadm control --reload-rules
udevadm trigger --subsystem-match=powercap
chmod 0444 /sys/class/powercap/intel-rapl*/energy_uj 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now dell-power-state.service

"$HELPER" status >/dev/null && echo "System components installed and working." \
  || echo "Components installed, but the helper reported an error (non-Dell machine?)."

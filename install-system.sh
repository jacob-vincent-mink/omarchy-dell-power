#!/bin/bash
# Install (or remove) the system components of io.github.nipsen.dell-power:
#   - /usr/local/bin/dell-charge-limit           (privileged helper)
#   - /usr/share/polkit-1/actions/…dell-power.policy
#   - /etc/systemd/system/dell-power-state.service (boot-time cache priming)
#
# Usage:
#   sudo ./install-system.sh             install
#   sudo ./install-system.sh --uninstall removal
#
# Payload integrity: the payload files live in a user-writable plugin
# checkout, so each one is bound to its reviewed bytes via the SHA-256
# digest below. The privileged pass verifies regular-file type, ownership,
# mode and digest BEFORE installing, then re-verifies the INSTALLED bytes
# before activating anything. When a payload changes, refresh the digests:
#   sha256sum system/dell-charge-limit system/*.policy system/*.service

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

HELPER=/usr/local/bin/dell-charge-limit
POLICY=/usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy
UNIT=/etc/systemd/system/dell-power-state.service
SUDOERS=/etc/sudoers.d/dell-power
# Installed by versions <= 1.1.1; no longer shipped, always cleaned up.
LEGACY_UDEV=/etc/udev/rules.d/90-dell-power-energy.rules

declare -A DIGEST=(
  [dell-charge-limit]=a32ec225953412f2c09ec9352e862431f89ea441a4310d3f2a06929ee97647f3
  [io.github.nipsen.dell-power.policy]=5a5567025d5a698a13e7583276e5a1811a2b59c8b4f9d6a603ffeba8164752a7
  [dell-power-state.service]=3c678c55b2fd96c9183100944b0ff9b66705865e0ece270210f7d858257892dc
)

fail() { echo "install-system.sh: $*" >&2; exit 1; }

sha() { sha256sum "$1" | awk '{print $1}'; }

verify_payload() { # $1 = checkout path, $2 = payload name
  local f=$1 name=$2 owner mode
  [[ -f $f && ! -L $f ]] || fail "$name: not a regular file (refusing symlink)"
  owner=$(stat -c %U "$f")
  [[ $owner == "${SUDO_USER:-root}" || $owner == root ]] \
    || fail "$name: unexpected owner '$owner' (expected ${SUDO_USER:-root})"
  mode=$(stat -c %a "$f")
  (( (8#$mode & 022) == 0 )) || fail "$name: group/world-writable mode $mode"
  [[ $(sha "$f") == "${DIGEST[$name]}" ]] \
    || fail "$name: digest mismatch — file modified since the reviewed commit?"
}

verify_installed() { # $1 = installed path, $2 = payload name
  [[ $(sha "$1") == "${DIGEST[$2]}" ]] \
    || fail "$2: installed digest mismatch — aborting before activation"
}

if [[ ${1:-} == --uninstall ]]; then
  [[ $EUID == 0 ]] || { echo "Re-run with sudo." >&2; exit 1; }
  rm -f "$HELPER"
  rm -f "$POLICY"
  rm -f "$SUDOERS"
  # Remove the legacy udev rule (<= 1.1.1) and restore the kernel default
  # (root-only) on the RAPL energy counters right away.
  rm -f "$LEGACY_UDEV"
  udevadm control --reload-rules 2>/dev/null || true
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

# Verify the payloads as root, immediately before installing them.
verify_payload "$HERE/system/dell-charge-limit" dell-charge-limit
verify_payload "$HERE/system/io.github.nipsen.dell-power.policy" io.github.nipsen.dell-power.policy
verify_payload "$HERE/system/dell-power-state.service" dell-power-state.service

install -Dm755 "$HERE/system/dell-charge-limit" "$HELPER"
install -Dm644 "$HERE/system/io.github.nipsen.dell-power.policy" "$POLICY"
install -Dm644 "$HERE/system/dell-power-state.service" "$UNIT"

# The bytes on disk in the privileged locations must be the reviewed ones.
verify_installed "$HELPER" dell-charge-limit
verify_installed "$POLICY" io.github.nipsen.dell-power.policy
verify_installed "$UNIT" dell-power-state.service

if [[ -n $target_user && $target_user != "root" ]]; then
  printf '%s ALL=(root) NOPASSWD: %s\n' "$target_user" "$HELPER" > "$SUDOERS"
  chmod 0440 "$SUDOERS"
  visudo -cf "$SUDOERS"
fi

# Older versions of this plugin made the RAPL counters world-readable
# (0444) via a udev rule. Remove the rule and close the counters
# immediately; the helper now reads them as root.
rm -f "$LEGACY_UDEV"
udevadm control --reload-rules 2>/dev/null || true
chmod 0400 /sys/class/powercap/intel-rapl*/energy_uj 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now dell-power-state.service

"$HELPER" status >/dev/null && echo "System components installed and working." \
  || echo "Components installed, but the helper reported an error (non-Dell machine?)."

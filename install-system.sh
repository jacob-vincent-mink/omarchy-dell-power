#!/bin/bash
# Install (or remove) the system components of io.github.nipsen.dell-power:
#   - /usr/local/bin/dell-charge-limit           (privileged helper)
#   - /usr/share/polkit-1/actions/…dell-power.policy
#   - /etc/systemd/system/dell-power-state.service (boot-time cache priming)
#   - /etc/sudoers.d/dell-power                  (NOPASSWD, scoped to the helper)
#
# Usage:
#   sudo ./install-system.sh               install
#   sudo ./install-system.sh --uninstall   removal
#
# Payload integrity model (marketplace security review):
#   * The privileged code is the single Python program in the heredoc below.
#     bash materializes the whole heredoc before exec, so the privileged
#     codepath is read exactly once — a same-user process cannot alter it
#     mid-execution.
#   * Expected payload digests are NOT taken from this user-writable checkout.
#     They come from the publisher manifest (SHA256SUMS) fetched over HTTPS at
#     the commit this checkout's HEAD points to: only bytes matching a commit
#     actually pushed to github.com/NIPSEN/omarchy-dell-power can be installed.
#   * Each payload is opened exactly once, walking every path component through
#     directory descriptors with O_NOFOLLOW (no symlink/directory swap races),
#     then fstat-ed, hashed and copied to its destination from that same
#     descriptor. Nothing is activated before every payload is in place.
#
# After changing a payload, regenerate the manifest, commit and push:
#   sha256sum system/dell-charge-limit system/*.policy system/*.service > SHA256SUMS

set -euo pipefail
command -v python3 >/dev/null || { echo "install-system.sh: python3 is required" >&2; exit 1; }
exec python3 - "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" "$@" <<'DELL_POWER_PY'
# Privileged installer core, run as root by the bash shim above. The program
# arrives on stdin (a materialized heredoc), never from a mutable pathname.
import errno
import glob
import hashlib
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request

REPO = "NIPSEN/omarchy-dell-power"
RAW_BASE = "https://raw.githubusercontent.com"
MANIFEST_NAME = "SHA256SUMS"

HELPER = "/usr/local/bin/dell-charge-limit"
POLICY = "/usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy"
UNIT = "/etc/systemd/system/dell-power-state.service"
SUDOERS = "/etc/sudoers.d/dell-power"
# Installed by versions <= 1.1.1; no longer shipped, always cleaned up.
LEGACY_UDEV = "/etc/udev/rules.d/90-dell-power-energy.rules"

PAYLOADS = {
    "system/dell-charge-limit": (HELPER, 0o755),
    "system/io.github.nipsen.dell-power.policy": (POLICY, 0o644),
    "system/dell-power-state.service": (UNIT, 0o644),
}


def fail(msg):
    print(f"install-system.sh: {msg}", file=sys.stderr)
    sys.exit(1)


def invoking_user():
    user = os.environ.get("SUDO_USER", "")
    if not user and os.environ.get("PKEXEC_UID"):
        try:
            user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
        except (KeyError, ValueError):
            user = ""
    return user


def close_rapl_counters():
    # Versions <= 1.1.1 exposed the RAPL energy counters world-readable (0444)
    # via a udev rule. Remove the rule and restore the kernel default
    # (root-only) on the live counters; the helper reads them as root.
    try:
        os.unlink(LEGACY_UDEV)
    except FileNotFoundError:
        pass
    subprocess.run(["udevadm", "control", "--reload-rules"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for path in glob.glob("/sys/class/powercap/intel-rapl*/energy_uj"):
        try:
            os.chmod(path, 0o400)
        except OSError:
            pass


def uninstall():
    for path in (HELPER, POLICY, SUDOERS):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    close_rapl_counters()
    subprocess.run(["systemctl", "disable", "--now", "dell-power-state.service"],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        os.unlink(UNIT)
    except FileNotFoundError:
        pass
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    shutil.rmtree("/run/dell-power", ignore_errors=True)
    print("System components removed.")


def checkout_head(checkout, user):
    # Resolve HEAD as the invoking user: never parse the user-owned .git as
    # root. The commit hash only selects which publisher manifest to fetch —
    # the digests in that manifest are what actually gate the payloads.
    if user:
        cmd = ["runuser", "-u", user, "--", "git", "-C", checkout, "rev-parse", "HEAD"]
    else:
        cmd = ["git", "-c", "safe.directory=" + checkout, "-C", checkout, "rev-parse", "HEAD"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        fail("could not resolve the checkout's HEAD commit — install from a git "
             "clone (omarchy plugin add …), not from an unpacked archive")
    commit = res.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"unexpected git HEAD output: {commit!r}")
    return commit


def fetch_manifest(commit):
    url = f"{RAW_BASE}/{REPO}/{commit}/{MANIFEST_NAME}"
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            text = resp.read().decode("utf-8")
    except Exception as e:
        fail(f"could not fetch the publisher manifest for commit {commit[:12]}…: {e}\n"
             "install-system.sh verifies the payloads against a commit actually pushed to\n"
             f"github.com/{REPO}. Check the network connection, and 'git status' if the\n"
             "checkout has unpushed commits.")
    digests = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            fail(f"malformed manifest line {lineno}: {line!r}")
        digests[parts[1].lstrip("*")] = parts[0]
    for rel in PAYLOADS:
        if rel not in digests:
            fail(f"publisher manifest has no entry for {rel}")
    return digests


def check_owner_mode(st, what, uid):
    if st.st_uid not in (0, uid):
        fail(f"{what}: owned by uid {st.st_uid}, expected uid {uid} or root")
    if st.st_mode & 0o022:
        fail(f"{what}: group/world-writable mode {oct(stat.S_IMODE(st.st_mode))}")


def open_component(dirfd, comp, what, uid, want_dir):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    if want_dir:
        flags |= os.O_DIRECTORY
    try:
        fd = os.open(comp, flags, dir_fd=dirfd)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            fail(f"{what}: '{comp}' is a symlink or not a directory — refusing to follow it")
        if e.errno == errno.ENOENT:
            fail(f"{what}: '{comp}' does not exist")
        raise
    st = os.fstat(fd)
    if want_dir and not stat.S_ISDIR(st.st_mode):
        os.close(fd)
        fail(f"{what}: '{comp}' is not a directory")
    check_owner_mode(st, what, uid)
    return fd


def open_checkout_dir(path, uid):
    # Open every path component from / exactly once, each held by descriptor:
    # a same-user process swapping a directory or symlink mid-install cannot
    # redirect a later open.
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    for comp in [c for c in path.split("/") if c]:
        nfd = open_component(fd, comp, f"path to the checkout ({path})", uid, want_dir=True)
        os.close(fd)
        fd = nfd
    return fd


def open_payload(checkout_fd, relpath, uid):
    parts = relpath.split("/")
    dfd = checkout_fd
    for comp in parts[:-1]:
        nfd = open_component(dfd, comp, relpath, uid, want_dir=True)
        if dfd != checkout_fd:
            os.close(dfd)
        dfd = nfd
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
    except OSError as e:
        if e.errno == errno.ELOOP:
            fail(f"{relpath}: refusing symlink")
        if e.errno == errno.ENOENT:
            fail(f"{relpath}: file not found in the checkout")
        raise
    if dfd != checkout_fd:
        os.close(dfd)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        fail(f"{relpath}: not a regular file")
    check_owner_mode(st, relpath, uid)
    return fd, st


def sha256_fd(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    h = hashlib.sha256()
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def install_payload(checkout_fd, relpath, expected_hex, uid):
    dest, mode = PAYLOADS[relpath]
    ffd, st = open_payload(checkout_fd, relpath, uid)
    try:
        digest = sha256_fd(ffd)
        if digest != expected_hex:
            fail(f"{relpath}: digest mismatch — the checkout does not match the "
                 "publisher manifest (uncommitted local changes? not at a pushed "
                 "commit? tampered file?)")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmpfd, tmp = tempfile.mkstemp(prefix=".dell-power-", dir=os.path.dirname(dest))
        try:
            # Copy from the verified descriptor itself — never reopen by path.
            off = 0
            while off < st.st_size:
                sent = os.sendfile(tmpfd, ffd, off, st.st_size - off)
                if sent == 0:
                    break
                off += sent
            os.fsync(tmpfd)
            os.fchmod(tmpfd, mode)
            # The staged copy is private to root (O_EXCL, 0600); hash it from
            # its own descriptor before the rename.
            if sha256_fd(tmpfd) != expected_hex:
                fail(f"{relpath}: staged copy corrupted — aborting")
            os.replace(tmp, dest)
            tmp = None
        finally:
            os.close(tmpfd)
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
    finally:
        os.close(ffd)


def verify_installed(digests):
    # Sanity check: the bytes on disk in the privileged locations must still
    # be the reviewed ones before anything is activated.
    for rel, (dest, _) in PAYLOADS.items():
        with open(dest, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != digests[rel]:
                fail(f"{dest}: installed digest mismatch — aborting before activation")


def write_sudoers(user):
    fd = os.open(SUDOERS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o440)
    with os.fdopen(fd, "w") as f:
        f.write(f"{user} ALL=(root) NOPASSWD: {HELPER}\n")
    os.chmod(SUDOERS, 0o440)
    res = subprocess.run(["visudo", "-cf", SUDOERS], capture_output=True)
    if res.returncode != 0:
        try:
            os.unlink(SUDOERS)
        except OSError:
            pass
        fail("visudo rejected the generated sudoers file")


def main():
    if len(sys.argv) < 2:
        fail("internal error: checkout path missing")
    checkout = sys.argv[1]
    args = sys.argv[2:]

    if os.geteuid() != 0:
        fail("Re-run with sudo (install-system.sh).")

    if args == ["--uninstall"]:
        uninstall()
        return
    if args:
        fail(f"unknown arguments: {' '.join(args)}")

    user = invoking_user()
    if user:
        uid = pwd.getpwnam(user).pw_uid
    else:
        uid = os.stat(checkout).st_uid

    commit = checkout_head(checkout, user)
    digests = fetch_manifest(commit)

    cfd = open_checkout_dir(checkout, uid)
    try:
        for rel in PAYLOADS:
            install_payload(cfd, rel, digests[rel], uid)
    finally:
        os.close(cfd)
    verify_installed(digests)

    if user and user != "root":
        write_sudoers(user)
    close_rapl_counters()
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", "dell-power-state.service"], check=True)

    res = subprocess.run([HELPER, "status"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if res.returncode == 0:
        print("System components installed and working.")
    else:
        print("Components installed, but the helper reported an error (non-Dell machine?).")


if __name__ == "__main__":
    main()
DELL_POWER_PY

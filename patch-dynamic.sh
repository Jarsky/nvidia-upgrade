#!/bin/bash
# ════════════════════════════════════════════════════════════
#   Dynamic NVENC Patcher
#   No hardcoded version list — detects patch pattern at runtime
#   Supports: patch | rollback | --check (dry-run)
# ════════════════════════════════════════════════════════════

set -euo pipefail

backup_path="/opt/nvidia/libnvidia-encode-backup"
opmode="patch"
manual_driver_version=""
flatpak_flag=""
silent_flag=""

print_usage() { printf '
SYNOPSIS
       patch-dynamic.sh [-s] [-r|-h|--check] [-d VERSION] [-f]

DESCRIPTION
       Dynamic patch for Nvidia drivers to remove NVENC session limit.
       Automatically detects the correct bytes to patch — no version list needed.

       -s             Silent mode (no output)
       -r             Rollback to original (restore lib from backup)
       -h             Print this help message
       --check        Dry-run: detect pattern and show what would be patched, no changes made
       -d VERSION     Use VERSION instead of auto-detecting via nvidia-smi
       -f             Enable support for Flatpak NVIDIA drivers
'
}

# ── Parse Arguments ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r)        opmode="rollback" ;;
        -s)        silent_flag="true" ;;
        -h)        opmode="help" ;;
        --check)   opmode="check" ;;
        -d)        shift; manual_driver_version="$1" ;;
        -f)        flatpak_flag="true" ;;
        *)         echo "Unknown option: $1"; print_usage; exit 2 ;;
    esac
    shift
done

[[ "$silent_flag" ]] && exec 1>/dev/null

# ── Helpers ───────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
warn()    { echo "[WARN]  $*" >&2; }
error()   { echo "[ERROR] $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Resolve driver version and library path ───────────────────
resolve_driver() {
    if [[ -n "$manual_driver_version" ]]; then
        driver_version="$manual_driver_version"
        info "Using manually specified driver version: $driver_version"
    else
        command -v nvidia-smi &>/dev/null || die "nvidia-smi not found. Is the driver installed?"
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n1)
        info "Detected driver version: $driver_version"
    fi

    driver_maj="${driver_version%%.*}"

    # Choose the right library (415-435 used libnvcuvid)
    if [[ "$driver_maj" -ge 415 && "$driver_maj" -le 435 ]]; then
        object="libnvcuvid.so"
    else
        object="libnvidia-encode.so"
    fi

    # Search known locations
    declare -ga driver_locations=(
        "/usr/lib/x86_64-linux-gnu"
        "/usr/lib/x86_64-linux-gnu/nvidia/current"
        "/usr/lib/x86_64-linux-gnu/nvidia/tesla"
        "/usr/lib/x86_64-linux-gnu/nvidia/tesla-${driver_maj}"
        "/usr/lib64"
        "/usr/lib"
        "/usr/lib/nvidia-${driver_maj}"
    )

    lib_path=""
    for dir in "${driver_locations[@]}"; do
        candidate="${dir}/${object}.${driver_version}"
        if [[ -f "$candidate" ]]; then
            lib_path="$candidate"
            break
        fi
    done

    if [[ -f "$lib_path" ]]; then
        info "Library: $lib_path"
    else
        # Handle Flatpak path separately — just set lib_path if flatpak
        if [[ -n "$flatpak_flag" ]]; then
            local version_dashed
            version_dashed=$(echo "$driver_version" | tr '.' '-')
            local flatpak_dir
            flatpak_dir=$(flatpak info --show-location \
                "org.freedesktop.Platform.GL.nvidia-${version_dashed}" 2>/dev/null | head -n1)
            [[ -n "$flatpak_dir" ]] || die "Flatpak package for $driver_version not found. Try: flatpak update"
            lib_path="${flatpak_dir}/files/lib/${object}.${driver_version}"
            [[ -f "$lib_path" ]] || die "Library not found in Flatpak path: $lib_path"
            info "Flatpak library: $lib_path"
        else
            die "Cannot find ${object}.${driver_version} in any known location."
        fi
    fi

    backup_file="${backup_path}/${object}.${driver_version}"
}

# ── Core: find patch pattern using Python ─────────────────────
find_patch_pattern() {
    # Returns via stdout: "OFFSET:CONTEXT_HEX"
    # Exits non-zero if pattern not found
    python3 - "$1" <<'PYEOF'
import sys
import re

lib_path = sys.argv[1]

with open(lib_path, 'rb') as f:
    data = f.read()

# We're looking for the session-count check:
#   test eax, eax  (\x85\xc0) — tests return value of session count call
#   followed by a move + conditional jump, OR just a conditional jump
#
# We capture 5 bytes of context BEFORE \x85\xc0 to make the match unique.
# Multiple patterns tried in order of specificity (newest drivers first).

patterns = [
    # 580+ pattern: call ?? ?? ?? 41 89 c6 85 c0 (longer context)
    re.compile(rb'(\xe8[\x00-\xff]{4}\x41\x89[\xc4-\xc7])\x85\xc0', re.DOTALL),
    # 460-575 pattern: call ?? ?? ?? 85 c0 41 89 cX
    re.compile(rb'(\xe8[\x00-\xff]{4})\x85\xc0\x41\x89[\xc4-\xc7]', re.DOTALL),
    # 440 pattern: 85 c0 41 89 c4 75
    re.compile(rb'([\x00-\xff]{5})\x85\xc0\x41\x89\xc4\x75', re.DOTALL),
    # Older pattern: 85 c0 89 c5 0f 85
    re.compile(rb'([\x00-\xff]{5})\x85\xc0\x89[\xc4-\xc7]\x0f[\x84\x85]', re.DOTALL),
    # Fallback: any 5-byte context before 85 c0 followed by conditional jump
    re.compile(rb'([\x00-\xff]{5})\x85\xc0\x0f[\x84\x85]', re.DOTALL),
]

match = None
for i, pattern in enumerate(patterns):
    matches = list(pattern.finditer(data))
    if matches:
        if len(matches) > 1:
            print(f"WARNING: Pattern #{i+1} found {len(matches)} candidates, using first", file=sys.stderr)
        match = matches[0]
        break

if not match:
    print("ERROR: Could not find test eax,eax session-check pattern in binary.", file=sys.stderr)
    print("The driver may use a different structure — manual analysis required.", file=sys.stderr)
    sys.exit(1)

context = match.group(1)
offset  = match.start()

# Verify uniqueness of context + 85 c0 in the file
needle = context + b'\x85\xc0'
count  = data.count(needle)
if count > 1:
    print(f"WARNING: context+test sequence appears {count} times — patch may affect multiple sites", file=sys.stderr)

print(f"{hex(offset)}:{context.hex()}")
PYEOF
}

# ── Apply patch (Python binary replace) ───────────────────────
apply_patch() {
    local src="$1"
    local dst="$2"
    local context_hex="$3"
    local dry_run="${4:-false}"

    python3 - "$src" "$dst" "$context_hex" "$dry_run" <<'PYEOF'
import sys

src        = sys.argv[1]
dst        = sys.argv[2]
ctx_hex    = sys.argv[3]
dry_run    = sys.argv[4] == "true"

context    = bytes.fromhex(ctx_hex)
needle     = context + b'\x85\xc0'
replacement= context + b'\x29\xc0'

with open(src, 'rb') as f:
    data = f.read()

count = data.count(needle)
if count == 0:
    # Check if already patched
    if data.count(context + b'\x29\xc0') > 0:
        print("INFO: Library appears to already be patched.")
        sys.exit(0)
    print("ERROR: Pattern not found in source file — cannot patch.", file=sys.stderr)
    sys.exit(1)

print(f"Found {count} occurrence(s) to patch.")

if dry_run:
    print("DRY-RUN: No changes written.")
    sys.exit(0)

patched = data.replace(needle, replacement)

with open(dst, 'wb') as f:
    f.write(patched)

print("Patch written successfully.")
PYEOF
}

# ── Verify patch was applied ──────────────────────────────────
verify_patch() {
    local lib="$1"
    local context_hex="$2"
    python3 - "$lib" "$context_hex" <<'PYEOF'
import sys
lib     = sys.argv[1]
ctx_hex = sys.argv[2]
context = bytes.fromhex(ctx_hex)
with open(lib, 'rb') as f:
    data = f.read()
if data.count(context + b'\x29\xc0') > 0:
    print("Verification PASSED: patched bytes confirmed in library.")
    sys.exit(0)
else:
    print("Verification FAILED: patched bytes not found.", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ════════════════════════════════════════════════════════════
#  MODES
# ════════════════════════════════════════════════════════════

do_patch() {
    local dry_run="${1:-false}"
    [[ $EUID -ne 0 && "$dry_run" == "false" ]] && die "Must run as root to patch. Use sudo."

    resolve_driver

    # Find pattern
    info "Scanning binary for session-check pattern..."
    local result
    result=$(find_patch_pattern "$lib_path") || exit 1

    local offset context_hex
    offset="${result%%:*}"
    context_hex="${result##*:}"

    info "Pattern found at offset: $offset"
    info "Context bytes: $context_hex"

    if [[ "$dry_run" == "true" ]]; then
        info "── DRY-RUN MODE ── no files will be modified"
        apply_patch "$lib_path" "$lib_path" "$context_hex" "true"

        # Show what the patch entry would look like for patch.sh compatibility
        local sed_ctx
        sed_ctx=$(python3 -c "
ctx = bytes.fromhex('$context_hex')
print(''.join(f'\\\\x{b:02x}' for b in ctx))
")
        info "Equivalent patch.sh entry would be:"
        echo "  [\"${driver_version}\"]='s/${sed_ctx}\\x85\\xc0/${sed_ctx}\\x29\\xc0/g'"
        return 0
    fi

    # Backup
    mkdir -p "$backup_path"
    if [[ -f "$backup_file" ]]; then
        local bkp_hash drv_hash
        bkp_hash=$(sha1sum "$backup_file"   | cut -d' ' -f1)
        drv_hash=$(sha1sum "$lib_path" | cut -d' ' -f1)
        if [[ "$bkp_hash" != "$drv_hash" ]]; then
            warn "Backup exists but differs from current library."
            warn "Library may already be patched, or was updated. Re-check manually."
        else
            info "Existing backup matches current library — OK."
        fi
    else
        info "No backup found — creating backup now."
        cp -p "$lib_path" "$backup_file"
        info "Backup: $backup_file"
    fi

    sha1sum "$backup_file"

    # Apply
    info "Applying patch..."
    apply_patch "$backup_file" "$lib_path" "$context_hex" "false"

    sha1sum "$lib_path"

    # Verify
    verify_patch "$lib_path" "$context_hex"

    ldconfig
    info "Done! Run 'nvidia-smi' to confirm driver is healthy."
}

do_rollback() {
    [[ $EUID -ne 0 ]] && die "Must run as root to rollback. Use sudo."

    resolve_driver

    [[ -f "$backup_file" ]] || die "No backup found at $backup_file — patch first, or backup is missing."

    info "Restoring from backup: $backup_file"
    cp -p "$backup_file" "$lib_path"
    sha1sum "$lib_path"
    ldconfig
    info "Rollback complete."
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════

case "$opmode" in
    patch)    do_patch "false" ;;
    check)    do_patch "true"  ;;
    rollback) do_rollback      ;;
    help)     print_usage; exit 0 ;;
esac

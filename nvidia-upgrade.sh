#!/bin/bash
#########################################################
#                                                       #
#                 nvidia-upgrade script                 #
#                                                       #
#        Written by Jarsky  ||  Updated 2025            #
#                                                       #
#  v2.1 - Fixed driver branch selection; NVIDIA now    #
#         publishes Production, New Feature, and Beta   #
#         branches — defaulting to Production.          #
#         Configurable via DRIVER_BRANCH below.         #
#                                                       #
#      Install and Upgrade NVIDIA Geforce driver on     #
#                headless Ubuntu Server                 #
#                                                       #
#########################################################

set -o pipefail

# ── Config ───────────────────────────────────────────
interactive=true
WORK_DIR="/tmp/nvidia-upgrade-$$"
PATCH_URL="https://raw.githubusercontent.com/keylase/nvidia-patch/master/patch.sh"
PATCH_FBC_URL="https://raw.githubusercontent.com/keylase/nvidia-patch/master/patch-fbc.sh"

# Driver branch to install. Options:
#   production   - Latest stable (e.g. 580.x) [default]
#   new-feature  - Latest New Feature Branch  (e.g. 590.x)
#   beta         - Latest Beta                (e.g. 595.x)
DRIVER_BRANCH="production"
# ─────────────────────────────────────────────────────

OK='\e[0;92m\u2714\e[0m'
ERR='\e[1;31m\u274c\e[0m'
INFO='\e[0;94m\u2139\e[0m'

# ── Cleanup trap ─────────────────────────────────────
stopped_container=""

cleanup() {
    if [[ -n "$stopped_container" ]]; then
        echo -e "[$INFO] Restarting Docker container $stopped_container"
        docker start "$stopped_container" || echo -e "[$ERR] Failed to restart container $stopped_container"
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Root check ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "[$ERR] You need to run this as root. e.g sudo $0"
    exit 1
fi

# ── Dependency checks ────────────────────────────────
for cmd in curl lsof modinfo awk sed; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "[$ERR] Required command not found: $cmd"
        exit 1
    fi
done

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ── Get installed driver version ─────────────────────
# Try DKMS path first (most common on Ubuntu), then fallback paths
installedVersion=""
for ko_path in \
    "/usr/lib/modules/$(uname -r)/updates/dkms/nvidia.ko" \
    "/usr/lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst" \
    "/usr/lib/modules/$(uname -r)/kernel/drivers/video/nvidia.ko" \
    "/usr/lib/modules/$(uname -r)/kernel/drivers/video/nvidia.ko.zst"; do
    if [[ -f "$ko_path" ]]; then
        # .zst compressed modules: use modinfo directly (it handles zst on modern kernels)
        v=$(modinfo "$ko_path" 2>/dev/null | awk '/^version:/{print $2}')
        if [[ -n "$v" ]]; then
            installedVersion="$v"
            break
        fi
    fi
done

# Fallback: nvidia-smi (works even if module path varies)
if [[ -z "$installedVersion" ]] && command -v nvidia-smi &>/dev/null; then
    installedVersion=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
fi

if [[ -z "$installedVersion" ]]; then
    echo -e "[$INFO] Installed Version: No driver detected (fresh install)"
else
    echo -e "[$OK] Installed Version: $installedVersion"
fi

# ── Get latest driver version ────────────────────────
# The NVIDIA unix driver page HTML looks like:
#   <span ...>Latest Production Branch Version:</span> <a href="https://.../details/XXXXXX/">595.58.03</a>
# We fetch the page once and extract both the version number and release
# notes URL for the selected branch.

NVIDIA_UNIX_PAGE=$(curl -fsSL "https://www.nvidia.com/en-us/drivers/unix/" 2>/dev/null)

case "$DRIVER_BRANCH" in
    production)   BRANCH_LABEL="Latest Production Branch Version" ;;
    new-feature)  BRANCH_LABEL="Latest New Feature Branch Version" ;;
    beta)         BRANCH_LABEL="Latest Beta Version" ;;
    *)
        echo -e "[$ERR] Unknown DRIVER_BRANCH: '$DRIVER_BRANCH'. Use: production, new-feature, or beta."
        exit 1
        ;;
esac

latestVersion=$(echo "$NVIDIA_UNIX_PAGE" \
    | grep -oP "${BRANCH_LABEL}:</span>\s*<a href=\"[^\"]*\">\K[0-9]+\.[0-9]+(\.[0-9]+)?" \
    | head -1)

latestDriverURL=$(echo "$NVIDIA_UNIX_PAGE" \
    | grep -oP "${BRANCH_LABEL}:</span>\s*<a href=\"\K[^\"]+(?=\">[0-9])" \
    | head -1)

if [[ -z "$latestVersion" ]]; then
    echo -e "[$ERR] Failed to retrieve latest NVIDIA driver version ($DRIVER_BRANCH branch)."
    echo -e "[$INFO] Check https://www.nvidia.com/en-us/drivers/unix/ manually."
    exit 1
fi
echo -e "[$OK] Branch:            $DRIVER_BRANCH"
echo -e "[$OK] Latest Version:    $latestVersion"
[[ -n "$latestDriverURL" ]] && echo -e "[$INFO] Release notes:    $latestDriverURL"

# ── Already up to date? ──────────────────────────────
if [[ "$installedVersion" == "$latestVersion" ]]; then
    echo -e "[$INFO] Driver is already at the latest version ($latestVersion)."
    if [[ "$interactive" == "true" ]]; then
        read -rp "$(echo -e "[$ERR] Reinstall anyway? [y/N] ")" input
        case "$input" in
            [yY][eE][sS]|[yY]) echo -e "[$OK] Continuing install" ;;
            *) echo -e "[$ERR] Cancelled."; exit 0 ;;
        esac
    else
        echo -e "[$ERR] Upgrade skipped. Already latest version."
        exit 0
    fi
fi

# ── Check if NVIDIA driver is in use ─────────────────
lsof_output=$(lsof /usr/lib/x86_64-linux-gnu/libnvidia-* 2>/dev/null)
if [[ -n "$lsof_output" ]]; then
    pid=$(echo "$lsof_output" | awk 'NR>1{print $2}' | head -1)
    if [[ -n "$pid" ]]; then
        cgroup_file="/proc/$pid/cgroup"
        if [[ -f "$cgroup_file" ]] && grep -q "docker-" "$cgroup_file"; then
            # Extract container ID — handles both cgroup v1 and v2
            container_id=$(grep -oP '(?<=docker-)[a-f0-9]+' "$cgroup_file" | head -1)
            if [[ -n "$container_id" ]]; then
                echo -e "[$INFO] Driver in use by Docker container $container_id — stopping it"
                docker stop "$container_id" || { echo -e "[$ERR] Failed to stop container $container_id"; exit 1; }
                stopped_container="$container_id"   # trap will restart it on exit
            fi
        else
            echo -e "[$ERR] Driver is in use by non-Docker process (PID $pid). Stop it first."
            exit 1
        fi
    fi
else
    echo -e "[$OK] NVIDIA driver is not in use"
fi

# ── Confirm before downloading ───────────────────────
if [[ "$interactive" == "true" ]]; then
    read -rp "$(echo -e "[$OK] Download and install NVIDIA $latestVersion? [Y/n] ")" input
    case "$input" in
        [nN][oO]|[nN]) echo -e "[$ERR] Cancelled."; exit 0 ;;
        *) echo -e "[$OK] Continuing install" ;;
    esac
fi

# ── Download driver ───────────────────────────────────
DRIVER_FILE="NVIDIA-Linux-x86_64-${latestVersion}.run"
BASE_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64"

echo -e "[$INFO] Downloading $DRIVER_FILE ..."
if ! curl -fSL --progress-bar -o "$DRIVER_FILE" "$BASE_URL/$latestVersion/$DRIVER_FILE"; then
    echo -e "[$ERR] Download failed. The version ($latestVersion) may not be at the expected URL."
    echo -e "[$INFO] Try downloading manually from https://www.nvidia.com/en-us/drivers/"
    exit 1
fi

chmod +x "$DRIVER_FILE"

# ── Install driver ────────────────────────────────────
echo -e "[$INFO] Installing driver (silent, DKMS) ..."
if ! "./$DRIVER_FILE" -q -a -n -s --dkms; then
    echo -e "[$ERR] Driver installation failed."
    exit 1
fi

echo -e "[$OK] Driver installation complete — version $latestVersion"

# ── nvidia-patch (NVENC / NvFBC) ─────────────────────
echo ""
echo -e "[$INFO] ─────────────────────────────────────────────────"
echo -e "[$INFO]  nvidia-patch (keylase) — NVENC session unlimit"
echo -e "[$INFO] ─────────────────────────────────────────────────"

# Download patch scripts
echo -e "[$INFO] Fetching patch.sh from GitHub ..."
if ! curl -fsSL -o patch.sh "$PATCH_URL"; then
    echo -e "[$ERR] Failed to download patch.sh — skipping patch step."
else
    chmod +x patch.sh

    # Check if this driver version is supported by the patch
    if bash ./patch.sh -c "$latestVersion" &>/dev/null; then
        echo -e "[$OK] Driver $latestVersion is supported by nvidia-patch (NVENC)"
        if [[ "$interactive" == "true" ]]; then
            read -rp "$(echo -e "[$INFO] Apply NVENC patch (removes simultaneous session limit)? [Y/n] ")" apply_patch
        else
            apply_patch="y"
        fi
        case "$apply_patch" in
            [nN][oO]|[nN]) echo -e "[$INFO] NVENC patch skipped." ;;
            *)
                echo -e "[$INFO] Applying NVENC patch ..."
                if bash ./patch.sh; then
                    echo -e "[$OK] NVENC patch applied successfully."
                else
                    echo -e "[$ERR] NVENC patch failed. You can retry manually: bash patch.sh"
                fi
                ;;
        esac
    else
        echo -e "[$ERR] Driver $latestVersion is NOT yet supported by nvidia-patch (NVENC)."
        echo -e "[$INFO] Check https://github.com/keylase/nvidia-patch for updates."
    fi

    # NvFBC patch (optional, for screen capture on consumer GPUs)
    echo ""
    echo -e "[$INFO] Fetching patch-fbc.sh from GitHub ..."
    if curl -fsSL -o patch-fbc.sh "$PATCH_FBC_URL"; then
        chmod +x patch-fbc.sh
        if bash ./patch-fbc.sh -c "$latestVersion" &>/dev/null; then
            echo -e "[$OK] Driver $latestVersion is supported by nvidia-patch (NvFBC)"
            if [[ "$interactive" == "true" ]]; then
                read -rp "$(echo -e "[$INFO] Apply NvFBC patch (enables screen capture on consumer GPUs)? [y/N] ")" apply_fbc
            else
                apply_fbc="n"
            fi
            case "$apply_fbc" in
                [yY][eE][sS]|[yY])
                    echo -e "[$INFO] Applying NvFBC patch ..."
                    if bash ./patch-fbc.sh; then
                        echo -e "[$OK] NvFBC patch applied successfully."
                    else
                        echo -e "[$ERR] NvFBC patch failed. Retry manually: bash patch-fbc.sh"
                    fi
                    ;;
                *) echo -e "[$INFO] NvFBC patch skipped." ;;
            esac
        else
            echo -e "[$INFO] NvFBC patch not available for driver $latestVersion (this is normal for 560+)."
        fi
    else
        echo -e "[$ERR] Failed to download patch-fbc.sh — skipping."
    fi
fi

echo ""
echo -e "[$OK] ── All done ──────────────────────────────────────"
echo -e "[$OK] Installed driver: $latestVersion"
echo -e "[$INFO] A reboot may be required if kernel modules changed."
echo -e "[$OK] ────────────────────────────────────────────────────"

# Trap EXIT will handle: container restart + WORK_DIR cleanup
exit 0

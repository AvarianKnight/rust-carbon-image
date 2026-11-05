#!/bin/bash
# Rust Dedicated Server + Carbon installer for Pterodactyl
# Server files: /mnt/server

set -euo pipefail

SRCDS_APPID=258550
SERVER_DIR="/mnt/server"
STEAMCMD_DIR="${SERVER_DIR}/steamcmd"

# Carbon's current Linux release archive.
CARBON_URL="${CARBON_URL:-https://github.com/CarbonCommunity/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz}"

# Steam login is normally anonymous for Rust Dedicated Server.
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

if [ "${STEAM_USER}" = "anonymous" ]; then
    echo "Using anonymous Steam login."
else
    echo "Using configured Steam account: ${STEAM_USER}"
fi

## clone the Carbon folder from git, if configured
## The existing folder is only replaced at the end, once everything else has succeeded.
CARBON_GIT_URL="${CARBON_GIT_URL:-}"
CARBON_GIT_BRANCH="${CARBON_GIT_BRANCH:-}"
CARBON_GIT_KEY="${CARBON_GIT_KEY:-}"
MODDING_ROOT="${MODDING_ROOT:-carbon}"
GIT_KEY_PATH="/tmp/.carbon_git_key"
GIT_CLONE_DIR=""

cleanup_git() {
    rm -f "${GIT_KEY_PATH}"
    if [ -n "${GIT_CLONE_DIR}" ]; then rm -rf "${GIT_CLONE_DIR}"; fi
}
trap cleanup_git EXIT

# Variables are single-line, so accept the key in the same shapes as carbon_git_sync.js:
# a file path, a PEM with real or literal "\n" newlines, a PEM with newlines
# flattened into spaces, or a base64-encoded PEM.
normalize_git_key() {
    local val="$1" header footer body file
    if [[ "${val}" != *"-----BEGIN"* ]]; then
        file="/mnt/server/${val#/home/container/}"
        if [ -f "${file}" ]; then
            val="$(cat "${file}")"
        else
            val="$(printf '%s' "${val}" | base64 -d 2>/dev/null || true)"
        fi
    fi
    val="${val//\\n/$'\n'}"
    val="${val//$'\r'/}"
    header="$(printf '%s\n' "${val}" | grep -oE -- '-----BEGIN [A-Z0-9 ]+-----' | head -n 1 || true)"
    footer="$(printf '%s\n' "${val}" | grep -oE -- '-----END [A-Z0-9 ]+-----' | head -n 1 || true)"
    if [ -z "${header}" ] || [ -z "${footer}" ]; then return 1; fi
    body="${val#*"${header}"}"
    body="${body%%"${footer}"*}"
    printf '%s\n' "${header}"
    printf '%s\n' ${body}
    printf '%s\n' "${footer}"
}

clone_carbon_repo() {
    if [ -z "${CARBON_GIT_URL}" ]; then
        return 0
    fi
    case "$(echo "${FRAMEWORK:-}" | tr '[:upper:]' '[:lower:]')" in
        *carbon*) ;;
        *) echo "CARBON_GIT_URL is set but the framework is not Carbon. Skipping git clone."; return 0 ;;
    esac
    if [[ ! "${MODDING_ROOT}" =~ ^[A-Za-z0-9._-]+$ ]] || [ "${MODDING_ROOT}" = "." ] || [ "${MODDING_ROOT}" = ".." ]; then
        echo "MODDING_ROOT '${MODDING_ROOT}' must be a single folder name to use git clone."
        return 1
    fi

    if ! command -v git >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
        echo "Installing git and ssh client..."
        apt-get update && apt-get install -y git openssh-client
    fi

    mkdir -p /mnt/server/.ssh
    chmod 700 /mnt/server/.ssh
    local ssh_cmd="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/mnt/server/.ssh/known_hosts"
    if [ -n "${CARBON_GIT_KEY}" ]; then
        (umask 077; normalize_git_key "${CARBON_GIT_KEY}" > "${GIT_KEY_PATH}") || {
            echo "CARBON_GIT_KEY is set but could not be parsed as a private key."
            return 1
        }
        ssh_cmd="ssh -i ${GIT_KEY_PATH} -o IdentitiesOnly=yes ${ssh_cmd#ssh }"
    fi

    # Clone next to the target so the final move stays on the same filesystem
    GIT_CLONE_DIR="/mnt/server/.carbon_git_clone"
    rm -rf "${GIT_CLONE_DIR}"
    local args=(clone -q --depth 1)
    if [ -n "${CARBON_GIT_BRANCH}" ]; then args+=(--branch "${CARBON_GIT_BRANCH}"); fi
    echo "Cloning ${MODDING_ROOT} folder from git..."
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${ssh_cmd}" git "${args[@]}" "${CARBON_GIT_URL}" "${GIT_CLONE_DIR}"
    rm -f "${GIT_KEY_PATH}"
}

install_carbon_repo() {
    if [ -z "${GIT_CLONE_DIR}" ]; then
        return 0
    fi
    echo "Replacing ${MODDING_ROOT} folder with the git clone. Files not in the repository are removed."
    rm -rf "/mnt/server/${MODDING_ROOT}"
    mv "${GIT_CLONE_DIR}" "/mnt/server/${MODDING_ROOT}"
    GIT_CLONE_DIR=""
}

mkdir -p /mnt/server
clone_carbon_repo

echo "Preparing directories..."
mkdir -p "${SERVER_DIR}"
mkdir -p "${STEAMCMD_DIR}"
mkdir -p "${SERVER_DIR}/steamapps"

echo "Downloading SteamCMD..."
cd /tmp
curl -fsSL \
    -o steamcmd.tar.gz \
    https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz

tar -xzf steamcmd.tar.gz -C "${STEAMCMD_DIR}"
rm -f steamcmd.tar.gz

# SteamCMD can fail with a disk-write error if this does not exist.
mkdir -p "${SERVER_DIR}/steamapps"

# Pterodactyl normally expects this ownership at the end.
# SteamCMD sometimes needs root ownership during install in this setup.
chown -R root:root /mnt
export HOME="${SERVER_DIR}"

echo "Installing/updating Rust Dedicated Server..."
cd "${STEAMCMD_DIR}"

./steamcmd.sh \
    +force_install_dir "${SERVER_DIR}" \
    +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
    +app_update "${SRCDS_APPID}" validate \
    +quit

# Swap in the clone now that the game install succeeded; Carbon extracts over it below.
install_carbon_repo

echo "Installing/updating Carbon..."
cd "${SERVER_DIR}"

rm -f /tmp/Carbon.Linux.Release.tar.gz

curl -fsSL \
    -o /tmp/Carbon.Linux.Release.tar.gz \
    "${CARBON_URL}"

tar -xzf /tmp/Carbon.Linux.Release.tar.gz -C "${SERVER_DIR}"
rm -f /tmp/Carbon.Linux.Release.tar.gz

echo "Setting up Steam client compatibility libraries..."
mkdir -p "${SERVER_DIR}/.steam/sdk32"
mkdir -p "${SERVER_DIR}/.steam/sdk64"

cp -fv "${STEAMCMD_DIR}/linux32/steamclient.so" \
    "${SERVER_DIR}/.steam/sdk32/steamclient.so"

cp -fv "${STEAMCMD_DIR}/linux64/steamclient.so" \
    "${SERVER_DIR}/.steam/sdk64/steamclient.so"

echo "Rust Dedicated Server and Carbon installation completed."

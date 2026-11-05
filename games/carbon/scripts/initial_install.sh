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

## Carbon folder from git, if configured. The clone itself happens at first boot
## (js/sections/carbon_git_sync.js): the runtime image ships git and ssh, and this
## install container can't reliably get ssh. It clones into an empty folder, so
## this script only moves the old folder aside and leaves Carbon to the boot update.
CARBON_GIT_URL="${CARBON_GIT_URL:-}"
MODDING_ROOT="${MODDING_ROOT:-carbon}"
USE_CARBON_GIT=0
if [ -n "${CARBON_GIT_URL}" ]; then
    case "$(echo "${FRAMEWORK:-}" | tr '[:upper:]' '[:lower:]')" in
        *carbon*)
            if [[ "${MODDING_ROOT}" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${MODDING_ROOT}" != "." ] && [ "${MODDING_ROOT}" != ".." ]; then
                USE_CARBON_GIT=1
            else
                echo "WARNING: MODDING_ROOT '${MODDING_ROOT}' must be a single folder name to use git. Ignoring CARBON_GIT_URL."
            fi
            ;;
        *) echo "WARNING: CARBON_GIT_URL is set but the framework is not Carbon. Ignoring it." ;;
    esac
fi

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

if [ "${USE_CARBON_GIT}" = "1" ]; then
    # Only reached once the game install succeeded, so a failed install keeps the old folder.
    CARBON_DIR="${SERVER_DIR}/${MODDING_ROOT}"
    if [ -d "${CARBON_DIR}" ] && [ -n "$(ls -A "${CARBON_DIR}")" ]; then
        CARBON_BACKUP="${CARBON_DIR}.old-$(date +%Y%m%d-%H%M%S)"
        echo "Moving existing ${MODDING_ROOT} folder to ${CARBON_BACKUP##*/}. Delete it once you no longer need it."
        mv "${CARBON_DIR}" "${CARBON_BACKUP}"
    fi
    echo "${MODDING_ROOT} folder will be cloned from git, and Carbon installed, on first boot."
else
    echo "Installing/updating Carbon..."
    cd "${SERVER_DIR}"

    rm -f /tmp/Carbon.Linux.Release.tar.gz

    curl -fsSL \
        -o /tmp/Carbon.Linux.Release.tar.gz \
        "${CARBON_URL}"

    tar -xzf /tmp/Carbon.Linux.Release.tar.gz -C "${SERVER_DIR}"
    rm -f /tmp/Carbon.Linux.Release.tar.gz
fi

echo "Setting up Steam client compatibility libraries..."
mkdir -p "${SERVER_DIR}/.steam/sdk32"
mkdir -p "${SERVER_DIR}/.steam/sdk64"

cp -fv "${STEAMCMD_DIR}/linux32/steamclient.so" \
    "${SERVER_DIR}/.steam/sdk32/steamclient.so"

cp -fv "${STEAMCMD_DIR}/linux64/steamclient.so" \
    "${SERVER_DIR}/.steam/sdk64/steamclient.so"

echo "Rust Dedicated Server and Carbon installation completed."

#!/bin/bash
# Initial install script (SteamCMD)
# Server Files: /mnt/server

set -euo pipefail

SRCDS_APPID=258550

## just in case someone removed the defaults.
if [ "${STEAM_USER:-}" == "" ]; then
    echo -e "steam user is not set."
    echo -e "Using anonymous user."
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
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

## download and install steamcmd
cd /tmp
mkdir -p /mnt/server/steamcmd
curl -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzvf steamcmd.tar.gz -C /mnt/server/steamcmd
mkdir -p /mnt/server/steamapps # Fix steamcmd disk write error when this folder is missing
cd /mnt/server/steamcmd

# SteamCMD fails otherwise for some reason, even running as root.
# This is changed at the end of the install process anyways.
chown -R root:root /mnt
export HOME=/mnt/server

echo "Using SteamCMD to download server files..."
./steamcmd.sh +force_install_dir /mnt/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} ${EXTRA_FLAGS} validate +quit

## set up 32 bit libraries
mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so

## set up 64 bit libraries
mkdir -p /mnt/server/.steam/sdk64
cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so

## swap in the Carbon clone now that the install has succeeded
install_carbon_repo

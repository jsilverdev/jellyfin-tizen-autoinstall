#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TV_IP=""
TIZEN_STUDIO_PATH="${HOME}/.local/share/tizen-studio"
ASSET_NAME="Jellyfin.wgt"
DOWNLOAD_DIRECTORY="${SCRIPT_DIR}/downloads"
VALIDATE_ONLY=0
SKIP_TIZEN_INSTALL=0
TIZEN_SDK_VERSION="10.0"
TIZEN_INSTALLER_URL="https://download.tizen.org/sdk/Installer/tizen-sdk_${TIZEN_SDK_VERSION}/web-cli_Tizen_SDK_${TIZEN_SDK_VERSION}_ubuntu-64.bin"
TIZEN_INSTALLER_SIZE=401290863
REPOSITORY="jeppevinkel/jellyfin-tizen-builds"
LATEST_RELEASE_API="https://api.github.com/repos/${REPOSITORY}/releases/latest"

usage() {
    cat <<'USAGE'
Usage:
  ./Install-JellyfinTizen.sh --tv-ip <IPv4> [options]

Options:
  --tv-ip <IPv4>                 Samsung TV IPv4 address (required).
  --tizen-studio-path <path>     Tizen CLI path. Default: ~/.local/share/tizen-studio
  --asset-name <name.wgt>        Release asset to install. Default: Jellyfin.wgt
  --download-directory <path>    Cache directory. Default: ./downloads
  --validate-only                Validate tools, TV connectivity, and release metadata only.
  --skip-tizen-install           Fail instead of auto-installing Tizen CLI when it is missing.
  -h, --help                     Show this help.
USAGE
}

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nERROR: %b\n' "$1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

is_ipv4() {
    local ip="$1" a b c d extra octet
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

safe_directory_name() { printf '%s' "$1" | sed 's#[\\/:*?"<>|]#_#g'; }
tizen_tools_exist() { [[ -x "$TIZEN_STUDIO_PATH/tools/sdb" && -x "$TIZEN_STUDIO_PATH/tools/ide/bin/tizen" ]]; }

download_file() {
    local url="$1" destination="$2"
    python3 - "$url" "$destination" <<'PY'
import sys
import urllib.request
url, destination = sys.argv[1], sys.argv[2]
request = urllib.request.Request(url, headers={"User-Agent": "jellyfin-tizen-autoinstall"})
with urllib.request.urlopen(request) as response, open(destination, "wb") as output:
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        output.write(chunk)
PY
}

install_tizen_cli() {
    (( SKIP_TIZEN_INSTALL == 0 )) || fail "Tizen CLI is missing at '$TIZEN_STUDIO_PATH' and --skip-tizen-install was specified."
    case "$(uname -m)" in x86_64|amd64) ;; *) fail "Automatic Tizen SDK installation currently requires x86_64 Linux." ;; esac
    (( EUID != 0 )) || fail "Tizen SDK must be installed as a regular user, not root."

    step "Tizen CLI not found; installing Tizen SDK ${TIZEN_SDK_VERSION}"
    printf 'Destination: %s\nSource: %s\n' "$TIZEN_STUDIO_PATH" "$TIZEN_INSTALLER_URL"

    local installer
    installer="$(mktemp "${TMPDIR:-/tmp}/jellyfin-tizen-installer.XXXXXX.bin")"
    trap 'rm -f -- "$installer"' EXIT
    download_file "$TIZEN_INSTALLER_URL" "$installer"
    local actual_size
    actual_size="$(stat -c '%s' "$installer")"
    [[ "$actual_size" == "$TIZEN_INSTALLER_SIZE" ]] || fail "Unexpected Tizen SDK installer size: got ${actual_size}, expected ${TIZEN_INSTALLER_SIZE}."
    chmod +x "$installer"
    mkdir -p "$(dirname -- "$TIZEN_STUDIO_PATH")"
    "$installer" --accept-license --no-java-check "$TIZEN_STUDIO_PATH"
    tizen_tools_exist || fail "Tizen SDK installation completed, but sdb and tizen were not found under '$TIZEN_STUDIO_PATH'."
    printf 'OK: Tizen SDK installed in %s\n' "$TIZEN_STUDIO_PATH"
    rm -f -- "$installer"
    trap - EXIT
}

get_local_address_for_target() {
    python3 - "$TV_IP" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    sock.connect((sys.argv[1], 26101))
    print(sock.getsockname()[0])
finally:
    sock.close()
PY
}

get_release_metadata() {
    python3 - "$LATEST_RELEASE_API" "$ASSET_NAME" <<'PY'
import json, sys, urllib.request
api, asset_name = sys.argv[1], sys.argv[2]
request = urllib.request.Request(api, headers={"Accept": "application/vnd.github+json", "User-Agent": "jellyfin-tizen-autoinstall"})
with urllib.request.urlopen(request) as response:
    release = json.load(response)
asset = next((item for item in release.get("assets", []) if item.get("name") == asset_name), None)
if asset is None:
    print(f"ERROR\tRelease {release.get('tag_name', '<unknown>')} does not contain {asset_name}.")
    sys.exit(3)
digest = asset.get("digest") or ""
if not digest.lower().startswith("sha256:"):
    print(f"ERROR\tGitHub did not publish a SHA-256 digest for {asset_name}.")
    sys.exit(4)
print(release["tag_name"])
print(asset["name"])
print(asset["size"])
print(digest)
print(asset["browser_download_url"])
PY
}

while (( $# > 0 )); do
    case "$1" in
        --tv-ip) (( $# >= 2 )) || fail "--tv-ip requires a value."; TV_IP="$2"; shift 2 ;;
        --tizen-studio-path) (( $# >= 2 )) || fail "--tizen-studio-path requires a value."; TIZEN_STUDIO_PATH="$2"; shift 2 ;;
        --asset-name) (( $# >= 2 )) || fail "--asset-name requires a value."; ASSET_NAME="$2"; shift 2 ;;
        --download-directory) (( $# >= 2 )) || fail "--download-directory requires a value."; DOWNLOAD_DIRECTORY="$2"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=1; shift ;;
        --skip-tizen-install) SKIP_TIZEN_INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -n "$TV_IP" ]] || { usage >&2; fail "--tv-ip is required."; }
is_ipv4 "$TV_IP" || fail "TV address is not a valid IPv4 address: $TV_IP"
[[ "$ASSET_NAME" == *.wgt && "$ASSET_NAME" != */* && "$ASSET_NAME" != *\\* ]] || fail "--asset-name must be a .wgt file name without a path."

for command in python3 sha256sum stat sed awk grep mktemp; do require_command "$command"; done

step 'Validating parameters and Tizen Studio'
if ! tizen_tools_exist; then install_tizen_cli; fi
SDB_PATH="$TIZEN_STUDIO_PATH/tools/sdb"
TIZEN_PATH="$TIZEN_STUDIO_PATH/tools/ide/bin/tizen"

if ! TIZEN_VERSION_OUTPUT="$("$TIZEN_PATH" version 2>&1)"; then fail "Tizen CLI is not working correctly: ${TIZEN_VERSION_OUTPUT}"; fi
printf 'OK: %s\n' "$(printf '%s\n' "$TIZEN_VERSION_OUTPUT" | head -n 1)"

PC_IP="$(get_local_address_for_target)"
printf 'IP of this PC for Developer Mode: %s\nTV IP: %s\n' "$PC_IP" "$TV_IP"
if command -v ping >/dev/null 2>&1 && ping -c 1 -W 1 "$TV_IP" >/dev/null 2>&1; then
    printf 'OK: TV responds on the network.\n'
else
    printf 'WARNING: TV did not answer ping. SDB will still be attempted because some devices block ICMP.\n' >&2
fi

step 'Validating Developer Mode and SDB connection'
"$SDB_PATH" start-server >/dev/null 2>&1 || true
ENDPOINT="${TV_IP}:26101"
set +e
CONNECT_OUTPUT="$("$SDB_PATH" connect "$ENDPOINT" 2>&1)"; CONNECT_EXIT=$?
DEVICES_OUTPUT="$("$SDB_PATH" devices 2>&1)"; DEVICES_EXIT=$?
set -e
TARGET_NAME="$(awk -v ip="$TV_IP" -v endpoint="$ENDPOINT" '$2 == "device" && ($1 == ip || $1 == endpoint) { print $3; exit }' <<<"$DEVICES_OUTPUT")"
if [[ -z "$TARGET_NAME" || $DEVICES_EXIT -ne 0 ]]; then
    fail "Could not validate the TV through SDB.\n\nOn the TV open Apps, press 1 2 3 4 5, then confirm:\n  Developer Mode: ON\n  Host PC IP: $PC_IP\n\nFully restart the TV and run the script again.\nSDB connect exit: $CONNECT_EXIT\n$CONNECT_OUTPUT\n$DEVICES_OUTPUT"
fi
printf 'OK: device detected: %s (%s)\n' "$TARGET_NAME" "$ENDPOINT"

step 'Querying the latest stable release'
set +e
RELEASE_METADATA="$(get_release_metadata)"; METADATA_EXIT=$?
set -e
if (( METADATA_EXIT != 0 )); then
    [[ $RELEASE_METADATA == ERROR$'\t'* ]] && fail "${RELEASE_METADATA#*$'\t'}"
    fail "Could not retrieve valid release metadata from GitHub."
fi
mapfile -t RELEASE_FIELDS <<<"$RELEASE_METADATA"
RELEASE_TAG="${RELEASE_FIELDS[0]}"
RELEASE_ASSET_NAME="${RELEASE_FIELDS[1]}"
RELEASE_ASSET_SIZE="${RELEASE_FIELDS[2]}"
RELEASE_ASSET_DIGEST="${RELEASE_FIELDS[3]}"
RELEASE_ASSET_URL="${RELEASE_FIELDS[4]}"
printf 'OK: release %s\nAsset: %s (%s bytes)\nExpected digest: %s\n' "$RELEASE_TAG" "$RELEASE_ASSET_NAME" "$RELEASE_ASSET_SIZE" "$RELEASE_ASSET_DIGEST"

if (( VALIDATE_ONLY == 1 )); then
    printf '\nValidation completed. No Jellyfin package was downloaded or installed.\n'
    exit 0
fi

step 'Downloading and verifying the package'
SAFE_TAG="$(safe_directory_name "$RELEASE_TAG")"
RELEASE_DIRECTORY="$DOWNLOAD_DIRECTORY/$SAFE_TAG"
PACKAGE_PATH="$RELEASE_DIRECTORY/$ASSET_NAME"
PARTIAL_PATH="${PACKAGE_PATH}.partial"
mkdir -p "$RELEASE_DIRECTORY"
PACKAGE_IS_VALID=0
if [[ -f "$PACKAGE_PATH" ]]; then
    EXISTING_HASH="$(sha256sum "$PACKAGE_PATH" | awk '{print tolower($1)}')"
    if [[ "sha256:${EXISTING_HASH}" == "${RELEASE_ASSET_DIGEST,,}" ]]; then
        PACKAGE_IS_VALID=1
        printf 'Existing package has the expected SHA-256 and will be reused.\n'
    else
        printf 'WARNING: existing package does not match GitHub and will be replaced.\n' >&2
        rm -f -- "$PACKAGE_PATH"
    fi
fi

if (( PACKAGE_IS_VALID == 0 )); then
    rm -f -- "$PARTIAL_PATH"
    trap 'rm -f -- "$PARTIAL_PATH"' EXIT
    download_file "$RELEASE_ASSET_URL" "$PARTIAL_PATH"
    DOWNLOADED_SIZE="$(stat -c '%s' "$PARTIAL_PATH")"
    [[ "$DOWNLOADED_SIZE" == "$RELEASE_ASSET_SIZE" ]] || fail "Incorrect package size: got ${DOWNLOADED_SIZE}, expected ${RELEASE_ASSET_SIZE}."
    ACTUAL_HASH="$(sha256sum "$PARTIAL_PATH" | awk '{print tolower($1)}')"
    ACTUAL_DIGEST="sha256:${ACTUAL_HASH}"
    [[ "$ACTUAL_DIGEST" == "${RELEASE_ASSET_DIGEST,,}" ]] || fail "SHA-256 mismatch. Expected: ${RELEASE_ASSET_DIGEST}. Got: ${ACTUAL_DIGEST}."
    mv -f -- "$PARTIAL_PATH" "$PACKAGE_PATH"
    trap - EXIT
    PACKAGE_IS_VALID=1
fi

(( PACKAGE_IS_VALID == 1 )) || fail 'Downloaded package could not be validated.'
FINAL_HASH="$(sha256sum "$PACKAGE_PATH" | awk '{print tolower($1)}')"
printf 'OK: verified package: %s\nSHA-256: sha256:%s\n' "$PACKAGE_PATH" "$FINAL_HASH"

step "Installing $ASSET_NAME on $TARGET_NAME"
pushd "$RELEASE_DIRECTORY" >/dev/null
set +e
INSTALL_OUTPUT="$("$TIZEN_PATH" install -n "$ASSET_NAME" -t "$TARGET_NAME" 2>&1)"; INSTALL_EXIT=$?
set -e
popd >/dev/null
printf '%s\n' "$INSTALL_OUTPUT"
if (( INSTALL_EXIT != 0 )) || ! grep -Eiq 'Tizen application is successfully installed|Installed the package' <<<"$INSTALL_OUTPUT"; then
    fail 'Tizen Studio did not confirm installation. If another build signed with a different certificate is installed, uninstall it from the TV Apps menu and retry.'
fi

APP_ID=""
ID_REGEX='Id\(([^)]+)\)'
APP_ID_REGEX='app_id\[([^]]+)\]'
if [[ $INSTALL_OUTPUT =~ $ID_REGEX ]]; then APP_ID="${BASH_REMATCH[1]}"; elif [[ $INSTALL_OUTPUT =~ $APP_ID_REGEX ]]; then APP_ID="${BASH_REMATCH[1]}"; fi

step 'Verifying the installed application'
set +e
APP_LIST_OUTPUT="$("$SDB_PATH" shell 0 applist 2>&1)"; APP_LIST_EXIT=$?
set -e
(( APP_LIST_EXIT == 0 )) || fail "Could not query the final application list: ${APP_LIST_OUTPUT}"
grep -Eiq '\bJellyfin\b' <<<"$APP_LIST_OUTPUT" || fail 'Installation reported success, but Jellyfin is not present in the TV application list.'
if [[ -n "$APP_ID" ]]; then grep -Fq "$APP_ID" <<<"$APP_LIST_OUTPUT" || fail "Jellyfin is present, but expected app ID '$APP_ID' was not found."; fi

printf '\nJellyfin was installed and verified successfully.\nTV: %s (%s)\nRelease: %s\n' "$TARGET_NAME" "$TV_IP" "$RELEASE_TAG"
[[ -z "$APP_ID" ]] || printf 'App ID: %s\n' "$APP_ID"
printf 'Package: %s\n' "$PACKAGE_PATH"

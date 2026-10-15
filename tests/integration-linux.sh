#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
TMP_DIR="$(mktemp -d)"
FAKE_TIZEN="$TMP_DIR/tizen-studio"
DOWNLOAD_DIR="$TMP_DIR/downloads"
BAD_DOWNLOAD_DIR="$TMP_DIR/bad-downloads"
FAKE_BIN="$TMP_DIR/bin"
REAL_PYTHON="$(command -v python3)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

mkdir -p "$FAKE_TIZEN/tools/ide/bin" "$FAKE_BIN"

cat > "$FAKE_TIZEN/tools/sdb" <<'SDB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  start-server)
    exit 0
    ;;
  connect)
    printf 'connected to %s\n' "${2:-unknown}"
    exit 0
    ;;
  devices)
    printf 'List of devices attached\n'
    if [[ "${MOCK_NO_DEVICE:-0}" != "1" ]]; then
      printf '127.0.0.1:26101 device MOCK-TV\n'
    fi
    exit 0
    ;;
  shell)
    if [[ "${2:-}" == "0" && "${3:-}" == "applist" ]]; then
      if [[ "${MOCK_APP_MISSING:-0}" == "1" ]]; then
        printf 'mock.other OtherApp\n'
      else
        printf 'mock.jellyfin Jellyfin\n'
      fi
      exit 0
    fi
    ;;
esac
printf 'Unexpected sdb invocation: %s\n' "$*" >&2
exit 2
SDB
chmod +x "$FAKE_TIZEN/tools/sdb"

cat > "$FAKE_TIZEN/tools/ide/bin/tizen" <<'TIZEN'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  version)
    printf 'Tizen CLI 1.0 mock\n'
    exit 0
    ;;
  install)
    if [[ "${MOCK_INSTALL_FAIL:-0}" == "1" ]]; then
      printf 'Simulated install failure\n' >&2
      exit 1
    fi
    printf 'Tizen application is successfully installed. Id(mock.jellyfin)\n'
    exit 0
    ;;
esac
printf 'Unexpected tizen invocation: %s\n' "$*" >&2
exit 2
TIZEN
chmod +x "$FAKE_TIZEN/tools/ide/bin/tizen"

cat > "$FAKE_BIN/python3" <<'PYWRAP'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_FILE="$(mktemp)"
trap 'rm -f -- "$SCRIPT_FILE"' EXIT
cat > "$SCRIPT_FILE"
if [[ "${1:-}" == "-" ]]; then
  shift
fi
"$REAL_PYTHON" "$SCRIPT_FILE" "$@"
status=$?
if (( status == 0 )) && [[ "${MOCK_CORRUPT_DOWNLOAD:-0}" == "1" ]] && [[ "${1:-}" == https://github.com/*/releases/download/* ]] && [[ -f "${2:-}" ]]; then
  "$REAL_PYTHON" - "${2}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
if not data:
    raise SystemExit("downloaded file is unexpectedly empty")
data[0] ^= 0x01
path.write_bytes(data)
PY
fi
exit "$status"
PYWRAP
chmod +x "$FAKE_BIN/python3"

LAST_OUTPUT=""
LAST_CODE=0

invoke() {
  set +e
  LAST_OUTPUT="$("$@" 2>&1)"
  LAST_CODE=$?
  set -e
  printf '%s\n' "$LAST_OUTPUT"
}

expect_success() {
  local name="$1"
  shift
  printf '\n--- %s ---\n' "$name"
  invoke "$@"
  if (( LAST_CODE != 0 )); then
    printf 'FAIL: %s exited with %s\n' "$name" "$LAST_CODE" >&2
    exit 1
  fi
}

expect_failure_contains() {
  local name="$1" expected="$2"
  shift 2
  printf '\n--- %s ---\n' "$name"
  invoke "$@"
  if (( LAST_CODE == 0 )); then
    printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  if [[ "$LAST_OUTPUT" != *"$expected"* ]]; then
    printf 'FAIL: %s did not contain expected text: %s\n' "$name" "$expected" >&2
    exit 1
  fi
}

COMMON=(--tv-ip 127.0.0.1 --tizen-studio-path "$FAKE_TIZEN" --download-directory "$DOWNLOAD_DIR")

expect_failure_contains 'invalid IPv4' 'not a valid IPv4' \
  bash "$INSTALLER" --tv-ip 999.1.1.1 --tizen-studio-path "$FAKE_TIZEN"

expect_failure_contains 'invalid asset path' '--asset-name must be a .wgt file name' \
  bash "$INSTALLER" --tv-ip 127.0.0.1 --tizen-studio-path "$FAKE_TIZEN" --asset-name nested/bad.wgt

expect_failure_contains 'missing Tizen with skip flag' '--skip-tizen-install was specified' \
  bash "$INSTALLER" --tv-ip 127.0.0.1 --tizen-studio-path "$TMP_DIR/missing-tizen" --skip-tizen-install

expect_success 'validate-only against real GitHub release' \
  bash "$INSTALLER" "${COMMON[@]}" --validate-only
[[ "$LAST_OUTPUT" == *'Validation completed'* ]] || { printf 'FAIL: validate-only confirmation missing\n' >&2; exit 1; }
if find "$DOWNLOAD_DIR" -type f -name '*.wgt' -print -quit 2>/dev/null | grep -q .; then
  printf 'FAIL: validate-only downloaded a WGT file\n' >&2
  exit 1
fi

expect_success 'full install flow with real WGT and mocked TV' \
  bash "$INSTALLER" "${COMMON[@]}"
[[ "$LAST_OUTPUT" == *'installed and verified successfully'* ]] || { printf 'FAIL: success confirmation missing\n' >&2; exit 1; }
PACKAGE_PATH="$(find "$DOWNLOAD_DIR" -type f -name 'Jellyfin.wgt' -print -quit)"
[[ -n "$PACKAGE_PATH" && -s "$PACKAGE_PATH" ]] || { printf 'FAIL: verified WGT was not cached\n' >&2; exit 1; }

printf 'corrupt-cache' > "$PACKAGE_PATH"
expect_success 'corrupt cached package is replaced' \
  bash "$INSTALLER" "${COMMON[@]}"
[[ "$LAST_OUTPUT" == *'existing package does not match GitHub and will be replaced'* ]] || { printf 'FAIL: corrupt cache was not detected\n' >&2; exit 1; }
[[ "$(stat -c '%s' "$PACKAGE_PATH")" -gt 1000 ]] || { printf 'FAIL: corrupt cache was not replaced\n' >&2; exit 1; }

expect_failure_contains 'SHA-256 mismatch is rejected' 'SHA-256 mismatch' \
  env PATH="$FAKE_BIN:$PATH" REAL_PYTHON="$REAL_PYTHON" MOCK_CORRUPT_DOWNLOAD=1 \
  bash "$INSTALLER" --tv-ip 127.0.0.1 --tizen-studio-path "$FAKE_TIZEN" --download-directory "$BAD_DOWNLOAD_DIR"

expect_failure_contains 'missing release asset' 'does not contain' \
  bash "$INSTALLER" "${COMMON[@]}" --asset-name DoesNotExist.wgt

expect_failure_contains 'SDB without TV' 'Could not validate the TV through SDB' \
  env MOCK_NO_DEVICE=1 bash "$INSTALLER" "${COMMON[@]}"

expect_failure_contains 'Tizen install failure' 'did not confirm installation' \
  env MOCK_INSTALL_FAIL=1 bash "$INSTALLER" "${COMMON[@]}"

expect_failure_contains 'installed app missing from applist' 'not present in the TV application list' \
  env MOCK_APP_MISSING=1 bash "$INSTALLER" "${COMMON[@]}"

printf '\nAll Linux integration tests passed.\n'

#!/usr/bin/env bash
#===============================================================================
# OpenObserve - native single-node installer (no Docker)
#
# Supported : AlmaLinux 9+ (and Rocky/RHEL/Oracle 9+), Ubuntu 22.04, Ubuntu 24.04
# Arch      : x86_64 (amd64), aarch64 (arm64)
# Result    : /usr/local/bin/openobserve + systemd unit "openobserve"
#
# Usage:
#   sudo bash install-openobserve.sh                # install / upgrade
#   sudo bash install-openobserve.sh --uninstall    # remove, keep data + config
#   sudo bash install-openobserve.sh --purge        # remove everything incl. data
#
# Optional environment overrides (all have defaults):
#   O2_VERSION=v1.0.4            release tag to install
#   O2_EDITION=opensource        opensource | enterprise
#   O2_VARIANT=                  "" (default) | simd | musl     (amd64 only)
#   O2_SHA256=                   expected sha256 of the tarball (optional verify)
#   O2_ROOT_EMAIL=admin@example.com
#   O2_ROOT_PASSWORD=            auto-generated when empty
#   O2_HTTP_PORT=5080            UI / HTTP ingest
#   O2_GRPC_PORT=5081            OTLP gRPC ingest
#   O2_BIND_ADDR=                e.g. 127.0.0.1 when fronted by a reverse proxy
#   O2_DATA_DIR=/var/lib/openobserve
#   O2_OPEN_FIREWALL=yes         yes | no  (firewalld / ufw, only if active)
#   O2_FORCE=0                   1 = skip the OS version gate
#
# Example:
#   sudo O2_ROOT_EMAIL=murali@example.com O2_ROOT_PASSWORD='Str0ng#Pass' \
#        bash install-openobserve.sh
#===============================================================================
set -Eeuo pipefail

O2_VERSION="${O2_VERSION:-v1.0.4}"
O2_EDITION="${O2_EDITION:-opensource}"
O2_VARIANT="${O2_VARIANT:-}"
O2_SHA256="${O2_SHA256:-}"
O2_ROOT_EMAIL="${O2_ROOT_EMAIL:-admin@example.com}"
O2_ROOT_PASSWORD="${O2_ROOT_PASSWORD:-}"
O2_HTTP_PORT="${O2_HTTP_PORT:-5080}"
O2_GRPC_PORT="${O2_GRPC_PORT:-5081}"
O2_BIND_ADDR="${O2_BIND_ADDR:-}"
O2_DATA_DIR="${O2_DATA_DIR:-/var/lib/openobserve}"
O2_OPEN_FIREWALL="${O2_OPEN_FIREWALL:-yes}"
O2_FORCE="${O2_FORCE:-0}"

O2_USER="openobserve"
O2_GROUP="openobserve"
O2_BIN="/usr/local/bin/openobserve"
O2_CONF_DIR="/etc/openobserve"
O2_ENV_FILE="${O2_CONF_DIR}/openobserve.env"
O2_UNIT="/etc/systemd/system/openobserve.service"
O2_BASE_URL="https://downloads.openobserve.ai/releases"

TMP_DIR=""
PW_GENERATED=0

#--- helpers -------------------------------------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
on_err()  { warn "Failed at line $1: $2"; }
trap cleanup EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

have() { command -v "$1" >/dev/null 2>&1; }

#--- pre-flight ----------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-0}"
  OS_MAJOR="${OS_VER%%.*}"

  case "$OS_ID" in
    almalinux|rocky|rhel|centos|ol)
      OS_FAMILY="rhel"
      if (( OS_MAJOR < 9 )) && [[ "$O2_FORCE" != "1" ]]; then
        die "${PRETTY_NAME:-$OS_ID} not supported (need EL 9+). Set O2_FORCE=1 to override."
      fi
      ;;
    ubuntu)
      OS_FAMILY="debian"
      if [[ "$OS_VER" != "22.04" && "$OS_VER" != "24.04" && "$O2_FORCE" != "1" ]]; then
        die "Ubuntu $OS_VER not supported (need 22.04 or 24.04). Set O2_FORCE=1 to override."
      fi
      ;;
    *)
      die "Unsupported distribution: ${PRETTY_NAME:-$OS_ID}"
      ;;
  esac
  have systemctl || die "systemd is required."
  log "OS: ${PRETTY_NAME:-$OS_ID $OS_VER}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)        ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  if [[ -n "$O2_VARIANT" ]]; then
    [[ "$O2_VARIANT" =~ ^(simd|musl)$ ]] || die "O2_VARIANT must be empty, simd or musl."
    [[ "$ARCH" == "amd64" ]] || die "O2_VARIANT=$O2_VARIANT is published for amd64 only."
  fi
  log "Arch: $ARCH${O2_VARIANT:+-$O2_VARIANT}"
}

validate_input() {
  [[ "$O2_VERSION" == v* ]] || O2_VERSION="v${O2_VERSION}"
  case "$O2_EDITION" in
    opensource|oss)   O2_EDITION="opensource"; REL_PATH="openobserve";   TAR_PREFIX="openobserve" ;;
    enterprise|ee)    O2_EDITION="enterprise"; REL_PATH="o2-enterprise"; TAR_PREFIX="openobserve-ee" ;;
    *) die "O2_EDITION must be opensource or enterprise." ;;
  esac
  [[ "$O2_HTTP_PORT" =~ ^[0-9]+$ && "$O2_GRPC_PORT" =~ ^[0-9]+$ ]] || die "Ports must be numeric."
  [[ "$O2_ROOT_EMAIL" == *@*.* ]] || die "O2_ROOT_EMAIL is not a valid e-mail address."
  [[ "$O2_ROOT_PASSWORD" != *"'"* ]] || die "O2_ROOT_PASSWORD must not contain a single quote."
  [[ "$O2_DATA_DIR" == /* && "$O2_DATA_DIR" != "/" ]] || die "O2_DATA_DIR must be an absolute path."
}

#--- packages ------------------------------------------------------------------
install_deps() {
  # Install only what is missing: on EL9 "dnf install curl" conflicts with curl-minimal.
  local pkgs=()
  have curl || pkgs+=(curl)
  have tar  || pkgs+=(tar)
  have gzip || pkgs+=(gzip)
  if [[ "$OS_FAMILY" == "rhel" ]]; then
    [[ -e /etc/pki/tls/certs/ca-bundle.crt ]] || pkgs+=(ca-certificates)
    have sha256sum || pkgs+=(coreutils)
    if (( ${#pkgs[@]} )); then
      log "Installing: ${pkgs[*]}"
      dnf -y -q install "${pkgs[@]}"
    fi
  else
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || pkgs+=(ca-certificates)
    if (( ${#pkgs[@]} )); then
      log "Installing: ${pkgs[*]}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq "${pkgs[@]}" >/dev/null
    fi
  fi
}

#--- user / dirs ---------------------------------------------------------------
create_user_dirs() {
  local nologin
  nologin="$(command -v nologin || echo /bin/false)"
  getent group "$O2_GROUP" >/dev/null || groupadd --system "$O2_GROUP"
  if ! id -u "$O2_USER" >/dev/null 2>&1; then
    useradd --system --gid "$O2_GROUP" --home-dir "$O2_DATA_DIR" --no-create-home \
            --shell "$nologin" --comment "OpenObserve" "$O2_USER"
    log "Created system user $O2_USER"
  fi
  install -d -m 0750 -o "$O2_USER" -g "$O2_GROUP" "$O2_DATA_DIR"
  install -d -m 0750 -o root       -g "$O2_GROUP" "$O2_CONF_DIR"
}

#--- download / install binary -------------------------------------------------
fetch_tarball() {   # $1 = variant ("" | simd | musl)
  local variant="$1" suffix file url
  suffix="${ARCH}${variant:+-$variant}"
  file="${TAR_PREFIX}-${O2_VERSION}-linux-${suffix}.tar.gz"
  url="${O2_BASE_URL}/${REL_PATH}/${O2_VERSION}/${file}"
  log "Downloading $url"
  rm -rf "${TMP_DIR:?}/x"; mkdir -p "$TMP_DIR/x"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$TMP_DIR/o2.tar.gz" "$url" \
    || die "Download failed. Check O2_VERSION/O2_EDITION/O2_VARIANT and outbound HTTPS to downloads.openobserve.ai."

  if [[ -n "$O2_SHA256" ]]; then
    echo "${O2_SHA256}  $TMP_DIR/o2.tar.gz" | sha256sum -c --status - \
      || die "SHA256 mismatch for $file"
    log "SHA256 verified"
  fi

  tar -xzf "$TMP_DIR/o2.tar.gz" -C "$TMP_DIR/x"
  NEW_BIN="$(find "$TMP_DIR/x" -type f \( -name openobserve -o -name openobserve-ee \) | head -n1)"
  [[ -n "$NEW_BIN" ]] || die "openobserve binary not found inside $file"
  chmod 0755 "$NEW_BIN"
}

install_binary() {
  TMP_DIR="$(mktemp -d /tmp/o2-install.XXXXXX)"
  fetch_tarball "$O2_VARIANT"

  # glibc mismatch -> fall back to the static musl build (amd64 only)
  if [[ "$O2_VARIANT" != "musl" ]] && ldd "$NEW_BIN" 2>&1 | grep -q 'not found'; then
    if [[ "$ARCH" == "amd64" ]]; then
      warn "Binary has unresolved libraries on this host - switching to the musl build."
      fetch_tarball "musl"
    else
      die "Binary has unresolved libraries: $(ldd "$NEW_BIN" 2>&1 | grep 'not found' | head -n3)"
    fi
  fi

  if systemctl is-active --quiet openobserve 2>/dev/null; then
    log "Stopping running service for upgrade"
    systemctl stop openobserve
  fi
  install -m 0755 -o root -g root "$NEW_BIN" "$O2_BIN"
  have restorecon && restorecon -F "$O2_BIN" 2>/dev/null || true
  log "Installed $O2_BIN ($O2_EDITION $O2_VERSION)"
}

#--- config --------------------------------------------------------------------
gen_password() {
  # 3 fixed chars for complexity + 24 hex chars of entropy
  printf 'Oo#%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

env_get() { sed -n "s/^$1=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}\$/\1/p" "$O2_ENV_FILE" | tail -n1; }

write_env() {
  if [[ -f "$O2_ENV_FILE" ]]; then
    log "Keeping existing $O2_ENV_FILE"
    O2_HTTP_PORT="$(env_get ZO_HTTP_PORT)"; O2_HTTP_PORT="${O2_HTTP_PORT:-5080}"
    O2_GRPC_PORT="$(env_get ZO_GRPC_PORT)"; O2_GRPC_PORT="${O2_GRPC_PORT:-5081}"
    O2_ROOT_EMAIL="$(env_get ZO_ROOT_USER_EMAIL)"
    return 0
  fi

  if [[ -z "$O2_ROOT_PASSWORD" ]]; then
    O2_ROOT_PASSWORD="$(gen_password)"
    PW_GENERATED=1
  fi

  umask 027
  cat > "$O2_ENV_FILE" <<EOF
# OpenObserve environment - managed by install-openobserve.sh
# Full variable reference: https://openobserve.ai/docs/environment-variables/
# Root credentials are only read on FIRST start (when the data dir is empty).
ZO_ROOT_USER_EMAIL='${O2_ROOT_EMAIL}'
ZO_ROOT_USER_PASSWORD='${O2_ROOT_PASSWORD}'

ZO_LOCAL_MODE=true
ZO_DATA_DIR=${O2_DATA_DIR%/}/
ZO_HTTP_PORT=${O2_HTTP_PORT}
ZO_GRPC_PORT=${O2_GRPC_PORT}
ZO_TELEMETRY=false
EOF
  [[ -n "$O2_BIND_ADDR" ]] && echo "ZO_HTTP_ADDR=${O2_BIND_ADDR}" >> "$O2_ENV_FILE"
  umask 022
  chown root:"$O2_GROUP" "$O2_ENV_FILE"
  chmod 0640 "$O2_ENV_FILE"
  log "Wrote $O2_ENV_FILE"
}

write_unit() {
  cat > "$O2_UNIT" <<EOF
[Unit]
Description=OpenObserve - logs, metrics, traces
Documentation=https://openobserve.ai/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${O2_USER}
Group=${O2_GROUP}
EnvironmentFile=${O2_ENV_FILE}
WorkingDirectory=${O2_DATA_DIR}
ExecStart=${O2_BIN}
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=65535
SyslogIdentifier=openobserve

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$O2_UNIT"
  have restorecon && restorecon -F "$O2_UNIT" 2>/dev/null || true
  systemctl daemon-reload
  log "Wrote $O2_UNIT"
}

#--- firewall ------------------------------------------------------------------
open_firewall() {
  [[ "$O2_OPEN_FIREWALL" == "yes" ]] || { log "Firewall untouched (O2_OPEN_FIREWALL=$O2_OPEN_FIREWALL)"; return 0; }
  if have firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd -q --permanent --add-port="${O2_HTTP_PORT}/tcp"
    firewall-cmd -q --permanent --add-port="${O2_GRPC_PORT}/tcp"
    firewall-cmd -q --reload
    log "firewalld: opened ${O2_HTTP_PORT}/tcp, ${O2_GRPC_PORT}/tcp"
  elif have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${O2_HTTP_PORT}/tcp" >/dev/null
    ufw allow "${O2_GRPC_PORT}/tcp" >/dev/null
    log "ufw: opened ${O2_HTTP_PORT}/tcp, ${O2_GRPC_PORT}/tcp"
  else
    log "No active firewalld/ufw - nothing to open"
  fi
}

#--- start / verify ------------------------------------------------------------
start_service() {
  chown -R "$O2_USER":"$O2_GROUP" "$O2_DATA_DIR"
  systemctl enable -q openobserve
  systemctl restart openobserve
  log "Waiting for OpenObserve on port ${O2_HTTP_PORT}"
  local i
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${O2_HTTP_PORT}/healthz" 2>/dev/null; then
      log "Health check OK (${i}s)"
      return 0
    fi
    systemctl is-active --quiet openobserve || break
    sleep 1
  done
  warn "Service did not become healthy. Last log lines:"
  journalctl -u openobserve -n 40 --no-pager >&2 || true
  die "OpenObserve failed to start."
}

summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; ip="${ip:-<server-ip>}"
  cat <<EOF

${c_b}OpenObserve ${O2_VERSION} (${O2_EDITION}) is running${c_0}
  UI            : http://${ip}:${O2_HTTP_PORT}
  OTLP HTTP     : http://${ip}:${O2_HTTP_PORT}/api/default
  OTLP gRPC     : ${ip}:${O2_GRPC_PORT}
  Login e-mail  : ${O2_ROOT_EMAIL}
EOF
  if (( PW_GENERATED )); then
    echo "  Password      : ${O2_ROOT_PASSWORD}   (generated - also in ${O2_ENV_FILE})"
  else
    echo "  Password      : as set in ${O2_ENV_FILE}"
  fi
  cat <<EOF
  Config        : ${O2_ENV_FILE}
  Data          : ${O2_DATA_DIR}
  Service       : systemctl {status|restart|stop} openobserve
  Logs          : journalctl -u openobserve -f
  Upgrade       : O2_VERSION=vX.Y.Z bash $0
EOF
}

#--- uninstall -----------------------------------------------------------------
uninstall() {
  local purge="$1"
  systemctl disable --now openobserve 2>/dev/null || true
  rm -f "$O2_UNIT" "$O2_BIN"
  systemctl daemon-reload
  if [[ "$purge" == "1" ]]; then
    local data_dir
    data_dir="$( [[ -f "$O2_ENV_FILE" ]] && env_get ZO_DATA_DIR || true )"
    data_dir="${data_dir:-$O2_DATA_DIR}"; data_dir="${data_dir%/}"
    [[ -n "$data_dir" && "$data_dir" != "/" ]] && rm -rf "$data_dir"
    rm -rf "$O2_CONF_DIR"
    id -u "$O2_USER" >/dev/null 2>&1 && userdel "$O2_USER" 2>/dev/null || true
    getent group "$O2_GROUP" >/dev/null && groupdel "$O2_GROUP" 2>/dev/null || true
    log "OpenObserve purged (binary, unit, config, data, user)."
  else
    log "OpenObserve removed. Kept: $O2_CONF_DIR and $O2_DATA_DIR"
  fi
}

#--- main ----------------------------------------------------------------------
main() {
  require_root
  case "${1:-}" in
    --uninstall) uninstall 0; exit 0 ;;
    --purge)     uninstall 1; exit 0 ;;
    ""|--install) ;;
    -h|--help)   sed -n '2,31p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (use --uninstall, --purge or --help)" ;;
  esac

  detect_os
  detect_arch
  validate_input
  install_deps
  create_user_dirs
  install_binary
  write_env
  write_unit
  open_firewall
  start_service
  summary
}

main "$@"

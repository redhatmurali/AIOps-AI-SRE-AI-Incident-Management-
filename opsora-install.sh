#!/usr/bin/env bash
# =============================================================================
# OPSORA - single-file native installer for Ubuntu Server 24.04 LTS
#
# Native only: apt, vendor apt repos, signed .deb, official binaries, venv/pipx,
# systemd, Nginx. This script never installs Docker, Podman, containerd,
# Kubernetes, K3s, MicroK8s, Minikube or Helm.
#
# Usage:
#   sudo bash opsora-install.sh                 full install
#   sudo bash opsora-install.sh --phase NAME    preflight|os|security|web|database|
#                                               observability|ai|automation|
#                                               validation|backup
#   sudo bash opsora-install.sh --component X   one step (see --list)
#   sudo bash opsora-install.sh --list          list steps
#   sudo bash opsora-install.sh --help
#
# First run writes /opt/opsora/config/install.env (mode 600). Any variable in
# that file can be pre-seeded from the environment on the first run, e.g.:
#   sudo OPENOBSERVE_DOMAIN=observe.example.com LETSENCRYPT_EMAIL=me@example.com \
#        bash opsora-install.sh
# Later runs read the file; edit it and re-run. Re-running is safe.
#
# The script never runs DROP DATABASE, DROP TABLE, terraform destroy, or rm -rf
# on data directories.
# =============================================================================
set -Eeuo pipefail
shopt -s lastpipe          # so '... | write_file' can report WF_CHANGED
umask 022
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C.UTF-8

# ----------------------------------------------------------------------------
# Pinned versions (verified against upstream on 2026-10-05)
# ----------------------------------------------------------------------------
: "${POSTGRES_VERSION:=17}"
: "${OPENOBSERVE_VERSION:=1.0.4}"
: "${ALLOY_VERSION:=1.20.1}"
: "${PROMETHEUS_VERSION:=3.13.4}"          # LTS line
: "${ALERTMANAGER_VERSION:=0.34.1}"
: "${NODE_EXPORTER_VERSION:=1.12.1}"
: "${POSTGRES_EXPORTER_VERSION:=0.20.1}"
: "${MYSQLD_EXPORTER_VERSION:=0.20.0}"
: "${SNMP_EXPORTER_VERSION:=0.30.1}"
: "${BLACKBOX_EXPORTER_VERSION:=0.28.0}"
: "${KEEP_REF:=v0.54.3}"
: "${KEEP_NODE_MAJOR:=20}"
: "${HOLMESGPT_VERSION:=0.42.0}"
: "${K8SGPT_VERSION:=0.4.39}"
: "${KUBECTL_VERSION:=1.37.1}"
: "${OPENRCA_COMMIT:=c1bd4af7f635171a1c31cdd567c07d698dff6abc}"
: "${PGADMIN_VERSION:=9.18}"
: "${ANSIBLE_CORE_VERSION:=2.21.4}"
: "${TERRAFORM_VERSION:=1.16.5}"
: "${SEMAPHORE_VERSION:=2.19.12}"

# SHA256 of linux-amd64 artifacts as published on prometheus.io/download.
# Each download is also checked against the release's own sha256sums.txt.
declare -A PINNED_SHA256=(
  ["prometheus-3.13.4.linux-amd64.tar.gz"]="87f21a66f96c597a189cef8d640e8921b621fc17a9feff707c332c4f3b3ddd56"
  ["alertmanager-0.34.1.linux-amd64.tar.gz"]="265b9d1e55ef0d5306a436018af6d2b686c2ce051f03d968f7464ecb1372a7e8"
  ["node_exporter-1.12.1.linux-amd64.tar.gz"]="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
  ["mysqld_exporter-0.20.0.linux-amd64.tar.gz"]="5773496e9962ca3817b3599fe4d74f218c95c1295eb2a742462df8e035fe51bd"
  ["blackbox_exporter-0.28.0.linux-amd64.tar.gz"]="caf5d242fb1cf6d5cb678f3f799f22703d4fafea26b03dcbbd7e1f1825e06329"
  ["snmp_exporter-0.30.1.linux-amd64.tar.gz"]="026aac4e23447ed593a783eccab9089cd41d77d17c9d2a0ab84398e45a0bb93e"
  ["k8sgpt_amd64.deb@0.4.39"]="1248e8f1cafca15a9b4a75ee0038981c1b9faf4222e8a96c371117d97f3e2469"
  ["semaphore_2.19.12_linux_amd64.deb"]="a5c1bd199a6c756b993567a86aea9e74b5760dd2bfd6e3cc5298921008409b59"
)

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
OPSORA_HOME=/opt/opsora
CONF_FILE=$OPSORA_HOME/config/install.env
SECRETS_DIR=/etc/opsora/secrets
STATE_DIR=/var/lib/opsora
LOG_DIR=/var/log/opsora
CACHE_DIR=/var/cache/opsora
DOC_DIR=$OPSORA_HOME/documentation
RUN_TS=$(date +%Y%m%d-%H%M%S)
PRE_BACKUP_DIR=$OPSORA_HOME/backups/pre-change/$RUN_TS
STATUS_FILE=$STATE_DIR/status.tsv
VERSIONS_FILE=$STATE_DIR/versions.tsv
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=; C_R=; C_Y=; C_B=; C_0=; fi
log()  { printf '%s [INFO] %s\n' "$(date +%T)" "$*"; }
warn() { printf '%s %s[WARN]%s %s\n' "$(date +%T)" "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s %s[FAIL]%s %s\n' "$(date +%T)" "$C_R" "$C_0" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "============================================================"; }
have() { command -v "$1" >/dev/null 2>&1; }
is_true() { [[ "${1:-}" =~ ^(1|true|yes|on)$ ]]; }

# status NAME PASS|FAIL|WARNING|SKIPPED "message"
status() {
  mkdir -p "$STATE_DIR"
  local tmp; tmp=$(mktemp)
  [[ -f $STATUS_FILE ]] && awk -F'\t' -v n="$1" '$1!=n' "$STATUS_FILE" >"$tmp"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -Is)" "${3:-}" >>"$tmp"
  install -m 0644 "$tmp" "$STATUS_FILE"; rm -f "$tmp"
}
# record_version COMPONENT VERSION SOURCE BINARY CONFIG UNIT NOTES
record_version() {
  mkdir -p "$STATE_DIR"
  local tmp; tmp=$(mktemp)
  [[ -f $VERSIONS_FILE ]] && awk -F'\t' -v n="$1" '$1!=n' "$VERSIONS_FILE" >"$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%F)" "${4:--}" "${5:--}" "${6:--}" "${7:-}" >>"$tmp"
  install -m 0644 "$tmp" "$VERSIONS_FILE"; rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# File helpers (idempotent, back up before overwrite)
# ----------------------------------------------------------------------------
backup_path() {
  local p
  for p in "$@"; do
    [[ -e $p ]] || continue
    mkdir -p "$PRE_BACKUP_DIR"; chmod 700 "$OPSORA_HOME/backups" "$PRE_BACKUP_DIR" 2>/dev/null || true
    [[ -e "$PRE_BACKUP_DIR$p" ]] || cp -a --parents "$p" "$PRE_BACKUP_DIR/"
  done
}
WF_CHANGED=0
# write_file PATH [MODE] [OWNER:GROUP]   (content on stdin). Sets WF_CHANGED.
write_file() {
  local path=$1 mode=${2:-0644} owner=${3:-root:root} tmp
  tmp=$(mktemp); cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    WF_CHANGED=0; rm -f "$tmp"
  else
    backup_path "$path"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
    WF_CHANGED=1; rm -f "$tmp"
  fi
  chmod "$mode" "$path"; chown "$owner" "$path"
}
gen_secret() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-32}"; }
# secret NAME [LEN] -> prints secret, creating it once
secret() {
  local f=$SECRETS_DIR/$1
  if [[ ! -s $f ]]; then
    install -d -m 0700 "$SECRETS_DIR"
    ( umask 077; gen_secret "${2:-32}" >"$f" )
  fi
  chmod 600 "$f"; cat "$f"
}
ensure_user() { # NAME HOME [EXTRA_GROUPS]
  local name=$1 home=$2 groups=${3:-}
  getent group "$name" >/dev/null || groupadd --system "$name"
  if ! id "$name" >/dev/null 2>&1; then
    useradd --system --gid "$name" --home-dir "$home" --shell /usr/sbin/nologin "$name"
  fi
  install -d -m 0750 -o "$name" -g "$name" "$home"
  [[ -n $groups ]] && usermod -aG "$groups" "$name"
  return 0
}
apt_install() { apt-get install -y --no-install-recommends "$@"; }
APT_UPDATED=0
apt_update() { apt-get update -q || warn "apt-get update reported errors (continuing with existing package lists)"; APT_UPDATED=1; }
apt_update_once() { (( APT_UPDATED )) || apt_update; }

fetch() { # URL DEST
  local url=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  [[ -s $dest ]] && return 0
  log "download $url"
  curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$dest.part" "$url" \
    || { rm -f "$dest.part"; die "download failed: $url"; }
  mv "$dest.part" "$dest"
}
verify_sha256() { # FILE EXPECTED
  local got; got=$(sha256sum "$1" | awk '{print $1}')
  [[ $got == "$2" ]] || { rm -f "$1"; die "SHA256 mismatch for $1 (expected $2, got $got) - file removed"; }
}
# verify_from_sums FILE SUMS_URL [NAME_IN_SUMS] [PINNED_KEY]
verify_from_sums() {
  local file=$1 sums_url=$2 name=${3:-$(basename "$1")} key=${4:-$(basename "$1")} sums exp
  sums=$(curl -fsSL --retry 3 --connect-timeout 20 "$sums_url") || die "cannot fetch checksums: $sums_url"
  exp=$(awk -v n="$name" '$2==n || $2=="*"n {print $1}' <<<"$sums" | head -1)
  [[ -n $exp ]] || die "no checksum for $name in $sums_url"
  verify_sha256 "$file" "$exp"
  if [[ -n ${PINNED_SHA256[$key]:-} ]]; then
    [[ ${PINNED_SHA256[$key]} == "$exp" ]] || die "checksum for $key differs from the value pinned in this script"
  fi
  log "checksum OK: $name"
}
wait_http() { # URL [TRIES] [CURL_ARGS...]
  local url=$1 tries=${2:-30} i; shift; shift || true
  for ((i=0; i<tries; i++)); do
    curl -fsS -o /dev/null --max-time 5 "$@" "$url" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
wait_port() { local i; for ((i=0; i<${3:-30}; i++)); do (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && return 0; sleep 2; done; return 1; }
svc_enable_restart() { # UNIT [CHANGED]
  systemctl daemon-reload
  systemctl enable "$1" >/dev/null 2>&1 || true
  if [[ ${2:-1} == 1 ]] || ! systemctl is-active --quiet "$1"; then systemctl restart "$1"; fi
}
ram_mb()  { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
clamp()   { local v=$1; (( v < $2 )) && v=$2; (( v > $3 )) && v=$3; echo "$v"; }
pg()      { runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -q "$@"; }
pg_port() { pg_lsclusters -h 2>/dev/null | awk -v v="$POSTGRES_VERSION" '$1==v && $2=="main" {print $3}'; }

# ----------------------------------------------------------------------------
# Configuration file
# ----------------------------------------------------------------------------
write_default_config() {
  install -d -m 0750 "$OPSORA_HOME" "$OPSORA_HOME/config"
  ( umask 077; cat >"$CONF_FILE" <<EOF
# OPSORA installer configuration. No secrets here: generated secrets live in
# $SECRETS_DIR (mode 600). Edit and re-run the installer.

# --- identity ---------------------------------------------------------------
OPSORA_ADMIN_EMAIL="${OPSORA_ADMIN_EMAIL:-admin@opsora.local}"   # login for OpenObserve/pgAdmin/Semaphore
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"                        # required for TLS certificates

# --- public hostnames (leave empty = UI stays on localhost, use an SSH tunnel)
OPENOBSERVE_DOMAIN="${OPENOBSERVE_DOMAIN:-}"
PROMETHEUS_DOMAIN="${PROMETHEUS_DOMAIN:-}"
ALERTMANAGER_DOMAIN="${ALERTMANAGER_DOMAIN:-}"
KEEP_DOMAIN="${KEEP_DOMAIN:-}"
PGADMIN_DOMAIN="${PGADMIN_DOMAIN:-}"
SEMAPHORE_DOMAIN="${SEMAPHORE_DOMAIN:-}"
REDIS_INSIGHT_DOMAIN="${REDIS_INSIGHT_DOMAIN:-}"                  # reserved, see ENABLE_REDIS_INSIGHT

# --- network ----------------------------------------------------------------
TRUSTED_NETWORKS="${TRUSTED_NETWORKS:-}"          # space separated CIDRs, e.g. "10.0.0.0/8 192.168.10.0/24"
RESTRICT_UI_TO_TRUSTED="${RESTRICT_UI_TO_TRUSTED:-false}"   # true = web UIs only from TRUSTED_NETWORKS
OTLP_BIND="${OTLP_BIND:-127.0.0.1}"               # set to a private IP to receive OTLP from TRUSTED_NETWORKS
CONFIGURE_UFW="${CONFIGURE_UFW:-true}"

# --- SSH hardening (both off by default so nobody gets locked out) -----------
SSH_DISABLE_PASSWORD_LOGIN="${SSH_DISABLE_PASSWORD_LOGIN:-false}"
SSH_DISABLE_ROOT_LOGIN="${SSH_DISABLE_ROOT_LOGIN:-false}"

# --- database ---------------------------------------------------------------
POSTGRES_VERSION=${POSTGRES_VERSION}
POSTGRES_DB="${POSTGRES_DB:-opsora}"
POSTGRES_USER="${POSTGRES_USER:-opsora_app}"

# --- AI ---------------------------------------------------------------------
# AI_PROVIDER: openai | anthropic | azure | ... (HolmesGPT uses LiteLLM model names)
# Put the API key in $SECRETS_DIR/ai.env as e.g. OPENAI_API_KEY=... or ANTHROPIC_API_KEY=...
AI_PROVIDER="${AI_PROVIDER:-}"
AI_MODEL="${AI_MODEL:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"            # optional: copied to /etc/opsora/kubeconfigs/default.yaml

# --- optional components ----------------------------------------------------
ENABLE_KEEP="${ENABLE_KEEP:-true}"                # built from source: not a vendor-supported install path
ENABLE_OPENRCA="${ENABLE_OPENRCA:-true}"          # benchmark checkout only, no service
OPENRCA_INSTALL_DEPS="${OPENRCA_INSTALL_DEPS:-false}"
ENABLE_REDIS_INSIGHT="${ENABLE_REDIS_INSIGHT:-false}"   # no official headless Linux build: postponed

# --- retention / alerting ---------------------------------------------------
OPENOBSERVE_RETENTION_DAYS="${OPENOBSERVE_RETENTION_DAYS:-30}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"        # extra Alertmanager webhook (future OPSORA API)

# --- download overrides -----------------------------------------------------
# OpenObserve 1.x binaries are no longer attached to GitHub releases. This URL
# follows the pattern of https://openobserve.ai/downloads; change it if the
# download step reports 404. Set OPENOBSERVE_SHA256 to enforce a checksum.
OPENOBSERVE_URL="${OPENOBSERVE_URL:-}"
OPENOBSERVE_SHA256="${OPENOBSERVE_SHA256:-}"
EOF
  )
  chmod 600 "$CONF_FILE"
  sed 's/=".*@.*"/=""/' "$CONF_FILE" >"$OPSORA_HOME/config/install.env.example"; chmod 644 "$OPSORA_HOME/config/install.env.example"
  log "wrote $CONF_FILE"
}
load_config() {
  [[ -f $CONF_FILE ]] || write_default_config
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  : "${OPENOBSERVE_URL:=}"
  [[ -n $OPENOBSERVE_URL ]] || OPENOBSERVE_URL="https://downloads.openobserve.ai/releases/openobserve/v${OPENOBSERVE_VERSION}/openobserve-v${OPENOBSERVE_VERSION}-linux-${ARCH}.tar.gz"
  SSH_PORT=$( { sshd -T 2>/dev/null || true; } | awk '$1=="port"{print $2; exit}'); SSH_PORT=${SSH_PORT:-22}
  # only emit IPv6 listeners when the kernel has IPv6 enabled
  L6_80=""; L6_80D=""; L6_443=""
  if [[ -f /proc/net/if_inet6 ]]; then L6_80="listen [::]:80;"; L6_80D="listen [::]:80 default_server;"; L6_443="listen [::]:443 ssl http2;"; fi
}
all_domains() {
  local d
  for d in "$OPENOBSERVE_DOMAIN" "$PROMETHEUS_DOMAIN" "$ALERTMANAGER_DOMAIN" "$KEEP_DOMAIN" "$PGADMIN_DOMAIN" "$SEMAPHORE_DOMAIN"; do
    [[ -n $d ]] && echo "$d"
  done
  return 0
}

# =============================================================================
# STEP: preflight
# =============================================================================
step_preflight() {
  local fail=0 ram disk
  hr; echo "OPSORA PREFLIGHT REPORT"; hr
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%-18s %s\n' "Hostname" "$(hostname)" "FQDN" "$(hostname -f 2>/dev/null || hostname)" \
    "OS" "$PRETTY_NAME" "Kernel" "$(uname -r)" "Architecture" "$ARCH" \
    "CPU cores" "$(nproc)" "RAM" "$(ram_mb) MB" \
    "Swap" "$(awk '/SwapTotal/ {printf "%d MB", $2/1024}' /proc/meminfo)" \
    "Load" "$(cut -d' ' -f1-3 /proc/loadavg)" \
    "Timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)" \
    "SSH port" "$SSH_PORT"
  echo; echo "IP addresses:";  ip -br addr 2>/dev/null | awk '{print "  " $0}'
  echo; echo "Filesystems:";   df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk '{print "  " $0}'
  echo
  [[ ${VERSION_ID:-} == "24.04" ]] || { warn "Ubuntu 24.04 required, found ${PRETTY_NAME}"; is_true "${ALLOW_UNSUPPORTED_OS:-false}" || fail=1; }
  [[ $ARCH == amd64 || $ARCH == arm64 ]] || { warn "unsupported architecture $ARCH"; fail=1; }
  [[ $(ps -p 1 -o comm= 2>/dev/null) == systemd ]] || { warn "PID 1 is not systemd"; fail=1; }
  ram=$(ram_mb); (( ram >= 15000 )) || warn "RAM ${ram} MB is below the 16 GB practical minimum (64 GB recommended)"
  disk=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9); (( ${disk:-0} >= 50 )) || warn "only ${disk:-?} GB free under /var/lib (1 TB+ recommended)"
  local rt found=""
  for rt in docker dockerd podman containerd k3s microk8s minikube kubelet helm; do have "$rt" && found+=" $rt"; done
  if [[ -n $found ]]; then warn "container/Kubernetes tooling already present:$found (not installed by OPSORA, left untouched)"
  else echo "Container runtimes: none (as required)"; fi
  echo "Listening ports that OPSORA wants:"
  local p owner
  for p in 80 443 3000 3001 4317 4318 5050 5080 5081 5432 6379 8080 9090 9093 9100 9104 9115 9116 9187 12345; do
    owner=$(ss -H -ltnp "sport = :$p" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)
    [[ -n $owner ]] && printf '  %-6s in use by %s\n' "$p" "$owner"
  done
  echo "Public domains configured: $(all_domains | tr '\n' ' ')"
  [[ -z $(all_domains) ]] && echo "  none -> no ports 80/443 opened, UIs reachable on 127.0.0.1 only (SSH tunnel)"
  hr
  (( fail == 0 )) || die "preflight failed"
}

# =============================================================================
# STEP: os  (base packages, directories, kernel limits)
# =============================================================================
step_os() {
  apt_update
  apt_install ca-certificates curl gnupg lsb-release jq git unzip tar openssl rsync acl \
    python3 python3-venv python3-pip python3-dev pipx build-essential pkg-config \
    libpq-dev libffi-dev libssl-dev libkrb5-dev dnsutils iproute2 logrotate
  install -d -m 0755 "$OPSORA_HOME" "$OPSORA_HOME"/{scripts,logs,ansible,terraform,documentation,runbooks,integrations,tmp,research} \
    "$OPSORA_HOME"/configs/{alloy,prometheus,alertmanager,openobserve,keep,holmesgpt,k8sgpt} \
    /etc/opsora "$STATE_DIR" "$LOG_DIR" "$CACHE_DIR"
  install -d -m 0700 "$OPSORA_HOME/backups" "$OPSORA_HOME/config" "$SECRETS_DIR"
  [[ -e $OPSORA_HOME/secrets ]] || ln -s "$SECRETS_DIR" "$OPSORA_HOME/secrets"
  ensure_user opsora "$STATE_DIR/opsora"
  write_file /etc/sysctl.d/90-opsora.conf <<'EOF'
# OPSORA: file watchers for log tailing, sane swap behaviour for a database host
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
vm.swappiness = 10
EOF
  if (( WF_CHANGED )); then sysctl -p /etc/sysctl.d/90-opsora.conf >/dev/null || warn "some sysctl keys could not be applied"; fi
  write_file /etc/logrotate.d/opsora <<EOF
$LOG_DIR/*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
EOF
  status os PASS "base packages and directories"
}

# =============================================================================
# STEP: time
# =============================================================================
step_time() {
  if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    log "chrony already active, leaving it in charge"
  else
    apt_install systemd-timesyncd
    systemctl enable --now systemd-timesyncd
    timedatectl set-ntp true || true
  fi
  local i
  for i in {1..15}; do [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && break; sleep 2; done
  timedatectl | sed 's/^/  /'
  if [[ $(timedatectl show -p NTPSynchronized --value) == yes ]]; then status time PASS "NTP synchronized"
  else status time WARNING "clock not yet reported as synchronized"; fi
}

# =============================================================================
# STEP: security  (UFW, SSH, Fail2ban)
# =============================================================================
setup_fail2ban() {
  apt_install fail2ban
  local ignore="127.0.0.1/8 ::1 ${TRUSTED_NETWORKS:-}" nginx_jail=false
  [[ -f /var/log/nginx/error.log ]] && nginx_jail=true
  write_file /etc/fail2ban/jail.d/opsora.local <<EOF
[DEFAULT]
ignoreip = $ignore
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT

[nginx-http-auth]
enabled  = $nginx_jail
backend  = auto
logpath  = /var/log/nginx/*error.log
maxretry = 8
EOF
  svc_enable_restart fail2ban "$WF_CHANGED"
}
step_security() {
  # --- UFW ---
  if is_true "$CONFIGURE_UFW"; then
    apt_install ufw
    backup_path /etc/ufw
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "$SSH_PORT/tcp" comment 'OPSORA ssh' >/dev/null      # before enable: never lock out SSH
    if [[ -n $(all_domains) ]]; then
      ufw allow 80/tcp comment 'OPSORA http (ACME + redirect)' >/dev/null
      ufw allow 443/tcp comment 'OPSORA https' >/dev/null
    fi
    if [[ $OTLP_BIND != 127.0.0.1 ]]; then
      local n
      for n in $TRUSTED_NETWORKS; do
        ufw allow from "$n" to any port 4317 proto tcp comment 'OPSORA otlp grpc' >/dev/null
        ufw allow from "$n" to any port 4318 proto tcp comment 'OPSORA otlp http' >/dev/null
      done
    fi
    ufw --force enable >/dev/null
    ufw status verbose | sed 's/^/  /'
  else
    warn "CONFIGURE_UFW=false: firewall left untouched"
  fi
  # --- SSH (opt-in, validated, reload not restart) ---
  local want_pw=yes want_root="" keys=0 u
  for u in "${SUDO_USER:-}" root; do
    [[ -n $u ]] || continue
    [[ -s $(getent passwd "$u" | cut -d: -f6)/.ssh/authorized_keys ]] && keys=1
  done
  if is_true "$SSH_DISABLE_PASSWORD_LOGIN"; then
    if (( keys )); then want_pw=no; else warn "no authorized_keys found for ${SUDO_USER:-root}: password login NOT disabled"; fi
  fi
  if is_true "$SSH_DISABLE_ROOT_LOGIN"; then
    if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then want_root=no; else warn "running directly as root: root login NOT disabled"; fi
  fi
  if ! have sshd; then warn "sshd not found: SSH hardening skipped"; else
  backup_path /etc/ssh/sshd_config /etc/ssh/sshd_config.d
  {
    echo "# Managed by OPSORA installer"
    echo "PasswordAuthentication $want_pw"
    [[ $want_pw == no ]] && echo "KbdInteractiveAuthentication no"
    [[ -n $want_root ]] && echo "PermitRootLogin no"
    echo "MaxAuthTries 4"
    echo "LoginGraceTime 30"
    echo "X11Forwarding no"
  } | write_file /etc/ssh/sshd_config.d/90-opsora.conf 0644
  if sshd -t; then
    (( WF_CHANGED )) && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }
  else
    rm -f /etc/ssh/sshd_config.d/90-opsora.conf
    die "sshd rejected the new configuration; drop-in removed, SSH left unchanged"
  fi
  fi
  setup_fail2ban
  status security PASS "ufw=$(is_true "$CONFIGURE_UFW" && echo on || echo untouched) ssh-password=$want_pw fail2ban=on"
}

# =============================================================================
# STEP: nginx  (package, hardening snippets, local health endpoint)
# =============================================================================
step_nginx() {
  apt_install nginx certbot
  backup_path /etc/nginx
  install -d -m 0755 /var/www/letsencrypt
  write_file /etc/nginx/conf.d/00-opsora-base.conf <<'EOF'
# Managed by OPSORA installer
server_tokens off;
map $http_upgrade $opsora_connection_upgrade { default upgrade; '' close; }
server {
    listen 127.0.0.1:8088;
    server_name localhost;
    access_log off;
    location = /nginx-health { return 200 "ok\n"; }
    location = /nginx-status { stub_status; allow 127.0.0.1; deny all; }
}
EOF
  write_file /etc/nginx/snippets/opsora-security.conf <<'EOF'
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF
  write_file /etc/nginx/snippets/opsora-proxy.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $opsora_connection_upgrade;
proxy_connect_timeout 15s;
proxy_send_timeout 300s;
proxy_read_timeout 300s;
proxy_buffering off;
EOF
  write_file /etc/nginx/snippets/opsora-tls.conf <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_timeout 1d;
ssl_session_cache shared:OPSORA:10m;
ssl_session_tickets off;
EOF
  # default site answers for any unknown Host; do not leak backends through it
  if [[ -L /etc/nginx/sites-enabled/default ]]; then rm -f /etc/nginx/sites-enabled/default; fi
  write_file /etc/nginx/conf.d/01-opsora-default.conf <<EOF
server {
    listen 80 default_server;
    $L6_80D
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 444; }
}
EOF
  nginx -t
  systemctl enable nginx >/dev/null 2>&1
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  setup_fail2ban
  record_version nginx "$(nginx -v 2>&1 | sed 's/.*nginx\///')" "Ubuntu apt" /usr/sbin/nginx /etc/nginx nginx.service "reverse proxy"
  status nginx PASS "installed, config valid"
}

# =============================================================================
# STEP: postgresql  (PGDG repo, PostgreSQL 17, roles, databases, tuning)
# =============================================================================
pg_role() { # ROLE PASSWORD CONNLIMIT [EXTRA]
  pg -v r="$1" -v pw="$2" -v cl="$3" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s', :'r', :'pw', :'cl')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'r') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s NOSUPERUSER NOCREATEDB NOCREATEROLE', :'r', :'pw', :'cl') \gexec
SQL
}
pg_db() { # DB OWNER
  pg -v d="$1" -v r="$2" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'d', :'r')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'d') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'d') \gexec
SQL
}
step_postgresql() {
  apt_update_once
  apt_install postgresql-common
  if [[ ! -f /etc/apt/sources.list.d/pgdg.sources && ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y        # official PGDG repo setup shipped by Ubuntu
    apt_update
  fi
  apt_install "postgresql-$POSTGRES_VERSION" "postgresql-client-$POSTGRES_VERSION"
  local port ram sb ecs mwm confd changed=0
  port=$(pg_port); [[ -n $port ]] || die "PostgreSQL $POSTGRES_VERSION main cluster not found (pg_lsclusters)"
  confd=/etc/postgresql/$POSTGRES_VERSION/main/conf.d
  backup_path "/etc/postgresql/$POSTGRES_VERSION/main"
  ram=$(ram_mb)
  sb=$(clamp $(( ram / 5 )) 256 16384); ecs=$(clamp $(( ram / 2 )) 512 98304); mwm=$(clamp $(( ram / 16 )) 64 2048)
  write_file "$confd/90-opsora.conf" 0644 postgres:postgres <<EOF
# Managed by OPSORA installer (sized for ${ram} MB RAM shared with other services)
listen_addresses = 'localhost'
max_connections = 200
password_encryption = 'scram-sha-256'
shared_buffers = ${sb}MB
effective_cache_size = ${ecs}MB
maintenance_work_mem = ${mwm}MB
work_mem = 16MB
wal_level = replica
wal_compression = on
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
logging_collector = off
log_line_prefix = '%m [%p] %q%u@%d '
log_min_duration_statement = 1000
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 1000
shared_preload_libraries = 'pg_stat_statements'
EOF
  changed=$WF_CHANGED
  # pg_hba: PGDG defaults are peer for local and scram-sha-256 for 127.0.0.1/::1. Verify, never widen.
  if grep -Eq '^\s*host\s+\S+\s+\S+\s+(0\.0\.0\.0/0|::/0)' "/etc/postgresql/$POSTGRES_VERSION/main/pg_hba.conf"; then
    warn "pg_hba.conf contains a 0.0.0.0/0 or ::/0 rule - review it"
  fi
  systemctl enable "postgresql@$POSTGRES_VERSION-main" >/dev/null 2>&1 || true
  if (( changed )); then systemctl restart "postgresql@$POSTGRES_VERSION-main"; else systemctl start "postgresql@$POSTGRES_VERSION-main"; fi
  local i; for i in {1..30}; do pg_isready -q -h 127.0.0.1 -p "$port" && break; sleep 1; done
  pg_isready -h 127.0.0.1 -p "$port" || die "PostgreSQL not ready"

  pg_role "$POSTGRES_USER" "$(secret pg_opsora_app)" 80
  pg_db   "$POSTGRES_DB" "$POSTGRES_USER"
  pg_role opsora_monitor "$(secret pg_monitor)" 5
  pg -c "GRANT pg_monitor TO opsora_monitor" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
  ( umask 077; cat >"$SECRETS_DIR/postgres.env" <<EOF
PGHOST=127.0.0.1
PGPORT=$port
PGDATABASE=$POSTGRES_DB
PGUSER=$POSTGRES_USER
PGPASSWORD=$(secret pg_opsora_app)
DATABASE_URL=postgresql://$POSTGRES_USER:$(secret pg_opsora_app)@127.0.0.1:$port/$POSTGRES_DB
EOF
  )
  # application-level read/write test with the non-superuser role
  PGPASSWORD=$(secret pg_opsora_app) psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS opsora_selftest;
CREATE TABLE IF NOT EXISTS opsora_selftest.install_check (id bigserial PRIMARY KEY, checked_at timestamptz NOT NULL DEFAULT now(), note text);
INSERT INTO opsora_selftest.install_check (note) VALUES ('installer read/write test');
SELECT count(*) AS selftest_rows FROM opsora_selftest.install_check;
SQL
  record_version postgresql "$(pg -Atc 'show server_version')" "apt.postgresql.org (PGDG)" "/usr/lib/postgresql/$POSTGRES_VERSION/bin/postgres" \
    "/etc/postgresql/$POSTGRES_VERSION/main" "postgresql@$POSTGRES_VERSION-main.service" "db=$POSTGRES_DB user=$POSTGRES_USER port=$port"
  status postgresql PASS "ready on 127.0.0.1:$port, db=$POSTGRES_DB, app role read/write OK"
}

# =============================================================================
# STEP: pgvector
# =============================================================================
step_pgvector() {
  apt_install "postgresql-$POSTGRES_VERSION-pgvector"
  local port; port=$(pg_port)
  pg -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector"
  local v d
  v=$(pg -d "$POSTGRES_DB" -Atc "SELECT extversion FROM pg_extension WHERE extname='vector'")
  d=$(PGPASSWORD=$(secret pg_opsora_app) psql -X -Atq -h 127.0.0.1 -p "$port" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector")
  [[ $d == 1 ]] || die "pgvector distance test returned '$d' (expected 1)"
  record_version pgvector "$v" "apt.postgresql.org (postgresql-$POSTGRES_VERSION-pgvector)" - - - "enabled in $POSTGRES_DB"
  status pgvector PASS "extension $v, distance query OK"
}

# =============================================================================
# STEP: redis
# =============================================================================
redis_unit() { systemctl list-unit-files 2>/dev/null | awk '$1 ~ /^redis(-server)?\.service$/ {print $1; exit}'; }
step_redis() {
  if [[ ! -f /etc/apt/sources.list.d/redis.list ]]; then
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" >/etc/apt/sources.list.d/redis.list
    apt_update
  fi
  apt_install redis
  apt-mark hold redis redis-server redis-tools >/dev/null 2>&1 || true
  local unit maxmem conf=/etc/redis/redis.conf changed=0
  unit=$(redis_unit); [[ -n $unit ]] || die "redis systemd unit not found"
  [[ -f $conf ]] || die "$conf not found"
  backup_path /etc/redis
  maxmem=$(clamp $(( $(ram_mb) / 16 )) 256 8192)
  write_file /etc/redis/users.acl 0640 redis:redis <<EOF
user default on >$(secret redis_admin) ~* &* +@all
user opsora_app on >$(secret redis_app) ~* &* +@all -@dangerous +info +keys
EOF
  changed=$WF_CHANGED
  write_file /etc/redis/opsora.conf 0640 redis:redis <<EOF
# Managed by OPSORA installer
bind 127.0.0.1 -::1
protected-mode yes
port 6379
aclfile /etc/redis/users.acl
maxmemory ${maxmem}mb
maxmemory-policy volatile-lru
appendonly yes
appendfsync everysec
tcp-keepalive 60
EOF
  (( changed |= WF_CHANGED )) || true
  if ! grep -qxF 'include /etc/redis/opsora.conf' "$conf"; then
    printf '\n# OPSORA overrides (must stay last)\ninclude /etc/redis/opsora.conf\n' >>"$conf"; changed=1
  fi
  svc_enable_restart "$unit" "$changed"
  wait_port 127.0.0.1 6379 20 || die "redis not listening on 127.0.0.1:6379"
  ( umask 077; cat >"$SECRETS_DIR/redis.env" <<EOF
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_USERNAME=opsora_app
REDIS_PASSWORD=$(secret redis_app)
REDIS_URL=redis://opsora_app:$(secret redis_app)@127.0.0.1:6379/0
EOF
  )
  r() { REDISCLI_AUTH=$(secret redis_app) redis-cli --no-auth-warning --user opsora_app -h 127.0.0.1 "$@"; }
  [[ $(r ping) == PONG ]] || die "redis PING failed"
  r set opsora_test hello >/dev/null; [[ $(r get opsora_test) == hello ]] || die "redis SET/GET failed"; r del opsora_test >/dev/null
  [[ $(redis-cli -h 127.0.0.1 ping 2>&1) == *NOAUTH* ]] || warn "redis answered an unauthenticated PING - check ACLs"
  record_version redis "$(redis-server --version | sed -n 's/.*v=\([^ ]*\).*/\1/p')" "packages.redis.io apt (held)" /usr/bin/redis-server /etc/redis "$unit" "maxmemory=${maxmem}mb volatile-lru AOF"
  status redis PASS "PONG, SET/GET/DEL OK, ACL enforced, bound to localhost"
}

# =============================================================================
# STEP: pgadmin  (official wheel in a venv, Gunicorn, localhost only)
# =============================================================================
step_pgadmin() {
  ensure_user pgadmin /var/lib/pgadmin
  install -d -m 0750 -o pgadmin -g pgadmin /var/log/pgadmin
  install -d -m 0755 /opt/pgadmin4
  local venv=/opt/pgadmin4/venv site pkg changed=0
  [[ -x $venv/bin/python ]] || python3 -m venv "$venv"
  if [[ $("$venv/bin/pip" show pgadmin4 2>/dev/null | awk '/^Version:/{print $2}') != "$PGADMIN_VERSION" ]]; then
    "$venv/bin/pip" install -q --upgrade pip wheel
    "$venv/bin/pip" install -q "pgadmin4==$PGADMIN_VERSION" gunicorn
    changed=1
  fi
  site=$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'); pkg=$site/pgadmin4
  write_file "$pkg/config_local.py" 0644 <<EOF
# Managed by OPSORA installer
import os
SERVER_MODE = True
DATA_DIR = '/var/lib/pgadmin'
LOG_FILE = '/var/log/pgadmin/pgadmin4.log'
SQLITE_PATH = os.path.join(DATA_DIR, 'pgadmin4.db')
SESSION_DB_PATH = os.path.join(DATA_DIR, 'sessions')
STORAGE_DIR = os.path.join(DATA_DIR, 'storage')
AZURE_CREDENTIAL_CACHE_DIR = os.path.join(DATA_DIR, 'azurecredentialcache')
KERBEROS_CCACHE_DIR = os.path.join(DATA_DIR, 'krbccache')
DEFAULT_SERVER = '127.0.0.1'
DEFAULT_SERVER_PORT = 5050
ENHANCED_COOKIE_PROTECTION = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
SESSION_COOKIE_SECURE = $([[ -n $PGADMIN_DOMAIN ]] && echo True || echo False)
PROXY_X_FOR_COUNT = 1
PROXY_X_PROTO_COUNT = 1
PROXY_X_HOST_COUNT = 1
UPGRADE_CHECK_ENABLED = False
ALLOW_SPECIAL_EMAIL_DOMAINS = ['local']
MASTER_PASSWORD_REQUIRED = True
EOF
  (( changed |= WF_CHANGED )) || true
  if [[ ! -f /var/lib/pgadmin/pgadmin4.db ]]; then
    runuser -u pgadmin -- env PGADMIN_SETUP_EMAIL="$OPSORA_ADMIN_EMAIL" PGADMIN_SETUP_PASSWORD="$(secret pgadmin_admin 24)" \
      "$venv/bin/python" "$pkg/setup.py" setup-db
  fi
  write_file /etc/systemd/system/pgadmin4.service <<EOF
[Unit]
Description=pgAdmin 4 (Gunicorn, OPSORA)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=pgadmin
Group=pgadmin
WorkingDirectory=$pkg
ExecStart=$venv/bin/gunicorn --bind 127.0.0.1:5050 --workers=1 --threads=25 --chdir $pkg pgAdmin4:app
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart pgadmin4 "$changed"
  wait_http http://127.0.0.1:5050/misc/ping 30 || die "pgAdmin did not answer on 127.0.0.1:5050"
  record_version pgadmin4 "$PGADMIN_VERSION" "PyPI wheel (pgadmin.org) in venv" "$venv/bin/gunicorn" "$pkg/config_local.py" pgadmin4.service "login: $OPSORA_ADMIN_EMAIL"
  status pgadmin PASS "answering on 127.0.0.1:5050"
}

# =============================================================================
# Generic installer for Prometheus-family release tarballs
# =============================================================================
# install_prom_tarball REPO NAME VERSION BIN...
install_prom_tarball() {
  local repo=$1 name=$2 ver=$3; shift 3
  local file="$name-$ver.linux-$ARCH.tar.gz" base="https://github.com/$repo/releases/download/v$ver" dir="/opt/$name-$ver" b
  if [[ ! -x $dir/$1 ]]; then
    fetch "$base/$file" "$CACHE_DIR/$file"
    verify_from_sums "$CACHE_DIR/$file" "$base/sha256sums.txt"
    rm -rf "$dir.tmp"; mkdir -p "$dir.tmp"
    tar -xzf "$CACHE_DIR/$file" -C "$dir.tmp" --strip-components=1
    mv "$dir.tmp" "$dir"
  fi
  for b in "$@"; do ln -sfn "$dir/$b" "/usr/local/bin/$b"; done
}
# go_unit NAME USER DESCRIPTION EXECSTART [EXTRA_UNIT_LINES]
go_unit() {
  write_file "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$3 (OPSORA)
After=network-online.target
Wants=network-online.target

[Service]
User=$2
Group=$2
ExecStart=$4
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal
${5:-}

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================================
# STEP: openobserve
# =============================================================================
step_openobserve() {
  local ver=$OPENOBSERVE_VERSION dir=/opt/openobserve/$OPENOBSERVE_VERSION file changed=0 sha
  file=$CACHE_DIR/openobserve-v$ver-linux-$ARCH.tar.gz
  ensure_user openobserve /var/lib/openobserve
  if [[ ! -x $dir/openobserve ]]; then
    if [[ ! -s $file ]]; then
      curl -fsL -r 0-0 -o /dev/null --connect-timeout 20 "$OPENOBSERVE_URL" 2>/dev/null || die "OpenObserve binary not found at $OPENOBSERVE_URL
       Get the Linux $ARCH open-source tarball URL from https://openobserve.ai/downloads,
       set OPENOBSERVE_URL in $CONF_FILE, then run: $0 --component openobserve"
      fetch "$OPENOBSERVE_URL" "$file"
    fi
    if [[ -n ${OPENOBSERVE_SHA256:-} ]]; then verify_sha256 "$file" "$OPENOBSERVE_SHA256"
    else warn "no OPENOBSERVE_SHA256 configured: recording the hash of what was downloaded (trust on first use)"; fi
    mkdir -p "$dir"; tar -xzf "$file" -C "$dir"
    [[ -x $dir/openobserve ]] || { local found; found=$(find "$dir" -type f -name openobserve | head -1); [[ -n $found ]] && mv "$found" "$dir/openobserve"; }
    chmod 755 "$dir/openobserve"; changed=1
  fi
  ln -sfn "$dir/openobserve" /usr/local/bin/openobserve
  sha=$( [[ -s $file ]] && sha256sum "$file" | awk '{print $1}' || echo unknown)
  local cache_mb; cache_mb=$(clamp $(( $(ram_mb) / 8 )) 512 16384)
  write_file "$SECRETS_DIR/openobserve.env" 0600 <<EOF
ZO_ROOT_USER_EMAIL=$OPSORA_ADMIN_EMAIL
ZO_ROOT_USER_PASSWORD=$(secret openobserve_root 28)
ZO_DATA_DIR=/var/lib/openobserve/
ZO_LOCAL_MODE=true
ZO_HTTP_ADDR=127.0.0.1
ZO_HTTP_PORT=5080
ZO_GRPC_ADDR=127.0.0.1
ZO_GRPC_PORT=5081
ZO_COMPACT_DATA_RETENTION_DAYS=$OPENOBSERVE_RETENTION_DAYS
ZO_MEMORY_CACHE_MAX_SIZE=$cache_mb
ZO_TELEMETRY=false
EOF
  (( changed |= WF_CHANGED )) || true
  go_unit openobserve openobserve "OpenObserve" /usr/local/bin/openobserve \
"EnvironmentFile=$SECRETS_DIR/openobserve.env
WorkingDirectory=/var/lib/openobserve
MemoryHigh=$(( $(ram_mb) * 35 / 100 ))M
LimitNOFILE=262144"
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart openobserve "$changed"
  wait_http http://127.0.0.1:5080/healthz 45 || die "OpenObserve /healthz not answering"
  # ingestion + search round trip
  local auth="$OPSORA_ADMIN_EMAIL:$(secret openobserve_root 28)" marker="opsora-install-$RUN_TS" now start hits=0 i
  curl -fsS -u "$auth" -H 'Content-Type: application/json' \
    -d "[{\"level\":\"info\",\"source\":\"opsora-installer\",\"message\":\"$marker\"}]" \
    http://127.0.0.1:5080/api/default/opsora_selftest/_json >/dev/null || die "OpenObserve test ingestion failed (login or ingest)"
  for i in {1..10}; do
    now=$(( $(date +%s) * 1000000 + 60000000 )); start=$(( now - 900000000 ))
    hits=$(curl -fsS -u "$auth" -H 'Content-Type: application/json' \
      -d "{\"query\":{\"sql\":\"SELECT * FROM \\\"opsora_selftest\\\" WHERE message = '$marker'\",\"start_time\":$start,\"end_time\":$now,\"from\":0,\"size\":1}}" \
      "http://127.0.0.1:5080/api/default/_search?type=logs" 2>/dev/null | jq -r '.hits | length' 2>/dev/null || echo 0)
    [[ ${hits:-0} -ge 1 ]] && break; sleep 3
  done
  record_version openobserve "$ver" "$OPENOBSERVE_URL" "$dir/openobserve" "$SECRETS_DIR/openobserve.env" openobserve.service "sha256=$sha retention=${OPENOBSERVE_RETENTION_DAYS}d"
  if [[ ${hits:-0} -ge 1 ]]; then status openobserve PASS "healthz OK, test event ingested and found by search"
  else status openobserve WARNING "healthz and ingestion OK, test event not yet returned by search"; fi
}

# =============================================================================
# STEP: alloy  (logs + OTLP -> OpenObserve; metrics scraping stays in Prometheus)
# =============================================================================
step_alloy() {
  if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL -o /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
    chmod 644 /etc/apt/keyrings/grafana.asc
    echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" >/etc/apt/sources.list.d/grafana.list
    apt_update
  fi
  if ! dpkg-query -W -f='${Version}' alloy 2>/dev/null | grep -q "^$ALLOY_VERSION"; then
    apt-get install -y --allow-downgrades --allow-change-held-packages "alloy=${ALLOY_VERSION}*"
  fi
  apt-mark hold alloy >/dev/null
  usermod -aG adm,systemd-journal alloy
  backup_path /etc/alloy
  local changed=0
  write_file "$SECRETS_DIR/alloy.env" 0600 <<EOF
O2_USER=$OPSORA_ADMIN_EMAIL
O2_PASSWORD=$(secret openobserve_root 28)
EOF
  (( changed |= WF_CHANGED )) || true
  write_file /etc/alloy/config.alloy 0644 <<EOF
// Managed by OPSORA installer.
// Role: logs (journald + files) and OTLP in, everything out to OpenObserve.
// Exporter metrics are scraped by Prometheus, not here, to avoid double collection.
logging {
  level  = "info"
  format = "logfmt"
}

// ---- logs: systemd journal ------------------------------------------------
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}
loki.source.journal "system" {
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  labels        = {job = "journal", host = constants.hostname}
  forward_to    = [otelcol.receiver.loki.to_otlp.receiver]
}

// ---- logs: files ----------------------------------------------------------
local.file_match "files" {
  path_targets = [
    {__path__ = "/var/log/nginx/*.log", job = "nginx", host = constants.hostname},
    {__path__ = "$LOG_DIR/*.log", job = "opsora", host = constants.hostname},
  ]
}
loki.source.file "files" {
  targets    = local.file_match.files.targets
  forward_to = [otelcol.receiver.loki.to_otlp.receiver]
}
otelcol.receiver.loki "to_otlp" {
  output {
    logs = [otelcol.processor.batch.default.input]
  }
}

// ---- OTLP in (applications, external collectors) ---------------------------
otelcol.receiver.otlp "ingest" {
  grpc {
    endpoint = "$OTLP_BIND:4317"
  }
  http {
    endpoint = "$OTLP_BIND:4318"
  }
  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.otlphttp.openobserve.input]
    logs    = [otelcol.exporter.otlphttp.openobserve.input]
    traces  = [otelcol.exporter.otlphttp.openobserve.input]
  }
}

// ---- out: OpenObserve -------------------------------------------------------
otelcol.auth.basic "openobserve" {
  username = sys.env("O2_USER")
  password = sys.env("O2_PASSWORD")
}
otelcol.exporter.otlphttp "openobserve" {
  client {
    endpoint = "http://127.0.0.1:5080/api/default"
    auth     = otelcol.auth.basic.openobserve.handler
    tls {
      insecure = true
    }
  }
}
EOF
  (( changed |= WF_CHANGED )) || true
  install -d /etc/systemd/system/alloy.service.d
  write_file /etc/systemd/system/alloy.service.d/10-opsora.conf <<EOF
[Service]
EnvironmentFile=$SECRETS_DIR/alloy.env
Restart=on-failure
RestartSec=5
EOF
  (( changed |= WF_CHANGED )) || true
  env O2_USER=x O2_PASSWORD=x alloy fmt /etc/alloy/config.alloy >/dev/null || die "Alloy configuration has syntax errors"
  if alloy validate --help >/dev/null 2>&1; then
    env O2_USER=x O2_PASSWORD=x alloy validate /etc/alloy/config.alloy || die "Alloy configuration failed validation"
  fi
  svc_enable_restart alloy "$changed"
  wait_http http://127.0.0.1:12345/-/ready 30 || die "Alloy not ready on 127.0.0.1:12345"
  record_version alloy "$(dpkg-query -W -f='${Version}' alloy)" "apt.grafana.com (held)" /usr/bin/alloy /etc/alloy/config.alloy alloy.service "journal+files+OTLP -> OpenObserve"
  status alloy PASS "config valid, ready, OTLP on $OTLP_BIND:4317/4318"
}

# =============================================================================
# STEP: prometheus
# =============================================================================
OPSORA_UNITS_RE='(nginx|postgresql@.+|redis(-server)?|openobserve|alloy|prometheus|alertmanager|keep-api|keep-ui|semaphore|pgadmin4|node_exporter|postgres_exporter|mysqld_exporter|snmp_exporter|blackbox_exporter|fail2ban|opsora-backup)\\.service'
write_prometheus_rules() {
  write_file /etc/prometheus/rules/opsora-recording.yml 0644 <<'EOF'
groups:
  - name: opsora-recording
    interval: 1m
    rules:
      - record: instance:node_cpu_utilisation:ratio
        expr: 1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
      - record: instance:node_memory_utilisation:ratio
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
      - record: instance:node_filesystem_utilisation:ratio
        expr: 1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs"})
EOF
  write_file /etc/prometheus/rules/opsora-alerts.yml 0644 <<EOF
groups:
  - name: opsora-host
    rules:
      - alert: HighCPU
        expr: instance:node_cpu_utilisation:ratio > 0.90
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "CPU above 90% for 15m on {{ \$labels.instance }}"}
      - alert: HighMemory
        expr: instance:node_memory_utilisation:ratio > 0.90
        for: 10m
        labels: {severity: warning}
        annotations: {summary: "Memory above 90% for 10m on {{ \$labels.instance }}"}
      - alert: HighDiskUsage
        expr: instance:node_filesystem_utilisation:ratio > 0.80
        for: 15m
        labels: {severity: warning}
        annotations: {summary: "{{ \$labels.mountpoint }} above 80% on {{ \$labels.instance }}"}
      - alert: DiskAlmostFull
        expr: instance:node_filesystem_utilisation:ratio > 0.92
        for: 5m
        labels: {severity: critical}
        annotations: {summary: "{{ \$labels.mountpoint }} above 92% on {{ \$labels.instance }}"}
  - name: opsora-services
    rules:
      - alert: ServiceDown
        expr: node_systemd_unit_state{state="failed", name=~"$OPSORA_UNITS_RE"} == 1
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "systemd unit {{ \$labels.name }} is failed"}
      - alert: PrometheusTargetDown
        expr: up == 0
        for: 5m
        labels: {severity: warning}
        annotations: {summary: "scrape target {{ \$labels.job }}/{{ \$labels.instance }} is down"}
      - alert: PostgreSQLDown
        expr: pg_up == 0 or absent(pg_up)
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "PostgreSQL is not answering the exporter"}
      - alert: RedisDown
        expr: probe_success{job="blackbox-tcp", service="redis"} == 0
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "Redis port is not accepting connections"}
      - alert: OpenObserveDown
        expr: probe_success{job="blackbox-tcp", service="openobserve"} == 0
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "OpenObserve port is not accepting connections"}
      - alert: AlloyDown
        expr: up{job="alloy"} == 0
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "Grafana Alloy is down, telemetry is not being collected"}
      - alert: NginxDown
        expr: probe_success{job="blackbox-tcp", service="nginx"} == 0
        for: 2m
        labels: {severity: critical}
        annotations: {summary: "Nginx is not accepting connections"}
      - alert: EndpointDown
        expr: probe_success{job=~"blackbox-(http|tcp|icmp)", service!~"redis|openobserve|nginx"} == 0
        for: 5m
        labels: {severity: warning}
        annotations: {summary: "probe failed for {{ \$labels.instance }}"}
      - alert: CertificateExpiring
        expr: probe_ssl_earliest_cert_expiry - time() < 14 * 86400
        for: 1h
        labels: {severity: warning}
        annotations: {summary: "TLS certificate for {{ \$labels.instance }} expires in under 14 days"}
      - alert: BackupFailure
        expr: (time() - opsora_backup_last_success_timestamp_seconds > 93600) or (opsora_backup_last_status != 0)
        for: 10m
        labels: {severity: critical}
        annotations: {summary: "OPSORA backup has not succeeded in the last 26 hours"}
EOF
}
write_prometheus_config() {
  write_file /etc/prometheus/prometheus.yml 0644 <<EOF
# Managed by OPSORA installer. Add targets through the file_sd directories, not here.
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    opsora_server: $(hostname)

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:9093']

remote_write:
  - url: http://127.0.0.1:5080/api/default/prometheus/api/v1/write
    basic_auth:
      username: $OPSORA_ADMIN_EMAIL
      password_file: /etc/prometheus/secrets/openobserve_password
    queue_config:
      max_samples_per_send: 5000
      capacity: 20000

scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: ['127.0.0.1:9090']}]
  - job_name: alertmanager
    static_configs: [{targets: ['127.0.0.1:9093']}]
  - job_name: alloy
    static_configs: [{targets: ['127.0.0.1:12345']}]
  - job_name: node
    static_configs: [{targets: ['127.0.0.1:9100'], labels: {host: '$(hostname)'}}]
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/node/*.yml']}]
  - job_name: postgres
    static_configs: [{targets: ['127.0.0.1:9187']}]
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/postgres/*.yml']}]
  - job_name: blackbox_exporter
    static_configs: [{targets: ['127.0.0.1:9115']}]
  - job_name: snmp_exporter
    static_configs: [{targets: ['127.0.0.1:9116']}]

  # MySQL/MariaDB servers: one line per server in file_sd/mysql/*.yml (host:3306)
  - job_name: mysql
    metrics_path: /probe
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/mysql/*.yml']}]
    relabel_configs:
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: '127.0.0.1:9104'}

  # SNMP devices (MikroTik, routers, switches, firewalls): file_sd/snmp/*.yml,
  # optional labels "module" (e.g. if_mib, mikrotik) and "auth" (e.g. public_v2)
  - job_name: snmp
    metrics_path: /snmp
    scrape_interval: 60s
    scrape_timeout: 30s
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/snmp/*.yml']}]
    relabel_configs:
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {source_labels: [module], regex: '(.+)', target_label: __param_module}
      - {source_labels: [auth], regex: '(.+)', target_label: __param_auth}
      - {target_label: __address__, replacement: '127.0.0.1:9116'}

  - job_name: blackbox-http
    metrics_path: /probe
    params: {module: [http_2xx]}
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/blackbox-http/*.yml']}]
    relabel_configs: &blackbox
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: '127.0.0.1:9115'}
  - job_name: blackbox-tcp
    metrics_path: /probe
    params: {module: [tcp_connect]}
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/blackbox-tcp/*.yml']}]
    relabel_configs: *blackbox
  - job_name: blackbox-icmp
    metrics_path: /probe
    params: {module: [icmp]}
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/blackbox-icmp/*.yml']}]
    relabel_configs: *blackbox
  - job_name: blackbox-dns
    metrics_path: /probe
    params: {module: [dns_udp]}
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/blackbox-dns/*.yml']}]
    relabel_configs: *blackbox

  # kube-state-metrics runs inside each external cluster; list its reachable
  # endpoint (NodePort / LoadBalancer / ingress) in file_sd/kube-state-metrics/*.yml
  - job_name: kube-state-metrics
    file_sd_configs: [{files: ['/etc/prometheus/file_sd/kube-state-metrics/*.yml']}]
EOF
}
step_prometheus() {
  ensure_user prometheus /var/lib/prometheus
  install_prom_tarball prometheus/prometheus prometheus "$PROMETHEUS_VERSION" prometheus promtool
  backup_path /etc/prometheus
  install -d -m 0755 /etc/prometheus /etc/prometheus/rules \
    /etc/prometheus/file_sd/{node,postgres,mysql,snmp,blackbox-http,blackbox-tcp,blackbox-icmp,blackbox-dns,kube-state-metrics}
  install -d -m 0750 -o root -g prometheus /etc/prometheus/secrets
  local changed=0
  secret openobserve_root 28 | tr -d '\n' | write_file /etc/prometheus/secrets/openobserve_password 0640 root:prometheus
  (( changed |= WF_CHANGED )) || true
  write_prometheus_rules;  (( changed |= WF_CHANGED )) || true
  write_prometheus_config; (( changed |= WF_CHANGED )) || true
  promtool check config /etc/prometheus/prometheus.yml
  local ext=""; [[ -n $PROMETHEUS_DOMAIN ]] && ext=" --web.external-url=https://$PROMETHEUS_DOMAIN"
  go_unit prometheus prometheus "Prometheus" \
"/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=$PROMETHEUS_RETENTION --web.listen-address=127.0.0.1:9090 --web.enable-lifecycle$ext" \
"ExecReload=/bin/kill -HUP \$MAINPID
MemoryHigh=$(( $(ram_mb) * 15 / 100 ))M"
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart prometheus "$changed"
  wait_http http://127.0.0.1:9090/-/ready 45 || die "Prometheus not ready"
  record_version prometheus "$PROMETHEUS_VERSION" "github.com/prometheus/prometheus release (sha256 verified)" /usr/local/bin/prometheus /etc/prometheus/prometheus.yml prometheus.service "LTS line, retention $PROMETHEUS_RETENTION, remote_write -> OpenObserve"
  status prometheus PASS "ready on 127.0.0.1:9090, config and rules valid"
}

# =============================================================================
# STEP: alertmanager
# =============================================================================
step_alertmanager() {
  ensure_user alertmanager /var/lib/alertmanager
  install_prom_tarball prometheus/alertmanager alertmanager "$ALERTMANAGER_VERSION" alertmanager amtool
  backup_path /etc/alertmanager
  install -d -m 0755 /etc/alertmanager
  install -d -m 0750 -o root -g alertmanager /etc/alertmanager/secrets
  local changed=0 receivers="" routes=""
  if is_true "$ENABLE_KEEP"; then
    secret keep_webhook_key 40 | tr -d '\n' | write_file /etc/alertmanager/secrets/keep_api_key 0640 root:alertmanager
    (( changed |= WF_CHANGED )) || true
    receivers+="
  - name: keep
    webhook_configs:
      - url: http://127.0.0.1:8080/alerts/event/prometheus
        send_resolved: true
        http_config:
          basic_auth:
            username: api_key
            password_file: /etc/alertmanager/secrets/keep_api_key"
    routes+="
    - receiver: keep
      continue: true"
  fi
  if [[ -n $ALERT_WEBHOOK_URL ]]; then
    receivers+="
  - name: opsora-webhook
    webhook_configs:
      - url: $ALERT_WEBHOOK_URL
        send_resolved: true"
    routes+="
    - receiver: opsora-webhook
      continue: true"
  fi
  write_file /etc/alertmanager/alertmanager.yml 0644 <<EOF
# Managed by OPSORA installer
global:
  resolve_timeout: 5m
route:
  receiver: blackhole
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:${routes:- []}
inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [alertname, instance]
  - source_matchers: [alertname="DiskAlmostFull"]
    target_matchers: [alertname="HighDiskUsage"]
    equal: [instance, mountpoint]
receivers:
  - name: blackhole$receivers
EOF
  (( changed |= WF_CHANGED )) || true
  amtool check-config /etc/alertmanager/alertmanager.yml
  local ext=""; [[ -n $ALERTMANAGER_DOMAIN ]] && ext=" --web.external-url=https://$ALERTMANAGER_DOMAIN"
  go_unit alertmanager alertmanager "Alertmanager" \
"/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=127.0.0.1:9093 --cluster.listen-address=$ext" \
"ExecReload=/bin/kill -HUP \$MAINPID"
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart alertmanager "$changed"
  wait_http http://127.0.0.1:9093/-/ready 30 || die "Alertmanager not ready"
  # harmless test alert, expires by itself after 5 minutes
  amtool --alertmanager.url=http://127.0.0.1:9093 alert add OpsoraInstallTest severity=info instance="$(hostname)" \
    --annotation=summary="OPSORA installer test alert, safe to ignore" --end="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
  amtool --alertmanager.url=http://127.0.0.1:9093 alert query alertname=OpsoraInstallTest | grep -q OpsoraInstallTest || die "test alert not accepted"
  record_version alertmanager "$ALERTMANAGER_VERSION" "github.com/prometheus/alertmanager release (sha256 verified)" /usr/local/bin/alertmanager /etc/alertmanager/alertmanager.yml alertmanager.service "receivers: blackhole$(is_true "$ENABLE_KEEP" && echo ', keep')$([[ -n $ALERT_WEBHOOK_URL ]] && echo ', opsora-webhook')"
  status alertmanager PASS "ready on 127.0.0.1:9093, test alert accepted"
}

# =============================================================================
# STEP: exporters
# =============================================================================
step_exporters() {
  local changed
  # --- node_exporter ---
  ensure_user node_exporter /var/lib/node_exporter
  install -d -m 0755 -o node_exporter -g node_exporter /var/lib/node_exporter/textfile
  install_prom_tarball prometheus/node_exporter node_exporter "$NODE_EXPORTER_VERSION" node_exporter
  go_unit node_exporter node_exporter "Prometheus Node Exporter" \
"/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100 --collector.systemd --collector.textfile.directory=/var/lib/node_exporter/textfile"
  svc_enable_restart node_exporter "$WF_CHANGED"
  record_version node_exporter "$NODE_EXPORTER_VERSION" "github.com/prometheus/node_exporter release" /usr/local/bin/node_exporter - node_exporter.service "127.0.0.1:9100"

  # --- postgres_exporter ---
  ensure_user postgres_exporter /var/lib/postgres_exporter
  install_prom_tarball prometheus-community/postgres_exporter postgres_exporter "$POSTGRES_EXPORTER_VERSION" postgres_exporter
  local port; port=$(pg_port); port=${port:-5432}
  write_file "$SECRETS_DIR/postgres_exporter.env" 0600 <<EOF
DATA_SOURCE_NAME=postgresql://opsora_monitor:$(secret pg_monitor)@127.0.0.1:$port/postgres?sslmode=disable
EOF
  changed=$WF_CHANGED
  go_unit postgres_exporter postgres_exporter "Prometheus PostgreSQL Exporter" \
"/usr/local/bin/postgres_exporter --web.listen-address=127.0.0.1:9187" "EnvironmentFile=$SECRETS_DIR/postgres_exporter.env"
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart postgres_exporter "$changed"
  record_version postgres_exporter "$POSTGRES_EXPORTER_VERSION" "github.com/prometheus-community/postgres_exporter release" /usr/local/bin/postgres_exporter "$SECRETS_DIR/postgres_exporter.env" postgres_exporter.service "127.0.0.1:9187"

  # --- mysqld_exporter (multi-target; no MySQL runs on this host) ---
  ensure_user mysqld_exporter /var/lib/mysqld_exporter
  install_prom_tarball prometheus/mysqld_exporter mysqld_exporter "$MYSQLD_EXPORTER_VERSION" mysqld_exporter
  install -d -m 0750 -o root -g mysqld_exporter /etc/mysqld_exporter
  if [[ ! -f /etc/mysqld_exporter/my.cnf ]]; then
    write_file /etc/mysqld_exporter/my.cnf 0640 root:mysqld_exporter <<'EOF'
# Credentials of the monitoring user that exists on your MySQL/MariaDB servers:
#   CREATE USER 'exporter'@'<opsora-ip>' IDENTIFIED BY '...' WITH MAX_USER_CONNECTIONS 3;
#   GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'<opsora-ip>';
[client]
user = exporter
password = CHANGE_ME
EOF
  fi
  go_unit mysqld_exporter mysqld_exporter "Prometheus MySQL/MariaDB Exporter" \
"/usr/local/bin/mysqld_exporter --config.my-cnf=/etc/mysqld_exporter/my.cnf --web.listen-address=127.0.0.1:9104"
  svc_enable_restart mysqld_exporter "$WF_CHANGED"
  record_version mysqld_exporter "$MYSQLD_EXPORTER_VERSION" "github.com/prometheus/mysqld_exporter release" /usr/local/bin/mysqld_exporter /etc/mysqld_exporter/my.cnf mysqld_exporter.service "127.0.0.1:9104, targets via file_sd/mysql"

  # --- snmp_exporter (ships the generated snmp.yml incl. if_mib and mikrotik modules) ---
  ensure_user snmp_exporter /var/lib/snmp_exporter
  install_prom_tarball prometheus/snmp_exporter snmp_exporter "$SNMP_EXPORTER_VERSION" snmp_exporter
  install -d -m 0755 /etc/snmp_exporter
  [[ -f /etc/snmp_exporter/snmp.yml ]] || install -m 0644 "/opt/snmp_exporter-$SNMP_EXPORTER_VERSION/snmp.yml" /etc/snmp_exporter/snmp.yml
  go_unit snmp_exporter snmp_exporter "Prometheus SNMP Exporter" \
"/usr/local/bin/snmp_exporter --config.file=/etc/snmp_exporter/snmp.yml --web.listen-address=127.0.0.1:9116"
  svc_enable_restart snmp_exporter "$WF_CHANGED"
  record_version snmp_exporter "$SNMP_EXPORTER_VERSION" "github.com/prometheus/snmp_exporter release" /usr/local/bin/snmp_exporter /etc/snmp_exporter/snmp.yml snmp_exporter.service "127.0.0.1:9116, targets via file_sd/snmp"

  # --- blackbox_exporter ---
  ensure_user blackbox_exporter /var/lib/blackbox_exporter
  install_prom_tarball prometheus/blackbox_exporter blackbox_exporter "$BLACKBOX_EXPORTER_VERSION" blackbox_exporter
  write_file /etc/blackbox_exporter/blackbox.yml 0644 <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      valid_status_codes: [200, 204, 301, 302, 401, 403]
  tcp_connect:
    prober: tcp
    timeout: 5s
  tcp_tls:
    prober: tcp
    timeout: 10s
    tcp:
      tls: true
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      query_name: example.com
      query_type: A
EOF
  changed=$WF_CHANGED
  go_unit blackbox_exporter blackbox_exporter "Prometheus Blackbox Exporter" \
"/usr/local/bin/blackbox_exporter --config.file=/etc/blackbox_exporter/blackbox.yml --web.listen-address=127.0.0.1:9115" \
"AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW"
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart blackbox_exporter "$changed"
  record_version blackbox_exporter "$BLACKBOX_EXPORTER_VERSION" "github.com/prometheus/blackbox_exporter release" /usr/local/bin/blackbox_exporter /etc/blackbox_exporter/blackbox.yml blackbox_exporter.service "127.0.0.1:9115"

  # --- kube-state-metrics: belongs in the external clusters, nothing to run here ---
  install -d -m 0755 "$OPSORA_HOME/integrations/kubernetes"
  write_file "$OPSORA_HOME/integrations/kubernetes/README-kube-state-metrics.md" 0644 <<'EOF'
# kube-state-metrics

kube-state-metrics is not installed on the OPSORA server. Deploy it inside each
external cluster with that cluster's own tooling, expose its metrics port (8080)
to the OPSORA server over a private network, then add the endpoint here:

    /etc/prometheus/file_sd/kube-state-metrics/<cluster>.yml
    - targets: ['10.0.0.10:30080']
      labels: {cluster: 'prod-1'}

Prometheus picks the file up without a restart.
EOF
  record_version kube-state-metrics "n/a" "external clusters" - /etc/prometheus/file_sd/kube-state-metrics - "scrape job prepared, no local install"

  local e bad=""
  for e in 9100 9187 9104 9116 9115; do wait_http "http://127.0.0.1:$e/metrics" 15 || bad+=" $e"; done
  [[ -z $bad ]] || die "exporters not answering on ports:$bad"
  status exporters PASS "node, postgres, mysqld, snmp, blackbox answering on localhost"
}

# =============================================================================
# STEP: keep  (source build; upstream only supports Docker/Kubernetes)
# Mirrors docker/Dockerfile.api, docker/Dockerfile.ui and keep/entrypoint.sh
# from the pinned tag. Pusher/websocket is disabled, so no third service.
# =============================================================================
step_keep() {
  if ! is_true "$ENABLE_KEEP"; then status keep SKIPPED "ENABLE_KEEP=false"; return 0; fi
  local root=/opt/keep src=/opt/keep/src venv=/opt/keep/venv ui=/opt/keep/ui marker=/opt/keep/.built-$KEEP_REF site changed=0 port
  (( $(ram_mb) >= 11000 )) || die "Keep UI build needs about 8 GB of free RAM; this host has $(ram_mb) MB. Set ENABLE_KEEP=false or add memory."
  git ls-remote --exit-code --tags https://github.com/keephq/keep "refs/tags/$KEEP_REF" >/dev/null || die "Keep tag $KEEP_REF not found upstream"
  # Node.js for the Next.js UI (NodeSource apt repo; Ubuntu 24.04 ships Node 18)
  if ! have node || [[ $(node -v | sed 's/v\([0-9]*\).*/\1/') -lt $KEEP_NODE_MAJOR ]]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${KEEP_NODE_MAJOR}.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
    apt_update; apt_install nodejs
  fi
  ensure_user keep "$STATE_DIR/keep"
  install -d -m 0750 -o keep -g keep "$STATE_DIR/keep/state" "$STATE_DIR/keep/prom" "$root"
  port=$(pg_port); port=${port:-5432}
  pg_role keep "$(secret pg_keep)" 40
  pg_db keep keep

  if [[ ! -f $marker ]]; then
    log "building Keep $KEEP_REF from source (several minutes)"
    rm -rf "$src.new"
    runuser -u keep -- git clone -q --depth 1 --branch "$KEEP_REF" https://github.com/keephq/keep "$src.new"
    if [[ -d $src ]]; then mv "$src" "$root/src.previous-$RUN_TS"; fi
    mv "$src.new" "$src"
    runuser -u keep -- bash -Eeuo pipefail -c "
      cd '$root'
      [[ -x venv/bin/python ]] || python3 -m venv venv
      [[ -x .build/bin/python ]] || python3 -m venv .build
      .build/bin/pip install -q --upgrade pip
      .build/bin/pip install -q 'poetry>=1.8,<2' poetry-plugin-export
      cd src
      ../.build/bin/poetry export -f requirements.txt --output ../requirements.txt --without-hashes --only main
      ../venv/bin/pip install -q --upgrade pip wheel
      ../venv/bin/pip install -q -r ../requirements.txt
      [[ -d keep/ee ]] || cp -a ee keep/ee
      ../venv/bin/pip install -q --no-deps .
      cd keep-ui
      npm ci --no-audit --no-fund
      NEXT_TELEMETRY_DISABLED=1 API_URL=http://localhost:8080 NODE_OPTIONS=--max-old-space-size=8192 npm run build
      rm -rf '$ui.new'; mkdir -p '$ui.new'
      cp -a .next/standalone/. '$ui.new/'
      cp -a public '$ui.new/public'
      mkdir -p '$ui.new/.next'; cp -a .next/static '$ui.new/.next/static'
    "
    [[ -f $ui.new/server.js ]] || die "Keep UI build did not produce a standalone server.js"
    if [[ -d $ui ]]; then mv "$ui" "$root/ui.previous-$RUN_TS"; fi
    mv "$ui.new" "$ui"
    touch "$marker"; changed=1
  fi
  site=$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  local base_url="http://127.0.0.1:3001"; [[ -n $KEEP_DOMAIN ]] && base_url="https://$KEEP_DOMAIN"
  write_file "$SECRETS_DIR/keep-api.env" 0600 <<EOF
PORT=8080
AUTH_TYPE=DB
KEEP_JWT_SECRET=$(secret keep_jwt 48)
KEEP_DEFAULT_USERNAME=admin
KEEP_DEFAULT_PASSWORD=$(secret keep_admin 24)
KEEP_DEFAULT_API_KEYS=alertmanager:webhook:$(secret keep_webhook_key 40)
DATABASE_CONNECTION_STRING=postgresql+psycopg2://keep:$(secret pg_keep)@127.0.0.1:$port/keep
SECRET_MANAGER_TYPE=FILE
SECRET_MANAGER_DIRECTORY=$STATE_DIR/keep/state
KEEP_API_URL=http://127.0.0.1:8080
PUSHER_DISABLED=true
POSTHOG_DISABLED=true
SENTRY_DISABLED=true
USE_NGROK=false
REDIS=false
KEEP_METRICS=true
PROMETHEUS_MULTIPROC_DIR=$STATE_DIR/keep/prom
EE_PATH=ee
PATH=$venv/bin:/usr/local/bin:/usr/bin:/bin
EOF
  (( changed |= WF_CHANGED )) || true
  write_file "$SECRETS_DIR/keep-ui.env" 0600 <<EOF
NODE_ENV=production
PORT=3001
HOSTNAME=127.0.0.1
AUTH_TYPE=DB
API_URL=http://127.0.0.1:8080
NEXTAUTH_URL=$base_url
NEXTAUTH_SECRET=$(secret keep_nextauth 48)
PUSHER_DISABLED=true
POSTHOG_DISABLED=true
SENTRY_DISABLED=true
NEXT_TELEMETRY_DISABLED=1
EOF
  (( changed |= WF_CHANGED )) || true
  write_file "$root/start-api.sh" 0755 <<EOF
#!/usr/bin/env bash
# Mirrors keep/entrypoint.sh (REDIS != true branch) and the CMD of docker/Dockerfile.api
set -e
"$venv/bin/python" "$site/keep/server_jobs_bg.py" &
"$venv/bin/keep" provider build_cache || echo "provider cache build failed, continuing"
exec "$venv/bin/gunicorn" keep.api.api:get_app --bind 127.0.0.1:8080 --workers "\${KEEP_API_WORKERS:-2}" \\
  -k uvicorn.workers.UvicornWorker -c "$site/keep/api/config.py" --preload
EOF
  (( changed |= WF_CHANGED )) || true
  write_file /etc/systemd/system/keep-api.service <<EOF
[Unit]
Description=Keep API (OPSORA, source build)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=keep
Group=keep
WorkingDirectory=$STATE_DIR/keep
EnvironmentFile=$SECRETS_DIR/keep-api.env
ExecStart=$root/start-api.sh
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  (( changed |= WF_CHANGED )) || true
  write_file /etc/systemd/system/keep-ui.service <<EOF
[Unit]
Description=Keep UI (OPSORA, source build)
After=network-online.target keep-api.service
Wants=keep-api.service

[Service]
User=keep
Group=keep
WorkingDirectory=$ui
EnvironmentFile=$SECRETS_DIR/keep-ui.env
ExecStart=$(command -v node) $ui/server.js
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  (( changed |= WF_CHANGED )) || true
  svc_enable_restart keep-api "$changed"
  wait_http http://127.0.0.1:8080/healthcheck 120 || die "Keep API /healthcheck not answering (journalctl -u keep-api)"
  svc_enable_restart keep-ui "$changed"
  wait_port 127.0.0.1 3001 45 || die "Keep UI not listening on 127.0.0.1:3001 (journalctl -u keep-ui)"
  # push one test alert through the same endpoint and key Alertmanager uses
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "api_key:$(secret keep_webhook_key 40)" -H 'Content-Type: application/json' \
    -d "{\"version\":\"4\",\"status\":\"firing\",\"receiver\":\"keep\",\"alerts\":[{\"status\":\"firing\",\"labels\":{\"alertname\":\"OpsoraInstallTest\",\"severity\":\"info\",\"instance\":\"$(hostname)\"},\"annotations\":{\"summary\":\"OPSORA installer test alert\"},\"startsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"fingerprint\":\"opsora-install-test\"}]}" \
    http://127.0.0.1:8080/alerts/event/prometheus || echo 000)
  record_version keep "$KEEP_REF" "github.com/keephq/keep (source build, not vendor-supported)" "$root/start-api.sh" "$SECRETS_DIR/keep-api.env" "keep-api.service keep-ui.service" "API 127.0.0.1:8080, UI 127.0.0.1:3001, websocket disabled"
  if [[ $code =~ ^20 ]]; then status keep PASS "API healthy, UI listening, webhook accepted test alert (HTTP $code)"
  else status keep WARNING "API healthy, UI listening, but webhook test returned HTTP $code - check the API key role"; fi
}

# =============================================================================
# STEP: holmesgpt  (CLI via pipx; upstream HTTP server is container-only)
# =============================================================================
pipx_global() { PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin PIPX_MAN_DIR=/usr/local/share/man pipx "$@"; }
ai_env_file() {
  [[ -f $SECRETS_DIR/ai.env ]] && return 0
  ( umask 077; cat >"$SECRETS_DIR/ai.env" <<'EOF'
# AI provider credentials for HolmesGPT and K8sGPT. Mode 600, never commit this file.
# Uncomment exactly what your provider needs, then re-run:
#   opsora-install.sh --phase ai
#OPENAI_API_KEY=
#ANTHROPIC_API_KEY=
#AZURE_API_KEY=
#AZURE_API_BASE=
#AZURE_API_VERSION=
EOF
  )
}
ai_key_present() { grep -Eq '^[A-Z_]+_API_KEY=.+' "$SECRETS_DIR/ai.env" 2>/dev/null; }
step_holmesgpt() {
  ensure_user holmes "$STATE_DIR/holmes"
  ai_env_file
  install -d -m 0755 /opt/pipx
  if [[ $(pipx_global list --short 2>/dev/null | awk '$1=="holmesgpt"{print $2}') != "$HOLMESGPT_VERSION" ]]; then
    pipx_global install --force "holmesgpt==$HOLMESGPT_VERSION"
  fi
  install -d -m 0700 -o holmes -g holmes "$STATE_DIR/holmes/.holmes"
  {
    echo "# Managed by OPSORA installer. Built-in toolsets are read-only."
    [[ -n $AI_MODEL ]] && echo "model: \"$AI_MODEL\""
    echo "alertmanager_url: http://127.0.0.1:9093"
    echo "toolsets:"
    echo "  prometheus/metrics:"
    echo "    enabled: true"
    echo "    subtype: prometheus"
    echo "    config:"
    echo "      prometheus_url: http://127.0.0.1:9090"
  } | write_file "$STATE_DIR/holmes/.holmes/config.yaml" 0600 holmes:holmes
  cp -f "$STATE_DIR/holmes/.holmes/config.yaml" "$OPSORA_HOME/configs/holmesgpt/config.yaml"
  write_file /usr/local/bin/opsora-holmes 0755 <<EOF
#!/usr/bin/env bash
# Runs HolmesGPT as the unprivileged "holmes" user with AI credentials loaded.
# Investigation only: this wrapper has no remediation path.
#   sudo opsora-holmes ask "why is disk usage high on this server?"
#   sudo opsora-holmes investigate alertmanager --alertmanager-url http://127.0.0.1:9093
[[ \$EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
set -a; . $SECRETS_DIR/ai.env; set +a
cd $STATE_DIR/holmes
exec setpriv --reuid holmes --regid holmes --init-groups env HOME=$STATE_DIR/holmes /usr/local/bin/holmes "\$@"
EOF
  runuser -u holmes -- env HOME="$STATE_DIR/holmes" /usr/local/bin/holmes ask --help >/dev/null || die "holmes CLI does not start"
  record_version holmesgpt "$HOLMESGPT_VERSION" "PyPI via pipx (/opt/pipx)" /usr/local/bin/holmes "$STATE_DIR/holmes/.holmes/config.yaml" "none (CLI)" "wrapper: opsora-holmes"
  if ai_key_present && [[ -n $AI_MODEL ]]; then
    if timeout 180 /usr/local/bin/opsora-holmes ask "Reply with the single word OK." >/dev/null 2>&1; then
      status holmesgpt PASS "CLI installed, AI provider answered a test question"
    else status holmesgpt WARNING "CLI installed, AI provider test failed (check $SECRETS_DIR/ai.env and AI_MODEL)"; fi
  else
    status holmesgpt WARNING "CLI installed; set AI_MODEL in $CONF_FILE and a key in $SECRETS_DIR/ai.env to run investigations"
  fi
}

# =============================================================================
# STEP: k8sgpt  (+ kubectl; connects to external clusters only)
# =============================================================================
step_k8sgpt() {
  local base file sums_name
  # kubectl: official binary + published sha256
  if [[ $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion) != "v$KUBECTL_VERSION" ]]; then
    base="https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/$ARCH"
    file=$CACHE_DIR/kubectl-$KUBECTL_VERSION-$ARCH
    fetch "$base/kubectl" "$file"
    verify_sha256 "$file" "$(curl -fsSL "$base/kubectl.sha256")"
    install -m 0755 "$file" /usr/local/bin/kubectl
  fi
  record_version kubectl "$KUBECTL_VERSION" "dl.k8s.io (sha256 verified)" /usr/local/bin/kubectl - - "client only"
  # k8sgpt: official .deb + release checksums
  if [[ $(dpkg-query -W -f='${Version}' k8sgpt 2>/dev/null) != "$K8SGPT_VERSION"* ]]; then
    base="https://github.com/k8sgpt-ai/k8sgpt/releases/download/v$K8SGPT_VERSION"
    sums_name="k8sgpt_${ARCH}.deb"; file=$CACHE_DIR/k8sgpt_${K8SGPT_VERSION}_${ARCH}.deb
    fetch "$base/$sums_name" "$file"
    verify_from_sums "$file" "$base/checksums.txt" "$sums_name" "$sums_name@$K8SGPT_VERSION"
    dpkg -i "$file"
  fi
  ensure_user k8sgpt "$STATE_DIR/k8sgpt"
  ai_env_file
  install -d -m 0750 -o root -g k8sgpt /etc/opsora/kubeconfigs
  if [[ -n $KUBECONFIG_PATH && -f $KUBECONFIG_PATH && ! -f /etc/opsora/kubeconfigs/default.yaml ]]; then
    install -m 0640 -o root -g k8sgpt "$KUBECONFIG_PATH" /etc/opsora/kubeconfigs/default.yaml
  fi
  write_file /usr/local/bin/opsora-k8sgpt 0755 <<EOF
#!/usr/bin/env bash
# Usage: sudo opsora-k8sgpt <cluster> [k8sgpt args]     e.g. sudo opsora-k8sgpt prod analyze --explain
# <cluster> is the name of a kubeconfig in /etc/opsora/kubeconfigs/<cluster>.yaml
[[ \$EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
cluster=\${1:?cluster name required}; shift
kc=/etc/opsora/kubeconfigs/\$cluster.yaml
[[ -f \$kc ]] || { echo "no kubeconfig \$kc. Available:"; ls /etc/opsora/kubeconfigs; exit 1; }
[[ \$# -gt 0 ]] || set -- analyze
exec setpriv --reuid k8sgpt --regid k8sgpt --init-groups env HOME=$STATE_DIR/k8sgpt XDG_CONFIG_HOME=$STATE_DIR/k8sgpt/.config KUBECONFIG="\$kc" /usr/bin/k8sgpt "\$@"
EOF
  write_file "$OPSORA_HOME/integrations/kubernetes/opsora-readonly-rbac.yaml" 0644 <<'EOF'
# Apply this IN EACH EXTERNAL CLUSTER (never on the OPSORA server):
#   kubectl apply -f opsora-readonly-rbac.yaml
#   kubectl -n opsora create token opsora-readonly --duration=8760h
# Build a kubeconfig from that token and save it on the OPSORA server as
#   /etc/opsora/kubeconfigs/<cluster>.yaml   (root:k8sgpt, mode 640)
# Read-only: no secrets, no write verbs, no cluster-admin.
apiVersion: v1
kind: Namespace
metadata: {name: opsora}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: opsora-readonly, namespace: opsora}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: opsora-readonly}
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, services, endpoints, events, nodes, namespaces, configmaps, persistentvolumes, persistentvolumeclaims, replicationcontrollers, serviceaccounts]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies, ingressclasses]
    verbs: [get, list, watch]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses]
    verbs: [get, list, watch]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations]
    verbs: [get, list, watch]
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gatewayclasses, gateways, httproutes]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: opsora-readonly}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: opsora-readonly}
subjects:
  - {kind: ServiceAccount, name: opsora-readonly, namespace: opsora}
EOF
  # AI backend (only providers k8sgpt lists as supported backends)
  local msg="installed; no kubeconfig yet" key=""
  if [[ -n $AI_PROVIDER && -n $AI_MODEL ]] && ai_key_present; then
    case $AI_PROVIDER in
      openai) key=$(sed -n 's/^OPENAI_API_KEY=//p' "$SECRETS_DIR/ai.env") ;;
      azureopenai|cohere|google|huggingface|litellm|customrest) key=$(grep -E '^[A-Z_]+_API_KEY=.+' "$SECRETS_DIR/ai.env" | head -1 | cut -d= -f2-) ;;
      *) warn "k8sgpt has no '$AI_PROVIDER' backend (supported include openai, azureopenai, cohere, google, amazonbedrock, ollama, localai, litellm). Analysis without --explain still works." ;;
    esac
    if [[ -n $key ]] && ! runuser -u k8sgpt -- env HOME="$STATE_DIR/k8sgpt" XDG_CONFIG_HOME="$STATE_DIR/k8sgpt/.config" k8sgpt auth list 2>/dev/null | sed -n '/Active/,/Unused/p' | grep -q "$AI_PROVIDER"; then
      runuser -u k8sgpt -- env HOME="$STATE_DIR/k8sgpt" XDG_CONFIG_HOME="$STATE_DIR/k8sgpt/.config" \
        k8sgpt auth add --backend "$AI_PROVIDER" --model "$AI_MODEL" --password "$key" >/dev/null
      chmod -R go-rwx "$STATE_DIR/k8sgpt/.config"
    fi
  fi
  /usr/bin/k8sgpt version >/dev/null || die "k8sgpt binary does not run"
  record_version k8sgpt "$K8SGPT_VERSION" "github.com/k8sgpt-ai/k8sgpt .deb (sha256 verified)" /usr/bin/k8sgpt "$STATE_DIR/k8sgpt/.config/k8sgpt/k8sgpt.yaml" "none (CLI)" "wrapper: opsora-k8sgpt <cluster>"
  local kc ok=0 n=0
  for kc in /etc/opsora/kubeconfigs/*.yaml; do
    [[ -f $kc ]] || continue; n=$((n+1))
    if runuser -u k8sgpt -- env KUBECONFIG="$kc" kubectl --request-timeout=10s get ns >/dev/null 2>&1; then ok=$((ok+1)); else warn "cluster $(basename "$kc" .yaml) not reachable with its kubeconfig"; fi
  done
  if (( n == 0 )); then status k8sgpt WARNING "$msg: add /etc/opsora/kubeconfigs/<cluster>.yaml (see integrations/kubernetes/opsora-readonly-rbac.yaml)"
  elif (( ok == n )); then status k8sgpt PASS "$ok/$n clusters reachable"
  else status k8sgpt WARNING "$ok/$n clusters reachable"; fi
}

# =============================================================================
# STEP: openrca  (microsoft/OpenRCA benchmark checkout; no service, no port)
# =============================================================================
step_openrca() {
  if ! is_true "$ENABLE_OPENRCA"; then status openrca SKIPPED "ENABLE_OPENRCA=false"; return 0; fi
  local dir=$OPSORA_HOME/research/openrca
  install -d -m 0755 -o opsora -g opsora "$dir"
  if [[ ! -d $dir/src/.git ]]; then
    runuser -u opsora -- git clone -q https://github.com/microsoft/OpenRCA "$dir/src"
  fi
  if [[ $(runuser -u opsora -- git -C "$dir/src" rev-parse HEAD) != "$OPENRCA_COMMIT" ]]; then
    runuser -u opsora -- git -C "$dir/src" fetch -q origin
    runuser -u opsora -- git -C "$dir/src" checkout -q --detach "$OPENRCA_COMMIT"
  fi
  [[ -x $dir/venv/bin/python ]] || runuser -u opsora -- python3 -m venv "$dir/venv"
  if is_true "$OPENRCA_INSTALL_DEPS" && [[ -f $dir/src/requirements.txt ]]; then
    runuser -u opsora -- "$dir/venv/bin/pip" install -q -r "$dir/src/requirements.txt"
  fi
  write_file "$dir/README-OPSORA.md" 0644 <<EOF
# OpenRCA on OPSORA

Project: microsoft/OpenRCA (ICLR 2025), pinned to commit $OPENRCA_COMMIT.
It is a benchmark for scoring LLM root-cause analysis, not an RCA engine and not
a service. Nothing in OPSORA depends on it.

- Source: $dir/src        Python env: $dir/venv
- The telemetry dataset (about 68 GB) is NOT downloaded. Follow $dir/src/README.md
  if you want to run evaluations; upstream recommends 80 GB disk and 32 GB RAM.
- Install its Python dependencies with OPENRCA_INSTALL_DEPS=true and
  \`opsora-install.sh --component openrca\`.
EOF
  record_version openrca "${OPENRCA_COMMIT:0:12}" "github.com/microsoft/OpenRCA (git commit)" - "$dir" "none" "research/evaluation only, dataset not downloaded"
  status openrca PASS "checked out at ${OPENRCA_COMMIT:0:12}, isolated under $dir"
}

# =============================================================================
# STEP: ansible
# =============================================================================
step_ansible() {
  install -d -m 0755 /opt/pipx
  if [[ $(pipx_global list --short 2>/dev/null | awk '$1=="ansible-core"{print $2}') != "$ANSIBLE_CORE_VERSION" ]]; then
    pipx_global install --force "ansible-core==$ANSIBLE_CORE_VERSION"
  fi
  local a=$OPSORA_HOME/ansible
  install -d -m 0755 "$a"/{inventories/local,playbooks,roles,collections,group_vars,host_vars,templates,files}
  [[ -f $a/ansible.cfg ]] || write_file "$a/ansible.cfg" 0644 <<EOF
[defaults]
inventory = $a/inventories/local/hosts.yml
roles_path = $a/roles
collections_path = $a/collections
host_key_checking = True
retry_files_enabled = False
stdout_callback = default
interpreter_python = auto_silent
forks = 10

[privilege_escalation]
become = False
EOF
  [[ -f $a/inventories/local/hosts.yml ]] || write_file "$a/inventories/local/hosts.yml" 0644 <<'EOF'
# Safe test inventory: only this server, no SSH involved.
all:
  hosts:
    opsora-local:
      ansible_connection: local
EOF
  [[ -f $a/playbooks/safe-health-report.yml ]] || write_file "$a/playbooks/safe-health-report.yml" 0644 <<'EOF'
---
# Read-only example runbook: gathers facts and reports. Changes nothing.
- name: OPSORA safe health report
  hosts: all
  gather_facts: true
  tasks:
    - name: Disk usage
      ansible.builtin.command: df -hT -x tmpfs -x devtmpfs
      register: disk
      changed_when: false
    - name: Failed systemd units
      ansible.builtin.command: systemctl --failed --no-legend
      register: failed
      changed_when: false
    - name: Report
      ansible.builtin.debug:
        msg:
          - "host={{ ansible_hostname }} os={{ ansible_distribution }} {{ ansible_distribution_version }}"
          - "load={{ ansible_loadavg['1m'] | default('n/a') }} mem_free_mb={{ ansible_memfree_mb }}"
          - "failed_units={{ failed.stdout_lines | length }}"
          - "{{ disk.stdout_lines }}"
EOF
  ( cd "$a" && ANSIBLE_CONFIG=$a/ansible.cfg ansible all -m ansible.builtin.ping >/dev/null ) || die "ansible ping against local inventory failed"
  ( cd "$a" && ANSIBLE_CONFIG=$a/ansible.cfg ansible-playbook --syntax-check playbooks/safe-health-report.yml >/dev/null ) || die "example runbook failed syntax check"
  record_version ansible-core "$ANSIBLE_CORE_VERSION" "PyPI via pipx (/opt/pipx)" /usr/local/bin/ansible "$a/ansible.cfg" - "layout under $a"
  status ansible PASS "ansible all -m ping OK, example runbook syntax OK"
}

# =============================================================================
# STEP: terraform
# =============================================================================
step_terraform() {
  if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" >/etc/apt/sources.list.d/hashicorp.list
    apt_update
  fi
  if [[ $(terraform version -json 2>/dev/null | jq -r .terraform_version) != "$TERRAFORM_VERSION" ]]; then
    apt-get install -y --allow-downgrades --allow-change-held-packages "terraform=${TERRAFORM_VERSION}*"
  fi
  apt-mark hold terraform >/dev/null
  local t=$OPSORA_HOME/terraform
  install -d -m 0755 "$t"/{modules,environments/selftest,providers,plans}
  [[ -f $t/environments/selftest/main.tf ]] || write_file "$t/environments/selftest/main.tf" 0644 <<'EOF'
# Self-test only. Uses the built-in terraform_data resource: no provider download,
# no cloud credentials, nothing is created outside local state.
terraform {
  required_version = ">= 1.6"
}

variable "note" {
  type    = string
  default = "opsora terraform self-test"
}

resource "terraform_data" "selftest" {
  input = var.note
}

output "note" {
  value = terraform_data.selftest.output
}
EOF
  ( cd "$t/environments/selftest" && terraform init -input=false -no-color >/dev/null && terraform validate -no-color >/dev/null \
      && terraform plan -input=false -no-color -lock=false >/dev/null ) || die "terraform init/validate/plan self-test failed"
  record_version terraform "$TERRAFORM_VERSION" "apt.releases.hashicorp.com (held)" /usr/bin/terraform "$t" - "init/validate/plan self-test only; never apply/destroy"
  status terraform PASS "init, validate, plan OK (nothing applied)"
}

# =============================================================================
# STEP: semaphore
# =============================================================================
step_semaphore() {
  local base file changed=0 port cfg=/etc/semaphore/config.json
  if [[ $(dpkg-query -W -f='${Version}' semaphore 2>/dev/null) != "$SEMAPHORE_VERSION"* ]]; then
    base="https://github.com/semaphoreui/semaphore/releases/download/v$SEMAPHORE_VERSION"
    file=$CACHE_DIR/semaphore_${SEMAPHORE_VERSION}_linux_${ARCH}.deb
    fetch "$base/$(basename "$file")" "$file"
    verify_from_sums "$file" "$base/semaphore_${SEMAPHORE_VERSION}_checksums.txt"
    dpkg -i "$file"; changed=1
  fi
  ensure_user semaphore /var/lib/semaphore
  install -d -m 0750 -o semaphore -g semaphore /var/lib/semaphore/tmp
  install -d -m 0750 -o root -g semaphore /etc/semaphore
  port=$(pg_port); port=${port:-5432}
  pg_role semaphore "$(secret pg_semaphore)" 30
  pg_db semaphore semaphore
  local web="http://127.0.0.1:3000"; [[ -n $SEMAPHORE_DOMAIN ]] && web="https://$SEMAPHORE_DOMAIN"
  # the three keys must be base64 of 32 random bytes and must never change once data exists
  local k
  for k in semaphore_cookie_hash semaphore_cookie_encryption semaphore_access_key_encryption; do
    [[ -s $SECRETS_DIR/$k ]] || ( umask 077; head -c32 /dev/urandom | base64 >"$SECRETS_DIR/$k" )
  done
  jq -n --arg host "127.0.0.1:$port" --arg pass "$(secret pg_semaphore)" --arg web "$web" \
        --arg ch "$(cat "$SECRETS_DIR/semaphore_cookie_hash")" --arg ce "$(cat "$SECRETS_DIR/semaphore_cookie_encryption")" \
        --arg ak "$(cat "$SECRETS_DIR/semaphore_access_key_encryption")" '{
    postgres: {host: $host, user: "semaphore", pass: $pass, name: "semaphore", options: {sslmode: "disable"}},
    dialect: "postgres",
    interface: "127.0.0.1",
    port: ":3000",
    web_host: $web,
    tmp_path: "/var/lib/semaphore/tmp",
    cookie_hash: $ch,
    cookie_encryption: $ce,
    access_key_encryption: $ak,
    max_parallel_tasks: 4,
    password_login_disable: false,
    non_admin_can_create_project: false
  }' | write_file "$cfg" 0640 root:semaphore
  (( changed |= WF_CHANGED )) || true
  write_file /etc/systemd/system/semaphore.service <<EOF
[Unit]
Description=Semaphore UI (OPSORA)
Documentation=https://semaphoreui.com/docs
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=semaphore
Group=semaphore
WorkingDirectory=/var/lib/semaphore
Environment=HOME=/var/lib/semaphore
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=ANSIBLE_HOST_KEY_CHECKING=True
ExecStart=/usr/bin/semaphore server --config $cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  (( changed |= WF_CHANGED )) || true
  runuser -u semaphore -- semaphore migrate --config "$cfg" >/dev/null 2>&1 || true   # server also migrates on start
  svc_enable_restart semaphore "$changed"
  wait_http http://127.0.0.1:3000/api/ping 45 || die "Semaphore /api/ping not answering (journalctl -u semaphore)"
  if ! runuser -u semaphore -- semaphore user list --config "$cfg" 2>/dev/null | grep -qw admin; then
    runuser -u semaphore -- semaphore user add --admin --login admin --name "OPSORA Admin" --email "$OPSORA_ADMIN_EMAIL" \
      --password "$(secret semaphore_admin 24)" --config "$cfg" >/dev/null
  fi
  # verify the admin login through the API
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -c /dev/null -H 'Content-Type: application/json' \
    -d "{\"auth\":\"admin\",\"password\":\"$(secret semaphore_admin 24)\"}" http://127.0.0.1:3000/api/auth/login || echo 000)
  record_version semaphore "$SEMAPHORE_VERSION" "github.com/semaphoreui/semaphore .deb (sha256 verified)" /usr/bin/semaphore "$cfg" semaphore.service "PostgreSQL backend, 127.0.0.1:3000"
  if [[ $code == 204 || $code == 200 ]]; then status semaphore PASS "API ping OK, admin login OK"
  else status semaphore WARNING "API ping OK, admin login returned HTTP $code"; fi
}

# =============================================================================
# STEP: redisinsight  (postponed: no official headless Linux server build)
# =============================================================================
step_redisinsight() {
  if is_true "$ENABLE_REDIS_INSIGHT"; then
    warn "Redis Insight is published for Linux only as a desktop app (plus Docker/Kubernetes)."
    warn "No native headless server install exists upstream, so it is not installed. Use redis-cli, or the desktop app over an SSH tunnel to 127.0.0.1:6379."
    status redisinsight WARNING "requested, but no official native server install exists - postponed"
  else
    status redisinsight SKIPPED "postponed: no official native headless install (use redis-cli or desktop app via SSH tunnel)"
  fi
}

# =============================================================================
# STEP: vhosts  (Nginx sites + Let's Encrypt via webroot; no backend over plain HTTP)
# =============================================================================
vhost() { # NAME DOMAIN UPSTREAM AUTH(basic|app)
  local name=$1 domain=$2 upstream=$3 auth=$4 site=/etc/nginx/sites-available/opsora-$1.conf acl="" authcfg="" live
  [[ -n $domain ]] || { rm -f "/etc/nginx/sites-enabled/opsora-$name.conf"; return 0; }
  live=/etc/letsencrypt/live/$domain
  if is_true "$RESTRICT_UI_TO_TRUSTED" && [[ -n $TRUSTED_NETWORKS ]]; then
    local n; for n in $TRUSTED_NETWORKS; do acl+="        allow $n;"$'\n'; done; acl+="        deny all;"$'\n'
  fi
  [[ $auth == basic ]] && authcfg="        auth_basic \"OPSORA $name\";"$'\n'"        auth_basic_user_file /etc/nginx/opsora.htpasswd;"$'\n'
  if [[ ! -f $live/fullchain.pem ]]; then
    # stage 1: ACME only
    write_file "$site" 0644 <<EOF
server {
    listen 80;
    $L6_80
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 503; }
}
EOF
    ln -sfn "$site" "/etc/nginx/sites-enabled/opsora-$name.conf"
    nginx -t && systemctl reload nginx
    if [[ -z $LETSENCRYPT_EMAIL ]]; then warn "$domain: LETSENCRYPT_EMAIL is empty, no certificate requested"; return 1; fi
    if ! getent hosts "$domain" >/dev/null; then warn "$domain does not resolve yet, no certificate requested"; return 1; fi
    certbot certonly --webroot -w /var/www/letsencrypt -d "$domain" --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" --keep-until-expiring \
      || { warn "$domain: certificate request failed (DNS must point here and port 80 must be reachable)"; return 1; }
  fi
  write_file "$site" 0644 <<EOF
# Managed by OPSORA installer
server {
    listen 80;
    $L6_80
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    $L6_443
    server_name $domain;

    ssl_certificate     $live/fullchain.pem;
    ssl_certificate_key $live/privkey.pem;
    include /etc/nginx/snippets/opsora-tls.conf;
    include /etc/nginx/snippets/opsora-security.conf;

    access_log /var/log/nginx/opsora-$name.access.log;
    error_log  /var/log/nginx/opsora-$name.error.log;
    client_max_body_size 64m;

    location / {
$acl$authcfg        proxy_pass http://$upstream;
        include /etc/nginx/snippets/opsora-proxy.conf;
    }
}
EOF
  ln -sfn "$site" "/etc/nginx/sites-enabled/opsora-$name.conf"
  return 0
}
step_vhosts() {
  if [[ -z $(all_domains) ]]; then
    status vhosts SKIPPED "no domains configured: UIs on 127.0.0.1 only"; status tls SKIPPED "no domains configured"; return 0
  fi
  if [[ ! -f /etc/nginx/opsora.htpasswd ]]; then
    printf 'admin:%s\n' "$(openssl passwd -apr1 "$(secret nginx_basic_auth 24)")" >/etc/nginx/opsora.htpasswd
  fi
  chown root:www-data /etc/nginx/opsora.htpasswd; chmod 640 /etc/nginx/opsora.htpasswd
  local failed=""
  vhost openobserve  "$OPENOBSERVE_DOMAIN"  127.0.0.1:5080 app   || failed+=" $OPENOBSERVE_DOMAIN"
  vhost prometheus   "$PROMETHEUS_DOMAIN"   127.0.0.1:9090 basic || failed+=" $PROMETHEUS_DOMAIN"
  vhost alertmanager "$ALERTMANAGER_DOMAIN" 127.0.0.1:9093 basic || failed+=" $ALERTMANAGER_DOMAIN"
  if is_true "$ENABLE_KEEP"; then vhost keep "$KEEP_DOMAIN" 127.0.0.1:3001 app || failed+=" $KEEP_DOMAIN"; fi
  vhost pgadmin      "$PGADMIN_DOMAIN"      127.0.0.1:5050 app   || failed+=" $PGADMIN_DOMAIN"
  vhost semaphore    "$SEMAPHORE_DOMAIN"    127.0.0.1:3000 app   || failed+=" $SEMAPHORE_DOMAIN"
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  write_file /etc/letsencrypt/renewal-hooks/deploy/opsora-nginx-reload.sh 0755 <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
  nginx -t; systemctl reload nginx
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  if [[ -z $failed ]]; then
    status vhosts PASS "HTTPS vhosts active for: $(all_domains | tr '\n' ' ')"
    if certbot renew --dry-run --quiet 2>/dev/null; then status tls PASS "certificates issued, renewal dry-run OK, certbot.timer enabled"
    else status tls WARNING "certificates issued, renewal dry-run failed"; fi
  else
    status vhosts WARNING "no certificate, backend NOT exposed, for:$failed"
    status tls WARNING "certificate missing for:$failed"
  fi
}

# =============================================================================
# STEP: targets  (blackbox targets for what is really running; no fake targets)
# =============================================================================
step_targets() {
  have promtool || { status targets SKIPPED "prometheus not installed"; return 0; }
  local f=/etc/prometheus/file_sd/blackbox-tcp/opsora-local.yml unit
  {
    echo "# Generated by OPSORA installer from services that are active on this host"
    add() { systemctl is-active --quiet "$1" 2>/dev/null && printf -- "- targets: ['%s']\n  labels: {service: '%s'}\n" "$2" "$3"; return 0; }
    add nginx 127.0.0.1:80 nginx
    add "postgresql@$POSTGRES_VERSION-main" "127.0.0.1:$(pg_port)" postgresql
    unit=$(redis_unit); [[ -n $unit ]] && add "$unit" 127.0.0.1:6379 redis
    add openobserve 127.0.0.1:5080 openobserve
    add keep-api 127.0.0.1:8080 keep-api
    add keep-ui 127.0.0.1:3001 keep-ui
    add semaphore 127.0.0.1:3000 semaphore
    add pgadmin4 127.0.0.1:5050 pgadmin
  } | write_file "$f" 0644
  local d
  {
    echo "# Generated by OPSORA installer: public UIs that have a certificate"
    for d in $(all_domains); do
      if [[ -f /etc/letsencrypt/live/$d/fullchain.pem ]]; then printf -- "- targets: ['https://%s']\n  labels: {service: 'web-ui'}\n" "$d"; fi
    done
  } | write_file /etc/prometheus/file_sd/blackbox-http/opsora-domains.yml 0644
  promtool check config /etc/prometheus/prometheus.yml >/dev/null
  systemctl is-active --quiet prometheus && systemctl reload prometheus
  status targets PASS "blackbox targets generated from active services"
}

# =============================================================================
# STEP: backup  (script + systemd service/timer + first run + archive check)
# =============================================================================
step_backup() {
  write_file /usr/local/sbin/opsora-backup 0750 <<EOF
#!/usr/bin/env bash
# OPSORA scheduled backup. Restore procedure: $DOC_DIR/OPERATIONS.md
set -Eeuo pipefail
umask 077
ROOT=$OPSORA_HOME/backups/scheduled
TS=\$(date +%Y%m%d-%H%M%S)
DEST=\$ROOT/\$TS
PROM=/var/lib/node_exporter/textfile/opsora_backup.prom
RETENTION_DAYS=\${BACKUP_RETENTION_DAYS:-$BACKUP_RETENTION_DAYS}
metric() { # status
  [[ -d \$(dirname "\$PROM") ]] || return 0
  { echo "# HELP opsora_backup_last_status 0 = last backup succeeded"
    echo "# TYPE opsora_backup_last_status gauge"
    echo "opsora_backup_last_status \$1"
    if [[ \$1 == 0 ]]; then
      echo "# TYPE opsora_backup_last_success_timestamp_seconds gauge"
      echo "opsora_backup_last_success_timestamp_seconds \$(date +%s)"
      echo "# TYPE opsora_backup_last_size_bytes gauge"
      echo "opsora_backup_last_size_bytes \$(du -sb "\$DEST" | cut -f1)"
    else
      grep -h '^opsora_backup_last_success_timestamp_seconds' "\$PROM" 2>/dev/null || true
    fi
  } >"\$PROM.tmp" && chmod 644 "\$PROM.tmp" && mv "\$PROM.tmp" "\$PROM"
}
trap 'metric 1; echo "backup FAILED" >&2' ERR
mkdir -p "\$DEST/postgresql"
runuser -u postgres -- pg_dumpall --globals-only >"\$DEST/postgresql/globals.sql"
for db in \$(runuser -u postgres -- psql -XAtc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"); do
  runuser -u postgres -- pg_dump -Fc -d "\$db" >"\$DEST/postgresql/\$db.dump"
  pg_restore --list "\$DEST/postgresql/\$db.dump" >/dev/null     # archive is readable
done
PATHS=()
for p in /etc/opsora $OPSORA_HOME/config $OPSORA_HOME/configs $OPSORA_HOME/ansible $OPSORA_HOME/terraform $OPSORA_HOME/runbooks \\
         $OPSORA_HOME/integrations /etc/nginx /etc/letsencrypt /etc/prometheus /etc/alertmanager /etc/alloy /etc/blackbox_exporter \\
         /etc/snmp_exporter /etc/mysqld_exporter /etc/semaphore /etc/redis /etc/postgresql /etc/fail2ban/jail.d /etc/ufw \\
         /etc/ssh/sshd_config.d /etc/systemd/system /var/lib/opsora/keep/state /var/lib/opsora/holmes/.holmes /var/lib/pgadmin/pgadmin4.db; do
  [[ -e \$p ]] && PATHS+=("\$p")
done
tar --warning=no-file-changed --exclude='*/.terraform/*' -czf "\$DEST/config.tar.gz" "\${PATHS[@]}" 2>/dev/null || [[ \$? -eq 1 ]]
tar -tzf "\$DEST/config.tar.gz" >/dev/null
( cd "\$DEST" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
# retention: only this script's own timestamped directories
find "\$ROOT" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9]*-*' -mtime +"\$RETENTION_DAYS" -exec rm -rf {} +
metric 0
echo "backup OK: \$DEST (\$(du -sh "\$DEST" | cut -f1))"
EOF
  write_file /etc/systemd/system/opsora-backup.service <<'EOF'
[Unit]
Description=OPSORA backup (PostgreSQL + configuration)
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opsora-backup
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
  write_file /etc/systemd/system/opsora-backup.timer <<'EOF'
[Unit]
Description=Daily OPSORA backup

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  install -d -m 0700 "$OPSORA_HOME/backups/scheduled"
  systemctl daemon-reload
  systemctl enable --now opsora-backup.timer >/dev/null
  systemctl start opsora-backup.service || die "first backup run failed (journalctl -u opsora-backup)"
  local last; last=$(find "$OPSORA_HOME/backups/scheduled" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
  ( cd "$last" && sha256sum --quiet -c SHA256SUMS ) || die "backup checksum verification failed"
  status backup PASS "timer enabled (daily 02:30), first backup verified: $last"
}

# =============================================================================
# Health check script (standalone, installed to /opt/opsora/scripts)
# =============================================================================
install_health_check() {
  write_file "$OPSORA_HOME/scripts/opsora-health-check.sh" 0750 <<'HEALTH'
#!/usr/bin/env bash
# OPSORA health check. Exit code 0 = no FAIL.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }
CONF=/opt/opsora/config/install.env; SEC=/etc/opsora/secrets
# shellcheck disable=SC1090
source "$CONF"
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else G=; R=; Y=; N=; fi
FAILS=0; WARNS=0
pass() { printf '%s[PASS]%s %s\n' "$G" "$N" "$1"; }
skip() { printf '[SKIP] %s - %s\n' "$1" "$2"; }
wrn()  { WARNS=$((WARNS+1)); printf '%s[WARN]%s %s - %s\n' "$Y" "$N" "$1" "$2"; }
# fail COMPONENT "exact failure" UNIT "likely cause" "safe remediation" "verification command"
fail() {
  FAILS=$((FAILS+1)); printf '%s[FAIL]%s %s\n' "$R" "$N" "$1"
  printf '       failure:      %s\n' "$2"
  if [[ -n ${3:-} ]]; then
    printf '       systemd:      %s\n' "$(systemctl is-active "$3" 2>&1) / $(systemctl is-enabled "$3" 2>&1)"
    printf '       recent log:\n'; journalctl -u "$3" -n 6 --no-pager 2>/dev/null | sed 's/^/         /'
  fi
  printf '       likely cause: %s\n       remediation:  %s\n       verify:       %s\n' "${4:-unknown}" "${5:-inspect the log above}" "${6:-}"
}
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
http()   { curl -fsS -o /dev/null --max-time 8 "$@" 2>/dev/null; }
# svc LABEL UNIT URL
svc() {
  if ! active "$2"; then fail "$1" "unit $2 is not active" "$2" "service crashed, misconfigured, or port already in use" "systemctl restart $2" "systemctl status $2"
  elif [[ -n ${3:-} ]] && ! http "$3"; then fail "$1" "$3 did not answer" "$2" "still starting, or listening on a different address" "systemctl restart $2; ss -ltnp | grep ${3##*:}" "curl -v $3"
  else pass "$1"; fi
}
PGV=${POSTGRES_VERSION:-17}
PGPORT_=$(pg_lsclusters -h 2>/dev/null | awk -v v="$PGV" '$1==v && $2=="main"{print $3}'); PGPORT_=${PGPORT_:-5432}

echo "========================================"; echo "OPSORA HEALTH CHECK"; echo "========================================"; echo
# shellcheck disable=SC1091
. /etc/os-release
[[ ${VERSION_ID:-} == 24.04 ]] && pass "Ubuntu ($PRETTY_NAME, kernel $(uname -r))" || wrn "Ubuntu" "expected 24.04, found ${PRETTY_NAME:-unknown}"
load=$(cut -d' ' -f2 /proc/loadavg); cores=$(nproc)
awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l < c*1.5)}' && pass "CPU (load5 $load on $cores cores)" || wrn "CPU" "5-minute load $load exceeds 1.5x $cores cores"
memp=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d",(t-a)*100/t}' /proc/meminfo)
(( memp < 90 )) && pass "RAM (${memp}% used)" || wrn "RAM" "${memp}% used"
dmax=$(df --output=pcent,target -x tmpfs -x devtmpfs -x squashfs -x overlay | tail -n +2 | sort -rn | head -1)
dp=$(awk '{print $1}' <<<"$dmax" | tr -dc 0-9)
if (( dp < 80 )); then pass "Disk (fullest: $dmax)"; elif (( dp < 92 )); then wrn "Disk" "fullest filesystem $dmax"
else fail "Disk" "filesystem almost full: $dmax" "" "data growth (OpenObserve, Prometheus, backups, logs)" "du -xh --max-depth=2 /var/lib /opt/opsora/backups | sort -h | tail; lower retention in $CONF" "df -h"; fi
ip route get 1.1.1.1 >/dev/null 2>&1 && pass "Network (default route present)" || fail "Network" "no route to the internet" "" "interface down or missing gateway" "ip -br addr; ip route" "ip route get 1.1.1.1"
getent hosts github.com >/dev/null && pass "DNS" || fail "DNS" "cannot resolve github.com" systemd-resolved "resolver not configured" "resolvectl status" "getent hosts github.com"
[[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && pass "NTP (synchronized)" || fail "NTP" "clock is not synchronized" systemd-timesyncd "no NTP server reachable" "timedatectl set-ntp true; systemctl restart systemd-timesyncd" "timedatectl"
if [[ ${CONFIGURE_UFW:-true} =~ ^(true|1|yes|on)$ ]]; then
  ufw status | grep -q '^Status: active' && pass "Firewall (ufw active)" || fail "Firewall" "ufw is not active" ufw "disabled manually" "ufw --force enable" "ufw status verbose"
else skip "Firewall" "CONFIGURE_UFW=false"; fi
svc "Fail2ban" fail2ban
svc "Nginx" nginx http://127.0.0.1:8088/nginx-health
nginx -t >/dev/null 2>&1 || fail "Nginx config" "nginx -t reports errors" nginx "broken vhost" "nginx -t" "nginx -t"
# TLS
doms=(); for d in "${OPENOBSERVE_DOMAIN:-}" "${PROMETHEUS_DOMAIN:-}" "${ALERTMANAGER_DOMAIN:-}" "${KEEP_DOMAIN:-}" "${PGADMIN_DOMAIN:-}" "${SEMAPHORE_DOMAIN:-}"; do [[ -n $d ]] && doms+=("$d"); done
if (( ${#doms[@]} == 0 )); then skip "TLS" "no public domains configured"
else
  bad=""
  for d in "${doms[@]}"; do
    c=/etc/letsencrypt/live/$d/fullchain.pem
    if [[ ! -f $c ]]; then bad+=" $d(no cert)"; elif ! openssl x509 -checkend $((14*86400)) -noout -in "$c" >/dev/null; then bad+=" $d(expires <14d)"; fi
  done
  [[ -z $bad ]] && pass "TLS (${#doms[@]} certificates valid >14 days)" || fail "TLS" "certificate problem:$bad" certbot.timer "DNS not pointing here, port 80 blocked, or renewal failing" "certbot renew --dry-run; then re-run the installer with --component vhosts" "certbot certificates"
fi
# PostgreSQL + pgvector
if pg_isready -q -h 127.0.0.1 -p "$PGPORT_"; then
  if PGPASSWORD=$(cat $SEC/pg_opsora_app 2>/dev/null) psql -X -Atq -h 127.0.0.1 -p "$PGPORT_" -U "${POSTGRES_USER:-opsora_app}" -d "${POSTGRES_DB:-opsora}" -c 'select 1' >/dev/null 2>&1; then pass "PostgreSQL ($PGV on 127.0.0.1:$PGPORT_, app login OK)"
  else fail "PostgreSQL" "application role cannot log in" "postgresql@$PGV-main" "password in $SEC/pg_opsora_app differs from the role, or pg_hba changed" "re-run installer: --component postgresql" "psql -h 127.0.0.1 -U ${POSTGRES_USER:-opsora_app} ${POSTGRES_DB:-opsora}"; fi
  v=$(runuser -u postgres -- psql -XAtc "select extversion from pg_extension where extname='vector'" -d "${POSTGRES_DB:-opsora}" 2>/dev/null)
  [[ -n $v ]] && pass "pgvector ($v)" || fail "pgvector" "extension vector missing in ${POSTGRES_DB:-opsora}" "" "extension never created" "re-run installer: --component pgvector" "psql -d ${POSTGRES_DB:-opsora} -c '\\dx vector'"
else
  fail "PostgreSQL" "pg_isready failed on 127.0.0.1:$PGPORT_" "postgresql@$PGV-main" "service stopped or disk full" "systemctl restart postgresql@$PGV-main" "pg_isready -h 127.0.0.1 -p $PGPORT_"
  fail "pgvector" "PostgreSQL is down" "" "PostgreSQL is down" "fix PostgreSQL first" ""
fi
# Redis
ru=$(systemctl list-unit-files 2>/dev/null | awk '$1 ~ /^redis(-server)?\.service$/{print $1; exit}')
if [[ $(REDISCLI_AUTH=$(cat $SEC/redis_app 2>/dev/null) redis-cli --no-auth-warning --user opsora_app -h 127.0.0.1 ping 2>/dev/null) == PONG ]]; then pass "Redis (PONG)"
else fail "Redis" "authenticated PING failed" "${ru:-redis-server}" "service down or ACL file changed" "systemctl restart ${ru:-redis-server}" "redis-cli --user opsora_app --askpass ping"; fi
svc "OpenObserve" openobserve http://127.0.0.1:5080/healthz
svc "Alloy" alloy http://127.0.0.1:12345/-/ready
svc "Prometheus" prometheus http://127.0.0.1:9090/-/ready
if active prometheus; then
  down=$(curl -fsS --max-time 8 'http://127.0.0.1:9090/api/v1/query?query=up==0' 2>/dev/null | jq -r '[.data.result[].metric | "\(.job)/\(.instance)"] | join(", ")' 2>/dev/null)
  [[ -z $down ]] && pass "Prometheus targets (all up)" || wrn "Prometheus targets" "down: $down"
fi
svc "Alertmanager" alertmanager http://127.0.0.1:9093/-/ready
if [[ ${ENABLE_KEEP:-true} =~ ^(true|1|yes|on)$ ]]; then svc "Keep API" keep-api http://127.0.0.1:8080/healthcheck; svc "Keep UI" keep-ui
else skip "Keep" "ENABLE_KEEP=false"; fi
if [[ -x /usr/local/bin/holmes ]] && runuser -u holmes -- env HOME=/var/lib/opsora/holmes /usr/local/bin/holmes ask --help >/dev/null 2>&1; then
  grep -Eq '^[A-Z_]+_API_KEY=.+' $SEC/ai.env 2>/dev/null && pass "HolmesGPT (CLI ok, AI key present)" || wrn "HolmesGPT" "CLI ok, no AI key in $SEC/ai.env"
else fail "HolmesGPT" "holmes CLI does not start" "" "pipx environment broken" "re-run installer: --component holmesgpt" "holmes ask --help"; fi
if /usr/bin/k8sgpt version >/dev/null 2>&1; then
  n=0; ok=0
  for kc in /etc/opsora/kubeconfigs/*.yaml; do [[ -f $kc ]] || continue; n=$((n+1)); runuser -u k8sgpt -- env KUBECONFIG="$kc" kubectl --request-timeout=8s get ns >/dev/null 2>&1 && ok=$((ok+1)); done
  if (( n == 0 )); then wrn "K8sGPT" "binary ok, no kubeconfig in /etc/opsora/kubeconfigs"
  elif (( ok == n )); then pass "K8sGPT ($ok/$n clusters reachable)"
  else fail "K8sGPT" "only $ok of $n clusters reachable" "" "expired token, wrong API endpoint, or firewall" "kubectl --kubeconfig /etc/opsora/kubeconfigs/<cluster>.yaml get ns" "sudo opsora-k8sgpt <cluster> analyze"; fi
else fail "K8sGPT" "k8sgpt binary missing or broken" "" "package removed" "re-run installer: --component k8sgpt" "k8sgpt version"; fi
if [[ ${ENABLE_OPENRCA:-true} =~ ^(true|1|yes|on)$ ]]; then
  [[ -d /opt/opsora/research/openrca/src/.git ]] && pass "OpenRCA (checkout $(git -c safe.directory='*' -C /opt/opsora/research/openrca/src rev-parse --short HEAD 2>/dev/null), research only)" || fail "OpenRCA" "checkout missing" "" "step never ran" "re-run installer: --component openrca" "ls /opt/opsora/research/openrca"
else skip "OpenRCA" "ENABLE_OPENRCA=false"; fi
( cd /opt/opsora/ansible 2>/dev/null && ANSIBLE_CONFIG=/opt/opsora/ansible/ansible.cfg ansible all -m ansible.builtin.ping >/dev/null 2>&1 ) && pass "Ansible ($(ansible --version | head -1))" || fail "Ansible" "ansible ping on local inventory failed" "" "pipx environment broken or inventory edited" "re-run installer: --component ansible" "cd /opt/opsora/ansible && ansible all -m ping"
terraform version >/dev/null 2>&1 && pass "Terraform ($(terraform version | head -1))" || fail "Terraform" "terraform binary missing" "" "package removed" "re-run installer: --component terraform" "terraform version"
svc "Semaphore" semaphore http://127.0.0.1:3000/api/ping
svc "pgAdmin" pgadmin4 http://127.0.0.1:5050/misc/ping
ebad=""
for e in node_exporter:9100 postgres_exporter:9187 mysqld_exporter:9104 snmp_exporter:9116 blackbox_exporter:9115; do
  http "http://127.0.0.1:${e##*:}/metrics" || ebad+=" ${e%%:*}"
done
[[ -z $ebad ]] && pass "Exporters (node, postgres, mysqld, snmp, blackbox)" || fail "Exporters" "not answering:$ebad" "" "exporter stopped" "systemctl restart${ebad}" "curl -s http://127.0.0.1:9100/metrics | head"
# Backup
prom=/var/lib/node_exporter/textfile/opsora_backup.prom
last=$(awk '/^opsora_backup_last_success_timestamp_seconds/{print int($2)}' "$prom" 2>/dev/null)
if [[ -n ${last:-} ]] && (( $(date +%s) - last < 93600 )) && active opsora-backup.timer; then pass "Backup (last success $(date -d "@$last" '+%F %T'), timer active)"
else fail "Backup" "no successful backup in the last 26 hours, or timer inactive" opsora-backup.service "disk full, PostgreSQL down, or timer disabled" "systemctl enable --now opsora-backup.timer; systemctl start opsora-backup.service" "journalctl -u opsora-backup -n 30"; fi
# Security
ssh_port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'); ssh_port=${ssh_port:-22}
pub=$(ss -H -ltnp 2>/dev/null | awk -v sp="$ssh_port" -v ob="${OTLP_BIND:-127.0.0.1}" '{
  split($4,a,":"); port=a[length(a)]; addr=substr($4,1,length($4)-length(port)-1)
  if (addr ~ /^(127\.|\[::1\]|::1)/) next
  if (port==sp || port==80 || port==443) next
  if ((port==4317 || port==4318) && addr==ob) next
  print addr":"port" "$6 }' | sort -u)
[[ -z $pub ]] && pass "Security: no unexpected non-loopback listeners" || wrn "Security: non-loopback listeners" "$(tr '\n' ';' <<<"$pub")"
loose=$(find $SEC -type f -perm /077 2>/dev/null | head -5)
[[ -z $loose ]] && pass "Security: secret files not group/world readable" || fail "Security: secrets" "readable by group/other: $loose" "" "permissions changed by hand" "chmod 600 $SEC/*" "find $SEC -type f -perm /077"
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[[ -z ${failed// } ]] && pass "systemd: no failed units" || wrn "systemd failed units" "$failed"

echo; echo "========================================"
if (( FAILS == 0 )); then echo "OPSORA READY  (warnings: $WARNS)"; else echo "OPSORA NOT READY  (failed: $FAILS, warnings: $WARNS)"; fi
echo "========================================"
exit $(( FAILS > 0 ))
HEALTH
  ln -sfn "$OPSORA_HOME/scripts/opsora-health-check.sh" /usr/local/bin/opsora-health-check
}

# =============================================================================
# STEP: validation
# =============================================================================
step_validation() {
  install_health_check
  local out=$LOG_DIR/validation-$RUN_TS.log
  {
    hr; echo "systemctl --failed"; hr; systemctl --failed --no-pager || true
    hr; echo "journalctl -p err -b (last 40)"; hr; journalctl -p err -b --no-pager -n 40 || true
    hr; echo "ss -tulpn"; hr; ss -tulpn || true
    hr; echo "ufw status verbose"; hr; ufw status verbose 2>/dev/null || true
    hr; echo "enabled OPSORA units"; hr
    systemctl list-unit-files --no-pager 2>/dev/null | grep -E '^(nginx|postgresql|redis|openobserve|alloy|prometheus|alertmanager|keep-|semaphore|pgadmin4|.*_exporter|fail2ban|opsora-backup)' || true
  } >"$out" 2>&1
  log "raw validation output: $out"
  if "$OPSORA_HOME/scripts/opsora-health-check.sh" | tee -a "$out"; then status validation PASS "health check passed (details: $out)"
  else status validation FAIL "health check reported failures (details: $out)"; fi
}

# =============================================================================
# STEP: report  (documentation generated from real state)
# =============================================================================
ui_row() { # NAME DOMAIN PORT UNIT AUTH PURPOSE
  local url="http://127.0.0.1:$3 (SSH tunnel: ssh -L $3:127.0.0.1:$3 user@server)" https=no access=internal
  if [[ -n $2 && -f /etc/letsencrypt/live/$2/fullchain.pem ]]; then url="https://$2"; https=yes; access=external; fi
  printf '| %s | %s | %s | %s | 127.0.0.1:%s | %s | %s | %s |\n' "$1" "$url" "$6" "$5" "$3" "$4" "$https" "$access"
}
step_report() {
  install -d -m 0755 "$DOC_DIR"
  # shellcheck disable=SC1091
  . /etc/os-release
  local keep_on=0; is_true "$ENABLE_KEEP" && keep_on=1

  { echo "# OPSORA component versions"; echo
    echo "| Component | Version | Source | Installation date | Binary path | Configuration path | Systemd service | Notes |"
    echo "|---|---|---|---|---|---|---|---|"
    if [[ -f $VERSIONS_FILE ]]; then sort "$VERSIONS_FILE" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8}'; fi
  } | write_file "$DOC_DIR/VERSIONS.md" 0644

  { echo "# OPSORA ports"; echo
    echo "Public ports are only $SSH_PORT (SSH) and, when domains are configured, 80 and 443. Everything else is loopback."; echo
    echo "| Component | Bind Address | Port | Protocol | Public/Private | Purpose |"; echo "|---|---|---|---|---|---|"
    echo "| OpenSSH | 0.0.0.0 | $SSH_PORT | TCP | Public | administration |"
    if [[ -n $(all_domains) ]]; then
      echo "| Nginx | 0.0.0.0 | 80 | TCP | Public | ACME challenge, redirect to HTTPS |"
      echo "| Nginx | 0.0.0.0 | 443 | TCP | Public | HTTPS reverse proxy for web UIs |"
    fi
    cat <<EOF
| Nginx health | 127.0.0.1 | 8088 | TCP | Private | /nginx-health, /nginx-status |
| PostgreSQL $POSTGRES_VERSION | 127.0.0.1 | $(pg_port 2>/dev/null || echo 5432) | TCP | Private | OPSORA database + pgvector |
| Redis | 127.0.0.1 | 6379 | TCP | Private | cache, queue, sessions |
| OpenObserve | 127.0.0.1 | 5080 | TCP | Private | UI, ingestion and query API |
| OpenObserve | 127.0.0.1 | 5081 | TCP | Private | gRPC |
| Grafana Alloy | 127.0.0.1 | 12345 | TCP | Private | Alloy UI and self metrics |
| Grafana Alloy | $OTLP_BIND | 4317 | TCP | Private | OTLP gRPC receiver |
| Grafana Alloy | $OTLP_BIND | 4318 | TCP | Private | OTLP HTTP receiver |
| Prometheus | 127.0.0.1 | 9090 | TCP | Private | metrics engine, rules |
| Alertmanager | 127.0.0.1 | 9093 | TCP | Private | alert routing |
| Keep API | 127.0.0.1 | 8080 | TCP | Private | alert ingestion, incidents |
| Keep UI | 127.0.0.1 | 3001 | TCP | Private | incident management UI |
| Semaphore UI | 127.0.0.1 | 3000 | TCP | Private | automation UI and API |
| pgAdmin 4 | 127.0.0.1 | 5050 | TCP | Private | PostgreSQL administration UI |
| node_exporter | 127.0.0.1 | 9100 | TCP | Private | host metrics |
| postgres_exporter | 127.0.0.1 | 9187 | TCP | Private | PostgreSQL metrics |
| mysqld_exporter | 127.0.0.1 | 9104 | TCP | Private | MySQL/MariaDB probe endpoint |
| snmp_exporter | 127.0.0.1 | 9116 | TCP | Private | SNMP probe endpoint |
| blackbox_exporter | 127.0.0.1 | 9115 | TCP | Private | synthetic probes |
EOF
  } | write_file "$DOC_DIR/PORTS.md" 0644

  { echo "# OPSORA web UIs"; echo
    echo "URLs below are the ones actually configured on this server. A UI without a certificate is not exposed and is reached through an SSH tunnel."; echo
    echo "| UI | URL | Purpose | Authentication | Backend | Backend service | HTTPS | Access |"; echo "|---|---|---|---|---|---|---|---|"
    ui_row OpenObserve  "$OPENOBSERVE_DOMAIN"  5080 openobserve.service  "OpenObserve login ($OPSORA_ADMIN_EMAIL)" "logs, metrics, traces, dashboards"
    ui_row Prometheus   "$PROMETHEUS_DOMAIN"   9090 prometheus.service   "Nginx basic auth when proxied (user admin)" "queries, targets, rules"
    ui_row Alertmanager "$ALERTMANAGER_DOMAIN" 9093 alertmanager.service "Nginx basic auth when proxied (user admin)" "alerts, silences"
    if (( keep_on )); then ui_row Keep "$KEEP_DOMAIN" 3001 keep-ui.service "Keep DB auth (user admin)" "alerts, incidents, workflows"; fi
    ui_row pgAdmin      "$PGADMIN_DOMAIN"      5050 pgadmin4.service     "pgAdmin login ($OPSORA_ADMIN_EMAIL)" "PostgreSQL administration"
    ui_row Semaphore    "$SEMAPHORE_DOMAIN"    3000 semaphore.service    "Semaphore login (user admin)" "Ansible/Terraform jobs"
    echo; echo "Redis Insight: not installed (no official native headless build). PostgreSQL and Redis themselves are never proxied."
    echo; echo "Passwords: \`sudo cat $SECRETS_DIR/<name>\` with name = openobserve_root, nginx_basic_auth, keep_admin, pgadmin_admin, semaphore_admin."
    if is_true "$RESTRICT_UI_TO_TRUSTED"; then echo; echo "All UIs are additionally restricted to: $TRUSTED_NETWORKS"; fi
  } | write_file "$DOC_DIR/WEB-UI.md" 0644

  write_file "$DOC_DIR/INTEGRATION.md" 0644 <<EOF
# Integration endpoints for the future OPSORA API/Engine

All endpoints are loopback. The OPSORA API/Engine should run on this host (or reach
them through a private network you add to TRUSTED_NETWORKS and bind explicitly).

| System | Endpoint | Auth | Credentials |
|---|---|---|---|
| PostgreSQL + pgvector | 127.0.0.1:$(pg_port 2>/dev/null || echo 5432), db \`$POSTGRES_DB\`, user \`$POSTGRES_USER\` | SCRAM password | $SECRETS_DIR/postgres.env |
| Redis | 127.0.0.1:6379, user \`opsora_app\` | ACL password | $SECRETS_DIR/redis.env |
| OpenObserve | http://127.0.0.1:5080/api/default/... (ingest \`/<stream>/_json\`, search \`/_search\`, OTLP \`/v1/{logs,metrics,traces}\`) | HTTP basic | $SECRETS_DIR/openobserve.env |
| OTLP (via Alloy) | $OTLP_BIND:4317 gRPC, $OTLP_BIND:4318 HTTP | none (network restricted) | - |
| Prometheus | http://127.0.0.1:9090/api/v1/{query,query_range,rules,targets,alerts} | none on loopback | - |
| Alertmanager | http://127.0.0.1:9093/api/v2/{alerts,silences} | none on loopback | - |
| Alertmanager -> OPSORA | set ALERT_WEBHOOK_URL in $CONF_FILE, re-run \`--component alertmanager\` | your API's | - |
| Keep | http://127.0.0.1:8080 (\`/alerts\`, \`/incidents\`, \`/alerts/event/prometheus\`, \`/healthcheck\`) | \`X-API-KEY\` header or basic \`api_key:<key>\` | $SECRETS_DIR/keep_webhook_key (role webhook); create admin keys in the Keep UI |
| Semaphore | http://127.0.0.1:3000/api (\`/auth/login\`, \`/projects\`, \`/project/{id}/tasks\`) | session cookie or API token | $SECRETS_DIR/semaphore_admin |
| HolmesGPT | CLI: \`sudo opsora-holmes ask "..."\`, \`sudo opsora-holmes investigate alertmanager\` | AI key | $SECRETS_DIR/ai.env |
| K8sGPT | CLI: \`sudo opsora-k8sgpt <cluster> analyze --explain --output=json\` | kubeconfig per cluster | /etc/opsora/kubeconfigs/ |
| Ansible | $OPSORA_HOME/ansible (run through Semaphore) | SSH keys stored in Semaphore | - |
| Terraform | $OPSORA_HOME/terraform (run through Semaphore) | provider credentials stored in Semaphore | - |

## Remediation safety model

READ and INVESTIGATE (OpenObserve, Prometheus, HolmesGPT, K8sGPT: read-only) ->
RECOMMEND (AI output only) -> APPROVE (a human, in Semaphore) -> EXECUTE (Semaphore
runs an Ansible playbook or Terraform plan) -> VERIFY (Prometheus/OpenObserve) ->
Keep incident updated/closed. No AI tool on this server holds credentials that can
change infrastructure. Nothing here runs \`terraform apply\` or \`terraform destroy\`.
EOF

  write_file "$DOC_DIR/OPERATIONS.md" 0644 <<EOF
# OPSORA operations

## Daily
    sudo opsora-health-check                      # full health check
    systemctl --failed                            # failed units
    journalctl -u <unit> -n 100 --no-pager        # logs of one service
    journalctl -p err -b                          # errors since boot
    df -hT; free -h                               # disk, memory

## Restart a service
    sudo systemctl restart openobserve | alloy | prometheus | alertmanager
    sudo systemctl restart keep-api keep-ui | semaphore | pgadmin4 | nginx
    sudo systemctl reload prometheus              # after editing rules or file_sd is not needed (auto), rules need reload

## Check
    pg_isready -h 127.0.0.1 -p $(pg_port 2>/dev/null || echo 5432)
    sudo bash -c '. $SECRETS_DIR/redis.env; redis-cli --user \$REDIS_USERNAME --pass \$REDIS_PASSWORD --no-auth-warning ping'
    for p in 9100 9187 9104 9116 9115; do curl -fsS -o /dev/null -w "%{http_code} \$p\n" http://127.0.0.1:\$p/metrics; done
    curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.health) \(.labels.job) \(.scrapeUrl)"'

## Validate configuration before reloading
    sudo nginx -t
    promtool check config /etc/prometheus/prometheus.yml
    amtool check-config /etc/alertmanager/alertmanager.yml
    sudo alloy fmt /etc/alloy/config.alloy >/dev/null

## Add monitoring targets (no restart)
    /etc/prometheus/file_sd/{node,postgres,mysql,snmp,blackbox-http,blackbox-tcp,blackbox-icmp,blackbox-dns,kube-state-metrics}/<name>.yml
    - targets: ['10.0.0.5:9100']
      labels: {host: 'web-1'}

## Backup and restore
    sudo systemctl start opsora-backup.service    # run now
    systemctl list-timers opsora-backup.timer     # schedule (daily 02:30)
    ls $OPSORA_HOME/backups/scheduled/            # retention: $BACKUP_RETENTION_DAYS days
Each backup holds postgresql/globals.sql, postgresql/<db>.dump (custom format),
config.tar.gz and SHA256SUMS. Copy backups off this server; they are not replicated.

Restore test into a scratch database (does not touch live data):
    sudo -u postgres createdb opsora_restore_test
    sudo -u postgres pg_restore -d opsora_restore_test <backup>/postgresql/$POSTGRES_DB.dump
    sudo -u postgres psql -d opsora_restore_test -c '\dt *.*'
Full restore of one database (destructive, do it deliberately and by hand):
    sudo systemctl stop keep-api semaphore        # stop writers first
    sudo -u postgres pg_restore --clean --if-exists -d <db> <backup>/postgresql/<db>.dump
Configuration: extract the needed paths from config.tar.gz (\`tar -xzf config.tar.gz -C / etc/nginx\`).

## Certificates
    sudo certbot certificates
    sudo certbot renew --dry-run
    systemctl list-timers certbot.timer

## Safe reboot and reboot test
    sudo opsora-health-check && sudo systemctl start opsora-backup.service
    sudo reboot
    # after login:
    systemctl --failed; sudo opsora-health-check
All services are enabled units with Restart=on-failure and come back without a login session.

## Re-run / change settings
    sudo nano $CONF_FILE
    sudo bash opsora-install.sh --component <step>     # or --phase <phase>, or no argument for everything
EOF

  write_file "$DOC_DIR/TROUBLESHOOTING.md" 0644 <<EOF
# OPSORA troubleshooting

| Symptom | Diagnose | Likely cause | Safe fix | Verify |
|---|---|---|---|---|
| Service will not start | \`systemctl status U; journalctl -u U -n 50\` | bad config, missing secret file, port in use | fix config, \`systemctl restart U\` | \`systemctl is-active U\` |
| Port conflict | \`ss -ltnp \| grep :PORT\` | another process owns the port | stop or move the other process | \`ss -ltnp\` |
| Nginx 502 | \`tail /var/log/nginx/opsora-*.error.log\`; \`curl -I 127.0.0.1:PORT\` | backend down | restart the backend unit | reload page |
| Nginx 503 on a domain | \`ls /etc/letsencrypt/live\` | no certificate yet, vhost is in ACME-only stage | fix DNS/port 80, \`--component vhosts\` | \`curl -I https://domain\` |
| TLS error / renewal failure | \`certbot certificates; certbot renew --dry-run\` | DNS changed, port 80 blocked | open 80, fix DNS, re-run renew | \`openssl s_client -connect domain:443\` |
| PostgreSQL auth failure | \`journalctl -u postgresql@$POSTGRES_VERSION-main -n 30\` | password drift, pg_hba edited | \`--component postgresql\` resets role passwords from the secret files | \`psql\` with $SECRETS_DIR/postgres.env |
| Redis connection failure | \`redis-cli -h 127.0.0.1 ping\` (expect NOAUTH) | wrong user/password, service down | use $SECRETS_DIR/redis.env, restart redis | authenticated \`ping\` returns PONG |
| OpenObserve ingestion failure | \`journalctl -u openobserve -n 50\`; \`curl 127.0.0.1:5080/healthz\` | wrong credentials, disk full | check $SECRETS_DIR/openobserve.env, free disk | send a test event (see INTEGRATION.md) |
| Alloy pipeline failure | \`journalctl -u alloy -n 50\`; UI at 127.0.0.1:12345 | syntax error, OpenObserve down or password changed | \`alloy fmt\`, \`--component alloy\` | component graph healthy |
| Prometheus target DOWN | Status > Targets, or query \`up == 0\` | exporter stopped, firewall, wrong file_sd entry | restart exporter, fix target file | target turns UP |
| Alertmanager not delivering | \`amtool --alertmanager.url=http://127.0.0.1:9093 alert query\`; journal | receiver URL/auth wrong | \`amtool check-config\`, \`--component alertmanager\` | test alert reaches receiver |
| Keep webhook failure | \`journalctl -u keep-api -n 50\` | API key mismatch, Keep down | \`--component keep\` then \`--component alertmanager\` | POST to /alerts/event/prometheus returns 2xx |
| HolmesGPT AI provider failure | \`sudo opsora-holmes ask "say OK"\` | missing/invalid key, wrong AI_MODEL | edit $SECRETS_DIR/ai.env and $CONF_FILE | command answers |
| K8sGPT kubeconfig failure | \`sudo -u k8sgpt KUBECONFIG=... kubectl get ns\` | expired token, API unreachable | new token, check firewall to API server | \`sudo opsora-k8sgpt <cluster> analyze\` |
| Semaphore Ansible failure | task log in Semaphore; \`journalctl -u semaphore\` | missing SSH key, wrong inventory, host key unknown | fix key store / inventory | re-run the task |
| Terraform provider failure | \`terraform init\` output | no network to registry, version constraint | fix constraint, mirror provider | \`terraform validate\` |
| Disk full | \`df -h; du -xh --max-depth=2 /var/lib \| sort -h \| tail\` | telemetry or backups growing | lower OPENOBSERVE_RETENTION_DAYS / PROMETHEUS_RETENTION / BACKUP_RETENTION_DAYS and re-run | \`df -h\` |
| Memory pressure | \`free -h; systemd-cgtop\` | OpenObserve/Prometheus/PostgreSQL caches | lower ZO_MEMORY_CACHE_MAX_SIZE or shared_buffers, add RAM | \`free -h\` |
EOF

  { echo "# OPSORA installation report"; echo; echo "Generated: $(date -Is) by run $RUN_TS"; echo
    echo "## Server"; echo
    echo "| Item | Value |"; echo "|---|---|"
    echo "| Hostname | $(hostname) |"; echo "| FQDN | $(hostname -f 2>/dev/null || hostname) |"
    echo "| IP addresses | $(ip -br -4 addr 2>/dev/null | awk '$1!="lo"{print $1"="$3}' | tr '\n' ' ') |"
    echo "| OS | $PRETTY_NAME |"; echo "| Kernel | $(uname -r) |"; echo "| Architecture | $ARCH |"
    echo "| CPU cores | $(nproc) |"; echo "| RAM | $(ram_mb) MB |"
    echo "| Root filesystem | $(df -hT / | awk 'NR==2{print $2", "$3" total, "$5" free"}') |"
    echo "| Timezone | $(timedatectl show -p Timezone --value 2>/dev/null) |"
    echo "| Docker/Podman/Kubernetes | $(for r in docker podman containerd k3s kubelet; do have $r && printf '%s ' "$r"; done; echo '(none installed by OPSORA)') |"
    echo; echo "## Component status"; echo
    echo "| Component | Result | When | Detail |"; echo "|---|---|---|---|"
    if [[ -f $STATUS_FILE ]]; then awk -F'\t' '{printf "| %s | %s | %s | %s |\n",$1,$2,$3,$4}' "$STATUS_FILE"; fi
    echo; echo "## Firewall"; echo; echo '```'; ufw status verbose 2>/dev/null || echo "ufw not managed"; echo '```'
    echo; echo "## Listening sockets"; echo; echo '```'; ss -H -ltnp 2>/dev/null | awk '{print $4, $6}' | sort -u; echo '```'
    echo; echo "## Enabled services"; echo; echo '```'
    systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(nginx|postgresql|redis|openobserve|alloy|prometheus|alertmanager|keep-|semaphore|pgadmin4|.*_exporter|fail2ban|ufw|certbot|opsora-backup|systemd-timesyncd)' || true
    echo '```'
    echo; echo "See also: VERSIONS.md, PORTS.md, WEB-UI.md, INTEGRATION.md, OPERATIONS.md, TROUBLESHOOTING.md."
  } | write_file "$DOC_DIR/INSTALLATION-REPORT.md" 0644
  status report PASS "documentation written to $DOC_DIR"
}

# =============================================================================
# Runner
# =============================================================================
ALL_STEPS=(preflight os time security nginx postgresql pgvector redis pgadmin openobserve alloy prometheus alertmanager exporters
           keep holmesgpt k8sgpt openrca ansible terraform semaphore redisinsight vhosts targets backup validation report)
declare -A PHASES=(
  [preflight]="preflight"
  [os]="os time"
  [security]="security"
  [web]="nginx vhosts"
  [database]="postgresql pgvector redis pgadmin"
  [observability]="openobserve alloy prometheus alertmanager exporters keep targets"
  [ai]="holmesgpt k8sgpt openrca"
  [automation]="ansible terraform semaphore"
  [validation]="targets validation report"
  [backup]="backup"
)
usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  echo; echo "Steps: ${ALL_STEPS[*]}"; echo "Phases: ${!PHASES[*]}"
}
run_step() {
  local name=$1 rc
  hr; log "${C_B}STEP: $name${C_0}"
  set +e
  ( set -Eeuo pipefail; "step_$name" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    status "$name" FAIL "step exited with code $rc (see log)"
    warn "step '$name' FAILED - continuing with the remaining steps"
    FAILED_STEPS+=("$name")
  fi
}
main() {
  local mode=all arg="" steps=() s
  while (( $# )); do
    case $1 in
      --phase)     mode=phase; arg=${2:?--phase needs a name}; shift 2 ;;
      --component) mode=component; arg=${2:?--component needs a name}; shift 2 ;;
      --list)      printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"
  mkdir -p "$LOG_DIR" "$STATE_DIR" "$CACHE_DIR"
  exec > >(tee -a "$LOG_DIR/install-$RUN_TS.log") 2>&1
  load_config
  case $mode in
    all)       steps=("${ALL_STEPS[@]}") ;;
    phase)     [[ -n ${PHASES[$arg]:-} ]] || die "unknown phase '$arg' (phases: ${!PHASES[*]})"
               read -r -a steps <<<"${PHASES[$arg]}" ;;
    component) [[ " ${ALL_STEPS[*]} " == *" $arg "* ]] || die "unknown component '$arg' (see --list)"
               steps=("$arg") ;;
  esac
  FAILED_STEPS=()
  log "OPSORA installer run $RUN_TS - steps: ${steps[*]}"
  for s in "${steps[@]}"; do
    run_step "$s"
    if [[ $s == preflight && ${#FAILED_STEPS[@]} -gt 0 ]]; then die "preflight failed - nothing was changed"; fi
  done
  hr; echo "${C_B}OPSORA INSTALL SUMMARY${C_0}"; hr
  if [[ -f $STATUS_FILE ]]; then
    awk -F'\t' -v g="$C_G" -v r="$C_R" -v y="$C_Y" -v n="$C_0" '{c=($2=="PASS")?g:($2=="FAIL")?r:y; printf "%s[%-7s]%s %-13s %s\n",c,$2,n,$1,$4}' "$STATUS_FILE"
  fi
  hr
  echo "Config:   $CONF_FILE"
  echo "Secrets:  $SECRETS_DIR (root only)"
  echo "Docs:     $DOC_DIR"
  echo "Health:   sudo opsora-health-check"
  echo "Log:      $LOG_DIR/install-$RUN_TS.log"
  if (( ${#FAILED_STEPS[@]} )); then echo "${C_R}Failed steps: ${FAILED_STEPS[*]}${C_0}"; fi
  local s2
  for s2 in "${steps[@]}"; do
    if awk -F'\t' -v n="$s2" '$1==n && $2=="FAIL"{f=1} END{exit !f}' "$STATUS_FILE" 2>/dev/null; then exit 1; fi
  done
  return 0
}
if [[ ${OPSORA_SOURCE_ONLY:-0} != 1 ]]; then main "$@"; fi

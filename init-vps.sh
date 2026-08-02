#!/usr/bin/env bash
set -Eeuo pipefail

# VPS first-login initializer.
# Defaults:
#   - run as root
#   - create user "nini"
#   - fetch SSH public keys from https://github.com/telly3e.keys
#   - move SSH to port 22222
#   - disable root login and password login
#   - enable time sync
#   - configure swap and TCP tuning
#   - install UFW and SSHGuard by default
#   - optionally install Caddy with the Cloudflare DNS plugin

DEFAULT_VPS_INIT_BASE_URL="https://raw.githubusercontent.com/telly3e/vps-first-initializer/main"
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && "$SCRIPT_PATH" != "-" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
else
  SCRIPT_DIR="$(pwd -P)"
fi
NEW_USER="nini"
SSH_PORT="22222"
GITHUB_USER="telly3e"
PUBKEY_URL=""
PUBKEY_INLINE=""
SWAP_SIZE="2G"
ENABLE_SWAP="yes"
ENABLE_UFW="yes"
ENABLE_SSHGUARD="yes"
INSTALL_CADDY="ask"
ASSUME_YES="no"
TCP_FORWARDING_MODE="auto"
TPROXY_MODE="off"
CDN_IP_FILE=""
CDN_IP_URL="${VPS_INIT_CDN_IP_URL:-}"
CLOUDFLARE_IPV4_URL="${VPS_INIT_CLOUDFLARE_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CLOUDFLARE_IPV6_URL="${VPS_INIT_CLOUDFLARE_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
CLOUDFLARE_IP_FILE=""
VPS_INIT_BASE_URL="${VPS_INIT_BASE_URL:-$DEFAULT_VPS_INIT_BASE_URL}"

OS_FAMILY=""
INIT_SYSTEM=""
SUDO_GROUP=""
TIME_SYNC_LABEL=""

SYSCTL_FILE="/etc/sysctl.d/99-proxy-vps.conf"
LEGACY_SYSCTL_FILE="/etc/sysctl.d/99-vps-init-tcp.conf"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/99-vps-init-hardening.conf"
BACKUP_DIR="/root/vps-init-backups"
CAN_PROMPT="no"
if [[ -t 0 ]]; then
  CAN_PROMPT="yes"
fi

log() {
  printf '\n[+] %s\n' "$*"
}

warn() {
  printf '\n[!] %s\n' "$*" >&2
}

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

detect_platform() {
  local os_id=""

  if [[ -r /etc/os-release ]]; then
    os_id="$(awk -F= '$1 == "ID" {gsub(/\"/, "", $2); print $2; exit}' /etc/os-release)"
  fi

  if [[ "$os_id" == "alpine" || -e /etc/alpine-release ]]; then
    OS_FAMILY="alpine"
    INIT_SYSTEM="openrc"
    SUDO_GROUP="wheel"
    TIME_SYNC_LABEL="chrony/OpenRC"
  elif [[ "$os_id" == "debian" || "$os_id" == "ubuntu" || -n "$(command -v apt-get 2>/dev/null || true)" ]]; then
    OS_FAMILY="debian"
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
      INIT_SYSTEM="systemd"
    else
      INIT_SYSTEM="sysvinit"
    fi
    SUDO_GROUP="sudo"
    TIME_SYNC_LABEL="systemd-timesyncd"
  else
    die "Unsupported operating system. This script supports Alpine, Debian, and Ubuntu."
  fi
}

enable_alpine_community_repo() {
  [[ "$OS_FAMILY" == "alpine" ]] || return 0
  [[ -f /etc/apk/repositories ]] || die "/etc/apk/repositories not found. Cannot enable Alpine community repository."

  if grep -Eq '/community([[:space:]]|$)' /etc/apk/repositories; then
    return 0
  fi

  if command -v setup-apkrepos >/dev/null 2>&1; then
    setup-apkrepos -c || true
    if grep -Eq '/community([[:space:]]|$)' /etc/apk/repositories; then
      return 0
    fi
  fi

  local main_repo=""
  main_repo="$(awk '!/^[[:space:]]*#/ && /\/main([[:space:]]|$)/ {sub(/[[:space:]]+$/, "", $1); sub(/\/main$/, "", $1); print $1; exit}' /etc/apk/repositories)"
  [[ -n "$main_repo" ]] || die "Alpine community repository is required, but no main repository was found in /etc/apk/repositories."

  backup_file /etc/apk/repositories
  printf '%s/community\n' "$main_repo" >> /etc/apk/repositories
}

run_package_update() {
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    apk update
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
  fi
}

usage() {
  cat <<EOF
Usage: bash init-vps.sh [options]

Options:
  --user USER              Linux sudo user to create, default: nini
  --ssh-port PORT          SSH port after hardening, default: 22222
  --github-user USER       Fetch keys from https://github.com/USER.keys, default: telly3e
  --pubkey-url URL         Fetch SSH public keys from custom URL
  --pubkey KEY             Add one inline SSH public key
  --swap-size SIZE         Swap file size, default: 2G
  --no-swap                Skip swap setup
  --no-ufw                 Skip UFW installation and configuration
  --no-sshguard            Skip SSHGuard installation and service enablement
  --install-caddy          Install Caddy and github.com/caddy-dns/cloudflare
  --no-caddy               Skip Caddy without prompt
  --cdn-ip-file FILE       Additional CDN IP list for Caddy 80/443, default: ./cdn-ip.txt
  --cdn-ip-url URL         Download additional CDN IP list when local file is absent
                           Cloudflare's official IPv4/IPv6 ranges are fetched automatically
  --yes                    Non-interactive mode; answers yes to safe prompts
  -h, --help               Show this help

Examples:
  bash init-vps.sh
  curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash
  apk add --no-cache bash curl && bash init-vps.sh --yes --no-caddy
  bash init-vps.sh --yes --install-caddy
  bash init-vps.sh --github-user telly3e --ssh-port 22222 --no-caddy
  bash init-vps.sh --install-caddy --cdn-ip-url https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/cdn-ip.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      NEW_USER="${2:?missing user}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:?missing port}"
      shift 2
      ;;
    --github-user)
      GITHUB_USER="${2:?missing GitHub user}"
      shift 2
      ;;
    --pubkey-url)
      PUBKEY_URL="${2:?missing public key URL}"
      shift 2
      ;;
    --pubkey)
      if [[ -n "$PUBKEY_INLINE" ]]; then
        PUBKEY_INLINE="${PUBKEY_INLINE}"$'\n'"${2:?missing public key}"
      else
        PUBKEY_INLINE="${2:?missing public key}"
      fi
      shift 2
      ;;
    --swap-size)
      SWAP_SIZE="${2:?missing swap size}"
      shift 2
      ;;
    --no-swap)
      ENABLE_SWAP="no"
      shift
      ;;
    --no-ufw)
      ENABLE_UFW="no"
      shift
      ;;
    --no-sshguard)
      ENABLE_SSHGUARD="no"
      shift
      ;;
    --install-caddy)
      INSTALL_CADDY="yes"
      shift
      ;;
    --no-caddy)
      INSTALL_CADDY="no"
      shift
      ;;
    --cdn-ip-file)
      CDN_IP_FILE="${2:?missing CDN IP file}"
      shift 2
      ;;
    --cdn-ip-url)
      CDN_IP_URL="${2:?missing CDN IP URL}"
      shift 2
      ;;
    --forward)
      TCP_FORWARDING_MODE="on"
      shift
      ;;
    --no-forward)
      TCP_FORWARDING_MODE="off"
      shift
      ;;
    --auto-forward)
      TCP_FORWARDING_MODE="auto"
      shift
      ;;
    --tproxy)
      TPROXY_MODE="on"
      shift
      ;;
    --yes)
      ASSUME_YES="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown option: $1"
      ;;
  esac
done

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Please run this script as root."
}

validate_inputs() {
  [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid Linux user name: $NEW_USER"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "Invalid SSH port: $SSH_PORT"
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Invalid SSH port: $SSH_PORT"

  if [[ -z "$PUBKEY_URL" && -z "$PUBKEY_INLINE" ]]; then
    PUBKEY_URL="https://github.com/${GITHUB_USER}.keys"
  fi
}

confirm_plan() {
  cat <<EOF

This script will initialize the VPS with:
  User                  : ${NEW_USER}
  Passwordless sudo     : enabled for ${NEW_USER}
  SSH port              : ${SSH_PORT}
  Public key source     : ${PUBKEY_URL:-inline key}
  Root SSH login        : disabled
  Password SSH login    : disabled
  Platform              : ${OS_FAMILY} (${INIT_SYSTEM})
  Time sync             : ${TIME_SYNC_LABEL}
  TCP tuning            : proxy VPS static sysctl profile
  Swap                  : ${ENABLE_SWAP}, size=${SWAP_SIZE}
  UFW                   : ${ENABLE_UFW}
  SSHGuard              : ${ENABLE_SSHGUARD}
  Caddy                 : ${INSTALL_CADDY}
  Caddy CDN IP file     : ${CDN_IP_FILE:-${SCRIPT_DIR}/cdn-ip.txt}
  Caddy CDN IP URL      : ${CDN_IP_URL:-${VPS_INIT_BASE_URL:+${VPS_INIT_BASE_URL%/}/cdn-ip.txt}}

EOF

  if [[ "$ASSUME_YES" != "yes" ]]; then
    if [[ "$CAN_PROMPT" != "yes" ]]; then
      warn "Non-interactive stdin detected; continuing with default choices. Pass --yes to silence this warning."
      return 0
    fi
    read -r -p "Continue? Type YES to proceed: " answer
    [[ "$answer" == "YES" ]] || die "Cancelled."
  fi
}

run_apt_update() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
}

install_base_packages() {
  log "Installing base packages"

  if [[ "$OS_FAMILY" == "alpine" ]]; then
    enable_alpine_community_repo

    run_package_update
    local packages=(
      bash
      ca-certificates
      chrony
      chrony-openrc
      curl
      e2fsprogs
      e2fsprogs-extra
      findmnt
      iproute2
      iputils-ping
      musl-utils
      openssh-server
      openssh-server-common-openrc
      procps-ng
      sudo
      util-linux-misc
    )

    if [[ "$ENABLE_UFW" == "yes" ]]; then
      packages+=(ip6tables ufw)
    fi

    if [[ "$ENABLE_SSHGUARD" == "yes" ]]; then
      packages+=(sshguard sshguard-openrc)
    fi

    apk add --no-cache "${packages[@]}"
    return 0
  fi

  run_package_update
  local packages=(
    ca-certificates
    curl
    gnupg
    iproute2
    iputils-ping
    openssh-server
    sudo
    e2fsprogs
    util-linux
  )

  if [[ "$ENABLE_UFW" == "yes" ]]; then
    packages+=(ufw)
  fi

  if [[ "$ENABLE_SSHGUARD" == "yes" ]]; then
    packages+=(sshguard)
  fi

  apt-get install -y "${packages[@]}"
}

backup_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$file" "${BACKUP_DIR}/$(basename "$file").bak.$(date +%F-%H%M%S)"
}

ensure_user() {
  log "Creating sudo user: ${NEW_USER}"

  if ! getent passwd "$NEW_USER" >/dev/null; then
    if [[ "$OS_FAMILY" == "alpine" ]]; then
      adduser -D -s /bin/ash "$NEW_USER"
    else
      adduser --disabled-password --gecos "" "$NEW_USER"
    fi
  fi

  if [[ "$OS_FAMILY" == "alpine" ]]; then
    adduser "$NEW_USER" "$SUDO_GROUP" >/dev/null 2>&1 || true
    passwd -u "$NEW_USER" >/dev/null 2>&1 || warn "Could not unlock ${NEW_USER}; Alpine may reject SSH key login for a locked account."
  else
    usermod -aG "$SUDO_GROUP" "$NEW_USER"
  fi

  local sudoers_file="/etc/sudoers.d/90-${NEW_USER}-nopasswd"
  install -d -m 0750 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$sudoers_file"
  chmod 0440 "$sudoers_file"
  visudo -cf "$sudoers_file" >/dev/null
}

valid_public_keys() {
  awk '
    /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]/ {
      print
    }
  '
}

install_public_keys() {
  log "Installing SSH public keys for ${NEW_USER}"

  local home group
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || die "Home directory for ${NEW_USER} not found."
  group="$(id -gn "$NEW_USER")"
  [[ -n "$group" ]] || die "Primary group for ${NEW_USER} not found."

  local ssh_dir="${home}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"
  local tmp_keys
  tmp_keys="$(mktemp)"

  if [[ -n "$PUBKEY_URL" ]]; then
    curl -fsSL "$PUBKEY_URL" | valid_public_keys > "$tmp_keys"
  else
    printf '%s\n' "$PUBKEY_INLINE" | valid_public_keys > "$tmp_keys"
  fi

  [[ -s "$tmp_keys" ]] || die "No valid SSH public key found from ${PUBKEY_URL:-inline key}."

  install -d -m 0700 -o "$NEW_USER" -g "$group" "$ssh_dir"
  touch "$auth_keys"
  chmod 0600 "$auth_keys"

  cat "$tmp_keys" >> "$auth_keys"
  awk '!seen[$0]++' "$auth_keys" > "${auth_keys}.tmp"
  mv "${auth_keys}.tmp" "$auth_keys"
  chown -R "$NEW_USER:$group" "$ssh_dir"
  chmod 0700 "$ssh_dir"
  chmod 0600 "$auth_keys"
  rm -f "$tmp_keys"

  [[ -s "$auth_keys" ]] || die "${auth_keys} is empty; refusing to harden SSH."
}

detect_sshd_service() {
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    if [[ -x /etc/init.d/sshd ]]; then
      echo "sshd"
    elif [[ -x /etc/init.d/ssh ]]; then
      echo "ssh"
    else
      echo ""
    fi
  elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
  else
    echo ""
  fi
}

ensure_sshd_include() {
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
}

comment_managed_sshd_directives() {
  local file="$1"
  sed -i -E \
    -e 's/^([[:space:]]*)Port[[:space:]]+/\1# Managed by init-vps: Port /' \
    -e 's/^([[:space:]]*)PubkeyAuthentication[[:space:]]+/\1# Managed by init-vps: PubkeyAuthentication /' \
    -e 's/^([[:space:]]*)PasswordAuthentication[[:space:]]+/\1# Managed by init-vps: PasswordAuthentication /' \
    -e 's/^([[:space:]]*)KbdInteractiveAuthentication[[:space:]]+/\1# Managed by init-vps: KbdInteractiveAuthentication /' \
    -e 's/^([[:space:]]*)ChallengeResponseAuthentication[[:space:]]+/\1# Managed by init-vps: ChallengeResponseAuthentication /' \
    -e 's/^([[:space:]]*)UsePAM[[:space:]]+/\1# Managed by init-vps: UsePAM /' \
    -e 's/^([[:space:]]*)PermitRootLogin[[:space:]]+/\1# Managed by init-vps: PermitRootLogin /' \
    -e 's/^([[:space:]]*)PermitEmptyPasswords[[:space:]]+/\1# Managed by init-vps: PermitEmptyPasswords /' \
    "$file"
}

comment_existing_sshd_directives() {
  log "Disabling conflicting SSH directives"

  local file
  backup_file /etc/ssh/sshd_config
  comment_managed_sshd_directives /etc/ssh/sshd_config

  if [[ -d "$SSHD_DROPIN_DIR" ]]; then
    while IFS= read -r -d '' file; do
      [[ "$file" == "$SSHD_DROPIN_FILE" ]] && continue
      backup_file "$file"
      comment_managed_sshd_directives "$file"
    done < <(find "$SSHD_DROPIN_DIR" -maxdepth 1 -type f -name '*.conf' -print0)
  fi
}

write_sshd_hardening() {
  log "Writing SSH hardening config"

  local use_pam_line
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    use_pam_line="# PAM is intentionally disabled; Alpine's default OpenSSH server has no PAM support"
  else
    use_pam_line="UsePAM yes"
  fi

  install -d -m 0755 "$SSHD_DROPIN_DIR"
  backup_file "$SSHD_DROPIN_FILE"

  cat > "$SSHD_DROPIN_FILE" <<EOF
# Generated by init-vps.sh
Port ${SSH_PORT}

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PermitEmptyPasswords no

${use_pam_line}
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

open_firewall_port() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    log "Allowing ${port}/tcp in ufw"
    ufw allow "${port}/tcp" >/dev/null || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "Allowing ${port}/tcp in firewalld"
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
}

restart_sshd() {
  log "Testing and restarting SSH"
  sshd -t

  local service=""
  service="$(detect_sshd_service)"

  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    [[ -n "$service" ]] || die "Could not find an OpenRC SSH service script."
    rc-update add "$service" default >/dev/null 2>&1 || true
    rc-service "$service" restart || rc-service "$service" start || die "Could not restart SSH service: ${service}."
  elif [[ "$INIT_SYSTEM" == "systemd" && -n "$service" ]]; then
    systemctl restart "$service"
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || die "Could not restart SSH service."
  fi
}

harden_ssh() {
  [[ -f /etc/ssh/sshd_config ]] || die "/etc/ssh/sshd_config not found."
  command -v sshd >/dev/null 2>&1 || die "sshd command not found."

  backup_file /etc/ssh/sshd_config
  ensure_sshd_include
  comment_existing_sshd_directives
  write_sshd_hardening
  open_firewall_port "$SSH_PORT"
  restart_sshd
}

enable_time_sync() {
  log "Configuring time sync"

  if [[ "$OS_FAMILY" == "alpine" ]]; then
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd restart || rc-service chronyd start || warn "Could not start chronyd automatically."
    chronyc tracking 2>/dev/null || true
    return 0
  fi

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
      run_package_update
      apt-get install -y systemd-timesyncd
    fi

    systemctl enable --now systemd-timesyncd || true
    timedatectl set-ntp true || true
    timedatectl status || true
  else
    run_package_update
    apt-get install -y chrony
    service chrony restart 2>/dev/null || service chrony start 2>/dev/null || warn "Could not start chrony automatically."
  fi
}

swap_size_to_mb() {
  local value="$1"
  case "$value" in
    *G|*g)
      echo $(( ${value%[Gg]} * 1024 ))
      ;;
    *M|*m)
      echo "${value%[Mm]}"
      ;;
    *)
      echo $(( value / 1024 / 1024 ))
      ;;
  esac
}

configure_swap() {
  [[ "$ENABLE_SWAP" == "yes" ]] || return 0
  log "Configuring swap file: ${SWAP_SIZE}"

  local fs_type swap_mb
  fs_type="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
  swap_mb="$(swap_size_to_mb "$SWAP_SIZE")"

  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile

  if [[ "$fs_type" == "btrfs" ]]; then
    truncate -s 0 /swapfile
    chattr +C /swapfile || warn "Could not set chattr +C on /swapfile; btrfs swap may fail."
    dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb"
  else
    fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb"
  fi

  chmod 0600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if grep -qE '^[^#[:space:]]+[[:space:]]+none[[:space:]]+swap[[:space:]]' /etc/fstab; then
    sed -i -E '/[[:space:]]+none[[:space:]]+swap[[:space:]]/d' /etc/fstab
  fi
  printf '/swapfile none swap sw 0 0\n' >> /etc/fstab

  swapon --show || true
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_mem_mb() {
  awk '/MemTotal/ {printf "%d\n", $2 / 1024}' /proc/meminfo
}

get_cpu_count() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1"
}

get_virt_type() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null || echo "none"
  elif grep -qa docker /proc/1/cgroup 2>/dev/null; then
    echo "docker"
  elif grep -qa lxc /proc/1/cgroup 2>/dev/null; then
    echo "lxc"
  elif [[ -d /proc/vz && ! -d /proc/bc ]]; then
    echo "openvz"
  else
    echo "unknown"
  fi
}

get_default_iface_v4() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

get_iface_speed_mbps() {
  local iface="$1"
  local speed=""

  if [[ -n "$iface" && -r "/sys/class/net/$iface/speed" ]]; then
    speed="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then
      echo "$speed"
      return
    fi
  fi

  echo "0"
}

has_ipv6_default_route() {
  ip -6 route show default 2>/dev/null | grep -q '^default' && echo "1" || echo "0"
}

has_tun_device() {
  [[ -c /dev/net/tun ]] && echo "1" || echo "0"
}

detect_proxy_like_processes() {
  local names="xray|v2ray|sing-box|hysteria|tuic|trojan|naive|brook|wireguard|wg-quick|tailscale|zerotier|openvpn"
  ps -eo comm,args 2>/dev/null | grep -Eiq "$names" && echo "1" || echo "0"
}

has_tproxy_rules() {
  local hit=0
  command_exists lsmod && lsmod 2>/dev/null | grep -Eq 'xt_TPROXY|nf_tproxy|nft_tproxy' && hit=1
  command_exists iptables && iptables-save 2>/dev/null | grep -qi 'TPROXY' && hit=1
  command_exists nft && nft list ruleset 2>/dev/null | grep -qi 'tproxy' && hit=1
  echo "$hit"
}

ping_avg_ms() {
  local target="$1"
  local output avg

  output="$(ping -c 3 -W 2 "$target" 2>/dev/null)" || return 1
  avg="$(printf '%s\n' "$output" | awk -F'/' '/rtt|round-trip/ {print $5}')"
  [[ -n "$avg" ]] || return 1
  printf '%.0f\n' "$avg"
}

pick_best_latency() {
  local targets=("www.189.cn" "baidu.com" "taobao.com" "163.com")
  local target ms best_ms=""

  for target in "${targets[@]}"; do
    if ms="$(ping_avg_ms "$target")"; then
      if [[ -z "$best_ms" || "$ms" -lt "$best_ms" ]]; then
        best_ms="$ms"
      fi
    fi
  done

  echo "${best_ms:-0}"
}

choose_buffer_bytes() {
  local latency_ms="$1"
  local mem_mb="$2"
  local speed_mbps="$3"
  local virt="$4"

  case "$virt" in
    openvz|docker|lxc|podman|container)
      [[ "$mem_mb" -lt 1024 ]] && echo "16777216" || echo "33554432"
      return
      ;;
  esac

  if [[ "$mem_mb" -lt 768 ]]; then
    echo "16777216"
  elif [[ "$speed_mbps" -gt 0 && "$speed_mbps" -le 100 ]]; then
    [[ "$latency_ms" -gt 180 && "$mem_mb" -ge 1024 ]] && echo "33554432" || echo "16777216"
  elif [[ "$latency_ms" -le 0 ]]; then
    [[ "$mem_mb" -ge 1024 ]] && echo "33554432" || echo "16777216"
  elif [[ "$latency_ms" -le 80 ]]; then
    [[ "$mem_mb" -ge 1024 ]] && echo "33554432" || echo "16777216"
  elif [[ "$latency_ms" -le 180 ]]; then
    [[ "$mem_mb" -ge 1024 ]] && echo "67108864" || echo "33554432"
  elif [[ "$mem_mb" -ge 2048 && "$speed_mbps" -ge 1000 ]]; then
    echo "134217728"
  else
    echo "67108864"
  fi
}

choose_congestion() {
  modprobe tcp_bbr 2>/dev/null || true
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "bbr"
  else
    cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "cubic"
  fi
}

choose_forwarding() {
  local has_tun="$1"
  local proxy_like="$2"
  local tproxy_like="$3"

  case "$TCP_FORWARDING_MODE" in
    on)
      echo "1"
      ;;
    off)
      echo "0"
      ;;
    auto)
      if [[ "$has_tun" -eq 1 || "$proxy_like" -eq 1 || "$tproxy_like" -eq 1 ]]; then
        echo "1"
      else
        echo "0"
      fi
      ;;
  esac
}

configure_tcp_tuning() {
  log "Configuring TCP tuning"
  if [[ -f "$LEGACY_SYSCTL_FILE" && "$LEGACY_SYSCTL_FILE" != "$SYSCTL_FILE" ]]; then
    backup_file "$LEGACY_SYSCTL_FILE"
    rm -f "$LEGACY_SYSCTL_FILE"
  fi

  backup_file "$SYSCTL_FILE"
  cat > "$SYSCTL_FILE" <<EOF
# Generated by init-vps.sh
# Proxy VPS TCP sysctl tuning

# 1. Basic file descriptor limits for high concurrency.
fs.file-max = 6815744
fs.nr_open = 6815744

# 2. Network queue and connection tuning.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 65536

# 3. BBR and congestion control.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# 4. TCP window and buffer tuning for high bandwidth / long-haul links.
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 5. IPv6 enablement and forwarding.
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.route.max_size = 1048576
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

# 6. Timestamps and connection recycling.
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0

# 7. Security and forwarding.
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0

# 8. Auxiliary tuning.
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
EOF

  if [[ "$OS_FAMILY" == "alpine" ]]; then
    if ! sysctl -p "$SYSCTL_FILE"; then
      warn "sysctl -p failed. Some VPS kernels/providers may reject specific values. Config was written to ${SYSCTL_FILE}."
    fi
    rc-update add sysctl boot >/dev/null 2>&1 || warn "Could not add the sysctl service to the Alpine boot runlevel."
  elif ! sysctl --system; then
    warn "sysctl --system failed. Some VPS kernels/providers may reject specific values. Config was written to ${SYSCTL_FILE}."
  fi

  cat > /root/vps-init-tcp-report.txt <<EOF
profile=proxy-vps-static
config_file=${SYSCTL_FILE}
ip_forward=1
ipv6_forwarding=1
tcp_congestion_control=bbr
default_qdisc=fq
tcp_buffer_max=67108864
EOF
}

prompt_caddy() {
  [[ "$INSTALL_CADDY" != "ask" ]] && return 0

  if [[ "$ASSUME_YES" == "yes" ]]; then
    INSTALL_CADDY="no"
    return 0
  fi

  if [[ "$CAN_PROMPT" != "yes" ]]; then
    INSTALL_CADDY="no"
    warn "Non-interactive stdin detected; skipping Caddy prompt. Pass --install-caddy to install Caddy."
    return 0
  fi

  read -r -p "Install Caddy with Cloudflare DNS plugin? [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      INSTALL_CADDY="yes"
      ;;
    *)
      INSTALL_CADDY="no"
      ;;
  esac
}

install_caddy_cloudflare() {
  [[ "$INSTALL_CADDY" == "yes" ]] || return 0
  log "Installing Caddy with Cloudflare DNS plugin"

  if [[ "$OS_FAMILY" == "alpine" ]]; then
    enable_alpine_community_repo
    run_package_update
    apk add --no-cache caddy caddy-openrc

    if ! caddy help add-package >/dev/null 2>&1; then
      die "The Alpine Caddy package does not support 'caddy add-package'. Use a newer Alpine release or install a custom Caddy build with the Cloudflare module."
    fi

    caddy add-package github.com/caddy-dns/cloudflare
    rc-update add caddy default >/dev/null 2>&1 || true
    rc-service caddy restart || rc-service caddy start || die "Could not start Caddy through OpenRC."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

  install -d -m 0755 /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list

  run_apt_update
  apt-get install -y caddy
  caddy add-package github.com/caddy-dns/cloudflare
  systemctl restart caddy
}

resolve_cdn_ip_file() {
  if [[ -n "$CDN_IP_FILE" ]]; then
    [[ -f "$CDN_IP_FILE" ]] && return 0
    return 1
  fi

  if [[ -f "${SCRIPT_DIR}/cdn-ip.txt" ]]; then
    CDN_IP_FILE="${SCRIPT_DIR}/cdn-ip.txt"
    return 0
  fi

  if [[ -f "./cdn-ip.txt" ]]; then
    CDN_IP_FILE="./cdn-ip.txt"
    return 0
  fi

  local url=""
  if [[ -n "$CDN_IP_URL" ]]; then
    url="$CDN_IP_URL"
  elif [[ -n "$VPS_INIT_BASE_URL" ]]; then
    url="${VPS_INIT_BASE_URL%/}/cdn-ip.txt"
  fi

  if [[ -n "$url" ]]; then
    CDN_IP_FILE="$(mktemp)"
    if curl -fsSL "$url" -o "$CDN_IP_FILE"; then
      return 0
    fi
    rm -f "$CDN_IP_FILE"
    CDN_IP_FILE=""
    return 1
  fi

  return 1
}

valid_cdn_source() {
  local source="$1"
  [[ "$source" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

validate_cdn_ip_file() {
  local file="$1"
  local raw source count=0

  [[ -s "$file" ]] || return 1

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    raw="${raw%%#*}"
    read -r source _ <<< "$raw"
    [[ -n "${source:-}" ]] || continue

    valid_cdn_source "$source" || return 1
    count=$((count + 1))
  done < "$file"

  [[ "$count" -gt 0 ]]
}

fetch_cloudflare_ip_ranges() {
  local ipv4_file ipv6_file

  ipv4_file="$(mktemp)"
  ipv6_file="$(mktemp)"

  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    "$CLOUDFLARE_IPV4_URL" -o "$ipv4_file" || \
    ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    "$CLOUDFLARE_IPV6_URL" -o "$ipv6_file"; then
    rm -f "$ipv4_file" "$ipv6_file"
    return 1
  fi

  if ! validate_cdn_ip_file "$ipv4_file" || ! validate_cdn_ip_file "$ipv6_file"; then
    rm -f "$ipv4_file" "$ipv6_file"
    return 1
  fi

  CLOUDFLARE_IP_FILE="$(mktemp)"
  {
    printf '%s\n' '# Cloudflare IPv4 (official)' '# Source: https://www.cloudflare.com/ips-v4'
    cat "$ipv4_file"
    printf '%s\n' '' '# Cloudflare IPv6 (official)' '# Source: https://www.cloudflare.com/ips-v6'
    cat "$ipv6_file"
  } > "$CLOUDFLARE_IP_FILE"

  rm -f "$ipv4_file" "$ipv6_file"
}

apply_caddy_cdn_ufw_rules() {
  [[ "$INSTALL_CADDY" == "yes" ]] || return 0

  if ! resolve_cdn_ip_file; then
    if [[ -n "$CDN_IP_FILE" ]]; then
      warn "Configured CDN IP list was not found: ${CDN_IP_FILE}. Ignoring it."
      CDN_IP_FILE=""
    fi
  fi

  if ! fetch_cloudflare_ip_ranges; then
    warn "Could not download Cloudflare's official IP ranges; continuing with the custom/static CDN list only."
  fi

  local rules_file
  rules_file="$(mktemp)"
  {
    [[ -z "$CLOUDFLARE_IP_FILE" ]] || cat "$CLOUDFLARE_IP_FILE"
    [[ -z "$CDN_IP_FILE" ]] || cat "$CDN_IP_FILE"
  } | awk '
    {
      sub(/\r$/, "", $0)
      if ($1 == "" || $1 ~ /^#/) next
      if (!seen[$1]++) print $1
    }
  ' > "$rules_file"

  if [[ ! -s "$rules_file" ]]; then
    warn "Caddy is installed, but no CDN IP ranges were available. UFW will not open 80/443."
    warn "Provide cdn-ip.txt beside init-vps.sh, pass --cdn-ip-file FILE, or pass --cdn-ip-url URL."
    rm -f "$rules_file"
    [[ -z "$CLOUDFLARE_IP_FILE" ]] || rm -f "$CLOUDFLARE_IP_FILE"
    CLOUDFLARE_IP_FILE=""
    return 0
  fi

  log "Applying Caddy CDN UFW rules from official Cloudflare ranges and ${CDN_IP_FILE:-custom list: none}"

  local raw source count=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%%#*}"
    read -r source _ <<< "$raw"
    [[ -n "${source:-}" ]] || continue

    if ! valid_cdn_source "$source"; then
      warn "Skipping invalid CDN source entry: ${source}"
      continue
    fi

    if ufw allow from "$source" to any port 80 proto tcp comment 'allow caddy cdn http' &&
      ufw allow from "$source" to any port 443 proto tcp comment 'allow caddy cdn https'; then
      count=$((count + 1))
    else
      warn "Failed to apply UFW rules for CDN source: ${source}"
    fi
  done < "$rules_file"

  [[ "$count" -gt 0 ]] || warn "No valid CDN source entries found in the merged CDN list."
  rm -f "$rules_file"
  [[ -z "$CLOUDFLARE_IP_FILE" ]] || rm -f "$CLOUDFLARE_IP_FILE"
  CLOUDFLARE_IP_FILE=""
}

configure_ufw() {
  [[ "$ENABLE_UFW" == "yes" ]] || return 0
  log "Configuring UFW"

  command -v ufw >/dev/null 2>&1 || die "ufw command not found after installation."

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'allow ssh'

  apply_caddy_cdn_ufw_rules

  ufw --force enable
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add ufw default >/dev/null 2>&1 || true
  fi
  ufw status verbose || true
}

enable_sshguard() {
  [[ "$ENABLE_SSHGUARD" == "yes" ]] || return 0
  log "Enabling SSHGuard"

  command -v sshguard >/dev/null 2>&1 || die "sshguard command not found after installation."

  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    if [[ -x /etc/init.d/sshguard ]]; then
      rc-update add sshguard default >/dev/null 2>&1 || true
      rc-service sshguard restart || rc-service sshguard start || warn "Could not start sshguard automatically."
    else
      warn "sshguard is installed but its OpenRC service script was not found."
    fi
  elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^sshguard\.service'; then
    systemctl enable --now sshguard
    systemctl restart sshguard || true
  else
    service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || warn "Could not start sshguard automatically."
  fi
}

show_final_notes() {
  cat <<EOF

Done.

Important:
  1. Keep this current SSH session open.
  2. Open a second terminal and test:
       ssh -p ${SSH_PORT} ${NEW_USER}@YOUR_SERVER_IP
  3. Only close the root session after the new key login works.

Files changed:
  Platform      : ${OS_FAMILY} (${INIT_SYSTEM})
  SSH hardening : ${SSHD_DROPIN_FILE}
  TCP tuning    : ${SYSCTL_FILE}
  TCP report    : /root/vps-init-tcp-report.txt
  UFW           : ${ENABLE_UFW}
  SSHGuard      : ${ENABLE_SSHGUARD}
  Backups       : ${BACKUP_DIR}

EOF
}

main() {
  need_root
  detect_platform
  validate_inputs
  prompt_caddy
  confirm_plan

  install_base_packages
  ensure_user
  install_public_keys
  enable_time_sync
  configure_swap
  configure_tcp_tuning
  install_caddy_cloudflare
  harden_ssh
  configure_ufw
  enable_sshguard
  show_final_notes
}

main "$@"

#!/usr/bin/env bash
# final-3xui-debian13-1c1g-vps-tuning-v5.sh
# Target: Debian 13 (Trixie), Linux 6.12+, 1 vCPU, about 1 GiB RAM.
# Workload: 3x-UI/Xray proxy, including TCP-based transports and Hysteria2/QUIC.
# Policy: conservative, latency-first, reversible tuning; no third-party kernel.
#
# This script does NOT change IP addresses, IPv4/IPv6 enablement, routes,
# policy rules, interface MTU, DNS, firewall rules, 3x-UI/Xray routing,
# certificates, proxy ports, or provider-specific network configuration.
#
# Based on the original Debian 12 version, adapted for Debian 13.
# Evidence checked 2026-07-30 (kernel 6.12+).
# - https://docs.kernel.org/networking/ip-sysctl.html
# - https://docs.kernel.org/admin-guide/sysctl/net.html
# - https://v2.hysteria.network/docs/advanced/Performance/
# - https://manpages.debian.org/bookworm/systemd/sysctl.d.5.en.html
# - https://manpages.debian.org/bookworm/systemd/systemd.exec.5.en.html

set -Eeuo pipefail

ACTION="${1:-apply}"
SYSCTL_FILE="/etc/sysctl.d/zzzz-3xui-vps.conf"
MODULES_FILE="/etc/modules-load.d/99-3xui-vps.conf"
FQ_HELPER="/usr/local/sbin/3xui-apply-fq.sh"
FQ_SERVICE="/etc/systemd/system/3xui-fq.service"
JOURNAL_DIR="/etc/systemd/journald.conf.d"
JOURNAL_FILE="${JOURNAL_DIR}/99-3xui-vps.conf"
STATE_DIR="/var/lib/3xui-vps-tuning"
STATE_FILE="${STATE_DIR}/original-state.env"
SWAP_MARKER="${STATE_DIR}/swap-created"
SWAP_FILE="${SWAP_FILE:-/swapfile-3xui}"
SWAP_MB="${SWAP_MB:-1024}"
ENABLE_SWAP="${ENABLE_SWAP:-1}"
NOFILE_LIMIT="${NOFILE_LIMIT:-262144}"
AUTO_INSTALL_TOOLS="${AUTO_INSTALL_TOOLS:-1}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-0}"
ALLOW_PROFILE_CONFLICT_ROLLBACK="${ALLOW_PROFILE_CONFLICT_ROLLBACK:-0}"
PURGE_CREATED_SWAP="${PURGE_CREATED_SWAP:-0}"
TS="$(date +%Y%m%d_%H%M%S)"

PROFILE_SYSCTL_KEYS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.core.netdev_max_backlog
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_keepalive_time
  net.ipv4.tcp_keepalive_intvl
  net.ipv4.tcp_keepalive_probes
  vm.swappiness
)

STATE_SYSCTL_KEYS=(
  "${PROFILE_SYSCTL_KEYS[@]}"
  net.ipv4.ip_local_port_range
)

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { printf '[x] %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "Run as root: sudo bash $0 ${ACTION}"
}

check_supported_os() {
  [ -r /etc/os-release ] || fail "/etc/os-release is unavailable"

  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-}" = "13" ]; then
    return 0
  fi

  if [ "$ALLOW_UNSUPPORTED_OS" = "1" ]; then
    warn "Unsupported OS override enabled: ${PRETTY_NAME:-unknown}"
    return 0
  fi

  fail "This profile is only for Debian 13. Set ALLOW_UNSUPPORTED_OS=1 only after manual review."
}

check_sibling_profile_conflicts() {
  local sibling
  for sibling in \
    /etc/sysctl.d/zzzz-3xui-debian12-1c1g-v5.conf \
    /etc/sysctl.d/99-zz-3xui-proxy.conf; do
    if [ -e "$sibling" ] || [ -L "$sibling" ]; then
      if [ "$ACTION" = "rollback" ] && [ "$ALLOW_PROFILE_CONFLICT_ROLLBACK" = "1" ]; then
        warn "Conflict-recovery override: another profile exists at $sibling"
        warn "After this rollback, reapply and verify the profile that must remain active."
        continue
      fi
      if [ "$ACTION" = "rollback" ]; then
        fail "Both profiles appear installed. Choose the one to remove, rerun its rollback with ALLOW_PROFILE_CONFLICT_ROLLBACK=1, then reapply the remaining profile."
      fi
      fail "Detected another 3x-UI tuning profile at $sibling. Use that profile's script to roll it back first."
    fi
  done
}

backup_file() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    cp -a -- "$path" "${path}.bak_${TS}" || return 1
    info "Backed up: ${path}.bak_${TS}"
  fi
}

missing_commands() {
  local cmd
  for cmd in sysctl ip tc ss modprobe modinfo systemctl swapon swapoff mkswap findmnt; do
    command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
  done
}

ensure_required_tools() {
  local allow_install="$1"
  local missing
  missing="$(missing_commands)"
  [ -z "$missing" ] && return 0

  warn "Missing required commands:"
  printf '%s\n' "$missing" >&2

  if [ "$allow_install" != "1" ] || [ "$AUTO_INSTALL_TOOLS" != "1" ]; then
    fail "Install: procps iproute2 kmod util-linux"
  fi

  command -v apt-get >/dev/null 2>&1 || fail "apt-get is unavailable"
  info "Installing required Debian packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y procps iproute2 kmod util-linux

  missing="$(missing_commands)"
  [ -z "$missing" ] || fail "Required commands are still missing after package installation"
}

primary_iface() {
  local dev
  dev="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  if [ -z "$dev" ]; then
    dev="$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  fi
  [ -n "$dev" ] || fail "Could not detect a default-route network interface"
  printf '%s\n' "$dev"
}

default_route_ifaces() {
  {
    ip -4 route show default 2>/dev/null || true
    ip -6 route show default 2>/dev/null || true
  } | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && $(i + 1) != "" && !seen[$(i + 1)]++) {
          print $(i + 1)
        }
      }
    }
  '
}

show_environment() {
  local mem_mb cpu_count root_fs root_size ipv4_count ipv6_count
  mem_mb="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
  cpu_count="$(nproc)"
  root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
  root_size="$(df -hP / | awk 'NR==2 {print $2 " total, " $4 " available"}')"
  ipv4_count="$(ip -4 -o addr show scope global 2>/dev/null | wc -l)"
  ipv6_count="$(ip -6 -o addr show scope global 2>/dev/null | wc -l)"

  # shellcheck disable=SC1091
  . /etc/os-release
  info "System: ${PRETTY_NAME:-unknown}; kernel: $(uname -r)"
  info "Resources: ${cpu_count} vCPU, ${mem_mb} MiB RAM, root ${root_fs} (${root_size})"
  info "Global addresses detected: IPv4=${ipv4_count}, IPv6=${ipv6_count}"
  info "Default-route interfaces: $(default_route_ifaces | paste -sd, -)"

  [ "$cpu_count" -eq 1 ] || warn "Profile target is 1 vCPU; detected ${cpu_count}"
  if [ "$mem_mb" -lt 768 ] || [ "$mem_mb" -gt 1536 ]; then
    warn "Profile target is about 1 GiB RAM; detected ${mem_mb} MiB"
  fi
  [ "$ipv4_count" -ge 1 ] || warn "No global IPv4 address was detected"
  [ "$ipv6_count" -ge 1 ] || warn "No global IPv6 address was detected"

  warn "Debian 13 is in development; keep system updated."
}

sysctl_var_name() {
  printf 'ORIG_%s' "${1//./_}"
}

save_original_state_once() {
  [ -f "$STATE_FILE" ] && return 0

  local iface qdisc_kind qdisc_line key var value
  iface="$(primary_iface)"
  qdisc_line="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1')"
  qdisc_kind="$(printf '%s\n' "$qdisc_line" | awk '{print $2}')"

  mkdir -p "$STATE_DIR"
  {
    printf '# Original runtime state captured before the first apply.\n'
    printf 'ORIG_IFACE=%q\n' "$iface"
    printf 'ORIG_QDISC=%q\n' "$qdisc_kind"
    printf 'ORIG_QDISC_KIND=%q\n' "$qdisc_kind"
    printf 'ORIG_QDISC_LINE=%q\n' "$qdisc_line"
    for key in "${STATE_SYSCTL_KEYS[@]}"; do
      var="$(sysctl_var_name "$key")"
      value="$(sysctl -n "$key" 2>/dev/null || true)"
      printf '%s=%q\n' "$var" "$value"
    done
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  info "Saved original runtime state to $STATE_FILE"
}

load_modules_and_choose() {
  local mod available current_cc current_qdisc
  local persist=()

  for mod in tcp_bbr sch_fq; do
    if modinfo "$mod" >/dev/null 2>&1; then
      if modprobe "$mod" >/dev/null 2>&1; then
        persist+=("$mod")
      else
        warn "Could not load kernel module: $mod"
      fi
    elif [ -d "/sys/module/$mod" ]; then
      info "$mod is built in or already loaded"
    else
      warn "$mod is unavailable on kernel $(uname -r)"
    fi
  done

  backup_file "$MODULES_FILE"
  {
    echo "# Modules used by 3x-UI VPS tuning"
    for mod in "${persist[@]}"; do
      echo "$mod"
    done
  } > "$MODULES_FILE"

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
  if printf '%s\n' "$available" | grep -qw bbr; then
    CHOSEN_CC="bbr"
  else
    CHOSEN_CC="$current_cc"
    warn "BBR is not available; retaining congestion control: $CHOSEN_CC"
  fi

  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)"
  if [ -d /sys/module/sch_fq ]; then
    CHOSEN_QDISC="fq"
  else
    CHOSEN_QDISC="$current_qdisc"
    warn "sch_fq is unavailable or failed to load; retaining default qdisc: $CHOSEN_QDISC"
  fi
}

write_sysctl_config() {
  backup_file "$SYSCTL_FILE"
  cat > "$SYSCTL_FILE" <<EOF_SYSCTL
# Conservative tuning for Debian 13, 1 vCPU, about 1 GiB RAM,
# dual-stack IPv4/IPv6, and 3x-UI/Xray/Hysteria2.
# No IP, route, MTU, DNS, firewall, or IPv6 policy settings are changed here.

# BBR is used only when the installed kernel exposes it. fq improves pacing
# under load, but modern BBR still works if a VPS platform cannot attach fq.
net.core.default_qdisc = ${CHOSEN_QDISC}
net.ipv4.tcp_congestion_control = ${CHOSEN_CC}

# 16 MiB follows current Hysteria 2 Linux guidance. These values are socket
# ceilings, not up-front per-connection allocations. Do not raise them without
# measured bandwidth-delay-product or QUIC buffer evidence on a 1 GiB host.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Moderate queues for one vCPU. Avoid extremely large software backlogs.
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# TCP Fast Open requires application socket support to have an effect.
net.ipv4.tcp_fastopen = 3

# Enable PLPMTUD only after an ICMP black-hole condition is detected.
net.ipv4.tcp_mtu_probing = 1

# These values affect only sockets that enable SO_KEEPALIVE. Xray may set its
# own per-socket values, which take precedence over these defaults.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Keep some swap available for short memory spikes without making it primary.
vm.swappiness = 20

# Intentionally not set: ip_local_port_range, tcp_tw_reuse, tcp_mem,
# fs.file-max, busy_poll, tcp_low_latency, RPS/RFS, MTU, IPv6 policy, or
# arbitrary UDP memory tables. Unknown 3x-UI inbound ports must not overlap a
# globally broadened ephemeral range unless ip_local_reserved_ports is managed.
EOF_SYSCTL
  info "Wrote $SYSCTL_FILE"
}

restore_unmanaged_port_range() {
  [ -f "$STATE_FILE" ] || return 0

  # shellcheck disable=SC1090
  . "$STATE_FILE"

  local original="${ORIG_net_ipv4_ip_local_port_range:-}"
  local current
  current="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)"

  if [ -n "$original" ] && [ "$current" != "$original" ]; then
    sysctl -w "net.ipv4.ip_local_port_range=$original" >/dev/null
    info "Restored unmanaged ip_local_port_range to its pre-tuning value: $original"
  fi
}

write_fq_service() {
  if [ "$CHOSEN_QDISC" != "fq" ]; then
    systemctl disable --now 3xui-fq.service >/dev/null 2>&1 || true
    rm -f -- "$FQ_SERVICE" "$FQ_HELPER"
    systemctl daemon-reload
    warn "Removed any stale explicit fq service because fq is unavailable"
    return 0
  fi

  backup_file "$FQ_HELPER"
  cat > "$FQ_HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

log_warning() {
  printf '[!] %s\n' "$*" >&2
  command -v logger >/dev/null 2>&1 && logger -t 3xui-fq -- "$*" || true
}

ifaces="$(
  {
    ip -4 route show default 2>/dev/null || true
    ip -6 route show default 2>/dev/null || true
  } | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && $(i + 1) != "" && !seen[$(i + 1)]++) {
          print $(i + 1)
        }
      }
    }
  '
)"

[ -n "$ifaces" ] || {
  log_warning "No default-route interface found; default_qdisc sysctl remains configured"
  exit 0
}

while IFS= read -r iface; do
  [ -n "$iface" ] || continue
  ip link show dev "$iface" >/dev/null 2>&1 || {
    log_warning "Interface disappeared before fq apply: $iface"
    continue
  }

  qdisc_output="$(tc qdisc show dev "$iface" 2>/dev/null || true)"
  root_kind="$(printf '%s\n' "$qdisc_output" | awk 'NR==1 {print $2}')"
  if [ "$root_kind" = "noqueue" ]; then
    log_warning "Interface $iface uses noqueue; explicit fq is unsupported"
    continue
  fi

  if [ "$root_kind" = "mq" ]; then
    parents="$(printf '%s\n' "$qdisc_output" | awk '$1 == "qdisc" && $4 == "parent" {print $5}')"
    if [ -z "$parents" ]; then
      log_warning "Interface $iface uses mq but exposes no leaf qdisc parents"
      continue
    fi
    while IFS= read -r parent; do
      [ -n "$parent" ] || continue
      if ! tc qdisc replace dev "$iface" parent "$parent" fq; then
        log_warning "Could not attach fq to $iface mq leaf $parent"
      fi
    done <<< "$parents"
    continue
  fi

  if ! tc qdisc replace dev "$iface" root fq; then
    log_warning "Could not attach fq to $iface; BBR can still use TCP-internal pacing"
  fi
done <<< "$ifaces"

exit 0
EOF_HELPER
  chmod 0755 "$FQ_HELPER"

  backup_file "$FQ_SERVICE"
  cat > "$FQ_SERVICE" <<EOF_SERVICE
[Unit]
Description=Apply fq pacing to 3x-UI VPS default-route interfaces
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FQ_HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable --now 3xui-fq.service
  info "Enabled explicit fq service without a hard-coded maxrate"
}

configure_service_limits() {
  local svc unit dir file found=0
  [[ "$NOFILE_LIMIT" =~ ^[1-9][0-9]*$ ]] || fail "NOFILE_LIMIT must be a positive integer"

  for svc in x-ui xray 3x-ui hysteria-server hysteria; do
    unit="${svc}.service"
    if systemctl cat "$unit" >/dev/null 2>&1; then
      found=1
      dir="/etc/systemd/system/${unit}.d"
      file="${dir}/99-3xui-tuning.conf"
      mkdir -p "$dir"
      backup_file "$file"
      cat > "$file" <<EOF_LIMIT
[Service]
LimitNOFILE=${NOFILE_LIMIT}
EOF_LIMIT
      info "Set $unit LimitNOFILE=$NOFILE_LIMIT"
    fi
  done
  [ "$found" -eq 1 ] || warn "No known x-ui/Xray/Hysteria systemd unit was found"
  systemctl daemon-reload
}

configure_journal_limit() {
  mkdir -p "$JOURNAL_DIR"
  backup_file "$JOURNAL_FILE"
  cat > "$JOURNAL_FILE" <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=128M
SystemKeepFree=512M
RuntimeMaxUse=64M
MaxRetentionSec=14day
Compress=yes
EOF_JOURNAL
  systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true
  info "Limited systemd journal disk use"
}

write_swap_fstab_entry() {
  local line="${SWAP_FILE} none swap sw 0 0"
  backup_file /etc/fstab || return 1
  if ! grep -Fxq "$line" /etc/fstab; then
    printf '%s\n' "$line" >> /etc/fstab || return 1
  fi
}

create_swap_if_needed() {
  [ "$ENABLE_SWAP" = "1" ] || {
    info "Swap creation disabled by ENABLE_SWAP=$ENABLE_SWAP"
    return 0
  }

  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    info "Active swap already exists; no swap file created"
    return 0
  fi

  local fstype available_kb required_kb used_fallocate=0
  fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  case "$fstype" in
    btrfs|zfs|overlay|nfs|nfs4|fuse.*)
      warn "Automatic swap-file creation is skipped on root filesystem: $fstype"
      return 0
      ;;
  esac

  [[ "$SWAP_MB" =~ ^[1-9][0-9]*$ ]] || fail "SWAP_MB must be a positive integer"
  available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  required_kb=$((SWAP_MB * 1024 + 262144))
  if [ "${available_kb:-0}" -lt "$required_kb" ]; then
    warn "Insufficient free disk space for ${SWAP_MB} MiB swap plus 256 MiB reserve"
    return 0
  fi

  if [ -e "$SWAP_FILE" ]; then
    warn "$SWAP_FILE already exists but is inactive; leaving it unchanged"
    return 0
  fi

  info "Creating ${SWAP_MB} MiB emergency swap file: $SWAP_FILE"
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "${SWAP_MB}M" "$SWAP_FILE"; then
    used_fallocate=1
  else
    if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=progress conv=fsync; then
      rm -f -- "$SWAP_FILE"
      warn "Could not allocate the swap file; cleaned up the partial file"
      return 0
    fi
  fi

  if ! chmod 0600 "$SWAP_FILE" || ! mkswap "$SWAP_FILE" >/dev/null; then
    rm -f -- "$SWAP_FILE"
    warn "Could not initialize the swap file; cleaned it up"
    return 0
  fi

  if ! swapon "$SWAP_FILE"; then
    if [ "$used_fallocate" -eq 1 ]; then
      warn "Preallocated swap was rejected; retrying with a fully written file"
      rm -f -- "$SWAP_FILE"
      if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=progress conv=fsync ||
        ! chmod 0600 "$SWAP_FILE" ||
        ! mkswap "$SWAP_FILE" >/dev/null; then
        rm -f -- "$SWAP_FILE"
        warn "Could not rebuild the swap file; cleaned it up"
        return 0
      fi
      if ! swapon "$SWAP_FILE"; then
        rm -f -- "$SWAP_FILE"
        warn "Swap activation failed; cleaned up the unusable file"
        return 0
      fi
    else
      rm -f -- "$SWAP_FILE"
      warn "Swap activation failed; cleaned up the unusable file"
      return 0
    fi
  fi

  if ! mkdir -p "$STATE_DIR" || ! touch "$SWAP_MARKER"; then
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f -- "$SWAP_FILE" "$SWAP_MARKER"
    warn "Could not record swap ownership; disabled and cleaned up the swap file"
    return 0
  fi

  if ! write_swap_fstab_entry; then
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f -- "$SWAP_FILE" "$SWAP_MARKER"
    warn "Could not persist swap in /etc/fstab; disabled and cleaned it up"
    return 0
  fi

  info "Swap file enabled"
}

warn_about_conflicts() {
  local matches
  matches="$(
    grep -RIlE \
      '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|vm\.swappiness)[[:space:]]*=' \
      /etc/sysctl.conf /etc/sysctl.d 2>/dev/null |
      grep -Fv "$SYSCTL_FILE" || true
  )"
  if [ -n "$matches" ]; then
    warn "Other sysctl files also define tuning keys:"
    printf '%s\n' "$matches" >&2
    warn "$SYSCTL_FILE is named to load late; verify after every reboot"
  fi
}

profile_value() {
  local key="$1"
  awk -F= -v wanted="$key" '
    {
      left = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == wanted) {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$SYSCTL_FILE"
}

VERIFY_FAILURES=0
VERIFY_WARNINGS=0

verify_equals() {
  local key="$1" expected="$2" actual expected_normalized actual_normalized
  actual="$(sysctl -n "$key" 2>/dev/null || true)"
  expected_normalized="$(printf '%s\n' "$expected" | awk '{$1=$1; print}')"
  actual_normalized="$(printf '%s\n' "$actual" | awk '{$1=$1; print}')"
  if [ "$actual_normalized" = "$expected_normalized" ]; then
    printf '[PASS] %s = %s\n' "$key" "$actual"
  else
    printf '[FAIL] %s expected "%s", got "%s"\n' "$key" "$expected" "$actual" >&2
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

apply_settings() {
  need_root
  check_supported_os
  check_sibling_profile_conflicts
  ensure_required_tools 1
  show_environment
  save_original_state_once

  load_modules_and_choose
  write_sysctl_config
  warn_about_conflicts

  info "Applying sysctl files, then reapplying the final profile explicitly"
  sysctl --system >/dev/null || warn "sysctl --system reported one or more warnings"
  sysctl -p "$SYSCTL_FILE" >/dev/null
  restore_unmanaged_port_range

  write_fq_service
  configure_service_limits
  configure_journal_limit
  create_swap_if_needed

  info "Tuning applied. The proxy service was not restarted automatically."
  if ! verify_settings; then
    warn "Apply completed, but verification found mismatches; review before reboot"
  fi
  info "Restart the actual proxy service during a maintenance window, for example: systemctl restart x-ui"
  info "Then reboot once and run: sudo bash $0 verify"
}

verify_settings() {
  [ -f "$SYSCTL_FILE" ] || fail "Profile is not installed: $SYSCTL_FILE"

  local key expected expected_qdisc iface qdisc_output unit configured_limit active_state
  local main_pid runtime_limit found_unit=0 ifaces_seen=0
  VERIFY_FAILURES=0
  VERIFY_WARNINGS=0

  echo
  echo "=== System ==="
  uname -a
  awk '/MemTotal|MemAvailable/ {print}' /proc/meminfo
  swapon --show || true
  ip -4 -br addr show scope global || true
  ip -6 -br addr show scope global || true

  echo
  echo "=== Exact sysctl verification ==="
  for key in "${PROFILE_SYSCTL_KEYS[@]}"; do
    expected="$(profile_value "$key")"
    if [ -z "$expected" ]; then
      warn "Profile entry is missing or empty: $key"
      VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    else
      verify_equals "$key" "$expected"
    fi
  done

  echo
  echo "=== Default-route interface qdiscs ==="
  expected_qdisc="$(profile_value net.core.default_qdisc)"
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    ifaces_seen=$((ifaces_seen + 1))
    qdisc_output="$(tc qdisc show dev "$iface" 2>/dev/null || true)"
    printf '%s\n' "$qdisc_output"
    if printf '%s\n' "$qdisc_output" | awk -v expected="$expected_qdisc" '
      $1 == "qdisc" && $2 == expected && ($4 == "root" || $4 == "parent") {
        found = 1
      }
      END { exit(found ? 0 : 1) }
    '; then
      :
    else
      warn "Interface $iface does not show expected qdisc $expected_qdisc at root or mq leaves; inspect its driver/virtualization support"
      VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
    fi
  done < <(default_route_ifaces)
  if [ "$ifaces_seen" -eq 0 ]; then
    warn "No default-route interface was available for qdisc verification"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  echo
  echo "=== Service limits ==="
  for unit in x-ui.service xray.service 3x-ui.service hysteria-server.service hysteria.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      found_unit=1
      configured_limit="$(systemctl show "$unit" -p LimitNOFILE --value)"
      active_state="$(systemctl show "$unit" -p ActiveState --value)"
      main_pid="$(systemctl show "$unit" -p MainPID --value)"
      printf '%s configured LimitNOFILE=%s ActiveState=%s MainPID=%s\n' \
        "$unit" "$configured_limit" "$active_state" "$main_pid"

      if [ "$configured_limit" != "$NOFILE_LIMIT" ]; then
        warn "$unit does not expose the expected configured LimitNOFILE"
        VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
      fi

      if [ "$active_state" = "active" ] && [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] &&
        [ -r "/proc/${main_pid}/limits" ]; then
        runtime_limit="$(
          awk '$1 == "Max" && $2 == "open" && $3 == "files" {print $4 ":" $5; exit}' \
            "/proc/${main_pid}/limits"
        )"
        printf '%s running process open-file limit=%s\n' "$unit" "${runtime_limit:-unknown}"
        if [ "$runtime_limit" != "${NOFILE_LIMIT}:${NOFILE_LIMIT}" ]; then
          warn "$unit is running with an older open-file limit; restart it during a maintenance window"
          VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
        fi
      fi
    fi
  done
  if [ "$found_unit" -eq 0 ]; then
    warn "No known proxy service unit was found"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  echo
  echo "=== Optional live TCP congestion-control evidence ==="
  ss -tin 2>/dev/null | grep -m 10 -E 'bbr|cubic|reno' || true

  echo
  if [ "$VERIFY_FAILURES" -eq 0 ]; then
    info "Verification passed with ${VERIFY_WARNINGS} warning(s)"
    return 0
  fi

  warn "Verification failed: ${VERIFY_FAILURES} mismatch(es), ${VERIFY_WARNINGS} warning(s)"
  return 1
}

remove_generated_fstab_entry() {
  local tmp
  tmp="$(mktemp /etc/fstab.3xui.XXXXXX)"
  awk -v target="$SWAP_FILE" '
    !($1 == target && $2 == "none" && $3 == "swap" && $4 == "sw" && $5 == "0" && $6 == "0")
  ' /etc/fstab > "$tmp"
  chmod --reference=/etc/fstab "$tmp"
  chown --reference=/etc/fstab "$tmp"
  mv -- "$tmp" /etc/fstab
}

purge_created_swap_if_requested() {
  [ -f "$SWAP_MARKER" ] || return 0

  if [ "$PURGE_CREATED_SWAP" != "1" ]; then
    warn "The script-created swap remains enabled for safety: $SWAP_FILE"
    warn "To remove it: sudo env PURGE_CREATED_SWAP=1 bash $0 rollback"
    return 0
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | awk '{$1=$1; print}' | grep -Fxq "$SWAP_FILE"; then
    if ! swapoff "$SWAP_FILE"; then
      warn "Could not disable $SWAP_FILE; leaving swap and fstab unchanged"
      return 0
    fi
  fi

  backup_file /etc/fstab
  remove_generated_fstab_entry
  rm -f -- "$SWAP_FILE" "$SWAP_MARKER"
  info "Removed the swap file created by this profile"
}

restore_original_runtime_state() {
  if [ ! -f "$STATE_FILE" ]; then
    warn "Original runtime state is unavailable; reboot to load remaining system configuration"
    return 0
  fi

  # shellcheck disable=SC1090
  . "$STATE_FILE"

  local key var value original_qdisc
  for key in "${STATE_SYSCTL_KEYS[@]}"; do
    var="$(sysctl_var_name "$key")"
    value="${!var:-}"
    if [ -n "$value" ]; then
      sysctl -w "$key=$value" >/dev/null 2>&1 || warn "Could not restore $key"
    fi
  done

  original_qdisc="${ORIG_QDISC_KIND:-${ORIG_QDISC:-}}"
  if [ -n "${ORIG_IFACE:-}" ] && [ -n "$original_qdisc" ]; then
    case "$original_qdisc" in
      fq|fq_codel|pfifo_fast|sfq|mq)
        tc qdisc replace dev "$ORIG_IFACE" root "$original_qdisc" >/dev/null 2>&1 ||
          warn "Could not restore qdisc $original_qdisc on $ORIG_IFACE; reboot recommended"
        ;;
      noqueue)
        ;;
      *)
        warn "Original qdisc was complex or unknown (${ORIG_QDISC_LINE:-$original_qdisc}); reboot instead of reconstructing it"
        ;;
    esac
  fi
}

rollback_settings() {
  need_root
  check_supported_os
  check_sibling_profile_conflicts
  ensure_required_tools 0

  info "Removing files created by this tuning profile"
  systemctl disable --now 3xui-fq.service >/dev/null 2>&1 || true
  rm -f -- "$FQ_SERVICE" "$FQ_HELPER" "$SYSCTL_FILE" "$MODULES_FILE" "$JOURNAL_FILE"

  local svc file
  for svc in x-ui xray 3x-ui hysteria-server hysteria; do
    file="/etc/systemd/system/${svc}.service.d/99-3xui-tuning.conf"
    rm -f -- "$file"
  done

  systemctl daemon-reload
  systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true
  sysctl --system >/dev/null || warn "sysctl --system reported one or more warnings"
  restore_original_runtime_state
  purge_created_swap_if_requested

  info "Rollback completed. Proxy services were not restarted."
  info "Reboot is recommended to reconstruct the provider's default qdisc and boot-time sysctls."
}

case "$ACTION" in
  apply)
    apply_settings
    ;;
  verify)
    need_root
    check_supported_os
    check_sibling_profile_conflicts
    ensure_required_tools 0
    show_environment
    verify_settings
    ;;
  rollback)
    rollback_settings
    ;;
  *)
    fail "Usage: $0 [apply|verify|rollback]"
    ;;
esac
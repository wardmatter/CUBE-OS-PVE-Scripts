#!/usr/bin/env bash
set -euo pipefail

REPO="eWeLinkCUBE/CUBE-OS"
DEFAULT_IMAGE_NAME="sdcard.vmdk"
DEFAULT_ARCHIVE_NAME="${DEFAULT_IMAGE_NAME}.xz"
DEFAULT_NAME="cube-os"
DEFAULT_MEMORY="4096"
DEFAULT_CORES="2"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE="local"
DEFAULT_CPU_TYPE="host"
DEFAULT_MACHINE="q35"
DEFAULT_DISK_INTERFACE="sata0"
DEFAULT_DOWNLOAD_DIR="/var/lib/vz/template/cache"
DEFAULT_BIOS="ovmf"
DEFAULT_SCSIHW="virtio-scsi-pci"
DEFAULT_NET_MODEL="virtio"

VMID=""
NAME="$DEFAULT_NAME"
MEMORY="$DEFAULT_MEMORY"
CORES="$DEFAULT_CORES"
BRIDGE="$DEFAULT_BRIDGE"
STORAGE="$DEFAULT_STORAGE"
EFI_STORAGE=""
CPU_TYPE="$DEFAULT_CPU_TYPE"
MACHINE="$DEFAULT_MACHINE"
DISK_INTERFACE="$DEFAULT_DISK_INTERFACE"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
IMAGE_PATH=""
ARCHIVE_PATH=""
DOWNLOAD_LATEST="0"
DOWNLOAD_URL=""
RELEASE_TAG="latest"
START_VM="0"
USB_VENDOR_ID=""
USB_PRODUCT_ID=""
USB3="1"
INTERACTIVE="0"
ASSUME_YES="0"
DRY_RUN="0"
KEEP_FAILED_VM="0"
SHOW_CONFIG_ONLY="0"
NO_COLOR="0"
VERBOSE="0"

CREATED_VM="0"
STEP_NUM="0"
TOTAL_STEPS="0"

if [[ -t 1 && "$NO_COLOR" == "0" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

usage() {
  cat <<'EOF'
Create a Proxmox VE VM for eWeLink CUBE OS.

Usage:
  pve-create-cube-os.sh [options]

Image source options (choose one):
  --image PATH               Use a local extracted .vmdk image.
  --archive PATH             Use a local .vmdk.xz archive and extract it first.
  --download-latest          Download the latest sdcard.vmdk.xz from GitHub releases.
  --release TAG              Download a specific GitHub release tag. Default: latest
  --download-url URL         Download a .vmdk.xz archive from a custom URL.
  --download-dir DIR         Directory for downloaded/extracted images.

VM options:
  --vmid ID                  VM ID. Default: next available VMID
  --name NAME                VM name. Default: cube-os
  --memory MB                Memory in MB. Default: 4096
  --cores N                  CPU cores. Default: 2
  --bridge NAME              Proxmox bridge. Default: vmbr0
  --storage NAME             Target VM disk storage. Default: local
  --efi-storage NAME         EFI disk storage. Default: same as --storage
  --cpu TYPE                 CPU type. Default: host
  --machine TYPE             Machine type. Default: q35
  --disk-interface NAME      Boot disk slot. Default: sata0

USB options:
  --usb VID:PID              Add a USB device by vendor/product ID.
  --usb2                     Attach USB device as USB2 instead of USB3.
  --usb3                     Attach USB device as USB3. Default.

Flow / UX options:
  --interactive              Prompt for values in a guided setup.
  --yes                      Skip the final confirmation prompt.
  --start                    Start the VM after creation.
  --dry-run                  Print the plan without making changes.
  --show-config              Print resolved configuration and exit.
  --keep-failed-vm           Do not suggest cleanup if a later step fails.
  --list-storage             List available Proxmox storage targets and exit.
  --list-bridges             List available bridge interfaces and exit.
  --list-usb                 List attached USB devices from lsusb and exit.
  --no-color                 Disable ANSI colors in output.
  --verbose                  Print commands before running them.
  -h, --help                 Show this help.

Examples:
  pve-create-cube-os.sh --download-latest --yes --start
  pve-create-cube-os.sh --image /root/sdcard.vmdk --vmid 950 --storage local
  pve-create-cube-os.sh --archive /root/sdcard.vmdk.xz --usb 10c4:ea60
  pve-create-cube-os.sh --release v2.5.2 --bridge vmbr1 --memory 8192 --cores 4
  pve-create-cube-os.sh --interactive
EOF
}

timestamp() {
  date '+%F %T'
}

log_info() {
  printf '%s[%s]%s %s\n' "$C_BLUE" "$(timestamp)" "$C_RESET" "$*"
}

log_warn() {
  printf '%s[%s]%s %s\n' "$C_YELLOW" "$(timestamp)" "$C_RESET" "$*" >&2
}

log_ok() {
  printf '%s[%s]%s %s\n' "$C_GREEN" "$(timestamp)" "$C_RESET" "$*"
}

fail() {
  printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "$VERBOSE" == "1" || "$DRY_RUN" == "1" ]]; then
    printf '%s$%s %s\n' "$C_DIM" "$C_RESET" "$*"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  "$@"
}

next_step() {
  STEP_NUM=$((STEP_NUM + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' "$C_BOLD" "$STEP_NUM" "$TOTAL_STEPS" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Run this script as root on the Proxmox host"
}

storage_exists() {
  pvesm status | awk 'NR > 1 {print $1}' | grep -Fx "$1" >/dev/null 2>&1
}

bridge_exists() {
  ip link show "$1" >/dev/null 2>&1
}

vmid_exists() {
  qm status "$1" >/dev/null 2>&1
}

list_storages() {
  require_command pvesm
  pvesm status
}

list_bridges() {
  require_command ip
  ip -o link show | awk -F': ' '{print $2}' | grep -E '^(vmbr|br|bond)' || true
}

list_usb_devices() {
  require_command lsusb
  lsusb
}

get_next_vmid() {
  if command_exists pvesh; then
    pvesh get /cluster/nextid
    return
  fi

  local candidate="100"
  while vmid_exists "$candidate"; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

print_banner() {
  cat <<EOF
${C_BOLD}CUBE OS Proxmox VE Installer${C_RESET}
Repository: ${REPO}
EOF
}

parse_args() {
  if [[ $# -eq 0 && -t 0 ]]; then
    INTERACTIVE="1"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        IMAGE_PATH="${2:-}"
        shift 2
        ;;
      --archive)
        ARCHIVE_PATH="${2:-}"
        shift 2
        ;;
      --download-latest)
        DOWNLOAD_LATEST="1"
        RELEASE_TAG="latest"
        shift
        ;;
      --release)
        RELEASE_TAG="${2:-}"
        DOWNLOAD_LATEST="1"
        shift 2
        ;;
      --download-url)
        DOWNLOAD_URL="${2:-}"
        shift 2
        ;;
      --download-dir)
        DOWNLOAD_DIR="${2:-}"
        shift 2
        ;;
      --vmid)
        VMID="${2:-}"
        shift 2
        ;;
      --name)
        NAME="${2:-}"
        shift 2
        ;;
      --memory)
        MEMORY="${2:-}"
        shift 2
        ;;
      --cores)
        CORES="${2:-}"
        shift 2
        ;;
      --bridge)
        BRIDGE="${2:-}"
        shift 2
        ;;
      --storage)
        STORAGE="${2:-}"
        shift 2
        ;;
      --efi-storage)
        EFI_STORAGE="${2:-}"
        shift 2
        ;;
      --cpu)
        CPU_TYPE="${2:-}"
        shift 2
        ;;
      --machine)
        MACHINE="${2:-}"
        shift 2
        ;;
      --disk-interface)
        DISK_INTERFACE="${2:-}"
        shift 2
        ;;
      --usb)
        IFS=':' read -r USB_VENDOR_ID USB_PRODUCT_ID <<<"${2:-}"
        shift 2
        ;;
      --usb2)
        USB3="0"
        shift
        ;;
      --usb3)
        USB3="1"
        shift
        ;;
      --interactive)
        INTERACTIVE="1"
        shift
        ;;
      --yes)
        ASSUME_YES="1"
        shift
        ;;
      --start)
        START_VM="1"
        shift
        ;;
      --dry-run)
        DRY_RUN="1"
        shift
        ;;
      --show-config)
        SHOW_CONFIG_ONLY="1"
        shift
        ;;
      --keep-failed-vm)
        KEEP_FAILED_VM="1"
        shift
        ;;
      --list-storage)
        list_storages
        exit 0
        ;;
      --list-bridges)
        list_bridges
        exit 0
        ;;
      --list-usb)
        list_usb_devices
        exit 0
        ;;
      --no-color)
        NO_COLOR="1"
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_RED=""
        C_GREEN=""
        C_YELLOW=""
        C_BLUE=""
        shift
        ;;
      --verbose)
        VERBOSE="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

prompt_value() {
  local prompt="$1"
  local default_value="$2"
  local input=""

  read -r -p "${prompt} [${default_value}]: " input || true
  if [[ -z "$input" ]]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$input"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local suffix="[y/N]"
  local answer=""

  if [[ "$default_answer" == "y" ]]; then
    suffix="[Y/n]"
  fi

  read -r -p "${prompt} ${suffix}: " answer || true
  answer="${answer:-$default_answer}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_interactive_setup() {
  print_banner
  printf '\n'
  log_info "Guided mode enabled. Press Enter to accept the defaults."

  local auto_vmid
  auto_vmid="$(get_next_vmid)"

  printf '\nAvailable storage targets:\n'
  list_storages || true

  printf '\nAvailable bridge interfaces:\n'
  list_bridges || true

  printf '\nChoose the CUBE OS image source:\n'
  printf '  1) Download latest release\n'
  printf '  2) Download a specific release tag\n'
  printf '  3) Use a local .vmdk image\n'
  printf '  4) Use a local .vmdk.xz archive\n'

  local source_choice=""
  read -r -p "Select an option [1]: " source_choice || true
  source_choice="${source_choice:-1}"

  case "$source_choice" in
    1)
      DOWNLOAD_LATEST="1"
      RELEASE_TAG="latest"
      ;;
    2)
      DOWNLOAD_LATEST="1"
      RELEASE_TAG="$(prompt_value "Release tag" "$RELEASE_TAG")"
      ;;
    3)
      IMAGE_PATH="$(prompt_value "Local .vmdk path" "/root/${DEFAULT_IMAGE_NAME}")"
      ;;
    4)
      ARCHIVE_PATH="$(prompt_value "Local .vmdk.xz path" "/root/${DEFAULT_ARCHIVE_NAME}")"
      ;;
    *)
      fail "Invalid source choice: $source_choice"
      ;;
  esac

  VMID="$(prompt_value "VM ID" "${VMID:-$auto_vmid}")"
  NAME="$(prompt_value "VM name" "$NAME")"
  MEMORY="$(prompt_value "Memory (MB)" "$MEMORY")"
  CORES="$(prompt_value "CPU cores" "$CORES")"
  STORAGE="$(prompt_value "Disk storage" "$STORAGE")"
  EFI_STORAGE="$(prompt_value "EFI storage" "${EFI_STORAGE:-$STORAGE}")"
  BRIDGE="$(prompt_value "Bridge" "$BRIDGE")"
  CPU_TYPE="$(prompt_value "CPU type" "$CPU_TYPE")"
  MACHINE="$(prompt_value "Machine type" "$MACHINE")"
  DISK_INTERFACE="$(prompt_value "Disk interface" "$DISK_INTERFACE")"
  DOWNLOAD_DIR="$(prompt_value "Download/extract directory" "$DOWNLOAD_DIR")"

  if prompt_yes_no "Attach a USB device?" "n"; then
    local usb_id
    usb_id="$(prompt_value "USB VID:PID" "10c4:ea60")"
    IFS=':' read -r USB_VENDOR_ID USB_PRODUCT_ID <<<"$usb_id"
    if prompt_yes_no "Use USB 3.0?" "y"; then
      USB3="1"
    else
      USB3="0"
    fi
  fi

  if prompt_yes_no "Start the VM automatically?" "y"; then
    START_VM="1"
  else
    START_VM="0"
  fi

  if prompt_yes_no "Skip final confirmation in future runs?" "y"; then
    ASSUME_YES="1"
  fi
}

validate_numeric() {
  [[ "$2" =~ ^[0-9]+$ ]] || fail "$1 must be numeric"
}

validate_args() {
  local source_count="0"

  [[ -n "$EFI_STORAGE" ]] || EFI_STORAGE="$STORAGE"

  [[ -n "$IMAGE_PATH" ]] && source_count=$((source_count + 1))
  [[ -n "$ARCHIVE_PATH" ]] && source_count=$((source_count + 1))
  [[ "$DOWNLOAD_LATEST" == "1" ]] && source_count=$((source_count + 1))
  [[ -n "$DOWNLOAD_URL" ]] && source_count=$((source_count + 1))

  [[ "$source_count" -eq 1 ]] || fail "Choose exactly one image source: --image, --archive, --download-latest/--release, or --download-url"

  validate_numeric "--vmid" "${VMID:-0}"
  validate_numeric "--memory" "$MEMORY"
  validate_numeric "--cores" "$CORES"
  [[ "$DISK_INTERFACE" =~ ^(scsi|sata|virtio)[0-9]+$ ]] || fail "--disk-interface must look like scsi0, sata0, or virtio0"

  if [[ -n "$USB_VENDOR_ID" || -n "$USB_PRODUCT_ID" ]]; then
    [[ "$USB_VENDOR_ID" =~ ^[[:xdigit:]]{4}$ ]] || fail "--usb vendor ID must be 4 hex chars"
    [[ "$USB_PRODUCT_ID" =~ ^[[:xdigit:]]{4}$ ]] || fail "--usb product ID must be 4 hex chars"
  fi
}

resolve_defaults() {
  if [[ -z "$VMID" ]]; then
    VMID="$(get_next_vmid)"
  fi
}

extract_archive() {
  require_command xz

  local archive="$1"
  local destination_dir="$2"
  local extracted_path="${destination_dir}/${DEFAULT_IMAGE_NAME}"

  [[ -f "$archive" ]] || fail "Archive not found: $archive"
  run_cmd mkdir -p "$destination_dir"

  next_step "Extracting CUBE OS disk image"
  log_info "Archive: $archive"
  log_info "Output : $extracted_path"

  if [[ "$DRY_RUN" == "1" ]]; then
    IMAGE_PATH="$extracted_path"
    return
  fi

  rm -f "$extracted_path"
  if [[ "$VERBOSE" == "1" ]]; then
    printf '%s$%s xz -dc %s > %s\n' "$C_DIM" "$C_RESET" "$archive" "$extracted_path"
  fi
  xz -dc -- "$archive" > "$extracted_path"

  [[ -f "$extracted_path" ]] || fail "Extraction failed: no .vmdk file produced"
  IMAGE_PATH="$extracted_path"
}

download_image() {
  require_command curl
  require_command xz

  local api_url=""
  local release_json=""
  local asset_url=""
  local archive_path=""

  run_cmd mkdir -p "$DOWNLOAD_DIR"

  if [[ -n "$DOWNLOAD_URL" ]]; then
    asset_url="$DOWNLOAD_URL"
    archive_path="${DOWNLOAD_DIR}/${DEFAULT_ARCHIVE_NAME}"
    next_step "Downloading CUBE OS archive from custom URL"
    log_info "URL: $asset_url"
  else
    if [[ "$RELEASE_TAG" == "latest" ]]; then
      api_url="https://api.github.com/repos/${REPO}/releases/latest"
      next_step "Resolving latest CUBE OS release"
    else
      api_url="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
      next_step "Resolving CUBE OS release tag ${RELEASE_TAG}"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      asset_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${DEFAULT_ARCHIVE_NAME}"
    else
      release_json="$(curl -fsSL "$api_url")"
      asset_url="$(printf '%s' "$release_json" | grep -Eo 'https://[^"]+/sdcard\.vmdk\.xz' | head -n1)"
      [[ -n "$asset_url" ]] || fail "Could not find ${DEFAULT_ARCHIVE_NAME} in the selected release"
    fi

    archive_path="${DOWNLOAD_DIR}/${DEFAULT_ARCHIVE_NAME}"
    log_info "Download URL: $asset_url"
  fi

  next_step "Downloading CUBE OS archive"
  log_info "Saving to ${archive_path}"
  run_cmd curl -fL "$asset_url" -o "$archive_path"

  ARCHIVE_PATH="$archive_path"
  extract_archive "$ARCHIVE_PATH" "$DOWNLOAD_DIR"
}

preflight_checks() {
  next_step "Running preflight checks"

  require_command qm
  require_command pvesm
  require_command ip

  if [[ -n "$ARCHIVE_PATH" || "$DOWNLOAD_LATEST" == "1" || -n "$DOWNLOAD_URL" ]]; then
    require_command xz
  fi
  if [[ "$DOWNLOAD_LATEST" == "1" || -n "$DOWNLOAD_URL" ]]; then
    require_command curl
  fi

  storage_exists "$STORAGE" || fail "Storage not found in Proxmox: $STORAGE"
  storage_exists "$EFI_STORAGE" || fail "EFI storage not found in Proxmox: $EFI_STORAGE"
  bridge_exists "$BRIDGE" || fail "Network bridge not found: $BRIDGE"
  vmid_exists "$VMID" && fail "VMID $VMID already exists"

  log_ok "Storage, bridge, and VMID checks passed"
}

show_configuration() {
  cat <<EOF

${C_BOLD}Resolved configuration${C_RESET}
  VMID:           ${VMID}
  Name:           ${NAME}
  Memory:         ${MEMORY} MB
  Cores:          ${CORES}
  Bridge:         ${BRIDGE}
  Storage:        ${STORAGE}
  EFI storage:    ${EFI_STORAGE}
  CPU type:       ${CPU_TYPE}
  Machine:        ${MACHINE}
  Disk interface: ${DISK_INTERFACE}
  Download dir:   ${DOWNLOAD_DIR}
  Start after:    ${START_VM}
  USB passthru:   ${USB_VENDOR_ID:+${USB_VENDOR_ID}:${USB_PRODUCT_ID}}${USB_VENDOR_ID:-disabled}
  USB mode:       $( [[ "$USB3" == "1" ]] && printf 'USB 3.0' || printf 'USB 2.0' )

Image source:
$(describe_image_source)
EOF
}

describe_image_source() {
  if [[ -n "$IMAGE_PATH" ]]; then
    printf '  Local image:    %s\n' "$IMAGE_PATH"
  elif [[ -n "$ARCHIVE_PATH" ]]; then
    printf '  Local archive:  %s\n' "$ARCHIVE_PATH"
  elif [[ -n "$DOWNLOAD_URL" ]]; then
    printf '  Download URL:   %s\n' "$DOWNLOAD_URL"
  else
    printf '  GitHub release: %s\n' "$RELEASE_TAG"
  fi
}

confirm_plan() {
  if [[ "$ASSUME_YES" == "1" || "$DRY_RUN" == "1" ]]; then
    return
  fi

  printf '\n'
  if ! prompt_yes_no "Proceed with VM creation?" "y"; then
    fail "Cancelled by user"
  fi
}

create_vm() {
  next_step "Creating Proxmox VM"
  run_cmd qm create "$VMID" \
    --name "$NAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu "$CPU_TYPE" \
    --machine "$MACHINE" \
    --bios "$DEFAULT_BIOS" \
    --scsihw "$DEFAULT_SCSIHW" \
    --agent enabled=0 \
    --net0 "${DEFAULT_NET_MODEL},bridge=${BRIDGE}"

  CREATED_VM="1"

  next_step "Adding EFI disk"
  run_cmd qm set "$VMID" --efidisk0 "${EFI_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

  next_step "Importing CUBE OS disk image"
  log_info "Image: ${IMAGE_PATH}"
  run_cmd qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" --format raw

  next_step "Configuring boot disk and console"
  run_cmd qm set "$VMID" --"${DISK_INTERFACE}" "${STORAGE}:vm-${VMID}-disk-0"
  run_cmd qm set "$VMID" --boot "order=${DISK_INTERFACE}"
  run_cmd qm set "$VMID" --vga std
}

attach_usb_if_requested() {
  if [[ -n "$USB_VENDOR_ID" && -n "$USB_PRODUCT_ID" ]]; then
    next_step "Attaching USB device ${USB_VENDOR_ID}:${USB_PRODUCT_ID}"
    run_cmd qm set "$VMID" --usb0 "host=${USB_VENDOR_ID}:${USB_PRODUCT_ID},usb3=${USB3}"
  fi
}

start_vm_if_requested() {
  if [[ "$START_VM" == "1" ]]; then
    next_step "Starting VM ${VMID}"
    run_cmd qm start "$VMID"
  fi
}

print_summary() {
  cat <<EOF

${C_GREEN}${C_BOLD}CUBE OS VM created successfully.${C_RESET}

VM details:
  VMID:       ${VMID}
  Name:       ${NAME}
  Memory:     ${MEMORY} MB
  Cores:      ${CORES}
  Bridge:     ${BRIDGE}
  Storage:    ${STORAGE}
  EFI store:  ${EFI_STORAGE}
  Disk slot:  ${DISK_INTERFACE}
  Image:      ${IMAGE_PATH}

Next steps:
  1. Start the VM if you did not use --start:
     qm start ${VMID}
  2. Open the Proxmox console and wait for CUBE OS to finish booting.
  3. Browse to http://<cube-ip>/ or http://cube.local

Helpful commands:
  qm status ${VMID}
  qm config ${VMID}
  qm terminal ${VMID}

Notes:
  - CUBE OS expects UEFI boot; this script uses OVMF and disables pre-enrolled keys.
  - Bridged networking is recommended so LAN discovery and cube.local work properly.
  - If you need Zigbee, pass a dongle with --usb VID:PID or add it later in the Proxmox UI.
EOF
}

cleanup_hint() {
  if [[ "$CREATED_VM" == "1" && "$KEEP_FAILED_VM" != "1" ]]; then
    log_warn "A VM may have been created before the failure. Review it with: qm config ${VMID}"
    log_warn "If you want to remove it manually: qm destroy ${VMID} --destroy-unreferenced-disks 1 --purge 1"
  fi
}

on_error() {
  cleanup_hint
}

calculate_total_steps() {
  TOTAL_STEPS="5"
  if [[ "$DOWNLOAD_LATEST" == "1" || -n "$DOWNLOAD_URL" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 2))
  elif [[ -n "$ARCHIVE_PATH" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
  fi
  if [[ -n "$USB_VENDOR_ID" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
  fi
  if [[ "$START_VM" == "1" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
  fi
}

main() {
  trap on_error ERR

  parse_args "$@"
  ensure_root

  if [[ "$INTERACTIVE" == "1" ]]; then
    run_interactive_setup
  fi

  resolve_defaults
  validate_args
  calculate_total_steps
  preflight_checks

  if [[ -n "$ARCHIVE_PATH" ]]; then
    extract_archive "$ARCHIVE_PATH" "$DOWNLOAD_DIR"
  elif [[ "$DOWNLOAD_LATEST" == "1" || -n "$DOWNLOAD_URL" ]]; then
    download_image
  fi

  [[ -f "$IMAGE_PATH" || "$DRY_RUN" == "1" ]] || fail "Image not found: $IMAGE_PATH"

  show_configuration

  if [[ "$SHOW_CONFIG_ONLY" == "1" ]]; then
    exit 0
  fi

  confirm_plan
  create_vm
  attach_usb_if_requested
  start_vm_if_requested
  print_summary
}

main "$@"

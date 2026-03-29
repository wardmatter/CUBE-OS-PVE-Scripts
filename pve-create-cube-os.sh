#!/usr/bin/env bash
set -euo pipefail

REPO="eWeLinkCUBE/CUBE-OS"
DEFAULT_IMAGE_NAME="sdcard.vmdk"
DEFAULT_ARCHIVE_NAME="${DEFAULT_IMAGE_NAME}.xz"

VMID="950"
NAME="cube-os"
MEMORY="4096"
CORES="2"
BRIDGE="vmbr0"
STORAGE="local-lvm"
EFI_STORAGE=""
CPU_TYPE="host"
MACHINE="q35"
IMAGE_PATH=""
DOWNLOAD_DIR="/var/lib/vz/template/cache"
DOWNLOAD_LATEST="0"
START_VM="0"
DISK_INTERFACE="scsi0"
USB_VENDOR_ID=""
USB_PRODUCT_ID=""
USB3="1"

usage() {
  cat <<'EOF'
Create a Proxmox VE VM for eWeLink CUBE OS.

Usage:
  pve-create-cube-os.sh [options]

Options:
  --image PATH               Use a local extracted .vmdk image.
  --download-latest          Download the latest sdcard.vmdk.xz from GitHub releases.
  --download-dir DIR         Directory for downloaded/extracted images.
  --vmid ID                  VM ID. Default: 950
  --name NAME                VM name. Default: cube-os
  --memory MB                Memory in MB. Default: 4096
  --cores N                  CPU cores. Default: 2
  --bridge NAME              Proxmox bridge. Default: vmbr0
  --storage NAME             Target VM disk storage. Default: local-lvm
  --efi-storage NAME         EFI disk storage. Default: same as --storage
  --cpu TYPE                 CPU type. Default: host
  --machine TYPE             Machine type. Default: q35
  --disk-interface NAME      Boot disk slot. Default: scsi0
  --usb VID:PID              Add a USB device by vendor/product ID.
  --usb2                     Attach USB device as USB2 instead of USB3.
  --start                    Start the VM after creation.
  -h, --help                 Show this help.

Examples:
  pve-create-cube-os.sh --image /root/sdcard.vmdk
  pve-create-cube-os.sh --download-latest --storage local-lvm --efi-storage local-lvm
  pve-create-cube-os.sh --download-latest --usb 10c4:ea60 --start
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        IMAGE_PATH="${2:-}"
        shift 2
        ;;
      --download-latest)
        DOWNLOAD_LATEST="1"
        shift
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
      --start)
        START_VM="1"
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

validate_args() {
  [[ -n "$EFI_STORAGE" ]] || EFI_STORAGE="$STORAGE"
  [[ "$DOWNLOAD_LATEST" == "1" || -n "$IMAGE_PATH" ]] || fail "Use --image PATH or --download-latest"
  [[ "$DOWNLOAD_LATEST" == "0" || -z "$IMAGE_PATH" ]] || fail "Use either --image or --download-latest, not both"
  [[ "$VMID" =~ ^[0-9]+$ ]] || fail "--vmid must be numeric"
  [[ "$MEMORY" =~ ^[0-9]+$ ]] || fail "--memory must be numeric"
  [[ "$CORES" =~ ^[0-9]+$ ]] || fail "--cores must be numeric"
  [[ "$DISK_INTERFACE" =~ ^(scsi|sata|virtio)[0-9]+$ ]] || fail "--disk-interface must look like scsi0, sata0, or virtio0"

  if [[ -n "$USB_VENDOR_ID" || -n "$USB_PRODUCT_ID" ]]; then
    [[ "$USB_VENDOR_ID" =~ ^[[:xdigit:]]{4}$ ]] || fail "--usb vendor ID must be 4 hex chars"
    [[ "$USB_PRODUCT_ID" =~ ^[[:xdigit:]]{4}$ ]] || fail "--usb product ID must be 4 hex chars"
  fi
}

ensure_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Run this script as root on the Proxmox host"
}

ensure_storage_exists() {
  pvesm status | awk '{print $1}' | grep -Fx "$1" >/dev/null 2>&1 || fail "Storage not found in Proxmox: $1"
}

ensure_bridge_exists() {
  ip link show "$BRIDGE" >/dev/null 2>&1 || fail "Network bridge not found: $BRIDGE"
}

ensure_vmid_unused() {
  qm status "$VMID" >/dev/null 2>&1 && fail "VMID $VMID already exists"
}

download_latest_image() {
  require_command curl
  require_command xz

  mkdir -p "$DOWNLOAD_DIR"

  local api_url="https://api.github.com/repos/${REPO}/releases/latest"
  local release_json
  local asset_url
  local archive_path
  local extracted_path

  log "Resolving latest CUBE OS release from GitHub"
  release_json="$(curl -fsSL "$api_url")"
  asset_url="$(printf '%s' "$release_json" | grep -Eo 'https://[^"]+/sdcard\.vmdk\.xz' | head -n1)"
  [[ -n "$asset_url" ]] || fail "Could not find ${DEFAULT_ARCHIVE_NAME} in the latest release"

  archive_path="${DOWNLOAD_DIR}/${DEFAULT_ARCHIVE_NAME}"
  extracted_path="${DOWNLOAD_DIR}/${DEFAULT_IMAGE_NAME}"

  log "Downloading ${DEFAULT_ARCHIVE_NAME}"
  curl -fL "$asset_url" -o "$archive_path"

  log "Extracting ${DEFAULT_ARCHIVE_NAME}"
  rm -f "$extracted_path"
  xz -dkf "$archive_path"

  [[ -f "$extracted_path" ]] || fail "Extraction failed: ${extracted_path} not found"
  IMAGE_PATH="$extracted_path"
}

create_vm() {
  log "Creating VM ${VMID} (${NAME})"
  qm create "$VMID" \
    --name "$NAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu "$CPU_TYPE" \
    --machine "$MACHINE" \
    --bios ovmf \
    --scsihw virtio-scsi-pci \
    --agent enabled=0 \
    --net0 "virtio,bridge=${BRIDGE}"

  qm set "$VMID" --efidisk0 "${EFI_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

  log "Importing disk from ${IMAGE_PATH}"
  qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" --format raw

  qm set "$VMID" --"${DISK_INTERFACE}" "${STORAGE}:vm-${VMID}-disk-0"
  qm set "$VMID" --boot "order=${DISK_INTERFACE}"
  qm set "$VMID" --serial0 socket --vga serial0
}

attach_usb_if_requested() {
  if [[ -n "$USB_VENDOR_ID" && -n "$USB_PRODUCT_ID" ]]; then
    log "Attaching USB device ${USB_VENDOR_ID}:${USB_PRODUCT_ID}"
    qm set "$VMID" --usb0 "host=${USB_VENDOR_ID}:${USB_PRODUCT_ID},usb3=${USB3}"
  fi
}

start_vm_if_requested() {
  if [[ "$START_VM" == "1" ]]; then
    log "Starting VM ${VMID}"
    qm start "$VMID"
  fi
}

print_summary() {
  cat <<EOF

CUBE OS VM created successfully.

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

Notes:
  - CUBE OS expects UEFI boot; this script uses OVMF and disables pre-enrolled keys.
  - Bridged networking is recommended so LAN discovery and cube.local work properly.
  - If you need Zigbee, pass a dongle with --usb VID:PID or add it later in the Proxmox UI.
EOF
}

main() {
  parse_args "$@"
  validate_args
  ensure_root

  require_command qm
  require_command pvesm
  require_command ip

  ensure_storage_exists "$STORAGE"
  ensure_storage_exists "$EFI_STORAGE"
  ensure_bridge_exists
  ensure_vmid_unused

  if [[ "$DOWNLOAD_LATEST" == "1" ]]; then
    download_latest_image
  fi

  [[ -f "$IMAGE_PATH" ]] || fail "Image not found: $IMAGE_PATH"

  create_vm
  attach_usb_if_requested
  start_vm_if_requested
  print_summary
}

main "$@"

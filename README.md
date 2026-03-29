# CUBE OS Proxmox VE Script

This repository contains a Bash script for creating an [eWeLink CUBE OS](https://github.com/eWeLinkCUBE/CUBE-OS) virtual machine on a Proxmox VE host.

The script:

- Creates a new Proxmox VM configured for UEFI boot
- Imports a CUBE OS `.vmdk` disk image
- Supports local images, local archives, GitHub release downloads, or a custom download URL
- Can guide you through setup interactively
- Shows visible step-by-step progress during provisioning
- Can attach a USB device such as a Zigbee dongle
- Can start the VM automatically after provisioning

## Files

- `pve-create-cube-os.sh` - Creates and configures the VM on a Proxmox host

## Requirements

Run this script directly on a Proxmox VE host as `root`.

Required tools:

- `qm`
- `pvesm`
- `ip`

Additional tools needed when using `--download-latest`, `--release`, `--download-url`, or `--archive`:

- `curl`
- `xz`

Optional for `--list-usb`:

- `lsusb`

## What It Creates

By default, the script creates a VM with:

- The next available Proxmox VM ID
- Name `cube-os`
- `4096` MB RAM
- `2` CPU cores
- Network bridge `vmbr0`
- Disk storage on the first Proxmox storage that supports VM images
- CPU type `host`
- Machine type `q35`
- Boot disk on `sata0`
- OVMF / UEFI firmware with an EFI disk
- Standard Proxmox VGA console

## Quick Start

Make the script executable:

```bash
chmod +x pve-create-cube-os.sh
```

Create a VM from a local image:

```bash
sudo ./pve-create-cube-os.sh --image /root/sdcard.vmdk
```

Download the latest image from GitHub and create the VM:

```bash
sudo ./pve-create-cube-os.sh --download-latest --yes
```

Download the latest image, attach a USB device, and start the VM:

```bash
sudo ./pve-create-cube-os.sh --download-latest --usb 10c4:ea60 --start
```

Run the script directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/wardmatter/CUBE-OS-PVE-Scripts/main/pve-create-cube-os.sh | bash -s -- --download-latest --storage local --efi-storage local --disk-interface sata0 --bridge vmbr0 --start
```

Launch the guided setup:

```bash
sudo ./pve-create-cube-os.sh --interactive
```

When `whiptail` is available, interactive mode opens a Proxmox helper-style menu with `default` and `advanced` setup paths. Without `whiptail`, it falls back to numbered text-based selectors so you can still choose storage, bridge, release source, and other VM options.

Preview the resolved configuration without making changes:

```bash
sudo ./pve-create-cube-os.sh --download-latest --dry-run --show-config
```

## Usage

```bash
./pve-create-cube-os.sh [options]
```

### Options

| Option | Description | Default |
| --- | --- | --- |
| `--image PATH` | Use a local extracted `.vmdk` image | none |
| `--archive PATH` | Use a local `.vmdk.xz` archive and extract it first | none |
| `--download-latest` | Download the latest `sdcard.vmdk.xz` release from GitHub | off |
| `--release TAG` | Download a specific GitHub release tag | `latest` |
| `--download-url URL` | Download a `.vmdk.xz` archive from a custom URL | none |
| `--download-dir DIR` | Directory used for downloaded and extracted images | `/var/lib/vz/template/cache` |
| `--vmid ID` | Proxmox VM ID | next available ID |
| `--name NAME` | VM name | `cube-os` |
| `--memory MB` | Memory in MB | `4096` |
| `--cores N` | Number of CPU cores | `2` |
| `--bridge NAME` | Proxmox network bridge | `vmbr0` |
| `--storage NAME` | Target storage for the imported disk | first image-capable storage |
| `--efi-storage NAME` | Storage for the EFI disk | same as `--storage` |
| `--cpu TYPE` | Proxmox CPU type | `host` |
| `--machine TYPE` | Proxmox machine type | `q35` |
| `--disk-interface NAME` | Boot disk slot such as `scsi0`, `sata0`, or `virtio0` | `sata0` |
| `--usb VID:PID` | Attach a USB device by vendor/product ID | none |
| `--usb2` | Attach the USB device as USB 2.0 instead of USB 3.0 | USB 3.0 |
| `--usb3` | Force USB 3.0 passthrough | USB 3.0 |
| `--interactive` | Run a guided setup with menus or numbered prompts | off |
| `--yes` | Skip the final confirmation prompt | off |
| `--start` | Start the VM after creation | off |
| `--dry-run` | Show the planned work without creating the VM | off |
| `--show-config` | Print the resolved configuration and exit | off |
| `--keep-failed-vm` | Do not print cleanup guidance after a failed run | off |
| `--list-storage` | List available storage targets and exit | off |
| `--list-bridges` | List bridge interfaces and exit | off |
| `--list-usb` | List USB devices with `lsusb` and exit | off |
| `--no-color` | Disable ANSI colors in output | off |
| `--verbose` | Print commands before running them | off |
| `-h`, `--help` | Show help output | n/a |

## Examples

Create a VM using a local disk image:

```bash
sudo ./pve-create-cube-os.sh --image /root/sdcard.vmdk --yes
```

Use a custom VM ID and storage:

```bash
sudo ./pve-create-cube-os.sh \
  --download-latest \
  --vmid 951 \
  --name cube-os-test \
  --storage local \
  --efi-storage local \
  --yes
```

Use a different bridge and more resources:

```bash
sudo ./pve-create-cube-os.sh \
  --download-latest \
  --bridge vmbr1 \
  --memory 8192 \
  --cores 4 \
  --yes
```

Pass through a Zigbee USB dongle:

```bash
sudo ./pve-create-cube-os.sh --download-latest --usb 10c4:ea60
```

Use a local compressed archive:

```bash
sudo ./pve-create-cube-os.sh --archive /root/sdcard.vmdk.xz --yes
```

Inspect your Proxmox environment before choosing values:

```bash
sudo ./pve-create-cube-os.sh --list-storage
sudo ./pve-create-cube-os.sh --list-bridges
sudo ./pve-create-cube-os.sh --list-usb
```

## How It Works

The script performs these checks and actions:

1. Validates the provided arguments
2. Verifies it is running as `root`
3. Auto-selects the next free VM ID unless you provide one
4. Confirms the Proxmox storage target exists
5. Confirms the network bridge exists
6. Confirms the VM ID is unused
7. Optionally downloads or extracts the CUBE OS image
8. Prints the resolved configuration and asks for confirmation
9. Creates a new Proxmox VM
10. Imports the disk image into the selected storage
11. Configures the imported disk as the boot disk
12. Optionally attaches a USB device
13. Optionally starts the VM

## After Provisioning

If you did not use `--start`, start the VM manually:

```bash
qm start <vmid>
```

Then:

1. Open the VM console in Proxmox and wait for CUBE OS to finish booting
2. Find the VM's IP address from your router, Proxmox, or console output
3. Open `http://<cube-ip>/` or `http://cube.local`

## Notes

- CUBE OS is configured here for UEFI boot using OVMF.
- The script disables pre-enrolled EFI keys.
- Bridged networking is recommended for local discovery and `cube.local` access.
- `sata0` is the safest boot disk default for the current CUBE OS Proxmox image.
- The script now auto-selects the first storage that supports VM images, because many Proxmox hosts use `local` for ISOs/templates only.
- USB passthrough can be used for Zigbee or similar adapters.
- You must choose exactly one image source: `--image`, `--archive`, `--download-latest` / `--release`, or `--download-url`.
- With no arguments on a TTY, the script drops into guided interactive mode.

## Troubleshooting

### `Run this script as root on the Proxmox host`

Run the script with `sudo` or as the `root` user on the Proxmox node.

### `Storage not found in Proxmox`

Verify the storage name with:

```bash
pvesm status
```

### `Network bridge not found`

Verify the bridge name with:

```bash
ip link show
```

### `VMID <id> already exists`

Choose a different VM ID with `--vmid`.

### Image download or extraction fails

Check:

- Internet connectivity from the Proxmox host
- GitHub access from the host
- Free space in the download directory
- That `curl` and `xz` are installed

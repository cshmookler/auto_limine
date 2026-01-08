#!/usr/bin/env bash

# Utilities
remove_prefix_and_postfix() {
    VALUE=$1
    PREFIX=$2
    POSTFIX=$3
    VALUE=${VALUE#"$PREFIX"}
    echo ${VALUE%"$POSTFIX"}
}
vertical_sep() {
    printf '%0.s-' $(seq 1 $(tput cols))
}
greentext() {
    echo -e "\e[32;1m$1\e[0m"
}
yellowtext() {
    echo -e "\e[33;1m$1\e[0m"
}
redtext() {
    echo -e "\e[31;1m$1\e[0m"
}

error() {
    redtext "Error: $1"
    exit 1
}

success() {
    greentext "Success"
    exit 0
}

# Program name and version
NAME=auto_limine
VERSION=20250222

# Positional Arguments
PART=''

# Options
LABEL='Arch Linux'
INSTALL=true

# Proper Usage
usage() {
    echo "$NAME (version: $VERSION)"
    echo "Automatic installer/uninstaller for Limine (https://limine-bootloader.org/)"
    echo ""
    echo "Usage: $NAME <boot partition> [options]"
    echo "Options:"
    echo "  -l, --label <label>  The label shown in the boot menu"
    echo "                       (default: 'Arch Linux') (ignored if the --uninstall option is enabled)"
    echo "  -u, --uninstall      Uninstall an existing installation"
    echo "  -h, --help           Show this help menu and quit"
    echo ""
    echo "Examples:"
    echo "  $NAME /dev/sda1 -l 'Custom Arch Linux'  # install"
    echo "  $NAME /dev/sda1 -u                      # uninstall"
}

error_with_usage_and_exit() {
    redtext "$1"
    echo ""
    usage
    exit 1
}

# Parse Arguments
if test -z "$1"; then
    error_with_usage_and_exit "Target partition not given"
fi
while test "$#" -gt 0; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            shift
            ;;
        -l|--label)
            LABEL="$2"
            if test -z "$LABEL"; then
                error_with_usage_and_exit "The given boot entry label must have at least one character"
            fi
            shift
            shift
            ;;
        -u|--uninstall)
            INSTALL=false
            shift
            ;;
        *)
            if test -n "$PART"; then
                error_with_usage_and_exit "Multiple boot partitions given"
            fi
            PART="$1"
            if test -z "$PART"; then
                error_with_usage_and_exit "Invalid boot partition"
            fi
            shift
            ;;
    esac
done

# Verify that a partition was given.
if test -z "$PART"; then
    error_with_usage_and_exit "Non-existent boot partition"
fi

# Get the associated disk, mount point, and UUID of the given partition.
if ! DISK=$(lsblk -npdo pkname "$PART") || test -z "$DISK"; then
    error_with_usage_and_exit "Failed to get the disk associated with the given boot partition"
fi
if ! MOUNT=$(lsblk -o mountpoint -nr "$PART"); then
    error_with_usage_and_exit "Failed to get the mountpoint of the given boot partition"
fi
if ! UUID=$(lsblk -no partuuid "$PART"); then
    error_with_usage_and_exit "Failed to get UUID of the given boot partition"
fi

LIMINE_DIR="$MOUNT/limine"
LIMINE_CONF="$LIMINE_DIR/limine.conf"
UNINSTALL_DATA_FILE="$LIMINE_DIR/uninstall_data"

PACMAN_HOOK_DIR="/etc/pacman.d/hooks"
LIMINE_HOOK_PATH="$PACMAN_HOOK_DIR/limine_upgrade.hook"

UEFI="/sys/firmware/efi/fw_platform_size"
PTTYPE=$(lsblk -ndo pttype "$DISK")

install() {
    # Define boot entry labels.
    BOOT_LABEL_LINUX="$LABEL (linux)"
    BOOT_LABEL_LINUX_LTS="$LABEL (linux-lts)"

    # Check which kernel is installed.
    unset HAS_LINUX
    unset HAS_LINUX_LTS
    if pacman -Q linux; then
        HAS_LINUX="1"
    fi
    if pacman -Q linux-lts; then
        HAS_LINUX_LTS="1"
    fi

    if test -z "$HAS_LINUX$HAS_LINUX_LTS"; then
        error "Either linux or linux-lts must be installed"
    fi
    
    # Define the Limine configuration file
    limine_conf() {
        ROOT_PART_UUID=$(findmnt / -no uuid) || error "Failed to find the UUID of the partition containing the root filesystem"

        echo "timeout: 0"

        if test -n "$HAS_LINUX"; then
            echo ""
            echo "/$BOOT_LABEL_LINUX"
            echo "    protocol: linux"
            echo "    kernel_path: boot():/vmlinuz-linux"
            echo "    kernel_cmdline: root=UUID=$ROOT_PART_UUID rw quiet"
            echo "    module_path: boot():/initramfs-linux.img"
        fi

        if test -n "$HAS_LINUX_LTS"; then
            echo ""
            echo "/$BOOT_LABEL_LINUX_LTS"
            echo "    protocol: linux"
            echo "    kernel_path: boot():/vmlinuz-linux-lts"
            echo "    kernel_cmdline: root=UUID=$ROOT_PART_UUID rw quiet"
            echo "    module_path: boot():/initramfs-linux-lts.img"
        fi
    }

    # Create the Limine boot directory (contains the boot loader and Limine configuration file)
    if ! test -e "$LIMINE_DIR"; then
        mkdir -p "$LIMINE_DIR" || error "Failed to create a directory for Limine on the boot partition"
    fi

    # Create the Limine configuration file
    vertical_sep
    echo "$LIMINE_CONF"
    vertical_sep
    limine_conf | tee "$LIMINE_CONF" || error "Failed to create the Limine configuration file"
    vertical_sep

    # Define the Limine upgrade hook (updates the boot loader when Limine is upgraded)
    limine_hook() {
        echo '[Trigger]'
        echo 'Operation = Install'
        echo 'Operation = Upgrade'
        echo 'Type = Package'
        echo 'Target = limine'
        echo
        echo '[Action]'
        echo 'Description = Updating boot loader after upgrade...'
        echo 'When = PostTransaction'
        echo "Exec = $1"
    }

    # Create the Pacman hook directory
    if ! test -e "$PACMAN_HOOK_DIR"; then
        mkdir -p "$PACMAN_HOOK_DIR" || error "Failed to create the Pacman hook directory"
    fi

    if test -e "$UEFI"; then
        # Create the boot entry
        if test -n "$HAS_LINUX"; then
            efibootmgr --create --disk "$DISK" --loader "/limine/BOOTX64.EFI" --label "$BOOT_LABEL_LINUX" --unicode || error "Failed to create the boot entry for Linux"
        fi
        if test -n "$HAS_LINUX_LTS"; then
            efibootmgr --create --disk "$DISK" --loader "/limine/BOOTX64.EFI" --label "$BOOT_LABEL_LINUX_LTS" --unicode || error "Failed to create the boot entry for Linux LTS"
        fi
        # Install the boot loader
        cp "/usr/share/limine/BOOTX64.EFI" "$LIMINE_DIR" || error "Failed to install the UEFI boot loader"
        # Create the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/BOOTX64.EFI' '$LIMINE_DIR'" | tee "$LIMINE_HOOK_PATH" || error "Failed to create the upgrade hook for Limine"
        vertical_sep
    elif test "$PTTYPE" = "gpt"; then
        # Extract the partition number from the partition name
        PART_NUM=$(echo "$PART" | grep -oE '[0-9]+$')
        if test -z "$PART_NUM"; then
            error "Failed to extract the partition number from '$PART'"
        fi
        # Install the stage 1 and 2 boot loaders on an MBR partition table
        limine bios-install --uninstall-data-file"$UNINSTALL_DATA_FILE" "$DISK" "$PART_NUM" || error "Failed to install the stage 1 and stage 2 boot loaders"
    elif test "$PTTYPE" = "dos"; then
        # Install the stage 1 and 2 boot loaders on a GPT partition table
        limine bios-install --uninstall-data-file"$UNINSTALL_DATA_FILE" "$DISK" "$" || error "Failed to install the stage 1 and stage 2 boot loaders"
    else
        error "Unrecognized partition table type: '$PTTYPE' (must be gpt or dos)"
    fi

    if ! test -e "$UEFI"; then
        # Install the stage 3 boot loader for BIOS
        cp "/usr/share/limine/limine-bios.sys" "$LIMINE_DIR" || error "Failed to install the stage 3 boot loader"
        # the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/limine-bios.sys' '$LIMINE_DIR' && '/usr/bin/limine' bios-install '$DISK'" | tee "$LIMINE_HOOK_PATH" || error "Failed to create the upgrade hook for Limine"
        vertical_sep
    fi
}

uninstall() {
    # Remove the upgrade hook for Limine
    if test -e "$LIMINE_HOOK_PATH"; then
        rm "$LIMINE_HOOK_PATH" || error "Failed to delete the upgrade hook for Limine"
    fi
    if test -e "$UEFI"; then
        # Delete all boot entries on the given partition
        efibootmgr | grep -e "$UUID" | while read -a boot_order; do
            if ! BOOT_NUM=$(remove_prefix_and_postfix "${boot_order[0]}" 'Boot' '*'); then
                error "Failed to get the boot # for a boot entry"
            fi
            efibootmgr --bootnum "$BOOT_NUM" --delete-bootnum || error "Failed to delete a boot entry"
        done || error "Failed to list and delete all boot entries"
    else
        if ! test -e "$UNINSTALL_DATA_FILE"; then
            error "Failed to find the uninstallation data for Limine"
        fi
        # Delete the associated boot entry on the disk of the given partition.
        limine bios-install --uninstall --uninstall-data-file"$UNINSTALL_DATA_FILE" "$DISK" || error "Failed to uninstall the stage 1 and stage 2 boot loaders"
    fi
    # Remove the Limine directory (contains the boot loader, uninstallation data, and Limine configuration file).
    if test -e "$LIMINE_DIR"; then
        rm -rf "$LIMINE_DIR" || error "Failed to delete the Limine directory on the boot partition"
    fi
}

if $INSTALL; then
    install
else
    uninstall
fi

success

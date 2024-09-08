#!/usr/bin/bash

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

# Program name and version
NAME=auto_limine
VERSION=20240907

# Error codes
E_SUCCESS=0
E_PART_NOT_GIVEN=1
E_PART_MULTIPLE_GIVEN=2
E_PART_MISSING=3
E_PART_INVALID=4
E_LABEL_INVALID=5
E_LIMINE_DIR_CREATE=6
E_LIMINE_DIR_DELETE=7
E_LIMINE_CONFIG_CREATE=8
E_PACMAN_HOOK_DIR_CREATE=9
E_LIMINE_HOOK_CREATE=10
E_LIMINE_HOOK_DELETE=11
E_UEFI_BOOT_LOADER_INSTALL=12
E_UEFI_BOOT_ENTRY_CREATE=13
E_UEFI_BOOT_ENTRY_DELETE=14
E_BIOS_STAGE_1_INSTALL=15
E_BIOS_STAGE_1_UNINSTALL=16
E_BIOS_STAGE_2_INSTALL=17
E_LIMINE_UNINSTALL_DATA_MISSING=18

# Keep track of the first reported error
FIRST_ERROR=$E_SUCCESS

# Error reporting
perror() {
    if test $FIRST_ERROR -eq 0; then
        FIRST_ERROR="$1"
    fi
    case "$1" in
        $E_SUCCESS)
            greentext "Success"
            ;;
        $E_PART_NOT_GIVEN)
            redtext "Error: Target partition not given"
            ;;
        $E_PART_MULTIPLE_GIVEN)
            redtext "Error: Multiple boot partitions given"
            ;;
        $E_PART_MISSING)
            redtext "Error: Non-existent boot partition"
            ;;
        $E_PART_INVALID)
            redtext "Error: Invalid boot partition"
            ;;
        $E_LABEL_INVALID)
            redtext "Error: Invalid boot label"
            ;;
        $E_LIMINE_DIR_CREATE)
            redtext "Error: Failed to create a directory for Limine on the boot partition"
            ;;
        $E_LIMINE_DIR_DELETE)
            redtext "Error: Failed to delete the Limine directory on the boot partition"
            ;;
        $E_LIMINE_CONFIG_CREATE)
            redtext "Error: Failed to create the Limine configuration file"
            ;;
        $E_PACMAN_HOOK_DIR_CREATE)
            redtext "Error: Failed to create the Pacman hook directory"
            ;;
        $E_LIMINE_HOOK_CREATE)
            redtext "Error: Failed to create the upgrade hook for Limine"
            ;;
        $E_LIMINE_HOOK_DELETE)
            redtext "Error: Failed to delete the upgrade hook for Limine"
            ;;
        $E_UEFI_BOOT_LOADER_INSTALL)
            redtext "Error: Failed to install the boot loader"
            ;;
        $E_UEFI_BOOT_ENTRY_CREATE)
            redtext "Error: Failed to create the boot entry"
            ;;
        $E_UEFI_BOOT_ENTRY_DELETE)
            redtext "Error: Failed to delete the boot entry"
            ;;
        $E_BIOS_STAGE_1_INSTALL)
            redtext "Error: Failed to install the stage 1 boot loader"
            ;;
        $E_BIOS_STAGE_1_UNINSTALL)
            redtext "Error: Failed to uninstall the stage 1 boot loader"
            ;;
        $E_BIOS_STAGE_2_INSTALL)
            redtext "Error: Failed to install the stage 2 boot loader"
            ;;
        $E_LIMINE_UNINSTALL_DATA_MISSING)
            redtext "Error: Failed to find the uninstallation data for Limine"
            ;;
        *)
            redtext "Error: Unknown"
            ;;
    esac
}
perror_and_exit() {
    perror "$1"
    exit "$1"
}

# Positional Arguments
PART=''

# Options
LABEL='Arch Linux'
INSTALL=true

# Proper Usage
usage() {
    perror "$1"
    echo
    echo "$NAME (version: $VERSION)"
    echo "Automatic installer/uninstaller for Limine (https://limine-bootloader.org/)"
    echo
    echo "Usage: $NAME <boot partition> [options]"
    echo "Options:"
    echo "  -l, --label <label>  The label shown in the boot menu"
    echo "                       (default: 'Arch Linux') (ignored if the --uninstall option is enabled)"
    echo "  -u, --uninstall      Uninstall an existing installation"
    echo
    echo "Examples:"
    echo "  $NAME /dev/sda1 -l 'Custom Arch Linux'  # install"
    echo "  $NAME /dev/sda1 -u                      # uninstall"
}
usage_and_exit() {
    usage "$1"
    exit "$1" 
}

# Parse Arguments
if test -z "$1"; then
    usage_and_exit $E_PART_NOT_GIVEN
fi
while test "$#" -gt 0; do
    case "$1" in
        -l|--label)
            LABEL="$2"
            if test -z "$LABEL"; then
                usage_and_exit $E_LABEL_INVALID
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
                usage_and_exit $E_PART_MULTIPLE_GIVEN
            fi
            PART="$1"
            if test -z "$PART"; then
                usage_and_exit $E_PART_INVALID
            fi
            shift
            ;;
    esac
done

# Verify that a partition was given.
if test -z "$PART"; then
    usage_and_exit $E_PART_MISSING
fi

# Get the associated disk, mount point, and UUID of the given partition.
if ! DISK=$(lsblk -npdo pkname "$PART") || test -z "$DISK"; then
    usage_and_exit $E_PART_INVALID
fi
if ! MOUNT=$(lsblk -o mountpoint -nr "$PART"); then
    usage_and_exit $E_PART_INVALID
fi
if ! UUID=$(lsblk -no partuuid "$PART"); then
    usage_and_exit $E_PART_INVALID
fi

LIMINE_DIR="$MOUNT/limine"
LIMINE_CONF="$LIMINE_DIR/limine.conf"
UNINSTALL_DATA_FILE="$LIMINE_DIR/uninstall_data"

PACMAN_HOOK_DIR="/etc/pacman.d/hooks"
LIMINE_HOOK_PATH="$PACMAN_HOOK_DIR/limine_upgrade.hook"

UEFI="/sys/firmware/efi/fw_platform_size"

install() {
    # Define the Limine configuration file
    limine_conf() {
        echo "timeout: 0"
        echo
        echo "/$LABEL"
        echo "    protocol: linux"
        echo "    kernel_path: boot():/vmlinuz-linux"
        echo "    kernel_cmdline: root=UUID=$(findmnt / -no uuid) rw quiet"
        echo "    module_path: boot():/initramfs-linux.img"
    }

    # Create the Limine boot directory (contains the boot loader and Limine configuration file)
    if ! test -e "$LIMINE_DIR"; then
        mkdir -p "$LIMINE_DIR" || perror $E_LIMINE_DIR_CREATE
    fi

    # Create the Limine configuration file
    vertical_sep
    echo "$LIMINE_CONF"
    vertical_sep
    limine_conf | tee "$LIMINE_CONF" || perror $E_LIMINE_CONFIG_CREATE
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
        mkdir -p "$PACMAN_HOOK_DIR" || perror $E_PACMAN_HOOK_DIR_CREATE
    fi

    if test -e "$UEFI"; then
        # Create the boot entry
        efibootmgr --create --disk "$DISK" --loader "/limine/BOOTX64.EFI" --label "$LABEL" --unicode || perror $E_UEFI_BOOT_ENTRY_CREATE
        # Install the boot loader
        cp "/usr/share/limine/BOOTX64.EFI" "$LIMINE_DIR" || perror $E_UEFI_BOOT_LOADER_INSTALL
        # Create the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/BOOTX64.EFI' '$LIMINE_DIR'" | tee "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_CREATE
        vertical_sep
    else
        # Install the stage 1 boot loader
        limine bios-install --uninstall-data-file"$UNINSTALL_DATA_FILE" "$DISK" || perror $E_BIOS_STAGE_1_INSTALL
        # Install the stage 2 boot loader
        cp "/usr/share/limine/limine-bios.sys" "$LIMINE_DIR" || perror $E_BIOS_STAGE_2_INSTALL
        # the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/limine-bios.sys' '$LIMINE_DIR' && '/usr/bin/limine' bios-install '$DISK'" | tee "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_CREATE
        vertical_sep
    fi
}

uninstall() {
    # Remove the upgrade hook for Limine
    if test -e "$LIMINE_HOOK_PATH"; then
        rm "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_DELETE
    fi
    if test -e "$UEFI"; then
        # Delete all boot entries on the given partition
        efibootmgr | grep -e "$UUID" | while read -a boot_order; do
            if ! BOOT_NUM=$(remove_prefix_and_postfix "${boot_order[0]}" 'Boot' '*'); then
                perror $E_UEFI_BOOT_ENTRY_DELETE
            fi
            efibootmgr --bootnum "$BOOT_NUM" --delete-bootnum || perror $E_UEFI_BOOT_ENTRY_DELETE
        done || perror $E_UEFI_BOOT_ENTRY_DELETE
    else
        if ! test -e "$UNINSTALL_DATA_FILE"; then
            perror $E_LIMINE_UNINSTALL_DATA_MISSING
        fi
        # Delete the associated boot entry on the disk of the given partition.
        limine bios-install --uninstall --uninstall-data-file"$UNINSTALL_DATA_FILE" "$DISK" || perror $E_BIOS_STAGE_1_UNINSTALL
    fi
    # Remove the Limine directory (contains the boot loader, uninstallation data, and Limine configuration file).
    if test -e "$LIMINE_DIR"; then
        rm -rf "$LIMINE_DIR" || perror $E_LIMINE_DIR_DELETE
    fi
}

if $INSTALL; then
    install
else
    uninstall
fi

perror_and_exit $FIRST_ERROR

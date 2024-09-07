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
VERSION=20240823

# Error codes
E_SUCCESS=0
E_PART_NOT_GIVEN=1
E_PART_MULTIPLE_GIVEN=2
E_PART_MISSING=3
E_PART_INVALID=4
E_LABEL_INVALID=5
E_CONFIG_SETUP_FAILED=6
E_BOOT_LOADER_INSTALL_FAILED=7
E_BOOT_ENTRY_CREATE_FAILED=8
E_CONFIG_REMOVE_FAILED=9
E_BOOT_LOADER_UNINSTALL_FAILED=10
E_BOOT_ENTRY_DELETE_FAILED=11
E_LIMINE_HOOK_SETUP_FAILED=12
E_LIMINE_HOOK_REMOVE_FAILED=13
E_LIMINE_DIR_FAILED=14
E_PACMAN_HOOK_DIR_FAILED=15

# Keep track of the first reported error
FIRST_ERROR=0

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
        $E_CONFIG_SETUP_FAILED)
            redtext "Error: Failed to create the limine configuration file"
            ;;
        $E_BOOT_LOADER_INSTALL_FAILED)
            redtext "Error: Failed to install the boot loader"
            ;;
        $E_BOOT_ENTRY_CREATE_FAILED)
            redtext "Error: Failed to create the boot entry"
            ;;
        $E_CONFIG_REMOVE_FAILED)
            redtext "Error: Failed to remove the limine configuration file"
            ;;
        $E_BOOT_LOADER_UNINSTALL_FAILED)
            redtext "Error: Failed to uninstall the boot loader"
            ;;
        $E_BOOT_ENTRY_DELETE_FAILED)
            redtext "Error: Failed to delete the boot entry"
            ;;
        $E_LIMINE_HOOK_SETUP_FAILED)
            redtext "Error: Failed to setup the upgrade hook for Limine"
            ;;
        $E_LIMINE_HOOK_REMOVE_FAILED)
            redtext "Error: Failed to remove the upgrade hook for Limine"
            ;;
        $E_LIMINE_DIR_FAILED)
            redtext "Error: Failed to create the Limine directory"
            ;;
        $E_PACMAN_HOOK_DIR_FAILED)
            redtext "Error: Failed to create the Pacman hook directory"
            ;;
        *)
            redtext "Error: Unknown"
            ;;
    esac
}
perror_and_exit() {
    perror "$1"
    exit $FIRST_ERROR
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

# Verify that 
if test -z "$PART"; then
    usage_and_exit $E_PART_MISSING
fi

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
        mkdir -p "$LIMINE_DIR" || perror $E_LIMINE_DIR_FAILED
    fi

    # Create the Limine configuration file
    vertical_sep
    echo "$LIMINE_CONF"
    vertical_sep
    limine_conf | tee "$LIMINE_CONF" || perror $E_CONFIG_SETUP_FAILED
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
        mkdir -p "$PACMAN_HOOK_DIR" || perror $E_PACMAN_HOOK_DIR_FAILED
    fi

    if test -e "$UEFI"; then
        # Create the boot entry
        efibootmgr --create --disk "$DISK" --loader "/limine/BOOTX64.EFI" --label "$LABEL" --unicode || perror $E_BOOT_ENTRY_CREATE_FAILED
        # Install the boot loader
        cp "/usr/share/limine/BOOTX64.EFI" "$LIMINE_DIR" || perror $E_BOOT_LOADER_INSTALL_FAILED
        # Setup the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/BOOTX64.EFI' '$LIMINE_DIR'" | tee "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_SETUP_FAILED
        vertical_sep
    else
        # Create the boot entry
        limine bios-install "$DISK" || perror $E_BOOT_ENTRY_CREATE_FAILED
        # Install the boot loader
        cp "/usr/share/limine/limine-bios.sys" "$LIMINE_DIR" || perror $E_BOOT_LOADER_INSTALL_FAILED
        # Setup the Limine configuration file
        vertical_sep
        echo "$LIMINE_HOOK_PATH"
        vertical_sep
        limine_hook "'/usr/bin/cp' '/usr/share/limine/limine-bios.sys' '$LIMINE_DIR' && '/usr/bin/limine' bios-install '$DISK'" | tee "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_SETUP_FAILED
        vertical_sep
    fi
}

uninstall() {
    # Remove the upgrade hook for Limine
    if test -e "$LIMINE_HOOK_PATH"; then
        rm "$LIMINE_HOOK_PATH" || perror $E_LIMINE_HOOK_REMOVE_FAILED
    fi
    # Remove the Limine directory (contains the boot loader and configuration file)
    if test -e "$LIMINE_DIR"; then
        rm -rf "$LIMINE_DIR" || perror $E_BOOT_LOADER_UNINSTALL_FAILED
    fi
    if test -e "$UEFI"; then
        # Delete all boot entries on the given partition
        efibootmgr | grep -e "$UUID" | while read -a boot_order; do
            if ! BOOT_NUM=$(remove_prefix_and_postfix "${boot_order[0]}" 'Boot' '*'); then
                perror $E_BOOT_ENTRY_DELETE_FAILED
            fi
            efibootmgr --bootnum "$BOOT_NUM" --delete-bootnum || perror $E_BOOT_ENTRY_DELETE_FAILED
        done || perror $E_BOOT_ENTRY_DELETE_FAILED
    else
        # Delete the associated boot entry on the disk of the given partition
        limine bios-install --uninstall "$DISK" || perror $E_BOOT_ENTRY_DELETE_FAILED
    fi
}

if $INSTALL; then
    install
else
    uninstall
fi

perror_and_exit $FIRST_ERROR

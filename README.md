# auto_limine

Automatically installs a boot loader ([Limine](https://limine-bootloader.org/)) on BIOS and UEFI systems.

## Usage

As root, execute the "auto_limine.sh" script with Bash. Provide the path to your boot directory as an argument.

```bash
bash auto_limine.sh /dev/sda1
```

To uninstall, provide the "-u" flag

```bash
bash auto_limine.sh /dev/sda1 -u
```

## TODO

- [ ] Add more options for customization of the boot loader.
- [ ] Improve the error reporting.

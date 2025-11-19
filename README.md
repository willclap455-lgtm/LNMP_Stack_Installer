# LNMP_Stack_Installer
This Bash Script sources the best repositories, downloads, and installs the latest software in the LNMP stack.

## Flipper Zero BadUSB Support
- Use the assets under `flipperzero/` to run the installer from a Flipper Zero acting as a BadUSB keyboard.
- Update `flipperzero/setup-lnmp-badusb.txt` with the correct sudo password (or remove the helper lines) and copy it to your device’s `badusb/` folder.
- The payload opens a terminal, downloads `setup-latest-nginx-mysql-php.sh` directly from GitHub, and executes it with every prompt auto-confirmed via `yes | sudo`.

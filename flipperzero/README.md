# Flipper Zero BadUSB Payload

This directory contains BadUSB payloads that make a Flipper Zero download and execute the existing `setup-latest-nginx-mysql-php.sh` installer on a Linux target.

## Payload Variants
- `setup-lnmp-badusb.txt`: Targets Ubuntu Desktop with GNOME by launching `CTRL+ALT+T` to open the terminal.
- `setup-lnmp-badusb-server.txt`: Targets Ubuntu Server (no GNOME) where a console or SSH session is already open; it types directly into the active shell.

## How It Works
- Desktop payload opens a terminal via `CTRL+ALT+T`, while the server payload simply ensures a clean prompt (`ENTER`, `clear`) before proceeding.
- Both payloads run `sudo -v` to cache elevated credentials (replace the placeholder password in the payload or delete those lines if the session already has sudo privileges).
- Downloads the latest script from GitHub into `/tmp`, marks it executable, and runs it with `yes | sudo` so every interactive prompt in the installer is answered with `y`.

## Usage
1. Open the payload that matches your target (`setup-lnmp-badusb.txt` for GNOME, `setup-lnmp-badusb-server.txt` for Ubuntu Server) and update the following to match your environment:
   - `PASSWORD_HERE` → replace with the target account’s sudo password, or remove the password line (and the preceding `sudo -v`) if you prefer to type it manually.
   - Optional: adjust `DEFAULT_DELAY`, individual `DELAY`s, or keyboard layout comments for non‑US layouts.
   - Optional: change `SCRIPT_URL` to point at a fork/branch if you are not using `origin/main`.
2. Copy the updated `.txt` file to your Flipper’s `badusb/` directory.
3. On the target machine:
   - Ensure it is logged in, has an active network connection, and the user can run `sudo`.
   - Plug in the Flipper, navigate to the payload, and press **Run**. Keep the terminal focused so keystrokes land correctly.
4. Watch the terminal; the LNMP installer will log progress exactly as if you ran the Bash script manually.

## Notes & Troubleshooting
- The GNOME payload assumes a US keyboard layout and GNOME’s default terminal shortcut. Adjust as needed for other environments (e.g., `CTRL ALT T` → `GUI R`, `gnome-terminal`, etc.).
- The server payload assumes you are already at a logged-in shell (local TTY or SSH). Make sure the console is focused so keystrokes land correctly.
- Because the payload pipes `yes` into the installer, it will accept every yes/no prompt. If you need granular control, remove the `yes |` portion and respond manually.
- If `curl` is missing on the target, add commands to install it before downloading the script.
- To run a locally modified installer, host it somewhere reachable (HTTPS, internal web server, etc.) and point `SCRIPT_URL` there.

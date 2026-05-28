# Meshcore Kiosk Tool

One-shot installer for running `meshcore_chat` as a fullscreen kiosk app on Raspberry Pi OS or Linux Mint.

The installer:

- installs or updates `meshcore_chat`
- detects a likely MeshCore USB serial device before installation
- configures a Python virtual environment
- configures GUI autostart
- patches the PyQt app for fullscreen startup
- patches the device selector to auto-connect the detected serial device
- creates a nightly `git pull` job at `00:00`
- reboots after the nightly update
- optionally sends a Pushover message after the device has rebooted successfully
- sends a Pushover install confirmation with hostname, app path, serial port, and timer state when Pushover is configured
- avoids duplicate kiosk starts by using one fixed autostart entry, disabling old Meshcore autostarts, and adding a runtime lock

## Quick Install

```bash
git clone https://github.com/robbyatbln/meshcore-kiosk-tool.git
cd meshcore-kiosk-tool
chmod +x install.sh
sudo ./install.sh
```

## Install With Pushover

Create a Pushover application first, then install with your app token and user key:

```bash
git clone https://github.com/robbyatbln/meshcore-kiosk-tool.git
cd meshcore-kiosk-tool
chmod +x install.sh
sudo PUSHOVER_APP_TOKEN="APP_TOKEN_HERE" PUSHOVER_USER_KEY="USER_KEY_HERE" ./install.sh
```

Optional device filter:

```bash
sudo PUSHOVER_APP_TOKEN="APP_TOKEN_HERE" PUSHOVER_USER_KEY="USER_KEY_HERE" PUSHOVER_DEVICE="phone" ./install.sh
```

After a successful nightly update and reboot, the device sends a Pushover notification.

## Override Serial Port

The installer detects common serial devices such as CP210x, CH340, FT232, `/dev/ttyUSB*`, and `/dev/ttyACM*`.

Override it manually if needed:

```bash
sudo MESHCORE_AUTO_PORT=/dev/ttyACM0 MESHCORE_AUTO_BAUD=115200 ./install.sh
```

You can combine that with Pushover:

```bash
sudo MESHCORE_AUTO_PORT=/dev/ttyACM0 PUSHOVER_APP_TOKEN="APP_TOKEN_HERE" PUSHOVER_USER_KEY="USER_KEY_HERE" ./install.sh
```

## After Install

Enable desktop autologin.

Raspberry Pi OS:

```bash
sudo raspi-config
```

Choose `System Options -> Boot / Auto Login -> Desktop Autologin`.

Linux Mint:

Open `Login Window` / `Anmeldefenster` and enable automatic login for the target user.

## Useful Commands

Test the app:

```bash
~/start_meshcore_chat.sh
```

Check the nightly update timer:

```bash
systemctl list-timers | grep meshcore
```

Read the nightly update log:

```bash
cat ~/meshcore_nightly_update.log
```

Run the nightly update manually:

```bash
sudo systemctl start meshcore-nightly-update.service
```

This manual test reboots the machine after the update.

Test Pushover directly:

```bash
sudo /usr/local/bin/meshcore-kiosk-send-pushover "Meshcore test" "Pushover works."
```

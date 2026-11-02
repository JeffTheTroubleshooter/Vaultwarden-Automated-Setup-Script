# Vaultwarden Automated Setup Script

Builds [Vaultwarden](https://github.com/dani-garcia/vaultwarden) from source with Rust and cargo (SQLite), installs the latest web vault, and sets it up as a systemd service.

## Automatic Install

```bash
bash vaultwarden-install.sh
```

The script asks for an install directory (default `/opt/vaultwarden`), a listen port (default `8000`), and whether to use HTTPS. If you choose HTTPS, it makes a self-signed certificate. When it finishes, open the address it prints, for example `https://<server-ip>:8000`.

Browsers only allow Vaultwarden's web vault over HTTPS or from `localhost`, so use HTTPS when you connect from another machine.

## Service

```bash
sudo systemctl status vaultwarden
sudo systemctl restart vaultwarden
sudo systemctl stop vaultwarden
```

Files are in `/opt/vaultwarden`, and your data is in `/opt/vaultwarden/data`. Back up the data folder.

## Uninstall

```bash
bash vaultwarden-install.sh uninstall
```

This removes the service and files, and can also remove the build packages and Rust if you choose to.

## Supported Distros

| Distro | Status |
|---|---|
| Fedora | Tested, works |
| Debian / Ubuntu (and Mint, Pop!_OS, Zorin, elementary) | Not tested, need feedback |
| RHEL / Rocky / AlmaLinux / CentOS | Not tested, need feedback |
| Arch / Manjaro / EndeavourOS / Garuda | Not tested, need feedback |
| openSUSE / SLES | Not tested, need feedback |
| Alpine | Not tested, need feedback |

If you try it on a distro that isn't tested, please open an issue and say how it went.

## Part of the Proxmox Homelab setup

This installer is used by [Proxmox-Homelab-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script), which creates an LXC for each app on a Proxmox host and runs this script inside it.

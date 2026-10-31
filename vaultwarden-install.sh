#!/usr/bin/env bash
#
# Vaultwarden installer / uninstaller (from source)
# Detects distro, installs Rust + build deps, clones vaultwarden,
# builds with cargo (sqlite), downloads the web vault, installs it,
# and creates a systemd service.
#
# Usage:
#   bash vaultwarden-install.sh            # install
#   bash vaultwarden-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/dani-garcia/vaultwarden.git"
DEFAULT_DIR="/opt/vaultwarden"
BUILD_DIR="/tmp/vaultwarden-src"
SERVICE_NAME="vaultwarden"
DEFAULT_PORT=8000

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest releases..."

  # Vaultwarden
  local vw_api="https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest"
  VW_LATEST=$(curl -fsSL "$vw_api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${VW_LATEST:-}" ]]; then
    ok "Latest Vaultwarden: $VW_LATEST"
  else
    warn "Could not query Vaultwarden releases (will use main)"
    VW_LATEST=""
  fi

  # Web vault
  local web_api="https://api.github.com/repos/dani-garcia/bw_web_builds/releases/latest"
  WEB_LATEST=$(curl -fsSL "$web_api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  WEB_URL=$(curl -fsSL "$web_api" 2>/dev/null | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.tar\.gz"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${WEB_LATEST:-}" ]]; then
    ok "Latest web vault: $WEB_LATEST"
  else
    warn "Could not query web vault releases (will use fallback)"
    WEB_LATEST=""
    WEB_URL="https://github.com/dani-garcia/bw_web_builds/releases/download/v2026.7.0/bw_web_v2026.7.0.tar.gz"
  fi

  echo
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git build-essential pkg-config libssl-dev libsqlite3-dev curl ca-certificates tar openssl
      ;;
    dnf)
      sudo dnf install -y \
        git gcc gcc-c++ make pkgconf-pkg-config openssl-devel sqlite-devel curl ca-certificates tar openssl
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git base-devel pkgconf openssl sqlite curl ca-certificates tar openssl
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git gcc gcc-c++ make pkg-config libopenssl-devel sqlite3-devel curl ca-certificates tar openssl
      ;;
    apk)
      sudo apk add --no-cache \
        git build-base pkgconf openssl-dev sqlite-dev curl ca-certificates tar openssl
      ;;
  esac

  ok "Build packages ready."
}

install_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    ok "Rust already installed: $(rustc --version)"
    return 0
  fi

  info "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  ok "Installed $(rustc --version)"
}

# ── build ──────────────────────────────────────────────────────────────────
build_vaultwarden() {
  info "Cloning vaultwarden..."
  rm -rf "$BUILD_DIR"
  if [[ -n "${VW_LATEST:-}" ]]; then
    info "Checking out release $VW_LATEST"
    git clone --depth 1 --branch "$VW_LATEST" "$REPO_URL" "$BUILD_DIR" ||       git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  else
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  fi
  cd "$BUILD_DIR"

  # make sure cargo is on PATH
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi

  info "Building with cargo (sqlite, release) — this can take several minutes..."
  cargo build --features sqlite --release

  [[ -x "$BUILD_DIR/target/release/vaultwarden" ]] || die "Build finished but binary not found."
  info "Build complete."
}

download_web_vault() {
  local url="${WEB_URL:-https://github.com/dani-garcia/bw_web_builds/releases/download/v2026.7.0/bw_web_v2026.7.0.tar.gz}"
  info "Downloading web vault: $url"
  local tmp="/tmp/bw_web.tar.gz"
  curl -fsSL -o "$tmp" -L "$url" || die "Web vault download failed."
  sudo mkdir -p "$INSTALL_DIR/web-vault"
  sudo tar -xzf "$tmp" -C "$INSTALL_DIR/web-vault" --strip-components=1
  rm -f "$tmp"
  ok "Web vault installed."
}

# ── install ────────────────────────────────────────────────────────────────
generate_cert() {
  info "Generating self-signed certificate..."
  sudo mkdir -p "$INSTALL_DIR/certs"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="127.0.0.1"
  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$INSTALL_DIR/certs/key.pem" \
    -out "$INSTALL_DIR/certs/cert.pem" \
    -subj "/CN=vaultwarden" \
    -addext "subjectAltName=IP:${ip},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
  sudo chmod 600 "$INSTALL_DIR/certs/key.pem"
  sudo chown -R "$USER:$USER" "$INSTALL_DIR/certs"
  ok "Certificate created: $INSTALL_DIR/certs/"
}

install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/web-vault"
  sudo cp "$BUILD_DIR/target/release/vaultwarden" "$INSTALL_DIR/vaultwarden"
  sudo chmod +x "$INSTALL_DIR/vaultwarden"

  local tls_line=""
  if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
    generate_cert
    tls_line="ROCKET_TLS={certs=\"$INSTALL_DIR/certs/cert.pem\",key=\"$INSTALL_DIR/certs/key.pem\"}"
  fi

  # env file for the service
  sudo tee "$INSTALL_DIR/vaultwarden.env" >/dev/null <<ENV
DATA_FOLDER=$INSTALL_DIR/data
WEB_VAULT_FOLDER=$INSTALL_DIR/web-vault
ROCKET_ADDRESS=0.0.0.0
ROCKET_PORT=$PORT
SIGNUPS_ALLOWED=$SIGNUPS_ALLOWED
${tls_line}
${DOMAIN:+DOMAIN=$DOMAIN}
ENV

  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/vaultwarden"
  [[ -x "$bin" ]] || die "vaultwarden binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Vaultwarden Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/vaultwarden.env
ExecStart=$bin
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes vault data)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Rust (rustup)?"; then
    if command -v rustup >/dev/null 2>&1; then
      rustup self uninstall -y || true
      ok "Rust removed."
    fi
  fi
  if ask_yn "Also remove build packages (gcc, openssl-devel, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y build-essential pkg-config libssl-dev libsqlite3-dev || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ make pkgconf-pkg-config openssl-devel sqlite-devel || true ;;
      pacman) sudo pacman -Rns --noconfirm base-devel pkgconf openssl sqlite || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ make pkg-config libopenssl-devel sqlite3-devel || true ;;
      apk)    sudo apk del build-base pkgconf openssl-dev sqlite-dev || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Vaultwarden uninstaller"
  echo "======================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Vaultwarden installer (from source)"
      echo "==================================="
      detect_distro
      check_latest
      install_packages
      install_rust

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt PORT "Listen port" "$DEFAULT_PORT"

      # HTTPS avoids the "insecure URL" / Subtle Crypto error in the web vault
      if ask_yn "Enable HTTPS with a self-signed certificate? (recommended — required for account creation over LAN IP)" "y"; then
        ENABLE_HTTPS="true"
        # default domain to the IP over https if user doesn't set one
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
        prompt DOMAIN "Domain (leave blank to use https://${ip}:${PORT})" ""
        if [[ -z "$DOMAIN" ]]; then
          DOMAIN="https://${ip}:${PORT}"
        fi
      else
        ENABLE_HTTPS="false"
        prompt DOMAIN "Domain (optional, e.g. https://vault.example.com)" ""
      fi

      if ask_yn "Allow open signups? (set to no after you create your account)"; then
        SIGNUPS_ALLOWED="true"
      else
        SIGNUPS_ALLOWED="false"
      fi

      [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      build_vaultwarden
      download_web_vault
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
        echo "  Open:  ${DOMAIN:-https://${ip:-localhost}:${PORT}}"
        echo
        echo "  Browser will warn about the self-signed certificate."
        echo "  Click Advanced -> Proceed to continue."
      else
        if [[ -n "$DOMAIN" ]]; then
          echo "  Open:  $DOMAIN"
        fi
        echo "  Open:  http://${ip:-localhost}:${PORT}"
        echo
        echo "  Note: account creation over a LAN IP requires HTTPS."
        echo "  Use http://localhost:${PORT} from this machine, or re-run with HTTPS."
      fi
      echo "  Files: $INSTALL_DIR"
      echo "  Data:  $INSTALL_DIR/data"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"

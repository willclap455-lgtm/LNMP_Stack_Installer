#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try sudo)." >&2
    exit 1
  fi
}

prompt_yes_no() {
  local prompt="${1:-Proceed?}"
  local default="${2:-N}"
  local suffix="[y/N]"

  case "${default}" in
    [Yy]) suffix="[Y/n]" ;;
    [Nn]) suffix="[y/N]" ;;
  esac

  while true; do
    read -r -p "${prompt} ${suffix} " reply || reply="${default}"
    reply="${reply:-${default}}"
    case "${reply}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

ensure_dependencies() {
  log "Ensuring base tooling is present..."
  apt-get update
  apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common
}

detect_codename() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  if [[ -z "${VERSION_CODENAME:-}" ]]; then
    echo "Unable to determine Ubuntu codename (VERSION_CODENAME missing)." >&2
    exit 1
  fi
  CODENAME="${VERSION_CODENAME}"
  log "Detected Ubuntu codename: ${CODENAME}"
}

setup_nginx_repo() {
  log "Configuring official NGINX repository..."
  local keyring="/etc/apt/keyrings/nginx-archive-keyring.gpg"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/nginx-official.list
deb [signed-by=${keyring}] http://nginx.org/packages/ubuntu/ ${CODENAME} nginx
deb-src [signed-by=${keyring}] http://nginx.org/packages/ubuntu/ ${CODENAME} nginx
EOF
}

setup_mysql_repo() {
  log "Configuring official MySQL repository..."
  local keyring="/etc/apt/keyrings/mysql-apt-keyring.gpg"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 | gpg --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/mysql-community.list
deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-apt-config
deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-8.4-lts
deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-tools
EOF
}

setup_php_repo() {
  log "Enabling Ondřej Surý PHP PPA..."
  add-apt-repository -y ppa:ondrej/php
}

setup_git_repo() {
  log "Adding the Git Core PPA (ppa:git-core/ppa)..."
  add-apt-repository -y ppa:git-core/ppa
}

setup_docker_repo() {
  log "Configuring the official Docker repository..."
  local keyring="/etc/apt/keyrings/docker-official.gpg"
  local arch
  arch="$(dpkg --print-architecture)"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/docker-official.list
deb [arch=${arch} signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
}

install_nginx() {
  log "Installing latest stable NGINX..."
  apt-get install -y nginx
  systemctl enable --now nginx
}

install_mysql() {
  log "Installing latest stable MySQL Server..."
  apt-get install -y mysql-server mysql-client mysql-shell
  systemctl enable --now mysql
}

install_git() {
  log "Installing the latest Git toolchain..."
  apt-get install -y git git-lfs
  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --system >/dev/null 2>&1 || true
  fi
}

install_php_stack() {
  log "Installing PHP base packages..."
  apt-get install -y \
    php \
    php-cli \
    php-fpm \
    php-common \
    php-mysql \
    php-dev \
    php-pear \
    php-curl \
    php-zip \
    php-gd \
    php-mbstring \
    php-xml \
    php-bcmath \
    php-intl \
    php-soap \
    php-ldap \
    php-imagick \
    php-opcache \
    php-redis \
    php-pspell \
    php-snmp \
    php-tidy \
    php-xsl \
    php-pgsql \
    php-sqlite3 \
    php-enchant

  install_all_php_extensions
}

install_all_php_extensions() {
  if ! command -v php >/dev/null 2>&1; then
    log "PHP binary not detected; skipping extension sweep."
    return
  fi

  local php_minor_version
  php_minor_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  local regex="^php${php_minor_version//./\\.}-"

  log "Discovering all available PHP ${php_minor_version} extensions..."
  mapfile -t all_extensions < <(apt-cache --names-only search "${regex}" | awk '{print $1}' | grep -v -- '-dbgsym$' | sort -u)

  if [[ "${#all_extensions[@]}" -eq 0 ]]; then
    log "No additional PHP ${php_minor_version} extensions were found."
    return
  fi

  log "Installing ${#all_extensions[@]} PHP ${php_minor_version} extensions..."
  apt-get install -y "${all_extensions[@]}"
}

install_docker() {
  log "Installing Docker Engine, CLI, and plugins..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

main() {
  require_root
  ensure_dependencies
  detect_codename

  local repos_added=0

  if prompt_yes_no "Add the official NGINX repository from nginx.org?" "Y"; then
    setup_nginx_repo
    repos_added=1
  else
    log "Skipping NGINX repository setup."
  fi

  if prompt_yes_no "Add the official MySQL Community repository from repo.mysql.com?" "Y"; then
    setup_mysql_repo
    repos_added=1
  else
    log "Skipping MySQL repository setup."
  fi

  if prompt_yes_no "Add the Ondřej Surý PHP repository (ppa:ondrej/php)?" "Y"; then
    setup_php_repo
    repos_added=1
  else
    log "Skipping PHP repository setup."
  fi

  if prompt_yes_no "Add the Git Core PPA (ppa:git-core/ppa) for the latest Git?" "Y"; then
    setup_git_repo
    repos_added=1
  else
    log "Skipping Git repository setup."
  fi

  if prompt_yes_no "Add the official Docker Engine repository from download.docker.com?" "Y"; then
    setup_docker_repo
    repos_added=1
  else
    log "Skipping Docker repository setup."
  fi

  if [[ "${repos_added}" -eq 1 ]]; then
    log "Refreshing package cache to include new repositories..."
    apt-get update
  else
    log "No new repositories were added; skipping apt-get update."
  fi

  if prompt_yes_no "Install the latest stable NGINX package set now?" "Y"; then
    install_nginx
  else
    log "NGINX installation skipped."
  fi

  if prompt_yes_no "Install the latest stable MySQL Server package set now?" "Y"; then
    install_mysql
  else
    log "MySQL installation skipped."
  fi

  if prompt_yes_no "Install PHP, FPM, and every available PHP extension now?" "Y"; then
    install_php_stack
  else
    log "PHP installation skipped."
  fi

  if prompt_yes_no "Install the latest Git and Git LFS packages now?" "Y"; then
    install_git
  else
    log "Git installation skipped."
  fi

  if prompt_yes_no "Install Docker Engine, CLI, and plugins now?" "Y"; then
    install_docker
  else
    log "Docker installation skipped."
  fi

  log "All requested actions have completed."
}

main "$@"

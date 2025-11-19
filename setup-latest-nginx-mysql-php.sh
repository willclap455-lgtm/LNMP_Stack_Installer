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
  if [[ -z "${VERSION_ID:-}" ]]; then
    echo "Unable to determine Ubuntu VERSION_ID (required for Microsoft repository setup)." >&2
    exit 1
  fi
  CODENAME="${VERSION_CODENAME}"
  UBUNTU_VERSION_ID="${VERSION_ID}"
  log "Detected Ubuntu release: ${UBUNTU_VERSION_ID} (${CODENAME})"
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

setup_microsoft_packages_repo() {
  log "Configuring Microsoft package repository for .NET and PowerShell..."
  if [[ -z "${UBUNTU_VERSION_ID:-}" ]]; then
    echo "Ubuntu VERSION_ID was not detected; cannot configure Microsoft repository." >&2
    exit 1
  fi
  local packages_deb
  packages_deb="$(mktemp)"
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION_ID}/packages-microsoft-prod.deb" -o "${packages_deb}"
  dpkg -i "${packages_deb}"
  rm -f "${packages_deb}"
setup_java_repo() {
  log "Configuring Eclipse Temurin (Adoptium) Java repository..."
  local keyring="/etc/apt/keyrings/adoptium-archive-keyring.gpg"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/adoptium-official.list
deb [signed-by=${keyring}] https://packages.adoptium.net/artifactory/deb ${CODENAME} main
EOF
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
setup_python_repo() {
  log "Enabling Deadsnakes Python PPA..."
  add-apt-repository -y ppa:deadsnakes/ppa
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

install_latest_dotnet_sdk() {
  log "Installing latest stable .NET SDK..."
  local sdk_candidates=()
  mapfile -t sdk_candidates < <(
    apt-cache search --names-only 'dotnet-sdk-' 2>/dev/null |
      awk '{print $1}' |
      grep -E '^dotnet-sdk-[0-9]+\.[0-9]+$' |
      sort -V
  ) || true

  if [[ "${#sdk_candidates[@]}" -eq 0 ]]; then
    echo "No dotnet-sdk packages were found in the configured repositories." >&2
    return 1
  fi

  local latest_sdk="${sdk_candidates[${#sdk_candidates[@]}-1]}"
  log "Installing package ${latest_sdk}..."
  apt-get install -y "${latest_sdk}"
}

install_powershell() {
  log "Installing PowerShell..."
  apt-get install -y powershell
install_java_stack() {
  log "Installing latest stable Eclipse Temurin JDK/JRE..."
  apt-get install -y temurin-21-jdk temurin-21-jre
install_network_tooling() {
  log "Installing net-tools and DNS utilities..."
  apt-get install -y --no-install-recommends \
    net-tools \
    dnsutils \
    whois \
    iputils-ping
install_docker() {
  log "Installing Docker Engine, CLI, and plugins..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
install_python_stack() {
  log "Installing Python 3 runtimes and tooling..."
  local -a python_packages=(
    python3
    python3-venv
    python3-dev
    python3-pip
    python3-distutils
    python3-setuptools
    python3-wheel
    python-is-python3
    build-essential
  )

  apt-get install -y "${python_packages[@]}"

  if ! command -v python3 >/dev/null 2>&1; then
    log "Python 3 installation failed; skipping pip package installation."
    return
  fi

  log "Upgrading pip and installing common Python packages (including ngxtop)..."
  local -a pip_install_base=(python3 -m pip install --upgrade --no-cache-dir)
  if python3 -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then
    pip_install_base+=(--break-system-packages)
  fi

  "${pip_install_base[@]}" pip

  local -a common_python_packages=(
    virtualenv
    pipenv
    requests
    numpy
    pandas
    flask
    django
    fastapi
    uvicorn
    gunicorn
    black
    pytest
    jupyter
    ipython
    ngxtop
  )

  "${pip_install_base[@]}" "${common_python_packages[@]}"
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

  if prompt_yes_no "Add the Microsoft repository for .NET and PowerShell?" "Y"; then
    setup_microsoft_packages_repo
    repos_added=1
  else
    log "Skipping Microsoft repository setup."
    if prompt_yes_no "Add the Eclipse Temurin (Adoptium) Java repository?" "Y"; then
      setup_java_repo
      repos_added=1
    else
      log "Skipping Java repository setup."
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
  if prompt_yes_no "Add the Deadsnakes Python repository (ppa:deadsnakes/ppa)?" "Y"; then
    setup_python_repo
    repos_added=1
  else
    log "Skipping Python repository setup."
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

  if prompt_yes_no "Install the latest stable .NET SDK now?" "Y"; then
    install_latest_dotnet_sdk
  else
    log ".NET installation skipped."
  fi

  if prompt_yes_no "Install PowerShell now?" "Y"; then
    install_powershell
  else
    log "PowerShell installation skipped."
    if prompt_yes_no "Install the latest stable Eclipse Temurin JDK and JRE now?" "Y"; then
      install_java_stack
    else
      log "Java installation skipped."
    fi
  if prompt_yes_no "Install net-tools and DNS utilities (whois, ping, dig)?" "Y"; then
    install_network_tooling
  else
    log "Network tooling installation skipped."
  if prompt_yes_no "Install the latest Git and Git LFS packages now?" "Y"; then
    install_git
  else
    log "Git installation skipped."
  fi

  if prompt_yes_no "Install Docker Engine, CLI, and plugins now?" "Y"; then
    install_docker
  else
    log "Docker installation skipped."
  if prompt_yes_no "Install Python 3, pip, and common Python packages (including ngxtop) now?" "Y"; then
    install_python_stack
  else
    log "Python installation skipped."
  fi

  log "All requested actions have completed."
}

main "$@"

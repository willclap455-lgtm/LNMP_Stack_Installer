#!/usr/bin/env bash
set -euo pipefail

declare -a INSTALL_SUCCESSES=()
declare -a INSTALL_FAILURES=()

record_install_success() {
  local label="${1:-unspecified component}"
  INSTALL_SUCCESSES+=("${label}")
}

record_install_failure() {
  local label="${1:-unspecified component}"
  INSTALL_FAILURES+=("${label}")
}

print_install_summary() {
  echo
  echo "Installation summary:"
  echo "Successfully installed:"
  if (( ${#INSTALL_SUCCESSES[@]} > 0 )); then
    local success_item
    for success_item in "${INSTALL_SUCCESSES[@]}"; do
      echo " - ${success_item}"
    done
  else
    echo " - None"
  fi

  echo "Failed installations:"
  if (( ${#INSTALL_FAILURES[@]} > 0 )); then
    local failure_item
    for failure_item in "${INSTALL_FAILURES[@]}"; do
      echo " - ${failure_item}"
    done
  else
    echo " - None"
  fi
}

resolve_default_download_dir() {
  local candidate=""

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if command -v getent >/dev/null 2>&1; then
      candidate="$(getent passwd "${SUDO_USER}" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
    elif [[ -r /etc/passwd ]]; then
      candidate="$(awk -F: -v user="${SUDO_USER}" '$1==user {print $6; exit}' /etc/passwd)"
    fi
  fi

  if [[ -z "${candidate}" && -n "${HOME:-}" ]]; then
    candidate="${HOME}"
  fi

  if [[ -z "${candidate}" && -n "${PWD:-}" ]]; then
    candidate="${PWD}"
  fi

  if [[ -z "${candidate}" ]]; then
    candidate="/tmp"
  fi

  printf '%s\n' "${candidate}"
}

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$(resolve_default_download_dir)}"
MEDIAWIKI_URL="${MEDIAWIKI_URL:-https://releases.wikimedia.org/mediawiki/latest/mediawiki-latest.tar.gz}"
NEOVIM_LATEST_STATIC_URL="${NEOVIM_LATEST_STATIC_URL:-https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz}"
NEOVIM_STABLE_STATIC_URL="${NEOVIM_STABLE_STATIC_URL:-https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz}"
NEOVIM_ASSET_PATTERN="${NEOVIM_ASSET_PATTERN:-nvim-linux-x86_64\\.tar\\.gz}"
PHP_TARGET_MINOR_VERSION=""
PHP_FALLBACK_MINOR_VERSION="${PHP_FALLBACK_MINOR_VERSION:-8.3}"

readonly -a PHP_BASE_PACKAGES=(
  php-cli
  php-common
  php-mysql
  php-dev
  php-pear
  php-curl
  php-zip
  php-gd
  php-mbstring
  php-xml
  php-bcmath
  php-intl
  php-soap
  php-ldap
  php-imagick
  php-redis
  php-pspell
  php-snmp
  php-tidy
  php-pgsql
  php-sqlite3
  php-enchant
)

readonly -a NON_VERSIONED_PHP_PACKAGES=(
  php-pear
)

readonly -a PHP_PACKAGE_DENYLIST=(
  php-fpm
  php8.4-fpm
)

readonly -a PHP_EXTENSION_EXCLUDE_PATTERNS=(
  "libapache2-mod-php*"
  "*apache*"
  "*swoole*"
)

PHP_EXTENSION_SKIP_PATTERN_MATCH=""

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

disable_service_auto_start() {
  local policy_path="/usr/sbin/policy-rc.d"
  local guard_state="absent"
  local backup_file=""

  if [[ -e "${policy_path}" ]]; then
    backup_file="$(mktemp)"
    cp -p "${policy_path}" "${backup_file}"
    guard_state="present"
  fi

  cat <<'EOF' >"${policy_path}"
#!/bin/sh
exit 101
EOF
  chmod 0755 "${policy_path}"

  printf '%s:%s\n' "${guard_state}" "${backup_file}"
}

restore_service_auto_start() {
  local policy_path="/usr/sbin/policy-rc.d"
  local guard="${1:-}"

  if [[ -z "${guard}" ]]; then
    return 0
  fi

  local state=""
  local backup_file=""
  IFS=':' read -r state backup_file <<<"${guard}"

  if [[ "${state}" == "present" && -n "${backup_file}" ]]; then
    cp -p "${backup_file}" "${policy_path}"
    rm -f "${backup_file}"
  else
    rm -f "${policy_path}"
    [[ -n "${backup_file}" ]] && rm -f "${backup_file}"
  fi
}

is_package_installed() {
  local package="${1:?package name required}"
  dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "ok installed"
}

is_denylisted_php_package() {
  local package="${1:-}"
  local blocked
  for blocked in "${PHP_PACKAGE_DENYLIST[@]}"; do
    if [[ -n "${package}" && "${package}" == "${blocked}" ]]; then
      return 0
    fi
  done
  return 1
}

remove_apache2_if_present() {
  log "Ensuring Apache HTTP Server packages are removed..."
  local -a apache_packages=(
    apache2
    apache2-bin
    apache2-data
    apache2-utils
    apache2-doc
    apache2-dev
    apache2-htcacheclean
    apache2-l10n
    apache2-ssl-dev
    apache2-suexec-pristine
    apache2-suexec-custom
    libapache2-mod-php
  )

  local -a installed=()
  local -A seen=()

  for pkg in "${apache_packages[@]}"; do
    if is_package_installed "${pkg}" && [[ -z "${seen[${pkg}]:-}" ]]; then
      installed+=("${pkg}")
      seen["${pkg}"]=1
    fi
  done

  local -a wildcard_patterns=(
    'apache2*'
    'libapache2*'
    'libapache2-mod-php*'
  )

  for pattern in "${wildcard_patterns[@]}"; do
    while IFS= read -r pkg; do
      [[ -z "${pkg}" ]] && continue
      if [[ -z "${seen[${pkg}]:-}" ]]; then
        installed+=("${pkg}")
        seen["${pkg}"]=1
      fi
    done < <(dpkg-query -W -f='${binary:Package}\n' "${pattern}" 2>/dev/null || true)
  done

  if [[ "${#installed[@]}" -eq 0 ]]; then
    log "No Apache packages detected; nothing to remove."
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop apache2 >/dev/null 2>&1 || true
    systemctl disable apache2 >/dev/null 2>&1 || true
  fi

  log "Purging Apache packages: ${installed[*]}"
  apt-get purge -y "${installed[@]}"
  apt-get autoremove -y --purge

  purge_apache2_config_leftovers
  ensure_apache2_removed

  log "Removing residual Apache directories and state files..."
  rm -rf /etc/apache2 /var/log/apache2 /var/lib/apache2
}

purge_apache2_config_leftovers() {
  local -a rc_packages=()
  mapfile -t rc_packages < <(
    dpkg -l 'apache2*' 'libapache2*' 2>/dev/null |
      awk '$1=="rc"{print $2}' || true
  )

  if [[ "${#rc_packages[@]}" -eq 0 ]]; then
    return
  fi

  log "Purging Apache configuration residue: ${rc_packages[*]}"
  dpkg --purge "${rc_packages[@]}"
}

ensure_apache2_removed() {
  local -a remaining=()
  mapfile -t remaining < <(
    dpkg-query -W -f='${binary:Package}\t${Status}\n' 'apache2*' 'libapache2*' 2>/dev/null |
      awk '$2=="install" && $3=="ok" && $4=="installed"{print $1}' || true
  )

  if [[ "${#remaining[@]}" -eq 0 ]]; then
    log "Apache packages successfully purged."
    return
  fi

  echo "Unable to purge all Apache packages automatically. Remaining: ${remaining[*]}" >&2
  echo "Please resolve the package state manually (dpkg -l | grep apache2) and rerun the script." >&2
  return 1
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
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --batch --yes --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/nginx-official.list
deb [signed-by=${keyring}] http://nginx.org/packages/ubuntu/ ${CODENAME} nginx
deb-src [signed-by=${keyring}] http://nginx.org/packages/ubuntu/ ${CODENAME} nginx
EOF
}

setup_ondrej_nginx_repo() {
  log "Enabling Ondřej Surý NGINX PPA (ppa:ondrej/nginx)..."
  add-apt-repository -y ppa:ondrej/nginx
}

# setup_mysql_repo() {
#   log "Configuring official MySQL repository..."
#   local keyring="/etc/apt/keyrings/mysql-apt-keyring.gpg"
#   install -d -m 0755 /etc/apt/keyrings
#   curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 | gpg --dearmor -o "${keyring}"
#   chmod 0644 "${keyring}"
#   cat <<EOF >/etc/apt/sources.list.d/mysql-community.list
# deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-apt-config
# deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-8.4-lts
# deb [signed-by=${keyring}] http://repo.mysql.com/apt/ubuntu/ ${CODENAME} mysql-tools
# EOF
# }

setup_php_repo() {
  log "Enabling Ondřej Surý PHP PPA..."
  add-apt-repository -y ppa:ondrej/php
  log "PHP PPA recommends pairing with the Ondřej NGINX PPA when using NGINX; ensuring it is configured..."
  setup_ondrej_nginx_repo
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
}

setup_java_repo() {
  log "Configuring Eclipse Temurin (Adoptium) Java repository..."
  local keyring="/etc/apt/keyrings/adoptium-archive-keyring.gpg"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --batch --yes --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/adoptium-official.list
deb [signed-by=${keyring}] https://packages.adoptium.net/artifactory/deb ${CODENAME} main
EOF
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
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/docker-official.list
deb [arch=${arch} signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
}

setup_python_repo() {
  log "Enabling Deadsnakes Python PPA..."
  add-apt-repository -y ppa:deadsnakes/ppa
}

setup_postgresql_repo() {
  log "Configuring PostgreSQL Global Development Group (PGDG) repository..."
  local keyring="/etc/apt/keyrings/pgdg-archive-keyring.gpg"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --batch --yes --dearmor -o "${keyring}"
  chmod 0644 "${keyring}"
  cat <<EOF >/etc/apt/sources.list.d/pgdg-official.list
deb [signed-by=${keyring}] http://apt.postgresql.org/pub/repos/apt/ ${CODENAME}-pgdg main
EOF
}

install_nginx() {
  log "Installing latest stable NGINX..."
  apt-get install -y nginx
  systemctl enable --now nginx
}

# install_mysql() {
#   log "Installing latest stable MySQL Server..."
#   apt-get install -y mysql-server mysql-client mysql-shell
#   systemctl enable --now mysql
# }

install_git() {
  log "Installing the latest Git toolchain..."
  apt-get install -y git git-lfs
  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --system >/dev/null 2>&1 || true
  fi
}

install_php_stack() {
  log "Installing PHP base packages..."

  if install_php_packages_for_version ""; then
    PHP_TARGET_MINOR_VERSION="$(detect_installed_php_minor_version)"
  else
    log "Primary PHP installation attempt failed; purging broken packages and retrying with fallback version..."
    purge_broken_php_packages
    if install_php_packages_for_version "${PHP_FALLBACK_MINOR_VERSION}"; then
      PHP_TARGET_MINOR_VERSION="${PHP_FALLBACK_MINOR_VERSION}"
    else
      echo "PHP installation failed, even after attempting fallback to PHP ${PHP_FALLBACK_MINOR_VERSION}." >&2
      return 1
    fi
  fi

  if [[ -z "${PHP_TARGET_MINOR_VERSION:-}" ]]; then
    PHP_TARGET_MINOR_VERSION="$(detect_installed_php_minor_version)"
  fi

  if [[ -n "${PHP_TARGET_MINOR_VERSION:-}" ]]; then
    log "Using PHP ${PHP_TARGET_MINOR_VERSION} as the active runtime."
    ensure_php_alternative "${PHP_TARGET_MINOR_VERSION}"
  else
    log "Unable to determine the installed PHP version; proceeding without adjusting alternatives."
  fi

  install_versioned_php_virtual "opcache"
  install_versioned_php_virtual "xsl"
  install_all_php_extensions
}

install_all_php_extensions() {
  if ! command -v php >/dev/null 2>&1; then
    log "PHP binary not detected; skipping extension sweep."
    return
  fi

  local php_minor_version=""
  if ! php_minor_version="$(PHP_INI_SCAN_DIR= php -n -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"; then
    log "Unable to query PHP minor version (php CLI failing); skipping extension sweep."
    return
  fi
  if [[ -z "${php_minor_version}" ]]; then
    log "PHP minor version detection returned an empty result; skipping extension sweep."
    return
  fi
  local regex="^php${php_minor_version//./\\.}-"

  log "Discovering all available PHP ${php_minor_version} extensions..."
  mapfile -t all_extensions < <(apt-cache --names-only search "${regex}" | awk '{print $1}' | grep -v -- '-dbgsym$' | sort -u)

  if [[ "${#all_extensions[@]}" -eq 0 ]]; then
    log "No additional PHP ${php_minor_version} extensions were found."
    return
  fi

  local -a excluded_extensions=(
    "php${php_minor_version}-yac"
    "php${php_minor_version}-gmagick"
  )
  local -a filtered_extensions=()

  for pkg in "${all_extensions[@]}"; do
    local skip_pkg=0
    if php_extension_should_skip "${pkg}"; then
      log "Skipping ${pkg} because it matches excluded pattern '${PHP_EXTENSION_SKIP_PATTERN_MATCH}'."
      continue
    fi
    if is_denylisted_php_package "${pkg}"; then
      log "Skipping ${pkg} because it is denylisted."
      continue
    fi
    for excluded in "${excluded_extensions[@]}"; do
      if [[ "${pkg}" == "${excluded}" ]]; then
        log "Skipping ${pkg} due to known dependency conflicts."
        skip_pkg=1
        break
      fi
    done
    if [[ "${skip_pkg}" -eq 0 ]]; then
      filtered_extensions+=("${pkg}")
    fi
  done

  if [[ "${#filtered_extensions[@]}" -eq 0 ]]; then
    log "All discovered PHP ${php_minor_version} extensions were excluded; nothing to install."
    return
  fi

  log "Installing ${#filtered_extensions[@]} PHP ${php_minor_version} extensions..."
  apt-get install -y "${filtered_extensions[@]}"
}

php_extension_should_skip() {
  local package="${1:-}"
  PHP_EXTENSION_SKIP_PATTERN_MATCH=""
  [[ -z "${package}" ]] && return 1

  local pattern
  for pattern in "${PHP_EXTENSION_EXCLUDE_PATTERNS[@]}"; do
    if [[ "${package}" == ${pattern} ]]; then
      PHP_EXTENSION_SKIP_PATTERN_MATCH="${pattern}"
      return 0
    fi
  done

  return 1
}

find_latest_versioned_php_package() {
  local suffix="${1:?missing suffix for php package discovery}"
  local pattern="^php[0-9.]+-${suffix}$"
  mapfile -t versioned_packages < <(
    apt-cache --names-only search "${pattern}" 2>/dev/null |
      awk '{print $1}' |
      sort -V
  ) || true

  if [[ "${#versioned_packages[@]}" -eq 0 ]]; then
    return 1
  fi

  local latest_package=""
  for pkg in "${versioned_packages[@]}"; do
    latest_package="${pkg}"
  done

  printf '%s\n' "${latest_package}"
}

install_versioned_php_virtual() {
  local suffix="${1:?missing suffix for virtual php package install}"
  local package_name
  if [[ -n "${PHP_TARGET_MINOR_VERSION:-}" ]]; then
    local pinned_candidate="php${PHP_TARGET_MINOR_VERSION}-${suffix}"
    if apt-cache show "${pinned_candidate}" >/dev/null 2>&1; then
      log "Installing ${pinned_candidate} to satisfy php-${suffix} virtual package..."
      apt-get install -y "${pinned_candidate}"
      return 0
    fi
  fi

  if ! package_name="$(find_latest_versioned_php_package "${suffix}")"; then
    log "No versioned php package found to satisfy php-${suffix}; skipping."
    return 0
  fi

  log "Installing ${package_name} to satisfy php-${suffix} virtual package..."
  apt-get install -y "${package_name}"
}

configure_custom_motd() {
  log "Configuring custom Clancy Systems MOTD..."

  local motd_dir="/etc/update-motd.d"
  local motd_script="${motd_dir}/10-clancy-systems"

  install -d -m 0755 "${motd_dir}"

  cat <<'EOF' >"${motd_script}"
#!/usr/bin/env bash

primary=$'\e[38;5;208m'
accent=$'\e[38;5;39m'
muted=$'\e[38;5;250m'
highlight=$'\e[38;5;82m'
reset=$'\e[0m'

hostname="$(hostname -f 2>/dev/null || hostname)"
kernel="$(uname -sr)"
distro="$(lsb_release -ds 2>/dev/null || uname -s)"
uptime_display="$(uptime -p 2>/dev/null)"
if [[ -n "${uptime_display}" ]]; then
  uptime_display="${uptime_display#up }"
else
  uptime_display="$(uptime | sed 's/.*up \([^,]*\), .*/\1/')"
fi
loadavg="$(cut -d ' ' -f1-3 /proc/loadavg 2>/dev/null)"
datetime="$(date '+%A, %B %d %Y %H:%M:%S %Z')"
users="$(who | awk '{print $1}' | sort -u | wc -l | tr -d ' ')"
[[ -z "${users}" ]] && users="0"
memory="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3\" / \"$2\" used\"}')"
disk="$(df -h / 2>/dev/null | awk 'NR==2 {print $3\" / \"$2\" used\"}')"
last_login="$(last -n 2 -w "$USER" 2>/dev/null | tail -n 1)"
if [[ -z "${last_login// }" ]]; then
  last_login="No previous login recorded."
fi
weather="$(curl -fs --max-time 4 'https://wttr.in/Denver?format=3' 2>/dev/null || true)"
if [[ -z "${weather}" ]]; then
  weather="Weather data unavailable."
fi

printf 'Welcome to Clancy Systems Denver.\n\n'

printf '%bClancy Node:%b %s %b(%s)%b\n' "${accent}" "${reset}" "${hostname}" "${muted}" "${distro}" "${reset}"
printf '%bKernel:%b %s   %bLoad:%b %s\n' "${accent}" "${reset}" "${kernel}" "${accent}" "${reset}" "${loadavg:-n/a}"
printf '%bUptime:%b %s   %bUsers:%b %s\n' "${accent}" "${reset}" "${uptime_display}" "${accent}" "${reset}" "${users}"
printf '%bMemory:%b %s   %bRoot FS:%b %s\n' "${accent}" "${reset}" "${memory:-n/a}" "${accent}" "${reset}" "${disk:-n/a}"
printf '%bDate:%b %s\n' "${accent}" "${reset}" "${datetime}"
printf '%bLast Login:%b %s\n' "${accent}" "${reset}" "${last_login}"
printf '%bDenver Weather:%b %s\n' "${accent}" "${reset}" "${weather}"
printf '%bEnjoy your session!%b\n' "${highlight}" "${reset}"
EOF

  chmod 0755 "${motd_script}"
  log "Custom MOTD installed at ${motd_script}"
}

ensure_transfer_tool_repo() {
  log "Confirming Ubuntu apt repositories provide curl and wget..."
  if ! apt-cache --names-only search '^curl$' >/dev/null; then
    log "Refreshing apt cache to ensure curl is discoverable..."
    apt-get update
  fi
}

detect_installed_php_minor_version() {
  if ! command -v php >/dev/null 2>&1; then
    return 0
  fi

  local detected_version=""
  if detected_version="$(PHP_INI_SCAN_DIR= php -n -r 'printf("%d.%d", PHP_MAJOR_VERSION, PHP_MINOR_VERSION);' 2>/dev/null)"; then
    printf '%s' "${detected_version}"
  fi

  return 0
}

ensure_php_alternative() {
  local minor_version="${1:-}"
  [[ -z "${minor_version}" ]] && return 0

  local php_binary="/usr/bin/php${minor_version}"
  if [[ ! -x "${php_binary}" ]]; then
    return 0
  fi

  if update-alternatives --list php >/dev/null 2>&1; then
    update-alternatives --set php "${php_binary}" >/dev/null 2>&1 || true
  else
    update-alternatives --install /usr/bin/php php "${php_binary}" 100 >/dev/null 2>&1 || true
  fi

  return 0
}

is_non_versioned_php_package() {
  local package="${1:-}"
  local candidate
  for candidate in "${NON_VERSIONED_PHP_PACKAGES[@]}"; do
    if [[ "${package}" == "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

build_php_package_list_for_version() {
  local minor_version="${1:-}"
  if [[ -z "${minor_version}" ]]; then
    printf '%s\n' "${PHP_BASE_PACKAGES[@]}"
    return 0
  fi

  local pkg
  for pkg in "${PHP_BASE_PACKAGES[@]}"; do
    if [[ "${pkg}" == php-* ]] && ! is_non_versioned_php_package "${pkg}"; then
      local candidate="php${minor_version}${pkg#php}"
      if apt-cache show "${candidate}" >/dev/null 2>&1; then
        printf '%s\n' "${candidate}"
        continue
      fi
    fi
    printf '%s\n' "${pkg}"
  done
}

install_php_packages_for_version() {
  local minor_version="${1:-}"
  local -a packages=()
  if [[ -n "${minor_version}" ]]; then
    mapfile -t packages < <(build_php_package_list_for_version "${minor_version}")
    log "Installing PHP ${minor_version} packages..."
  else
    packages=("${PHP_BASE_PACKAGES[@]}")
    log "Installing PHP packages via distribution meta packages..."
  fi

  local -a filtered_packages=()
  local pkg
  for pkg in "${packages[@]}"; do
    if is_denylisted_php_package "${pkg}"; then
      log "Skipping denylisted package ${pkg}."
      continue
    fi
    filtered_packages+=("${pkg}")
  done
  packages=("${filtered_packages[@]}")

  if [[ "${#packages[@]}" -eq 0 ]]; then
    log "No PHP packages resolved for installation."
    return 1
  fi

  log "Temporarily blocking service auto-start for PHP-related packages until manually configured..."
  local policy_guard=""
  policy_guard="$(disable_service_auto_start)"

  local apt_status=0
  if ! apt-get install -y "${packages[@]}"; then
    apt_status=1
  fi

  restore_service_auto_start "${policy_guard}"

  if [[ "${apt_status}" -ne 0 ]]; then
    return 1
  fi

  return 0
}

purge_broken_php_packages() {
  log "Checking for partially installed PHP packages to purge..."
  log "Skipping purge of php-fpm packages per policy."
  return 0
}

install_curl_wget_if_missing() {
  log "Ensuring curl and wget are installed..."
  local missing=()
  if ! command -v curl >/dev/null 2>&1; then
    missing+=("curl")
  fi
  if ! command -v wget >/dev/null 2>&1; then
    missing+=("wget")
  fi

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "curl and wget are already present."
    return
  fi

  apt-get install -y "${missing[@]}"
}

discover_latest_mediawiki_tarball_url() {
  local base_url="https://releases.wikimedia.org/mediawiki"
  local listing=""
  local -a series_candidates=()
  local -a tarballs=()

  if ! listing="$(curl -fsSL "${base_url}/")"; then
    return 1
  fi

  mapfile -t series_candidates < <(
    printf '%s\n' "${listing}" |
      grep -oE 'href="[0-9]+\.[0-9]+/' |
      sed -E 's/^href="//; s/\/$//' |
      LC_ALL=C sort -Vu
  ) || true

  if [[ "${#series_candidates[@]}" -eq 0 ]]; then
    return 1
  fi

  local latest_series="${series_candidates[${#series_candidates[@]}-1]}"

  if ! listing="$(curl -fsSL "${base_url}/${latest_series}/")"; then
    return 1
  fi

  mapfile -t tarballs < <(
    printf '%s\n' "${listing}" |
      grep -oE 'mediawiki-[0-9]+\.[0-9]+(\.[0-9]+)?(-rc\.[0-9]+)?\.tar\.gz' |
      LC_ALL=C sort -Vu
  ) || true

  if [[ "${#tarballs[@]}" -eq 0 ]]; then
    return 1
  fi

  local -a stable_tarballs=()
  local -a prerelease_tarballs=()
  local tarball
  for tarball in "${tarballs[@]}"; do
    if [[ "${tarball}" == *"-rc."* ]]; then
      prerelease_tarballs+=("${tarball}")
    else
      stable_tarballs+=("${tarball}")
    fi
  done

  local latest_tarball=""
  if [[ "${#stable_tarballs[@]}" -gt 0 ]]; then
    latest_tarball="${stable_tarballs[${#stable_tarballs[@]}-1]}"
  else
    latest_tarball="${prerelease_tarballs[${#prerelease_tarballs[@]}-1]}"
  fi

  printf '%s/%s/%s\n' "${base_url}" "${latest_series}" "${latest_tarball}"
}

download_latest_mediawiki() {
  local archive_name
  archive_name="$(basename "${MEDIAWIKI_URL}")"
  install -d -m 0755 "${DOWNLOAD_DIR}"
  local destination="${DOWNLOAD_DIR}/${archive_name}"

  log "Downloading latest MediaWiki archive to ${destination}..."
  local primary_status=0
  if wget -nv -O "${destination}" "${MEDIAWIKI_URL}"; then
    return 0
  else
    primary_status=$?
  fi

  rm -f "${destination}"
  log "Primary MediaWiki URL ${MEDIAWIKI_URL} failed with exit code ${primary_status}; attempting fallback discovery..."

  local fallback_url=""
  if ! fallback_url="$(discover_latest_mediawiki_tarball_url)"; then
    echo "Failed to download MediaWiki from ${MEDIAWIKI_URL} and could not determine a fallback release URL." >&2
    return 1
  fi

  destination="${DOWNLOAD_DIR}/$(basename "${fallback_url}")"
  log "Downloading MediaWiki from fallback URL ${fallback_url}..."
  wget -nv -O "${destination}" "${fallback_url}"
}

resolve_neovim_download_url() {
  local api_url="https://api.github.com/repos/neovim/neovim/releases/latest"
  local asset_pattern="${NEOVIM_ASSET_PATTERN}"
  local response=""
  local url=""

  if response="$(curl -fsSL -H 'Accept: application/vnd.github+json' "${api_url}" 2>/dev/null)"; then
    url="$(
      printf '%s\n' "${response}" |
        grep -oE "\"browser_download_url\":[[:space:]]*\"[^\"]*${asset_pattern}\"" |
        head -n 1 |
        sed -E 's/.*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/'
    )"
    if [[ -n "${url}" ]]; then
      printf '%s\n' "${url}"
      return 0
    fi
  fi

  printf '%s\n' "${NEOVIM_LATEST_STATIC_URL}"
  return 1
}

install_neovim() {
  log "Installing latest stable Neovim from GitHub releases..."

  local tmpdir
  tmpdir="$(mktemp -d)"
  local archive="${tmpdir}/nvim.tar.gz"
  local install_dir="/opt/nvim-linux64"
  local download_url=""

  if ! download_url="$(resolve_neovim_download_url)"; then
    log "Unable to query Neovim release metadata; defaulting to ${download_url}."
  fi

  log "Downloading Neovim archive from ${download_url}..."
  if ! curl -fsSL -o "${archive}" "${download_url}"; then
    local primary_status=$?
    log "Primary Neovim download failed with exit code ${primary_status}; retrying with ${NEOVIM_STABLE_STATIC_URL}..."
    rm -f "${archive}"
    if ! curl -fsSL -o "${archive}" "${NEOVIM_STABLE_STATIC_URL}"; then
      local secondary_status=$?
      rm -rf "${tmpdir}"
      echo "Failed to download Neovim archives (attempted ${download_url} and ${NEOVIM_STABLE_STATIC_URL})." >&2
      return "${secondary_status}"
    fi
  fi

  log "Extracting Neovim archive..."
  tar -xzf "${archive}" -C "${tmpdir}"

  local extracted_dir=""
  if [[ -d "${tmpdir}/nvim-linux64" ]]; then
    extracted_dir="${tmpdir}/nvim-linux64"
  else
    extracted_dir="$(find "${tmpdir}" -maxdepth 1 -mindepth 1 -type d -name 'nvim-*' -print -quit)"
  fi

  if [[ -z "${extracted_dir}" || ! -d "${extracted_dir}" ]]; then
    echo "Unable to locate extracted Neovim directory under ${tmpdir}." >&2
    rm -rf "${tmpdir}"
    return 1
  fi

  log "Placing Neovim under ${install_dir}..."
  install -d /opt
  rm -rf "${install_dir}"
  mv "${extracted_dir}" "${install_dir}"

  log "Linking Neovim binary into /usr/local/bin..."
  install -d /usr/local/bin
  ln -sf "${install_dir}/bin/nvim" /usr/local/bin/nvim

  rm -rf "${tmpdir}"
  log "Neovim installation complete: $(/usr/local/bin/nvim --version | head -n 1)"
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
}

install_java_stack() {
  log "Installing latest stable Eclipse Temurin JDK/JRE..."
  apt-get install -y temurin-21-jdk temurin-21-jre
}

install_network_tooling() {
  log "Installing net-tools and DNS utilities..."
  apt-get install -y --no-install-recommends \
    net-tools \
    dnsutils \
    whois \
    iputils-ping \
    btop
}

install_docker() {
  log "Installing Docker Engine, CLI, and plugins..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

resolve_python_distutils_package() {
  local base_pkg="python3-distutils"
  if apt-cache --names-only show "${base_pkg}" >/dev/null 2>&1; then
    printf '%s' "${base_pkg}"
    return 0
  fi

  local -a candidates=()
  mapfile -t candidates < <(
    apt-cache --names-only search '^python3\.[0-9]+-distutils$' 2>/dev/null |
      awk '{print $1}' |
      sort -V
  ) || true

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    return 1
  fi

  printf '%s' "${candidates[${#candidates[@]}-1]}"
  return 0
}

install_python_stack() {
  log "Installing Python 3 runtimes and tooling..."
  local -a python_packages=(
    python3
    python3-venv
    python3-dev
    python3-pip
    python3-setuptools
    python3-wheel
    python-is-python3
    build-essential
  )

  local distutils_pkg=""
  if distutils_pkg="$(resolve_python_distutils_package)"; then
    python_packages+=("${distutils_pkg}")
  else
    log "No python*-distutils package found in current apt sources; continuing without it."
  fi

  local -a available_python_packages=()
  local -a missing_python_packages=()

  local pkg
  for pkg in "${python_packages[@]}"; do
    if apt-cache --names-only show "${pkg}" >/dev/null 2>&1; then
      available_python_packages+=("${pkg}")
    else
      missing_python_packages+=("${pkg}")
    fi
  done

  if [[ "${#available_python_packages[@]}" -eq 0 ]]; then
    log "None of the requested Python runtime packages are available; skipping Python installation."
    return
  fi

  if [[ "${#missing_python_packages[@]}" -gt 0 ]]; then
    log "Skipping unavailable Python packages: ${missing_python_packages[*]}"
  fi

  if ! apt-get install -y "${available_python_packages[@]}"; then
    log "Python runtime installation failed; skipping pip package installation."
    return
  fi

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

install_postgresql_latest() {
  log "Installing latest stable PostgreSQL server and tooling..."

  local -a server_packages=()
  mapfile -t server_packages < <(
    apt-cache search --names-only '^postgresql-[0-9]+$' 2>/dev/null |
      awk '{print $1}' |
      sort -V
  ) || true

  if [[ "${#server_packages[@]}" -eq 0 ]]; then
    echo "No versioned postgresql-* packages were found (repository missing?)." >&2
    return 1
  fi

  local latest_server_package="${server_packages[${#server_packages[@]}-1]}"
  local latest_version="${latest_server_package#postgresql-}"

  log "Discovered latest PostgreSQL version ${latest_version}; installing..."

  apt-get install -y \
    "postgresql-${latest_version}" \
    "postgresql-client-${latest_version}" \
    "postgresql-contrib-${latest_version}" \
    libpq-dev

  systemctl enable --now postgresql
}

main() {
  require_root
  if ensure_dependencies; then
    record_install_success "Base dependency tooling"
  else
    record_install_failure "Base dependency tooling"
    echo "Failed to install base dependencies; aborting." >&2
    exit 1
  fi
  detect_codename

  local repos_added=0

  if prompt_yes_no "Add the official NGINX repository from nginx.org?" "Y"; then
    setup_nginx_repo
    repos_added=1
  else
    log "Skipping NGINX repository setup."
  fi

  # Temporarily disabled due to upstream MySQL apt GPG signature issues (NO_PUBKEY B7B3B788A8D3785C).
  # if prompt_yes_no "Add the official MySQL Community repository from repo.mysql.com?" "Y"; then
  #   setup_mysql_repo
  #   repos_added=1
  # else
  #   log "Skipping MySQL repository setup."
  # fi

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
  fi

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
  fi

  if prompt_yes_no "Add the Deadsnakes Python repository (ppa:deadsnakes/ppa)?" "Y"; then
    setup_python_repo
    repos_added=1
  else
    log "Skipping Python repository setup."
  fi

  if prompt_yes_no "Add the PostgreSQL Global Development Group (PGDG) repository for the latest PostgreSQL releases?" "Y"; then
    setup_postgresql_repo
    repos_added=1
  else
    log "Skipping PostgreSQL repository setup."
  fi

    if [[ "${repos_added}" -eq 1 ]]; then
      log "Refreshing package cache to include new repositories..."
      apt-get update
    else
      log "No new repositories were added; skipping apt-get update."
    fi

    if prompt_yes_no "Install the latest stable NGINX package set now?" "Y"; then
      if remove_apache2_if_present && install_nginx; then
        record_install_success "NGINX"
      else
        record_install_failure "NGINX"
      fi
    else
      log "NGINX installation skipped."
    fi

  # Temporarily disabled due to upstream MySQL apt GPG signature issues (NO_PUBKEY B7B3B788A8D3785C).
  # if prompt_yes_no "Install the latest stable MySQL Server package set now?" "Y"; then
  #   install_mysql
  # else
  #   log "MySQL installation skipped."
  # fi

    if prompt_yes_no "Install PHP, FPM, and every available PHP extension now?" "Y"; then
      if remove_apache2_if_present && install_php_stack; then
        record_install_success "PHP stack"
      else
        record_install_failure "PHP stack"
      fi
    else
      log "PHP installation skipped."
    fi

    if prompt_yes_no "Install the latest stable PostgreSQL server, client, and contrib packages now?" "Y"; then
      if install_postgresql_latest; then
        record_install_success "PostgreSQL"
      else
        record_install_failure "PostgreSQL"
      fi
    else
      log "PostgreSQL installation skipped."
    fi

    if prompt_yes_no "Install the custom Clancy Systems login MOTD?" "Y"; then
      if configure_custom_motd; then
        record_install_success "Custom MOTD"
      else
        record_install_failure "Custom MOTD"
      fi
    else
      log "Custom MOTD installation skipped."
    fi

    ensure_transfer_tool_repo
    if install_curl_wget_if_missing; then
      record_install_success "curl and wget"
    else
      record_install_failure "curl and wget"
    fi
  download_latest_mediawiki

    if prompt_yes_no "Install the latest stable Neovim release from GitHub now?" "Y"; then
      if install_neovim; then
        record_install_success "Neovim"
      else
        record_install_failure "Neovim"
      fi
    else
      log "Neovim installation skipped."
    fi

    if prompt_yes_no "Install the latest stable .NET SDK now?" "Y"; then
      if install_latest_dotnet_sdk; then
        record_install_success ".NET SDK"
      else
        record_install_failure ".NET SDK"
      fi
    else
      log ".NET installation skipped."
    fi

    if prompt_yes_no "Install PowerShell now?" "Y"; then
      if install_powershell; then
        record_install_success "PowerShell"
      else
        record_install_failure "PowerShell"
      fi
    else
      log "PowerShell installation skipped."
    fi

    if prompt_yes_no "Install the latest stable Eclipse Temurin JDK and JRE now?" "Y"; then
      if install_java_stack; then
        record_install_success "Java (Temurin JDK/JRE)"
      else
        record_install_failure "Java (Temurin JDK/JRE)"
      fi
    else
      log "Java installation skipped."
    fi

    if prompt_yes_no "Install net-tools and DNS utilities (whois, ping, dig)?" "Y"; then
      if install_network_tooling; then
        record_install_success "Network tooling"
      else
        record_install_failure "Network tooling"
      fi
    else
      log "Network tooling installation skipped."
    fi

    if prompt_yes_no "Install the latest Git and Git LFS packages now?" "Y"; then
      if install_git; then
        record_install_success "Git and Git LFS"
      else
        record_install_failure "Git and Git LFS"
      fi
    else
      log "Git installation skipped."
    fi

    if prompt_yes_no "Install Docker Engine, CLI, and plugins now?" "Y"; then
      if install_docker; then
        record_install_success "Docker"
      else
        record_install_failure "Docker"
      fi
    else
      log "Docker installation skipped."
    fi

    if prompt_yes_no "Install Python 3, pip, and common Python packages (including ngxtop) now?" "Y"; then
      if install_python_stack; then
        record_install_success "Python runtime and tooling"
      else
        record_install_failure "Python runtime and tooling"
      fi
    else
      log "Python installation skipped."
    fi

    log "Running sudo apt autoremove to clean up unused packages..."
    sudo apt autoremove -y

    log "All requested actions have completed."
    echo "success!"
    print_install_summary
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
# Call Center AI Installer
# ============================================================================
# Bootstraps a local development / operator install on Linux and macOS.
#
# It provisions what `make install` cannot provision for itself — uv, a
# Python 3.13 interpreter, git, make, a C toolchain, yq (the Makefile parses
# config.yaml with it), and optionally the Azure / Twilio / dev tunnel CLIs —
# then clones (or reuses) the checkout, creates .venv, installs the locked
# dependency set, and scaffolds config.yaml / .env.
#
# Usage:
#   ./install.sh                                  # from inside a checkout
#   curl -fsSL <raw-url>/install.sh | bash        # standalone, clones first
#
# Or with options:
#   ./install.sh --no-dev --no-optional-tools
#
# ============================================================================

set -e

# Guard against environment leakage. A pre-set PYTHONPATH makes pip/uv and the
# app's entrypoints import a different checkout than the one being installed,
# which makes a fresh install look broken or stale.
if [ -n "${PYTHONPATH:-}" ]; then
    echo "⚠ Ignoring inherited PYTHONPATH during install to avoid module shadowing"
    unset PYTHONPATH
fi
if [ -n "${PYTHONHOME:-}" ]; then
    echo "⚠ Ignoring inherited PYTHONHOME during install"
    unset PYTHONHOME
fi

# Prevent uv from discovering config files (uv.toml, pyproject.toml) from the
# wrong user's home directory when running under sudo -u <user>. The locked
# project sync re-enables project discovery for itself — see
# run_locked_uv_sync.
export UV_NO_CONFIG=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
REPO_URL_SSH="git@github.com:Redcode44/call-center-ai.git"
REPO_URL_HTTPS="https://github.com/Redcode44/call-center-ai.git"
PYTHON_VERSION="3.13"
PYTHON_SUPPORTED_RANGE=">=3.13"  # pyproject requires-python; keep in sync
YQ_VERSION="v4.44.3"             # mikefarah/yq; the Makefile relies on its syntax

# Where user-scoped binaries (uv, yq, devtunnel) are installed. This is the
# astral installer's own default, so uv lands here whether we install it or
# the user did.
LOCAL_BIN="${CCAI_LOCAL_BIN:-$HOME/.local/bin}"

# Wall-clock caps. A stalled (not failed) registry or release download never
# returns on a throttled link, so every network step is time-boxed and a stall
# becomes a non-zero exit the caller can report.
NETWORK_TIMEOUT="${CCAI_NETWORK_TIMEOUT:-600}"
DEPS_TIMEOUT="${CCAI_DEPS_TIMEOUT:-1800}"

# Options
INSTALL_DIR=""
INSTALL_DIR_EXPLICIT=false
BRANCH="main"
INSTALL_COMMIT=""
WITH_DEV=true
OPTIONAL_TOOLS=true
SCAFFOLD_CONFIG=true
NON_INTERACTIVE=false
ENSURE_DEPS=""

# Resolved during the run
OS=""
DISTRO=""
DISTRO_VERSION=""
UV_CMD=""
PYTHON_PATH=""
HAS_YQ=false
HAS_AZ=false
HAS_TWILIO=false
HAS_DEVTUNNEL=false
HAS_RUST=false
PATH_PROFILE_UPDATED=false

if [ -n "${CCAI_INSTALL_DIR:-}" ]; then
    INSTALL_DIR="$CCAI_INSTALL_DIR"
    INSTALL_DIR_EXPLICIT=true
fi

# Detect non-interactive mode (e.g. curl | bash). When stdin is not a
# terminal, `read -p` fails with EOF, which under `set -e` would silently
# abort the whole script.
if [ -t 0 ]; then
    IS_INTERACTIVE=true
else
    IS_INTERACTIVE=false
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)
            INSTALL_DIR="$2"
            INSTALL_DIR_EXPLICIT=true
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --commit)
            INSTALL_COMMIT="$2"
            if ! printf '%s' "$INSTALL_COMMIT" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
                echo "--commit expects a hex SHA (7-40 chars), got: $INSTALL_COMMIT"
                exit 1
            fi
            shift 2
            ;;
        --no-dev)
            WITH_DEV=false
            shift
            ;;
        --no-optional-tools)
            OPTIONAL_TOOLS=false
            shift
            ;;
        --skip-config)
            SCAFFOLD_CONFIG=false
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --ensure)
            ENSURE_DEPS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Call Center AI Installer"
            echo ""
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dir PATH            Checkout directory"
            echo "                          default: the current checkout, else ~/call-center-ai"
            echo "  --branch NAME         Git branch to install (default: main)"
            echo "  --commit SHA          Pin the checkout to a specific commit after clone/update"
            echo "  --no-dev              Install runtime dependencies only (skip the 'dev' extra)"
            echo "  --no-optional-tools   Skip Azure CLI / Twilio CLI / dev tunnel CLI installs"
            echo "  --skip-config         Don't scaffold config.yaml and .env"
            echo "  --non-interactive     Never prompt; take the default answer everywhere"
            echo "  --ensure DEPS         Install only the named tools (comma-separated) and exit"
            echo "                          Supported: uv, python, git, make, yq, az, twilio, devtunnel, rust"
            echo "                          Does NOT clone the repo, create .venv, or install dependencies"
            echo "  -h, --help            Show this help"
            echo ""
            echo "Notes:"
            echo "  Run from inside an existing checkout and the installer uses it in place."
            echo "  Run it standalone (curl | bash) and it clones into --dir first."
            echo "  User-scoped binaries go to \$CCAI_LOCAL_BIN (default ~/.local/bin), which"
            echo "  is added to your shell profile when it isn't already on PATH."
            echo "  Windows is not supported directly — use WSL2 or the devcontainer."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# ============================================================================
# Helper functions
# ============================================================================

print_banner() {
    echo ""
    echo -e "${MAGENTA}${BOLD}"
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│             ☎  Call Center AI Installer                 │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  AI-powered call center with Azure and OpenAI GPT.      │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
}

log_info() {
    echo -e "${CYAN}→${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

prompt_yes_no() {
    local question="$1"
    local default="${2:-yes}"
    local prompt_suffix
    local answer=""

    # Use case patterns (not ${var,,}) so this works on bash 3.2 (macOS /bin/bash).
    case "$default" in
        [yY]|[yY][eE][sS]|[tT][rR][uU][eE]|1) prompt_suffix="[Y/n]" ;;
        *) prompt_suffix="[y/N]" ;;
    esac

    if [ "$NON_INTERACTIVE" = true ]; then
        answer=""
    elif [ "$IS_INTERACTIVE" = true ]; then
        read -r -p "$question $prompt_suffix " answer || answer=""
    elif (: </dev/tty) 2>/dev/null; then
        # Piped from curl but a terminal is still reachable. Probe by actually
        # opening /dev/tty: a bare existence test passes inside container
        # builds where the device node exists but opening fails with ENXIO.
        printf "%s %s " "$question" "$prompt_suffix" > /dev/tty
        IFS= read -r answer < /dev/tty || answer=""
    else
        answer=""
    fi

    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"

    if [ -z "$answer" ]; then
        case "$default" in
            [yY]|[yY][eE][sS]|[tT][rR][uU][eE]|1) return 0 ;;
            *) return 1 ;;
        esac
    fi

    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Run a command with a hard wall-clock timeout, returning 124 if it is killed.
# Prefers GNU coreutils `timeout` (Linux) or `gtimeout` (macOS via Homebrew)
# for an external command; a shell function target always goes through the
# pure-shell watchdog, which the `timeout` binary cannot exec. The watchdog
# runs the command in its own process group and kills the whole group, so a
# stalled download's children die with it.
run_with_timeout() {
    local timeout_seconds="$1"
    shift

    case "$timeout_seconds" in
        ''|*[!0-9]*) timeout_seconds="$NETWORK_TIMEOUT" ;;
    esac

    if [ "$(type -t "$1" 2>/dev/null)" != "function" ]; then
        local timeout_bin=""
        if command -v timeout >/dev/null 2>&1; then
            timeout_bin="timeout"
        elif command -v gtimeout >/dev/null 2>&1; then
            timeout_bin="gtimeout"
        fi
        if [ -n "$timeout_bin" ]; then
            # --foreground keeps the command in the shell's foreground process
            # group so a terminal Ctrl+C reaches it; -k 10 escalates to SIGKILL
            # 10s past the deadline. Both are GNU-only, so probe once and fall
            # back to plain `timeout` on BusyBox (Alpine).
            if "$timeout_bin" --foreground -k 10 1 true >/dev/null 2>&1; then
                "$timeout_bin" --foreground -k 10 "$timeout_seconds" "$@"
            else
                "$timeout_bin" "$timeout_seconds" "$@"
            fi
            return $?
        fi
    fi

    set -m
    ( "$@" ) &
    local cmd_pid=$!
    set +m

    local waited=0
    local rc
    while [ "$waited" -lt "$timeout_seconds" ]; do
        if ! kill -0 "$cmd_pid" 2>/dev/null; then
            # `|| rc=$?` keeps the child's non-zero status without letting
            # `set -e` abort the caller here.
            rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
            return "$rc"
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Boundary recheck: don't kill (and mislabel as 124) a command that
    # finished during the last poll interval.
    if ! kill -0 "$cmd_pid" 2>/dev/null; then
        rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
        return "$rc"
    fi

    kill -TERM "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
    wait "$cmd_pid" 2>/dev/null || true
    return 124
}

# Echo the sudo prefix to use for a system package install, or nothing when
# running as root. Empty output with a non-zero return means privilege
# escalation isn't available at all, so callers can degrade instead of
# blocking on a prompt nobody can answer.
resolve_sudo() {
    if [ "$(id -u 2>/dev/null || echo 1000)" -eq 0 ]; then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        return 1
    fi
    if sudo -n true 2>/dev/null; then
        echo "sudo"
        return 0
    fi
    # sudo exists but needs a password. Only usable when someone can type it.
    if [ "$NON_INTERACTIVE" = false ] && { [ "$IS_INTERACTIVE" = true ] || (: </dev/tty) 2>/dev/null; }; then
        echo "sudo"
        return 0
    fi
    return 1
}

# Best-effort system package install, one package set per distro family.
# Never fatal: every caller decides whether a miss is a warning or an abort.
install_system_packages() {
    local sudo_cmd=""
    sudo_cmd="$(resolve_sudo)" || {
        log_warn "No root access available — cannot install: $*"
        return 1
    }

    case "$DISTRO" in
        ubuntu|debian|raspbian|pop|linuxmint|elementary|zorin|kali|parrot)
            $sudo_cmd env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                apt-get update -qq >/dev/null 2>&1 || true
            $sudo_cmd env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                apt-get install -y -qq "$@" >/dev/null 2>&1 || return 1
            ;;
        fedora|rhel|centos|rocky|alma)
            $sudo_cmd dnf install -y "$@" >/dev/null 2>&1 || return 1
            ;;
        arch|manjaro|cachyos|endeavouros|garuda)
            $sudo_cmd pacman -S --noconfirm --needed "$@" >/dev/null 2>&1 || return 1
            ;;
        opensuse*|sles)
            $sudo_cmd zypper --non-interactive install "$@" >/dev/null 2>&1 || return 1
            ;;
        macos)
            command -v brew >/dev/null 2>&1 || return 1
            brew install "$@" >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

show_manual_install_hint() {
    local pkg="$1"
    log_info "To install $pkg manually:"
    case "$OS" in
        linux)
            case "$DISTRO" in
                ubuntu|debian) log_info "  sudo apt install $pkg" ;;
                fedora|rhel|centos|rocky|alma) log_info "  sudo dnf install $pkg" ;;
                arch|manjaro) log_info "  sudo pacman -S $pkg" ;;
                opensuse*|sles) log_info "  sudo zypper install $pkg" ;;
                *) log_info "  Use your package manager or visit the project homepage" ;;
            esac
            ;;
        macos) log_info "  brew install $pkg" ;;
    esac
}

arch_suffix() {
    # Normalized architecture for GitHub release asset names.
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

# Add $LOCAL_BIN to PATH for this process, and persist it in the login shell's
# config when it isn't there already. uv, yq, and devtunnel all land in it, so
# without this a fresh install "works" until the next shell.
ensure_local_bin_on_path() {
    mkdir -p "$LOCAL_BIN"

    case ":$PATH:" in
        *":$LOCAL_BIN:"*) ;;
        *) export PATH="$LOCAL_BIN:$PATH" ;;
    esac

    # Only rewrite shell config for the conventional location; a custom
    # CCAI_LOCAL_BIN is the caller's to manage.
    if [ "$LOCAL_BIN" != "$HOME/.local/bin" ]; then
        return 0
    fi

    local login_shell
    login_shell="$(basename "${SHELL:-/bin/bash}")"

    if [ "$login_shell" = "fish" ]; then
        local fish_config="$HOME/.config/fish/config.fish"
        mkdir -p "$(dirname "$fish_config")"
        touch "$fish_config"
        if ! grep -q 'fish_add_path.*\.local/bin' "$fish_config" 2>/dev/null; then
            {
                echo ""
                echo "# Call Center AI — ensure ~/.local/bin is on PATH"
                echo 'fish_add_path "$HOME/.local/bin"'
            } >> "$fish_config"
            PATH_PROFILE_UPDATED=true
            log_success "Added ~/.local/bin to PATH in $fish_config"
        fi
        return 0
    fi

    local configs=()
    case "$login_shell" in
        zsh)
            [ -f "$HOME/.zshrc" ] && configs+=("$HOME/.zshrc")
            [ -f "$HOME/.zprofile" ] && configs+=("$HOME/.zprofile")
            # Fresh macOS accounts have neither.
            if [ "${#configs[@]}" -eq 0 ]; then
                touch "$HOME/.zshrc"
                configs+=("$HOME/.zshrc")
            fi
            ;;
        bash)
            [ -f "$HOME/.bashrc" ] && configs+=("$HOME/.bashrc")
            [ -f "$HOME/.bash_profile" ] && configs+=("$HOME/.bash_profile")
            if [ "${#configs[@]}" -eq 0 ]; then
                touch "$HOME/.bashrc"
                configs+=("$HOME/.bashrc")
            fi
            ;;
        *)
            [ -f "$HOME/.bashrc" ] && configs+=("$HOME/.bashrc")
            [ -f "$HOME/.zshrc" ] && configs+=("$HOME/.zshrc")
            ;;
    esac
    # Login shells on Ubuntu/Debian/WSL source ~/.profile even when ~/.bashrc
    # is skipped.
    [ -f "$HOME/.profile" ] && configs+=("$HOME/.profile")

    local config
    for config in "${configs[@]}"; do
        if ! grep -v '^[[:space:]]*#' "$config" 2>/dev/null | grep -qE 'PATH=.*\.local/bin'; then
            {
                echo ""
                echo "# Call Center AI — ensure ~/.local/bin is on PATH"
                echo 'export PATH="$HOME/.local/bin:$PATH"'
            } >> "$config"
            PATH_PROFILE_UPDATED=true
            log_success "Added ~/.local/bin to PATH in $config"
        fi
    done
}

# ============================================================================
# System detection
# ============================================================================

detect_os() {
    case "$(uname -s)" in
        Linux*)
            if [ -n "${TERMUX_VERSION:-}" ] || [[ "${PREFIX:-}" == *"com.termux/files/usr"* ]]; then
                log_error "Termux / Android is not supported."
                log_info "This project needs Python 3.13 plus the Azure Speech SDK, which"
                log_info "publishes no Android wheels. Use Linux, macOS, WSL2, or the devcontainer."
                exit 1
            fi
            OS="linux"
            if [ -f /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                DISTRO="$ID"
                DISTRO_VERSION="${VERSION_ID:-}"
            else
                DISTRO="unknown"
                DISTRO_VERSION=""
            fi
            ;;
        Darwin*)
            OS="macos"
            DISTRO="macos"
            DISTRO_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            log_error "Windows detected. This installer needs a POSIX shell."
            log_info "Use WSL2 and re-run there, or open the repo in the devcontainer:"
            log_info "  https://codespaces.new/microsoft/call-center-ai?quickstart=1"
            exit 1
            ;;
        *)
            OS="unknown"
            DISTRO="unknown"
            log_warn "Unknown operating system — continuing, but nothing is verified here"
            ;;
    esac

    log_success "Detected: $OS ($DISTRO${DISTRO_VERSION:+ $DISTRO_VERSION})"
}

# True when $1 answers an HTTPS request. Some corporate proxies reject HEAD
# (405/403) while passing GET, so a failed HEAD is retried as a 1-byte ranged
# GET before the host is called unreachable.
url_reachable() {
    curl -fsSI --max-time 8 "$1" >/dev/null 2>&1 \
        || curl -fsS --max-time 8 --range 0-0 -o /dev/null "$1" >/dev/null 2>&1
}

check_network_prerequisites() {
    log_info "Checking connectivity to the hosts this install needs..."

    local pypi_ok=true

    # PyPI is the one hard requirement: without it there are no dependencies.
    if command -v curl >/dev/null 2>&1; then
        if url_reachable "https://pypi.org/simple/"; then
            log_success "PyPI reachable"
        else
            pypi_ok=false
            log_warn "Could not reach https://pypi.org/simple/ — dependency installation will fail"
        fi
    else
        log_warn "curl not found; skipping the PyPI probe"
    fi

    # Probe the repository with git rather than a plain GET on github.com:
    # it is the operation clone_repo actually performs, and a proxy that
    # blocks the website can still pass the git endpoints.
    if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
        if run_with_timeout 15 env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true \
            git ls-remote --exit-code --heads "$REPO_URL_HTTPS" >/dev/null 2>&1; then
            log_success "Repository reachable over HTTPS"
        else
            log_info "Could not list refs of $REPO_URL_HTTPS over HTTPS."
            log_info "Expected for a private repository — SSH is tried first when cloning."
        fi
    fi

    if [ "$pypi_ok" = false ]; then
        log_warn "Check DNS and proxy settings (HTTPS_PROXY is honored by curl, git, and uv), then retry."
    fi
}

# ============================================================================
# Toolchain
# ============================================================================

install_uv() {
    # uv drives everything downstream: the interpreter, the venv, and the
    # locked dependency install. Reuse one already on PATH, then the managed
    # copy in $LOCAL_BIN, then install it there.
    if command -v uv >/dev/null 2>&1; then
        UV_CMD="$(command -v uv)"
        log_success "uv found ($($UV_CMD --version 2>/dev/null))"
        return 0
    fi

    if [ -x "$LOCAL_BIN/uv" ]; then
        UV_CMD="$LOCAL_BIN/uv"
        log_success "uv found ($($UV_CMD --version 2>/dev/null))"
        return 0
    fi

    log_info "Installing uv into $LOCAL_BIN ..."
    mkdir -p "$LOCAL_BIN"

    # Two-stage: download the installer, then run it. Piping `curl | sh` masks
    # curl failures (sh exits 0 on empty stdin) and conflates a network error
    # with an installer error.
    local install_log installer
    install_log="$(mktemp)"
    installer="$(mktemp)"
    if ! run_with_timeout "$NETWORK_TIMEOUT" curl -LsSf https://astral.sh/uv/install.sh -o "$installer" 2>"$install_log"; then
        log_error "Failed to download the uv installer from https://astral.sh/uv/install.sh"
        sed 's/^/    /' "$install_log" >&2
        log_info "Install manually: https://docs.astral.sh/uv/getting-started/installation/"
        rm -f "$install_log" "$installer"
        exit 1
    fi

    # UV_UNMANAGED_INSTALL puts the binary in our directory and skips the
    # installer's own shell-profile edits (ensure_local_bin_on_path owns that).
    if UV_UNMANAGED_INSTALL="$LOCAL_BIN" sh "$installer" >>"$install_log" 2>&1 && [ -x "$LOCAL_BIN/uv" ]; then
        UV_CMD="$LOCAL_BIN/uv"
        rm -f "$install_log" "$installer"
        log_success "uv installed ($($UV_CMD --version 2>/dev/null))"
        return 0
    fi

    log_error "Failed to install uv"
    log_info "Installer output:"
    sed 's/^/    /' "$install_log" >&2
    log_info "Install manually: https://docs.astral.sh/uv/getting-started/installation/"
    rm -f "$install_log" "$installer"
    exit 1
}

check_python() {
    log_info "Checking Python $PYTHON_VERSION..."

    if [ -z "$UV_CMD" ]; then
        install_uv
    fi

    # --system: with the project's own .venv activated (a re-run), a bare
    # `uv python find` returns .venv/bin/python, which setup_venv is about to
    # delete out from under itself.
    if PYTHON_PATH="$("$UV_CMD" python find --system "$PYTHON_SUPPORTED_RANGE" 2>/dev/null)"; then
        log_success "Python found: $("$PYTHON_PATH" --version 2>/dev/null) ($PYTHON_PATH)"
        return 0
    fi

    log_info "No Python $PYTHON_SUPPORTED_RANGE found — installing $PYTHON_VERSION via uv (no sudo needed)..."
    if run_with_timeout "$NETWORK_TIMEOUT" "$UV_CMD" python install "$PYTHON_VERSION"; then
        PYTHON_PATH="$("$UV_CMD" python find "$PYTHON_VERSION")"
        log_success "Python installed: $("$PYTHON_PATH" --version 2>/dev/null)"
        return 0
    fi

    log_error "Failed to install Python $PYTHON_VERSION"
    log_info "Install Python $PYTHON_VERSION manually, then re-run this script"
    exit 1
}

check_git() {
    log_info "Checking Git..."

    # On a fresh macOS, /usr/bin/git is a stub that exits non-zero until the
    # Command Line Tools are installed, so probe by running it.
    if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
        log_success "Git $(git --version | awk '{print $3}') found"
        return 0
    fi

    log_info "Git not found — attempting to install it..."

    if [ "$OS" = "macos" ]; then
        if command -v brew >/dev/null 2>&1; then
            brew install git >/dev/null 2>&1 || true
        fi
        if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
            # The Command Line Tools ship git AND the compiler some wheels
            # need. Apple gates them behind a GUI dialog that cannot be
            # suppressed without MDM, so trigger it and poll.
            if command -v xcode-select >/dev/null 2>&1; then
                log_info "Requesting Apple Command Line Tools (provides git + a C compiler)..."
                log_info 'If a macOS dialog appears, click "Install" and accept the license.'
                xcode-select --install >/dev/null 2>&1 || true
                local waited=0
                while [ "$waited" -lt 900 ]; do
                    if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
                        break
                    fi
                    sleep 5
                    waited=$((waited + 5))
                    if [ $((waited % 60)) -eq 0 ]; then
                        log_info "Still waiting for the Command Line Tools install ($((waited / 60))m)..."
                    fi
                done
            fi
        fi
    else
        install_system_packages git || true
    fi

    if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
        log_success "Git $(git --version | awk '{print $3}') installed"
        return 0
    fi

    log_error "Could not install Git automatically. Install it manually and re-run:"
    show_manual_install_hint git
    exit 1
}

check_make() {
    log_info "Checking make (this project is driven by its Makefile)..."

    if command -v make >/dev/null 2>&1; then
        log_success "$(make --version 2>/dev/null | head -1) found"
        return 0
    fi

    log_info "make not found — attempting to install it..."
    if [ "$OS" = "macos" ]; then
        # make comes with the Command Line Tools, which check_git already
        # triggers; brew's `make` installs as `gmake`, so don't rely on it.
        install_system_packages make || true
    else
        case "$DISTRO" in
            arch|manjaro|cachyos|endeavouros|garuda) install_system_packages base-devel || true ;;
            *) install_system_packages make || true ;;
        esac
    fi

    if command -v make >/dev/null 2>&1; then
        log_success "make installed"
        return 0
    fi

    log_warn "make is not available — the documented workflow (make install / dev / deploy) won't run."
    log_info "This installer still completes; install make later to use the Makefile targets."
    show_manual_install_hint make
}

check_build_tools() {
    # Most dependencies ship wheels for CPython 3.13 on x86_64/arm64, but a
    # source build (noisereduce's scientific stack, or any package without a
    # wheel for this platform) needs a compiler and the Python headers. Warn
    # early instead of surfacing it as a wall of gcc output inside `uv sync`.
    log_info "Checking C toolchain (needed when a dependency has no wheel for this platform)..."

    if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
        log_success "C compiler found"
        return 0
    fi

    log_info "No C compiler found — attempting to install one..."
    case "$OS" in
        macos)
            log_info 'If a macOS dialog appears, click "Install" and accept the license.'
            xcode-select --install >/dev/null 2>&1 || true
            ;;
        linux)
            case "$DISTRO" in
                ubuntu|debian|raspbian|pop|linuxmint|elementary|zorin|kali|parrot)
                    install_system_packages build-essential python3-dev libffi-dev || true
                    ;;
                fedora|rhel|centos|rocky|alma)
                    install_system_packages gcc gcc-c++ python3-devel libffi-devel || true
                    ;;
                arch|manjaro|cachyos|endeavouros|garuda)
                    install_system_packages base-devel libffi || true
                    ;;
                opensuse*|sles)
                    install_system_packages gcc gcc-c++ python3-devel libffi-devel || true
                    ;;
            esac
            ;;
    esac

    if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
        log_success "C compiler installed"
        return 0
    fi

    log_warn "No C compiler available. Dependency installation will still be attempted,"
    log_warn "but any package without a prebuilt wheel for this platform will fail to build."
}

check_rust() {
    # README lists Rust as a prerequisite: it is only needed when a
    # Rust-backed dependency (pydantic-core, tiktoken, ...) has to be built
    # from source. Report it, offer rustup, never block on it.
    if command -v cargo >/dev/null 2>&1; then
        HAS_RUST=true
        log_success "Rust found ($(cargo --version 2>/dev/null | awk '{print $2}'))"
        return 0
    fi

    HAS_RUST=false
    log_info "Rust not found (only needed to build Rust-backed dependencies from source)"

    if [ "$OPTIONAL_TOOLS" = false ]; then
        return 0
    fi
    if ! prompt_yes_no "Install Rust via rustup?" "no"; then
        log_info "Skipped. Install later with: https://rustup.rs"
        return 0
    fi

    local rustup_script
    rustup_script="$(mktemp)"
    if run_with_timeout "$NETWORK_TIMEOUT" curl -fsSL https://sh.rustup.rs -o "$rustup_script" \
        && run_with_timeout "$NETWORK_TIMEOUT" sh "$rustup_script" -y --no-modify-path >/dev/null 2>&1; then
        export PATH="$HOME/.cargo/bin:$PATH"
        if command -v cargo >/dev/null 2>&1; then
            HAS_RUST=true
            log_success "Rust installed ($(cargo --version 2>/dev/null | awk '{print $2}'))"
        fi
    else
        log_warn "Rust install failed — install manually from https://rustup.rs if a build needs it"
    fi
    rm -f "$rustup_script"
}

check_yq() {
    # The Makefile reads config.yaml and Azure output with yq, using
    # mikefarah/yq (Go) syntax. Debian and some other distros ship the
    # unrelated python-yq under the same command name, whose expression
    # syntax differs — so verify which one is on PATH rather than just
    # checking for the binary.
    log_info "Checking yq (the Makefile parses config.yaml with it)..."

    if command -v yq >/dev/null 2>&1; then
        local yq_banner
        yq_banner="$(yq --version 2>&1 || true)"
        case "$yq_banner" in
            *mikefarah*)
                HAS_YQ=true
                log_success "yq found ($yq_banner)"
                return 0
                ;;
            *)
                log_warn "The yq on PATH is not mikefarah/yq: $yq_banner"
                log_warn "The Makefile's expressions need the Go implementation."
                log_info "Installing it into $LOCAL_BIN ..."
                ;;
        esac
    fi

    local arch os_name
    if ! arch="$(arch_suffix)"; then
        log_warn "No yq release for $(uname -m) — install it manually: https://github.com/mikefarah/yq"
        return 0
    fi
    case "$OS" in
        macos) os_name="darwin" ;;
        linux) os_name="linux" ;;
        *)
            log_warn "No yq release for this OS — install it manually: https://github.com/mikefarah/yq"
            return 0
            ;;
    esac

    mkdir -p "$LOCAL_BIN"
    local url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${os_name}_${arch}"
    local tmp
    tmp="$(mktemp)"
    if run_with_timeout "$NETWORK_TIMEOUT" curl -fsSL "$url" -o "$tmp"; then
        chmod +x "$tmp"
        # Verify before publishing: a captive portal or an HTML error page
        # would otherwise be installed as an unrunnable "yq".
        if "$tmp" --version >/dev/null 2>&1; then
            mv -f "$tmp" "$LOCAL_BIN/yq"
            chmod 755 "$LOCAL_BIN/yq"
            HAS_YQ=true
            log_success "yq installed ($("$LOCAL_BIN/yq" --version 2>&1))"
            # $LOCAL_BIN may sit after /usr/bin on PATH, so a pre-existing
            # python-yq can still win. Say so rather than leaving the user to
            # discover it through a broken Makefile target.
            if ! yq --version 2>&1 | grep -q mikefarah; then
                log_warn "'yq' on PATH still resolves to $(command -v yq) — put $LOCAL_BIN first,"
                log_warn "or remove the other yq, or the Makefile's yq expressions will fail."
            fi
            return 0
        fi
    fi
    rm -f "$tmp"
    log_warn "Could not install yq automatically — some Makefile targets will fail."
    log_info "Install it manually: https://github.com/mikefarah/yq#install"
}

check_azure_cli() {
    # Required for every deploy / logs / sync-local-config target, but not for
    # running the app locally against an existing config, so it stays optional.
    if command -v az >/dev/null 2>&1; then
        HAS_AZ=true
        log_success "Azure CLI found ($(az --version 2>/dev/null | awk '/^azure-cli/ {print $2; exit}'))"
        install_bicep
        return 0
    fi

    log_info "Azure CLI not found (needed for 'make deploy', 'make logs', 'make sync-local-config')"
    if ! prompt_yes_no "Install the Azure CLI?" "yes"; then
        log_info "Skipped. Install later: https://learn.microsoft.com/cli/azure/install-azure-cli"
        return 0
    fi

    case "$OS" in
        macos)
            install_system_packages azure-cli || true
            ;;
        linux)
            case "$DISTRO" in
                ubuntu|debian|raspbian|pop|linuxmint|elementary|zorin|kali|parrot)
                    local sudo_cmd deb_script
                    if sudo_cmd="$(resolve_sudo)"; then
                        deb_script="$(mktemp)"
                        if run_with_timeout "$NETWORK_TIMEOUT" curl -fsSL https://aka.ms/InstallAzureCLIDeb -o "$deb_script"; then
                            run_with_timeout "$NETWORK_TIMEOUT" $sudo_cmd bash "$deb_script" >/dev/null 2>&1 || true
                        fi
                        rm -f "$deb_script"
                    else
                        log_warn "No root access — cannot install the Azure CLI"
                    fi
                    ;;
                arch|manjaro|cachyos|endeavouros|garuda)
                    install_system_packages azure-cli || true
                    ;;
                *)
                    install_system_packages azure-cli || true
                    ;;
            esac
            ;;
    esac

    if command -v az >/dev/null 2>&1; then
        HAS_AZ=true
        log_success "Azure CLI installed"
        install_bicep
    else
        log_warn "Could not install the Azure CLI automatically."
        log_info "Install it manually: https://learn.microsoft.com/cli/azure/install-azure-cli"
    fi
}

install_bicep() {
    # `make deploy-bicep` and `make test-static` both invoke az bicep, which
    # needs the extension installed once. Best-effort.
    command -v az >/dev/null 2>&1 || return 0
    if az bicep version >/dev/null 2>&1; then
        log_success "Bicep CLI ready"
        return 0
    fi
    log_info "Installing the Bicep CLI (used by 'make deploy' and 'make test-static')..."
    if run_with_timeout "$NETWORK_TIMEOUT" az bicep install >/dev/null 2>&1; then
        log_success "Bicep CLI installed"
    else
        log_warn "Bicep CLI install failed — run 'az bicep install' later"
    fi
}

check_twilio_cli() {
    # Only used by `make twilio-register`, so entirely optional.
    if command -v twilio >/dev/null 2>&1; then
        HAS_TWILIO=true
        log_success "Twilio CLI found"
        return 0
    fi

    log_info "Twilio CLI not found (only needed for SMS via 'make twilio-register')"
    if ! prompt_yes_no "Install the Twilio CLI?" "no"; then
        log_info "Skipped. Install later: https://www.twilio.com/docs/twilio-cli/getting-started/install"
        return 0
    fi

    if [ "$OS" = "macos" ] && command -v brew >/dev/null 2>&1; then
        brew tap twilio/brew >/dev/null 2>&1 || true
        brew install twilio >/dev/null 2>&1 || true
    elif command -v npm >/dev/null 2>&1; then
        run_with_timeout "$NETWORK_TIMEOUT" npm install -g twilio-cli >/dev/null 2>&1 || true
    fi

    if command -v twilio >/dev/null 2>&1; then
        HAS_TWILIO=true
        log_success "Twilio CLI installed"
    else
        log_warn "Could not install the Twilio CLI automatically."
        log_info "Install it manually: https://www.twilio.com/docs/twilio-cli/getting-started/install"
    fi
}

check_devtunnel() {
    # `make tunnel` exposes the local app to Communication Services webhooks.
    if command -v devtunnel >/dev/null 2>&1; then
        HAS_DEVTUNNEL=true
        log_success "Azure Dev tunnels CLI found"
        return 0
    fi

    log_info "Dev tunnels CLI not found (needed by 'make tunnel' for local webhook testing)"
    if ! prompt_yes_no "Install the Azure Dev tunnels CLI?" "yes"; then
        log_info "Skipped. Install later: https://aka.ms/DevTunnelCliInstall"
        return 0
    fi

    local script
    script="$(mktemp)"
    if run_with_timeout "$NETWORK_TIMEOUT" curl -fsSL https://aka.ms/DevTunnelCliInstall -o "$script"; then
        run_with_timeout "$NETWORK_TIMEOUT" bash "$script" >/dev/null 2>&1 || true
    fi
    rm -f "$script"

    # The installer drops the binary in ~/bin or ~/.local/bin depending on
    # platform; pick it up for this process either way.
    if [ -x "$HOME/bin/devtunnel" ]; then
        case ":$PATH:" in
            *":$HOME/bin:"*) ;;
            *) export PATH="$HOME/bin:$PATH" ;;
        esac
    fi

    if command -v devtunnel >/dev/null 2>&1; then
        HAS_DEVTUNNEL=true
        log_success "Azure Dev tunnels CLI installed"
    else
        log_warn "Could not install the Dev tunnels CLI automatically."
        log_info "Install it manually: https://aka.ms/DevTunnelCliInstall"
    fi
}

install_optional_tools() {
    if [ "$OPTIONAL_TOOLS" = false ]; then
        log_info "Skipping Azure CLI / Twilio CLI / Dev tunnels CLI (--no-optional-tools)"
        return 0
    fi
    check_azure_cli
    check_twilio_cli
    check_devtunnel
}

# ============================================================================
# Checkout
# ============================================================================

# True when $1 looks like a call-center-ai checkout.
is_project_checkout() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -f "$dir/pyproject.toml" ] || return 1
    [ -f "$dir/Makefile" ] || return 1
    grep -q '^name = "call-center-ai"' "$dir/pyproject.toml" 2>/dev/null
}

# Pick the directory to install into: an explicit --dir, the checkout this
# script lives in, the checkout we were invoked from, or a fresh clone.
resolve_install_dir() {
    if [ "$INSTALL_DIR_EXPLICIT" = true ]; then
        log_info "Install directory: $INSTALL_DIR (explicit)"
        return 0
    fi

    # `curl | bash` leaves BASH_SOURCE unusable (it names the shell or stdin),
    # so only trust it when it resolves to a real file.
    local script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if is_project_checkout "$script_dir"; then
        INSTALL_DIR="$script_dir"
        log_success "Using the checkout this script lives in: $INSTALL_DIR"
        return 0
    fi
    if is_project_checkout "$PWD"; then
        INSTALL_DIR="$PWD"
        log_success "Using the current checkout: $INSTALL_DIR"
        return 0
    fi

    INSTALL_DIR="$HOME/call-center-ai"
    log_info "No checkout detected — will clone into $INSTALL_DIR"
}

clone_repo() {
    # Installing in place: leave the user's branch, remote, and local commits
    # alone. Re-running the installer must never move someone's working
    # checkout, and --branch / --commit are clone-time options here.
    if is_project_checkout "$INSTALL_DIR"; then
        cd "$INSTALL_DIR"
        if [ -d "$INSTALL_DIR/.git" ]; then
            log_info "Existing checkout on $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'a detached HEAD') — left as is"
            if [ -n "$INSTALL_COMMIT" ] || [ "$BRANCH" != "main" ]; then
                log_warn "--branch/--commit are ignored for an existing checkout; switch it yourself with git."
            fi
        fi
        return 0
    fi

    if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        log_error "$INSTALL_DIR exists and is not a call-center-ai checkout."
        log_info "Remove it, or choose another directory with --dir PATH"
        exit 1
    fi

    log_info "Cloning $BRANCH into $INSTALL_DIR ..."

    # Try SSH first (works for a private fork with a configured key), then
    # HTTPS. BatchMode + a short timeout make SSH fail fast instead of hanging
    # on a passphrase or host-key prompt.
    if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" \
        git clone --depth 1 --single-branch --branch "$BRANCH" "$REPO_URL_SSH" "$INSTALL_DIR" 2>/dev/null; then
        log_success "Cloned via SSH"
    else
        rm -rf "$INSTALL_DIR" 2>/dev/null || true  # partial SSH clone is unusable
        log_info "SSH unavailable — cloning over HTTPS..."

        local clone_ok=false
        local attempt
        for attempt in 1 2 3 4; do
            [ "$attempt" -gt 1 ] && log_info "Retrying HTTPS clone (attempt $attempt/4)..."
            if git clone --depth 1 --single-branch --branch "$BRANCH" "$REPO_URL_HTTPS" "$INSTALL_DIR"; then
                clone_ok=true
                break
            fi
            rm -rf "$INSTALL_DIR" 2>/dev/null || true
            [ "$attempt" -lt 4 ] && sleep $((attempt * 5))
        done

        if [ "$clone_ok" != true ]; then
            log_error "Failed to clone $REPO_URL_HTTPS"
            log_info "Check network access to github.com, then re-run this script."
            exit 1
        fi
        log_success "Cloned via HTTPS"
    fi

    cd "$INSTALL_DIR"

    if [ -n "$INSTALL_COMMIT" ]; then
        if ! git cat-file -e "$INSTALL_COMMIT^{commit}" 2>/dev/null; then
            # A shallow clone has one commit, so the pin almost always needs
            # fetching. Abbreviated SHAs cannot be fetched by name.
            if ! git fetch --depth 1 origin "$INSTALL_COMMIT"; then
                log_error "Could not fetch commit $INSTALL_COMMIT from origin."
                log_error "Abbreviated SHAs are not fetchable — use the full 40-char hash."
                exit 1
            fi
        fi
        log_info "Pinning the checkout to $INSTALL_COMMIT ..."
        if ! git checkout --detach "$INSTALL_COMMIT"; then
            log_error "Failed to check out $INSTALL_COMMIT"
            exit 1
        fi
    fi

    log_success "Repository ready at $INSTALL_DIR"
}

init_submodules() {
    [ -f "$INSTALL_DIR/.gitmodules" ] || return 0
    log_info "Initializing Git submodules (cicd/version powers 'make version')..."
    if (cd "$INSTALL_DIR" && run_with_timeout "$NETWORK_TIMEOUT" git submodule update --init --recursive); then
        log_success "Submodules ready"
    else
        log_warn "Submodule checkout failed — 'make version' and 'make dev' will not resolve a version."
        log_info "Retry later with: git submodule update --init --recursive"
    fi
}

# ============================================================================
# Python environment
# ============================================================================

setup_venv() {
    cd "$INSTALL_DIR"
    log_info "Creating the virtual environment with Python $PYTHON_VERSION..."

    # Match the Makefile: `uv venv --python 3.13 --allow-existing`, so a
    # re-run reuses a healthy .venv instead of forcing a full rebuild.
    if ! run_with_timeout "$NETWORK_TIMEOUT" "$UV_CMD" venv .venv --python "$PYTHON_VERSION" --allow-existing \
        || [ ! -x ".venv/bin/python" ]; then
        log_error "Failed to create .venv with Python $PYTHON_VERSION"
        exit 1
    fi

    # Neutralize an inherited UV_PYTHON (e.g. UV_PYTHON=3.12 left in the
    # shell): uv honors it over an existing venv, so the sync below would
    # silently recreate .venv at the wrong version. Pinning it to the
    # interpreter we just created forces every later uv command onto it.
    export UV_PYTHON="$INSTALL_DIR/.venv/bin/python"

    log_success "Virtual environment ready ($(./.venv/bin/python --version 2>/dev/null))"
}

run_locked_uv_sync() {
    # Bootstrap uv calls stay isolated from ambient config via UV_NO_CONFIG.
    # A locked project sync is different: uv.lock records resolver settings
    # from this checkout's pyproject.toml, so hiding the project file makes uv
    # reject a valid lock and fall through to an unlocked resolve. Re-enable
    # project discovery for this subprocess only, while still redirecting
    # user/system config lookups into an empty directory. HOME is left alone so
    # caches, credentials, and git keep working.
    local extra_args=("$@")
    local isolated_config sync_rc
    isolated_config="$(mktemp -d)" || return 1

    (
        unset UV_NO_CONFIG UV_CONFIG_FILE
        export XDG_CONFIG_HOME="$isolated_config"
        export XDG_CONFIG_DIRS="$isolated_config"
        UV_PROJECT_ENVIRONMENT="$INSTALL_DIR/.venv" "$UV_CMD" sync "${extra_args[@]}"
    )
    sync_rc=$?
    rmdir "$isolated_config" 2>/dev/null || true
    return "$sync_rc"
}

install_deps() {
    cd "$INSTALL_DIR"

    local sync_args=()
    if [ "$WITH_DEV" = true ]; then
        sync_args+=(--extra dev)
    fi

    # Tier 0 — hash-verified install. uv.lock pins every transitive with a
    # hash, so a package republished with different content is REJECTED by the
    # resolver. This is the only tier with that property: the fallbacks below
    # re-resolve against PyPI without it, and exist so an install still
    # completes when the lockfile is stale or out of sync with pyproject.toml.
    if [ -f "uv.lock" ]; then
        log_info "Installing dependencies from uv.lock (hash-verified)..."
        log_info "(first run on a fresh venv downloads the full dependency set — 1-5 minutes)"
        if run_with_timeout "$DEPS_TIMEOUT" run_locked_uv_sync --locked "${sync_args[@]}"; then
            log_success "Dependencies installed (hash-verified via uv.lock)"
            return 0
        fi
        log_warn "Locked sync failed (see the uv output above) — the lockfile may be out of date."
        log_warn "Falling back to a fresh PyPI resolve; this does NOT verify hashes."
    else
        log_info "uv.lock not found — resolving from PyPI (no hash verification)"
    fi

    # Tier 1 — unlocked sync: same dependency set, freshly resolved.
    log_info "Resolving and installing dependencies..."
    if run_with_timeout "$DEPS_TIMEOUT" run_locked_uv_sync "${sync_args[@]}"; then
        log_success "Dependencies installed (unlocked resolve)"
        log_warn "Consider running 'uv lock' and committing the refreshed lockfile."
        return 0
    fi

    # Tier 2 — runtime only. The dev extra pulls linters, a type checker, and
    # an eval framework; dropping it still yields a runnable app.
    if [ "$WITH_DEV" = true ]; then
        log_warn "Install with the 'dev' extra failed — retrying with runtime dependencies only..."
        if run_with_timeout "$DEPS_TIMEOUT" run_locked_uv_sync; then
            log_success "Runtime dependencies installed (the 'dev' extra was skipped)"
            log_warn "Tests and linters are unavailable until 'uv sync --extra dev' succeeds."
            return 0
        fi
    fi

    log_error "Dependency installation failed."
    log_info "Common causes: no C compiler or Python headers for a source build,"
    log_info "an unreachable PyPI, or a dependency with no wheel for this platform."
    log_info "Retry manually to see the full resolver output:"
    log_info "  cd $INSTALL_DIR && uv sync --extra dev"
    exit 1
}

# ============================================================================
# Configuration
# ============================================================================

scaffold_config() {
    if [ "$SCAFFOLD_CONFIG" = false ]; then
        log_info "Skipping config scaffolding (--skip-config)"
        return 0
    fi

    cd "$INSTALL_DIR"
    log_info "Setting up configuration files..."

    if [ -f "config.yaml" ]; then
        log_info "config.yaml already exists, keeping it"
    elif [ -f "config-local-example.yaml" ]; then
        cp "config-local-example.yaml" "config.yaml"
        log_success "Created config.yaml from config-local-example.yaml"
        log_warn "config.yaml holds placeholder values — fill them in before running the app."
        log_info "Already deployed on Azure? Overwrite it with the live config:"
        log_info "  make sync-local-config name=my-rg-name"
    else
        log_warn "config-local-example.yaml not found — create config.yaml manually"
    fi

    if [ -f ".env" ]; then
        log_info ".env already exists, keeping it"
    elif [ -f ".env.example" ]; then
        cp ".env.example" ".env"
        log_success "Created .env from .env.example (optional: Service Principal, App Insights)"
    fi

    # .env holds a client secret and a telemetry connection string, so keep it
    # owner-only — the convention for credential files (.netrc, .aws/credentials).
    if [ -f ".env" ]; then
        chmod 600 ".env"
    fi
}

verify_install() {
    cd "$INSTALL_DIR"
    log_info "Verifying the installation..."

    if [ ! -x ".venv/bin/python" ]; then
        log_error "No interpreter at .venv/bin/python — the install did not complete."
        exit 1
    fi

    # Import a few of the heaviest third-party entry points rather than the app
    # itself: app.main reads config.yaml at import time, which still holds
    # placeholders on a fresh install.
    local import_log
    import_log="$(mktemp)"
    if ./.venv/bin/python -c 'import fastapi, granian, azure.identity, yaml' >"$import_log" 2>&1; then
        log_success "Core dependencies import cleanly"
    else
        log_error "Core dependencies failed to import:"
        sed 's/^/    /' "$import_log" >&2
        rm -f "$import_log"
        log_info "Retry with: cd $INSTALL_DIR && uv sync --extra dev"
        exit 1
    fi
    rm -f "$import_log"
}

print_success() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│              ✓ Installation Complete!                   │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}📁 Your files:${NC}"
    echo ""
    echo -e "   ${YELLOW}Code:${NC}      $INSTALL_DIR"
    echo -e "   ${YELLOW}Config:${NC}    $INSTALL_DIR/config.yaml"
    echo -e "   ${YELLOW}Secrets:${NC}   $INSTALL_DIR/.env"
    echo -e "   ${YELLOW}Venv:${NC}      $INSTALL_DIR/.venv"
    echo ""

    echo -e "${CYAN}─────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}🚀 Next steps:${NC}"
    echo ""
    echo -e "   ${GREEN}1.${NC} Fill in $INSTALL_DIR/config.yaml"
    echo -e "      (or ${GREEN}make sync-local-config name=my-rg-name${NC} to pull it from Azure)"
    echo -e "   ${GREEN}2.${NC} ${GREEN}make tunnel${NC}   Expose port 8080 so Communication Services can call back"
    echo -e "   ${GREEN}3.${NC} ${GREEN}make dev${NC}      Run the app locally with reload"
    echo ""
    echo -e "${CYAN}${BOLD}   Other targets:${NC}"
    echo ""
    echo -e "   ${GREEN}make test${NC}         Static checks and unit tests"
    echo -e "   ${GREEN}make lint${NC}         Auto-fix Python code style"
    echo -e "   ${GREEN}make deploy name=my-rg-name${NC}   Deploy to Azure"
    echo -e "   ${GREEN}make install${NC}      Re-sync the venv after pulling changes"
    echo ""

    echo -e "${CYAN}─────────────────────────────────────────────────────────${NC}"
    echo ""

    # Report what is missing rather than letting it surface as a Makefile
    # failure three commands from now.
    local missing=false
    if [ "$HAS_YQ" = false ]; then
        log_warn "yq (mikefarah) is missing — 'make dev', 'make deploy', and 'make sync-local-config' need it."
        missing=true
    fi
    if [ "$HAS_AZ" = false ]; then
        log_warn "Azure CLI is missing — 'make deploy', 'make logs', and 'make sync-local-config' need it."
        missing=true
    fi
    if [ "$HAS_DEVTUNNEL" = false ]; then
        log_warn "Dev tunnels CLI is missing — 'make tunnel' needs it for local webhook testing."
        missing=true
    fi
    if [ "$HAS_TWILIO" = false ]; then
        log_info "Twilio CLI is not installed — only needed for 'make twilio-register'."
    fi
    if [ "$HAS_RUST" = false ]; then
        log_info "Rust is not installed — only needed to build Rust-backed dependencies from source."
    fi
    if [ "$missing" = true ]; then
        echo ""
        log_info "Re-run this installer any time to pick the missing tools up."
    fi

    # Only ask for a reload when a profile was actually edited: this process
    # always has $LOCAL_BIN on PATH, so PATH alone says nothing about the
    # user's next shell.
    if [ "$PATH_PROFILE_UPDATED" = true ]; then
        echo ""
        echo -e "${YELLOW}⚡ Reload your shell so ~/.local/bin (uv, yq) is on PATH:${NC}"
        echo ""
        local login_shell
        login_shell="$(basename "${SHELL:-/bin/bash}")"
        case "$login_shell" in
            zsh)  echo "   source ~/.zshrc" ;;
            bash) echo "   source ~/.bashrc" ;;
            fish) echo "   source ~/.config/fish/config.fish" ;;
            *)    echo "   source ~/.bashrc   # or ~/.zshrc" ;;
        esac
        echo ""
    fi
}

# ============================================================================
# --ensure mode
# ============================================================================

ensure_mode() {
    detect_os
    ensure_local_bin_on_path

    local deps dep
    IFS=',' read -ra deps <<< "$ENSURE_DEPS"
    for dep in "${deps[@]}"; do
        dep="$(echo "$dep" | tr -d '[:space:]')"
        case "$dep" in
            uv)        install_uv ;;
            python)    check_python ;;
            git)       check_git ;;
            make)      check_make ;;
            yq)        check_yq ;;
            az|azure)  check_azure_cli ;;
            twilio)    check_twilio_cli ;;
            devtunnel) check_devtunnel ;;
            rust)      check_rust ;;
            "")        ;;
            *)         log_warn "Unknown dependency: $dep" ;;
        esac
    done
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_banner

    detect_os
    check_network_prerequisites
    ensure_local_bin_on_path

    install_uv
    check_python
    check_git
    check_make
    check_build_tools
    check_rust
    check_yq
    install_optional_tools

    resolve_install_dir
    clone_repo
    init_submodules

    setup_venv
    install_deps

    scaffold_config
    verify_install

    print_success
}

if [ -n "$ENSURE_DEPS" ]; then
    ensure_mode
else
    main
fi

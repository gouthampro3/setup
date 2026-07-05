#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
PROMPT_NAME=""
TMP_ROOT="/tmp/terminal-setup-${USER:-$(id -un 2>/dev/null || echo user)}"
STATE_DIR="$TMP_ROOT/state"
LOG_DIR="$TMP_ROOT/logs"
SCRATCH_DIR="$TMP_ROOT/scratch"
PERSIST_DIR="$HOME/Scripts/terminal-setup"
BIN_DIR="$PERSIST_DIR/bin"
BACKUP_ROOT="$PERSIST_DIR/backups"
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
PACKAGE_MANAGER=""
CURRENT_STEP="initialization"
SUDO_CMD=()
PACKAGES=()
RUN_ZSH=0
RUN_TMUX=0
RUN_NEOVIM=0
REQUESTED_SCOPE=0
SKIP_TREE_SITTER=0

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [--zsh] [--tmux] [--neovim] [--all] [--skip-tree-sitter] [prompt-name]

Installs and configures zsh, Oh My Zsh, tmux, TPM plugins, Neovim, and LazyVim.

Setup scopes:
  --zsh         Install zsh, Oh My Zsh, zsh plugins, and managed prompt config.
  --tmux        Install tmux, TPM, tmux plugins, and managed tmux config.
  --neovim      Install Neovim, tree-sitter CLI, LazyVim, and PATH support.
  --nvim        Alias for --neovim.
  --all         Run every setup scope. This is the default when no scope is given.
  --skip-tree-sitter
                Skip optional tree-sitter CLI setup for LazyVim parser tooling.

Prompt name:
  Required when --zsh is selected or when no scope is given.
  Optional and ignored for --tmux/--neovim-only runs.

State and logs:
  $TMP_ROOT

Persistent non-dotfile assets:
  $PERSIST_DIR
EOF
}

log() {
  printf '[terminal-setup] %s\n' "$*"
}

die() {
  printf '[terminal-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local rc=$?
  if (( rc != 0 )); then
    printf '[terminal-setup] Failed during %s. Logs are in %s\n' "$CURRENT_STEP" "$LOG_DIR" >&2
  fi
}

trap on_error ERR

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --zsh|--oh-my-zsh)
        RUN_ZSH=1
        REQUESTED_SCOPE=1
        ;;
      --tmux)
        RUN_TMUX=1
        REQUESTED_SCOPE=1
        ;;
      --neovim|--nvim)
        RUN_NEOVIM=1
        REQUESTED_SCOPE=1
        ;;
      --all)
        RUN_ZSH=1
        RUN_TMUX=1
        RUN_NEOVIM=1
        REQUESTED_SCOPE=1
        ;;
      --skip-tree-sitter)
        SKIP_TREE_SITTER=1
        ;;
      -*)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [[ -n "$PROMPT_NAME" ]]; then
          printf 'Unexpected extra argument: %s\n\n' "$1" >&2
          usage >&2
          exit 2
        fi
        PROMPT_NAME="$1"
        ;;
    esac
    shift
  done

  if (( REQUESTED_SCOPE == 0 )); then
    RUN_ZSH=1
    RUN_TMUX=1
    RUN_NEOVIM=1
  fi

  if (( RUN_ZSH == 1 )) && [[ -z "$PROMPT_NAME" ]]; then
    printf 'A prompt-name is required for zsh setup.\n\n' >&2
    usage >&2
    exit 2
  fi

  if [[ -z "$PROMPT_NAME" || "$PROMPT_NAME" == *$'\n'* || "$PROMPT_NAME" == *$'\r'* ]]; then
    if (( RUN_ZSH == 1 )); then
      die "prompt-name must be non-empty and must not contain newlines"
    fi
  fi
}

ensure_directories() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$SCRATCH_DIR" "$PERSIST_DIR" "$BIN_DIR" "$BACKUP_ROOT"
  export PATH="$BIN_DIR:$PATH"
}

detect_package_manager() {
  local os_name
  os_name="$(uname -s)"

  if [[ "$os_name" == "Darwin" ]]; then
    command -v brew >/dev/null 2>&1 || die "macOS support requires Homebrew to already be installed"
    PACKAGE_MANAGER="brew"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
  else
    die "unsupported package manager; expected apt-get, dnf, yum, or Homebrew"
  fi
}

setup_sudo() {
  if [[ "$PACKAGE_MANAGER" == "brew" || "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO_CMD=()
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required for package installation"
    SUDO_CMD=(sudo)
  fi
}

safe_backup_name() {
  local target="$1"
  target="${target/#$HOME\//home/}"
  target="${target//\//__}"
  printf '%s' "$target"
}

backup_path() {
  local target="$1"
  local backup_name

  [[ -e "$target" || -L "$target" ]] || return 0
  mkdir -p "$BACKUP_DIR" || return 1
  backup_name="$(safe_backup_name "$target")"
  cp -a "$target" "$BACKUP_DIR/$backup_name" || return 1
  log "Backed up $target to $BACKUP_DIR/$backup_name"
}

zsh_single_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "%s" "$value"
}

zsh_prompt_literal() {
  local value="$1"
  value="${value//%/%%}"
  zsh_single_quote "$value"
}

version_ge() {
  local have="$1"
  local need="$2"
  local have_major have_minor have_patch need_major need_minor need_patch

  IFS=. read -r have_major have_minor have_patch <<<"${have#v}"
  IFS=. read -r need_major need_minor need_patch <<<"${need#v}"
  have_major="${have_major:-0}"
  have_minor="${have_minor:-0}"
  have_patch="${have_patch:-0}"
  need_major="${need_major:-0}"
  need_minor="${need_minor:-0}"
  need_patch="${need_patch:-0}"

  (( have_major > need_major )) && return 0
  (( have_major < need_major )) && return 1
  (( have_minor > need_minor )) && return 0
  (( have_minor < need_minor )) && return 1
  (( have_patch >= need_patch ))
}

run_step() {
  local name="$1"
  local validator="$2"
  local action="$3"
  local marker="$STATE_DIR/$name.done"
  local log_file="$LOG_DIR/$name.log"

  CURRENT_STEP="$name"

  if "$validator"; then
    touch "$marker"
    log "Already satisfied: $name"
    return 0
  fi

  rm -f "$marker"
  log "Running: $name"

  if "$action" >"$log_file" 2>&1; then
    if "$validator"; then
      touch "$marker"
      log "Completed: $name"
      return 0
    fi

    log "Step finished but validation failed: $name"
    tail -n 40 "$log_file" >&2 || true
    return 1
  fi

  log "Step failed: $name"
  tail -n 40 "$log_file" >&2 || true
  return 1
}

run_optional_step() {
  local name="$1"
  local validator="$2"
  local action="$3"

  if run_step "$name" "$validator" "$action"; then
    return 0
  fi

  log "Optional setup failed and will be skipped: $name"
  return 0
}

has_c_compiler() {
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1
}

add_pkg_if_missing() {
  local command_name="$1"
  local package_name="$2"

  command -v "$command_name" >/dev/null 2>&1 || PACKAGES+=("$package_name")
}

dedupe_packages() {
  local -a deduped=()
  local package existing

  for package in "${PACKAGES[@]}"; do
    existing=0
    for seen in "${deduped[@]}"; do
      if [[ "$seen" == "$package" ]]; then
        existing=1
        break
      fi
    done
    (( existing == 0 )) && deduped+=("$package")
  done

  PACKAGES=("${deduped[@]}")
}

install_packages() {
  local -a packages=("$@")
  ((${#packages[@]} > 0)) || return 0

  case "$PACKAGE_MANAGER" in
    apt)
      "${SUDO_CMD[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update || return 1
      "${SUDO_CMD[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || return 1
      ;;
    dnf)
      "${SUDO_CMD[@]}" dnf install -y "${packages[@]}" || return 1
      ;;
    yum)
      "${SUDO_CMD[@]}" yum install -y "${packages[@]}" || return 1
      ;;
    brew)
      brew install "${packages[@]}" || return 1
      ;;
    *)
      printf 'Unsupported package manager: %s\n' "$PACKAGE_MANAGER" >&2
      return 1
      ;;
  esac
}

package_available() {
  local package_name="$1"

  case "$PACKAGE_MANAGER" in
    apt)
      apt-cache show "$package_name" >/dev/null 2>&1
      ;;
    dnf)
      dnf list --available "$package_name" >/dev/null 2>&1 || dnf list --installed "$package_name" >/dev/null 2>&1
      ;;
    yum)
      yum list available "$package_name" >/dev/null 2>&1 || yum list installed "$package_name" >/dev/null 2>&1
      ;;
    brew)
      brew info "$package_name" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

validate_zsh_packages() {
  command -v zsh >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
}

install_zsh_packages() {
  PACKAGES=()
  add_pkg_if_missing zsh zsh
  add_pkg_if_missing git git
  dedupe_packages
  install_packages "${PACKAGES[@]}" || return 1
}

validate_tmux_packages() {
  command -v tmux >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  command -v entr >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v ping >/dev/null 2>&1 || return 1
  if [[ "$(uname -s)" == "Linux" ]]; then
    command -v iw >/dev/null 2>&1 || return 1
  fi
}

install_tmux_packages() {
  PACKAGES=()
  add_pkg_if_missing tmux tmux
  add_pkg_if_missing git git
  add_pkg_if_missing entr entr
  add_pkg_if_missing curl curl

  case "$PACKAGE_MANAGER" in
    apt)
      add_pkg_if_missing ping iputils-ping
      [[ "$(uname -s)" == "Linux" ]] && add_pkg_if_missing iw iw
      ;;
    dnf|yum)
      add_pkg_if_missing ping iputils
      [[ "$(uname -s)" == "Linux" ]] && add_pkg_if_missing iw iw
      ;;
  esac

  dedupe_packages
  install_packages "${PACKAGES[@]}" || return 1
}

validate_neovim_packages() {
  local command_name

  for command_name in git curl unzip tar gzip make; do
    command -v "$command_name" >/dev/null 2>&1 || return 1
  done

  has_c_compiler || return 1
  return 0
}

install_neovim_packages() {
  PACKAGES=()

  case "$PACKAGE_MANAGER" in
    apt|dnf|yum)
      add_pkg_if_missing git git
      add_pkg_if_missing curl curl
      add_pkg_if_missing unzip unzip
      add_pkg_if_missing tar tar
      add_pkg_if_missing gzip gzip
      add_pkg_if_missing make make
      has_c_compiler || PACKAGES+=(gcc)
      ;;
    brew)
      add_pkg_if_missing git git
      add_pkg_if_missing curl curl
      add_pkg_if_missing unzip unzip
      ;;
  esac

  dedupe_packages
  install_packages "${PACKAGES[@]}" || return 1
}

validate_oh_my_zsh() {
  [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
}

install_oh_my_zsh() {
  if [[ -e "$HOME/.oh-my-zsh" && ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
    backup_path "$HOME/.oh-my-zsh" || return 1
    rm -rf "$HOME/.oh-my-zsh" || return 1
  fi

  [[ -e "$HOME/.oh-my-zsh" ]] && return 0
  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" || return 1
}

validate_zsh_plugins() {
  local custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  [[ -f "$custom_dir/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] || return 1
  [[ -f "$custom_dir/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] || return 1
}

install_zsh_plugins() {
  local custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  local plugin_dir

  mkdir -p "$custom_dir/plugins" || return 1

  plugin_dir="$custom_dir/plugins/zsh-autosuggestions"
  if [[ -e "$plugin_dir" && ! -f "$plugin_dir/zsh-autosuggestions.zsh" ]]; then
    backup_path "$plugin_dir" || return 1
    rm -rf "$plugin_dir" || return 1
  fi
  [[ -e "$plugin_dir" ]] || git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$plugin_dir" || return 1

  plugin_dir="$custom_dir/plugins/zsh-syntax-highlighting"
  if [[ -e "$plugin_dir" && ! -f "$plugin_dir/zsh-syntax-highlighting.zsh" ]]; then
    backup_path "$plugin_dir" || return 1
    rm -rf "$plugin_dir" || return 1
  fi
  [[ -e "$plugin_dir" ]] || git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugin_dir" || return 1
}

validate_zshrc() {
  local prompt_value
  prompt_value="$(zsh_single_quote "$PROMPT_NAME")"

  [[ -f "$HOME/.zshrc" ]] || return 1
  grep -Fq "# terminal-setup managed zsh config" "$HOME/.zshrc" || return 1
  grep -Fq "TERMINAL_SETUP_PROMPT_NAME='$prompt_value'" "$HOME/.zshrc" || return 1
  grep -Fq "zsh-autosuggestions" "$HOME/.zshrc" || return 1
  grep -Fq "zsh-syntax-highlighting" "$HOME/.zshrc" || return 1
}

write_zshrc() {
  local prompt_name_quoted prompt_literal
  prompt_name_quoted="$(zsh_single_quote "$PROMPT_NAME")"
  prompt_literal="$(zsh_prompt_literal "$PROMPT_NAME")"

  backup_path "$HOME/.zshrc" || return 1

  cat >"$HOME/.zshrc" <<EOF
# terminal-setup managed zsh config
# Generated by $SCRIPT_NAME on $(date -u +%Y-%m-%dT%H:%M:%SZ)

# terminal-setup managed PATH start
export TERMINAL_SETUP_HOME="\$HOME/Scripts/terminal-setup"
export PATH="\$TERMINAL_SETUP_HOME/bin:\$PATH"
# terminal-setup managed PATH end

export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME=""

plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source "\$ZSH/oh-my-zsh.sh"

TERMINAL_SETUP_PROMPT_NAME='$prompt_name_quoted'
PROMPT='%F{cyan}$prompt_literal%f:%F{blue}%~%f %# '
RPROMPT=''
EOF
}

validate_terminal_setup_path() {
  [[ -f "$HOME/.zshrc" ]] || return 1
  grep -Fq "# terminal-setup managed PATH start" "$HOME/.zshrc" || return 1
  grep -Fq 'export TERMINAL_SETUP_HOME="$HOME/Scripts/terminal-setup"' "$HOME/.zshrc" || return 1
  grep -Fq 'export PATH="$TERMINAL_SETUP_HOME/bin:$PATH"' "$HOME/.zshrc" || return 1
  grep -Fq "# terminal-setup managed PATH end" "$HOME/.zshrc" || return 1
}

write_terminal_setup_path() {
  local tmp_zshrc="$SCRATCH_DIR/zshrc.without-terminal-setup-path"

  backup_path "$HOME/.zshrc" || return 1

  if [[ -f "$HOME/.zshrc" ]] && grep -Fq "# terminal-setup managed PATH start" "$HOME/.zshrc"; then
    sed '/# terminal-setup managed PATH start/,/# terminal-setup managed PATH end/d' "$HOME/.zshrc" >"$tmp_zshrc" || return 1
    cp "$tmp_zshrc" "$HOME/.zshrc" || return 1
  fi

  cat >>"$HOME/.zshrc" <<'EOF'

# terminal-setup managed PATH start
export TERMINAL_SETUP_HOME="$HOME/Scripts/terminal-setup"
export PATH="$TERMINAL_SETUP_HOME/bin:$PATH"
# terminal-setup managed PATH end
EOF
}

validate_tpm() {
  [[ -x "$HOME/.tmux/plugins/tpm/tpm" ]]
}

install_tpm() {
  local tpm_dir="$HOME/.tmux/plugins/tpm"

  if [[ -e "$tpm_dir" && ! -x "$tpm_dir/tpm" ]]; then
    backup_path "$tpm_dir" || return 1
    rm -rf "$tpm_dir" || return 1
  fi

  mkdir -p "$HOME/.tmux/plugins" || return 1
  [[ -e "$tpm_dir" ]] || git clone --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir" || return 1
}

validate_tmux_conf() {
  local conf="$HOME/.tmux.conf"
  [[ -f "$conf" ]] || return 1
  grep -Fq "# terminal-setup managed tmux config" "$conf" || return 1
  grep -Fq "set -g prefix M-c" "$conf" || return 1
  grep -Fq "set -g mouse on" "$conf" || return 1
  grep -Fq "bind h select-pane -L" "$conf" || return 1
  grep -Fq "set-window-option -g mode-keys vi" "$conf" || return 1
  grep -Fq "set -g @dracula-plugins \"network weather time\"" "$conf" || return 1
  grep -Fq "tmux-plugins/tmux-sensible" "$conf" || return 1
  grep -Fq "christoomey/vim-tmux-navigator" "$conf" || return 1
  grep -Fq "b0o/tmux-autoreload" "$conf" || return 1
  grep -Fq "jaclu/tmux-menus" "$conf" || return 1
  grep -Fq "tmux-plugins/tmux-sidebar" "$conf" || return 1
  grep -Fq "noscript/tmux-mighty-scroll" "$conf" || return 1
  grep -Fq "tmux-plugins/tmux-resurrect" "$conf" || return 1
  grep -Fq "tmux-plugins/tmux-prefix-highlight" "$conf" || return 1
  grep -Fq "dracula/tmux" "$conf" || return 1
}

write_tmux_conf() {
  backup_path "$HOME/.tmux.conf" || return 1

  cat >"$HOME/.tmux.conf" <<'EOF'
# terminal-setup managed tmux config

# Terminal behavior.
set-option -sa terminal-overrides ",xterm*:Tc"
set -g mouse on

# Use tmux-sensible defaults through TPM, with the requested prefix override.
unbind C-b
unbind C-c
set -g prefix M-c
bind M-c send-prefix

# Vim-style pane navigation.
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Window navigation and numbering.
bind -n S-Left previous-window
bind -n S-Right next-window
bind -n M-H previous-window
bind -n M-L next-window
set -g base-index 1
set -g pane-base-index 1
set-window-option -g pane-base-index 1
set-option -g renumber-windows on

# Vi-style copy mode.
set-window-option -g mode-keys vi
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel

# Split panes from the active pane's current directory.
bind '"' split-window -v -c "#{pane_current_path}"
bind % split-window -h -c "#{pane_current_path}"

# Dracula status bar widgets.
set -g status-position bottom
set -g @dracula-plugins "network weather time"
set -g @dracula-refresh-rate 5
set -g @dracula-show-powerline true
set -g @dracula-show-flags true
set -g @dracula-show-empty-plugins false
set -g @dracula-network-hosts "1.1.1.1 8.8.8.8 google.com github.com"
set -g @dracula-network-wifi-label "WiFi "
set -g @dracula-network-ethernet-label "Ethernet"
set -g @dracula-network-offline-label "Offline"
set -g @dracula-show-fahrenheit true
set -g @dracula-show-location true
set -g @dracula-weather-hide-errors true
set -g @dracula-show-timezone false
set -g @dracula-time-format "%a %b %d %I:%M %p"

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'b0o/tmux-autoreload'
set -g @plugin 'jaclu/tmux-menus'
set -g @plugin 'tmux-plugins/tmux-sidebar'
set -g @plugin 'noscript/tmux-mighty-scroll'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-prefix-highlight'
set -g @plugin 'dracula/tmux'

run '~/.tmux/plugins/tpm/tpm'
EOF
}

validate_tmux_plugins() {
  [[ -d "$HOME/.tmux/plugins/tmux-sensible" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-autoreload" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-menus" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-sidebar" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-mighty-scroll" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-resurrect" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux-prefix-highlight" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/vim-tmux-navigator" ]] || return 1
  [[ -d "$HOME/.tmux/plugins/tmux" ]] || return 1
}

install_tmux_plugin_repo() {
  local repo="$1"
  local dirname="$2"
  local target="$HOME/.tmux/plugins/$dirname"

  if [[ -e "$target" ]]; then
    return 0
  fi

  git clone --depth=1 "https://github.com/$repo" "$target" || return 1
}

install_tmux_plugins() {
  mkdir -p "$HOME/.tmux/plugins" || return 1

  install_tmux_plugin_repo tmux-plugins/tmux-sensible tmux-sensible || return 1
  install_tmux_plugin_repo christoomey/vim-tmux-navigator vim-tmux-navigator || return 1
  install_tmux_plugin_repo b0o/tmux-autoreload tmux-autoreload || return 1
  install_tmux_plugin_repo jaclu/tmux-menus tmux-menus || return 1
  install_tmux_plugin_repo tmux-plugins/tmux-sidebar tmux-sidebar || return 1
  install_tmux_plugin_repo noscript/tmux-mighty-scroll tmux-mighty-scroll || return 1
  install_tmux_plugin_repo tmux-plugins/tmux-resurrect tmux-resurrect || return 1
  install_tmux_plugin_repo tmux-plugins/tmux-prefix-highlight tmux-prefix-highlight || return 1
  install_tmux_plugin_repo dracula/tmux tmux || return 1

  if tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$HOME/.tmux.conf" || true
  fi
}

nvim_version() {
  command -v nvim >/dev/null 2>&1 || return 1
  nvim --version | sed -nE '1s/^NVIM v?([0-9]+(\.[0-9]+){1,2}).*/\1/p'
}

validate_neovim() {
  local version
  version="$(nvim_version)" || return 1
  [[ -n "$version" ]] || return 1
  version_ge "$version" "0.11.2"
}

asset_arch_for_neovim() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

install_neovim_archive() {
  local url="$1"
  local archive="$SCRATCH_DIR/nvim.tar.gz"

  rm -rf "$SCRATCH_DIR/nvim-extract" "$PERSIST_DIR/neovim" || return 1
  mkdir -p "$SCRATCH_DIR/nvim-extract" "$PERSIST_DIR/neovim" "$BIN_DIR" || return 1
  curl -fL "$url" -o "$archive" || return 1
  tar -xzf "$archive" -C "$PERSIST_DIR/neovim" --strip-components=1 || return 1
  ln -sfn "$PERSIST_DIR/neovim/bin/nvim" "$BIN_DIR/nvim" || return 1
}

install_neovim() {
  local os_name arch primary_url fallback_url
  os_name="$(uname -s)"

  if [[ "$PACKAGE_MANAGER" == "brew" ]]; then
    if command -v nvim >/dev/null 2>&1; then
      brew upgrade neovim || true
    else
      brew install neovim || return 1
    fi
    validate_neovim && return 0
  fi

  arch="$(asset_arch_for_neovim)" || {
    printf 'Unsupported Neovim architecture: %s\n' "$(uname -m)" >&2
    return 1
  }

  case "$os_name" in
    Linux)
      primary_url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz"
      fallback_url="https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-$arch.tar.gz"
      ;;
    Darwin)
      primary_url="https://github.com/neovim/neovim/releases/latest/download/nvim-macos-$arch.tar.gz"
      fallback_url=""
      ;;
    *)
      printf 'Unsupported OS for Neovim archive: %s\n' "$os_name" >&2
      return 1
      ;;
  esac

  install_neovim_archive "$primary_url" || return 1
  if validate_neovim; then
    return 0
  fi

  if [[ -n "$fallback_url" ]]; then
    printf 'Primary Neovim binary did not run on this system; trying older-glibc build.\n'
    install_neovim_archive "$fallback_url" || return 1
    validate_neovim && return 0
  fi

  printf 'Neovim was installed but could not run. Check glibc compatibility or build Neovim locally.\n' >&2
  return 1
}

tree_sitter_version() {
  command -v tree-sitter >/dev/null 2>&1 || return 1
  tree-sitter --version | sed -nE 's/^tree-sitter ([0-9]+(\.[0-9]+){1,2}).*/\1/p'
}

validate_tree_sitter_cli() {
  local version
  version="$(tree_sitter_version)" || return 1
  [[ -n "$version" ]]
}

tree_sitter_asset_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x64' ;;
    arm64|aarch64) printf 'arm64' ;;
    armv7l|armv6l) printf 'arm' ;;
    *) return 1 ;;
  esac
}

validate_rust_toolchain() {
  command -v cargo >/dev/null 2>&1 || return 1
  command -v rustc >/dev/null 2>&1 || return 1
}

install_rust_toolchain() {
  PACKAGES=()

  if validate_rust_toolchain; then
    return 0
  fi

  case "$PACKAGE_MANAGER" in
    apt)
      add_pkg_if_missing cargo cargo
      add_pkg_if_missing rustc rustc
      dedupe_packages
      install_packages "${PACKAGES[@]}" || return 1
      ;;
    dnf)
      add_pkg_if_missing cargo cargo
      add_pkg_if_missing rustc rust
      dedupe_packages
      install_packages "${PACKAGES[@]}" || return 1
      ;;
    yum)
      add_pkg_if_missing cargo cargo
      add_pkg_if_missing rustc rust
      dedupe_packages
      if ! install_packages "${PACKAGES[@]}"; then
        command -v amazon-linux-extras >/dev/null 2>&1 || return 1
        "${SUDO_CMD[@]}" amazon-linux-extras install -y rust1 || return 1
      fi
      ;;
    brew)
      add_pkg_if_missing cargo rust
      add_pkg_if_missing rustc rust
      dedupe_packages
      install_packages "${PACKAGES[@]}" || return 1
      ;;
    *)
      return 1
      ;;
  esac

  validate_rust_toolchain
}

install_tree_sitter_cli_from_source() {
  local install_root="$PERSIST_DIR/tree-sitter-cli"

  install_rust_toolchain || return 1
  rm -rf "$install_root" || return 1
  mkdir -p "$PERSIST_DIR/cargo" "$install_root" "$BIN_DIR" || return 1
  CARGO_HOME="$PERSIST_DIR/cargo" cargo install tree-sitter-cli --locked --root "$install_root" || return 1
  ln -sfn "$install_root/bin/tree-sitter" "$BIN_DIR/tree-sitter" || return 1
}

install_tree_sitter_cli_from_package_manager() {
  local package_name

  for package_name in tree-sitter-cli tree-sitter; do
    if package_available "$package_name"; then
      install_packages "$package_name" || continue
      validate_tree_sitter_cli && return 0
    fi
  done

  return 1
}

install_tree_sitter_cli() {
  local os_name arch url archive extract_dir binary_path
  os_name="$(uname -s)"

  if [[ "$PACKAGE_MANAGER" == "brew" ]]; then
    brew install tree-sitter-cli || brew upgrade tree-sitter-cli || return 1
    return 0
  fi

  if install_tree_sitter_cli_from_package_manager; then
    return 0
  fi

  arch="$(tree_sitter_asset_arch)" || {
    printf 'Unsupported tree-sitter architecture: %s\n' "$(uname -m)" >&2
    return 1
  }

  case "$os_name" in
    Linux) url="https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-cli-linux-$arch.zip" ;;
    Darwin) url="https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-cli-macos-$arch.zip" ;;
    *)
      printf 'Unsupported OS for tree-sitter archive: %s\n' "$os_name" >&2
      return 1
      ;;
  esac

  archive="$SCRATCH_DIR/tree-sitter.zip"
  extract_dir="$SCRATCH_DIR/tree-sitter"
  rm -rf "$extract_dir" || return 1
  mkdir -p "$extract_dir" "$BIN_DIR" || return 1
  curl -fL "$url" -o "$archive" || return 1
  unzip -o "$archive" -d "$extract_dir" || return 1
  binary_path="$(find "$extract_dir" -type f -name tree-sitter -perm -u+x | head -n 1)"
  if [[ -z "$binary_path" ]]; then
    binary_path="$(find "$extract_dir" -type f -name tree-sitter | head -n 1)"
  fi
  [[ -n "$binary_path" ]] || return 1
  cp "$binary_path" "$BIN_DIR/tree-sitter" || return 1
  chmod +x "$BIN_DIR/tree-sitter" || return 1

  if validate_tree_sitter_cli; then
    return 0
  fi

  printf 'Prebuilt tree-sitter CLI did not run on this system; building from source with Cargo.\n'
  install_tree_sitter_cli_from_source || return 1
  validate_tree_sitter_cli
}

validate_lazyvim() {
  [[ -f "$HOME/.config/nvim/init.lua" ]] || return 1
  [[ -f "$HOME/.config/nvim/lua/config/lazy.lua" ]] || return 1
  grep -Fq "LazyVim/LazyVim" "$HOME/.config/nvim/lua/config/lazy.lua" || return 1
}

install_lazyvim() {
  local path

  for path in \
    "$HOME/.config/nvim" \
    "$HOME/.local/share/nvim" \
    "$HOME/.local/state/nvim" \
    "$HOME/.cache/nvim"; do
    if [[ -e "$path" || -L "$path" ]]; then
      backup_path "$path" || return 1
      rm -rf "$path" || return 1
    fi
  done

  mkdir -p "$HOME/.config" || return 1
  git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" || return 1
  rm -rf "$HOME/.config/nvim/.git" || return 1
}

selected_scopes() {
  local -a scopes=()
  local joined

  (( RUN_ZSH == 1 )) && scopes+=("zsh")
  (( RUN_TMUX == 1 )) && scopes+=("tmux")
  (( RUN_NEOVIM == 1 )) && scopes+=("neovim")

  joined="${scopes[*]}"
  printf '%s' "${joined// /,}"
}

run_zsh_setup() {
  run_step install_zsh_packages validate_zsh_packages install_zsh_packages
  run_step install_oh_my_zsh validate_oh_my_zsh install_oh_my_zsh
  run_step install_zsh_plugins validate_zsh_plugins install_zsh_plugins
  run_step configure_zshrc validate_zshrc write_zshrc
}

run_tmux_setup() {
  run_step install_tmux_packages validate_tmux_packages install_tmux_packages
  run_step install_tpm validate_tpm install_tpm
  run_step configure_tmux validate_tmux_conf write_tmux_conf
  run_step install_tmux_plugins validate_tmux_plugins install_tmux_plugins
}

run_neovim_setup() {
  run_step install_neovim_packages validate_neovim_packages install_neovim_packages
  run_step install_neovim validate_neovim install_neovim
  if (( SKIP_TREE_SITTER == 1 )); then
    log "Skipping tree-sitter CLI setup by request."
  else
    run_optional_step install_tree_sitter_cli validate_tree_sitter_cli install_tree_sitter_cli
  fi
  run_step configure_terminal_setup_path validate_terminal_setup_path write_terminal_setup_path
  run_step install_lazyvim validate_lazyvim install_lazyvim
}

main() {
  parse_args "$@"
  ensure_directories
  detect_package_manager
  setup_sudo

  log "Using package manager: $PACKAGE_MANAGER"
  log "Selected setup scopes: $(selected_scopes)"
  log "Scratch/state/log directory: $TMP_ROOT"
  log "Persistent setup directory: $PERSIST_DIR"

  if (( RUN_ZSH == 1 )); then
    run_zsh_setup
  fi

  if (( RUN_TMUX == 1 )); then
    run_tmux_setup
  fi

  if (( RUN_NEOVIM == 1 )); then
    run_neovim_setup
  fi

  CURRENT_STEP="complete"
  log "Terminal setup complete."
  log "Open a new zsh session to load the updated prompt and PATH."
  log "Logs: $LOG_DIR"
}

main "$@"

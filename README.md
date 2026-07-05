# Terminal Setup

Small bootstrap script for setting up a familiar terminal environment on new machines.

## Usage

Run the full setup:

```bash
./terminal-setup.sh
```

Run only part of the setup:

```bash
./terminal-setup.sh --zsh
./terminal-setup.sh --zsh workbox
./terminal-setup.sh --tmux
./terminal-setup.sh --neovim
./terminal-setup.sh --neovim --skip-tree-sitter
```

Flags can be combined:

```bash
./terminal-setup.sh --tmux --neovim
```

## What It Installs

- Oh My Zsh with autosuggestions and syntax highlighting
- tmux with TPM, Dracula theme, vim-style pane navigation, mouse mode, and selected plugins
- Neovim with LazyVim

The zsh setup keeps Oh My Zsh's default `robbyrussell` theme. If you pass a
word as the final argument, the script prepends it to the robbyrussell prompt
without replacing the theme.

Tree-sitter CLI is attempted for LazyVim parser tooling, but it is optional for this script.
Use `--skip-tree-sitter` if the machine is too old for available binaries/packages.

The generated tmux status bar uses Dracula widgets for network/Wi-Fi, weather with location
and temperature, and date/time.

## Files

- Logs and retry state: `/tmp/terminal-setup-$USER`
- Persistent tools and backups: `~/Scripts/terminal-setup`
- tmux source config: `~/.config/tmux/tmux.conf`
- tmux compatibility shim: `~/.tmux.conf`
- tmux plugins: `~/.config/.tmux/plugins`

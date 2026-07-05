# Terminal Setup

Small bootstrap script for setting up a familiar terminal environment on new machines.

## Usage

Run the full setup:

```bash
./terminal-setup.sh my-prompt-name
```

Run only part of the setup:

```bash
./terminal-setup.sh --zsh my-prompt-name
./terminal-setup.sh --tmux
./terminal-setup.sh --neovim
```

Flags can be combined:

```bash
./terminal-setup.sh --tmux --neovim
```

## What It Installs

- Oh My Zsh with autosuggestions and syntax highlighting
- tmux with TPM, Dracula theme, and selected plugins
- Neovim with LazyVim

## Files

- Logs and retry state: `/tmp/terminal-setup-$USER`
- Persistent tools and backups: `~/Scripts/terminal-setup`

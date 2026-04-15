# zsh-ai-autosuggestions

A drop-in replacement for [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) that adds local LLM-powered completions via [llama.cpp](https://github.com/ggerganov/llama.cpp). History suggestions still work instantly, but when history has no match, a local language model fills in.

The LLM also handles typo correction and natural language command generation. All inference runs locally on your machine, nothing is sent to any server.

## How it works

The plugin is a fork of zsh-autosuggestions v0.7.1 with an `ai` strategy added to the suggestion pipeline. The base autosuggestions code is included directly (not a dependency) so you don't need zsh-autosuggestions installed separately. Credit to Thiago de Arruda and Eric Freese for the original.

When you type a command:

1. Other strategies run first (history by default, or whatever you have configured like atuin). These are instant, grey text, same as before.
2. If no match from those, the `ai` strategy queries a local llama-server running a small code model
3. The suggestion appears as purple ghost text to distinguish it from history
4. Right arrow accepts, like normal

If the model detects a typo (e.g. `gti stauts`), it shows a correction below the prompt instead of appending garbage. Pressing Shift-Tab forces an AI suggestion at any time. Typing `ai <description>` and pressing Shift-Tab converts natural language to a shell command (e.g. `ai find large files over 100mb` becomes `find . -type f -size +100M`).

The model runs as a persistent background server, so there's no cold start per-completion. Typical response time is 25-80ms.

The history strategy is bundled into the plugin. If you want to disable it and only use AI:

```sh
ZSH_AUTOSUGGEST_STRATEGY=(ai)
```

Or if you have atuin and want history, atuin, then AI fallback:

```sh
ZSH_AUTOSUGGEST_STRATEGY=(history atuin ai)
```

Personally I use atuin and it works fine. The plugin automatically appends `ai` to whatever strategy list you or your other plugins set up, so you usually don't need to configure this.

## Requirements

- zsh >= 5.0.8
- [llama.cpp](https://github.com/ggerganov/llama.cpp) (provides `llama-server`)
- curl
- jq
- A GGUF model file (see below)

## Install

### 1. Install llama.cpp

```sh
brew install llama.cpp
# or with zerobrew (https://github.com/lucasgelfond/zerobrew)
zb install llama.cpp
```

### 2. Download a model

You need to download a GGUF model file yourself. The plugin does not download anything automatically.

The recommended model is [Qwen2.5-Coder-3B-Instruct](https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF) (Q5_K_M quantization, ~2 GB). See the benchmarks section below for why this was chosen.

```sh
mkdir -p ~/.local/share/models
hf download bartowski/Qwen2.5-Coder-3B-Instruct-GGUF Qwen2.5-Coder-3B-Instruct-Q5_K_M.gguf --local-dir ~/.local/share/models/
```

Or with curl:

```sh
mkdir -p ~/.local/share/models
curl -L -o ~/.local/share/models/Qwen2.5-Coder-3B-Instruct-Q5_K_M.gguf \
  "https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q5_K_M.gguf"
```

### 3. Install the plugin

Remove `zsh-users/zsh-autosuggestions` from your plugin list first, since this plugin replaces it and both define the same widget names.

With [antidote](https://github.com/mattmc3/antidote) (tested):

```sh
# ~/.zsh_plugins.txt
willzeng274/zsh-ai-autosuggestions kind:defer
```

With [zinit](https://github.com/zdharma-continuum/zinit) (untested):

```sh
zinit light willzeng274/zsh-ai-autosuggestions
```

With [oh-my-zsh](https://github.com/ohmyzsh/ohmyzsh) (untested):

```sh
git clone https://github.com/willzeng274/zsh-ai-autosuggestions.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-ai-autosuggestions
# then add zsh-ai-autosuggestions to your plugins array in .zshrc
```

Manual:

```sh
git clone https://github.com/willzeng274/zsh-ai-autosuggestions.git
echo 'source /path/to/zsh-ai-autosuggestions/zsh-ai-autosuggestions.plugin.zsh' >> ~/.zshrc
```

### 4. Start the server

The llama-server does not start automatically. You need to start it manually:

```sh
zsh-ai-start
```

This starts llama-server in the background with the configured model. It takes around 10 seconds to load, then stays resident. Use `zsh-ai-stop` to kill it.

If you want it to start automatically when you open a terminal, add this to your `.zshrc` (after the plugin is sourced):

```sh
zsh-ai-start 2>/dev/null
```

## Usage

Just type normally. History suggestions appear instantly in grey. When there's no history match, the AI fills in after a short delay in purple.

### Keybindings

| Key | Action |
|---|---|
| Right arrow | Accept the current suggestion (history or AI) |
| Shift-Tab | Switch to AI suggestion (replaces history suggestion with AI's take) |
| Shift-Tab (again) | Accept a correction or natural language result |
| Ctrl-X Ctrl-A | Same as Shift-Tab (fallback binding) |

The accept behavior (right arrow, end-of-line, etc.) is inherited from zsh-autosuggestions and can be configured with `ZSH_AUTOSUGGEST_ACCEPT_WIDGETS`.

To change the AI trigger keybinding, add this to your `.zshrc` after the plugin is sourced:

```sh
# Example: rebind AI trigger to Ctrl-Space
bindkey '^ ' autosuggest-ai-trigger
```

The widget name is `autosuggest-ai-trigger`. You can bind it to whatever you want. The default bindings are Shift-Tab (`^[[Z`) and Ctrl-X Ctrl-A (`^X^A`).

### Natural language mode

Prefix your input with `ai` to describe what you want in plain English. Press Shift-Tab and the model converts it to a command:

```
$ ai find all python files modified in the last week
  suggestion: find . -name "*.py" -mtime -7  [shift-tab to accept]
```

Press Shift-Tab again to replace the buffer with the suggested command.

### Typo correction

If you mistype a command and neither history nor AI can extend it as-is, the model attempts a correction:

```
$ gti stauts
  suggestion: git status  [shift-tab to accept]
```

## Configuration

All settings have defaults and are optional. Set these in your `.zshrc` before the plugin is sourced.

```sh
# Model path (default: ~/.local/share/models/Qwen2.5-Coder-3B-Instruct-Q5_K_M.gguf)
ZSH_AI_COMPLETE_MODEL="$HOME/.local/share/models/your-model.gguf"

# llama-server port (default: 8794)
ZSH_AI_COMPLETE_PORT=8794

# Max tokens for autocomplete (default: 40)
ZSH_AI_COMPLETE_MAX_TOKENS=40

# Minimum characters before AI triggers (default: 3)
ZSH_AI_COMPLETE_MIN_CHARS=3

# Highlight style for AI suggestions (default: fg=magenta)
# History suggestions use ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE (default: fg=8)
ZSH_AI_COMPLETE_HIGHLIGHT="fg=magenta"

# Debug log path (default: empty, no logging)
ZSH_AI_LOG="/tmp/zsh-ai-debug.log"
```

You can use any GGUF model by setting `ZSH_AI_COMPLETE_MODEL`.

## Compatibility

This plugin replaces zsh-autosuggestions. It implements all the same widgets (`autosuggest-accept`, `autosuggest-clear`, etc.) and respects the same configuration variables (`ZSH_AUTOSUGGEST_STRATEGY`, `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE`, `ZSH_AUTOSUGGEST_ACCEPT_WIDGETS`, etc.).

Tested with:

- [atuin](https://github.com/atuinsh/atuin) (the plugin detects atuin's strategy and appends `ai` to the end automatically)
- [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
- [fzf-tab](https://github.com/Aloxaf/fzf-tab)
- [powerlevel10k](https://github.com/romkatv/powerlevel10k)
- zsh-defer (loads fine with `kind:defer` in antidote)

Not tested with oh-my-zsh, zinit, prezto, or other frameworks. Should work since it's a standard `.plugin.zsh` file, but no guarantees.

## Memory and performance

Benchmarked on Apple M3 Max with 36 GB unified memory, using Qwen2.5-Coder-3B Q5_K_M:

- Model file: 2.0 GB on disk
- Memory: ~500 MB resident + ~2 GB memory-mapped (reclaimable by macOS under pressure)
- Autocomplete latency: 25-80ms
- Natural language mode: 100-250ms
- The server idles at effectively zero CPU when not in use

The memory-mapped portion is backed by the file on disk. macOS will page it out if your system needs the memory and page it back in on next use.

## How the model was chosen

Three models were benchmarked on an Apple M3 Max (36 GB) across autocomplete, typo correction, and natural language mode:

| Model | Size | Speed | Notes |
|---|---|---|---|
| Gemma 4 E4B | 6.1 GB | 40-120ms | Decent but generates HTML tags in output, worst typo correction |
| Qwen3.5-4B | 2.9 GB | 40-160ms | More up to date training data, best typo correction, slightly verbose |
| Qwen2.5-Coder-3B | 2.0 GB | 25-100ms | Smallest, fastest, best at completing flags and arguments |

Qwen2.5-Coder-3B won on the combination of speed, size, and accuracy. It's trained specifically on code so it handles CLI flags, file paths, and tool-specific arguments better than the general-purpose models. Qwen3.5 was a close second with better knowledge of newer CLI syntax (e.g. `docker compose` vs `docker-compose`), but the speed and size difference made Coder the better default.

Test cases covered git, docker, kubectl, npm/yarn/pnpm, pip, cargo, go, curl, jq, redis-cli, grpcurl, macOS commands (`defaults`, `pbcopy`, `diskutil`), C++ toolchains, and common unix utilities. Typo correction was tested on misspellings like `gti stauts`, `dcoker rn`, `kubeclt gt pods`. Natural language mode was tested on things like "find large files over 100mb", "kill process on port 3000", "base64 decode a jwt token and pretty print".

## License

The zsh-autosuggestions base code is MIT licensed (Copyright 2013 Thiago de Arruda, Copyright 2016-2021 Eric Freese). AI strategy additions are MIT licensed (Copyright 2026 William Zeng).

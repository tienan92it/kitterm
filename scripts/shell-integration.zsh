# kitterm shell integration for zsh.
#
# Emits OSC 133 semantic prompt marks (prompt start / output start / exit)
# and the OSC 633;E command line, so kitterm can index commands: ⌘↑/⌘↓
# prompt jumps, failed-command dots, and /api/sessions/<id>/marks.
#
# Install: source it from ~/.zshrc, guarded to kitterm shells only:
#
#   [[ -n $KITTERM_DAEMON_CHILD ]] && source /path/to/shell-integration.zsh
#
# fish ≥ 4 and nushell emit OSC 133 natively — no snippet needed there.
# VS Code's shell integration (OSC 633) also works unchanged.

[[ -o interactive ]] || return 0
[[ -n $KITTERM_SHELL_INTEGRATION ]] && return 0
KITTERM_SHELL_INTEGRATION=1

# 633;E escaping: literal backslashes doubled, semicolons as \x3b.
__kitterm_escape_cmd() {
  local cmd=${1//\\/\\\\}
  printf '%s' "${cmd//;/\\x3b}"
}

__kitterm_preexec() {
  printf '\e]633;E;%s\a' "$(__kitterm_escape_cmd "$1")"
  printf '\e]133;C\a'
  __kitterm_ran_command=1
}

__kitterm_precmd() {
  local exit_code=$?
  if [[ -n $__kitterm_ran_command ]]; then
    printf '\e]133;D;%d\a' "$exit_code"
    __kitterm_ran_command=
  fi
  printf '\e]133;A\a'
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __kitterm_preexec
add-zsh-hook precmd __kitterm_precmd

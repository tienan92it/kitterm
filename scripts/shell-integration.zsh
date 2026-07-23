# kitterm shell integration for zsh.
#
# Emits OSC 133 semantic prompt marks (prompt start / output start / exit)
# and the OSC 633;E command line, so kitterm can index commands: ⌘↑/⌘↓
# prompt jumps, failed-command dots, and /api/sessions/<id>/marks.
#
# ONLY source this if your shell does not already emit OSC 133. Many setups
# do (Powerlevel10k, oh-my-zsh integrations, VS Code, iTerm2). Two emitters
# means every prompt and exit is marked twice, which doubles the entries in
# /api/sessions/<id>/marks. To check, run this in a kitterm tab:
#
#   cat -v <<< "$(print -P "$PS1")" | grep -o '133;[A-D]'
#
# or simply try the features first — if ⌘↑/⌘↓ already jump between prompts
# and failed commands already show a red dot, you need nothing here.
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

# 633;E escaping: literal backslashes doubled; semicolons and line breaks as
# hex escapes. A raw newline inside an OSC payload would abort the sequence
# and echo the rest of the command into the terminal.
__kitterm_escape_cmd() {
  local cmd=${1//\\/\\\\}
  cmd=${cmd//;/\\x3b}
  cmd=${cmd//$'\n'/\\x0a}
  printf '%s' "${cmd//$'\r'/\\x0d}"
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

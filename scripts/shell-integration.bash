# kitterm shell integration for bash.
#
# Emits OSC 133 semantic prompt marks (prompt start / output start / exit)
# and the OSC 633;E command line, so kitterm can index commands: ⌘↑/⌘↓
# prompt jumps, failed-command dots, and /api/sessions/<id>/marks.
#
# The zsh variant lives in shell-integration.zsh; this one exists mostly for
# remote Linux boxes and containers where bash is the default shell:
#
#   kitterm integrate bash | ssh vm 'cat >> ~/.bashrc'
#
# ONLY source this if your shell does not already emit OSC 133 (Starship and
# VS Code's integration do). preexec fires from a DEBUG trap; BASH_COMMAND is
# the first simple command of the line, so a pipeline's 633;E reports its
# first stage — close enough for the fleet view, exact exits regardless.
#
# Bash does not inherit a DEBUG trap into a subshell unless `set -T`, so a
# line that is only a subshell — `(cd x && make)` — runs and prints normally
# but is not indexed as a command. Forcing `set -T` on someone's shell to
# close that gap costs more than the gap does.

[[ $- == *i* ]] || return 0
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

# DEBUG fires before every simple command; the at-prompt gate limits the
# preexec marks to the first command after each prompt, and COMP_LINE keeps
# tab-completion callbacks from counting as execution.
__kitterm_preexec() {
  [[ -n $COMP_LINE ]] && return
  [[ -z $__kitterm_at_prompt ]] && return
  # A subshell — `(exit 42)`, `(cd x && make)` — runs the DEBUG trap in the
  # child, so it clears its own copy of the gate and the parent's stays set.
  # The next DEBUG in the parent is PROMPT_COMMAND calling precmd, which
  # would then be reported as the command the user ran.
  [[ $BASH_COMMAND == __kitterm_precmd* ]] && return
  __kitterm_at_prompt=
  printf '\e]633;E;%s\a' "$(__kitterm_escape_cmd "$BASH_COMMAND")"
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
  # OSC 7 cwd report — how kitterm learns where a *remote* shell is (the
  # daemon's local poll only sees the ssh/docker process). Unencoded: fine
  # for ordinary paths; a literal % in the path may display decoded.
  printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"
  __kitterm_at_prompt=1
}

trap '__kitterm_preexec' DEBUG
PROMPT_COMMAND="__kitterm_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

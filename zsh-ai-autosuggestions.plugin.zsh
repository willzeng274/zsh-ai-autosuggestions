# zsh-ai-autosuggestions
# zsh-autosuggestions v0.7.1 fork with local LLM completions via llama.cpp.
# https://github.com/willzeng274/zsh-ai-autosuggestions
#
# Original: Thiago de Arruda, Eric Freese (MIT)
# AI bits: William Zeng

zmodload zsh/system 2>/dev/null

#--------------------------------------------------------------------#
# Configuration                                                      #
#--------------------------------------------------------------------#

(( ! ${+ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE} )) &&
typeset -g ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'

(( ! ${+ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX} )) &&
typeset -g ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX=autosuggest-orig-

(( ! ${+ZSH_AUTOSUGGEST_STRATEGY} )) && {
	typeset -ga ZSH_AUTOSUGGEST_STRATEGY
	ZSH_AUTOSUGGEST_STRATEGY=(history)
}

(( ! ${+ZSH_AUTOSUGGEST_CLEAR_WIDGETS} )) && {
	typeset -ga ZSH_AUTOSUGGEST_CLEAR_WIDGETS
	ZSH_AUTOSUGGEST_CLEAR_WIDGETS=(
		history-search-forward
		history-search-backward
		history-beginning-search-forward
		history-beginning-search-backward
		history-beginning-search-forward-end
		history-beginning-search-backward-end
		history-substring-search-up
		history-substring-search-down
		up-line-or-beginning-search
		down-line-or-beginning-search
		up-line-or-history
		down-line-or-history
		accept-line
		copy-earlier-word
	)
}

(( ! ${+ZSH_AUTOSUGGEST_ACCEPT_WIDGETS} )) && {
	typeset -ga ZSH_AUTOSUGGEST_ACCEPT_WIDGETS
	ZSH_AUTOSUGGEST_ACCEPT_WIDGETS=(
		forward-char
		end-of-line
		vi-forward-char
		vi-end-of-line
		vi-add-eol
	)
}

(( ! ${+ZSH_AUTOSUGGEST_EXECUTE_WIDGETS} )) && {
	typeset -ga ZSH_AUTOSUGGEST_EXECUTE_WIDGETS
	ZSH_AUTOSUGGEST_EXECUTE_WIDGETS=(
	)
}

(( ! ${+ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS} )) && {
	typeset -ga ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS
	ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS=(
		forward-word
		emacs-forward-word
		vi-forward-word
		vi-forward-word-end
		vi-forward-blank-word
		vi-forward-blank-word-end
		vi-find-next-char
		vi-find-next-char-skip
	)
}

(( ! ${+ZSH_AUTOSUGGEST_IGNORE_WIDGETS} )) && {
	typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
	ZSH_AUTOSUGGEST_IGNORE_WIDGETS=(
		orig-\*
		beep
		run-help
		set-local-history
		which-command
		yank
		yank-pop
		zle-\*
		autosuggest-ai-trigger
		_zsh_ai_show_correction
	)
}

(( ! ${+ZSH_AUTOSUGGEST_COMPLETIONS_PTY_NAME} )) &&
typeset -g ZSH_AUTOSUGGEST_COMPLETIONS_PTY_NAME=zsh_autosuggest_completion_pty

# --- AI Configuration ---
ZSH_AI_COMPLETE_MODEL="${ZSH_AI_COMPLETE_MODEL:-$HOME/.local/share/models/Qwen2.5-Coder-3B-Instruct-Q5_K_M.gguf}"
ZSH_AI_COMPLETE_MAX_TOKENS="${ZSH_AI_COMPLETE_MAX_TOKENS:-40}"
ZSH_AI_COMPLETE_PORT="${ZSH_AI_COMPLETE_PORT:-8794}"
ZSH_AI_COMPLETE_MIN_CHARS="${ZSH_AI_COMPLETE_MIN_CHARS:-3}"
ZSH_AI_COMPLETE_HIGHLIGHT="${ZSH_AI_COMPLETE_HIGHLIGHT:-fg=magenta}"
ZSH_AI_LOG="${ZSH_AI_LOG:-}"  # set to a path to enable debug logging

typeset -g _zsh_ai_source=""  # "history", "ai", or ""
typeset -g _zsh_ai_correction=""  # stores correction when AI detects a typo
typeset -g _zsh_ai_manual_mode=""  # set when manual trigger is active

_zsh_ai_log() { [[ -n "$ZSH_AI_LOG" ]] && echo "[$(date +%T)] $*" >>"$ZSH_AI_LOG"; }

#--------------------------------------------------------------------#
# Utility                                                            #
#--------------------------------------------------------------------#

_zsh_autosuggest_escape_command() {
	setopt localoptions EXTENDED_GLOB
	echo -E "${1//(#m)[\"\'\\()\[\]|*?~]/\\$MATCH}"
}

#--------------------------------------------------------------------#
# Widget Helpers                                                     #
#--------------------------------------------------------------------#

_zsh_autosuggest_incr_bind_count() {
	typeset -gi bind_count=$((_ZSH_AUTOSUGGEST_BIND_COUNTS[$1]+1))
	_ZSH_AUTOSUGGEST_BIND_COUNTS[$1]=$bind_count
}

_zsh_autosuggest_bind_widget() {
	typeset -gA _ZSH_AUTOSUGGEST_BIND_COUNTS

	local widget=$1
	local autosuggest_action=$2
	local prefix=$ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX

	local -i bind_count

	case $widgets[$widget] in
		user:_zsh_autosuggest_(bound|orig)_*)
			bind_count=$((_ZSH_AUTOSUGGEST_BIND_COUNTS[$widget]))
			;;
		user:*)
			_zsh_autosuggest_incr_bind_count $widget
			zle -N $prefix$bind_count-$widget ${widgets[$widget]#*:}
			;;
		builtin)
			_zsh_autosuggest_incr_bind_count $widget
			eval "_zsh_autosuggest_orig_${(q)widget}() { zle .${(q)widget} }"
			zle -N $prefix$bind_count-$widget _zsh_autosuggest_orig_$widget
			;;
		completion:*)
			_zsh_autosuggest_incr_bind_count $widget
			eval "zle -C $prefix$bind_count-${(q)widget} ${${(s.:.)widgets[$widget]}[2,3]}"
			;;
	esac

	eval "_zsh_autosuggest_bound_${bind_count}_${(q)widget}() {
		_zsh_autosuggest_widget_$autosuggest_action $prefix$bind_count-${(q)widget} \$@
	}"

	zle -N -- $widget _zsh_autosuggest_bound_${bind_count}_$widget
}

_zsh_autosuggest_bind_widgets() {
	emulate -L zsh

 	local widget
	local ignore_widgets

	ignore_widgets=(
		.\*
		_\*
		${_ZSH_AUTOSUGGEST_BUILTIN_ACTIONS/#/autosuggest-}
		$ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX\*
		$ZSH_AUTOSUGGEST_IGNORE_WIDGETS
	)

	for widget in ${${(f)"$(builtin zle -la)"}:#${(j:|:)~ignore_widgets}}; do
		if [[ -n ${ZSH_AUTOSUGGEST_CLEAR_WIDGETS[(r)$widget]} ]]; then
			_zsh_autosuggest_bind_widget $widget clear
		elif [[ -n ${ZSH_AUTOSUGGEST_ACCEPT_WIDGETS[(r)$widget]} ]]; then
			_zsh_autosuggest_bind_widget $widget accept
		elif [[ -n ${ZSH_AUTOSUGGEST_EXECUTE_WIDGETS[(r)$widget]} ]]; then
			_zsh_autosuggest_bind_widget $widget execute
		elif [[ -n ${ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS[(r)$widget]} ]]; then
			_zsh_autosuggest_bind_widget $widget partial_accept
		else
			_zsh_autosuggest_bind_widget $widget modify
		fi
	done
}

_zsh_autosuggest_invoke_original_widget() {
	(( $# )) || return 0

	local original_widget_name="$1"
	shift

	if (( ${+widgets[$original_widget_name]} )); then
		zle $original_widget_name -- $@
	fi
}

#--------------------------------------------------------------------#
# Highlighting                                                       #
#--------------------------------------------------------------------#

_zsh_autosuggest_highlight_reset() {
	typeset -g _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT

	if [[ -n "$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT" ]]; then
		region_highlight=("${(@)region_highlight:#$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT}")
		unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT
	fi
}

_zsh_autosuggest_highlight_apply() {
	typeset -g _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT

	if (( $#POSTDISPLAY )); then
		local style
		if [[ "$_zsh_ai_source" == "ai" ]]; then
			style="$ZSH_AI_COMPLETE_HIGHLIGHT"
		else
			style="$ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE"
		fi
		typeset -g _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT="$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) $style"
		region_highlight+=("$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT")
		_zsh_ai_log "highlight_apply: source='$_zsh_ai_source' style='$style' entry='$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT'"
	else
		unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT
	fi
}

#--------------------------------------------------------------------#
# Widget Implementations                                             #
#--------------------------------------------------------------------#

_zsh_autosuggest_disable() {
	typeset -g _ZSH_AUTOSUGGEST_DISABLED
	_zsh_autosuggest_clear
}

_zsh_autosuggest_enable() {
	unset _ZSH_AUTOSUGGEST_DISABLED
	if (( $#BUFFER )); then
		_zsh_autosuggest_fetch
	fi
}

_zsh_autosuggest_toggle() {
	if (( ${+_ZSH_AUTOSUGGEST_DISABLED} )); then
		_zsh_autosuggest_enable
	else
		_zsh_autosuggest_disable
	fi
}

_zsh_autosuggest_clear() {
	POSTDISPLAY=
	_zsh_ai_source=""
	_zsh_autosuggest_invoke_original_widget $@
}

_zsh_autosuggest_modify() {
	local -i retval
	local -i KEYS_QUEUED_COUNT

	local orig_buffer="$BUFFER"
	local orig_postdisplay="$POSTDISPLAY"

	POSTDISPLAY=
	_zsh_ai_correction=""

	_zsh_autosuggest_invoke_original_widget $@
	retval=$?

	emulate -L zsh

	if (( $PENDING > 0 || $KEYS_QUEUED_COUNT > 0 )); then
		POSTDISPLAY="$orig_postdisplay"
		return $retval
	fi

	if [[ "$BUFFER" = "$orig_buffer"* && "$orig_postdisplay" = "${BUFFER:$#orig_buffer}"* ]]; then
		POSTDISPLAY="${orig_postdisplay:$(($#BUFFER - $#orig_buffer))}"
		return $retval
	fi

	if (( ${+_ZSH_AUTOSUGGEST_DISABLED} )); then
		return $?
	fi

	if (( $#BUFFER > 0 )); then
		if [[ -z "$ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE" ]] || (( $#BUFFER <= $ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE )); then
			_zsh_autosuggest_fetch
		fi
	fi

	return $retval
}

_zsh_autosuggest_fetch() {
	# clear so the async response can set it
	_zsh_ai_source=""
	if (( ${+ZSH_AUTOSUGGEST_USE_ASYNC} )); then
		_zsh_autosuggest_async_request "$BUFFER"
	else
		local suggestion
		_zsh_autosuggest_fetch_suggestion "$BUFFER"
		_zsh_autosuggest_suggest "$suggestion"
	fi
}

_zsh_autosuggest_suggest() {
	emulate -L zsh

	local suggestion="$1"

	if [[ -n "$suggestion" ]] && (( $#BUFFER )); then
		POSTDISPLAY="${suggestion#$BUFFER}"
	else
		POSTDISPLAY=
		_zsh_ai_source=""
	fi
}

_zsh_autosuggest_accept() {
	local -i retval max_cursor_pos=$#BUFFER

	if [[ "$KEYMAP" = "vicmd" ]]; then
		max_cursor_pos=$((max_cursor_pos - 1))
	fi

	if (( $CURSOR != $max_cursor_pos || !$#POSTDISPLAY )); then
		_zsh_autosuggest_invoke_original_widget $@
		return
	fi

	BUFFER="$BUFFER$POSTDISPLAY"
	POSTDISPLAY=
	_zsh_ai_source=""
	# nuke any leftover AI highlight
	region_highlight=("${(@)region_highlight:#*fg=magenta*}")
	unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT

	_zsh_autosuggest_invoke_original_widget $@
	retval=$?

	if [[ "$KEYMAP" = "vicmd" ]]; then
		CURSOR=$(($#BUFFER - 1))
	else
		CURSOR=$#BUFFER
	fi

	return $retval
}

_zsh_autosuggest_execute() {
	BUFFER="$BUFFER$POSTDISPLAY"
	POSTDISPLAY=
	_zsh_ai_source="history"
	_zsh_autosuggest_invoke_original_widget "accept-line"
}

_zsh_autosuggest_partial_accept() {
	local -i retval cursor_loc

	local original_buffer="$BUFFER"
	BUFFER="$BUFFER$POSTDISPLAY"

	_zsh_autosuggest_invoke_original_widget $@
	retval=$?

	cursor_loc=$CURSOR
	if [[ "$KEYMAP" = "vicmd" ]]; then
		cursor_loc=$((cursor_loc + 1))
	fi

	if (( $cursor_loc > $#original_buffer )); then
		POSTDISPLAY="${BUFFER[$(($cursor_loc + 1)),$#BUFFER]}"
		BUFFER="${BUFFER[1,$cursor_loc]}"
	else
		BUFFER="$original_buffer"
	fi

	return $retval
}

() {
	typeset -ga _ZSH_AUTOSUGGEST_BUILTIN_ACTIONS

	_ZSH_AUTOSUGGEST_BUILTIN_ACTIONS=(
		clear
		fetch
		suggest
		accept
		execute
		enable
		disable
		toggle
	)

	local action
	for action in $_ZSH_AUTOSUGGEST_BUILTIN_ACTIONS modify partial_accept; do
		eval "_zsh_autosuggest_widget_$action() {
			local -i retval

			_zsh_autosuggest_highlight_reset

			_zsh_autosuggest_$action \$@
			retval=\$?

			_zsh_autosuggest_highlight_apply

			zle -R

			return \$retval
		}"
	done

	for action in $_ZSH_AUTOSUGGEST_BUILTIN_ACTIONS; do
		zle -N autosuggest-$action _zsh_autosuggest_widget_$action
	done
}

#--------------------------------------------------------------------#
# History Strategy                                                   #
#--------------------------------------------------------------------#

_zsh_autosuggest_strategy_history() {
	emulate -L zsh
	setopt EXTENDED_GLOB

	local prefix="${1//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"

	local pattern="$prefix*"
	if [[ -n $ZSH_AUTOSUGGEST_HISTORY_IGNORE ]]; then
		pattern="($pattern)~($ZSH_AUTOSUGGEST_HISTORY_IGNORE)"
	fi

	typeset -g suggestion="${history[(r)$pattern]}"

	if [[ -n "$suggestion" ]]; then
		_zsh_ai_source="history"
	fi
}

#--------------------------------------------------------------------#
# AI Strategy                                                        #
#--------------------------------------------------------------------#

_zsh_autosuggest_strategy_ai() {
	typeset -g suggestion

	# too short
	(( ${#1} < ZSH_AI_COMPLETE_MIN_CHARS )) && return

	# "ai " prefix only runs on shift-tab, not on every keystroke
	if [[ "$1" == "ai "* && -z "$_zsh_ai_manual_mode" ]]; then
		return
	fi

	# this runs in the async subprocess
	local json_payload
	json_payload=$(_zsh_ai_build_json "$1")
	_zsh_ai_log "strategy_ai: json_len=${#json_payload} json_start='${json_payload:0:80}'"

	[[ -z "$json_payload" ]] && { _zsh_ai_log "strategy_ai: EMPTY JSON"; return; }

	local raw
	raw=$(curl -sf --max-time 5 "http://127.0.0.1:${ZSH_AI_COMPLETE_PORT}/completion" \
		-H "Content-Type: application/json" \
		-d "$json_payload" 2>/dev/null)
	_zsh_ai_log "strategy_ai: raw_len=${#raw} raw_start='${raw:0:80}'"

	[[ -z "$raw" ]] && return

	local completion
	completion=$(printf '%s' "$raw" | jq -r '.content // empty' 2>/dev/null)
	completion="${completion# }"
	completion="${completion%$'\n'}"

	[[ -z "$completion" ]] && return

	# natural language mode: treat as a correction (replace whole buffer)
	if [[ "$1" == "ai "* ]]; then
		_zsh_ai_correction="$completion"
		_zsh_ai_source="ai"
		_zsh_ai_log "strategy_ai: NL_MODE input='$1' command='$completion'"
		return
	fi

	# figure out if this is a completion (extends buffer) or correction (replaces it)
	if [[ "$completion" == "$1"* ]]; then
		suggestion="$completion"
	elif [[ "$1" == "$completion"* ]]; then
		return # already typed past the suggestion
	elif [[ "$completion" == *"$1"* || "$1" == *"$completion"* ]]; then
		suggestion="${1}${completion}" # partial overlap, just append
	else
		_zsh_ai_correction="$completion" # no match, probably a typo
		_zsh_ai_source="ai"
		_zsh_ai_log "strategy_ai: CORRECTION input='$1' correction='$completion'"
		return
	fi

	# no point suggesting what's already typed
	if [[ "$suggestion" == "$1" ]]; then
		return
	fi

	if [[ -n "$suggestion" ]]; then
		_zsh_ai_source="ai"
		_zsh_ai_log "strategy_ai: COMPLETION input='$1' suggestion='$suggestion'"
	fi
}

_zsh_ai_build_json() {
	local buf="$1"

	local git_branch=""
	git_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

	local ctx=""
	ctx+="cwd: $(pwd)"$'\n'
	[[ -n "$git_branch" ]] && ctx+="git branch: ${git_branch}"$'\n'
	[[ -n "$VIRTUAL_ENV" ]] && ctx+="venv: ${VIRTUAL_ENV##*/}"$'\n'
	[[ -n "$NODE_ENV" ]] && ctx+="NODE_ENV: ${NODE_ENV}"$'\n'
	[[ -n "$AWS_PROFILE" ]] && ctx+="AWS_PROFILE: ${AWS_PROFILE}"$'\n'

	local history_ctx=""
	local -i n=0
	local cmd
	for cmd in "${history[@]}"; do
		history_ctx+='$ '"${cmd}"$'\n'
		(( ++n >= 5 )) && break
	done

	local dir_ctx=""
	if [[ "$buf" == cd* || "$buf" == ls* || "$buf" == cat* || "$buf" == vim* || "$buf" == nvim* || "$buf" == code* ]]; then
		local partial_path="${buf#* }"
		local search_dir="${partial_path%/*}"
		[[ -z "$search_dir" || "$search_dir" == "$partial_path" ]] && search_dir="."
		local dirs files
		dirs=$(command find "${search_dir}" -maxdepth 1 -type d -not -name '.*' 2>/dev/null | head -10 | tr '\n' ' ')
		files=$(command find "${search_dir}" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | head -10 | tr '\n' ' ')
		[[ -n "$dirs" ]] && dir_ctx+="Directories: ${dirs}"$'\n'
		[[ -n "$files" ]] && dir_ctx+="Files: ${files}"$'\n'
	fi

	local branch_ctx=""
	if [[ "$buf" == git\ checkout* || "$buf" == git\ switch* || "$buf" == git\ merge* || "$buf" == git\ rebase* ]]; then
		branch_ctx+="Current branch: ${git_branch}"$'\n'
		local others
		others=$(git branch --format='%(refname:short)' 2>/dev/null | grep -v "^${git_branch}$" | head -9 | tr '\n' ' ')
		[[ -n "$others" ]] && branch_ctx+="Other branches: ${others}"$'\n'
	fi

	local prompt max_tokens mode

	if [[ "$buf" == "ai "* ]]; then
		local description="${buf#ai }"
		max_tokens=120
		mode="nl"

		prompt=$'Convert the request to a shell command.\n\nRequest: list all running containers\nCommand: docker ps\n\nRequest: show disk usage\nCommand: df -h\n\nRequest: find files modified today\nCommand: find . -mtime 0\n\n'
		prompt+="${ctx}${dir_ctx}${branch_ctx}"
		[[ -n "$history_ctx" ]] && prompt+=$'Recent commands:\n'"${history_ctx}"$'\n'
		prompt+=$'Request: '"${description}"$'\nCommand:'
	else
		max_tokens="${ZSH_AI_COMPLETE_MAX_TOKENS}"
		mode="autocomplete"

		prompt=$'$ git chec\t# autocomplete: git checkout\n$ docker ru\t# autocomplete: docker run\n$ kubectl get po\t# autocomplete: kubectl get pods\n$ brew cask ins\t# autocomplete: brew install --cask\n'
		prompt+="${ctx}${dir_ctx}${branch_ctx}"
		[[ -n "$history_ctx" ]] && prompt+=$'Recent commands:\n'"${history_ctx}"$'\n'
		prompt+=$'$ '"${buf}"$'\t# autocomplete:'
	fi

	local json_prompt
	json_prompt=$(printf '%s' "$prompt" | jq -Rs '.' 2>/dev/null)

	local stop_json
	if [[ "$mode" == "nl" ]]; then
		stop_json='["\n\n","User request:","cwd:"]'
	else
		stop_json='["\n"]'
	fi

	printf '%s' "{\"prompt\":${json_prompt},\"n_predict\":${max_tokens},\"temperature\":0.0,\"stop\":${stop_json},\"stream\":false}"
}

#--------------------------------------------------------------------#
# Manual AI trigger                                                  #
#--------------------------------------------------------------------#

_zsh_ai_show_correction() {
	if [[ -n "$_zsh_ai_correction" ]]; then
		zle -M "  suggestion: ${_zsh_ai_correction}  [shift-tab to accept]"
		zle -R
	fi
}
zle -N _zsh_ai_show_correction

_zsh_ai_manual_trigger() {
	_zsh_ai_log "manual: triggered for '$BUFFER'"

	# second shift-tab accepts the pending correction
	if [[ -n "$_zsh_ai_correction" ]]; then
		_zsh_ai_log "manual: accepting correction '$_zsh_ai_correction'"
		_zsh_autosuggest_highlight_reset
		BUFFER="$_zsh_ai_correction"
		CURSOR=${#BUFFER}
		POSTDISPLAY=""
		_zsh_ai_correction=""
		_zsh_ai_source=""
		region_highlight=("${(@)region_highlight:#*fg=magenta*}")
		zle -M ""
		_zsh_autosuggest_highlight_apply
		zle -R
		return
	fi

	_zsh_autosuggest_highlight_reset
	_zsh_ai_correction=""

	# async because curl blocks inside zle widgets
	_zsh_ai_manual_mode=1
	_zsh_autosuggest_async_request "$BUFFER"
	_zsh_ai_manual_mode=""
}
zle -N autosuggest-ai-trigger _zsh_ai_manual_trigger

#--------------------------------------------------------------------#
# Daemon management                                                  #
#--------------------------------------------------------------------#

zsh-ai-start() {
	if curl -sf "http://127.0.0.1:${ZSH_AI_COMPLETE_PORT}/health" >/dev/null 2>&1; then
		echo "zsh-ai: daemon already running on port ${ZSH_AI_COMPLETE_PORT}"
		return 0
	fi
	echo "zsh-ai: starting llama-server..."
	nohup llama-server \
		--model "${ZSH_AI_COMPLETE_MODEL}" \
		--port "${ZSH_AI_COMPLETE_PORT}" \
		--host 127.0.0.1 \
		--ctx-size 2048 \
		--n-gpu-layers 99 \
		--flash-attn on \
		--cont-batching \
		--log-disable \
		>"${TMPDIR:-/tmp}/zsh-ai-complete.log" 2>&1 &
	local pid=$! i=0
	echo "zsh-ai: waiting for server (pid $pid)..."
	while ! curl -sf "http://127.0.0.1:${ZSH_AI_COMPLETE_PORT}/health" >/dev/null 2>&1 && (( i++ < 30 )); do sleep 1; done
	if curl -sf "http://127.0.0.1:${ZSH_AI_COMPLETE_PORT}/health" >/dev/null 2>&1; then echo "zsh-ai: ready"
	else echo "zsh-ai: failed — check ${TMPDIR:-/tmp}/zsh-ai-complete.log"; return 1; fi
}

zsh-ai-stop() {
	local pids
	pids=$(lsof -ti :"${ZSH_AI_COMPLETE_PORT}" 2>/dev/null)
	if [[ -n "$pids" ]]; then
		echo "$pids" | xargs kill 2>/dev/null
		echo "zsh-ai: stopped"
	else
		echo "zsh-ai: not running"
	fi
}

#--------------------------------------------------------------------#
# Fetch Suggestion                                                   #
#--------------------------------------------------------------------#

_zsh_autosuggest_fetch_suggestion() {
	typeset -g suggestion
	local -a strategies
	local strategy

	_zsh_ai_source=""

	# manual trigger skips history/atuin, goes straight to ai
	if [[ -n "$_zsh_ai_manual_mode" ]]; then
		_zsh_ai_log "fetch: manual mode, ai only for input='$1'"
		_zsh_autosuggest_strategy_ai "$1"
		_zsh_ai_log "fetch: FINAL source='$_zsh_ai_source' suggestion='${suggestion:0:50}'"
		return
	fi

	strategies=(${=ZSH_AUTOSUGGEST_STRATEGY})

	_zsh_ai_log "fetch: strategies=(${strategies[*]}) for input='$1'"
	for strategy in $strategies; do
		_zsh_autosuggest_strategy_$strategy "$1"

		_zsh_ai_log "fetch: strategy=$strategy input='$1' suggestion='${suggestion:0:50}'"

		[[ "$suggestion" != "$1"* ]] && unset suggestion

		[[ -n "$suggestion" ]] && break
	done
	_zsh_ai_log "fetch: FINAL source='$_zsh_ai_source' suggestion='${suggestion:0:50}'"
}

#--------------------------------------------------------------------#
# Async                                                              #
#--------------------------------------------------------------------#

_zsh_autosuggest_async_request() {
	zmodload zsh/system 2>/dev/null

	typeset -g _ZSH_AUTOSUGGEST_ASYNC_FD _ZSH_AUTOSUGGEST_CHILD_PID

	if [[ -n "$_ZSH_AUTOSUGGEST_ASYNC_FD" ]] && { true <&$_ZSH_AUTOSUGGEST_ASYNC_FD } 2>/dev/null; then
		builtin exec {_ZSH_AUTOSUGGEST_ASYNC_FD}<&-
		zle -F $_ZSH_AUTOSUGGEST_ASYNC_FD

		if [[ -n "$_ZSH_AUTOSUGGEST_CHILD_PID" ]]; then
			if [[ -o MONITOR ]]; then
				kill -TERM -$_ZSH_AUTOSUGGEST_CHILD_PID 2>/dev/null
			else
				kill -TERM $_ZSH_AUTOSUGGEST_CHILD_PID 2>/dev/null
			fi
		fi
	fi

	builtin exec {_ZSH_AUTOSUGGEST_ASYNC_FD}< <(
		echo $sysparams[pid]

		local suggestion
		_zsh_autosuggest_fetch_suggestion "$1"
		_zsh_ai_log "subprocess: input='$1' source='${_zsh_ai_source}' suggestion='${suggestion:0:50}' correction='${_zsh_ai_correction:0:50}'"
		# pipe back: source, correction, suggestion (one per line)
		echo -E "${_zsh_ai_source}"
		echo -E "${_zsh_ai_correction}"
		echo -nE "${suggestion}"
	)

	autoload -Uz is-at-least
	is-at-least 5.8 || command true

	read _ZSH_AUTOSUGGEST_CHILD_PID <&$_ZSH_AUTOSUGGEST_ASYNC_FD

	zle -F "$_ZSH_AUTOSUGGEST_ASYNC_FD" _zsh_autosuggest_async_response
}

_zsh_autosuggest_async_response() {
	emulate -L zsh

	local suggestion

	if [[ -z "$2" || "$2" == "hup" ]]; then
		# read back what the subprocess piped
		local source correction
		IFS='' read -r -u $1 source
		IFS='' read -r -u $1 correction
		IFS='' read -rd '' -u $1 suggestion

		_zsh_ai_source="$source"
		_zsh_ai_correction="$correction"
		_zsh_ai_log "async_response: source='$source' correction='$correction' suggestion='${suggestion:0:50}'"

		if [[ -n "$correction" ]]; then
			# show correction via widget (zle -M needs widget context)
			zle _zsh_ai_show_correction 2>/dev/null
		else
			zle autosuggest-suggest -- "$suggestion"
		fi

		builtin exec {1}<&-
	fi

	zle -F "$1"
	_ZSH_AUTOSUGGEST_ASYNC_FD=
}

#--------------------------------------------------------------------#
# Start                                                              #
#--------------------------------------------------------------------#

_zsh_autosuggest_start() {
	if (( ${+ZSH_AUTOSUGGEST_MANUAL_REBIND} )); then
		add-zsh-hook -d precmd _zsh_autosuggest_start
	fi

	_zsh_autosuggest_bind_widgets
}

autoload -Uz add-zsh-hook is-at-least

if is-at-least 5.0.8; then
	typeset -g ZSH_AUTOSUGGEST_USE_ASYNC=
fi

add-zsh-hook precmd _zsh_autosuggest_start

# Ensure 'ai' is in the strategy list after all other plugins have loaded
_zsh_ai_ensure_strategy() {
	if [[ "${ZSH_AUTOSUGGEST_STRATEGY[(r)ai]}" != "ai" ]]; then
		ZSH_AUTOSUGGEST_STRATEGY+=("ai")
		_zsh_ai_log "ensure_strategy: added ai, now (${ZSH_AUTOSUGGEST_STRATEGY[*]})"
	fi
	# rebind here so it sticks after all other plugins have loaded
	bindkey '^[[Z' autosuggest-ai-trigger
	bindkey '^X^A' autosuggest-ai-trigger
	# one-shot
	add-zsh-hook -d precmd _zsh_ai_ensure_strategy
}
add-zsh-hook precmd _zsh_ai_ensure_strategy

# shellcheck shell=bash
# Screen fallback. Structured harness events take precedence in the collector.
# Keep this independent of tmux so real screen fixtures can be regression tested.
# fleet_classify <agent> <visible content> <pane title> -> state
fleet_classify() {
  local agent="$1" content="$2" title="${3:-}" title_busy=0
  # A title can survive a failed capture (or a crashed agent); never use it alone.
  if ! printf '%s\n' "$content" | grep -q '[^[:space:]]'; then
    echo unknown
    return
  fi
  if [ "$agent" = codex ]; then
    case "$title" in
      '[ ! ] Action Required'*|'[ . ] Action Required'*) echo waiting; return ;;
    esac
  fi
  case "$title" in
    $'\342\240'*|$'\342\241'*|$'\342\242'*|$'\342\243'*) title_busy=1 ;;
  esac

  printf '%s\n' "$content" | awk -v agent="$agent" -v title_busy="$title_busy" '
    NF { lines[++count] = $0 }
    END {
      # Transcript text is not current state. Consider only the bottom UI, then
      # discard old dialogs/errors when a newer composer/progress cue appears.
      start = count - 19
      if (start < 1) start = 1
      for (i = start; i <= count; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        lower = tolower(line)
        if (agent == "claude") {
          if (line ~ /^[[:space:]]*❯[[:space:]]*$/ ||
              (line ~ /^[[:space:]]*❯[[:space:]]+/ &&
               line !~ /^[[:space:]]*❯[[:space:]]+(Yes|No|[0-9]+\.)/)) prompt = i
          if (line ~ /^[[:space:]│]*❯[[:space:]]+(Yes|No|[0-9]+\.)/ ||
              lower ~ /enter to (select|confirm).*esc to cancel/ ||
              lower ~ /press enter to select/ ||
              line ~ /^[[:space:]│]*(Do you want to proceed|Do you trust the files|Allow this MCP server|Run this command\?)/ ||
              line ~ /│ (Do you want|Would you like)/) waiting = i
          if (lower ~ /esc to interrupt|ctrl\+c to interrupt/)
            busy = strong_busy = i
          if (line ~ /^[[:space:]]*(✳|✽|✶|✻|✢|·)[[:space:]].*…/)
            busy = i
        } else if (agent == "codex") {
          if (line ~ /^[[:space:]]*›([[:space:]]|$)/ &&
              line !~ /^[[:space:]]*›[[:space:]]*[0-9]+\./) prompt = i
          if (line ~ /^[[:space:]]*›[[:space:]]*[0-9]+\./ ||
              lower ~ /enter to (submit answer|confirm or esc|submit.*answer)/ ||
              lower ~ /tab to add notes/ ||
              lower ~ /^[[:space:]]*question [0-9]+\/[0-9]+/) waiting = i
          if (lower ~ /esc to interrupt|ctrl\+c to interrupt/ ||
              line ~ /^[[:space:]]*(•|◦)[[:space:]]+Working \(/)
            busy = strong_busy = i
        } else if (agent == "opencode") {
          if (lower ~ /^[[:space:]│┃]*permission required[[:space:]│┃]*$/ ||
              lower ~ /enter[[:space:]]+(confirm|submit|toggle).*esc[[:space:]]+(dismiss|cancel)/ ||
              lower ~ /⇆[[:space:]]+select.*enter[[:space:]]+confirm/ ||
              lower ~ /allow once.*(always|reject)/) waiting = i
          if (lower ~ /esc[[:space:]]+(again to )?interrupt/ ||
              lower ~ /\[retrying .*attempt #[0-9]+\]/)
            busy = strong_busy = i
          # This footer is also shown while busy: it is only idle evidence when
          # no interrupt/retry or dialog controls are present in the bottom UI.
          if (lower ~ /ctrl\+p[[:space:]]+commands/ ||
              lower ~ /tab[[:space:]]+agents/) idle_footer = prompt = i
        } else if (agent == "pi") {
          if (line ~ /^[[:space:]]*─.*─[[:space:]]*$/) {
            previous_border = border
            border = i
          }
          if (line ~ /^[[:space:]]*── .*Working([[:space:]─]|$)/ ||
              lower ~ /^[[:space:]]*[^[:alnum:]]*[[:space:]]*working\.\.\./ ||
              lower ~ /retrying \([0-9]+\/[0-9]+\) in .* to cancel\)/ ||
              lower ~ /(compacting context|auto-compacting|summarizing branch).* to cancel\)/ ||
              lower ~ /working.* to interrupt\)/)
            busy = strong_busy = i
          if (lower ~ /enter to (select|confirm).*esc to cancel/ ||
              lower ~ /enter[[:space:]]+submit.*esc[[:space:]]+cancel/ ||
              lower ~ /↑↓.*(select|navigate).*enter.*(select|confirm)/)
            waiting = i
        } else if (agent == "agy") {
          if (line ~ /^[[:space:]]*──────────(─)*[[:space:]]*$/) {
            previous_border = border
            border = i
          }
          if (line ~ /^[[:space:]]*>[[:space:]]*$/ ||
              (line ~ /^[[:space:]]*>[[:space:]]+/ &&
               line !~ /^[[:space:]]*>[[:space:]]+(Yes,|No,|[0-9]+\.)/)) prompt = i
          if (lower ~ /\? for shortcuts/) idle_footer = prompt = i
          if (line ~ /^[[:space:]]*(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⣾|⣽|⣻|⢿|⡿|⣟|⣯|⣷)[[:space:]]+.*(\.\.\.|…)/)
            busy = strong_busy = spinner_busy = i
          if (lower ~ /^[[:space:]]*esc to cancel([[:space:]]|$)/ ||
              lower ~ /(·[[:space:]]*|\()(enter\/)?esc to cancel\)/ ||
              lower ~ /esc to interrupt|ctrl\+c to interrupt/)
            busy = strong_busy = i
          if (line ~ /^[[:space:]│╭╰─]*(⚠[[:space:]]*)?(Approval Required|Run this command\?|Allow access to this URL\?|Allow calling this tool\?|Do you want to proceed|Do you trust)/ ||
              line ~ /^[[:space:]│]*[>❯›]?[[:space:]]*([0-9]+\.[[:space:]]+)?(Yes, (run command|allow (access|creation|tool call)|and always allow|proceed|approve|elevate|grant permission)|No, (deny (access|creation|permission)|and always deny))/ ||
              line ~ /Blocked · / ||
              lower ~ /waiting for (site |upload |download )?approval|waiting for (you to sign in|authentication)/ ||
              lower ~ /enter to (select|confirm|submit).*esc to (cancel|dismiss)/ ||
              lower ~ /press enter to (select|confirm|continue|install|update)/)
            waiting = i
          if (lower ~ /^[[:space:]│┃]*(got an error:|\[auth error\]|agy_error:|api error:|quota exhausted)/)
            error = i
        } else {
          # Conservative fallback for other configured harnesses. Do not infer
          # idle merely from the absence of a known spinner.
          if (lower ~ /esc to interrupt|ctrl\+c to interrupt/) busy = strong_busy = i
          if (lower ~ /press enter to (select|confirm)/ ||
              lower ~ /\[(y\/n|n\/y)\]|\(y\/n\)/) waiting = i
          if (line ~ /^[[:space:]]*[>❯›][[:space:]]*$/) prompt = i
        }
        if (lower ~ /^[[:space:]│┃]*(error: |api error: 401|please run \/login|socket connection closed)/)
          error = i
      }

      # A new prompt clears transcript dialogs/errors. A busy footer can occur
      # below OR above the composer (Codex), hence its separate strong signal.
      if (agent == "pi" && previous_border) {
        if (busy < previous_border - 1) busy = 0
        if (waiting < previous_border) waiting = 0
        if (error < previous_border - 1) error = 0
      }
      if (agent == "agy") {
        if (previous_border) {
          if (busy < previous_border - 1) busy = 0
          if (spinner_busy < previous_border - 1) spinner_busy = 0
          if (waiting < previous_border - 1) waiting = 0
          if (error < previous_border - 1) error = 0
        }
        # An active approval/question dialog can coexist with the persistent
        # `esc to cancel` status bar; waiting wins unless a newer spinner or
        # idle footer superseded it.
        if (waiting && waiting >= idle_footer && waiting > spinner_busy &&
            (!previous_border || waiting >= previous_border - 1)) {
          print "waiting"; exit
        }
      }
      if (waiting && waiting >= prompt && waiting >= busy) { print "waiting"; exit }
      if (error && error >= prompt && error > busy && error > waiting) { print "error"; exit }
      if (busy && (busy >= prompt ||
          (strong_busy && (agent == "codex" || agent == "opencode") && busy == prompt - 1) ||
          (agent == "agy" && spinner_busy && previous_border && spinner_busy == previous_border - 1 && !idle_footer))) {
        print "working"; exit
      }
      if (title_busy) { print "working"; exit }
      if (prompt || idle_footer || (agent == "pi" && previous_border)) { print "idle"; exit }
      print "unknown"
    }'
}

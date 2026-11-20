#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/classify.sh"
passed=0
check() {
  local label="$1" expected="$2" agent="$3" content="$4" title="${5:-}" actual
  actual="$(fleet_classify "$agent" "$content" "$title")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

check 'empty capture' unknown claude ''
check 'empty capture with old title' unknown codex '' '⠋ Working'
check 'empty capture with old approval title' unknown codex '' '[ ! ] Action Required'
check 'whitespace capture' unknown pi $' \n\t'
check 'unrecognized screen' unknown codex 'A paragraph from the transcript.'
check 'Claude working' working claude $'❯ fix it\n✳ Thinking… (2s)\nesc to interrupt'
check 'Claude approval beats lingering spinner' waiting claude $'✳ Thinking…\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select · esc to cancel' '⠋ Claude'
check 'Claude answered approval' idle claude $'Do you want to proceed?\n❯ 1. Yes\nFinished successfully.\n❯\n? for shortcuts'
check 'Claude resumed after approval' working claude $'Do you want to proceed?\n❯ 1. Yes\n✳ Reading…\nesc to interrupt'
check 'Claude recovered error' idle claude $'API Error: 401\nSigned in successfully\n❯'
check 'Claude current error' error claude $'❯ continue\nAPI Error: 401 Unauthorized'
check 'Claude old spinner before idle prompt' idle claude $'✳ Thinking…\nAnswer complete.\n❯\n? for shortcuts'
check 'Claude recovered interrupt footer' idle claude $'esc to interrupt\nAnswer complete.\n❯\n? for shortcuts'
check 'Claude selected text is not idle composer' waiting claude $'│ Would you like to continue?\n❯ Yes\n  No'
check 'Claude plain composer' idle claude '❯ '

check 'Codex approval' waiting codex $'Would you like to run the following command?\n$ echo hi\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel'
check 'Codex question interrupt is not work' waiting codex $'Question 1/1 (1 unanswered)\nChoose an option.\n› 1. Option 1\n  2. Option 2\ntab to add notes | enter to submit answer | esc to interrupt'
check 'Codex freeform question' waiting codex $'Please enter your answer.\nenter to submit answer | esc to interrupt'
check 'Codex title on blink' waiting codex 'Background work' '[ ! ] Action Required: sandbox'
check 'Codex title off blink' waiting codex 'Background work' '[ . ] Action Required: sandbox'
check 'Codex working above composer' working codex $'• Working (2s • esc to interrupt)\n›\n100% context left'
check 'Codex idle' idle codex $'All done.\n› Find a bug\n100% context left'
check 'Codex resolved dialog' idle codex $'› 1. Yes, proceed\nPress enter to confirm or esc to cancel\nCommand succeeded.\n›\n100% context left'
check 'Codex old busy footer' idle codex $'• Working (2s • esc to interrupt)\nAll done.\n›\n100% context left'

check 'OpenCode working' working opencode $'Build GPT\nesc interrupt    ctrl+p commands'
check 'OpenCode second escape' working opencode 'esc again to interrupt'
check 'OpenCode permission' waiting opencode $'Permission required\nAllow once  Always  Reject\nenter confirm'
check 'OpenCode tall permission footer' waiting opencode $'Long command output\n⇆ select   enter confirm'
check 'OpenCode question' waiting opencode $'Which option?\n1. First\n2. Second\n↑↓ select  enter submit  esc dismiss'
check 'OpenCode retry' working opencode 'Server unavailable [retrying in 2s attempt #3]'
check 'OpenCode idle footer' idle opencode 'tab agents   ctrl+p commands'
check 'OpenCode recovered permission' idle opencode $'Permission required\nAllow once  Always  Reject\nCommand completed\ntab agents   ctrl+p commands'

check 'pi working editor border' working pi $'── ⠋ Working ─────────────────\n\n─────────────────────────────\nclaude-opus-4.6 • 12%'
check 'pi retry' working pi '⠋ Retrying (1/3) in 2s... (esc to cancel)'
check 'pi manual compaction' working pi '⠋ Compacting context... (esc to cancel)'
check 'pi automatic compaction' working pi '⠋ Context overflow detected, Auto-compacting... (esc to cancel)'
check 'pi branch summary' working pi '⠋ Summarizing branch... (esc to cancel)'
check 'pi idle editor' idle pi $'Answer complete\n─────────────────────────────\n\n─────────────────────────────\nclaude-opus-4.6 • 12%'
check 'pi old working border' idle pi $'── ⠋ Working ─────────────────\nOld prompt\n─────────────────────────────\nAnswer complete\n─────────────────────────────\n\n─────────────────────────────\nclaude-opus-4.6 • 12%'
check 'pi selector' waiting pi $'Select environment\n↑↓ navigate · enter to select · esc to cancel'
check 'pi input dialog' waiting pi $'─────────────────────────────\nEnvironment name\nenter submit  esc cancel\n─────────────────────────────'
check 'pi old input dialog' idle pi $'enter submit  esc cancel\nCompleted.\n─────────────────────────────\n\n─────────────────────────────'
check 'agy idle composer' idle agy $'Answer complete.\n─────────────────────────────\n>\n─────────────────────────────\n? for shortcuts   auto · Gemini 4 Neon · high'
check 'agy idle with draft text' idle agy $'Answer complete.\n─────────────────────────────\n> Yes, let us try that next\n─────────────────────────────\n? for shortcuts   auto · Gemini 4 Neon · high'
check 'agy working spinner and footer' working agy $'○ Running (ls -la) (ctrl+o to expand)\n⣟  Running command...\n─────────────────────────────\n>\n─────────────────────────────\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy working spinner only above composer' working agy $'⠋ Thinking...\n─────────────────────────────\n>\n─────────────────────────────'
check 'agy working footer only' working agy $'─────────────────────────────\n>\n─────────────────────────────\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy old spinner in idle transcript' idle agy $'⠋ Thinking...\n─────────────────────────────\n>\n─────────────────────────────\n? for shortcuts   auto · Gemini 4 Neon · high'
check 'agy approval dialog beats esc to cancel footer' waiting agy $'⚠ Approval Required\nRun this command?\n  tmux list-panes -a\n> 1. Yes, run command\n  2. No, deny permission\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy approval dialog inside borders' waiting agy $'─────────────────────────────\nAllow calling this tool?\n> Yes, allow tool call\n  No, deny permission\n─────────────────────────────\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy blocked ask question' waiting agy $'███ Blocked · AskQuestion\n─────────────────────────────\n>\n─────────────────────────────\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy waiting for sign in' waiting agy $'Open the URL below in your browser:\nWaiting for you to sign in...'
check 'agy resolved approval now working' working agy $'Run this command?\n> Yes, run command\n○ Running (tmux list-panes -a)\n⣟  Running command...\n─────────────────────────────\n>\n─────────────────────────────\nesc to cancel   auto · Gemini 4 Neon · high'
check 'agy resolved approval now idle' idle agy $'Run this command?\n> Yes, run command\nCommand succeeded.\n─────────────────────────────\n>\n─────────────────────────────\n? for shortcuts   auto · Gemini 4 Neon · high'
check 'agy current error' error agy $'> fix it\nGot an error: 500 internal error'
check 'agy auth error' error agy $'[Auth Error] Failed to select license'
check 'agy recovered error' idle agy $'Got an error: 500 internal error\n─────────────────────────────\n>\n─────────────────────────────\n? for shortcuts   auto · Gemini 4 Neon · high'
check 'agy unrecognized transcript' unknown agy 'A paragraph from the transcript mentioning nothing.'
check 'harness isolation agy phrase' unknown codex $'? for shortcuts\nesc to cancel'
check 'harness isolation pi phrase' unknown codex '── ⠋ Working ─────────────────'
check 'generic idle' idle aider '>'
check 'generic unknown' unknown aider 'A code block mentioning Working...'
check 'unknown pane with spinner title' working goose 'Processing' '⠋ goose'

printf 'classifier: %s checks passed\n' "$passed"

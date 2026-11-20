# Input: LC_ALL=C ps -eo pid=,ppid=,pgid=,stat=,tty=,lstart=,args=
# Output: tty TAB agent TAB pid TAB identity. One foreground agent per tty.
# Optional -v api_file=...: Claude API rows: PID TAB identity TAB status ...
# Only executable / interpreter entrypoints are matched, never arbitrary argv.
function basename(path) {
    sub(/^.*\//, "", path)
    return path
}
function recognized(name) {
    return name ~ ("^(" re ")$") ? name : ""
}
function script_agent(path, name) {
    name = basename(path)
    sub(/\.(mjs|cjs|js|py)$/, "", name)
    if (recognized(name) != "") return name
    if (path ~ /\/@(earendil-works|mariozechner)\/pi-coding-agent\/dist\/(bundle\/)?cli\.js$/) return recognized("pi")
    if (path ~ /\/@anthropic-ai\/claude-code\/cli\.js$/) return recognized("claude")
    if (path ~ /\/@openai\/codex\/bin\/codex\.js$/) return recognized("codex")
    if (path ~ /\/@google\/gemini-cli\/dist\/index\.js$/) return recognized("gemini")
    if (path ~ /\/@opencode-ai\/cli\/bin\/opencode2?\.exe$/) return recognized("opencode")
    return ""
}
function command_agent(    exe, i, arg) {
    exe = basename($11)
    if (recognized(exe) != "") return exe
    # OpenCode's published binary has a platform-independent .exe suffix.
    if (exe ~ /^opencode2?\.exe$/) return recognized("opencode")
    if (exe !~ /^(node|nodejs|bun|python([0-9]+(\.[0-9]+)?)?|bash|sh|zsh)$/) return ""
    for (i = 12; i <= NF; i++) {
        arg = $i
        # Inline programs are not script entrypoints, even if their args name agents.
        if (arg ~ /^(-e|-p|-c|--eval|--print)(=|$)/) return ""
        if (arg == "-m") {
            if (exe ~ /^python/ && $(i + 1) ~ /^aider(\.main)?$/) return recognized("aider")
            return ""
        }
        if (arg ~ /^(--require|-r|--import|--loader|--experimental-loader|--conditions|-C)$/) { i++; continue }
        if (arg == "--") { i++; return script_agent($i) }
        if (arg ~ /^-/) continue
        if (exe == "bun" && arg == "run") continue
        return script_agent(arg)
    }
    return ""
}
BEGIN {
    OFS = "\t"
    if (re == "") re = "claude|codex|gemini|aider|opencode|cursor-agent|amp|goose|droid|copilot|grok|crush|pi|agy"
    if (api_file != "") {
        while ((getline api_line < api_file) > 0) {
            split(api_line, api_fields, "\t")
            if (api_fields[1] ~ /^[0-9]+$/) api_pid[api_fields[1]] = api_fields[2]
        }
        close(api_file)
    }
}
NF >= 11 && $1 ~ /^[0-9]+$/ {
    pid = $1
    parent[pid] = $2
    tty[pid] = $5
    state[pid] = $4
    identity[pid] = pid ":" $6 "_" $7 "_" $8 "_" $9 "_" $10
    candidate[pid] = command_agent()
    if (pid in api_pid && api_pid[pid] == identity[pid] && candidate[pid] == "") candidate[pid] = recognized("claude")
}
END {
    # A foreground child (e.g. a tool command) keeps its agent eligible, even if
    # the child temporarily owns the terminal process group. Stopped jobs do not.
    for (pid in parent) {
        if (state[pid] !~ /\+/ || state[pid] ~ /[TZ]/ || tty[pid] ~ /^(\?\??|-)$|^$/) continue
        ancestor = pid
        for (distance = 0; distance < 256 && ancestor in parent; distance++) {
            if (tty[ancestor] != tty[pid]) break
            if (candidate[ancestor] != "" && state[ancestor] !~ /[TZ]/) {
                # The innermost agent owns the visible TUI. Tie-break by PID so
                # ps ordering and awk hash iteration cannot change the winner.
                terminal = tty[pid]
                score = distance
                if (!(terminal in best) || score < best_score[terminal] ||
                    (score == best_score[terminal] && ancestor + 0 > best[terminal] + 0)) {
                    best[terminal] = ancestor
                    best_score[terminal] = score
                }
                break
            }
            if (parent[ancestor] == ancestor) break
            ancestor = parent[ancestor]
        }
    }
    for (terminal in best) {
        pid = best[terminal]
        print terminal, candidate[pid], pid, identity[pid]
    }
}

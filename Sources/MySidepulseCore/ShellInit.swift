import Foundation

/// Printed by `mysidepulse shell-init zsh` for `eval` in .zshrc. A contract
/// with something outside the program that no compiler checks, so it is held
/// to behavioural tests in a real zsh — the same discipline as the LED
/// programs.
public enum ShellInit {
    /// Substituted for the absolute path of the binary that generated the
    /// snippet. A bare `mysidepulse` is a PATH lookup, and PATH is not ours to
    /// trust: on the machine this was developed against, `command -v
    /// mysidepulse` resolved to an unrelated program that happened to sit
    /// earlier on PATH, and every hook call went silently nowhere.
    static let binaryPlaceholder = "@MYSIDEPULSE@"
    /// Kept as a placeholder rather than a literal in the template so the
    /// threshold has one source of truth: the constant here.
    static let showAfterPlaceholder = "@SHOWAFTER@"

    public static func zsh(mysidepulsePath: String) -> String {
        zshTemplate
            .replacingOccurrences(of: binaryPlaceholder, with: mysidepulsePath)
            .replacingOccurrences(of: showAfterPlaceholder,
                                  with: String(Int(K.shellShowAfterDefaultSeconds)))
    }

    // MARK: the block in ~/.zshrc

    /// The first and last line of the block the settings window writes.
    public static let zshrcHeader = "# ---------- MySidepulse ----------"

    /// The comment lines between the opening header and the eval line. The
    /// skip syntax is shown here because MYSIDEPULSE_SKIP is otherwise
    /// invisible, and shown *below the closing line* because there it extends
    /// the shipped list instead of replacing it, and survives a Remove.
    public static var zshrcDescription: [String] {[
        "# The LED strip follows commands that run longer than MYSIDEPULSE_SHOW_AFTER seconds",
        "# (default \(Int(K.shellShowAfterDefaultSeconds))). Guarded so a missing app is silent, not an error on every shell start.",
        "# Everything between the two \"---------- MySidepulse ----------\" lines is removed by",
        "# Settings › General › Hooks › Remove: keep your own lines outside them.",
        "# To keep a command off the strip, add it to MYSIDEPULSE_SKIP *below* the closing line",
        "# (there it extends the shipped list — vi, ssh, claude… — instead of replacing it, and",
        "# survives Remove), for example:  MYSIDEPULSE_SKIP+=(cswap)",
    ]}

    /// The line that sources the snippet. The binary is named by absolute
    /// path for the same reason the snippet calls it that way, and guarded so
    /// a shell on a Mac where the app is gone starts silently.
    public static func zshrcLine(mysidepulsePath: String) -> String {
        "[ -x \"\(mysidepulsePath)\" ] && eval \"$(\"\(mysidepulsePath)\" shell-init zsh)\""
    }

    /// An uncommented line that sources this app's snippet — the block's or a
    /// hand-written one. Another tool's `shell-init zsh` line is never ours.
    public static func isOurEvalLine(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix("#") && t.contains("shell-init zsh")
            && t.lowercased().contains("mysidepulse")
    }

    /// True when `text` already sources the snippet: the header, or an
    /// uncommented eval line of ours.
    public static func zshrcSourcesSnippet(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.trimmingCharacters(in: .whitespaces) == zshrcHeader || isOurEvalLine(line)
        }
    }

    /// The text ~/.zshrc should hold after adding `line`: the content
    /// unchanged, one blank line, the header, the description, the line, the
    /// header again. A new file starts directly with the header. Nil when the
    /// snippet is already sourced.
    public static func zshrcAppending(_ line: String, to existing: String) -> String? {
        if zshrcSourcesSnippet(existing) { return nil }
        let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
        return existing + separator
            + ([zshrcHeader] + zshrcDescription + [line, zshrcHeader]).joined(separator: "\n") + "\n"
    }

    /// The text ~/.zshrc should hold after removing the snippet. Ours, hence
    /// removed: everything from a header line to the next header line,
    /// inclusive (the block says so in its own comment); after a header with
    /// no closing header, the lines up to the next blank one when they are
    /// all comments or eval lines of ours, otherwise the header alone; every
    /// uncommented eval line of ours wherever it sits. Nothing else is
    /// touched — not another tool's `shell-init zsh` line, not a commented
    /// copy, not a foreign line after an unclosed header. The blank line that
    /// separated the block goes with it. Nil when there is nothing to remove.
    public static func zshrcRemoving(from existing: String) -> String? {
        guard zshrcSourcesSnippet(existing) else { return nil }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var i = 0
        func trimmed(_ line: Substring) -> String { line.trimmingCharacters(in: .whitespaces) }
        // The block sat between two blank lines, or at the top or the end of
        // the file: keep one blank, or none.
        func dropSeparatingBlank() {
            let blankBefore = kept.last.map { trimmed($0).isEmpty } ?? true
            if blankBefore, i < lines.count, trimmed(lines[i]).isEmpty { i += 1 }
        }
        while i < lines.count {
            let line = lines[i]
            if trimmed(line) == zshrcHeader {
                if let close = lines[(i + 1)...].firstIndex(where: { trimmed($0) == zshrcHeader }) {
                    i = close + 1
                } else {
                    var j = i + 1
                    while j < lines.count, !trimmed(lines[j]).isEmpty { j += 1 }
                    let block = lines[(i + 1)..<j]
                    i = block.allSatisfy({ trimmed($0).hasPrefix("#") || isOurEvalLine($0) }) ? j : i + 1
                }
                dropSeparatingBlank()
                continue
            }
            if isOurEvalLine(line) { i += 1; dropSeparatingBlank(); continue }
            kept.append(line)
            i += 1
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        if text == "\n" { text = "" }
        return text
    }

    static let zshTemplate = #"""
# MySidepulse: the LED strip follows commands that run longer than
# $MYSIDEPULSE_SHOW_AFTER seconds. Set MYSIDEPULSE_SKIP or MYSIDEPULSE_SHOW_AFTER
# before this line to override either default.
typeset -ga MYSIDEPULSE_SKIP
(( ${#MYSIDEPULSE_SKIP} )) || MYSIDEPULSE_SKIP=(
  vi vim nvim emacs nano pico less more man info
  ssh mosh tmux screen top htop btop watch tig lazygit
  zsh bash sh fish dash ksh su login
  claude codex copilot opencode grok mysidepulse koffeelid
)
: ${MYSIDEPULSE_SHOW_AFTER:=@SHOWAFTER@}
# Declared, never reset: a `source ~/.zshrc` inside a command keeps the job it
# belongs to.
(( ${+_mysidepulse_job} )) || typeset -g _mysidepulse_job=

_mysidepulse_preexec() {
  # $3 is the command line after alias expansion. Split it into shell words
  # through a real array: ${${(z)3}[1]} indexes the *string* and yields its
  # first character, so `true` would come out as `t`.
  local -a words heads checked
  words=(${(z)3})
  # The command to judge is not always the first word: a launcher generates
  # `cd '<dir>' && '<path>/cswap' run`, and matching words[1] put the skip
  # list out of reach of every one of them. Collect the head of each segment
  # instead (split on && || | |& ; & and the group characters; the trailing
  # `;` closes the last one). (Q) strips the quotes a generated path carries
  # — (z) leaves them on the word, so the tail of `'/bin/vim'` is `vim'` and
  # matches nothing — and the tail makes /usr/bin/make and make one entry.
  # Leading VAR=value words and the prefixes below, with their -flags (and
  # the argument of those that take one), are not the program: `sudo -u root
  # vim` is vim. A segment of prefixes alone (`sudo -i`) opens an interactive
  # shell. A shell's name is checked against the skip list only when every
  # word after it is a flag (`bash -l`), not when it runs a script
  # (`bash build.sh`, `sh -c …`).
  local word bare head= prefix= skiparg= shell= skip=
  for word in $words ';'; do
    case $word in
      '&&'|'||'|'|'|'|&'|';'|'&'|'('|')'|'{'|'}')
        [[ -n $prefix && -z $head ]] && skip=1
        [[ -n $shell ]] && checked+=($head)
        head= prefix= skiparg= shell= ;;
      *)
        if [[ -n $head ]]; then
          [[ -n $shell && $word != -* ]] && shell=
          continue
        fi
        if [[ -n $skiparg ]]; then skiparg=; continue; fi
        if [[ -n $prefix && $word == -* ]]; then
          case $prefix:$word in
            sudo:-[ughpCDTUrt]|nice:-n|env:-[uCS]) skiparg=1 ;;
          esac
          continue
        fi
        bare=${word%%=*}
        [[ $word == *=* && $bare == [A-Za-z_]* && $bare != *[^A-Za-z0-9_]* ]] && continue
        bare=${${(Q)word}:t}
        case $bare in
          sudo|time|command|builtin|exec|nice|nohup|env|noglob|caffeinate) prefix=$bare; continue ;;
          zsh|bash|sh|fish|dash|ksh) shell=1 ;;
          *) checked+=($bare) ;;
        esac
        head=$bare; heads+=($head) ;;
    esac
  done
  # One skipped head skips the whole line: the shell waits on an interactive
  # program wherever it sits in the chain, so the line's duration is its
  # duration and means nothing about work.
  [[ -n $skip ]] && return
  for head in $checked; do
    (( ${MYSIDEPULSE_SKIP[(I)$head]} )) && return
  done
  # A line with no program (`FOO=1`) runs nothing worth showing.
  (( ${#heads} )) || return
  # The first head names the job.
  local name=${heads[1]}
  # One slot per shell: the app evicts a shell's previous job on begin, so a
  # stable id needs no randomness and no bookkeeping.
  _mysidepulse_job=zsh-$$
  @MYSIDEPULSE@ job begin --id $_mysidepulse_job --pid $$ --label $name \
    --show-after $MYSIDEPULSE_SHOW_AFTER >/dev/null 2>&1
}

_mysidepulse_precmd() {
  # First statement: $? is the command's status, and later precmd hooks (a
  # theme's exit-status indicator) still expect to see it, so hand it back on
  # the way out rather than leaving them the CLI call's status.
  local code=$?
  if [[ -n $_mysidepulse_job ]]; then
    @MYSIDEPULSE@ job end --id $_mysidepulse_job --exit $code >/dev/null 2>&1
    _mysidepulse_job=
  fi
  return $code
}

# Loading the snippet ends the job this shell's pid holds: one an earlier
# image began (`exec zsh`), or the `source` that is reading it now. As a
# cancellation, so that job never shows as an outcome.
[[ -o interactive ]] && @MYSIDEPULSE@ job end --id zsh-$$ --exit 130 >/dev/null 2>&1
autoload -Uz add-zsh-hook
add-zsh-hook preexec _mysidepulse_preexec
add-zsh-hook precmd _mysidepulse_precmd
"""#
}

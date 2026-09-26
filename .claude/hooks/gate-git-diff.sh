#!/usr/bin/env bash
# PreToolUse gate on the Bash tool.
#
# .claude/settings.json denies the Read tool this repository's secret-shaped
# paths -- cosign.key, a .env, any private key -- and allows `git diff`,
# `git log`, `git show` and `git ls-files` with no prompt. Those are rules on
# different tools: a deny rule on Read says nothing about what an allowed Bash
# command opens or writes, and this family of commands carries one primitive of
# each kind.
#
# The read primitive: `git diff` in its two-path mode compares operands as
# plain files rather than as repository content, so it prints any file this uid
# can read -- untracked, gitignored, or outside the checkout entirely -- and
# never consults the deny list. `cat ./cosign.key` prompts; the diff form did
# not.
#
# Eleven things this gate has to get right, each of them a spelling an earlier
# version of it missed:
#
#   1. The mode has no required flag. `git diff /dev/null ./cosign.key` prints
#      the file with no `--no-index` anywhere in the command, because git
#      enters that mode on its own when two operands are given and either one
#      is not repository content. Matching the flag string alone missed this
#      entirely.
#   2. The shell rewrites the command before git sees it. `--no-'index'` and
#      `--no-\index` both reach git as `--no-index` while a substring test on
#      the typed spelling finds neither.
#   3. `--` does not end the mode. `git diff -- /dev/null ./cosign.key` prints
#      the file: git's own scan (builtin/diff.c, cmd_diff) consumes a leading
#      `--` and then applies the same two-operand test to whatever follows.
#      Only an operand *before* the `--` stops that scan, which is why
#      `git diff HEAD -- path` can never be a plain-file read but
#      `git diff -- a b` can.
#   4. A lone `-` is an operand, not a flag. Git diff reads it as stdin and
#      counts it toward the same two-operand test, so `git diff /etc/shadow -`
#      prints the file. Skipping every dash-prefixed word -- which is right for
#      `--stat`, `-U0` and the rest, since git rejects an unknown one -- leaves
#      the operand count one short of the refusal.
#   5. Git decides inside-or-outside on the spelling, not on where the path
#      lands. `git diff -- ../<checkout>/cosign.key -` names a file inside this
#      repository by a route that leaves it and comes back; git calls that
#      outside and prints the file, while a test that folds `..` first sees a
#      tidy in-tree path and allows it. See `path_inside_worktree` below.
#   6. Bash expands braces before splitting words, so one word here can be two
#      words at git -- `git diff {/dev/null,./cosign.key}` -- and a flag name
#      split by a brace is no flag at all to a matcher working on the typed
#      spelling: `--outpu{t,t}=FILE` reaches git as `--output=FILE`. Both
#      refusals below are rebuilt by four characters. A brace bash would
#      expand is refused inside a git invocation rather than expanded; one
#      it would not -- git's own `HEAD@{1}`, `main@{upstream}` -- is left
#      alone. The brace test reads the words *as typed*, quotes and all:
#      `{a';',b}` is one word to bash and two paths after expansion, and a
#      test run on the quote-stripped words saw `{a` and `,b}` and passed
#      both. See `raw_words`, `brace_would_expand` and `BRACE_MSG`.
#   7. A git invocation ends where bash ends it, and only there. An earlier
#      version of this gate stripped quotes first and then split on every
#      operator character, so a *quoted* operator inside a flag ended the
#      command as far as the scan was concerned: `git diff --src-prefix='x|'
#      /dev/null ./cosign.key` reset the operand count at the `|` and printed
#      the key (issue #316). The same split counted every unquoted `&` as a
#      separator, so `git log 2>&1 --outpu{t,t}=FILE` closed the brace scope
#      at the `&` of its redirection and `git diff 2>&1 /dev/null ./cosign.key`
#      reset the operand count there; `>|` did the same as a pipe and `<(` as
#      a subshell. The split now reads quotes, redirections and process
#      substitution as bash does. See the split below `brace_would_expand`.
#   8. A glob is one word here and however many files match at git. Nothing
#      in `git diff ~/.ssh/*` or `git diff ./cosign.*` looks like two
#      operands, and bash hands git two, which is the plain-file read. "A
#      glob cannot leave the working directory" is no defence either: the
#      deny rules name `./cosign.key`, `./.env` and `**/*.pem`, all of them
#      inside the checkout. Verified against git 2.39.5: one word expanded
#      to two paths printed both files. See `GLOB_MSG`.
#   9. Nothing that decides what a command does has to be written in the
#      command. A variable assignment in front of it -- `GIT_EXTERNAL_DIFF=`,
#      `GIT_DIR=`, `SHELLCHECK_OPTS=`, `LD_PRELOAD=` -- sits outside the
#      prefix an allow rule matches; an `export` sits in another command
#      entirely and outlives the string; and a git global option
#      (`-c diff.external=`, `-C <dir>`) sits between the name and the
#      subcommand. See `GATED_ENV_MSG`, `GATED_EXPORT_MSG` and
#      `GIT_GLOBAL_MSG`.
#  10. An allow rule matching by prefix covers more subcommands than it names.
#      `Bash(git diff*)` matches `git difftool` as readily as `git diff`, and
#      `git difftool --extcmd=PROG` (or `-x PROG`) runs PROG once per changed
#      path -- the same program-running primitive as `GIT_EXTERNAL_DIFF=` and
#      `-c diff.external=`, with neither an assignment nor a config option in
#      the command for the rules above to find. See `DIFFTOOL_MSG`.
#  11. A command's operands do not have to be in the command at all. `xargs`
#      appends the words it reads from standard input -- or from the file
#      `-a` names -- to the command it runs, so `printf '%s\n' /dev/null
#      ./cosign.key | xargs git diff` hands git both operands of the
#      plain-file read while the string after `git diff` holds none, and
#      the allow row matches it anyway: Claude Code 2.1.267 tries
#      `xargs <row>` against every allow row that ends in `*`. The wrappers
#      the permission layer steps over before it matches a row have to be
#      the ones this gate steps over too, and `noglob` was missing: `noglob
#      podman ps >.claude/settings.json` matched `Bash(podman ps*)` while
#      this gate read `noglob` as the command and let the redirection
#      through (bash opens the target before it finds no `noglob` to run;
#      zsh runs the command). See `XARGS_MSG` and the wrapper list below.
#
# The write primitive: `--output=FILE` sends the diff git would have printed to
# a path instead of stdout, so an allow-listed, unprompted call overwrites any
# file this uid can reach -- `cosign.pub`, which is the signature trust anchor
# copied into the image; `.claude/settings.json`; this hook;
# `~/.ssh/authorized_keys`. The deny rules are no help, because they gate the
# Read tool and say nothing about what an allowed Bash command writes. The
# operand scan below cannot see it either: it skips every dash-prefixed word,
# and it stops tracking git at the subcommand, while `git log -p --output=FILE`
# and `git show --output=FILE` are allow-listed and reach the same primitive.
# `git show` refuses the flag only for a *combined* diff -- a merge commit, and
# on git 2.39 only after truncating the file it named -- and writes an ordinary
# commit's diff in full, so "git show rejects --output" is not a reason to
# leave it out.
#
# The written content is diff-framed rather than byte-clean, which matters less
# than it sounds: the `+` lines carry whatever the caller committed, and for a
# trust anchor or a config file corruption alone is the event. Nothing
# legitimate needs the flag -- diff, log and show print to stdout, which the
# agent already reads -- so the refusal is the whole git invocation rather than
# one subcommand. `--output-indicator-new` and its siblings change the marker
# character rather than the destination and stay permitted.
#
# The shell has its own spelling of the same write, and it is the older one:
# `git diff HEAD >cosign.pub` truncates the file before git starts, and
# `>>`, `>|`, `&>`, `&>>`, `2>err`, `>&file` and `<>file` each open a path
# for writing the same way, wherever in the command they are written --
# `>cosign.pub git diff HEAD` is the same command as `git diff HEAD
# >cosign.pub`. Nothing in the allow rule sees it -- the rule
# matches a `git diff` prefix -- and the operand scan must not, because a
# redirection's target is the shell's word, not git's (counting it refused
# `git diff HEAD 2>&1`). So an output redirection inside a git invocation is
# refused outright, whatever it targets, on the same ground as `--output`:
# these commands print to stdout, and that is what to read. `>&N`, `N>&M`
# and `>&-` name a descriptor rather than a path and are not refused; nor is
# any input redirection (`<`, `<<`, `<<<`, `<&`); nor is a redirection on
# some other command of the same string (`echo x >out; git diff HEAD`).
#
# `git` is not the only allow-listed command that opens a file it is pointed
# at. `Bash(shellcheck *)` is allowed with no prompt too, and ShellCheck prints
# the *source line* above every diagnostic it reports, so `shellcheck ./.env`
# prints back every unexported `NAME=value` line of a file `Read(./.env)`
# refuses -- values included -- and a PEM-shaped file gives up its
# `-----BEGIN/END-----` lines and its trailing base64 line. It is a lossy read
# rather than `cat`, and for the `.env` shape the deny rules name, the loss is
# nothing that matters. No permission pattern closes it: patterns match by
# prefix, so `Bash(shellcheck tests/*)` still matches `shellcheck
# tests/run-tests.sh /home/me/.aws/credentials`. So the same operand scan
# applies to a `shellcheck` invocation (see `in_shellcheck` below): every
# operand must resolve inside the working tree and must not be one of the
# secret-shaped names the deny rules list, and a word bash would rewrite
# before ShellCheck saw it -- an unquoted leading `~`, an unquoted `*`, `?`
# or `[`, a `$`, a backtick, an expanding brace, a process substitution -- is
# refused, since `~/.aws/credentials` reaches this hook as a literal `~` that
# resolves inside the tree and reaches bash as `$HOME`, and `.env*` is one
# word here and the file to bash. `SHELLCHECK_OPTS=` is refused wherever it
# is assigned, because ShellCheck reads file operands out of it too. Linting
# this repository's own scripts is unaffected.
#
# That operand scan reads the words after `shellcheck`, and an input
# redirection puts the path somewhere it never looks. ShellCheck reads
# standard input when its operand is `-`, so `shellcheck - < .env` prints the
# file back exactly as `shellcheck ./.env` did, and the scan sees only the `-`
# because the path sits behind the `<` (issue #323). So the target of every
# bare `<` on a shellcheck invocation is held to the operand test -- inside
# the working tree, none of the deny shapes, and spelled out with no brace, no
# leading `~` and no glob, since a glob naming exactly one denied file is not
# the ambiguous redirect bash refuses on its own. It applies wherever the
# redirection is written, the form before the command name
# (`< .env shellcheck -`) included, because bash attaches it to the same
# simple command either way. `/dev/null` stays allowed: nothing is printed
# back, and `</dev/null` is how a session says "no stdin". `<<` and `<<<`
# carry a delimiter or content rather than a path, and `<&` and `<>` name a
# descriptor or open for writing, which the redirection rules already decide.
# See
# `reading_target_refused` and `SHELLCHECK_STDIN_MSG`.
#
# Git reads standard input too. `git log --stdin`, `git show --stdin` and
# `git diff --stdin` take revisions from it, one per line, and the first line
# that is not one ends the run with `fatal: bad revision '<that line>'`, so
# `git log --stdin <.env` printed the first line of the file past
# `Read(./.env)` while this gate, which passed every input redirection on a
# git invocation, exited 0 (issue #351). The same target test is applied to a
# bare `<` on a command whose name may be `git`: a file inside the checkout
# that none of the deny shapes match (`git log --stdin <revs.txt`) and
# `</dev/null` are unaffected. See `GIT_STDIN_MSG`.
#
# The write primitive is not git's alone, either. Six other allow rows in
# `.claude/settings.json` end in `*` -- "this command with any arguments" --
# and a shell output redirection is part of the string that rule matches, so
# the shell opened the target before the command ran and nothing prompted:
# `shellcheck tests/run-tests.sh >cosign.pub` truncated the trust anchor
# before a line was linted (the file is emptied even when the command then
# fails), and `podman images >.claude/settings.json` overwrote the file
# holding these rules. Those commands are named in `GATED_PREFIXES` below,
# and an output redirection inside any of them is refused the way one inside
# a git invocation is; descriptor forms, input redirections, pipes and a
# command no allow rule covers are left alone. One of them also carries a
# flag that undoes the read: `bash -n` parses a script without running it,
# and a later `+n` or `+o noexec` on the same command line turns that back
# off, so `bash -n +n -c 'cat ./cosign.key'` ran the command under the
# linter's allow rule. A word beginning with `+` in a `bash -n` invocation
# is refused, and so is a brace, a glob, a `$` or a backtick in one of its
# words, since `{+,+}n` reaches bash as `+n` and so does `?n` beside a file
# of that name. And `-n` stops bash running the script, not printing it
# (issue #345): `-v` prints every line bash reads, so `bash -n -v
# ./cosign.key` printed the key. The options that print or copy what bash
# reads are refused in a `bash -n` invocation, read the way bash reads its
# own options (`-nv` is `-n -v`, `-no verbose` is `-n -o verbose`), and its
# operands and a file on its stdin are held to the shellcheck operand test,
# since bash prints the line a syntax error stands on (`bash -n .env`).
#
# So this looks at the operands git would actually receive, and refuses the
# two-operand form unless every operand resolves as a revision -- which is what
# separates `git diff main feature` from `git diff /dev/null ./cosign.key`.
# After a bare `--` no word can be a revision, so there the test is git's own:
# two or more words where any one lies outside the working tree. The write
# primitive needs none of that machinery: `--output` anywhere in a git
# invocation is refused outright.
#
# One more rewrite sits between the typed word and the path git opens: an
# unquoted leading `~` is `$HOME` to bash and a literal `~` to a scan of the
# typed words, and `realpath -m -s` resolved that literal to `<checkout>/~/...`,
# an inside path. So `git diff -- ~/.aws/credentials ~/.bashrc` counted two
# operands, found both inside the working tree, and exited 0, and bash then
# handed git two files from the home directory, which it printed. The
# ShellCheck operand scan already refuses that word (see
# `word_bash_would_rewrite`); the git scope now does the same. A word of a
# git invocation that begins with an unquoted `~` (`~/...`, `~user/...`, `~`
# alone) is refused rather than expanded (see `TILDE_MSG`), and
# `path_inside_worktree` counts a leading `~` as outside as well, so neither
# operand scan can be talked into the same answer by another route. A
# quoted or escaped tilde (`'~/x'`, `\~/x`) is a literal to bash and is not
# refused; nor is a tilde inside a word (`HEAD~1`). The containment test is
# stricter than that on purpose: it never resolves a leading `~` inside the
# tree, quoted or not, so two quoted tildes after a `--` (`git diff -- '~/x'
# '~/y'`) are refused as the plain-file form although bash would hand git two
# literal paths. Nothing here is named `~`, and the alternative is a
# containment test that has to know how each word was quoted.
#
# What it still cannot see, stated rather than implied: a command that hides a
# git invocation behind another interpreter (`sh -c ...`, `eval`, and `source`
# or `.`, which can export anything the file it reads assigns), one that
# changes directory out of the repository first, and anything a command reads
# or writes once it has started. Nor an environment variable set by a string
# this gate left alone -- an `export` in a command string that runs nothing
# gated matches no allow rule and prompts, and a human who approves that prompt
# has set it for every later call of the same shell, because the Bash tool's
# shell outlives one call. A `shellcheck -x` run whose target file names an
# outside file in a `source` directive is in that last category: the operands
# are checked, what the tool then opens on their behalf is not. A git argument
# built at runtime (`git diff $x $y`,
# `$(...)`, a backtick, `$'\x74'`) is no longer waved through -- every `$` and
# backtick in a word of a git invocation is refused, see `EXPAND_MSG` -- but
# that is a refusal, not an inspection. This re-gates the pre-approved commands
# that reach past the deny list; it is not a sandbox.

set -uo pipefail

refuse() {
  printf '%s\n' "$1" >&2
  exit 2
}

# shellcheck disable=SC2016 # the message quotes shell spellings as literal
# text -- $'\x74' and $(...) are what the reader has to see, not what this
# script should expand.
EXPAND_MSG='blocked: bash expands ANSI-C quotes and substitutions before git sees the words, and this gate reads the words as typed, so two characters rebuild both spellings it refuses: `git diff $(...)` and a backtick supply operands the operand scan never saw (the plain-file read), and `--outpu$'"'"'\x74'"'"'=FILE` matches no word here and reaches git as --output=FILE. Expanding them correctly means reimplementing bash inside a hook, so every $ and backtick in a word of a git invocation is refused instead. Write the command out in full. Only words of a git invocation are affected: an awk or jq program elsewhere in the string is not, unless it carries a backtick after a git word.'

DIFF_MSG='blocked: this git diff would compare paths as plain files (git'"'"'s --no-index mode, which needs no flag once two operands are given), so it prints any file on disk -- cosign.key, a .env, a private key outside this repository -- past the Read(...) deny rules in .claude/settings.json. Describe such a file with ls -l or wc -c instead.'

SHELLCHECK_MSG='blocked: shellcheck prints the source line above every diagnostic it reports, so pointing it at this path prints that file back -- every unexported NAME=value line of a .env, the BEGIN/END lines of a key -- past the Read(...) deny rules in .claude/settings.json, which gate the Read tool and say nothing about what an allowed Bash command opens. Operands must be inside the working tree and must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519). Linting this repository'"'"'s own scripts is unaffected.'

# shellcheck disable=SC2016 # the literal $HOME and $(...) are what the reader has to see
SHELLCHECK_EXPAND_MSG='blocked: bash rewrites this word before shellcheck sees it, and this gate reads the words as typed, so the path checked here is not the path shellcheck would open: an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to the gate (shellcheck ~/.aws/credentials), an unquoted glob character (*, ? or a bracket) is what bash expands into files this gate never saw (shellcheck .env*), a brace bash would expand is two words (shellcheck {tests/run-tests.sh,/etc/shadow}), and a $, a backtick or a process substitution supplies operands at runtime. Expanding them correctly means reimplementing bash inside a hook, so they are refused inside a shellcheck invocation instead. Spell every path out in full, relative to the checkout. SHELLCHECK_OPTS= is refused for the same reason: shellcheck reads file operands out of it, so pass options on the command line.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
SHELLCHECK_STDIN_MSG='blocked: shellcheck reads standard input when its operand is -, and it prints the source line above every diagnostic it reports, so `shellcheck - < .env` prints the file back exactly as `shellcheck ./.env` does. The operand scan never sees that path, because it sits behind the redirection operator, so the target of a bare < on a shellcheck invocation is checked the way an operand is: it must resolve inside the working tree, it must not be one of the secret-shaped names the Read(...) deny rules in .claude/settings.json list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519), and it must be spelled out -- no brace, no leading ~, no glob, since a glob naming exactly one denied file is not the ambiguous redirect bash refuses on its own. Redirect from a script inside the checkout instead, spelled out in full. </dev/null is unaffected, and so are <<, <<< and <&, which carry a delimiter, content or a descriptor rather than a path.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
DIFFTOOL_MSG='blocked: `git difftool` runs a program of the caller'"'"'s choosing once per changed path -- `git difftool --no-prompt --extcmd=/tmp/evil HEAD~1 HEAD`, and `-x PROG` is the same option one letter long -- and the allow row `Bash(git diff*)` matches it on that prefix, so nothing prompts. It is a third spelling of the primitive this gate already refuses as `GIT_EXTERNAL_DIFF=` and as `-c diff.external=`, and the only one that needs neither an environment nor a config option: the program is an ordinary argument of an allow-listed command. Leaving out --extcmd is no better, since the program is then whatever diff.tool names in a config file this gate cannot see. So the difftool and mergetool subcommands are refused outright. git diff, git log and git show print to stdout; read that instead. Only the subcommand is refused, so --grep=difftool and a path of that name are unaffected.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
GIT_STDIN_MSG='blocked: git log, git show and git diff take revisions from standard input under --stdin, one per line, and the first line that is not a revision ends the run with fatal: bad revision followed by that line, so `git log --stdin <.env` prints the first line of the file back past the Read(...) deny rules in .claude/settings.json. The target of a bare < on a git invocation is therefore checked the way a shellcheck one is: it must resolve inside the working tree, it must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519), and it must be spelled out -- no brace, no leading ~, no glob. Put the revisions in a file inside the checkout, or name them on the command line. </dev/null is unaffected, and so are <<, <<< and <&.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
XARGS_MSG='blocked: xargs adds the words it reads from standard input (or from the file -a/--arg-file names) to the command it runs, so the operands git or the linter receive are not in this string and none of the operand tests here can check them: `printf "%s\n" /dev/null ./cosign.key | xargs git diff` hands git both operands of the plain-file read and prints the key with nothing after `git diff` for this gate to count, and `xargs shellcheck <list.txt` lints, and prints back, whatever list.txt names. The allow rules do not stop it either: Claude Code matches `xargs <prefix>` against an allow row ending in * as readily as `<prefix>` itself, so nothing prompts. xargs is therefore refused in front of git or an allow-listed command (shellcheck, bash -n, podman images, podman ps, findmnt, df -T), wherever it stands among the wrappers (`timeout 5 xargs git diff`, `nice xargs shellcheck`). Name the operands in the command itself instead. xargs in front of a command no allow rule covers (`git diff --name-only | xargs echo`) is unaffected: that string matches no allow row and prompts on its own.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
WRAPPER_PATH_MSG='blocked: a wrapper written as a path, or with a quote or a backslash in it, other than its bare name, /usr/bin/NAME or /bin/NAME -- `./shim/nohup git diff HEAD`, `/tmp/timeout 5 shellcheck tests/run-tests.sh`, `'"'"'./shim\nohup'"'"' git diff HEAD`, `/usr/bin\timeout 5 podman ps >out` -- runs something other than that wrapper: the file at that path, which can be anything, an agent-made file included, or, for `/usr/bin\timeout`, nothing at all once bash has already opened the redirection target. Claude Code reads the word as the wrapper its last path component names (it cuts the text at / and at \), steps over it, and matches the allow rule against the words after it, so nothing prompts. Write the wrapper by its bare name (nohup, timeout, xargs, env, ...), or as /usr/bin/NAME or /bin/NAME, with no quotes or backslashes.'

OUT_MSG='blocked: git --output=FILE (and the space form) writes this diff or log to the path it names instead of stdout, overwriting any file this uid can reach -- cosign.pub, .claude/settings.json, this hook, ~/.ssh/authorized_keys -- with no Read(...) or Write(...) deny rule in its way. git diff, git log and git show print to stdout; read that instead. --output-indicator-* is a different flag and is unaffected.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
GATED_REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside an allow-listed command makes the shell open its target for writing before the command runs, and the allow rule matches a command prefix while the redirection is the rest of the string, so nothing prompts: `shellcheck tests/run-tests.sh >cosign.pub` truncates the trust anchor before a line is linted, and `podman images >.claude/settings.json` overwrites the file holding these rules. It is the same write .claude/hooks/gate-git-diff.sh already refuses for `git diff HEAD >cosign.pub`. These commands print to stdout; read that, or pipe it. Descriptor forms (2>&1, >&2, >&-) and input redirections (<, <<, <<<, <&) are not affected, and a command no allow rule covers is left alone -- that one prompts on its own.'

# shellcheck disable=SC2016 # the literal $(...) and <( are what the reader has to see
GATED_SUBST_MSG='blocked: a substitution or an expansion -- `$(...)`, a backtick, `$VAR`, `<(...)` or `>(...)`, quoted or not, in a word or a redirection target -- in an allow-listed command runs a command or supplies a word as part of a string the allow rule approved on its prefix alone, and neither is held to any rule: `df -T >(cat >cosign.pub)` and `podman images $(printf x >cosign.pub)` truncate the trust anchor from inside the substitution while the command prints as usual. It is refused in these commands the way it is in a git or shellcheck invocation. Write the inner command as a command of its own.'

# shellcheck disable=SC2016 # the literal $(...) and <<EOF are what the reader has to see
GATED_HEREDOC_MSG='blocked: a here-document with an unquoted delimiter (`<<EOF`) on an allow-listed command is expanded by bash before the command runs, so a `$(...)` or a backtick on any line of its body runs as part of the string the allow rule approved on its prefix, and this gate reads those lines as commands of their own: `df -T <<EOF` followed by a `$(printf x >cosign.pub)` line writes the file while df prints as usual. Quote the delimiter (`<<'"'"'EOF'"'"'`) so the body is literal, or pass the input another way.'

# shellcheck disable=SC2016 # the literal NAME=value spellings are what the reader has to see
GATED_ENV_MSG='blocked: an assignment before an allow-listed command (`NAME=value cmd ...`) is an environment the command runs under, and for these commands that changes what runs or where it goes: `LD_PRELOAD=x.so shellcheck f` loads code before a line is linted, `BASH_ENV=f bash -n x` names a file for bash to read, `GH_HOST=other gh pr list` sends the token elsewhere, `CONTAINERS_CONF=f podman ps` re-points podman. A git invocation is held to the same rule (issue #329): `GIT_EXTERNAL_DIFF=prog git diff HEAD~1` runs prog once per changed path, `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=prog` reaches that same driver under another name, and `PATH=dir git diff HEAD~1` runs a different git -- each of them arbitrary code from a string the allow rows match on their git prefix. A deny list of variable names is the wrong shape for this, since GIT_DIR, GIT_INDEX_FILE, LD_PRELOAD and PATH all matter and the list would have to track git'"'"'s own. Every spelling that puts a variable there is refused: NAME=value, NAME+=value (appending to an unset variable creates it, so it is not a narrower case of the first), and the same through env, env -i or a quoted name (`env NAME=value cmd`, `env -i NAME=value cmd`, `env '"'"'NAME'"'"'=value cmd`, which env sets although bash alone would read it as a command name). An export in another command of the same string has a refusal of its own. Run the command without the assignment.'

# shellcheck disable=SC2016 # the backticks quote a command spelling for the reader
BASH_NOEXEC_MSG='blocked: `bash -n` is allow-listed because -n reads a script without running it, and a later +n or +o noexec on the same command line turns that off again, so `bash -n +n -c COMMAND` and `bash -n +o noexec script.sh` run whatever they name under the linter'"'"'s allow rule with no prompt. A word beginning with + in a bash -n invocation is refused. Check syntax with bash -n FILE and nothing else; to run a script, run it as itself so the permission rules see it.'

# shellcheck disable=SC2016 # the literal ${VAR} and $(...) are what the reader has to see
BASH_EXPAND_MSG='blocked: a brace bash could expand, an unquoted glob character (*, ? or a bracket), an unquoted leading ~, a $ or a backtick in a word of a bash -n invocation is refused rather than expanded (a process substitution is refused by GATED_SUBST_MSG), for the reason BRACE_MSG and EXPAND_MSG give for git: bash rewrites the words before the inner bash sees them, so `{+,+}n` matches no spelling here and reaches bash as +n, which turns noexec off, `?n` does the same when a file named +n exists in the working directory, and $(...), ${VAR} and a backtick supply a word this gate never saw. Write the command out in full.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
BASH_ECHO_MSG='blocked: this bash -n invocation carries an option that makes bash print or copy what it reads, and -n stops bash running a script, not printing it: -v (and -o verbose) prints every line as bash reads it, so `bash -n -v ./cosign.key` prints the whole key past the Read(...) deny rules in .claude/settings.json; -D prints every $"..." string in the script; -o history and -i copy every line into ~/.bash_history when bash exits; -i and -l read ~/.bashrc and the login profiles and print the line a syntax error in them stands on, and so does a login shell started without -l: exec -l, or exec -a / env -a (--argv0) naming a zeroth argument that begins with -. -x (and -o xtrace) prints what bash runs, which under -n is nothing; it is refused with the rest because a syntax check has no use for it. bash reads a cluster of letters as separate options (-nv is -n -v) and takes the value of -o from the next word (-no verbose is -n -o verbose), and so does this gate. Check syntax with bash -n FILE and nothing else.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
BASH_READ_MSG='blocked: bash -n prints the line a syntax error stands on, so pointing it at a file prints that line back -- `bash -n .env` prints a NAME=value line whose value holds a ( -- past the Read(...) deny rules in .claude/settings.json, which gate the Read tool and say nothing about what an allow-listed Bash command opens. bash reads the script from standard input when no file is named, so `bash -n - < .env` is the same read. Every operand of a bash -n invocation, and the target of a bare < on it, must be inside the working tree and must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519); </dev/null stays allowed. Check the syntax of this repository'"'"'s own scripts.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside a git invocation makes the shell open its target for writing before git runs -- `git diff HEAD >cosign.pub` truncates the trust anchor, and `>> .claude/settings.json` or `2> .claude/hooks/gate-git-diff.sh` reach any file this uid can write -- and the allow rule for git diff, git log and git show sees none of it. These commands print to stdout; read that instead. Descriptor forms (2>&1, >&2, >&-) and input redirections (<, <<, <<<, <&) are not affected, and a redirection on another command of the same string is that command'"'"'s own.'

# shellcheck disable=SC2016 # the literal $HOME is what the reader has to see
TILDE_MSG='blocked: an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to this gate, so the path checked here is not the path git would open: `git diff -- ~/.aws/credentials ~/.bashrc` resolved both operands inside the working tree and printed both files out of the home directory as a plain-file diff, past the Read(...) deny rules in .claude/settings.json. A word of a git invocation that begins with an unquoted ~ (~/..., ~user/..., or ~ alone) is refused rather than expanded. Spell the path out in full, relative to the checkout. A tilde inside a word (HEAD~1) and a quoted or escaped one are literals to bash and are not refused by this rule.'

# shellcheck disable=SC2016 # the literal $G and $(...) are what the reader has to see
CMD_MSG='blocked: the name of a command in this string is not spelled literally -- it is built by an expansion (`$G diff ...`, `$(printf git) diff ...`, a backtick in command position), by a brace (`{,git} diff ...`), or by a glob (`g?t`, `/usr/bin/g[i]t`) -- so neither this gate nor the allow rule that matched the string'"'"'s literal prefix can tell which command bash will run, and `G=git; $G diff /dev/null ./cosign.key` runs the plain-file read this gate exists to refuse. Spell every command name literally, and drop a variable assignment that only exists to build one. After a wrapper such as command, env, exec, timeout or xargs the same holds for every word of that command, since the wrapper'"'"'s own options are not modelled here. A literal name after an assignment is not what this rule refuses -- the assignment has a refusal of its own -- and a literal path to git (`/usr/bin/git diff`) is read as git. env -S (--split-string) splits a quoted string into a command this gate never sees and is refused outright.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
GLOB_MSG='blocked: bash expands a glob before git sees the words, so one word here is several operands at git and the operand scan never reaches the count it refuses at: `git diff ./cosign.*` is a single word to this gate and two operands to git, which prints both files (verified against git 2.39.5). "A glob cannot leave the working directory" is no reason to expand it and check the result either, because the Read(...) deny rules this gate stands in front of name paths inside the checkout -- ./cosign.key, ./.env, **/*.pem. So a `*`, `?` or `[` bash would expand in a word of a git invocation is refused rather than expanded, for the reason the brace and $ rules give: expanding correctly means reimplementing bash in a hook. Quote the pathspec -- `git diff -- '"'"'*.md'"'"'` is git'"'"'s own glob, matched against repository content rather than against the filesystem -- or write the paths out. A quoted or escaped glob character is a literal to bash and is not refused, and a glob in another command of the string is not a word git receives.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
GATED_EXPORT_MSG='blocked: an export in a string that also runs an allow-listed command puts a variable in that command'"'"'s environment without being written where the command is: bash applies `export GIT_EXTERNAL_DIFF=/tmp/evil; git diff HEAD` to every later command of the string, so the gated command carries no assignment for the leading-assignment scan to find. The test is therefore the whole string, and it is deliberately not ordered: `git status --short; export GIT_EXTERNAL_DIFF=/tmp/evil` runs nothing gated after the export, matches the allow rule on its `git status` prefix, and is the same reach one Bash call later, because the tool'"'"'s shell outlives a single call. export, declare -x, typeset -x, local -x, readonly -x and `set -a` (which exports every assignment made after it) are the spellings refused. A bare `declare NAME=x` or `readonly NAME=x` exports nothing (verified against bash 5.2) and is not refused; neither is an export in a string that runs nothing this gate covers, which matches no allow rule and prompts on its own. Set the variable on the command that needs it, where this gate can see what it reaches, or drop it.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
GIT_GLOBAL_MSG='blocked: a git global option written before the subcommand reaches the same primitives from outside the part an allow rule matches. `-c diff.external=/tmp/evil` runs that program once per changed path -- the config spelling of GIT_EXTERNAL_DIFF, verified against git 2.39.5 -- and `-c core.sshCommand`, `-c credential.helper` and `-c alias.x=!cmd` are the same shape; `--config-env` names an environment variable to take the value from; `-C <dir>` moves git to another directory, so `git -C /home/<user> diff -- .netrc .profile` printed a file outside this checkout while the containment test below resolved both operands inside it; and `--exec-path` is the value form of GIT_EXEC_PATH, which the environment rule refuses in every other spelling. So -c, -C, --config-env and --exec-path are refused in a git invocation rather than stepped over. The options that only rename or relocate what git reports -- --git-dir, --work-tree, --namespace, --super-prefix, --attr-source -- are stepped over as before, so the subcommand behind them is still found. A `-c` after the subcommand is git'"'"'s combined-diff flag and is not affected.'

# shellcheck disable=SC2016 # the literal ${VAR} is what the reader has to see
BRACE_MSG='blocked: bash expands braces before git sees the words, and this gate reads the words as typed, so a brace rebuilds both spellings it refuses: `git diff {/dev/null,./cosign.key}` passes the operand scan as one word and reaches git as two operands (the plain-file read), and `--outpu{t,t}=FILE` matches no word here and reaches git as --output=FILE. Expanding braces correctly means reimplementing bash inside a hook, so a brace bash could expand -- a { followed, anywhere later in the word, by a comma or a .. and then a }, or a ${VAR} -- is refused instead, and so is a process substitution (`git diff <(...)`), which supplies an operand this gate never saw. Write the command out in full. A brace with neither, such as HEAD@{1} or main@{upstream}, is a literal to bash and is not refused; a .. between two reflog entries (HEAD@{2}..HEAD@{1}) has the refused shape, so write HEAD~2..HEAD~1. Only words of a git invocation are affected: awk and jq programs elsewhere in the string are not.'

# Fail closed. This gate stands in front of the pre-approved commands that can
# read a denied path, so a missing dependency must not quietly disable it:
# AGENTS.md requires that setup of this kind fail closed, and a hook that lets
# calls through uninspected when jq is absent is exactly that requirement
# broken by accident.
command -v jq >/dev/null 2>&1 ||
  refuse 'blocked: this PreToolUse hook needs jq to inspect the command and jq is not on PATH. It gates the pre-approved commands that can read a denied path, so it refuses rather than letting calls through uninspected. Install jq.'

payload="$(cat)"
command_string="$(printf '%s' "${payload}" | jq -r '.tool_input.command // empty')" ||
  refuse 'blocked: this PreToolUse hook could not parse the tool payload as JSON, so it cannot tell whether the call reads a denied path. It refuses rather than letting the call through uninspected.'

[[ -n "${command_string}" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

# The shape of every brace expansion bash performs: a `{`, then a `,` or a
# `..` somewhere after it, then a `}` somewhere after that. Bash pairs a `{`
# with the last `}` it can, so `{a},b}` expands (to `a}` and `b}`) and a test
# that closed the brace at the first `}` missed the comma; no nesting or
# matching is tracked here, on purpose, and every refinement toward bash's
# real rule is a chance to disagree with it in some other direction. What
# this never does is call a word literal that bash would rewrite. Git's own
# `HEAD@{1}`, `main@{upstream}`, `@{-1}` and `@{2.days.ago}` have neither
# inside the braces and pass; so does a `{` that never closes, which bash
# leaves alone. `HEAD@{2}..HEAD@{1}` is refused although bash would not
# expand it -- the over-refusal is the safe direction, and BRACE_MSG names
# the `HEAD~2..HEAD~1` spelling. `${VAR}` is refused as well, as a
# runtime-built argument this hook cannot inspect.
#
# It is applied to the word as typed, quotes and backslashes included. A
# quoted comma or operator is still part of the word bash expands --
# `{a",",b}` and `{a';',b}` both become two words -- and a test on the
# quote-stripped spelling, cut at its `;`, saw `{a` and `,b}` and waved both
# through. A fully quoted `"{a,b}"`, which bash leaves alone, is refused as
# the price of that.
brace_would_expand() {
  # shellcheck disable=SC2016 # the literal `${` is what is being looked for
  [[ "$1" == *'${'* || "$1" == *'{'*','*'}'* || "$1" == *'{'*..*'}'* ]]
}

# The command's words as bash would delimit them, split once and read by both
# scans below. Each word is kept in two spellings: as typed, with every quote
# mark and backslash in place, because bash brace-expands exactly that form
# and `brace_would_expand` has to see it; and with the quotes and backslashes
# removed, which is the word git receives and what the operand scan compares.
# Alongside them is what kind of thing each entry is: a `word` of a command, a
# `sep` (an unquoted command separator: `;`, `&`, `&&`, `|`, `||`, `|&`, `(`,
# `)`, a newline, a backtick), or the `target` of a redirection.
#
# The separators are the only things that end a command, and the list has to
# be exactly bash's, in both directions. An earlier version of this split
# treated every unquoted `&` as a separator and reset the git scope at it, so
# `git log 2>&1 --outpu{t,t}=cosign.pub -1` passed: the `&` in `2>&1` closed
# the scope before the brace was seen, then bash expanded the flag and git
# overwrote the file. The same `&` reset the operand scan, and `git diff 2>&1
# /dev/null ./cosign.key` printed the key with neither operand counted. `>&`,
# `<&`, `&>` and `&>>` are redirections, and so is `>|` (the noclobber form),
# where the `|` is not a pipe. `|&` is a pipe and stays a separator. A `(`
# behind an unquoted `<` or `>` is a process substitution rather than a
# subshell: `git diff <(true) ./cosign.key` hands git a `/dev/fd/N` operand
# this scan never counted, so it is refused in a git invocation as an
# expanding brace is (see `raw_in_git` below) instead of resetting the scope
# at its `(`.
#
# A redirection is `[n]op word` -- an optional descriptor number written hard
# against the operator, one of `<`, `>`, `>>`, `<<`, `<<<`, `<>`, `>&`, `<&`,
# `>|`, `&>`, `&>>`, and the target word. None of it is a word git receives:
# the number is dropped, the target is kept as `target` so that the operand
# scan can skip it, and the operator is kept beside the target in
# `redirects`, because which operator it was decides whether the shell opens
# the target for writing (see `redirection_writes_a_path`). `git diff HEAD
# 2>&1` is a one-operand diff; counting `2` and `1` refused it. A heredoc's
# body lines are read as words of the command that opened it, which can only
# over-refuse.
#
# No real word is ever empty in the as-typed spelling: a typed `""` keeps its
# quotes. An unquoted `\` followed by a newline is a line continuation, which
# bash removes before anything else, and it is removed here.
raw_words=()
words=()
kinds=()
redirects=() # the operator, for a `target`; empty for anything else
globs=()     # 1 when the word carries a `*`, `?` or `[` bash would expand
raw_word=''
raw_glob=0
raw_quote=''
raw_escaped=0
redirect_pending=0 # the next word is the target of a redirection
redirect_op=''     # the operator of that redirection, as typed
after_redirect=0   # the previous unquoted character was `<` or `>`
subst_depth=0      # open `$(` substitutions, whose `)` is not a subshell's

push_word() {
  raw_words+=("${raw_word}")
  words+=("${raw_word//[\'\"\\]/}")
  kinds+=("$1")
  redirects+=("${2-}")
  globs+=("${raw_glob}")
  raw_word=''
  raw_glob=0
}
end_word() {
  [[ -n "${raw_word}" ]] || return 0
  if ((redirect_pending)); then
    push_word target "${redirect_op}"
    redirect_pending=0
    redirect_op=''
  else
    push_word word
  fi
}
push_sep() {
  end_word
  raw_words+=('')
  words+=("$1")
  kinds+=(sep)
  redirects+=('')
  globs+=(0)
  redirect_pending=0
  redirect_op=''
}

for ((i = 0; i < ${#command_string}; i++)); do
  ch="${command_string:i:1}"
  next="${command_string:i+1:1}"
  prev_redirect="${after_redirect}"
  after_redirect=0
  if ((raw_escaped)); then
    raw_escaped=0
    if [[ "${ch}" == $'\n' ]]; then
      raw_word="${raw_word%\\}"
    else
      raw_word+="${ch}"
    fi
    continue
  fi
  if [[ -n "${raw_quote}" ]]; then
    raw_word+="${ch}"
    if [[ "${ch}" == "${raw_quote}" ]]; then
      raw_quote=''
    elif [[ "${raw_quote}" == '"' && "${ch}" == $'\\' ]]; then
      raw_escaped=1
    fi
    continue
  fi
  case "${ch}" in
  $'\\')
    raw_escaped=1
    raw_word+="${ch}"
    ;;
  "'" | '"')
    raw_quote="${ch}"
    raw_word+="${ch}"
    ;;
  ' ' | $'\t')
    end_word
    ;;
  '<' | '>')
    # `2>` and `10<`: the digits are the descriptor, not a word, and so is
    # bash's `{name}>` form, which allocates a descriptor into the variable.
    if ((!redirect_pending)) && [[ "${raw_word}" =~ ^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})$ ]]; then
      raw_word=''
      raw_glob=0
    else
      end_word
    fi
    if [[ "${next}" == '(' ]]; then
      # Process substitution. Kept as a word spelled `<(` or `>(` so the
      # brace scan can refuse it inside a git invocation; its body is a
      # command of its own and is split as one. Written where a
      # redirection's target goes (`df -T > >(cat >victim)`), it is that
      # target: bash connects the command's output to the substitution,
      # which writes wherever it likes, so it is kept as a `target` of that
      # operator and `redirection_writes_a_path` reads it as the write it
      # is (review on arch-bootc#322).
      raw_word="${ch}("
      if ((redirect_pending)); then
        push_word target "${redirect_op}"
        redirect_pending=0
        redirect_op=''
      else
        push_word word
      fi
      push_sep '('
      ((i++))
      continue
    fi
    # A second `>` or `<` while the target is still to come extends the
    # operator (`>>`, `<<`, `<<<`, `<>`); after a target it opens a new one
    # (`>x>y`), and `end_word` above has already emptied `redirect_op`.
    redirect_op+="${ch}"
    redirect_pending=1
    after_redirect=1
    ;;
  '&')
    if ((prev_redirect)); then
      redirect_op+='&' # `>&` or `<&`: the operator continues and its target follows.
    elif [[ "${next}" == '>' ]]; then
      end_word # `&>` and `&>>`: the `>` that follows opens the redirection.
      redirect_op='&'
    else
      push_sep '&'
    fi
    ;;
  '|')
    if ((prev_redirect)); then
      redirect_op+='|' # `>|`: noclobber redirection, not a pipe.
    else
      push_sep '|'
    fi
    ;;
  $'\n') push_sep ';' ;;
  '#')
    # A `#` that begins a word after whitespace starts a comment, which bash
    # drops through the end of the line, so `shellcheck tests/run-tests.sh
    # # output > file` opens nothing (review on aurora-zfs-simple#211). Only
    # that spelling is dropped here: a `#` inside a word (`HEAD^#x`) is a
    # character of it, and one straight after an operator (`;#`, `>#`) is
    # kept as a word, which can only over-refuse.
    if [[ -z "${raw_word}" ]] && { ((i == 0)) || [[ "${command_string:i-1:1}" == [$' \t\n'] ]]; }; then
      while ((i + 1 < ${#command_string})) && [[ "${command_string:i+1:1}" != $'\n' ]]; do
        ((i++))
      done
    else
      raw_word+="${ch}"
    fi
    ;;
  '(')
    # `$(`: a command substitution, not a subshell. It is a nested command,
    # so it is split as one, but the command around it goes on afterwards:
    # `>$(printf cosign.pub) git diff HEAD` is git's redirection, and a
    # scope that reset at the `(` had forgotten the target by the time it
    # reached `git`. The `$(` and `$)` separators let the scans below save
    # and restore the outer command's state instead of resetting it.
    if [[ "${raw_word}" == *'$' && "${raw_word}" != *'\$' ]]; then
      end_word
      # shellcheck disable=SC2016 # the literal `$(` is the separator's name
      push_sep '$('
      ((subst_depth++))
    else
      push_sep '('
    fi
    ;;
  ')')
    if ((subst_depth > 0)); then
      ((subst_depth--))
      push_sep '$)'
    else
      push_sep ')'
    fi
    ;;
  ';' | '`') push_sep "${ch}" ;;
  '*' | '?' | '[')
    # A pathname expansion. Recorded on the way past, where the quoting is
    # still known: this arm is reached only outside quotes and outside a
    # backslash escape, because both of those are handled above and
    # `continue`. The spellings kept for each word are no help here -- the
    # quote-stripped one has lost the quotes, and the as-typed one keeps them
    # but says nothing about which characters they covered -- and `'*.md'` is
    # a literal to bash while `*.md` is however many files match.
    raw_glob=1
    raw_word+="${ch}"
    ;;
  *) raw_word+="${ch}" ;;
  esac
done
end_word

# Every scan below looks for a literal `git` word to open its scope, and the
# allow rules in .claude/settings.json match a literal `git diff`/`git log`
# prefix. Both are blind to a command whose *name* is not that word: in
# `git status; G=git; $G diff /dev/null ./cosign.key` the string is allowed
# on its `git status` prefix, `$G` is not the word `git`, so no scope opens
# and the hook exits 0 -- and bash runs the plain-file read (review on
# aurora-zfs-simple#205, the same hook). `$(printf git) diff ...` and a
# backtick in command position
# are the same thing spelled differently; so are `{,git} diff ...`, which
# bash brace-expands to `git`, and `g?t` or `/usr/bin/g[i]t`, which pathname
# expansion resolves to it; and so is the plain `/usr/bin/git diff ...`,
# which needs no expansion at all. Whether the permission layer would prompt
# for the second command on its own is not this gate's to assume.
#
# So the word that names each command has to be literal, and a literal path
# to git has to count as git. The name is the first word after a separator
# (or of the string) that is not a variable assignment (`FOO=bar git diff
# HEAD` names git) and not a shell keyword that takes a command (`{`, `!`,
# `if`, `then`, `time`, ...). After a wrapper that runs its arguments
# (`command`, `exec`, `env`, `nohup`, `noglob`, `xargs`, `timeout`, ...)
# the name is somewhere among the words that follow, behind options this
# gate does not model -- `command -- $G` -- so every remaining word of that
# command is held to the test. A word in that position carrying a `$`, a
# backtick, a `*` or `?`, a `[` (other than the `[` and `[[` commands
# themselves), or a brace bash would expand is refused, and so is an
# unquoted backtick opening there, whose output would be the name. A
# literal name whose last path component is `git` is rewritten to `git`, so
# `/usr/bin/git diff` opens every scope that `git diff` does, and one whose
# last component is a wrapper is that wrapper when it is `/usr/bin/NAME` or
# `/bin/NAME` and is refused as any other path (see `WRAPPER_PATH_MSG`).
# A redirection's target is never the name. One wrapper
# option is modelled, because it is not an option but an interpreter:
# `env -S 'git diff /dev/null ./cosign.key'` (GNU and uutils
# `--split-string`) splits its quoted string into a command this scan never
# sees as words, so any `-S`, clustered (`-iS`) or long, after `env` is
# refused outright. `sh -c ...` and `eval` remain the interpreters the
# header says this hook does not see behind.
#
# The wrapper list has to hold every wrapper the permission layer steps over
# before it matches an allow row, and Claude Code 2.1.267 strips `time`,
# `nohup`, `timeout`, `nice`, `stdbuf`, `command`, `builtin` and
# `noglob`. `noglob`, zsh's precommand modifier, takes no options and was
# missing here, so `noglob podman ps >.claude/settings.json` matched
# `Bash(podman ps*)` while this scan named `noglob` and the gated-prefix
# scan below never reached `podman ps`. Bash opens the target and only then
# finds no `noglob` to run, so the file is truncated either way; under zsh
# the command runs too. `xargs` is recorded where it stands as a wrapper
# (`xargs_wrappers`), because stepping over it is not enough: it adds
# operands this string does not hold. See `XARGS_MSG` and
# `check_gated_command`. Its own options are read as well, so that the
# command it runs is known and the words after that command are its
# arguments rather than names (see the xargs option reading below).
#
# The cost is a backtick assignment (`X=\`date\``): the split ends the word
# `X=` at the backtick, and the backtick then opens in command position. The
# `$(...)` spelling of the same assignment is not affected. A glob or a `$`
# in an argument after a wrapper (`timeout 60 find . -name '*.sh'`) is
# refused too; without the wrapper it is not.
# The wrapper options, by wrapper and detached spelling, that take their
# value as the *next* word rather than attached to the option itself. Only
# the detached spelling needs an entry: `-uNAME`, `--unset=NAME` and
# `--chdir=DIR` are one word already, and the dash-prefix test below steps
# over them like any other option. Without this, the value word -- `X` in
# `timeout -s X ...`, `L` in `stdbuf -o L ...`, `5` in `nice -n 5 ...`,
# `UNUSED` in `env -u UNUSED ...` -- was read as the command name: it
# matched no GATED_PREFIXES row and was not `git`, so a leading assignment
# after it stood behind a command that had already been "named" and the
# environment refusal never fired (review on arch-bootc#334).
wrapper_option_takes_value() {
  local wrapper="$1" option="$2"
  case "${wrapper}:${option}" in
  env:-u | env:--unset | env:-C | env:--chdir) return 0 ;;
  nice:-n | nice:--adjustment) return 0 ;;
  timeout:-s | timeout:--signal | timeout:-k | timeout:--kill-after) return 0 ;;
  stdbuf:-i | stdbuf:--input | stdbuf:-o | stdbuf:--output | stdbuf:-e | stdbuf:--error) return 0 ;;
  xargs:-I | xargs:--replace | xargs:-L | xargs:--max-lines | xargs:-n | xargs:--max-args | \
    xargs:-P | xargs:--max-procs | xargs:-s | xargs:--max-chars | xargs:-a | xargs:--arg-file | \
    xargs:-d | xargs:--delimiter | xargs:-E | xargs:--eof) return 0 ;;
  sudo:-u | sudo:--user | sudo:-g | sudo:--group | sudo:-h | sudo:--host | \
    sudo:-p | sudo:--prompt | sudo:-C | sudo:--close-from | sudo:-T | sudo:--command-timeout | \
    sudo:-R | sudo:--chroot) return 0 ;;
  doas:-u | doas:-C) return 0 ;;
  esac
  return 1
}

# The wrappers this scan steps over to find the name, by the name bash would
# run. `time` is here for its path spellings only: the bare word is bash's
# keyword and is read above that, while `/usr/bin/time` is the external
# program, which runs its arguments like any wrapper here, so
# `/usr/bin/time shellcheck tests/run-tests.sh >cosign.pub` is shellcheck's
# redirection (review on #339); its `-p` is an option like any other.
is_wrapper() {
  case "$1" in
  command | builtin | exec | env | nohup | noglob | nice | xargs | timeout | stdbuf | sudo | doas | time) return 0 ;;
  esac
  return 1
}

# Whether a word in a name position is spelled literally: no `$`, backtick,
# `*` or `?`, no `[` other than the `[` and `[[` commands themselves, and no
# brace bash would expand.
name_is_literal() {
  local raw="$1" word="$2"
  [[ "${raw}" == *'$'* || "${raw}" == *'`'* || "${raw}" == *'*'* || "${raw}" == *'?'* ]] && return 1
  brace_would_expand "${raw}" && return 1
  [[ "${raw}" == *'['* && "${word}" != '[' && "${word}" != '[[' ]] && return 1
  return 0
}

# GNU findutils' and uutils' xargs short options, clustered the way getopt
# allows (`-0rn1`). Returns non-zero at a letter it does not know, and at an
# optional-value letter (`-e`, `-i`, `-l`) with no value attached, which the
# two implementations read differently. Sets `xargs_optarg` when a letter
# that takes a value ends the word, so the value is the next word.
xargs_short_options() {
  local cluster="${1#-}" i
  for ((i = 0; i < ${#cluster}; i++)); do
    case "${cluster:i:1}" in
    0 | o | p | r | t | x) ;;
    a | d | E | I | L | n | P | s)
      ((i + 1 < ${#cluster})) || xargs_optarg=1
      return 0
      ;;
    e | i | l)
      ((i + 1 < ${#cluster}))
      return
      ;;
    *) return 1 ;;
    esac
  done
  return 0
}

command_word_pending=1 # the next word of this command may be its name
after_time=0           # the last name-position word was `time`, whose -p may follow
after_wrapper=0        # a wrapper ran: every remaining word may be the name
command_names=()       # 1 at each index that names, or may name, a command
xargs_wrappers=()      # 1 at each index where `xargs` runs the rest of its command
argv0_words=()         # 1 at each exec/env option that sets the zeroth argument
xargs_state=0          # 1: xargs's own options are being read; 2: after its `--`
xargs_optarg=0         # the next word is the value of an xargs option
xargs_command_idx=-1   # the word xargs runs, once its options are read
wrapper_name=''
# 1 while the previous word was a wrapper option that takes a separate value
# word; that next word is neither a name nor an assignment.
wrapper_value_pending=0
# 1 after `timeout` is recognised, until its own mandatory DURATION operand
# is consumed: `timeout [OPTION] DURATION COMMAND` takes a positional
# argument no dash marks, so the option scan below cannot skip it as an
# option's value, and unconsumed it was read as the command name --
# `timeout -s TERM 60 GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD` named `60`
# and neither the later `git` nor the assignment ahead of it was checked. No
# other wrapper here has a positional word of its own before its command.
wrapper_positional_pending=0
in_backtick=0
name_stack=() # the outer command's state, while a `$(...)` is being read
for ((idx = 0; idx < ${#words[@]}; idx++)); do
  case "${kinds[idx]}" in
  sep)
    # A `$(...)` substitution is a nested command: its own words are held
    # to the rule, and the command around it resumes where it left off, so
    # `>$(printf x) git diff HEAD` still finds its name at `git` and
    # `echo $(date) *.sh` does not read `*.sh` as a name.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]]; then
      name_stack+=("${command_word_pending} ${after_wrapper} ${wrapper_value_pending} ${wrapper_positional_pending} ${xargs_state} ${xargs_optarg} ${wrapper_name}")
      command_word_pending=1
      after_wrapper=0
      wrapper_name=''
      wrapper_value_pending=0
      wrapper_positional_pending=0
      xargs_state=0
      xargs_optarg=0
      continue
    fi
    if [[ "${words[idx]}" == '$)' ]] && ((${#name_stack[@]})); then
      read -r command_word_pending after_wrapper wrapper_value_pending wrapper_positional_pending xargs_state xargs_optarg wrapper_name <<<"${name_stack[-1]}"
      unset 'name_stack[-1]'
      continue
    fi
    if [[ "${words[idx]}" == '`' ]]; then
      if ((in_backtick)); then
        # Closing: the command that contained the substitution has its name.
        in_backtick=0
        command_word_pending=0
        after_wrapper=0
        wrapper_name=''
        wrapper_value_pending=0
        wrapper_positional_pending=0
        xargs_state=0
        xargs_optarg=0
        continue
      fi
      ((command_word_pending)) && refuse "${CMD_MSG}"
      in_backtick=1
    fi
    command_word_pending=1
    after_wrapper=0
    after_time=0
    wrapper_name=''
    wrapper_value_pending=0
    wrapper_positional_pending=0
    xargs_state=0
    xargs_optarg=0
    continue
    ;;
  target) continue ;;
  *) ;;
  esac
  ((command_word_pending)) || continue
  raw_word="${raw_words[idx]}"
  word="${words[idx]}"
  # The word right after a wrapper option that takes a separate value
  # (`env -u NAME`, `timeout -s TERM`, `nice -n 5`, `stdbuf -o L`, ...) is
  # that value, not a word of the command the wrapper runs. Consuming only
  # the option itself and not this word left it to fall through to the
  # command-name test below: `env -u UNUSED GIT_EXTERNAL_DIFF=/tmp/evil git
  # diff HEAD~1` read `UNUSED` as the command name, which matched no
  # GATED_PREFIXES row and was not `git`, so neither the later `git` nor
  # the `GIT_EXTERNAL_DIFF=` assignment ahead of it was ever checked
  # (review on arch-bootc#334). `after_wrapper` and `wrapper_name` are left
  # exactly as they were: the word after this one is still the wrapper's
  # own name search, not the wrapper's again.
  if ((wrapper_value_pending)); then
    wrapper_value_pending=0
    continue
  fi
  # `timeout`'s own DURATION, consumed once its dash-prefixed options (if
  # any) are behind it: the first word that is not itself one of those
  # options is it, whatever it looks like (`60`, `0.5`, `2m`).
  if ((wrapper_positional_pending)) && [[ "${word}" != -* ]]; then
    wrapper_positional_pending=0
    continue
  fi
  # xargs's own options and their values, read so that the command xargs
  # runs is known: it is the first word after them, and the words after it
  # are that command's arguments rather than names. Read as a chain of name
  # candidates, `git ls-files | xargs grep -l git` and `git ls-files | xargs
  # rg shellcheck` were refused as a git and a shellcheck run, when xargs
  # runs grep and rg there (review on aurora-zfs-simple#224). Read here,
  # before the assignment and keyword tests below, which would take the
  # value in `-I if` or `-I A=1` for a word of their own and hand the value's
  # slot to the command after it. Held to the literal test all the same: bash
  # splits an unquoted `$X` in `-n$X` into more words. An option GNU
  # findutils and uutils do not both read the same way (`--max-lines 1`, a
  # bare `-i`), one neither has (`-J`), or an abbreviated long option leaves
  # the older reading in place: every later word may be the name.
  if ((xargs_optarg)); then
    name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
    xargs_optarg=0
    continue
  fi
  if ((xargs_state == 1)) && [[ "${word}" == -?* ]]; then
    name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
    case "${word}" in
    --)
      xargs_state=2
      continue
      ;;
    --arg-file | --delimiter | --max-args | --max-procs | --max-chars | --process-slot-var)
      xargs_optarg=1
      continue
      ;;
    --arg-file=* | --delimiter=* | --max-args=* | --max-procs=* | --max-chars=* | \
      --process-slot-var=* | --eof=* | --replace=* | --max-lines=* | --null | \
      --open-tty | --interactive | --no-run-if-empty | --verbose | --exit | --show-limits)
      continue
      ;;
    --*) ;;
    *) xargs_short_options "${word}" && continue ;;
    esac
    xargs_state=0 # not an option this reads: every later word may be the name
  fi
  if ((xargs_state)); then
    xargs_state=0
    xargs_command_idx=${idx}
  fi
  if ((after_time)) && [[ "${word}" == '-p' || "${word}" == '--' ]]; then
    continue # time's own option (review on arch-bootc#322); the name is still to come
  fi
  after_time=0
  # An assignment, in either of bash's two operators: `+=` appends, and
  # appending to an unset variable creates it, so it is not a narrower case of
  # `=`. The test reads the word with its quotes removed: bash reads
  # `'NAME'=value cmd` as a *command* named `NAME=value` rather than as an
  # assignment, while `env 'NAME'=value cmd` does set NAME, since env reads its
  # argv after the shell has removed the quotes. Calling both an assignment
  # over-refuses the first -- a command name no PATH entry answers to -- and
  # catches the second.
  if [[ "${word}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
    continue # an assignment; the name is still to come
  fi
  case "${word}" in
  time)
    after_time=1 # `time -p CMD`: the option is time's, not the name
    continue
    ;;
  '{' | '}' | '!' | if | then | else | elif | fi | do | done | while | until | coproc)
    continue # a keyword; the name is still to come
    ;;
  *) ;;
  esac
  if [[ "${wrapper_name}" == env ]] &&
    [[ "${raw_word}" =~ ^-[^-]*S || "${raw_word}" == --split-string* ]]; then
    refuse "${CMD_MSG}"
  fi
  # bash starts as a login shell when its zeroth argument begins with `-`,
  # which is what exec's -l puts there, and what exec -a and env -a
  # (--argv0) can set: `exec -l bash -n tests/run-tests.sh` and `exec -a
  # -bash bash -n ...` read ~/.bash_profile and print the line a syntax
  # error in it stands on, the read `bash -n -l` is refused for, with no
  # `-l` among bash's own words (review on aurora-zfs-simple#237). Marked
  # here, where the wrapper is known, and refused in front of a gated bash
  # below. Any exec option carrying an `l` or an `a` counts, whatever the
  # value: `exec -a bash` sets no dash, and refusing it costs a spelling
  # nobody needs.
  # Claude Code does not step over exec or env before it matches an allow
  # row, so these spellings prompt today; they are refused so that this
  # gate does not rest on that.
  if [[ "${wrapper_name}" == exec && "${raw_word}" =~ ^-[^-]*[al] ]] ||
    [[ "${wrapper_name}" == env && ("${raw_word}" =~ ^-[^-]*a || "${raw_word}" == --argv0*) ]]; then
    argv0_words[idx]=1
  fi
  name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
  # A wrapper, found by its last path component once the word is known to be
  # literal, cut at `\` as well as at `/`, which is where Claude Code's
  # matcher cuts it (`replace(/^.*[\\/]/,"")`): the permission layer steps
  # over a wrapper written as any path and matches the allow row against
  # the words after it. Compared on the whole word, `git status;
  # /usr/bin/xargs git diff` read `/usr/bin/xargs` as the name, so the git
  # behind it reached no scan (review on zfs-kinoite-complex#235). The
  # component is read from the word bash hands on, from the word with its
  # quotes removed but its backslashes kept, and from the word as typed,
  # since `'./shim\nohup'` is a file named `shim\nohup` to bash and `nohup`
  # to the matcher, and an unquoted `/usr/bin\timeout` is `/usr/bintimeout`
  # to bash -- not found, though bash has already opened any redirection
  # target -- and `timeout` to the matcher (review on sensi#259).
  #
  # Only a word typed exactly as the bare name, `/usr/bin/NAME` or
  # `/bin/NAME` is stepped over, compared as typed so no quote or backslash
  # can make bash and the matcher read it apart. Any other path to a wrapper
  # -- `./shim/nohup`, `/tmp/timeout`, an agent-made file -- runs the file
  # at that path, which can be anything, while the allow rule approved only
  # the words after it, so it is refused outright (review on
  # atomic-image-builder#438); a quoted or escaped bare name (`'nohup'`,
  # `\nohup`) is refused with it, which costs nothing a session needs.
  # Checked after the literal test, so `$D/env` is still refused as a name
  # built at runtime.
  wrapper_base=''
  for wrapper_spelling in "${word}" "${raw_word//[\'\"]/}" "${raw_word}"; do
    is_wrapper "${wrapper_spelling##*[/\\]}" && wrapper_base="${wrapper_spelling##*[/\\]}"
  done
  if [[ -n "${wrapper_base}" ]]; then
    case "${raw_word}" in
    "${wrapper_base}" | "/usr/bin/${wrapper_base}" | "/bin/${wrapper_base}") ;;
    *) refuse "${WRAPPER_PATH_MSG}" ;;
    esac
    after_wrapper=1
    wrapper_name="${wrapper_base}"
    [[ "${wrapper_name}" == timeout ]] && wrapper_positional_pending=1
    if [[ "${wrapper_name}" == xargs ]]; then
      xargs_wrappers[idx]=1
      xargs_state=1
    fi
    continue
  fi
  if [[ "${word}" == */git ]]; then
    words[idx]=git
    raw_words[idx]=git
  fi
  # A dash-prefixed word after a wrapper is the wrapper's own option, not the
  # name of the command it runs. It is still held to the literal-name test
  # above -- that is what refuses `command -- $G` -- but it must not be taken
  # for the name, or the environment scan below stops looking for an
  # assignment one word early: `env -i GIT_EXTERNAL_DIFF=/tmp/evil git diff
  # HEAD` read `-i` as the name, so the assignment after it was a word of a
  # command that had already been named, and the refusal never fired. Where
  # that option is documented to take a separate value word of its own, that
  # value word is consumed the same way, via wrapper_value_pending, so it is
  # never read as the name either.
  if ((after_wrapper)) && [[ "${word}" == -* ]]; then
    wrapper_option_takes_value "${wrapper_name}" "${word}" && wrapper_value_pending=1
    continue
  fi
  command_names[idx]=1
  # The command xargs runs, when it is not a wrapper, keyword or assignment
  # (each of which went on above): the words after it are its arguments.
  ((idx == xargs_command_idx)) && after_wrapper=0
  ((after_wrapper)) || command_word_pending=0
done

# Whether the shell opens a redirection's target for writing. Every operator
# with a `>` in it does -- `>`, `>>`, `>|`, `&>`, `&>>`, and `<>`, which
# opens read-write and creates the file -- and so does `>&` when its target
# is a path: `>&file` is bash's older spelling of `&>file`. The exception is
# a target that names a descriptor: `>&1`, `2>&1` and `>&-` duplicate or
# close a descriptor and touch no path. `2>&file` is an "ambiguous redirect"
# error in bash and writes nothing, and is refused anyway -- the rule is the
# operator and the target's shape, not a model of bash's error paths. `<`,
# `<<`, `<<<` and `<&` open nothing for writing.
redirection_writes_a_path() {
  local op="$1" target="$2"
  [[ "${op}" == *'>'* ]] || return 1
  if [[ "${op}" == *'&' ]]; then
    [[ "${target}" =~ ^[0-9]+$ || "${target}" == '-' ]] && return 1
  fi
  return 0
}

# From a `git` word to the end of *that command*: the scope opens at `git`
# and closes at the next separator, so `git diff HEAD | jq '{a,b}'` leaves
# the jq program alone while `git log -1; git diff {a,b}` and `echo x | git
# diff {a,b}` are each refused at their own `git`. A redirection does not
# close it: `git log 2>&1 --outpu{t,t}=FILE` is one command, and the brace
# in it is git's. This is narrower than the `in_git` latch below, which holds
# to the end of the string, and can be: that latch guards the `--output`
# test, which is kept wide on purpose. The word is compared with
# its quotes removed so `'git'` opens the scope as `git` does; a `git`
# assembled from an expansion (`g{i,i}t`) matches no allow rule and prompts on
# its own.
#
# The same scope decides the output redirections: bash attaches a redirection
# to the simple command it is written in, so `git diff HEAD >cosign.pub` is
# git's and `echo x >out; git diff HEAD` and `git diff HEAD | jq . >out` are
# not -- those are decided by whatever rule covers `echo` and `jq`, the way
# `git diff HEAD | tee cosign.pub` already is. Bash also lets a redirection
# *precede* the command name -- `>cosign.pub git diff HEAD` is the same
# command as `git diff HEAD >cosign.pub`, and `git status; >cosign.pub git
# diff HEAD` truncated the trust anchor while a scope that opened at the
# `git` word had not yet seen the target (review on #317). So a writing
# target seen before any `git` word of its command is carried until the
# command's name is known, and refused if that name turns out to be git --
# a `git` the command-name scan above marked as naming its command, so
# `>out printf %s git` stays printf's own. A
# brace found anywhere in the string wins the refusal: an expanding brace
# means the words here are not the words git would receive, and that message
# is the one to act on first.
#
# The same scope refuses a word that begins with an unquoted `~`: bash
# expands it to `$HOME` before git runs, and the operand scan below, which
# reads the quote-stripped spelling, resolved the literal `~` inside the
# checkout and let `git diff -- ~/.aws/credentials ~/.bashrc` through. The
# test is on the word as typed, so `'~/x'` and `\~/x`, which bash leaves
# alone, are not refused. A redirection's target is not a word of git's and
# is decided here by the redirection rule instead.
raw_in_git=0
writing_redirect=0
prefix_writing_redirect=0 # a writing target seen before this command's git word
scope_stack=()            # the outer command's state, while a `$(...)` is being read
for ((idx = 0; idx < ${#raw_words[@]}; idx++)); do
  if [[ "${kinds[idx]}" == sep ]]; then
    # A `$(...)` substitution is a nested command; the scope of the command
    # around it, and a writing target waiting for that command's name, are
    # saved at the `$(` and restored at its `)` rather than reset.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]]; then
      scope_stack+=("${raw_in_git} ${prefix_writing_redirect}")
    elif [[ "${words[idx]}" == '$)' ]] && ((${#scope_stack[@]})); then
      read -r raw_in_git prefix_writing_redirect <<<"${scope_stack[-1]}"
      unset 'scope_stack[-1]'
      continue
    fi
    raw_in_git=0
    prefix_writing_redirect=0
    continue
  fi
  raw_word="${raw_words[idx]}"
  if ((raw_in_git)); then
    if brace_would_expand "${raw_word}" ||
      [[ "${raw_word}" == '<(' || "${raw_word}" == '>(' ]]; then
      refuse "${BRACE_MSG}"
    fi
    if [[ "${kinds[idx]}" == word && "${raw_word}" == '~'* ]]; then
      refuse "${TILDE_MSG}"
    fi
    # The same rewrite by another route: a glob is one word here and however
    # many files match at git, so `git diff ./cosign.*` is one operand to the
    # scan below and two to git, which is the plain-file read. A redirection's
    # target is not a word git receives and is decided by the redirection
    # rules instead.
    if [[ "${kinds[idx]}" == word ]] && ((${globs[idx]:-0})); then
      refuse "${GLOB_MSG}"
    fi
    if [[ "${kinds[idx]}" == target ]] &&
      redirection_writes_a_path "${redirects[idx]}" "${words[idx]}"; then
      writing_redirect=1
    fi
  elif [[ "${kinds[idx]}" == target ]] &&
    redirection_writes_a_path "${redirects[idx]}" "${words[idx]}"; then
    prefix_writing_redirect=1
  fi
  if [[ "${kinds[idx]}" == word && "${words[idx]}" == "git" ]]; then
    raw_in_git=1
    ((prefix_writing_redirect)) && ((${command_names[idx]:-0})) && writing_redirect=1
  fi
done
((writing_redirect)) && refuse "${REDIRECT_MSG}"

# The whole string with quoting removed, for the one test that is a substring
# match rather than a word: the shell removes quotes and backslashes on the
# way to git, so `--no-'index'` and `--no-\index` both reach it as
# `--no-index`.
normalized="${command_string//[\'\"\\]/}"

case "${normalized}" in
*--no-index*) refuse "${DIFF_MSG}" ;;
*) ;;
esac

# Git's path_inside_repo, which decides on the *spelling* rather than on where
# the path ends up. That distinction is the whole of this function, and folding
# `..` before the comparison gets it backwards: `git diff --
# ../<checkout>/cosign.key -` names a file inside this repository by a route
# that leaves it and comes back, git's test calls that outside and enters the
# plain-file mode, and a gate that resolved the path first saw a tidy in-tree
# path and allowed it -- reading a denied path with two operands that both look
# local. So every `..` component and the stdin operand `-` count as outside
# here, before anything is normalized. This also refuses some ordinary
# pathspecs (e.g. tests/../AGENTS.md); use a direct inside spelling instead.
# A leading `~` counts as outside too: to bash that is a home directory, never
# a path under this checkout, and resolving the literal put
# `~/.aws/credentials` inside the tree.
# Then both lexical and symlink-resolved containment are required: -s alone
# does not follow symlinks, while resolution alone admits an outside alias
# back inside. Anything this cannot decide -- no working tree here, no realpath
# on the host -- counts as outside, so the gate refuses rather than guesses.
path_inside_worktree() {
  local candidate toplevel
  [[ "$1" == "-" || "$1" == '~'* || "/$1/" == */../* ]] && return 1
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  candidate="$(realpath -m -s -- "$1" 2>/dev/null)" || return 1
  [[ "${candidate}" == "${toplevel}" || "${candidate}" == "${toplevel}"/* ]] || return 1
  candidate="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  [[ "${candidate}" == "${toplevel}" || "${candidate}" == "${toplevel}"/* ]]
}

# The shapes `.claude/settings.json` denies the Read tool. Inside the working
# tree is not enough on its own: `cosign.key` and a `.env` live there, and they
# are the two files those rules exist for.
denied_read_shape() {
  case "${1##*/}" in
  cosign.key | .env | .env.* | *.pem | *.p12 | id_rsa | id_ed25519) return 0 ;;
  *) ;;
  esac
  return 1
}

# Whether bash would rewrite this word, as typed, into something other than
# the quote-stripped spelling the operand scan checks: an unquoted `~` at the
# start (tilde expansion to $HOME), an unquoted `*`, `?` or `[` anywhere
# (pathname expansion), a `$` or backtick anywhere (any expansion; a quoted
# `$` inside double quotes still expands, and a single-quoted one is refused
# as the price of not modelling that), a brace bash would expand, or a process
# substitution. Quote state is tracked so that `'tests/*.sh'` is the literal
# word bash would pass; a backslash escapes the next character.
word_bash_would_rewrite() {
  local raw="$1" quote='' escaped=0 i ch
  [[ "${raw}" == *'$'* || "${raw}" == *'`'* ]] && return 0
  [[ "${raw}" == '<(' || "${raw}" == '>(' ]] && return 0
  brace_would_expand "${raw}" && return 0
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if ((escaped)); then
      escaped=0
      continue
    fi
    if [[ -n "${quote}" ]]; then
      if [[ "${ch}" == "${quote}" ]]; then
        quote=''
      elif [[ "${quote}" == '"' && "${ch}" == $'\\' ]]; then
        escaped=1
      fi
      continue
    fi
    case "${ch}" in
    $'\\') escaped=1 ;;
    "'" | '"') quote="${ch}" ;;
    '~') ((i == 0)) && return 0 ;;
    '*' | '?' | '[') return 0 ;;
    *) ;;
    esac
  done
  return 1
}

# Whether a `<` redirection would feed a shellcheck invocation a file the
# operand scan would have refused as an operand. ShellCheck reads standard
# input for a `-` operand and prints the source line above every diagnostic,
# so `shellcheck - < .env` is the same read as `shellcheck ./.env` with the
# path moved behind the operator, where the operand scan does not look
# (issue #323). The three tests are that scan's own, in its order: a word bash
# would rewrite is not the path bash would open, and the rest must resolve
# inside the working tree and carry none of the deny shapes.
#
# Two targets are not paths this has anything to say about. `/dev/null` prints
# nothing back and is how a session says "no stdin". A process substitution
# (`< <(...)`) runs a command of its own, which `GATED_SUBST_MSG` refuses with
# the message that names it; the word here is the `<(` opening, not a file.
#
# Only a bare `<` reaches this. `<<` takes a here-document delimiter and
# `<<<` a here-string's content -- neither names a file, and neither can be
# made to without a substitution, which is refused before this runs -- while
# `<&` duplicates a descriptor and `<>` opens for writing, which
# `redirection_writes_a_path` already decides.
reading_target_refused() {
  local raw="$1" target="$2"
  [[ "${target}" == '/dev/null' ]] && return 1
  [[ "${raw}" == '<(' || "${raw}" == '>(' ]] && return 1
  word_bash_would_rewrite "${raw}" && return 0
  path_inside_worktree "${target}" || return 0
  denied_read_shape "${target}"
}

# The same write, reached by the allow-listed commands that are not git.
#
# Everything above is scoped to a `git` word (and the operand tests to a
# `shellcheck` one), and the write primitive is not git's alone.
# `.claude/settings.json` allows six other command prefixes with a trailing
# `*` -- "this command with any arguments" -- and an output redirection is
# part of the string that rule matches, so the shell opens the target before
# the command runs and nothing prompts: `shellcheck tests/run-tests.sh
# >cosign.pub` truncates the trust anchor before a line is linted, and the
# file stays empty when shellcheck then fails; `podman images
# >.claude/settings.json` overwrites the file that holds these rules. The
# `Read(...)` deny rows gate the Read tool and say nothing about it, exactly
# as they say nothing about `git diff HEAD >cosign.pub`.
#
# One of those commands also carries a flag that undoes its read-only mode.
# `bash -n` is allowed because `-n` reads a script without running it, and
# bash lets a later `+n` (or `+o noexec`) on the same command line turn the
# option back off, so `bash -n +n -c 'cat ./cosign.key'` ran the command --
# the allow rule matches the `bash -n` prefix and the `+n` is the rest of the
# string. A word beginning with `+` in a `bash -n` invocation is refused, and
# so is a brace, a glob, a `$` or a backtick in one of its words, because
# `{+,+}n` is the rebuild that reopened the git half of this gate twice and
# `?n` beside a file named `+n` is the same rebuild by pathname expansion.
#
# And `-n` stops bash running the script, not reading it out (issue #345).
# `bash -n -v ./cosign.key` printed the key: `-v` prints every line bash
# reads, and nothing about `-n` stops it. So the options that print or copy
# what bash reads are refused in a `bash -n` invocation, read the way bash
# reads its own, and the script it opens -- an operand, or its stdin when
# none is named -- is held to the shellcheck operand test. The option scan
# at the end of the loop below says which options and why.
#
# The patterns below are the allow rows ending in `*` other than git's,
# spelled as the settings file spells them, because the two shapes match
# differently: `shellcheck *` and `findmnt *` name the command and then
# anything, while `podman images*` and `df -T*` also match a longer last
# word, so `df -Th >cosign.pub` is allowed on the `df -T*` row and has to be
# gated on it. The git rows are covered by the scan above, which refuses an
# output redirection in every git invocation, `git status` and `git ls-files`
# included. The exact rows (`just test`, `./tests/run-tests.sh`, the virsh
# inventories) carry no `*`, so a redirection makes the string match no row
# and Claude Code prompts. tests/test-gate-git-diff.sh derives this list from
# the settings file rather than restating it, so a rule added there fails
# that suite until it is listed here.
GATED_PREFIXES=(
  'shellcheck *'
  'bash -n *'
  'podman images*'
  'podman ps*'
  'findmnt *'
  'df -T*'
)

# Whether the words of a command so far, space-joined, are what one of the
# rows above matches: `shellcheck` alone for `shellcheck *` (the rest of the
# string may be the redirection), and any continuation of `df -T` for
# `df -T*`.
command_is_gated() {
  local joined="$1" rule prefix
  for rule in "${GATED_PREFIXES[@]}"; do
    prefix="${rule%\*}"
    if [[ "${rule}" == *' *' ]]; then
      [[ "${joined}" == "${prefix% }" ]] && return 0
    else
      [[ "${joined}" == "${prefix}"* ]] && return 0
    fi
  done
  return 1
}

# Whether the words so far can still grow into one of the prefixes above:
# `bash` can (`bash -n`), `-p` cannot. After a wrapper such as `command`
# every following word may be the name, and the wrapper's own options come
# first (`command -p bash -n +n -c ...`, review on arch-bootc#322), so a
# prefix that can no longer match is dropped when the next candidate name
# arrives rather than kept as a name that was never one.
prefix_could_match() {
  local joined="$1" rule
  for rule in "${GATED_PREFIXES[@]}"; do
    [[ "${rule}" == "${joined} "* ]] && return 0
  done
  return 1
}

# The command that just ended. Only two facts about it are kept -- whether its
# leading words matched one of the rows above, and whether a redirection in
# it opens a path -- because a redirection can be written before the name
# (`>cosign.pub shellcheck tests/run-tests.sh` is the same command as
# `shellcheck tests/run-tests.sh >cosign.pub`), so neither fact is complete
# until the command ends.
check_gated_command() {
  # `xargs` in front of a command this gate covers. Every test here reads the
  # words of the string, and xargs adds words the string does not hold: it
  # appends what it reads from standard input, or from the file `-a` names,
  # to the command it runs, so `printf '%s\n' /dev/null ./cosign.key | xargs
  # git diff` is the plain-file read with no operand after `git diff`, and
  # `xargs shellcheck <list.txt` lints whatever the list names. The allow
  # rows are no check on it: Claude Code 2.1.267 matches `xargs <row>`
  # against every allow row ending in `*`, so the string runs unprompted.
  # So xargs is refused outright here, wherever it stands among the wrappers
  # (`timeout 5 xargs git diff`, `nice xargs shellcheck`), rather than read
  # as one more wrapper to step over. It is decided on the command it runs:
  # the gated-prefix match, and a `git` word the command-name scan marked as
  # a possible name (`cmd_git_name`) rather than any `git` word, since that
  # scan reads xargs's own options and stops at the command after them, so
  # `git ls-files | xargs grep -l git` runs grep with `git` as its pattern
  # and is left alone. Where it cannot read an option, every later word may
  # be the name and is held to this test. xargs in front of a command no
  # allow rule covers (`git diff --name-only | xargs echo`) matches no allow
  # row, prompts on its own, and is left alone.
  ((cmd_xargs && (cmd_gated || cmd_git_name))) && refuse "${XARGS_MSG}"
  ((cmd_gated && cmd_writes)) && refuse "${GATED_REDIRECT_MSG}"
  # A shellcheck invocation has its own scan for this, with the message that
  # names the operand; that one is left to say it.
  ((cmd_gated && cmd_subst)) && { [[ "${cmd_prefix}" != shellcheck* ]] || ((cmd_subst == 2)); } && refuse "${GATED_SUBST_MSG}"
  # The read an input redirection reaches, which is a shellcheck or bash -n
  # invocation's alone: ShellCheck echoes the source line of what it is given
  # on stdin, bash -n reads its script from stdin when no file is named and
  # prints the line a syntax error stands on (issue #345), and the other
  # gated commands do not read a file from stdin at all. It comes after the
  # substitution test on purpose: a target built by one
  # (`shellcheck f <"$(printf x >cosign.pub)"`) is refused for the command it
  # runs, which is the message to act on first.
  ((cmd_gated && cmd_read)) && [[ "${cmd_prefix}" == shellcheck* ]] && refuse "${SHELLCHECK_STDIN_MSG}"
  # Git's half of the same read: `--stdin` on log, show and diff takes
  # revisions from standard input and names the first line that is not one in
  # its error, so `git log --stdin <.env` prints that line back. Decided on a
  # `git` word that stands where the name may be (`cmd_git_name`), the way the
  # xargs test is, so `grep git <notes.txt` is not read as a git invocation.
  ((cmd_git_name && cmd_read)) && refuse "${GIT_STDIN_MSG}"
  ((cmd_gated && cmd_read && cmd_bash)) && refuse "${BASH_READ_MSG}"
  ((cmd_gated && cmd_heredoc)) && refuse "${GATED_HEREDOC_MSG}"
  # A `SHELLCHECK_OPTS=` assignment has a refusal of its own, which names what
  # the linter reads out of it; that one is left to say it.
  ((cmd_gated && cmd_assign)) && [[ "${cmd_prefix}" != shellcheck* || "${cmd_assign_name}" != SHELLCHECK_OPTS ]] && refuse "${GATED_ENV_MSG}"
  # Git is held to the same rule. It was exempt until issue #329, on the
  # reading that a git invocation is decided by the operand scan above; that
  # scan reads words, and an assignment is not one. Git's environment carries
  # both primitives this gate refuses elsewhere: `GIT_EXTERNAL_DIFF=prog git
  # diff HEAD~1` runs `prog` once per changed path, `GIT_CONFIG_COUNT=1
  # GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=prog` reaches the same
  # driver under another name, and `PATH=dir git diff HEAD~1` picks a
  # different git altogether -- each of them an unprompted string the allow
  # rows match on their `git diff` prefix.
  ((cmd_git && cmd_assign)) && refuse "${GATED_ENV_MSG}"
  return 0
}

reset_command() {
  cmd_prefix=''
  cmd_writes=0
  cmd_read=0
  cmd_subst=0
  cmd_heredoc=0
  cmd_assign=0
  cmd_assign_name=''
  cmd_bash=0
  cmd_named=0
  cmd_gated=0
  cmd_git=0
  cmd_git_name=0
  cmd_name=''
  cmd_export_no_add=0
  cmd_xargs=0
  bash_options=0
  bash_optvals=''
  cmd_argv0=0
}

# The words of a command from its *name* onward: a leading assignment
# (`FOO=bar shellcheck ...`) is not part of the prefix an allow rule matches,
# and neither is a redirection's target, which is the shell's word rather
# than the command's. `command_names` above marks the name, and every word
# after it belongs to the same command until a separator.
#
# The export family is decided here too, because it is the same question --
# what reaches a gated command from outside the words an allow rule matches --
# and this is the loop that knows which commands those are. It cannot be a
# per-command fact, though: bash applies an export to every *later* command
# instead of to one, so the gated command carries no assignment at all. It is
# a whole-string latch, and deliberately an unordered one. `git status
# --short; export GIT_EXTERNAL_DIFF=/tmp/evil` runs nothing gated after the
# export, matches the allow row on its `git status` prefix, and is the same
# reach on the *next* Bash call, because the tool's shell outlives one call.
# Refusing only what an export precedes would leave that spelling, which is
# the residual the sibling repositories state rather than close
# (aurora-zfs-simple#219, sensi#249, goodreads-mcp#116).
cmd_prefix='' # the words so far, space-joined, while a prefix is still possible
cmd_writes=0  # a redirection in this command opens a path for writing
cmd_read=0    # a `<` in this command opens a path the operand test refuses
cmd_subst=0   # a substitution stands in this command, or in a target of it
cmd_heredoc=0 # this command reads a here-document bash expands
cmd_assign=0  # an assignment stands before this command's name
cmd_assign_name='' # the variable that assignment sets
cmd_bash=0    # its name is bash, so the +n and expansion rules apply once gated
cmd_named=0   # the name has been seen; every later word belongs to it
cmd_gated=0   # its leading words matched one of GATED_PREFIXES
cmd_git=0     # a literal `git` word is one of its words
cmd_git_name=0 # a literal `git` word stands where this command's name may be
cmd_xargs=0   # `xargs` stands among its wrappers, so its operands are not all here
bash_options=0 # a gated bash is still reading option words, as bash itself does
bash_optvals='' # one letter per -o/-O still waiting for its value, in order
cmd_argv0=0   # an exec/env option before the name set bash's zeroth argument
cmd_name=''   # the word that names it, once seen
cmd_export_no_add=0 # this command's export saw -n or bare -p, so it adds nothing
cmd_stack=()  # the outer command's state, while a `$(...)` is being read
saw_gated=0   # some command of this string is one this gate covers
saw_export=0  # some command of this string exports into every later one
reset_command
for ((idx = 0; idx < ${#words[@]}; idx++)); do
  case "${kinds[idx]}" in
  sep)
    # A `$(...)` or a backtick inside a gated command runs the command
    # inside it as part of the approved string, with no rule on that inner
    # command (`df -T $(touch cosign.pub)`, review on arch-bootc#322), the
    # way a process substitution does; a gated bash invocation says so in
    # its own words, since there the substitution also rebuilds `+n`.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if ((cmd_gated)) && [[ "${words[idx]}" == '$(' || "${words[idx]}" == *'`'* ]]; then
      ((cmd_bash)) && refuse "${BASH_EXPAND_MSG}"
      # A shellcheck invocation has its own scan for this, whose message
      # names the operand; that one is left to say it.
      [[ "${cmd_prefix}" == shellcheck* ]] || refuse "${GATED_SUBST_MSG}"
    fi
    # A `$(...)` substitution is a nested command: it is decided on its own,
    # and the command around it -- including a redirection of its own already
    # seen -- resumes at the `)` rather than starting over, so
    # `shellcheck $(git ls-files '*.sh') >cosign.pub` is still that command's
    # write.
    # A process substitution's body is split as a command of its own behind
    # a `(` separator; the command around it is saved there and restored at
    # the `)`, like a `$(...)`, so `>(cat >cosign.pub) df -T` still reaches
    # its name with the substitution remembered.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]] ||
      { [[ "${words[idx]}" == '(' ]] && ((idx > 0)) && [[ "${kinds[idx - 1]}" != sep ]] &&
        [[ "${words[idx - 1]}" == '<(' || "${words[idx - 1]}" == '>(' ]]; }; then
      # `cmd_name` carries no space, and `cmd_prefix` is read last, so the two
      # come back apart with no separator of their own. Both are empty until
      # the name is seen, and `read` fills the trailing fields with nothing.
      cmd_stack+=("${cmd_writes} ${cmd_read} ${cmd_subst} ${cmd_heredoc} ${cmd_assign} ${cmd_bash} ${cmd_named} ${cmd_gated} ${cmd_git} ${cmd_git_name} ${cmd_xargs} ${cmd_export_no_add} ${cmd_name} ${cmd_prefix}")
      reset_command
      continue
    fi
    if [[ "${words[idx]}" == '$)' || "${words[idx]}" == ')' ]] && ((${#cmd_stack[@]})); then
      check_gated_command
      read -r cmd_writes cmd_read cmd_subst cmd_heredoc cmd_assign cmd_bash cmd_named cmd_gated cmd_git cmd_git_name cmd_xargs cmd_export_no_add cmd_name cmd_prefix <<<"${cmd_stack[-1]}"
      unset 'cmd_stack[-1]'
      # The command that resumes here contains a substitution, whether or
      # not its name has been seen yet (`$(touch cosign.pub) df -T`).
      ((cmd_subst)) || cmd_subst=1
      continue
    fi
    check_gated_command
    reset_command
    continue
    ;;
  target)
    redirection_writes_a_path "${redirects[idx]}" "${words[idx]}" && cmd_writes=1
    # The read half, for the one gated command that echoes what it is given on
    # stdin: `shellcheck - < .env` prints the file back and the operand scan
    # sees only the `-` (issue #323). Recorded here rather than refused here,
    # because a redirection can be written before the name
    # (`< .env shellcheck -` is the same command), so which command it belongs
    # to is not known until that command ends.
    if [[ "${redirects[idx]}" == '<' ]] &&
      reading_target_refused "${raw_words[idx]}" "${words[idx]}"; then
      cmd_read=1
    fi
    # `df -T < <(printf x >cosign.pub)`: the substitution is a target, and
    # its body still runs (review on arch-bootc#322). So does one quoted
    # into the target of an input redirection or a here-string
    # (`gh pr list <"$(printf x >cosign.pub)"`, review on
    # aurora-zfs-simple#211): bash expands the target before the command.
    # (Recorded as 2: a shellcheck invocation's own scan covers its operand
    # words, never its targets, so the exemption below does not apply.)
    [[ "${words[idx]}" == '<(' || "${words[idx]}" == '>(' ]] && cmd_subst=2
    [[ "${raw_words[idx]}" == *'$'* || "${raw_words[idx]}" == *'`'* ]] && cmd_subst=2
    # A here-document with an unquoted delimiter is expanded before the
    # command runs, and its body lies on the lines after this one, which
    # the scan reads as commands of their own: `df -T <<EOF` followed by a
    # `$(printf x >cosign.pub)` line writes the file (review on
    # arch-bootc#322). One with a quoted delimiter (`<<'EOF'`) is literal.
    if [[ "${redirects[idx]}" == '<<' && "${raw_words[idx]}" != *[\'\"\\]* ]]; then
      cmd_heredoc=1
    fi
    continue
    ;;
  *) ;;
  esac
  # A `<(` or `>(` is the substitution's opening, not a word of the prefix:
  # it is remembered for the command and its body follows behind a `(`.
  if [[ "${words[idx]}" == '<(' || "${words[idx]}" == '>(' ]]; then
    cmd_subst=1
    continue
  fi
  # Which commands the environment rule covers is a literal `git` word
  # anywhere in this command, rather than the word that names it: the scans
  # above open their git scope the same way, and reading the name alone let a
  # wrapper's own option move the name in front of the assignment
  # (`env -i GIT_EXTERNAL_DIFF=/tmp/evil git diff HEAD`). The command-name
  # scan above rewrote a path spelling (`/usr/bin/git`) to `git`, so this one
  # test covers both. `FOO=bar echo git` is the over-refusal that buys it.
  [[ "${words[idx]}" == git ]] && cmd_git=1
  [[ "${words[idx]}" == git ]] && ((${command_names[idx]:-0})) && cmd_git_name=1
  # A wrapper `xargs` is not the name and is stepped over below like the
  # others; that it stood here is what `check_gated_command` refuses on.
  ((${xargs_wrappers[idx]:-0})) && cmd_xargs=1
  # An assignment before the name is an environment the command runs under,
  # and for these commands that is a way in: `PYTEST_ADDOPTS`, `PYTHONPATH`,
  # `GH_HOST`, `LD_PRELOAD` each change what the command does or where it
  # sends what it has (review on sensi#244). A git invocation is refused it
  # too (issue #329): `GIT_EXTERNAL_DIFF` names a program git runs per changed
  # path, and the operand scan above reads words, which an assignment is not.
  # The word is read with its quotes removed, for the reason the command-name
  # scan gives: `env 'NAME'=value cmd` sets NAME although bash alone would
  # read that word as a command name (issue #333).
  if ((cmd_named == 0)) && [[ "${words[idx]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?= ]]; then
    cmd_assign=1
    cmd_assign_name="${BASH_REMATCH[1]}"
    continue
  fi
  # An exec or env option that sets the zeroth argument, before the name: a
  # dash there makes bash a login shell (see `argv0_words` above).
  ((${argv0_words[idx]:-0})) && ((cmd_gated == 0)) && cmd_argv0=1
  ((cmd_named)) || ((${command_names[idx]:-0})) || continue
  if ((cmd_named == 0)); then
    cmd_named=1
    cmd_name="${words[idx]}"
  else
    case "${cmd_name}" in
    declare | typeset | local | readonly)
      [[ "${words[idx]}" == -*x* ]] && saw_export=1
      ;;
    # The export family, which no per-command scan can find: bash applies an
    # export to every *later* command of the string, so the gated command
    # carries no assignment at all. Only the latch is set here; the refusal
    # is at the end of this file, where the whole string has been read.
    #
    # `-n` unexports rather than exports, and `-p` alone lists what is
    # already exported -- neither adds anything a later command inherits, so
    # `export -p` and the remediation `export -n GIT_EXTERNAL_DIFF` must not
    # arm the latch (review on arch-bootc#334). `-n` is read for the whole
    # command rather than only in isolation, since it can precede a name
    # (`export -n FOO`) and a name after it is still being removed, not
    # added. `-f` (functions) still arms: `export -f name` still puts
    # `BASH_FUNC_name%%` in the environment, which is exported state the
    # same as a variable. A bare `export` with no words at all never reaches
    # this branch at all -- it only runs for a word *after* the name -- so
    # it arms nothing, which matches bash: no names, nothing exported.
    export)
      case "${words[idx]}" in
      -n | -*n*) cmd_export_no_add=1 ;;
      -p) ;;
      *) ((cmd_export_no_add)) || saw_export=1 ;;
      esac
      ;;
    set)
      [[ "${words[idx]}" == -*a* || "${words[idx]}" == allexport ]] && saw_export=1
      ;;
    *) ;;
    esac
  fi
  if ((cmd_gated == 0)); then
    # The words so far cannot grow into a gated prefix and this word may
    # still be the name (a wrapper's option came first): start over here.
    if [[ -n "${cmd_prefix}" ]] && ((${command_names[idx]:-0})) && ! prefix_could_match "${cmd_prefix}"; then
      cmd_prefix=''
      cmd_bash=0
    fi
    [[ -z "${cmd_prefix}" && "${words[idx]}" == "bash" ]] && cmd_bash=1
    cmd_prefix="${cmd_prefix:+${cmd_prefix} }${words[idx]}"
    command_is_gated "${cmd_prefix}" && cmd_gated=1
    # `bash -nv ./cosign.key` is `bash -n -v` to bash. Claude Code's
    # documented matcher keeps the space after `-n` in the allow row, so that
    # spelling prompts today; it is gated here anyway, so this gate does not
    # rest on where the matcher draws a word boundary. A first option word
    # that begins `-n` completes the prefix, and the option scan at the end
    # of this loop reads the rest of it; the refusal blocks a spelling a
    # syntax check never needs.
    ((cmd_bash)) && [[ "${cmd_prefix}" == 'bash -n'?* ]] && cmd_gated=1
    ((cmd_bash && cmd_gated)) && bash_options=1
    ((cmd_bash && cmd_gated && cmd_argv0)) && refuse "${BASH_ECHO_MSG}"
  fi
  # Some command of this string is one this gate covers, which is what makes
  # an export anywhere in it worth refusing. A string that runs nothing gated
  # is left alone: it matches no allow rule and prompts on its own, the same
  # line `GATED_REDIRECT_MSG` draws for a redirection on an unlisted command.
  ((cmd_git || cmd_gated)) && saw_gated=1
  # A substitution or an expansion quoted into a word (`df -T "$(printf x
  # >cosign.pub)"`, `podman images $X`) is one the split above never opened,
  # and bash performs it all the same (review on arch-bootc#322).
  if ((cmd_gated)) && [[ "${raw_words[idx]}" == *'$'* || "${raw_words[idx]}" == *'`'* ]]; then
    ((cmd_subst)) || cmd_subst=1
  fi
  ((cmd_bash && cmd_gated)) || continue
  [[ "${words[idx]}" == '+'* ]] && refuse "${BASH_NOEXEC_MSG}"
  # A glob is the third rebuild: with a file named `+n` in the working
  # directory, `?n` and `[+]n` reach bash as `+n` (review on
  # aurora-zfs-simple#211), so the rewrite test the shellcheck operands are
  # held to applies here as well.
  if brace_would_expand "${raw_words[idx]}" || [[ "${raw_words[idx]}" == *'$'* ]] ||
    word_bash_would_rewrite "${raw_words[idx]}"; then
    refuse "${BASH_EXPAND_MSG}"
  fi
  # What the inner bash reads and prints, decided the way bash reads its own
  # command line (issue #345). `-n` stops bash running the script, not
  # printing it: `-v` (`-o verbose`) prints every line bash reads, `-D`
  # every `$"..."` string in it, `-o history` and `-i` copy every line into
  # ~/.bash_history when bash exits, and `-i` and `-l` read ~/.bashrc and
  # the login profiles, whose syntax errors print a line of them. `-x` (`-o
  # xtrace`) prints what bash runs, which under `-n` is nothing; it goes with
  # the rest because a syntax check has no use for it. Every other option
  # letter, `-o` name and `-O` name was run under `-n` (bash 5.3) against a
  # script holding a marker, and put none of it in the output or in HOME.
  #
  # bash's own parser (shell.c, parse_shell_options) takes a word beginning
  # with `-` as options until the first word that does not, or a lone `-` or
  # `--`, which it consumes. Each letter of such a word is an option of its
  # own, so `-nv` is `-n -v`, and each `o` or `O` among them takes the next
  # unread word as its value, in order, so `-no verbose` and `-oo noexec
  # verbose` both turn verbose on. A `--word` there is not a long option --
  # bash reads those only before the first short one, and the allow row puts
  # `-n` first -- so bash rejects it and exits; one carrying a refused letter
  # (`--verbose`) is refused here all the same. The first word that is not an
  # option, and every word after it, is the script (or the `-c` string) and
  # its arguments, held to the shellcheck operand test: bash prints the line
  # a syntax error stands on, so `bash -n .env` printed a `NAME=value` line
  # whose value held a `(`.
  if [[ -n "${bash_optvals}" ]]; then
    if [[ "${bash_optvals:0:1}" == o ]]; then
      case "${words[idx]}" in
      verbose | xtrace | history) refuse "${BASH_ECHO_MSG}" ;;
      *) ;;
      esac
    fi
    bash_optvals="${bash_optvals:1}"
  elif ((bash_options)) && [[ "${words[idx]}" == - || "${words[idx]}" == -- ]]; then
    bash_options=0
  elif ((bash_options)) && [[ "${words[idx]}" == -* ]]; then
    [[ "${words[idx]}" == -*[vxilD]* ]] && refuse "${BASH_ECHO_MSG}"
    bash_optvals+="${words[idx]//[!oO]/}"
  else
    bash_options=0
    if ! path_inside_worktree "${words[idx]}" || denied_read_shape "${words[idx]}"; then
      refuse "${BASH_READ_MSG}"
    fi
  fi
done
check_gated_command

# Every test below reads a word as typed, and bash rewrites the words before
# git receives them. `$(...)`, `${x}`, `$x` and a backtick each supply words
# the operand scan never counted, so `git diff $(echo /dev/null) ./cosign.key`
# is one operand here and two at git -- one short of the refusal -- and
# `$'\x74'` is the letter t, so `--outpu$'\x74'=FILE` matches neither
# `--output` nor `--output=*` here and arrives at git as `--output=FILE`. The
# brace scan above catches a `${VAR}` and nothing else of this.
#
# They are refused rather than expanded, for the reason the brace scan gives:
# correct expansion means reimplementing bash in a hook -- nesting, quoting,
# word splitting on $IFS -- and a half-right expansion is a gate that
# disagrees with the shell in some other direction. A refusal cannot be
# half-right, and a git argument built at runtime was already outside what
# this hook can vouch for, so refusing it turns a silent pass into a visible
# refusal. Neither character has a literal form git relies on, the way
# `HEAD@{1}` relies on a brace, so unlike the brace test this one is every
# `$` and every backtick.
#
# The `$` half is scoped like the brace scan: to the words as typed of the
# command that starts at a `git` word and ends at the next separator bash
# honours, so `git diff HEAD | awk '{print $1}'` and `jq '.[$x]' f | git
# diff` are left alone while `git log -1; git diff $x` is refused at its
# own `git`. The words as typed are the right ones here as well: the
# normalized split cuts a *quoted* operator inside an argument, and a scope
# that closed there would hand `git log --grep='a|b' --outpu$'\x74'=FILE -1`
# its `$` word unwatched. A `$` *before* the first `git` word is not checked
# and does not need to be: the allow rules in .claude/settings.json match a
# literal `git diff`/`git log` prefix, so an invocation assembled out of an
# expansion (`$GIT diff ...`) matches no allow rule and prompts on its own.
expand_in_git=0
for raw_word in "${raw_words[@]+"${raw_words[@]}"}"; do
  if [[ -z "${raw_word}" ]]; then
    expand_in_git=0
    continue
  fi
  if ((expand_in_git)) && [[ "${raw_word}" == *'$'* ]]; then
    refuse "${EXPAND_MSG}"
  fi
  [[ "${raw_word//[\'\"\\]/}" == "git" ]] && expand_in_git=1
done

# The backtick half cannot use that scope: an unquoted backtick is itself a
# separator to the split above, so it closes the scope it would have to be
# refused in and leaves no word behind. It is refused on the normalized
# words instead -- where it survives as a word of its own -- from the first
# `git` word to the end of the string, the latch `--output` uses below. The
# cost is a backtick in a quoted program piped from git, which no session
# needs; the alternative is `git diff \`echo /dev/null\` ./cosign.key`.
expand_in_git=0
for word in "${words[@]+"${words[@]}"}"; do
  if ((expand_in_git)) && [[ "${word}" == *'`'* ]]; then
    refuse "${EXPAND_MSG}"
  fi
  [[ "${word}" == "git" ]] && expand_in_git=1
done

# The same latch for a shellcheck invocation, for the same reason: the
# backtick that would supply its operand (`shellcheck \`echo /etc/shadow\``)
# closes the scope the operand scan below would refuse it in.
expand_in_shellcheck=0
for word in "${words[@]+"${words[@]}"}"; do
  if ((expand_in_shellcheck)) && [[ "${word}" == *'`'* ]]; then
    refuse "${SHELLCHECK_EXPAND_MSG}"
  fi
  [[ "${word}" == "shellcheck" ]] && expand_in_shellcheck=1
done

seen_git=0
in_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0
skip_git_option_value=0
in_shellcheck=0
skip_shellcheck_option_value=0

for ((idx = 0; idx < ${#words[@]}; idx++)); do
  word="${words[idx]}"
  kind="${kinds[idx]}"
  raw_word="${raw_words[idx]}"
  # ShellCheck reads file operands out of SHELLCHECK_OPTS as well as from the
  # command line, so `SHELLCHECK_OPTS=/etc/shadow shellcheck tests/run-tests.sh`
  # prints /etc/shadow with the operand scan below seeing only a tracked
  # script. The assignment is refused wherever it stands -- before the word,
  # after `export` or `env`, in another command of the same string -- since a
  # persistent shell carries it to the next call.
  if [[ "${kind}" != sep && "${word}" == SHELLCHECK_OPTS=* ]]; then
    refuse "${SHELLCHECK_EXPAND_MSG}"
  fi
  if [[ "${kind}" == sep ]]; then
    # Unlike `in_git`, `in_shellcheck` does not latch past a command
    # boundary. The refusal is about one command's own operands, so a path
    # belonging to some later command in the string is not its business.
    in_shellcheck=0
    skip_shellcheck_option_value=0
    # The operand scan starts over at each command boundary. `in_git` does not:
    # it latches for the rest of the command string, so an `--output` in any
    # later command of the same string -- `git log --grep=a|b
    # --output=cosign.pub -1` is `git log --grep=a` piped into `b --output=...`
    # -- is refused rather than handed back unwatched. The cost is refusing an
    # `--output` that belongs to some later non-git command; the alternative
    # is a bypass spelled with one pipe.
    seen_git=0
    in_diff=0
    skip_git_option_value=0
    continue
  fi

  # The target of a redirection is the shell's, not git's: `git diff HEAD
  # 2>&1` has one operand, and the `1` is neither a revision nor a path. The
  # targets the shell would open for writing were refused above.
  [[ "${kind}" == target ]] && continue

  # The operand scan for the other allow-listed command that opens a file it
  # is pointed at. Everything here is refused-by-default: a word this does not
  # recognise as an option is treated as a path and checked, so forgetting an
  # option costs a refused lint run rather than an unwatched read. The word
  # as typed is tested first, because the quote-stripped spelling is not the
  # path bash would hand shellcheck when it carries a tilde, a glob, a brace
  # or an expansion (see `word_bash_would_rewrite`).
  if ((in_shellcheck)); then
    if word_bash_would_rewrite "${raw_word}"; then
      refuse "${SHELLCHECK_EXPAND_MSG}"
    fi
    if ((skip_shellcheck_option_value)); then
      skip_shellcheck_option_value=0
      continue
    fi
    case "${word}" in
    # The eight short options that take a value, and the long options in the
    # space spelling Haskell's getOpt accepts (`--shell bash`). The attached
    # spellings (`-sbash`, `--shell=bash`) need no entry: they are one
    # dash-prefixed word and fall through to the catch-all below.
    #
    # `--rcfile` is deliberately absent, so its path is checked like any other
    # operand: an rc file outside the tree is not something a lint run here
    # needs. `-C` is absent too, because its argument is optional and must be
    # attached -- shellcheck reads `-C always` as the flag plus a file named
    # `always`, and so does this.
    -i | -e | -f | -o | -P | -s | -S | -W | \
      --include | --exclude | --format | --enable | --source-path | \
      --shell | --severity | --wiki-link-count)
      skip_shellcheck_option_value=1
      continue
      ;;
    # Stdin, not a file on disk.
    -) continue ;;
    -*) continue ;;
    *) ;;
    esac
    if ! path_inside_worktree "${word}" || denied_read_shape "${word}"; then
      refuse "${SHELLCHECK_MSG}"
    fi
    continue
  fi

  # Scoped to the git invocation as a whole, and checked before anything below
  # skips a dash-prefixed word: the write primitive belongs to the
  # diff-generation machinery rather than to one subcommand, so `git log -p
  # --output=FILE` and `git show --output=FILE` reach it without the word
  # `diff` appearing anywhere. `--output=x` and a bare `--output` (the space
  # form, whose path is the next word) are the two spellings; the pattern is
  # anchored so `--output-indicator-new=%` does not match it.
  #
  # This is deliberately wider than the allow list: a `git commit -m` whose
  # message happens to contain the word --output is refused too. That costs a
  # rephrased commit message; the alternative is a list of which git
  # subcommands accept the flag, and the subcommand this hook forgot is the
  # hole.
  # Brace expansion is the last rewrite bash performs that this scan can still
  # see, and it undoes both refusals below. It splits one word into several --
  # `git diff {/dev/null,./cosign.key}` is a single word here and two operands
  # to git, so the operand count never reaches 2 -- and it splits a flag name
  # apart -- `--outpu{t,t}=FILE` matches neither `--output` nor `--output=*`
  # here and arrives at git as `--output=FILE --output=FILE`. It needs no
  # variable and no subshell, so it is not one of the runtime-built arguments
  # this hook says it cannot see; it is plainly in the string and simply was
  # not expanded.
  #
  # Refused rather than expanded. Expanding means reimplementing bash's rules
  # in this hook -- nesting, `{1..9}` sequences, quoting -- and a half-right
  # expansion is a gate that disagrees with the shell in some other direction.
  # A refusal cannot be half-right. It is not every brace, though: bash leaves
  # a brace alone unless a comma or a `..` range sits inside it, and git's own
  # `@{...}` revision syntax -- `HEAD@{1}`, `main@{upstream}`, `@{-1}`,
  # `@{2.days.ago}` -- is spelled with exactly that literal form. Refusing it
  # blocks the ordinary diff against the previous commit for no gain, so the
  # test is `brace_would_expand`: a comma or `..` somewhere after a `{` and
  # before a `}`, which every expansion bash performs must have, and nothing
  # bash would leave alone needs. That test ran above, on the words as
  # typed, because the words here have had their quotes removed and a quote
  # is what keeps `{a';',b}` one word.
  #
  # Scoped to the git invocation's own words, so `awk '{print}'` and
  # `jq '{a:1}'` are untouched whether they come before, after, or without a
  # git command in the same string (see `raw_in_git` above). The cost is a
  # `${VAR}` inside a git invocation, which is a runtime-built argument this
  # hook already cannot inspect -- refusing it is stricter than the status
  # quo, not weaker. A brace *before* the first `git` word is not
  # checked and does not need to be: the allow rules in .claude/settings.json
  # match a literal `git diff`/`git log` prefix, so a git invocation assembled
  # out of braces (`{git,:} diff ...`, `g{i,i}t diff ...`) matches no allow
  # rule and prompts on its own.
  if ((in_git)); then
    case "${word}" in
    --output | --output=*) refuse "${OUT_MSG}" ;;
    esac
  fi

  if ((in_diff)); then
    if [[ "${word}" == "--" ]]; then
      if ((operands > 0)); then
        # A revision or path already stopped git's scan, so what follows is a
        # pathspec resolved against the repository, never a plain file.
        seen_git=0
        in_diff=0
      else
        # Nothing preceded the `--`: git consumes it and applies the
        # two-operand test to the words after it. Count those instead.
        after_dashdash=1
      fi
      continue
    fi
    if ((after_dashdash)); then
      # Git does not parse options here: `-x` after `--` is a path named -x.
      ((operands++))
      path_inside_worktree "${word}" || unresolved=1
      if ((operands >= 2 && unresolved)); then
        refuse "${DIFF_MSG}"
      fi
      continue
    fi
    # `-` is not an option here. Git diff reads it as the stdin operand and
    # counts it toward the same two-operand test, so `git diff /etc/shadow -`
    # prints the file with one flagless operand and one dash -- while a scan
    # that skips every dash-prefixed word sees a single operand and never
    # reaches the refusal. It is the one word git treats as an operand and a
    # loop like this one would treat as an option: every other `-x` is a flag
    # git would reject if it were not one.
    [[ "${word}" == -* && "${word}" != "-" ]] && continue
    ((operands++))
    git rev-parse --verify --quiet "${word}^{commit}" >/dev/null 2>&1 || unresolved=1
    if ((operands >= 2 && unresolved)); then
      refuse "${DIFF_MSG}"
    fi
    continue
  fi

  if ((seen_git)); then
    if ((skip_git_option_value)); then
      # The value half of a two-token git global option. Without this the
      # directory or setting is read as the subcommand, git is forgotten, and
      # the operand scan never starts at all: `git -C / diff /dev/null
      # etc/shadow` went through uninspected. No allow rule matches that
      # spelling today, so it prompts -- but a gate whose coverage depends on
      # an allow rule's exact prefix is one allow-list edit from silence.
      skip_git_option_value=0
      continue
    fi
    case "${word}" in
    # The git-level options that load a program or move git somewhere else.
    # Stepping over them was enough while the only question was where the
    # subcommand is; it is not, because each reaches past the words an allow
    # rule matched: `-c diff.external=/tmp/evil` runs that program once per
    # changed path (verified against git 2.39.5), and `-C <dir>` makes the
    # containment test below answer about a directory git has already left.
    # Both the attached and the separated value are the same option to git
    # (`-C/tmp`, `-ccolor.ui=false`), so the pattern is the prefix; in this
    # position no other git option begins with `-c` or `-C`.
    -c* | -C* | --config-env | --config-env=* | --exec-path | --exec-path=*)
      refuse "${GIT_GLOBAL_MSG}"
      ;;
    --git-dir | --work-tree | --namespace | --super-prefix | --attr-source)
      skip_git_option_value=1
      continue
      ;;
    # The same program-running primitive as `-c diff.external=` above, written
    # as a subcommand instead of as an option, and the allow row reaches it for
    # free: `Bash(git diff*)` matches by prefix, so `git difftool` is a `git
    # diff` string to the permission layer. `--extcmd=PROG` (and `-x PROG`)
    # runs PROG once per changed path, with no environment assignment and no
    # config option anywhere in the command -- the two spellings this gate
    # already refuses. Verified against git 2.47.3.
    #
    # Refused in subcommand position rather than as a word anywhere, so
    # `git log --grep=difftool` and a path of that name are untouched.
    # `mergetool` runs a program the same way, through `--tool`; no allow row
    # here reaches it today, and it is refused with difftool anyway, because a
    # gate whose coverage depends on an allow rule's exact prefix is one
    # allow-list edit from silence -- the reason `skip_git_option_value` gives
    # just below for covering `git -C`.
    difftool | mergetool)
      refuse "${DIFFTOOL_MSG}"
      ;;
    esac
    # git-level options such as --no-pager sit between `git` and the subcommand.
    [[ "${word}" == -* ]] && continue
    if [[ "${word}" == "diff" ]]; then
      in_diff=1
      operands=0
      unresolved=0
      after_dashdash=0
      continue
    fi
    seen_git=0
  fi

  if [[ "${word}" == "git" ]]; then
    seen_git=1
    in_git=1
  fi

  # The bare word, for the same reason the git latch above matches the bare
  # word: `.claude/settings.json` allows the literal `shellcheck ` prefix, so
  # `/usr/bin/shellcheck ...` matches no allow rule and prompts on its own
  # account. Position is not required either -- `FOO=bar shellcheck ./.env`
  # puts the word second -- and the cost of that is an outside path named
  # after the word in some command that is not shellcheck at all
  # (`echo shellcheck /etc/passwd`), refused where it would otherwise have
  # prompted. That is the same trade the `--output` latch above makes.
  if [[ "${word}" == "shellcheck" ]]; then
    in_shellcheck=1
    skip_shellcheck_option_value=0
  fi
done

# The export family, latched while the commands were read above and refused
# here, after every other scan, so that a more specific message gets to speak
# first: `export SHELLCHECK_OPTS=/etc/shadow; shellcheck tests/run-tests.sh`
# is the linter reading a file operand out of its own options, and
# SHELLCHECK_EXPAND_MSG names that operand. Both strings are refused either
# way; only which explanation the reader gets depends on the order.
((saw_gated && saw_export)) && refuse "${GATED_EXPORT_MSG}"

exit 0

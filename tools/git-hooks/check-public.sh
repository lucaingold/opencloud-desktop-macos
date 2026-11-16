#!/bin/bash
# Guards this public repository against leaking secrets, personal data or local AI tooling.
#
#   check-public.sh staged            # pre-commit: staged changes and the author identity
#   check-public.sh message <file>    # commit-msg: the commit message
#   check-public.sh range <a>..<b>    # pre-push: every commit about to be published
#
# Personal patterns (names, addresses, hosts, IDs) are read from
# $(git rev-parse --git-common-dir)/info/private-patterns, one extended regex per line.
# That file stays local: publishing the list would leak what it protects.
set -uo pipefail

common_dir=$(git rev-parse --git-common-dir)
private_file="$common_dir/info/private-patterns"

# Credentials and keys, independent of the person.
secret_patterns=(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'gh[pousr]_[A-Za-z0-9]{30,}' 'github_pat_[A-Za-z0-9_]{40,}'
    'AKIA[0-9A-Z]{16}' 'xox[abprs]-[A-Za-z0-9-]{10,}' 'sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}'
    'AIza[0-9A-Za-z_-]{35}' 'glpat-[A-Za-z0-9_-]{20}'
    '(password|passwd|secret|api[_-]?key|access[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$({ ]{8,}["'"'"']'
    'Bearer [A-Za-z0-9._~+/-]{20,}=*'
)
# Files that never belong in the repository.
forbidden_files='(^|/)(\.env(\..*)?|.*\.(pem|p12|pfx|key|mobileprovision|keychain|sqlite)|id_(rsa|ed25519|ecdsa)(\.pub)?|credentials(\.json)?|CLAUDE\.md|AGENTS\.md|WARP\.md|GEMINI\.md|\.claude/.*|\.cursor/.*|\.codex/.*|openspec/.*|ai_docs/.*)$'
# Commit identities allowed in this repository.
allowed_email='(@users\.noreply\.github\.com|^feedback@restot\.top)$'

failed=0
report() { echo "check-public: $1" >&2; failed=1; }

personal_regex() {
    [ -f "$private_file" ] || return 1
    grep -v -E '^[[:space:]]*(#|$)' "$private_file" | paste -sd'|' -
}

scan_text() { # $1 = where, stdin = text
    local where=$1 text personal hit
    text=$(cat)
    for pattern in "${secret_patterns[@]}"; do
        hit=$(printf '%s\n' "$text" | grep -E -i -m1 -- "$pattern") && report "possible secret in $where: ${hit:0:120}"
    done
    if personal=$(personal_regex) && [ -n "$personal" ]; then
        hit=$(printf '%s\n' "$text" | grep -E -i -m1 -- "$personal") && report "personal data in $where: ${hit:0:120}"
    fi
}

scan_message() { # $1 = where, stdin = message
    local where=$1 message
    message=$(cat)
    printf '%s\n' "$message" | grep -q -i -E 'Co-Authored-By: *(Claude|.*anthropic)|Generated with \[Claude' &&
        report "AI attribution line in $where (this repository publishes without it)"
    printf '%s\n' "$message" | scan_text "$where message"
}

scan_files() { # $1 = where, stdin = file names
    local hit
    hit=$(grep -E -m1 -- "$forbidden_files") && report "forbidden file in $1: $hit"
}

check_email() { # $1 = where, $2 = email
    printf '%s' "$2" | grep -q -E -- "$allowed_email" ||
        report "$1 uses $2; use the GitHub noreply address (git config user.email <id>+<user>@users.noreply.github.com)"
}

case "${1:-}" in
staged)
    check_email "author" "$(git var GIT_AUTHOR_IDENT | sed -E 's/.*<(.*)>.*/\1/')"
    check_email "committer" "$(git var GIT_COMMITTER_IDENT | sed -E 's/.*<(.*)>.*/\1/')"
    # Process substitution keeps the scans in this shell, so their findings set $failed.
    scan_files "staged changes" < <(git diff --cached --name-only --diff-filter=ACR)
    scan_text "staged changes" < <(git diff --cached --unified=0 --no-color --diff-filter=ACMR | grep -E '^\+[^+]')
    ;;
message)
    scan_message "commit message" < <(grep -v '^#' "$2")
    ;;
range)
    # Commits already in the official client, the previous fork or this repository are public already.
    for commit in $(git rev-list "$2" --not --remotes=upstream --remotes=restot --remotes=origin); do
        short=$(git rev-parse --short "$commit")
        check_email "commit $short author" "$(git log -1 --format=%ae "$commit")"
        check_email "commit $short committer" "$(git log -1 --format=%ce "$commit")"
        scan_message "commit $short" < <(git log -1 --format=%B "$commit")
        scan_files "commit $short" < <(git show --format= --name-only --diff-filter=ACR "$commit")
        # For merges, --cc shows only what the merge itself changed (conflict resolutions), not upstream's work.
        scan_text "commit $short" < <(git show --format= --cc --unified=0 --no-color "$commit" | grep -E '^\+[^+]|^ *\+\+[^+]')
    done
    ;;
*)
    echo "usage: $0 staged | message <file> | range <a>..<b>" >&2
    exit 2
    ;;
esac

if [ "$failed" -ne 0 ]; then
    echo "check-public: blocked. Fix the findings above; for a deliberate false positive use --no-verify." >&2
    exit 1
fi

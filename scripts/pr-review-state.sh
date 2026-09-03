#!/usr/bin/env bash
set -euo pipefail

# Report the *thread-aware* review state of a pull request, plus its checks at
# the current head SHA.
#
# AGENTS.md and docs/review-rubric.md both require this and neither `gh pr view
# --comments` nor `gh api .../pulls/N/comments` provides it: both return a flat
# list of comments, from which you cannot tell whether the thread a comment
# belongs to is still unresolved, or has been marked outdated by a later push.
# Acting on a flat list means re-fixing settled feedback and missing live
# feedback, so this asks GitHub's GraphQL API for the thread objects instead.
#
# It also reads the checks at the head SHA the same query returned, because
# "checks passed" is only meaningful next to the commit it was said about --
# a rollup read from an earlier push is a statement about a commit nobody is
# looking at any more.
#
# Read-only. It issues one GraphQL query and writes nothing.
#
# Exit status is the point when this is used as a gate:
#   0  no unresolved threads and no failing checks
#   1  something is outstanding (unresolved threads, or failing checks)
#   2  usage or API error
#
# Note the exit code says nothing about whether a *review* happened, and a
# resolved thread is not evidence that the underlying issue was fixed -- only
# that someone marked it resolved.

usage() {
  cat <<'USAGE'
Usage: pr-review-state.sh [--json] [--repo OWNER/REPO] [PR_NUMBER]

Report unresolved review threads and check results for a pull request.

  --json            Emit the raw JSON instead of the human-readable report.
  --repo OWNER/REPO Target repository. Defaults to gh's current repository.
  PR_NUMBER         Defaults to the pull request for the current branch.

Exit status: 0 nothing outstanding, 1 something outstanding, 2 usage/API error.
USAGE
}

emit_json=0
repo=""
pr_number=""

while (($# > 0)); do
  case "$1" in
    --json)
      emit_json=1
      shift
      ;;
    --repo)
      if (($# < 2)); then
        echo "error: --repo needs a value" >&2
        exit 2
      fi
      repo="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'error: unknown option %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${pr_number}" ]]; then
        echo "error: more than one pull request number given" >&2
        exit 2
      fi
      pr_number="$1"
      shift
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is not on PATH; see https://cli.github.com" >&2
  exit 2
fi

repo_args=()
[[ -n "${repo}" ]] && repo_args=(--repo "${repo}")

if [[ -z "${pr_number}" ]]; then
  # No number given: fall back to the pull request for the current branch.
  if ! pr_number="$(gh pr view "${repo_args[@]}" --json number --jq '.number' 2>/dev/null)"; then
    echo "error: no pull request number given and none found for the current branch" >&2
    exit 2
  fi
fi

if [[ ! "${pr_number}" =~ ^[0-9]+$ ]]; then
  printf 'error: pull request number must be numeric, got %s\n' "${pr_number}" >&2
  exit 2
fi

# One query for everything, so the threads and the checks are read at the same
# head SHA rather than from two calls that could straddle a push.
read -r -d '' query <<'GRAPHQL' || true
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      title
      isDraft
      headRefOid
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          # An outdated thread reports a null `line`, because the line it was
          # anchored to no longer exists at head. originalLine is where it was
          # written, which is the only location worth printing for it.
          originalLine
          comments(first: 1) {
            nodes {
              author { login }
              body
              url
            }
          }
        }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  __typename
                  ... on CheckRun { name conclusion status detailsUrl }
                  ... on StatusContext { context state targetUrl }
                }
              }
            }
          }
        }
      }
    }
  }
}
GRAPHQL

if [[ -n "${repo}" ]]; then
  owner="${repo%%/*}"
  name="${repo#*/}"
else
  if ! owner_and_name="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)"; then
    echo "error: could not determine the repository; pass --repo OWNER/REPO" >&2
    exit 2
  fi
  owner="${owner_and_name%%/*}"
  name="${owner_and_name#*/}"
fi

if ! response="$(gh api graphql \
  -F owner="${owner}" -F repo="${name}" -F number="${pr_number}" \
  -f query="${query}" 2>&1)"; then
  printf 'error: GraphQL query failed: %s\n' "${response}" >&2
  exit 2
fi

# Flatten into the shape the report and --json both consume, so there is one
# definition of "unresolved" rather than two that can disagree.
if ! summary="$(printf '%s' "${response}" | jq '
  .data.repository.pullRequest as $pr
  | ($pr.commits.nodes[0].commit.statusCheckRollup) as $rollup
  | {
      number: $pr.number,
      title: $pr.title,
      isDraft: $pr.isDraft,
      headRefOid: $pr.headRefOid,
      rollupState: ($rollup.state // "NONE"),
      threads: [
        $pr.reviewThreads.nodes[]
        | {
            resolved: .isResolved,
            outdated: .isOutdated,
            path: .path,
            line: (.line // .originalLine),
            author: (.comments.nodes[0].author.login // "unknown"),
            url: (.comments.nodes[0].url // ""),
            excerpt: ((.comments.nodes[0].body // "") | gsub("\\s+"; " ") | .[0:160])
          }
      ],
      checks: [
        ($rollup.contexts.nodes // [])[]
        | if .__typename == "CheckRun"
          then {name: .name, state: (.conclusion // .status), url: .detailsUrl}
          else {name: .context, state: .state, url: .targetUrl}
          end
      ]
    }
  | .unresolved = [.threads[] | select(.resolved | not)]
  | .failing = [.checks[] | select(.state == "FAILURE" or .state == "TIMED_OUT" or .state == "CANCELLED" or .state == "ERROR" or .state == "ACTION_REQUIRED")]
  | .pending = [.checks[] | select(.state == "IN_PROGRESS" or .state == "QUEUED" or .state == "PENDING" or .state == "WAITING")]
' 2>&1)"; then
  printf 'error: could not parse the GraphQL response: %s\n' "${summary}" >&2
  exit 2
fi

if ((emit_json)); then
  printf '%s\n' "${summary}"
else
  printf '%s' "${summary}" | jq -r '
    "PR #\(.number): \(.title)" ,
    "head:   \(.headRefOid)" ,
    "" ,
    "Review threads: \(.threads | length) total, \(.unresolved | length) unresolved" ,
    ( if (.unresolved | length) == 0 then "  (none outstanding)"
      else (.unresolved[] |
        "  - \(.path // "(no file)"):\(.line // "?")  by \(.author)\(if .outdated then "  [outdated]" else "" end)\n" +
        "      \(.excerpt)\n" +
        "      \(.url)")
      end ) ,
    "" ,
    "Checks at \(.headRefOid[0:12]): \(.rollupState)" ,
    ( if (.checks | length) == 0 then "  (no checks ran -- for a docs-only change that is a skip, not a pass)"
      else (.checks[] | "  \(.state | .[0:14] | . + (" " * (14 - length)))  \(.name)")
      end ) ,
    "" ,
    "Outstanding: \(.unresolved | length) unresolved thread(s), \(.failing | length) failing check(s), \(.pending | length) still running"
  '
fi

unresolved_count="$(printf '%s' "${summary}" | jq '.unresolved | length')"
failing_count="$(printf '%s' "${summary}" | jq '.failing | length')"

if ((unresolved_count > 0 || failing_count > 0)); then
  exit 1
fi
exit 0

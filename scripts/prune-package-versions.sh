#!/usr/bin/env bash
set -euo pipefail

# Prune old versions of a GitHub Packages container package: drop the versions
# nobody can name, then keep the N most recently created tagged images.
#
# This exists to replace `actions/delete-package-versions`, which has had no
# release since 2024-02-07. An unmaintained action is an ordinary supply-chain
# nuisance in most jobs; here it was the one step in the whole workflow holding
# *delete* rights over every image this repository has ever published, with no
# upstream left to ship a fix if something turned up in it. Everything it did
# for this repository is a list call plus a delete call per doomed version, and
# `gh` is already on every GitHub-hosted runner -- so the job makes those calls
# itself, and tests/test-prune-package-versions.sh covers the decision of what
# to delete without touching the network.
#
# The retention rule counts images a person can name, in three passes:
#
#   1. Untagged versions go. Every publish pushes by tag, so an image is
#      untagged only once a newer build has taken its date tag (several
#      publishes a day share one YYYYMMDD), and nothing can ask for it by name
#      any more.
#   2. Tagged images are ordered by creation time; the newest
#      --min-versions-to-keep stay and the rest go.
#   3. A cosign signature (a version whose tags are all `sha256-<hex>.sig`)
#      names its subject in the tag. It stays while the image `sha256:<hex>`
#      stays, and goes once that image is gone -- including an image whose own
#      deletion was asked for in this run and succeeded. A signature whose
#      subject failed to delete is kept, so a failure never leaves an image
#      without its signature.
#
# The action this replaced counted every version, signatures and untagged
# images included. At about four publishes a day that kept 15 images and only
# four days of dated tags under a floor of 30 (issue #430); counting tagged
# images keeps 30 dated builds.
#
# Two assumptions that pass 1 rests on, both true of build.yml today. Every
# image is a single manifest: a multi-arch index would list its per-platform
# manifests as untagged versions, and this pass would delete them out from
# under it. And cosign stores signatures as `.sig` tags
# (--new-bundle-format=false): the newer bundle format stores them as untagged
# OCI referrers, which this pass would also delete. Change either and this
# script has to change with it.
#
# One deliberate addition. The workflow's own comment argues that a version
# tagged `latest` is always among the newest, because `latest` is repointed at
# the newest version on every publish -- so no explicit carve-out is needed.
# That argument is correct today, and it is an argument rather than a
# guarantee, and what it protects is `bootc upgrade` on machines already
# running this image. So it is enforced here as well as reasoned about: a
# version tagged `latest` is never deleted. If the reasoning ever stops
# holding, the failure mode becomes one version too many surviving a prune
# rather than a broken upgrade path on installed systems.
#
# Nothing is written to disk and no temporary files are created: every API
# response is read into a variable, so the only state this touches is the
# package it was pointed at. --dry-run reports exactly what would go without
# issuing a single DELETE, which is how to check a retention change before
# letting it run against a real package.
#
# Exit status:
#   0  the package is within its retention budget, or was brought within it
#   1  one or more deletions failed
#   2  usage error, missing tool, or the version list could not be read

usage() {
  cat <<'USAGE'
Usage: prune-package-versions.sh --package NAME --min-versions-to-keep N [options]

Delete old versions of a GitHub Packages package: every untagged version,
every tagged image past the newest N, and every signature whose image is gone.

  --package NAME            Package name, e.g. arch-bootc-base. Required.
  --min-versions-to-keep N  How many of the newest tagged images to keep.
                            Signatures and untagged versions do not count.
                            Required, and must be at least 1.
  --owner OWNER             Account owning the package. Defaults to
                            $GITHUB_REPOSITORY_OWNER.
  --owner-type TYPE         "user" or "organization". Looked up from the API
                            when omitted or empty.
  --package-type TYPE       Defaults to "container".
  --dry-run                 Report what would be deleted and delete nothing.

Needs gh authenticated with permission to delete versions of the package. For
GITHUB_TOKEN that means `packages: write` *and* the package's own settings on
ghcr.io granting this repository the Admin role.

Exit status: 0 nothing outstanding, 1 a deletion failed, 2 usage/API error.
USAGE
}

owner="${GITHUB_REPOSITORY_OWNER:-}"
owner_type=""
package_name=""
package_type="container"
min_versions_to_keep=""
dry_run=0

need_value() {
  if (($2 < 2)); then
    printf 'error: %s needs a value\n' "$1" >&2
    exit 2
  fi
}

while (($# > 0)); do
  case "$1" in
    --package)
      need_value "$1" "$#"
      package_name="$2"
      shift 2
      ;;
    --min-versions-to-keep)
      need_value "$1" "$#"
      min_versions_to_keep="$2"
      shift 2
      ;;
    --owner)
      need_value "$1" "$#"
      owner="$2"
      shift 2
      ;;
    --owner-type)
      need_value "$1" "$#"
      owner_type="$2"
      shift 2
      ;;
    --package-type)
      need_value "$1" "$#"
      package_type="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${package_name}" ]]; then
  echo "error: --package is required" >&2
  usage >&2
  exit 2
fi

if [[ -z "${owner}" ]]; then
  echo "error: no owner given and GITHUB_REPOSITORY_OWNER is unset; pass --owner OWNER" >&2
  exit 2
fi

# Required rather than defaulted. A default here is a silent retention policy,
# and the two obvious candidates are both wrong: 0 deletes everything, and any
# other number is a guess at how much history this repository wants to keep.
if [[ -z "${min_versions_to_keep}" ]]; then
  echo "error: --min-versions-to-keep is required" >&2
  usage >&2
  exit 2
fi
if [[ ! "${min_versions_to_keep}" =~ ^[0-9]+$ ]]; then
  printf 'error: --min-versions-to-keep must be a non-negative integer, got %s\n' \
    "${min_versions_to_keep}" >&2
  exit 2
fi
# `--min-versions-to-keep 0` asks to remove every published version of the
# image, including the one `latest` points at. Nothing here wants that, and a
# typo or an empty variable expanding to 0 is a far more likely way to reach it
# than a deliberate decision, so it is refused outright.
if ((min_versions_to_keep < 1)); then
  echo "error: --min-versions-to-keep must be at least 1; refusing to prune every version" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh (the GitHub CLI) is required; see https://cli.github.com" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required; see https://jqlang.github.io/jq/" >&2
  exit 2
fi

# Collapse a multi-line API error so it stays on the line the message formats.
one_line() {
  printf '%s' "${1//$'\n'/ }"
}

# The REST path differs between a user-owned and an organization-owned package,
# and getting it wrong is a 404 rather than a wrong answer -- but a 404 here
# would read as "the package has no versions", so resolve the owner type up
# front and fail if it cannot be resolved.
if [[ -z "${owner_type}" ]]; then
  if ! owner_type="$(gh api "users/${owner}" --jq '.type' 2>&1)"; then
    printf 'error: could not tell whether %s is a user or an organization: %s\n' \
      "${owner}" "$(one_line "${owner_type}")" >&2
    exit 2
  fi
fi

case "${owner_type,,}" in
  user)
    owner_scope="users/${owner}"
    ;;
  organization | org)
    owner_scope="orgs/${owner}"
    ;;
  *)
    printf 'error: unknown owner type %s; expected "user" or "organization"\n' "${owner_type}" >&2
    exit 2
    ;;
esac

versions_path="${owner_scope}/packages/${package_type}/${package_name}/versions"

# `--jq '.[]'` per page followed by a slurp, rather than gh's own `--slurp`:
# with --paginate, --slurp wraps each page in an outer array, so the result is
# an array of pages and every filter below would have to flatten it first.
#
# stderr is folded into the capture on purpose, so a failure has something to
# report rather than an empty string. The cost is that anything gh writes to
# stderr on an otherwise successful call lands in the data -- which the parse
# below turns into a loud failure, not a silently short version list. Failing
# closed is the right side to err on here: the quiet alternative is a prune job
# that thinks the package is empty.
if ! versions_ndjson="$(gh api --paginate "${versions_path}?per_page=100" --jq '.[]' 2>&1)"; then
  printf 'error: could not list versions of %s: %s\n' \
    "${package_name}" "$(one_line "${versions_ndjson}")" >&2
  exit 2
fi

# A call that succeeds can still return something unreadable -- a schema change,
# or a proxy substituting its own body -- and gh exited 0, so this parse is the
# only thing left to notice. Failing here beats reading it as an empty package.
if ! versions="$(jq -s '.' <<<"${versions_ndjson}" 2>&1)"; then
  printf 'error: could not parse the version list for %s: %s\n' \
    "${package_name}" "$(one_line "${versions}")" >&2
  exit 2
fi

total="$(jq 'length' <<<"${versions}")"
printf 'prune: %s/%s (%s) has %s version(s); keeping the newest %s tagged image(s)\n' \
  "${owner}" "${package_name}" "${package_type}" "${total}" "${min_versions_to_keep}"

# A signature is a version whose every tag is `sha256-<hex>.sig`; an image is
# any other tagged version. Each version gets a `kind` and, for a signature,
# the digest of the image it signs.
classified="$(jq -c '
  map(
    (.metadata.container.tags // []) as $tags
    | if ($tags | length) == 0 then . + {kind: "untagged"}
      elif all($tags[]; test("^sha256-[0-9a-f]+\\.sig$")) then
        . + {kind: "signature", subject: ($tags[0] | sub("^sha256-"; "sha256:") | sub("\\.sig$"; ""))}
      else . + {kind: "image"}
      end
  )' <<<"${versions}")"

# `.id` as a secondary sort key so two versions created in the same second get
# a defined order. Without it the boundary between kept and pruned moves
# between runs on ties, which is the kind of thing that surfaces months later
# as one unexpectedly missing image.
ordered="$(jq -c '[.[] | select(.kind == "image")] | sort_by(.created_at, .id) | reverse' <<<"${classified}")"
candidates="$(jq -c --argjson keep "${min_versions_to_keep}" '.[$keep:]' <<<"${ordered}")"
untagged="$(jq -c '[.[] | select(.kind == "untagged")] | sort_by(.created_at, .id)' <<<"${classified}")"
signatures="$(jq -c '[.[] | select(.kind == "signature")] | sort_by(.created_at, .id)' <<<"${classified}")"

tsv() {
  jq -r '.[] | [
    (.id | tostring),
    (.name // "(no digest)"),
    (.created_at // "(no timestamp)"),
    (((.metadata.container.tags // []) | join(",")) | if . == "" then "(untagged)" else . end)
  ] | @tsv'
}

# Reported, not silently skipped. A `latest` outside the newest N means the
# assumption the retention rule rests on has stopped holding, and a quiet
# carve-out would hide the one condition here worth knowing about.
protected="$(jq -c '[.[] | select(((.metadata.container.tags // []) | index("latest")) != null)]' <<<"${candidates}")"
protected_count="$(jq 'length' <<<"${protected}")"
if ((protected_count > 0)); then
  while IFS=$'\t' read -r id digest created tags; do
    printf 'prune: KEEPING %s (%s, created %s, tags %s) -- tagged latest but outside the newest %s\n' \
      "${id}" "${digest}" "${created}" "${tags}" "${min_versions_to_keep}" >&2
  done < <(tsv <<<"${protected}")
fi

# Untagged versions first, then tagged images past the floor. Signatures are
# decided after both, against what actually went.
doomed_images="$(jq -c --argjson untagged "${untagged}" \
  '$untagged + [.[] | select(((.metadata.container.tags // []) | index("latest")) == null)]' <<<"${candidates}")"

pruned=0
failed=0
gone_digests=()
remove() {
  local id="$1" digest="$2" created="$3" tags="$4"
  if ((dry_run)); then
    printf 'prune: would remove %s (%s, created %s, tags %s)\n' "${id}" "${digest}" "${created}" "${tags}"
    pruned=$((pruned + 1))
    return 0
  fi
  # `2>&1 >/dev/null` in that order: stderr goes to the capture and stdout to
  # nowhere. Reversed, both would be captured and a successful response body
  # would be reported as an error message.
  if api_error="$(gh api --method DELETE "${versions_path}/${id}" 2>&1 >/dev/null)"; then
    printf 'prune: removed %s (%s, created %s, tags %s)\n' "${id}" "${digest}" "${created}" "${tags}"
    pruned=$((pruned + 1))
    return 0
  fi
  printf 'prune: FAILED on %s (%s, created %s, tags %s): %s\n' \
    "${id}" "${digest}" "${created}" "${tags}" "$(one_line "${api_error}")" >&2
  failed=$((failed + 1))
  return 1
}

while IFS=$'\t' read -r id digest created tags; do
  remove "${id}" "${digest}" "${created}" "${tags}" && gone_digests+=("${digest}")
done < <(tsv <<<"${doomed_images}")

# The images still standing are every image and untagged version that was not
# removed just now. A signature whose subject is among them stays; any other
# signature has nothing left to sign.
standing="$(jq -c --args '[.[] | select(.kind != "signature") | .name] - $ARGS.positional' \
  "${gone_digests[@]}" <<<"${classified}")"
doomed_signatures="$(jq -c --argjson standing "${standing}" \
  '[.[] | select(.subject as $s | ($standing | index($s)) == null)]' <<<"${signatures}")"
while IFS=$'\t' read -r id digest created tags; do
  remove "${id}" "${digest}" "${created}" "${tags}" || true
done < <(tsv <<<"${doomed_signatures}")

doomed_count=$(($(jq 'length' <<<"${doomed_images}") + $(jq 'length' <<<"${doomed_signatures}")))
if ((doomed_count == 0)); then
  echo "prune: nothing to prune"
  exit 0
fi

if ((dry_run)); then
  printf 'prune: dry run -- %s of %s candidate version(s) would go, %s kept by the latest guard\n' \
    "${pruned}" "${doomed_count}" "${protected_count}"
  exit 0
fi

printf 'prune: removed %s of %s version(s), %s failure(s), %s kept by the latest guard\n' \
  "${pruned}" "${doomed_count}" "${failed}" "${protected_count}"

if ((failed > 0)); then
  # Loud rather than best-effort. The usual cause is the package's Admin-role
  # grant having been dropped, which otherwise shows up as a job that has
  # quietly stopped pruning anything for months.
  exit 1
fi

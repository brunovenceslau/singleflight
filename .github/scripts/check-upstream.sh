#!/usr/bin/env bash
#
# Fails when golang.org/x/sync has published a version this repo has not
# caught up with yet.
#
# Why this exists: this repo's tags are meant to track the upstream
# golang.org/x/sync version (see README "Updates & Versioning"), and the
# generic wrapper must mirror any upstream API change. x/sync tags are
# monolithic (one tag covers the whole module, not just singleflight), so a
# version bump upstream is exactly the event that requires a look here -
# there is no finer-grained signal worth diffing against. This script is the
# weekly alarm for that event; it does not itself do any of the mirroring
# work.
#
# Two comparisons, both must hold for the check to pass:
#   1. The go.mod pin for golang.org/x/sync must equal upstream latest.
#      Otherwise a Dependabot bump is pending or open but unmerged.
#   2. The newest release tag in this repo (strict vX.Y.Z semver, compared
#      with `sort -V`) must be >= upstream latest. Otherwise the mirror work
#      landed but the aligned tag has not been cut yet. This keeps the
#      alarm firing after a Dependabot merge until a matching tag exists.
#
# Fails closed: an empty upstream version, an empty pin, a pin or upstream
# version that is not a valid semver string, or the absence of any
# qualifying tag at all is treated as a failure with a clear message -
# never as a silent pass.
#
# Covered by .github/scripts/check-upstream_test.sh, run in CI as the
# "selftest" job in .github/workflows/upstream-check.yaml.
set -euo pipefail

MODULE="golang.org/x/sync"

log_error() {
  local msg="$1"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    # ::error:: annotations are line-oriented - a literal newline in msg
    # would truncate the annotation at the first line, and an embedded
    # "::" line could otherwise be read as a second, forged workflow
    # command. Escape percent-encoded per GitHub's documented order:
    # % first (so the escapes below don't get re-escaped), then CR, then
    # LF, so a multi-reason message lands as one complete, inert
    # annotation.
    msg=${msg//'%'/%25}
    msg=${msg//$'\r'/%0D}
    msg=${msg//$'\n'/%0A}
    # printf, not echo: with `shopt -s xpg_echo` (settable via BASHOPTS in
    # the inherited environment) bash's builtin echo interprets backslash
    # escapes, so a literal two-character "\n" in the untrusted text would
    # be expanded back into a real newline *after* the escaping above -
    # splitting one annotation into two and re-opening the forged-workflow-
    # command hole the escaping just closed. printf's format string is
    # fixed here, and %s never re-interprets its argument.
    printf '::error::%s\n' "${msg}"
  else
    printf 'ERROR: %s\n' "${msg}" >&2
  fi
}

write_summary() {
  local body="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    # The verdict is the exit code, not the summary: an unwritable
    # GITHUB_STEP_SUMMARY must never turn a PASS into a failure here.
    # printf, not echo, for the same reason as in log_error: under
    # `shopt -s xpg_echo` echo would re-expand a literal "\n" (or any other
    # backslash escape) inside the untrusted detail this body carries.
    printf '%s\n' "${body}" >> "${GITHUB_STEP_SUMMARY}" || true
  fi
}

# fail MSG [DETAIL]. DETAIL, when given, is untrusted text (go list's
# stderr) - it is appended to the annotation as plain text (annotations
# are line-oriented, not markdown, so there is no heading syntax there for
# it to exploit). In GITHUB_STEP_SUMMARY it is wrapped in a fenced code
# block instead of dropped in as bare markdown, and the fence is sized to
# be longer than any run of backticks already present in detail, so detail
# cannot supply its own closing fence and break out of the block early.
fail() {
  local msg="$1"
  local detail="${2:-}"
  # Bound the untrusted text here, before it is used anywhere. The
  # fence-sizing loop below terminates only because detail is finite, and
  # today it happens to be finite because the Go toolchain truncates a
  # command's stderr at its internal maxErrorDetailBytes cap - an
  # implementation detail of another program, not a guarantee this script
  # holds. A local cap makes the loop's termination (and the annotation's
  # size) a property of this script alone.
  detail="${detail:0:4096}"
  local full_msg="${msg}"
  if [[ -n "${detail}" ]]; then
    full_msg="${msg}
go list stderr: ${detail}"
  fi
  log_error "${full_msg}"
  if [[ -n "${detail}" ]]; then
    # Grow the fence until it is longer than every backtick run in detail.
    # The match is deliberately "a backtick run anywhere in the text", not
    # "a standalone fence line": a run embedded mid-line can never close a
    # markdown fence, so this over-approximates. Over-approximating can
    # only make the fence longer than strictly necessary, never shorter -
    # it cannot under-size it, which is the only direction that would be a
    # break-out. Do not "optimize" this into a line-anchored check; the
    # loose match is what makes the bound trivially safe to reason about.
    local fence='```'
    while [[ "${detail}" == *"${fence}"* ]]; do
      fence="${fence}"'`'
    done
    write_summary "### Upstream check: FAIL

${msg}

${fence}
${detail}
${fence}"
  else
    write_summary "### Upstream check: FAIL

${msg}"
  fi
  exit 1
}

# Both git calls in this script (`git rev-parse --show-toplevel` here and
# `git tag -l` below) resolve their repository from the environment before
# they look at the working directory, so an inherited GIT_DIR (or any of
# its siblings) silently redirects them at a repository that is not this
# checkout. That is not hypothetical noise: point GIT_DIR at a decoy repo
# holding a forged high tag and the tag half of the alarm passes while the
# real checkout has no aligned tag at all - a silent pass, the one outcome
# this script exists to prevent. Clearing them makes the working directory
# the single source of truth for which repository is being inspected.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES

# Position-independent: always operate from the root of whichever git repo
# contains the current working directory, regardless of where the script is
# invoked from. A command substitution's failure does not trip `set -e` when
# the substitution is used as an argument (and `cd ""` on an empty result
# would be a silent no-op) - so the failure is checked explicitly and made
# to fail closed via `fail`, rather than relying on -e to catch it.
repo_root="$(git rev-parse --show-toplevel)" || fail "Not inside a git repository."
cd "${repo_root}"

# Shape gate for the two version strings that come back from `go list`,
# both of which end up interpolated into an annotation and into the step
# summary. It is deliberately not a general-purpose SemVer validator: it
# accepts a leading-zero major/minor/patch (v01.2.3), which strict SemVer
# disallows. What it does guarantee is the only property that matters
# here - the value is drawn from [v0-9.+-] and letters, so it cannot carry
# a newline, a "::" workflow command, a backtick, or any other character
# that would let it break out of the context it is printed into.
semver_re='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

stderr_file="$(mktemp)"
trap 'rm -f "${stderr_file}"' EXIT

upstream_version="$(go list -m -f '{{.Version}}' "${MODULE}@latest" 2>"${stderr_file}" || true)"
upstream_err="$(cat "${stderr_file}")"
if [[ -z "${upstream_version}" ]]; then
  fail "Could not determine the latest published version of ${MODULE} from the Go proxy." "${upstream_err}"
fi
if [[ ! "${upstream_version}" =~ ${semver_re} ]]; then
  fail "Upstream version reported by the Go proxy is not a valid semver string."
fi

: > "${stderr_file}"
pinned_version="$(go list -m -f '{{.Version}}' "${MODULE}" 2>"${stderr_file}" || true)"
pinned_err="$(cat "${stderr_file}")"
if [[ -z "${pinned_version}" ]]; then
  fail "Could not determine the go.mod pin for ${MODULE}." "${pinned_err}"
fi
if [[ ! "${pinned_version}" =~ ${semver_re} ]]; then
  fail "go.mod pin for ${MODULE} is not a valid semver string."
fi

# List release tags present in this checkout (fetch-depth: 0 in CI so tags
# are fetched). Restrict to strict release semver (vX.Y.Z): `sort -V` is not
# a semver comparator, so pre-release tags (v0.23.0-rc.1), bare non-numeric
# tags (vX), and non-semver tags (vendor-pin, v-experimental) would
# otherwise be able to sort above a real release tag and make the gate pass
# while the actual release tag is missing.
#
# The `|| true` covers two failure modes of the pipeline under `pipefail`:
# `git tag` failing outright, and `grep` finding zero matching tags (which
# exits 1 even though the pipeline "succeeded"). Either way this degrades to
# an empty value rather than aborting, so the check right below can fail
# closed with a clear message instead of the script dying silently.
#
# `command grep` (not bare `grep`) bypasses any shell function or alias
# named grep - house convention. It does not defend against a PATH-planted
# `grep` binary ahead of the real one.
newest_tag="$(git tag -l 'v*' | command grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
if [[ -z "${newest_tag}" ]]; then
  fail "No release tags (strict vX.Y.Z) found in this repository. Cannot confirm the mirror release is aligned with ${MODULE}@${upstream_version}."
fi

# One aligned printf rather than three echos with hand-counted padding
# (which had drifted a column apart): the first label embeds MODULE, so
# the column the values start in is not a constant that can be typed in by
# hand. `%-*s` takes the field width as an argument, and printf reuses the
# format for each following triple.
label_width=$(( ${#MODULE} + 10 ))  # "Upstream " + MODULE + ":"
if (( label_width < 16 )); then     # unless a shorter MODULE leaves
  label_width=16                    # "Newest repo tag:" as the longest
fi
printf '%-*s %s\n' \
  "${label_width}" "Upstream ${MODULE}:" "${upstream_version}" \
  "${label_width}" "go.mod pin:" "${pinned_version}" \
  "${label_width}" "Newest repo tag:" "${newest_tag}"

pin_ok=true
tag_ok=true

if [[ "${pinned_version}" != "${upstream_version}" ]]; then
  pin_ok=false
fi

# tag_ok when newest_tag >= upstream_version, i.e. sorting the two together
# with sort -V puts upstream_version first (or they are equal). Only these
# two already-filtered values are ever compared here.
smallest="$(printf '%s\n%s\n' "${newest_tag}" "${upstream_version}" | sort -V | head -n1)"
if [[ "${smallest}" != "${upstream_version}" ]]; then
  tag_ok=false
fi

if [[ "${pin_ok}" == "true" && "${tag_ok}" == "true" ]]; then
  write_summary "### Upstream check: PASS

- Upstream \`${MODULE}\`: \`${upstream_version}\`
- go.mod pin: \`${pinned_version}\`
- Newest repo tag: \`${newest_tag}\`"
  echo "OK: go.mod pin and newest tag are aligned with upstream ${upstream_version}."
  exit 0
fi

reasons=()
if [[ "${pin_ok}" == "false" ]]; then
  reasons+=("go.mod pins ${MODULE}@${pinned_version}, but upstream latest is ${upstream_version} (a Dependabot bump is pending or unmerged).")
fi
if [[ "${tag_ok}" == "false" ]]; then
  reasons+=("newest repo tag is ${newest_tag}, which is older than upstream ${upstream_version} (the aligned release tag has not been cut yet).")
fi

joined="$(printf '%s\n' "${reasons[@]}")"
log_error "Upstream ${MODULE} has moved to ${upstream_version}; this repo has not caught up: ${joined}"
write_summary "### Upstream check: FAIL

Upstream \`${MODULE}\` has moved to \`${upstream_version}\`; this repo has not caught up.

$(printf -- '- %s\n' "${reasons[@]}")"
exit 1

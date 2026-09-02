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
#   2. The newest semver tag in this repo (v-prefixed, compared with
#      `sort -V`) must be >= upstream latest. Otherwise the mirror work
#      landed but the aligned tag has not been cut yet. This keeps the
#      alarm firing after a Dependabot merge until a matching tag exists.
#
# Fails closed: an empty upstream version, an empty pin, or the absence of
# any tag at all is treated as a failure with a clear message - never as a
# silent pass.
set -euo pipefail

MODULE="golang.org/x/sync"

log_error() {
  local msg="$1"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::${msg}"
  else
    echo "ERROR: ${msg}" >&2
  fi
}

write_summary() {
  local body="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "${body}" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

fail() {
  local msg="$1"
  log_error "${msg}"
  write_summary "### Upstream check: FAIL

${msg}"
  exit 1
}

upstream_version="$(go list -m -f '{{.Version}}' "${MODULE}@latest" 2>/dev/null || true)"
if [[ -z "${upstream_version}" ]]; then
  fail "Could not determine the latest published version of ${MODULE} from the Go proxy."
fi

pinned_version="$(go list -m -f '{{.Version}}' "${MODULE}" 2>/dev/null || true)"
if [[ -z "${pinned_version}" ]]; then
  fail "Could not determine the go.mod pin for ${MODULE}."
fi

# List tags reachable from this checkout. Requires fetch-depth: 0 in CI.
newest_tag="$(git tag -l 'v*' | sort -V | tail -n1 || true)"
if [[ -z "${newest_tag}" ]]; then
  fail "No v-prefixed tags found in this repository. Cannot confirm the mirror release is aligned with ${MODULE}@${upstream_version}."
fi

echo "Upstream ${MODULE}: ${upstream_version}"
echo "go.mod pin:          ${pinned_version}"
echo "Newest repo tag:      ${newest_tag}"

pin_ok=true
tag_ok=true

if [[ "${pinned_version}" != "${upstream_version}" ]]; then
  pin_ok=false
fi

# tag_ok when newest_tag >= upstream_version, i.e. sorting the two together
# with sort -V puts upstream_version first (or they are equal).
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

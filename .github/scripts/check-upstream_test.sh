#!/usr/bin/env bash
#
# Table-driven self-test for check-upstream.sh. Run in CI as the
# "selftest" job in .github/workflows/upstream-check.yaml so the gate
# itself is exercised on every change, not just trusted to work.
#
# Strategy: stub `go` with a fake executable on PATH that answers the two
# exact `go list -m -f {{.Version}} ...` invocations the script under test
# makes, driven by FAKE_UPSTREAM / FAKE_PIN. Each case gets its own throwaway
# git repo (never the real repo) with its own tag set, and check-upstream.sh
# is invoked by absolute path with that throwaway repo (or a subdirectory of
# it, or a plain non-repo directory) as the working directory - its own
# `git rev-parse --show-toplevel` / `cd` then resolves relative to wherever
# it was invoked from, not to this checkout.
set -euo pipefail

# Hermetic against ambient git configuration: a caller's ~/.gitconfig (or
# /etc/gitconfig) might set core.hooksPath to something that fails, or
# gpgsign defaults that prompt, or anything else unexpected. None of that
# should be able to affect the throwaway repos this self-test creates and
# destroys, so both config tiers are pointed at /dev/null - here for this
# script's own git calls, and forwarded into run_case's env -i below for
# check-upstream.sh's git calls too.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# Same reasoning for the variables that steer git at a *repository*: with
# GIT_DIR or GIT_WORK_TREE exported in the caller's environment, this
# script's own `git init` for the first throwaway repo dies ("Cannot access
# work tree") and not a single case runs - the developer gets no signal at
# all rather than a failing assertion. Clearing them here cannot weaken the
# decoy cases below, which plant these very variables: run_case rebuilds
# the child environment from scratch with `env -i` and re-supplies whatever
# the case asked for.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/check-upstream.sh"

# The trap is installed after the first mktemp and before the second, so a
# failure of the second cannot leak the first. The ${work_dir:+...} guard
# covers the window in between, where work_dir exists but is still empty.
fake_go_dir="$(mktemp -d)"
work_dir=""
trap 'rm -rf "${fake_go_dir}" ${work_dir:+"${work_dir}"}' EXIT
# Every per-case throwaway repo lives under this one directory instead of
# its own mktemp -d, so a single EXIT trap covers all of them: an abort
# mid-run (a failing case, Ctrl-C, whatever) still leaves nothing behind.
work_dir="$(mktemp -d)"
case_seq=0

cat > "${fake_go_dir}/go" <<'FAKE_GO'
#!/usr/bin/env bash
# Fake `go` for check-upstream_test.sh. Only implements the exact
# `go list -m -f {{.Version}} <module>[@latest]` invocation the script
# under test makes; anything else is a hard error so stub drift is loud.
#
# Every emission is `command printf`, never echo and never a bare printf:
# a case may run this stub under `shopt -s xpg_echo` (see XPG_ECHO in
# run_case), where echo would expand backslash escapes in the injected
# text, or with printf hijacked by an exported shell function (see
# HIJACK_PRINTF), which the stub inherits just as the script under test
# does. Either way the stub would silently deliver something other than
# what the case asked for, and the case would be testing the stub.
set -euo pipefail
if [[ "${1:-}" == "list" && "${2:-}" == "-m" && "${3:-}" == "-f" && "${4:-}" == "{{.Version}}" ]]; then
  target="${5:-}"
  if [[ "${target}" == *"@latest" ]]; then
    if [[ -z "${FAKE_UPSTREAM:-}" ]]; then
      # FAKE_UPSTREAM_ERR lets a test case inject arbitrary (including
      # hostile) stderr text; it defaults to a plain stub-failure message.
      command printf '%s\n' "${FAKE_UPSTREAM_ERR:-go: golang.org/x/sync@latest: module lookup disabled (stub failure: GOPROXY unreachable)}" >&2
      exit 1
    fi
    # FAKE_UPSTREAM_ERR is honoured on the success path too: a real
    # `go list` can write to stderr (a proxy warning, a "downloading ..."
    # note) and still resolve the version. That is the case that proves
    # the script re-truncates its stderr capture file between the two
    # lookups instead of letting the first call's text bleed into the
    # second call's error detail.
    if [[ -n "${FAKE_UPSTREAM_ERR:-}" ]]; then
      command printf '%s\n' "${FAKE_UPSTREAM_ERR}" >&2
    fi
    command printf '%s\n' "${FAKE_UPSTREAM}"
    exit 0
  else
    # EXPECTED_REPO_ROOT, when set, proves the script under test actually
    # `cd`ed to the repo root before this call: the pin lookup only
    # succeeds when invoked from exactly that directory, so a case that
    # invokes check-upstream.sh from a subdirectory only passes if the
    # script's own `cd` moved it back to the root first.
    if [[ -n "${EXPECTED_REPO_ROOT:-}" && "${PWD}" != "${EXPECTED_REPO_ROOT}" ]]; then
      command printf '%s\n' "go: golang.org/x/sync: module lookup failed (stub failure: not invoked from repo root, cwd=${PWD})" >&2
      exit 1
    fi
    if [[ -z "${FAKE_PIN:-}" ]]; then
      command printf '%s\n' "go: golang.org/x/sync: missing go.sum entry (stub failure: broken go.mod)" >&2
      exit 1
    fi
    command printf '%s\n' "${FAKE_PIN}"
    exit 0
  fi
fi
command printf '%s\n' "fake go: unsupported invocation: $*" >&2
exit 127
FAKE_GO
chmod u+x "${fake_go_dir}/go"

failures=0
cases_run=0

# summary_fence_line CONTENT: prints the first line of CONTENT matching
# ^```+$ (an opening or closing fence check-upstream.sh's fail() may have
# written), or nothing if there is none.
summary_fence_line() {
  awk '/^```+$/ { print; exit }' <<<"$1"
}

# summary_outside_fence CONTENT: prints every line of CONTENT that falls
# outside a fenced code block - any fenced block, not just the first one:
# a block runs from a line matching ^```+$ up to, and including, the next
# line exactly equal to that opening fence, and a later fence-shaped line
# opens another block the same way. Used to prove untrusted text a fence
# wraps cannot leak a forged heading or a stray fence marker outside the
# block.
summary_outside_fence() {
  awk '
    BEGIN { in_fence = 0; fence = "" }
    !in_fence && /^```+$/ { fence = $0; in_fence = 1; next }
    in_fence && $0 == fence { in_fence = 0; next }
    in_fence { next }
    { print }
  ' <<<"$1"
}

# summary_fence_count CONTENT: prints how many lines of CONTENT are
# exactly equal to the first fence line found (the opening fence). A
# well-formed fenced block contributes exactly 2 - the opening and the
# closing fence - which is what proves the closing fence was written at
# all. summary_outside_fence structurally cannot see a missing closing
# fence: an unclosed block simply swallows the rest of the file and
# reports nothing outside it. Comparing against the opening fence line
# rather than the ^```+$ shape is deliberate, so that a shorter backtick
# run *inside* the block (attacker text trying to close it early) is not
# miscounted as a fence.
summary_fence_count() {
  awk '
    BEGIN { fence = ""; n = 0 }
    fence == "" && /^```+$/ { fence = $0 }
    fence != "" && $0 == fence { n++ }
    END { print n }
  ' <<<"$1"
}

# run_case NAME UPSTREAM PIN TAGS EXPECT_EXIT MUST_CONTAIN[;...] [GITHUB_ACTIONS] \
#          [SINGLE_ERROR_LINE] [WANT_SUMMARY] [MUST_CONTAIN_SUMMARY[;...]] \
#          [SUMMARY_NO_COLON_LINES] [FAKE_UPSTREAM_ERR] [NO_RAW_CR] \
#          [MUST_NOT_CONTAIN_SUMMARY_OUTSIDE_FENCE[;...]] [FENCE_MIN_BACKTICKS] \
#          [RUN_SUBDIR] [NO_GIT_REPO] [MUST_NOT_CONTAIN[;...]] \
#          [MUST_NOT_CONTAIN_SUMMARY[;...]] [EXPECT_FENCE_LINES] \
#          [GIT_ENV_DECOY_TAGS] [XPG_ECHO] [GIT_ENV_DECOY_MODE] \
#          [HIJACK_PRINTF]
#
# MUST_CONTAIN / MUST_NOT_CONTAIN are checked against the script's combined
# stdout+stderr. GITHUB_ACTIONS is "true", "" or "unset": the empty string
# is still a *set* variable, so only "unset" - which omits the name from
# the environment entirely - exercises the script's `${GITHUB_ACTIONS:-}`
# guard under `set -u`. SINGLE_ERROR_LINE is "true" (exactly one
# ::error:: line and exactly one line starting with "::") or "none" (not a
# single one of either), the latter for the non-Actions branch, which must
# never emit anything annotation-shaped. WANT_SUMMARY
# ("true"/"false"/"unset"/"unwritable") threads a per-case
# GITHUB_STEP_SUMMARY file through the run ("unset"
# omits the variable from the environment entirely, rather than pointing
# it at a file; "unwritable" points it at a path under a directory that
# does not exist, so the append fails and only the script's `|| true`
# keeps the verdict from flipping); MUST_CONTAIN_SUMMARY,
# MUST_NOT_CONTAIN_SUMMARY, SUMMARY_NO_COLON_LINES, EXPECT_FENCE_LINES and
# MUST_NOT_CONTAIN_SUMMARY_OUTSIDE_FENCE then assert against that file's
# contents (the last via summary_outside_fence, above). FENCE_MIN_BACKTICKS,
# when set, asserts the first fence line in the summary is at least that
# many backticks long, and that no fence-shaped line leaked outside the
# block; EXPECT_FENCE_LINES asserts the exact number of lines equal to that
# opening fence (2 for a well-formed block: opening and closing).
# FAKE_UPSTREAM_ERR is the fake `go`'s stderr for the upstream lookup, on
# both its failure and its success path, for testing how hostile or merely
# stale stderr text is handled. NO_RAW_CR asserts the script's output
# contains no literal carriage return. RUN_SUBDIR, when set, invokes
# check-upstream.sh from that subdirectory of the throwaway repo instead of
# its root. NO_GIT_REPO ("true") skips creating a git repo altogether, so
# the throwaway directory is just a plain directory. GIT_ENV_DECOY_TAGS,
# when set, builds a second repository carrying those tags and points the
# GIT_ENV_DECOY_MODE variable ("GIT_DIR", the default, or "GIT_WORK_TREE")
# at it, so a case can prove the script inspects the checkout it is
# standing in rather than whatever the environment steers git at.
# XPG_ECHO ("true") starts the script under `shopt -s xpg_echo`, where the
# `echo` builtin expands backslash escapes. HIJACK_PRINTF ("true") exports
# a shell function named printf into the run, which bash imports and which
# a bare `printf` would resolve to ahead of the builtin.
#
# Two assertions are unconditional rather than parameterised, because they
# should hold for every case: a WANT_SUMMARY=true file is pre-seeded with a
# sentinel line that must still be there afterwards (the script appends,
# never truncates), and TMPDIR points at a per-case directory that must be
# empty afterwards (the script removes its mktemp'd stderr capture file on
# exit).
run_case() {
  local name="$1" upstream="$2" pin="$3" tags="$4" expect_exit="$5"
  local must_contain="${6:-}" gha="${7:-}" single_error_line="${8:-false}"
  local want_summary="${9:-false}" must_contain_summary="${10:-}"
  local summary_no_colon_lines="${11:-false}" fake_upstream_err="${12:-}"
  local no_raw_cr="${13:-false}"
  local must_not_contain_summary_outside_fence="${14:-}" fence_min_backticks="${15:-}"
  local run_subdir="${16:-}" no_git_repo="${17:-false}" must_not_contain="${18:-}"
  local must_not_contain_summary="${19:-}" expect_fence_lines="${20:-}"
  local git_env_decoy_tags="${21:-}" xpg_echo="${22:-false}"
  local git_env_decoy_mode="${23:-GIT_DIR}" hijack_printf="${24:-false}"

  case_seq=$((case_seq + 1))
  local tmp_repo="${work_dir}/case-${case_seq}"
  mkdir -p "${tmp_repo}"

  local repo_root_real=""
  if [[ "${no_git_repo}" != "true" ]]; then
    git -C "${tmp_repo}" init -q
    git -C "${tmp_repo}" -c user.name="upstream-check-test" -c user.email="upstream-check-test@example.invalid" -c commit.gpgsign=false commit --allow-empty -q -m "init"

    local tag
    for tag in ${tags}; do
      git -C "${tmp_repo}" -c tag.gpgsign=false tag "${tag}"
    done

    repo_root_real="$(git -C "${tmp_repo}" rev-parse --show-toplevel)"
  fi

  # A second, unrelated repository whose tags are planted to look aligned,
  # pointed at by one of the GIT_* steering variables. git resolves which
  # repository to operate on from the environment before it looks at the
  # working directory, so unless the script under test clears those
  # variables, this decoy's tags are what `git tag -l` reports - a forged
  # pass with no aligned tag anywhere in the real checkout. The two
  # variables get there by different routes, which is why both are worth a
  # case: GIT_DIR leaves the working directory alone and only swaps the tag
  # store, while GIT_WORK_TREE moves `git rev-parse --show-toplevel` onto
  # the decoy, so the script `cd`s into it and reads its tags from there.
  # The other four the script clears (GIT_COMMON_DIR, GIT_INDEX_FILE,
  # GIT_OBJECT_DIRECTORY, GIT_CEILING_DIRECTORIES) are inert for these two
  # git calls - clearing them is still right, but a case for them would
  # assert nothing.
  local decoy_git_dir=""
  if [[ -n "${git_env_decoy_tags}" ]]; then
    local decoy_repo="${work_dir}/decoy-${case_seq}"
    mkdir -p "${decoy_repo}"
    git -C "${decoy_repo}" init -q
    git -C "${decoy_repo}" -c user.name="upstream-check-test" -c user.email="upstream-check-test@example.invalid" -c commit.gpgsign=false commit --allow-empty -q -m "init"
    local decoy_tag
    for decoy_tag in ${git_env_decoy_tags}; do
      git -C "${decoy_repo}" -c tag.gpgsign=false tag "${decoy_tag}"
    done
    if [[ "${git_env_decoy_mode}" == "GIT_WORK_TREE" ]]; then
      decoy_git_dir="${decoy_repo}"
      # The stub's "was I called from the repo root?" check has to stand
      # down for this one: the attack's whole point is to move the script's
      # working directory, so with the hardening removed the stub would
      # abort the pin lookup and mask the forged PASS behind a stub
      # failure. Leaving it off makes the unhardened outcome the real one
      # (rc=0, decoy tag reported as aligned); the `cd` behaviour itself is
      # covered by the run-from-a-subdirectory case.
      repo_root_real=""
    else
      decoy_git_dir="${decoy_repo}/.git"
    fi
  fi

  local invoke_dir="${tmp_repo}"
  if [[ -n "${run_subdir}" ]]; then
    invoke_dir="${tmp_repo}/${run_subdir}"
    mkdir -p "${invoke_dir}"
  fi

  local summary_file="${tmp_repo}/step-summary.md"
  local summary_target="/dev/null"
  # A step summary file in a real job is never empty when this script runs
  # - earlier steps have already appended to it. Seeding a sentinel line
  # reproduces that, so a `>` in place of `>>` in the script under test is
  # a caught mutation rather than an invisible one (every case would
  # otherwise start from an empty file, where truncating and appending look
  # identical). The sentinel is deliberately fence-free, colon-free and
  # heading-free so it cannot disturb any other summary assertion.
  local summary_sentinel="<!-- pre-existing step summary content -->"
  if [[ "${want_summary}" == "true" ]]; then
    printf '%s\n' "${summary_sentinel}" > "${summary_file}"
    summary_target="${summary_file}"
  elif [[ "${want_summary}" == "unwritable" ]]; then
    # A path under a directory that does not exist: the append redirection
    # itself fails, which is the condition the script's `|| true` exists
    # for. Nothing is created, so there is nothing to assert on afterwards
    # beyond the exit code.
    summary_target="${tmp_repo}/no-such-dir/step-summary.md"
  fi

  # Per-case TMPDIR: `env -i` drops the ambient one, so without this the
  # script's own `mktemp` lands in the shared /tmp where a leaked file is
  # indistinguishable from anyone else's. Pointed at a directory of its
  # own, "is this directory empty afterwards?" becomes a precise assertion
  # that the script's EXIT trap ran.
  local case_tmp="${tmp_repo}/tmp"
  mkdir -p "${case_tmp}"

  local env_args=(
    PATH="${fake_go_dir}:${PATH}"
    # A caller can legitimately have no HOME (this suite run under
    # `env -i`, a minimal container): under `set -u` a bare ${HOME} would
    # abort the whole run before the first case, which is the same
    # no-signal-at-all failure the GIT_* unset above exists to prevent.
    # The throwaway work_dir is a real, writable stand-in; git never reads
    # a config out of it anyway, GIT_CONFIG_GLOBAL being /dev/null.
    HOME="${HOME:-${work_dir}}"
    GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL}"
    GIT_CONFIG_SYSTEM="${GIT_CONFIG_SYSTEM}"
    FAKE_UPSTREAM="${upstream}"
    FAKE_PIN="${pin}"
    FAKE_UPSTREAM_ERR="${fake_upstream_err}"
    EXPECTED_REPO_ROOT="${repo_root_real}"
    TMPDIR="${case_tmp}"
  )
  if [[ -n "${decoy_git_dir}" ]]; then
    env_args+=("${git_env_decoy_mode}=${decoy_git_dir}")
  fi
  # bash enables every shell option named in BASHOPTS before it reads the
  # script, so this is a caller-controlled setting the script cannot see
  # coming. xpg_echo is the dangerous one here: it makes the `echo` builtin
  # interpret backslash escapes, which would re-expand a literal two-
  # character "\n" in untrusted text back into a real newline - after the
  # annotation escaping has already run.
  if [[ "${xpg_echo}" == "true" ]]; then
    env_args+=("BASHOPTS=xpg_echo")
  fi
  # bash imports a function definition from any environment entry named
  # BASH_FUNC_<name>%%, so an exported function in whatever invoked the
  # workflow step becomes a function of that name inside the script. This
  # one answers every call with a forged annotation line, which is what a
  # bare `printf` would run instead of the builtin.
  if [[ "${hijack_printf}" == "true" ]]; then
    env_args+=('BASH_FUNC_printf%%=() { builtin printf "::error::FORGED-BY-EXPORTED-FUNCTION\n"; }')
  fi
  if [[ "${gha}" != "unset" ]]; then
    env_args+=("GITHUB_ACTIONS=${gha}")
  fi
  if [[ "${want_summary}" != "unset" ]]; then
    env_args+=("GITHUB_STEP_SUMMARY=${summary_target}")
  fi

  local output rc
  set +e
  output="$(cd "${invoke_dir}" && env -i "${env_args[@]}" "${script_path}" 2>&1)"
  rc=$?
  set -e

  local ok=true
  local reason=""

  if [[ "${rc}" -ne "${expect_exit}" ]]; then
    ok=false
    reason="exit=${rc} expected=${expect_exit}"
  fi

  if [[ -n "${must_contain}" ]]; then
    local saved_ifs="${IFS}"
    IFS=';'
    local pat
    for pat in ${must_contain}; do
      IFS="${saved_ifs}"
      if [[ -n "${pat}" ]] && [[ "${output}" != *"${pat}"* ]]; then
        ok=false
        reason="${reason} missing:[${pat}]"
      fi
    done
    IFS="${saved_ifs}"
  fi

  if [[ -n "${must_not_contain}" ]]; then
    local saved_ifs4="${IFS}"
    IFS=';'
    local npat2
    for npat2 in ${must_not_contain}; do
      IFS="${saved_ifs4}"
      if [[ -n "${npat2}" ]] && [[ "${output}" == *"${npat2}"* ]]; then
        ok=false
        reason="${reason} output-has:[${npat2}]"
      fi
    done
    IFS="${saved_ifs4}"
  fi

  if [[ "${single_error_line}" == "true" || "${single_error_line}" == "none" ]]; then
    local expected_error_lines=1
    if [[ "${single_error_line}" == "none" ]]; then
      expected_error_lines=0
    fi
    local error_lines colon_lines
    error_lines="$(printf '%s\n' "${output}" | command grep -c '^::error::' || true)"
    colon_lines="$(printf '%s\n' "${output}" | command grep -c '^::' || true)"
    if [[ "${error_lines}" -ne "${expected_error_lines}" ]]; then
      ok=false
      reason="${reason} error-lines=${error_lines} expected=${expected_error_lines}"
    fi
    if [[ "${colon_lines}" -ne "${expected_error_lines}" ]]; then
      ok=false
      reason="${reason} colon-lines=${colon_lines} expected=${expected_error_lines}"
    fi
  fi

  if [[ "${no_raw_cr}" == "true" ]]; then
    local cr_count
    cr_count="$(printf '%s' "${output}" | command grep -c $'\r' || true)"
    if [[ "${cr_count}" -ne 0 ]]; then
      ok=false
      reason="${reason} raw-cr-lines=${cr_count}"
    fi
  fi

  # The script mktemps a file to capture `go list` stderr and removes it
  # from an EXIT trap. Every exit path is covered by some case, so an empty
  # per-case TMPDIR here is the assertion that the trap exists and fires.
  local tmp_leftovers
  tmp_leftovers="$(find "${case_tmp}" -mindepth 1 | command grep -c . || true)"
  if [[ "${tmp_leftovers}" -ne 0 ]]; then
    ok=false
    reason="${reason} tmpdir-leftovers=${tmp_leftovers}"
  fi

  if [[ "${want_summary}" == "true" ]]; then
    local summary_content
    summary_content="$(cat "${summary_file}" 2>/dev/null || true)"

    if [[ "${summary_content}" != *"${summary_sentinel}"* ]]; then
      ok=false
      reason="${reason} summary-sentinel-lost"
    fi

    if [[ -n "${must_contain_summary}" ]]; then
      local saved_ifs2="${IFS}"
      IFS=';'
      local spat
      for spat in ${must_contain_summary}; do
        IFS="${saved_ifs2}"
        if [[ -n "${spat}" ]] && [[ "${summary_content}" != *"${spat}"* ]]; then
          ok=false
          reason="${reason} summary-missing:[${spat}]"
        fi
      done
      IFS="${saved_ifs2}"
    fi

    if [[ -n "${must_not_contain_summary}" ]]; then
      local saved_ifs5="${IFS}"
      IFS=';'
      local snpat
      for snpat in ${must_not_contain_summary}; do
        IFS="${saved_ifs5}"
        if [[ -n "${snpat}" ]] && [[ "${summary_content}" == *"${snpat}"* ]]; then
          ok=false
          reason="${reason} summary-has:[${snpat}]"
        fi
      done
      IFS="${saved_ifs5}"
    fi

    if [[ "${summary_no_colon_lines}" == "true" ]]; then
      local colon_lines2
      colon_lines2="$(printf '%s\n' "${summary_content}" | command grep -c '^::' || true)"
      if [[ "${colon_lines2}" -ne 0 ]]; then
        ok=false
        reason="${reason} summary-colon-lines=${colon_lines2}"
      fi
    fi

    local outside=""
    outside="$(summary_outside_fence "${summary_content}")"

    if [[ -n "${must_not_contain_summary_outside_fence}" ]]; then
      local saved_ifs3="${IFS}"
      IFS=';'
      local npat
      for npat in ${must_not_contain_summary_outside_fence}; do
        IFS="${saved_ifs3}"
        if [[ -n "${npat}" ]] && [[ "${outside}" == *"${npat}"* ]]; then
          ok=false
          reason="${reason} outside-fence-has:[${npat}]"
        fi
      done
      IFS="${saved_ifs3}"
    fi

    if [[ -n "${fence_min_backticks}" ]]; then
      local fence_line fence_len stray_fence
      fence_line="$(summary_fence_line "${summary_content}")"
      fence_len=${#fence_line}
      if [[ "${fence_len}" -lt "${fence_min_backticks}" ]]; then
        ok=false
        reason="${reason} fence-len=${fence_len} expected>=${fence_min_backticks}"
      fi
      stray_fence="$(summary_fence_line "${outside}")"
      if [[ -n "${stray_fence}" ]]; then
        ok=false
        reason="${reason} stray-fence-outside=[${stray_fence}]"
      fi
    fi

    if [[ -n "${expect_fence_lines}" ]]; then
      local fence_lines
      fence_lines="$(summary_fence_count "${summary_content}")"
      if [[ "${fence_lines}" -ne "${expect_fence_lines}" ]]; then
        ok=false
        reason="${reason} fence-lines=${fence_lines} expected=${expect_fence_lines}"
      fi
    fi
  fi

  cases_run=$((cases_run + 1))
  if [[ "${ok}" == "true" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} (${reason})"
    echo "--- output ---"
    echo "${output}"
    echo "--------------"
    failures=$((failures + 1))
  fi
}

run_case "aligned" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned"

run_case "pin behind upstream" \
  "v0.22.0" "v0.21.0" "v0.22.0" 1 \
  "go.mod pins golang.org/x/sync@v0.21.0"

run_case "tag behind upstream, pin aligned" \
  "v0.22.0" "v0.22.0" "v0.21.0" 1 \
  "newest repo tag is v0.21.0"

# The realistic alarm state: upstream published, nothing here has caught
# up yet. It is also the only case that pins which two values the tag
# comparison uses - with only the single-reason cases above, comparing the
# newest tag against the go.mod pin instead of against upstream produces
# the same verdict everywhere and goes unnoticed. Here the tag equals the
# pin, so that mistake drops the tag reason entirely.
run_case "pin behind and tag behind at once" \
  "v0.23.0" "v0.22.0" "v0.22.0" 1 \
  "go.mod pins golang.org/x/sync@v0.22.0, but upstream latest is v0.23.0;newest repo tag is v0.22.0, which is older than upstream v0.23.0" \
  "" "false" \
  "true" "### Upstream check: FAIL;has moved to \`v0.23.0\`;- go.mod pins golang.org/x/sync@v0.22.0, but upstream latest is v0.23.0;- newest repo tag is v0.22.0, which is older than upstream v0.23.0"

run_case "no tags at all" \
  "v0.22.0" "v0.22.0" "" 1 \
  "No release tags"

run_case "pre-release tag excluded from candidates" \
  "v0.23.0" "v0.23.0" "v0.22.0 v0.23.0-rc.1" 1 \
  "newest repo tag is v0.22.0"

run_case "non-semver tags excluded from candidates" \
  "v0.23.0" "v0.23.0" "v0.22.0 vendor-pin v-experimental" 1 \
  "newest repo tag is v0.22.0"

run_case "non-v tags ignored, aligned still passes" \
  "v0.22.0" "v0.22.0" "v0.22.0 latest release-2026" 0 \
  "OK: go.mod pin and newest tag are aligned"

run_case "repo tag ahead of upstream" \
  "v0.22.0" "v0.22.0" "v0.99.0" 0 \
  "OK: go.mod pin and newest tag are aligned"

run_case "upstream lookup failure surfaces stub stderr" \
  "" "v0.22.0" "v0.22.0" 1 \
  "stub failure"

run_case "both reasons collapse into one ::error:: annotation" \
  "v0.23.0" "v0.21.0" "v0.20.0" 1 \
  "go.mod pins;newest repo tag is;%0A" "true" "true"

run_case "multi-tag ordering" \
  "v0.10.0" "v0.10.0" "v0.9.0 v0.10.0" 0 \
  "OK: go.mod pin and newest tag are aligned"

run_case "patch ordering is numeric" \
  "v0.22.10" "v0.22.10" "v0.22.9" 1 \
  "older than upstream"

run_case "two-component tag excluded" \
  "v0.23.0" "v0.23.0" "v0.22.0 v0.24" 1 \
  "newest repo tag is v0.22.0"

run_case "pin lookup failure" \
  "v0.22.0" "" "v0.22.0" 1 \
  "Could not determine the go.mod pin"

run_case "step summary PASS" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "" "false" \
  "true" "### Upstream check: PASS"

run_case "step summary FAIL" \
  "" "v0.22.0" "v0.22.0" 1 \
  "Could not determine the latest published version" "" "false" \
  "true" "### Upstream check: FAIL;\`\`\`;attacker-controlled stderr should not forge a heading" "true" \
  $'### Upstream check: PASS\nattacker-controlled stderr should not forge a heading' \
  "false" "### Upstream check: PASS" "" "" "" "" "" \
  "2"

run_case "step summary fence sized past embedded backticks" \
  "" "v0.22.0" "v0.22.0" 1 \
  "Could not determine the latest published version" "" "false" \
  "true" "### Upstream check: FAIL;### Upstream check: PASS" "false" \
  $'```\n### Upstream check: PASS\nmore attacker text after the fake fence' \
  "false" "### Upstream check: PASS" "4" "" "" "" "" \
  "2"

run_case "GITHUB_STEP_SUMMARY unset" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "" "false" \
  "unset"

run_case "annotation escapes CR and percent" \
  "" "v0.22.0" "v0.22.0" 1 \
  "%25;%0D;%0A" "true" "true" \
  "false" "" "false" \
  $'100% done\r\n::add-mask::x' "true"

run_case "runs from a subdirectory of the repo" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 "OK: go.mod pin and newest tag are aligned" \
  "" "false" "false" "" "false" "" "false" "" "" \
  "sub" ""

run_case "fails closed outside a git repository" \
  "v0.22.0" "v0.22.0" "" 1 "Not inside a git repository" \
  "" "false" "false" "" "false" "" "false" "" "" \
  "" "true"

run_case "upstream version from proxy is not valid semver" \
  "not-a-version" "v0.22.0" "v0.22.0" 1 "not a valid semver" \
  "" "false" "true" "not a valid semver" "false" "" "false" \
  "not-a-version" "" "" "" \
  "not-a-version"

run_case "go.mod pin is not valid semver" \
  "v0.22.0" "not-a-version" "v0.22.0" 1 "not a valid semver" \
  "" "false" "true" "not a valid semver" "false" "" "false" \
  "not-a-version" "" "" "" \
  "not-a-version"

# The PASS path deserves the same scrutiny as the FAIL path: it is the
# outcome that lets a release through, so anything it emits (or must not
# emit) is worth pinning down. Nothing here may look like an annotation or
# like a reason line - SINGLE_ERROR_LINE asserts exactly one ::error::
# line and so cannot express "none at all".
run_case "PASS under GITHUB_ACTIONS emits no annotation" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "true" "false" \
  "true" "### Upstream check: PASS" "false" "" "false" "" "" \
  "" "" "::error::;go.mod pins;newest repo tag is;has not caught up" \
  "### Upstream check: FAIL"

# The operator-facing log is the only place the three compared values are
# printed side by side, so a change that silently stops printing one of
# them (or prints the wrong variable) should be caught here. The tag is
# deliberately ahead of upstream so all three values differ and no
# assertion can be satisfied by the wrong one. The expected padding is
# part of the assertion: the values are meant to line up in one column.
run_case "PASS logs upstream, pin and tag" \
  "v0.22.0" "v0.22.0" "v0.99.0" 0 \
  "Upstream golang.org/x/sync: v0.22.0;go.mod pin:                 v0.22.0;Newest repo tag:            v0.99.0"

# GITHUB_ACTIONS absent from the environment entirely, not merely empty:
# under `set -u` a bare ${GITHUB_ACTIONS} would abort log_error before it
# prints anything, so the assertion is that the full reason still reaches
# stderr in plain form.
run_case "GITHUB_ACTIONS absent falls back to plain stderr" \
  "v0.23.0" "v0.21.0" "v0.20.0" 1 \
  "ERROR: Upstream golang.org/x/sync has moved to v0.23.0" "unset" "false" \
  "false" "" "false" "" "false" "" "" \
  "" "" "::error::"

# An unwritable GITHUB_STEP_SUMMARY (here: a path under a directory that
# does not exist) is an environment defect, not a verdict. The inputs are
# aligned, so the run must still exit 0 - only the `|| true` on the append
# keeps it that way.
run_case "unwritable step summary does not flip the verdict" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "" "false" \
  "unwritable"

# Both halves of the semver gate's `$` anchor: extra components and
# trailing junk. Without the anchor each of these is accepted as a valid
# version and flows on into the comparisons.
run_case "upstream version with a fourth component rejected" \
  "v0.22.0.1" "v0.22.0" "v0.22.0" 1 \
  "Upstream version reported by the Go proxy is not a valid semver string"

run_case "upstream version with trailing junk rejected" \
  "v0.22.0junk" "v0.22.0" "v0.22.0" 1 \
  "Upstream version reported by the Go proxy is not a valid semver string"

# The other direction: the pre-release and build-metadata alternatives in
# the regex are real requirements, not decoration. A pre-release upstream
# version must pass the shape gate and be compared like any other (the tag
# here is far ahead, so the verdict does not depend on how `sort -V`
# orders a pre-release against its own release).
run_case "pre-release upstream version is not rejected" \
  "v0.23.0-rc.1" "v0.23.0-rc.1" "v0.99.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "" "false" \
  "false" "" "false" "" "false" "" "" \
  "" "" "not a valid semver"

run_case "build-metadata upstream version is not rejected" \
  "v0.23.0+build.5" "v0.23.0+build.5" "v0.99.0" 0 \
  "OK: go.mod pin and newest tag are aligned" "" "false" \
  "false" "" "false" "" "false" "" "" \
  "" "" "not a valid semver"

# The stderr capture file is reused across the two `go list` calls. Here
# the first call writes to stderr and still succeeds, then the second
# fails: without the truncation between them, the first call's text would
# be reported as the second call's error detail.
run_case "stale upstream stderr does not bleed into the pin failure" \
  "v0.22.0" "" "v0.22.0" 1 \
  "Could not determine the go.mod pin;stub failure: broken go.mod" "" "false" \
  "false" "" "false" \
  "go: downloading golang.org/x/sync (stub warning on a successful lookup)" \
  "false" "" "" \
  "" "" "stub warning on a successful lookup"

# An inherited GIT_DIR must not be able to answer the tag question. The
# decoy repo carries a tag that would satisfy the check outright; the real
# checkout does not, so the run must still fail with the real repo's
# newest tag named in the reason.
run_case "inherited GIT_DIR cannot forge the tag verdict" \
  "v0.23.0" "v0.23.0" "v0.22.0" 1 \
  "newest repo tag is v0.22.0, which is older than upstream v0.23.0" "" "false" \
  "false" "" "false" "" "false" "" "" \
  "" "" "v9.9.9" \
  "" "" \
  "v9.9.9"

# The same forgery by the other route. GIT_WORK_TREE does not swap the tag
# store directly - it moves what `git rev-parse --show-toplevel` reports,
# so the script `cd`s into the decoy and reads its tags from there. Without
# the unset this run reports the decoy's v9.9.9 as the newest tag and exits
# 0; the real checkout's v0.22.0 must be what shows up in the reason
# instead, and v9.9.9 must appear nowhere in the output.
run_case "inherited GIT_WORK_TREE cannot forge the tag verdict" \
  "v0.23.0" "v0.23.0" "v0.22.0" 1 \
  "newest repo tag is v0.22.0, which is older than upstream v0.23.0" "" "false" \
  "false" "" "false" "" "false" "" "" \
  "" "" "v9.9.9" \
  "" "" \
  "v9.9.9" "false" \
  "GIT_WORK_TREE"

# Same hostile stderr as the escaping case above, but carrying a literal
# two-character "\n" and run under xpg_echo. The escaping pass cannot help
# here - it never sees a newline - so the only thing keeping the forged
# "::add-mask::" off a line of its own is that both emitters use printf
# rather than echo. Asserted on both surfaces: exactly one "::" line in
# the annotation output, and the untrusted text still one unbroken line in
# the step summary.
run_case "xpg_echo cannot re-expand escapes in untrusted text" \
  "" "v0.22.0" "v0.22.0" 1 \
  "Could not determine the latest published version" "true" "true" \
  "true" "warning: a\n::add-mask::x" "true" \
  "warning: a\n::add-mask::x" \
  "false" "" "" \
  "" "" "" \
  "" "2" \
  "" "true"

# The other branch of log_error, which a case with GITHUB_ACTIONS set can
# never reach. Plain stderr is not annotation-shaped, so nothing here may
# start with "::" at all - SINGLE_ERROR_LINE="none" is the assertion for
# that, and the payload has to stay on the single line it arrived on.
run_case "xpg_echo cannot split the plain stderr message either" \
  "" "v0.22.0" "v0.22.0" 1 \
  "ERROR: Could not determine the latest published version;warning: a\n::add-mask::PWNED" "unset" "none" \
  "false" "" "false" \
  "warning: a\n::add-mask::PWNED" \
  "false" "" "" \
  "" "" "" \
  "" "" \
  "" "true"

# An exported shell function named printf, imported by bash from
# BASH_FUNC_printf%% in the environment, answers every call with a forged
# annotation. A bare `printf` resolves to it ahead of the builtin, so with
# one this run would print nothing but forged lines - not only in the
# annotation and the summary, but in the comparisons the verdict is built
# from. `command printf` is what keeps the real message, the real reasons
# and the real exit code intact.
run_case "an exported printf function cannot hijack the output" \
  "v0.23.0" "v0.22.0" "v0.22.0" 1 \
  "::error::Upstream golang.org/x/sync has moved to v0.23.0;go.mod pins golang.org/x/sync@v0.22.0;newest repo tag is v0.22.0" "true" "true" \
  "true" "### Upstream check: FAIL;- newest repo tag is v0.22.0" "false" "" "false" "" "" \
  "" "" "FORGED-BY-EXPORTED-FUNCTION" \
  "FORGED-BY-EXPORTED-FUNCTION" "" \
  "" "false" \
  "GIT_DIR" "true"

# The same hijack against the PASS path, which is where it does the real
# damage: the verdict itself is computed through printf (the two versions
# are sorted by piping them into `sort -V`), so a hijacked one turns an
# aligned repo into a spurious alarm - and, with a less blunt function
# than this one, an unaligned repo into a pass. Nothing forged may reach
# the operator log, the summary or the exit code.
run_case "an exported printf function cannot forge the verdict" \
  "v0.22.0" "v0.22.0" "v0.22.0" 0 \
  "OK: go.mod pin and newest tag are aligned;Newest repo tag:            v0.22.0" "true" "none" \
  "true" "### Upstream check: PASS" "false" "" "false" "" "" \
  "" "" "FORGED-BY-EXPORTED-FUNCTION" \
  "FORGED-BY-EXPORTED-FUNCTION" "" \
  "" "false" \
  "GIT_DIR" "true"

# The script caps the untrusted detail at 4096 characters rather than
# trusting the Go toolchain to keep its stderr short. 5000 characters of
# filler between two markers: the head marker must survive, the tail
# marker must not, on both the annotation and the summary.
run_case "oversized go list stderr is truncated" \
  "" "v0.22.0" "v0.22.0" 1 \
  "detail-head-marker" "" "false" \
  "true" "detail-head-marker" "false" \
  "detail-head-marker$(printf 'x%.0s' {1..5000})detail-tail-marker" \
  "false" "" "" \
  "" "" "detail-tail-marker" \
  "detail-tail-marker" "2"

echo
echo "${cases_run} case(s) run, ${failures} failure(s)."
if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi

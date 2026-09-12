#!/usr/bin/env bash
#
# Self-contained, cross-platform benchmark: download this ONE file to each
# machine you want to test (Ubuntu/Intel, Apple Silicon, AMD, ...) and run
# it there -- no other files needed, everything (all PHP helper scripts)
# is embedded below as heredocs.
#
# It ALWAYS compares two live sources, fetched fresh on every run (no
# pinned commit, no embedded patch file):
#   - baseline:   the current tip of php/php-src's master branch
#   - contender:  the current tip of adapik/php-src's perf/json-sse2-escape
#                 branch (https://github.com/adapik/php-src/tree/perf/json-sse2-escape),
#                 a SIMD (SSE2/NEON) fast path for JSON string escaping
# Both are built and benchmarked identically; only the source differs.
# Since both branches move, re-running later re-tests whatever each branch
# looks like at that moment -- see env.txt / the report header for the
# exact commit SHAs actually used on a given run.
#
# By default this builds and runs EVERYTHING inside a Docker container
# (ubuntu:24.04 + apt-installed toolchain), the same way every number in
# the original report was produced. That keeps the comparison apples-to-
# apples across an Ubuntu/Intel box, an AMD box, and a Mac -- same base
# image, same package versions, same libc, same kernel-visible behavior --
# with the only real variable being the host CPU (Docker Desktop on Apple
# Silicon runs genuine arm64 Linux containers, not emulated x86). It also
# sidesteps every native-toolchain difference (Homebrew vs apt package
# names, BSD vs GNU libtool, etc.) since the container recipe is identical
# everywhere Docker runs. Set USE_DOCKER=0 to build natively instead (needs
# autoconf/automake/libtool/bison/re2c/pkg-config/a C compiler on the host).
#
# Usage (download-and-run, on any Linux/macOS machine with Docker):
#   curl -fsSL <url-to-this-file> -o cross_cpu_bench.sh
#   chmod +x cross_cpu_bench.sh
#   ./cross_cpu_bench.sh                     # default: build+run in Docker, always fetches fresh master + fork branch
#   FORK_REF=some-other-branch ./cross_cpu_bench.sh   # compare master against a different branch/tag/commit of FORK_REPO
#   BASE_REF=some-tag ./cross_cpu_bench.sh   # compare a different baseline ref instead of master
#   CC=clang ./cross_cpu_bench.sh            # build with a different compiler
#   CFLAGS="-O3" ./cross_cpu_bench.sh        # build with different optimization
#   TRIALS=15 ./cross_cpu_bench.sh           # more trials for tighter error bars
#   USE_DOCKER=0 ./cross_cpu_bench.sh        # build natively on this host instead
#
# Output: ./cross-cpu-results/<hostname>_<os>_<arch>_<timestamp>/
#   REPORT.md, env.txt, plus all raw correctness/timing data.
#
set -euo pipefail

# ============================================================================
# Configuration (all env-overridable)
# ============================================================================
# Baseline: always the tip of php-src's own master branch (fetched fresh
# every run -- never pinned to a fixed commit).
BASE_REPO="${BASE_REPO:-https://github.com/php/php-src.git}"
BASE_REF="${BASE_REF:-master}"
# Contender: always the tip of the fork branch under test (also fetched
# fresh every run).
FORK_REPO="${FORK_REPO:-https://github.com/adapik/php-src.git}"
FORK_REF="${FORK_REF:-perf/json-sse2-escape}"
WORKDIR="${WORKDIR:-$PWD/cross-cpu-bench-work}"
OUT_BASE="${OUT_BASE:-$PWD/cross-cpu-results}"
CORE="${CORE:-}"                              # CPU core to taskset to (Linux only); empty = auto-pick from this process's own allowed-CPU set
TRIALS="${TRIALS:-7}"
# CC / CFLAGS: leave unset to use the container/host's default compiler and
# php-src's own default release flags (gcc -O2 on the ubuntu:24.04 image
# used by the Docker path). Override to test a different compiler/level.
CC_OVERRIDE="${CC:-}"
CFLAGS_OVERRIDE="${CFLAGS:-}"
CONFIGURE_EXTRA="${CONFIGURE_EXTRA:-}"

USE_DOCKER="${USE_DOCKER:-1}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:24.04}"
DOCKER_CPUSET="${DOCKER_CPUSET:-}"            # e.g. "2,3"; empty = let Docker decide, letting the container roam every CPU makes noisy-neighbor contention on a busy host easy to mistake for a real regression

log() { printf '\n== %s ==\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ============================================================================
# Docker outer wrapper: builds/reuses a container with the toolchain, copies
# this script in, re-runs this same script INSIDE the container (as the
# "inner" run below, which clones BASE_REPO/BASE_REF and FORK_REPO/FORK_REF
# itself), then copies the results back out to the host. Skipped entirely if
# USE_DOCKER=0, or if we're already the inner invocation (INSIDE_CONTAINER=1).
# ============================================================================
if [[ "$USE_DOCKER" == "1" && -z "${INSIDE_CONTAINER:-}" ]]; then
    command -v docker >/dev/null 2>&1 || die "USE_DOCKER=1 (default) but 'docker' was not found on this machine. Install Docker (or Docker Desktop on macOS), or set USE_DOCKER=0 to build natively -- that needs autoconf/automake/libtool/bison/re2c/pkg-config/a C compiler on this host directly."

    HOST_TAG="$(hostname 2>/dev/null || echo host)_$(uname -s)_$(uname -m)"
    CONTAINER_NAME="${CONTAINER_NAME:-json-sse2-bench-$(echo "$HOST_TAG" | tr -c 'A-Za-z0-9' '-')}"

    log "Docker mode: preparing container '$CONTAINER_NAME' ($DOCKER_IMAGE)"
    if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        RUN_ARGS=(-d --name "$CONTAINER_NAME")
        if [[ -n "$DOCKER_CPUSET" ]]; then
            RUN_ARGS+=(--cpuset-cpus="$DOCKER_CPUSET")
        fi
        docker run "${RUN_ARGS[@]}" "$DOCKER_IMAGE" sleep infinity >/dev/null
    elif [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
        docker start "$CONTAINER_NAME" >/dev/null
    fi

    # Idempotent: only installs if something's missing, so re-runs are fast.
    if ! docker exec "$CONTAINER_NAME" bash -c 'command -v autoconf && command -v bison && command -v re2c && command -v libtoolize && command -v cc' >/dev/null 2>&1; then
        log "Installing build toolchain in the container (first run only)"
        docker exec "$CONTAINER_NAME" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential autoconf automake libtool bison re2c pkg-config git ca-certificates >/dev/null'
        if [[ -n "$CC_OVERRIDE" && "$CC_OVERRIDE" == clang* ]]; then
            docker exec "$CONTAINER_NAME" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang >/dev/null'
        fi
    fi

    docker exec "$CONTAINER_NAME" mkdir -p /work /out
    docker cp "$0" "$CONTAINER_NAME:/work/cross_cpu_bench.sh"

    log "Running the benchmark inside the container"
    # IMPORTANT: only pass CC/CFLAGS/CONFIGURE_EXTRA through when the user
    # actually set them. `docker exec -e CFLAGS=` with an empty value still
    # sets CFLAGS to the empty string (not unset) in the child environment,
    # and autoconf's `: ${CFLAGS=-g -O2 ...}` convention treats an
    # already-set (even empty) CFLAGS as "the user chose this" and skips
    # its own default -- silently producing an unoptimized (-O0) build that
    # makes both binaries look many times slower without changing whether
    # SSE2 code is present at all. Always pass these unset unless non-empty.
    EXEC_ENV=(
        -e INSIDE_CONTAINER=1
        -e BASE_REPO="$BASE_REPO"
        -e BASE_REF="$BASE_REF"
        -e FORK_REPO="$FORK_REPO"
        -e FORK_REF="$FORK_REF"
        -e WORKDIR="/work/run"
        -e OUT_BASE="/out"
        -e CORE="$CORE"
        -e TRIALS="$TRIALS"
        -e USE_DOCKER=0
    )
    [[ -n "$CC_OVERRIDE" ]] && EXEC_ENV+=(-e CC="$CC_OVERRIDE")
    [[ -n "$CFLAGS_OVERRIDE" ]] && EXEC_ENV+=(-e CFLAGS="$CFLAGS_OVERRIDE")
    [[ -n "$CONFIGURE_EXTRA" ]] && EXEC_ENV+=(-e CONFIGURE_EXTRA="$CONFIGURE_EXTRA")
    docker exec "${EXEC_ENV[@]}" "$CONTAINER_NAME" bash /work/cross_cpu_bench.sh

    mkdir -p "$OUT_BASE"
    log "Copying results back out of the container"
    for d in $(docker exec "$CONTAINER_NAME" bash -c 'ls -1 /out'); do
        docker cp "$CONTAINER_NAME:/out/$d" "$OUT_BASE/$d"
        echo "Report: $OUT_BASE/$d/REPORT.md"
    done
    echo
    echo "Container '$CONTAINER_NAME' left running for reuse (faster re-runs). Remove it with:"
    echo "  docker rm -f $CONTAINER_NAME"
    exit 0
fi

# ============================================================================
# From here on: the actual build + benchmark, run either natively
# (USE_DOCKER=0) or inside the container (as the inner invocation above).
# ============================================================================

STAMP="$(date +%Y%m%d_%H%M%S)"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
HOST_NAME="$(hostname 2>/dev/null || echo unknown-host)"
OUT_DIR="$OUT_BASE/${HOST_NAME}_${OS_NAME}_${ARCH_NAME}_${STAMP}"

mkdir -p "$WORKDIR" "$OUT_DIR"

# `docker cp` preserves the host's file ownership, which can trip git's
# "dubious ownership" safety check once we're root inside the container
# operating on files owned by some other host UID. This script only ever
# touches its own throwaway copies, so it's safe to blanket-trust here.
if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory '*' 2>/dev/null || true
fi

# ============================================================================
# 1. Environment fingerprint (saved verbatim into the report)
# ============================================================================
log "Collecting environment info"
{
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname: $HOST_NAME"
    echo "os: $OS_NAME"
    echo "arch: $ARCH_NAME"
    echo "uname -a: $(uname -a)"
    echo "ran_inside_docker: ${INSIDE_CONTAINER:+yes (${DOCKER_IMAGE:-container})}"
    if [[ "$OS_NAME" == "Darwin" ]]; then
        echo "cpu_brand: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
        echo "cpu_cores: $(sysctl -n hw.physicalcpu 2>/dev/null || echo unknown) physical / $(sysctl -n hw.logicalcpu 2>/dev/null || echo unknown) logical"
        echo "macos_version: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    else
        echo "cpu_model: $(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2 | sed 's/^ *//' || echo unknown)"
        echo "cpu_cores: $(nproc 2>/dev/null || echo unknown)"
        if command -v cpupower >/dev/null 2>&1; then
            echo "governor: $(cpupower frequency-info 2>/dev/null | grep 'current policy' | sed 's/^ *//' || echo unknown)"
        fi
    fi
    CC_FOR_INFO="${CC_OVERRIDE:-cc}"
    echo "compiler: $("$CC_FOR_INFO" --version 2>&1 | head -1 || echo unknown)"
    echo "base_repo: $BASE_REPO"
    echo "base_ref: $BASE_REF"
    echo "fork_repo: $FORK_REPO"
    echo "fork_ref: $FORK_REF"
    echo "trials: $TRIALS"
    echo "cc_override: ${CC_OVERRIDE:-<default>}"
    echo "cflags_override: ${CFLAGS_OVERRIDE:-<default>}"
} | tee "$OUT_DIR/env.txt"

# ============================================================================
# 2. Dependency check (never auto-installs; tells you what to run yourself).
#    Only relevant with USE_DOCKER=0 -- the container path above already
#    guarantees these via apt.
# ============================================================================
log "Checking build dependencies"
MISSING=()
for tool in autoconf automake bison re2c pkg-config make; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
# libtool doesn't ship a system-wide `libtool` binary on Debian/Ubuntu --
# only `libtoolize` (the actual `libtool` wrapper script is generated fresh
# per-project by buildconf/autoreconf). macOS ships a BSD libtool under that
# name, so php-src needs Homebrew's GNU one, installed as `glibtoolize`.
if [[ "$OS_NAME" == "Darwin" ]]; then
    command -v glibtoolize >/dev/null 2>&1 || MISSING+=("libtool (need 'glibtoolize' from Homebrew)")
else
    command -v libtoolize >/dev/null 2>&1 || MISSING+=("libtool")
fi
command -v git >/dev/null 2>&1 || MISSING+=("git")
if [[ -z "$CC_OVERRIDE" ]]; then
    command -v cc >/dev/null 2>&1 || MISSING+=("a C compiler (cc)")
fi

if (( ${#MISSING[@]} > 0 )); then
    echo "Missing required tools: ${MISSING[*]}"
    if [[ "$OS_NAME" == "Darwin" ]]; then
        echo "Install with:  brew install autoconf automake libtool bison re2c pkg-config"
        echo "(and make sure Xcode Command Line Tools are installed: xcode-select --install)"
        echo "Or just drop USE_DOCKER=0 and let this script use Docker instead (default)."
    else
        echo "Install with:  sudo apt-get install -y autoconf automake libtool bison re2c pkg-config build-essential"
        echo "Or just drop USE_DOCKER=0 and let this script use Docker instead (default)."
    fi
    die "install the above, then re-run this script"
fi
echo "All required build tools found."

# ============================================================================
# 3. Get both sources, always fresh: php-src's own master branch (baseline)
#    and the fork branch under test (contender). Neither is pinned to a
#    commit -- every run fetches whatever each ref currently points to, so
#    the comparison always reflects the current state of both branches.
# ============================================================================
clone_or_update_ref() {
    local repo="$1" ref="$2" dir="$3" label="$4"
    if [[ ! -d "$dir/.git" ]]; then
        log "Cloning $label ($repo)"
        git clone --quiet "$repo" "$dir"
    fi
    log "Fetching latest '$ref' for $label"
    git -C "$dir" fetch --quiet origin "$ref" || die "could not fetch ref '$ref' from $repo for $label"
    git -C "$dir" checkout --quiet --detach FETCH_HEAD
    git -C "$dir" reset --hard --quiet FETCH_HEAD
}

BASE_SRC="$WORKDIR/base-src"
FORK_SRC="$WORKDIR/fork-src"

clone_or_update_ref "$BASE_REPO" "$BASE_REF" "$BASE_SRC" "php-src baseline (master)"
BASE_COMMIT="$(git -C "$BASE_SRC" rev-parse HEAD)"
echo "baseline (php-src $BASE_REF) at: $BASE_COMMIT"

clone_or_update_ref "$FORK_REPO" "$FORK_REF" "$FORK_SRC" "fork branch under test"
FORK_COMMIT="$(git -C "$FORK_SRC" rev-parse HEAD)"
echo "contender (fork $FORK_REF) at: $FORK_COMMIT"

{
    echo "base_commit: $BASE_COMMIT"
    echo "fork_commit: $FORK_COMMIT"
} >> "$OUT_DIR/env.txt"

# ============================================================================
# 4. Prepare the two build trees from the two live checkouts above. No
#    patch is applied here -- "unpatched" is a fresh copy of php-src
#    master (BASE_SRC) and "patched" is a fresh copy of the fork branch
#    (FORK_SRC, https://github.com/adapik/php-src/tree/perf/json-sse2-escape
#    by default), whatever that branch's SIMD JSON-escaping fast path
#    currently looks like. The "unpatched"/"patched" names are kept
#    throughout this script (filenames, report columns) purely as short
#    tags for "baseline" vs "contender" -- see base_commit/fork_commit in
#    env.txt for exactly what was built.
# ============================================================================
log "Preparing baseline (master) + contender (fork branch) build trees"
UNPATCHED="$WORKDIR/unpatched"
PATCHED="$WORKDIR/patched"
rm -rf "$UNPATCHED" "$PATCHED"
cp -r "$BASE_SRC" "$UNPATCHED"
cp -r "$FORK_SRC" "$PATCHED"
( cd "$UNPATCHED" && git clean -qfdx >/dev/null 2>&1 || true )
( cd "$PATCHED" && git clean -qfdx >/dev/null 2>&1 || true )

# ============================================================================
# 5. Configure + build both trees
# ============================================================================
build_tree() {
    local dir="$1" label="$2"
    log "Building $label ($dir)"
    ( cd "$dir" && ./buildconf --force ) > "$OUT_DIR/${label}_buildconf.log" 2>&1
    local configure_cmd=(./configure --disable-all --disable-cgi --disable-phpdbg)
    if [[ -n "$CONFIGURE_EXTRA" ]]; then
        configure_cmd+=($CONFIGURE_EXTRA)
    fi
    (
        cd "$dir"
        [[ -n "$CC_OVERRIDE" ]] && export CC="$CC_OVERRIDE"
        [[ -n "$CFLAGS_OVERRIDE" ]] && export CFLAGS="$CFLAGS_OVERRIDE"
        "${configure_cmd[@]}"
    ) > "$OUT_DIR/${label}_configure.log" 2>&1 || {
        tail -40 "$OUT_DIR/${label}_configure.log"
        die "configure failed for $label -- see $OUT_DIR/${label}_configure.log"
    }
    local njobs
    njobs="$( { [[ "$OS_NAME" == Darwin ]] && sysctl -n hw.ncpu; } || nproc || echo 2 )"
    ( cd "$dir" && make -j"$njobs" ) > "$OUT_DIR/${label}_build.log" 2>&1 || {
        tail -60 "$OUT_DIR/${label}_build.log"
        die "build failed for $label -- see $OUT_DIR/${label}_build.log"
    }
    [[ -x "$dir/sapi/cli/php" ]] || die "$label build did not produce sapi/cli/php"
    echo "$label built: $("$dir/sapi/cli/php" -v | head -1)"
}

build_tree "$UNPATCHED" unpatched
build_tree "$PATCHED" patched

UNPATCHED_PHP="$UNPATCHED/sapi/cli/php"
PATCHED_PHP="$PATCHED/sapi/cli/php"

# ============================================================================
# 6. Best-effort, arch-aware check for vector instructions in the
#    contender's ext/json/json_encoder.o. This is purely informational --
#    the fork branch is fetched fresh each run and may change its
#    approach (which intrinsics it uses, whether it covers aarch64 at
#    all, etc.), so a miss here is a warning, never a hard failure. It
#    just tells you, on this specific run, whether SSE2/NEON instructions
#    actually made it into the compiled object on this host/compiler.
# ============================================================================
log "Checking whether vector instructions made it into the contender binary"
VECTOR_ACTIVE=false
if [[ "$ARCH_NAME" == "arm64" || "$ARCH_NAME" == "aarch64" ]]; then
    NEON_COUNT=0
    if command -v objdump >/dev/null 2>&1; then
        # AArch64 NEON mnemonics the zend_simd.h shim's _mm_cmplt_epi8 /
        # _mm_cmpeq_epi8 / _mm_or_si128 / _mm_movemask_epi8 lower to, plus
        # the ".16b" (128-bit byte-lane) register-width suffix as a
        # sanity check that these are genuinely 16-byte vector ops and not
        # some unrelated scalar use of the same mnemonic.
        NEON_COUNT="$(objdump -d "$PATCHED/ext/json/json_encoder.o" 2>/dev/null | grep -icE '\b(cmeq|cmgt|cmlt|orr)\b.*\.16b' || true)"
    elif command -v otool >/dev/null 2>&1; then
        NEON_COUNT="$(otool -tV "$PATCHED/ext/json/json_encoder.o" 2>/dev/null | grep -icE '\b(cmeq|cmgt|cmlt|orr)\b.*\.16b' || true)"
    else
        warn "neither objdump nor otool available -- cannot verify NEON codegen directly"
    fi
    echo "NEON vector instruction occurrences found in contender's json_encoder.o: $NEON_COUNT"
    if [[ "$NEON_COUNT" -eq 0 ]]; then
        warn "no NEON vector instructions detected in the contender's json_encoder.o -- either this build doesn't enable a NEON path on this compiler/target, or the fork branch's current implementation doesn't cover aarch64"
    else
        VECTOR_ACTIVE=true
    fi
else
    SSE2_COUNT=0
    if command -v objdump >/dev/null 2>&1; then
        SSE2_COUNT="$(objdump -d "$PATCHED/ext/json/json_encoder.o" 2>/dev/null | grep -icE 'movdqu|pcmpeq|pcmpgt|pmovmskb' || true)"
    elif command -v otool >/dev/null 2>&1; then
        SSE2_COUNT="$(otool -tV "$PATCHED/ext/json/json_encoder.o" 2>/dev/null | grep -icE 'movdqu|pcmpeq|pcmpgt|pmovmskb' || true)"
    else
        warn "neither objdump nor otool available -- cannot verify SSE2 codegen directly"
    fi
    echo "SSE2 instruction occurrences found in contender's json_encoder.o: $SSE2_COUNT"
    if [[ "$SSE2_COUNT" -eq 0 ]]; then
        warn "no SSE2 instructions detected in the contender's json_encoder.o -- the fast path may not be active on this build/compiler"
    else
        VECTOR_ACTIVE=true
    fi
fi
echo "vector_fast_path_active: $VECTOR_ACTIVE" >> "$OUT_DIR/env.txt"

# ============================================================================
# 7. Write the embedded PHP benchmark suite
# ============================================================================
log "Writing benchmark suite to $WORKDIR/suite"
SUITE="$WORKDIR/suite"
mkdir -p "$SUITE"

cat > "$SUITE/lib.php" <<'PHP_EOF'
<?php

/**
 * Shared helpers for corpus generation, stats, and I/O used by every script
 * in this benchmark suite. Loaded by generate_corpora.php, correctness.php,
 * and bench.php.
 */

function stats_ns(array $samplesNs): array {
    $n = count($samplesNs);
    sort($samplesNs);
    $sum = array_sum($samplesNs);
    $mean = $sum / $n;
    $mid = intdiv($n, 2);
    $median = ($n % 2 === 0) ? ($samplesNs[$mid - 1] + $samplesNs[$mid]) / 2 : $samplesNs[$mid];
    $variance = 0.0;
    foreach ($samplesNs as $v) {
        $variance += ($v - $mean) ** 2;
    }
    $variance /= max(1, $n - 1); // sample stddev
    $stddev = sqrt($variance);
    // Standard error of the MEAN (shrinks as 1/sqrt(n)), as opposed to
    // stddev/rel_stddev_pct which describe dispersion of individual calls
    // and do NOT shrink with more samples -- for a sub-microsecond corpus,
    // individual-call jitter close to timer/scheduler resolution is normal
    // and does not by itself mean the pooled MEAN is unreliable. SEM is the
    // statistic that actually answers "do I need more iterations/trials?".
    $sem = $stddev / sqrt($n);
    return [
        'n' => $n,
        'mean_ns' => $mean,
        'median_ns' => $median,
        'mean_ms' => $mean / 1e6,
        'median_ms' => $median / 1e6,
        'stddev_ms' => $stddev / 1e6,
        'min_ms' => $samplesNs[0] / 1e6,
        'max_ms' => $samplesNs[$n - 1] / 1e6,
        'rel_stddev_pct' => $mean > 0 ? ($stddev / $mean) * 100 : 0.0,
        'rel_sem_pct' => $mean > 0 ? ($sem / $mean) * 100 : 0.0,
    ];
}

/** Auto-scaling time formatter (ns/µs/ms) with ~3 significant figures, so a
 *  sub-microsecond corpus prints as e.g. "42.3 ns" instead of rounding to
 *  "0.0000" under a fixed 4-decimal millisecond format. */
function fmt_ns(float $ns): string {
    if ($ns < 1000) {
        $unit = 'ns'; $v = $ns;
    } elseif ($ns < 1_000_000) {
        $unit = 'µs'; $v = $ns / 1000;
    } else {
        $unit = 'ms'; $v = $ns / 1_000_000;
    }
    $decimals = $v >= 100 ? 0 : ($v >= 10 ? 1 : 2);
    return number_format($v, $decimals) . ' ' . $unit;
}

/** Deterministic xorshift-ish PRNG so every corpus is byte-for-byte reproducible
 *  regardless of PHP build / mt_rand implementation differences between binaries. */
function make_rng(int $seed): Closure {
    $state = $seed ?: 1;
    return function (int $max) use (&$state): int {
        // xorshift32
        $state ^= ($state << 13) & 0xFFFFFFFF;
        $state ^= ($state >> 17);
        $state ^= ($state << 5) & 0xFFFFFFFF;
        $state &= 0xFFFFFFFF;
        return $state % ($max + 1);
    };
}

function rand_choice(Closure $rng, array $arr) {
    return $arr[$rng(count($arr) - 1)];
}

function rand_hex(Closure $rng, int $len): string {
    $s = '';
    $hex = '0123456789abcdef';
    for ($i = 0; $i < $len; $i++) {
        $s .= $hex[$rng(15)];
    }
    return $s;
}

function rand_uuid(Closure $rng): string {
    return sprintf(
        '%s-%s-4%s-%s%s-%s',
        rand_hex($rng, 8),
        rand_hex($rng, 4),
        rand_hex($rng, 3),
        rand_choice($rng, ['8', '9', 'a', 'b']),
        rand_hex($rng, 3),
        rand_hex($rng, 12)
    );
}

function rand_word(Closure $rng): string {
    static $words = [
        'apple', 'banana', 'cargo', 'delta', 'engine', 'falcon', 'grid', 'harbor',
        'island', 'jungle', 'kernel', 'lambda', 'meadow', 'nectar', 'oracle', 'piston',
        'quartz', 'ridge', 'sonar', 'tango', 'umbra', 'vector', 'willow', 'xenon',
        'yonder', 'zephyr', 'orbit', 'signal', 'harvest', 'canyon',
    ];
    return rand_choice($rng, $words);
}

/** Build a flat array of strings using $gen(rng) until we've generated
 *  roughly $targetBytes of total content (measured as raw string bytes, which
 *  tracks json_encode() output size closely enough for tiering purposes). */
function build_corpus_by_size(Closure $gen, int $targetBytes, int $seed): array {
    $rng = make_rng($seed);
    $out = [];
    $total = 0;
    while ($total < $targetBytes) {
        $s = $gen($rng);
        $out[] = $s;
        $total += strlen($s) + 8; // rough overhead per array element in output
    }
    return $out;
}

function write_corpus(string $dir, string $name, $data): void {
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    $path = "$dir/$name.php";
    file_put_contents($path, "<?php\nreturn " . var_export($data, true) . ";\n");
}
PHP_EOF

cat > "$SUITE/generate_corpora.php" <<'PHP_EOF'
<?php

require __DIR__ . '/lib.php';

/**
 * Generates every test corpus described in the benchmark plan, as PHP files
 * under corpora/ that `return` a value ready to json_encode(). Deterministic:
 * re-running this script produces byte-identical corpora (uses a private
 * xorshift PRNG, not mt_rand, so results don't depend on the PHP build under
 * test).
 */

const DIR = __DIR__ . '/corpora';

$sizeTiers = [
    'small'  => 200,        // ~200 B, typical single API response
    'medium' => 30 * 1024,  // ~30 KB
    'large'  => 1536 * 1024, // ~1.5 MB, bulk export
];

// ---- Content generators -----------------------------------------------

function gen_clean_ascii(Closure $rng): string {
    switch ($rng(3)) {
        case 0: return rand_uuid($rng);
        case 1: return rand_choice($rng, ['ACTIVE', 'PENDING', 'CLOSED', 'ARCHIVED', 'DRAFT']);
        case 2: {
            $y = 2020 + $rng(5);
            $mo = 1 + $rng(11);
            $d = 1 + $rng(27);
            $h = $rng(23);
            $mi = $rng(59);
            $se = $rng(59);
            return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $y, $mo, $d, $h, $mi, $se);
        }
        default: return rand_word($rng) . '_' . rand_word($rng) . '_' . $rng(99999);
    }
}

function gen_mixed(Closure $rng): string {
    $words = [];
    $n = 6 + $rng(10);
    for ($i = 0; $i < $n; $i++) {
        $words[] = rand_word($rng);
    }
    $s = implode(' ', $words);
    switch ($rng(2)) {
        case 0: $s .= " & co.";
            break;
        case 1: $s = "It's the " . $s;
            break;
        default: $s = 'He said "' . $s . '"';
            break;
    }
    return $s;
}

function gen_url_heavy(Closure $rng): string {
    $segs = ['api', 'v1', 'v2', 'users', 'orders', 'items', 'products', 'search', 'assets'];
    $n = 3 + $rng(4);
    $parts = [];
    for ($i = 0; $i < $n; $i++) {
        $parts[] = ($rng(1) === 0) ? rand_choice($rng, $segs) : (string) $rng(99999);
    }
    return '/' . implode('/', $parts);
}

function gen_non_ascii(Closure $rng): string {
    static $samples = [
        "こんにちは世界、今日は良い天気ですね",
        "東京から大阪までの新幹線は速いです",
        "Привет, мир! Как твои дела сегодня?",
        "Это тестовая строка на русском языке",
        "café, naïve, façade, résumé, jalapeño",
        "über cool, straße, größe, Müller",
        "🎉🚀✨ deploy succeeded 🎉🚀✨",
        "emoji test: 😀😃😄😁😆😅🤣😂🙂🙃",
        "日本語とemoji混在😊テスト文字列です",
        "Ñoño pingüino jalapeño año niño",
    ];
    return rand_choice($rng, $samples) . ' ' . rand_word($rng);
}

function gen_html_heavy(Closure $rng): string {
    $tag = rand_choice($rng, ['div', 'span', 'p', 'a', 'b']);
    $cls = rand_word($rng);
    return "<$tag class=\"$cls\">" . rand_word($rng) . ' &amp; ' . rand_word($rng)
        . "</$tag><br/>\"quoted\" 'text' <script>if (a < b && b > c) { }</script>";
}

$categories = [
    'clean_ascii' => 'gen_clean_ascii',
    'mixed'       => 'gen_mixed',
    'url_heavy'   => 'gen_url_heavy',
    'non_ascii'   => 'gen_non_ascii',
    'html_heavy'  => 'gen_html_heavy',
];

$seedBase = 1000;
foreach ($categories as $catName => $genFn) {
    foreach ($sizeTiers as $tierName => $targetBytes) {
        $seed = $seedBase++;
        $data = build_corpus_by_size(Closure::fromCallable($genFn), $targetBytes, $seed);
        write_corpus(DIR, "{$catName}_{$tierName}", $data);
        $bytes = strlen(json_encode($data));
        fwrite(STDOUT, sprintf("%-14s %-8s seed=%-5d elements=%-6d encoded_bytes=%d\n", $catName, $tierName, $seed, count($data), $bytes));
    }
}

// Boundary lengths: 0/1/15/16/17/31/32/33 bytes, clean + dirty-last-byte
// variants, one corpus file per length so correctness/perf are attributable
// to an exact length.
$lengths = [0, 1, 15, 16, 17, 31, 32, 33];
$boundaryNames = [];
foreach ($lengths as $len) {
    $clean = str_repeat('a', $len);
    $name = "boundary_clean_len_{$len}";
    write_corpus(DIR, $name, [$clean]);
    $boundaryNames[] = $name;
    if ($len > 0) {
        $dirty = str_repeat('a', $len - 1) . '"';
        $name = "boundary_dirty_last_len_{$len}";
        write_corpus(DIR, $name, [$dirty]);
        $boundaryNames[] = $name;
    }
}
fwrite(STDOUT, sprintf("%-14s %-8s files=%-6d\n", 'boundary', 'n/a', count($boundaryNames)));
fwrite(STDOUT, "\nCorpora written to " . DIR . "\n");
PHP_EOF

cat > "$SUITE/correctness.php" <<'PHP_EOF'
<?php

/**
 * Encodes every corpus under corpora/ with a fixed set of json_encode()
 * flag combinations and prints one base64 line per (corpus, flags) pair:
 *
 *   <corpus_name>|<flags_int>|<base64(json_encode_output)>|<last_error>
 *
 * Run this against the unpatched and patched binaries and diff the two
 * outputs byte-for-byte. Any diff is a correctness failure.
 */

const DIR = __DIR__ . '/corpora';

$flagSets = [
    0,
    JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
        | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT,
];

$files = glob(DIR . '/*.php');
sort($files);
if (!$files) {
    fwrite(STDERR, "No corpora found in " . DIR . " -- run generate_corpora.php first\n");
    exit(1);
}

foreach ($files as $file) {
    $name = basename($file, '.php');
    $data = require $file;
    foreach ($flagSets as $flags) {
        $encoded = json_encode($data, $flags);
        $err = json_last_error();
        $b64 = base64_encode($encoded === false ? '<<<FALSE>>>' : $encoded);
        echo "$name|$flags|$b64|$err\n";
    }
}
PHP_EOF

cat > "$SUITE/bench.php" <<'PHP_EOF'
<?php

require __DIR__ . '/lib.php';

/**
 * Times json_encode() over a single corpus in-process, using hrtime()
 * (monotonic, nanosecond resolution). Discards a warmup phase, then times
 * $iters calls, and prints one serialized summary. Intended to be invoked
 * many times (once per trial) by the driver, alternating which binary runs
 * first, so thermal/scheduling drift over a long run doesn't bias one side.
 *
 * Usage: php bench.php <corpus_name> <flags_int> <warmup> <iters>
 */

[, $corpusName, $flags, $warmup, $iters] = $argv + [null, null, null, null, null];
if ($corpusName === null) {
    fwrite(STDERR, "Usage: php bench.php <corpus_name> <flags_int> <warmup> <iters>\n");
    exit(1);
}
$flags = (int) $flags;
$warmup = (int) $warmup;
$iters = (int) $iters;

$path = __DIR__ . "/corpora/$corpusName.php";
if (!is_file($path)) {
    fwrite(STDERR, "Corpus not found: $path\n");
    exit(1);
}
$data = require $path;

$sink = null;
for ($i = 0; $i < $warmup; $i++) {
    $sink = json_encode($data, $flags);
}
if ($sink === false && json_last_error() !== JSON_ERROR_NONE) {
    fwrite(STDERR, "json_encode failed during warmup for $corpusName: " . json_last_error_msg() . "\n");
    exit(1);
}

$samples = [];
for ($i = 0; $i < $iters; $i++) {
    $t0 = hrtime(true);
    $out = json_encode($data, $flags);
    $t1 = hrtime(true);
    $samples[] = $t1 - $t0;
}

$summary = stats_ns($samples);
$summary['corpus'] = $corpusName;
$summary['flags'] = $flags;
$summary['warmup'] = $warmup;
$summary['iters'] = $iters;
$summary['encoded_bytes'] = strlen($out);
$summary['samples_ns'] = $samples;

// Deliberately NOT json_encode() here: this script runs under the very
// binary being benchmarked, which -- if it has the bug this suite is
// designed to catch -- can corrupt json_encode() output for clean ASCII
// strings >= 16 bytes, and several corpus names are exactly that length.
// serialize() doesn't go through php_json_escape_string() at all.
echo serialize($summary), "\n";
PHP_EOF

cat > "$SUITE/list_failed_corpora.php" <<'PHP_EOF'
<?php

/**
 * Prints, one per line, the names of corpora whose json_encode() output or
 * json_last_error() differs between the two correctness dump files given as
 * argv[1] (unpatched) and argv[2] (patched).
 */

function load(string $file): array {
    $out = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        [$name, $flags, $b64, $err] = explode('|', $line, 4);
        $out[$name][$flags] = [$b64, $err];
    }
    return $out;
}

$u = load($argv[1]);
$p = load($argv[2]);

foreach ($u as $name => $byFlags) {
    foreach ($byFlags as $flags => [$b64u, $erru]) {
        [$b64p, $errp] = $p[$name][$flags] ?? [null, null];
        if ($b64u !== $b64p || $erru !== $errp) {
            echo "$name\n";
            continue 2;
        }
    }
}
PHP_EOF

cat > "$SUITE/report.php" <<'PHP_EOF'
<?php

require __DIR__ . '/lib.php';

/**
 * Aggregates results/*.json into a single markdown report. Correctness is
 * evaluated PER CORPUS: if json_encode() output or json_last_error() differs
 * between the unpatched and patched binary for ANY flag combination on a
 * given corpus, that corpus is marked FAIL and its performance numbers are
 * withheld.
 */

$resultsDir = __DIR__ . '/results';

function load_correctness(string $file): array {
    $out = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        [$name, $flags, $b64, $err] = explode('|', $line, 4);
        $out[$name][$flags] = [$b64, $err];
    }
    return $out;
}

$unpatchedC = load_correctness("$resultsDir/correctness_unpatched.txt");
$patchedC = load_correctness("$resultsDir/correctness_patched.txt");

$correctnessByCorpus = [];
foreach ($unpatchedC as $name => $byFlags) {
    $pass = true;
    $detail = [];
    foreach ($byFlags as $flags => [$b64u, $erru]) {
        [$b64p, $errp] = $patchedC[$name][$flags] ?? [null, null];
        if ($b64u !== $b64p || $erru !== $errp) {
            $pass = false;
            $detail[] = "flags=$flags: unpatched error=$erru vs patched error=$errp"
                . ($b64u !== $b64p ? ' (output differs)' : ' (output equal, error code differs)');
        }
    }
    $correctnessByCorpus[$name] = ['pass' => $pass, 'detail' => $detail];
}

$files = glob("$resultsDir/*__*__trial*.json");
$pooled = [];
$meta = [];

foreach ($files as $file) {
    $base = basename($file, '.json');
    if (!preg_match('/^(.+)__(unpatched|patched)__trial\d+$/', $base, $m)) {
        fwrite(STDERR, "Skipping unrecognized result file: $file\n");
        continue;
    }
    [, $corpus, $binary] = $m;
    $j = @unserialize(file_get_contents($file));
    if ($j === false) {
        fwrite(STDERR, "Skipping unparseable result file: $file\n");
        continue;
    }
    foreach ($j['samples_ns'] as $s) {
        $pooled[$corpus][$binary][] = $s;
    }
    $meta[$corpus] = [
        'encoded_bytes' => $j['encoded_bytes'],
        'iters' => $j['iters'],
        'warmup' => $j['warmup'],
    ];
}

ksort($pooled);
ksort($correctnessByCorpus);

$rows = [];
foreach ($pooled as $corpus => $byBinary) {
    if (!isset($byBinary['unpatched'], $byBinary['patched'])) {
        fwrite(STDERR, "Incomplete timing data for $corpus, skipping\n");
        continue;
    }
    $correct = $correctnessByCorpus[$corpus]['pass'] ?? null;
    $u = stats_ns($byBinary['unpatched']);
    $p = stats_ns($byBinary['patched']);
    $speedup = $p['mean_ms'] > 0 ? $u['mean_ms'] / $p['mean_ms'] : NAN;
    // Approx relative half-width of a 95% CI on the speedup RATIO, via
    // first-order error propagation of two independent relative SEMs:
    // relSEM(u/p) ~= sqrt(relSEM(u)^2 + relSEM(p)^2). This is the number
    // that actually answers "is this ratio trustworthy, or do I need more
    // iterations/trials" -- unlike per-call rel_stddev_pct, it shrinks as
    // sample count grows.
    $relSemU = $u['rel_sem_pct'] / 100;
    $relSemP = $p['rel_sem_pct'] / 100;
    $speedupCiPct = 1.96 * sqrt($relSemU ** 2 + $relSemP ** 2) * 100;
    $rows[$corpus] = [
        'corpus' => $corpus,
        'bytes' => $meta[$corpus]['encoded_bytes'] ?? null,
        'unpatched' => $u,
        'patched' => $p,
        'speedup' => $speedup,
        'speedup_ci_pct' => $speedupCiPct,
        // Informational only: per-call timing jitter. Expected and harmless
        // for sub-microsecond corpora given the sample sizes this suite
        // uses; does NOT by itself mean the reported mean/speedup is wrong.
        'jitter' => ($u['rel_stddev_pct'] > 15 || $p['rel_stddev_pct'] > 15),
        // The actual reliability flag: speedup's own CI is wide enough that
        // more iterations/trials would change the conclusion.
        'uncertain' => $speedupCiPct > 2.0,
        'regression' => $speedup < 0.97,
        'correct' => $correct,
    ];
}

$out = [];
$out[] = "# JSON encoder benchmark: php-src master vs. adapik/php-src perf/json-sse2-escape";
$out[] = "";

$failedCorpora = array_keys(array_filter($correctnessByCorpus, fn($c) => !$c['pass']));
$passedCorpora = array_keys(array_filter($correctnessByCorpus, fn($c) => $c['pass']));

if ($failedCorpora) {
    $out[] = "## CORRECTNESS FAILURES (blocks performance reporting for these corpora)";
    $out[] = "";
    $out[] = sprintf("**%d of %d corpora produced different json_encode() output or a different json_last_error() between the unpatched and patched binary.**", count($failedCorpora), count($correctnessByCorpus));
    $out[] = "";
    foreach ($failedCorpora as $name) {
        $out[] = "- `$name`: " . implode('; ', $correctnessByCorpus[$name]['detail']);
    }
    $out[] = "";
} else {
    $out[] = "## Correctness: PASS for all corpora and flag combinations tested.";
    $out[] = "";
}

$out[] = "## Performance (only for corpora that passed correctness)";
$out[] = "";
$out[] = "Mean/median are auto-scaled (ns/µs/ms) so sub-microsecond corpora don't";
$out[] = "round to zero. \"±95% CI\" is the approximate 95% confidence interval on";
$out[] = "the speedup ratio itself (from the standard error of each mean, not raw";
$out[] = "per-call dispersion) -- this is the number that says whether the ratio";
$out[] = "is trustworthy, not the NOISY flag (see notes below the table).";
$out[] = "";
$out[] = "| Corpus | Bytes | Master mean | Master median | Fork mean | Fork median | Speedup | ±95% CI | Flags |";
$out[] = "|---|---|---|---|---|---|---|---|---|";
foreach ($rows as $r) {
    if ($r['correct'] === false) {
        $out[] = sprintf("| %s | %s | - | - | - | - | - | - | CORRECTNESS FAILURE, no result reported |", $r['corpus'], number_format((int)($r['bytes'] ?? 0)));
        continue;
    }
    $flags = [];
    if ($r['jitter']) $flags[] = 'NOISY (per-call jitter, informational)';
    if ($r['uncertain']) $flags[] = 'UNCERTAIN (wide CI, more trials would help)';
    if ($r['regression']) $flags[] = 'REGRESSION';
    $flagStr = $flags ? implode(', ', $flags) : '';
    $out[] = sprintf(
        "| %s | %s | %s | %s | %s | %s | %.2fx | ±%.2f%% | %s |",
        $r['corpus'],
        number_format((int)$r['bytes']),
        fmt_ns($r['unpatched']['mean_ns']),
        fmt_ns($r['unpatched']['median_ns']),
        fmt_ns($r['patched']['mean_ns']),
        fmt_ns($r['patched']['median_ns']),
        $r['speedup'],
        $r['speedup_ci_pct'],
        $flagStr
    );
}
$out[] = "";

$biggestWin = null;
$flat = [];
$worstRegression = null;
foreach ($rows as $r) {
    if ($r['correct'] === false) continue;
    if (strpos($r['corpus'], 'boundary') === 0) continue;
    if ($biggestWin === null || $r['speedup'] > $rows[$biggestWin]['speedup']) $biggestWin = $r['corpus'];
    if ($r['regression'] && ($worstRegression === null || $r['speedup'] < $rows[$worstRegression]['speedup'])) {
        $worstRegression = $r['corpus'];
    }
    if (abs($r['speedup'] - 1.0) < 0.05) $flat[] = $r['corpus'];
}

$out[] = "## Summary";
$out[] = "";
if ($biggestWin !== null) {
    $out[] = sprintf("- Among corpora that passed correctness, biggest win: **%s** at %.2fx speedup.", $biggestWin, $rows[$biggestWin]['speedup']);
} else {
    $out[] = "- No non-boundary corpus both passed correctness and produced a performance number.";
}
if ($flat) {
    $out[] = "- Flat / no-regression corpora (within 5% of 1.00x): " . implode(', ', $flat) . ".";
}
if ($worstRegression !== null) {
    $out[] = sprintf("- **REGRESSION FLAGGED:** %s is %.2fx (patched slower than unpatched by >3%%).", $worstRegression, $rows[$worstRegression]['speedup']);
} else {
    $out[] = "- No corpus that passed correctness showed the patched build slower than unpatched by more than 3%.";
}
$uncertainList = array_map(fn($r) => $r['corpus'], array_filter($rows, fn($r) => $r['uncertain'] && $r['correct'] !== false));
if ($uncertainList) {
    $out[] = "- **Actually uncertain** (speedup's own ±95% CI > 2%, i.e. more trials/iterations would likely change the number): " . implode(', ', $uncertainList) . ".";
} else {
    $out[] = "- Every reported speedup has a ±95% CI within 2% -- none of these numbers would meaningfully change with more iterations or trials.";
}
$jitterList = array_map(fn($r) => $r['corpus'], array_filter($rows, fn($r) => $r['jitter'] && $r['correct'] !== false));
if ($jitterList) {
    $out[] = "- Individual-call jitter > 15% (informational only, not a reliability concern by itself -- see the CI column and note above): " . implode(', ', $jitterList) . ".";
}
$out[] = sprintf("- %d/%d corpora passed correctness and have reportable performance numbers; %d failed correctness and are withheld.", count($passedCorpora), count($correctnessByCorpus), count($failedCorpora));
$out[] = "";

file_put_contents(__DIR__ . '/REPORT.md', implode("\n", $out) . "\n");
echo implode("\n", $out), "\n";
PHP_EOF

# ============================================================================
# 8. Run: correctness, then timed trials, then the report
# ============================================================================
RESULTS="$SUITE/results"
rm -rf "$RESULTS" "$SUITE/corpora"
mkdir -p "$RESULTS"

log "Generating corpora"
"$UNPATCHED_PHP" -n "$SUITE/generate_corpora.php"

log "Correctness check (php-src master vs fork branch, byte-for-byte)"
"$UNPATCHED_PHP" -n "$SUITE/correctness.php" > "$RESULTS/correctness_unpatched.txt"
"$PATCHED_PHP"   -n "$SUITE/correctness.php" > "$RESULTS/correctness_patched.txt"
"$UNPATCHED_PHP" -n "$SUITE/list_failed_corpora.php" "$RESULTS/correctness_unpatched.txt" "$RESULTS/correctness_patched.txt" > "$RESULTS/failed_corpora.txt" || true
NUM_FAILED=$(wc -l < "$RESULTS/failed_corpora.txt" | tr -d ' ')
if [[ "$NUM_FAILED" -eq 0 ]]; then
    echo "PASS: output identical for every corpus x flag combination"
else
    echo "FAIL: $NUM_FAILED corpus/corpora differ:"
    cat "$RESULTS/failed_corpora.txt"
fi

# Pick a pinning strategy. Crucially: don't assume CPU IDs are a contiguous
# 0..nproc-1 range -- under a cgroup cpuset (e.g. `docker run --cpuset-cpus`)
# nproc reports the COUNT of allowed CPUs, but their actual IDs can be
# anything (e.g. only {2,3} visible), so "nproc-1" can name a CPU that isn't
# in this process's allowed set at all and taskset will fail with EINVAL.
# Read the real allowed-CPU list from this process's own current affinity
# instead, and pin to the last CPU actually in it.
PIN_CMD=()
if command -v taskset >/dev/null 2>&1; then
    if [[ -n "$CORE" ]]; then
        PIN_CORE="$CORE"
    else
        AFFINITY_LIST="$(taskset -pc $$ 2>/dev/null | sed 's/.*: *//')"
        if [[ -n "$AFFINITY_LIST" ]]; then
            LAST_GROUP="${AFFINITY_LIST##*,}"
            PIN_CORE="${LAST_GROUP##*-}"
        fi
    fi
    if [[ -n "${PIN_CORE:-}" ]] && taskset -c "$PIN_CORE" true 2>/dev/null; then
        PIN_CMD=(taskset -c "$PIN_CORE")
        echo "Pinning timed runs to CPU $PIN_CORE"
    else
        warn "could not determine a valid CPU to pin to -- running without pinning"
    fi
else
    warn "no CPU pinning available on this OS (taskset not found) -- results may be noisier"
fi

declare -A PARAMS=(
    [small]="3000 30000"
    [medium]="500 4000"
    [large]="80 400"
)

log "Timed trials ($TRIALS trials/binary/corpus, alternating order)"
for corpus_path in "$SUITE"/corpora/*.php; do
    name="$(basename "$corpus_path" .php)"

    if grep -qxF "$name" "$RESULTS/failed_corpora.txt" 2>/dev/null; then
        echo "-- $name: SKIPPED (failed correctness) --"
        continue
    fi

    if [[ "$name" == boundary_* ]]; then
        wi="5000 40000"
    else
        tier="${name##*_}"
        wi="${PARAMS[$tier]:-500 4000}"
    fi
    warmup="${wi% *}"
    iters="${wi#* }"

    echo "-- $name (warmup=$warmup iters=$iters) --"
    for trial in $(seq 1 "$TRIALS"); do
        if (( trial % 2 == 0 )); then
            order=("unpatched:$UNPATCHED_PHP" "patched:$PATCHED_PHP")
        else
            order=("patched:$PATCHED_PHP" "unpatched:$UNPATCHED_PHP")
        fi
        for entry in "${order[@]}"; do
            tag="${entry%%:*}"
            bin="${entry#*:}"
            out="$RESULTS/${name}__${tag}__trial${trial}.json"
            "${PIN_CMD[@]}" "$bin" -n "$SUITE/bench.php" "$name" 0 "$warmup" "$iters" > "$out"
        done
    done
done

log "Generating final report"
"$UNPATCHED_PHP" -n -d memory_limit=2G "$SUITE/report.php" | tee "$OUT_DIR/REPORT_BODY.md"

# ============================================================================
# 9. Assemble the final, self-describing report for this machine
# ============================================================================
{
    echo "# Benchmark run: $HOST_NAME ($OS_NAME/$ARCH_NAME)"
    echo
    echo "Comparing **$BASE_REPO@$BASE_REF** (\`$BASE_COMMIT\`) vs. **$FORK_REPO@$FORK_REF** (\`$FORK_COMMIT\`)."
    echo
    echo "## Environment"
    echo '```'
    cat "$OUT_DIR/env.txt"
    echo '```'
    echo
    cat "$OUT_DIR/REPORT_BODY.md"
} > "$OUT_DIR/REPORT.md"

cp -r "$RESULTS" "$OUT_DIR/results"
cp -r "$SUITE/corpora" "$OUT_DIR/corpora"

log "Done"
echo "Report: $OUT_DIR/REPORT.md"
echo "Raw results: $OUT_DIR/results/"

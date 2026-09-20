#!/usr/bin/env bash
#
# bin2hex()/hex2bin() SIMD benchmark - branch-vs-baseline runner.
#
# Compares two git refs by building each into its own PHP CLI binary (via
# disposable `git worktree`s, so your actual working tree is never touched
# or stashed) and running the same benchmark suite against both:
#   - "branch"   = the ref under test (e.g. a SIMD-optimization branch)
#   - "baseline" = what it's being compared against (default: master)
#
# Runs on any host/arch. The vectorized bin2hex()/hex2bin() path lives
# behind the XSSE2 macro in Zend/zend_simd.h, which covers both x86-64
# (SSE2) and aarch64 (NEON) - this script probes that engagement at
# compile time rather than gating on `uname -m`, so the same script is
# correct whether it's run on an x86-64 dev box or an ARM host. If XSSE2
# doesn't engage on a given host (e.g. 32-bit ARM, RISC-V), the probe dies
# loudly instead of silently benchmarking a scalar fallback.
#
# Methodology:
#   - A correctness gate that must pass on BOTH binaries before any timing
#     runs - includes the invalid-hex-byte-at-every-offset-0..63 matrix
#     (catches an off-by-one at a SIMD chunk boundary, which is exactly the
#     kind of bug a vectorized rewrite breaks silently) and the existing
#     ext/standard/tests/strings/bin2hex*.phpt / hex2bin*.phpt suite found
#     in the current checkout (see note below on phpt resolution).
#   - Batched-loop timing (time N iterations, divide by N), NOT per-call
#     hrtime() sampling: hrtime() itself costs ~20ns/call on a typical
#     dev host, which is *larger* than a single patched bin2hex(16 bytes)
#     call (~13ns on x86-64) - per-call sampling would be swamped by timer
#     overhead for exactly the small/crypto sizes this suite cares about
#     most. Measure hrtime()'s own cost on the host too (see the "timer
#     overhead" line in the report) and sanity-check it against the
#     smallest corpus's per-call time.
#   - Small-size sweep run in BOTH binary orders (branch-first and
#     baseline-first) to rule out thermal/scheduling drift biasing one
#     side - if the two orders disagree, trust neither in isolation.
#   - Named crypto-primitive sizes (CRC32/MAC/MD5/SHA-1/SHA-256/.../RSA sig),
#     not just round power-of-two corpora, since that's what a reviewer
#     will actually ask "does this matter for MY use case" about.
#   - A cache/allocator-boundary corpus (16B..16MB) reporting GB/s, plus an
#     strace-based mmap/munmap count to confirm (not just theorize) whether
#     any large-buffer falloff is Zend MM's huge-allocation path
#     (ZEND_MM_CHUNK_SIZE, 2MB) rather than a SIMD/cache effect.
#
# Note on phpt resolution: the phpt suite below is run from paths relative
# to the *current* working-tree checkout (REPO_ROOT), not from either
# worktree being benchmarked - both binaries are tested against the same
# on-disk test file content, which is the point of a correctness gate. Any
# listed phpt that doesn't exist in the current checkout is skipped with a
# warning rather than failing the run, since e.g. new *_simd_boundary.phpt
# files may only exist as uncommitted additions on your branch.
#
# Usage:
#   ./scripts/bin2hex_hex2bin/bench.sh <branch-to-test> [baseline-ref]
#   ./scripts/bin2hex_hex2bin/bench.sh binhex-simd              # vs. master
#   ./scripts/bin2hex_hex2bin/bench.sh binhex-simd v8.5.0RC1    # vs. explicit baseline
#   PATCH_REF=binhex-simd BASELINE_REF=master ./scripts/bin2hex_hex2bin/bench.sh
#   TRIALS_FULL=15 ./scripts/bin2hex_hex2bin/bench.sh binhex-simd   # tighter CI, slower
#   WORKDIR=/tmp/mybench ./scripts/bin2hex_hex2bin/bench.sh binhex-simd
#
# Output: ./results/<timestamp>/REPORT.md plus raw per-trial data files.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

TRIALS_SMALL="${TRIALS_SMALL:-21}"
TRIALS_CRYPTO="${TRIALS_CRYPTO:-15}"
TRIALS_FULL="${TRIALS_FULL:-9}"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/work}"
OUT_BASE="${OUT_BASE:-$SCRIPT_DIR/results}"

log()  { printf '\n== %s ==\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cd "$REPO_ROOT"
command -v git  >/dev/null || die "git required"
command -v make >/dev/null || die "make required"
command -v cc   >/dev/null || die "a C compiler (cc) required"

# ============================================================================
# 0. Resolve refs
# ============================================================================
PATCH_REF="${1:-${PATCH_REF:-}}"
BASELINE_REF="${2:-${BASELINE_REF:-master}}"

if [[ -z "$PATCH_REF" ]]; then
    PATCH_REF="$(git branch --show-current)"
    [[ -n "$PATCH_REF" ]] || die "No branch to test given and HEAD is detached - pass it explicitly: $0 <branch> [baseline]"
    warn "No branch given, defaulting to current branch: $PATCH_REF"
fi

git rev-parse --verify --quiet "$PATCH_REF" >/dev/null    || die "ref '$PATCH_REF' (branch under test) not found"
git rev-parse --verify --quiet "$BASELINE_REF" >/dev/null || die "ref '$BASELINE_REF' (baseline) not found"

PATCH_SHA="$(git rev-parse --short "$PATCH_REF")"
BASELINE_SHA="$(git rev-parse --short "$BASELINE_REF")"
[[ "$(git rev-parse "$PATCH_REF")" != "$(git rev-parse "$BASELINE_REF")" ]] || \
    warn "'$PATCH_REF' and '$BASELINE_REF' resolve to the same commit ($PATCH_SHA) - branch vs. baseline will be identical binaries."

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OUT_BASE/$STAMP"
RESULTS="$OUT_DIR/raw"
mkdir -p "$WORKDIR" "$RESULTS"

NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# ============================================================================
# 1. Environment fingerprint
# ============================================================================
log "Environment"
ENV_FILE="$OUT_DIR/environment.txt"
{
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname: $(hostname 2>/dev/null || echo unknown)"
    echo "uname -a: $(uname -a)"
    echo "arch: $(uname -m)"
    echo "cpu_cores: $NPROC"
    if [[ -r /proc/cpuinfo ]]; then
        echo "cpu_model: $(grep -m1 -E 'model name|Model' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//' || echo unknown)"
    fi
    echo "branch_ref: $PATCH_REF ($PATCH_SHA)"
    echo "baseline_ref: $BASELINE_REF ($BASELINE_SHA)"
} | tee "$ENV_FILE"

# Confirm the zend_simd.h vectorized path actually engages here (XSSE2
# covers x86-64/SSE2 and aarch64/NEON per that header, nothing else) - a
# real gate, not a formality: without it the code under test silently
# falls back to scalar and this whole benchmark would be meaningless.
cat > "$WORKDIR/simd_probe.c" <<'CEOF'
#include "Zend/zend_simd.h"
int main(void) {
#ifdef XSSE2
    __m128i v = _mm_set1_epi8(1);
    (void)v;
    return 0;
#else
    return 1;
#endif
}
CEOF
if cc -I"$REPO_ROOT" -o "$WORKDIR/simd_probe" "$WORKDIR/simd_probe.c" 2>"$WORKDIR/simd_probe.err" && "$WORKDIR/simd_probe"; then
    echo "zend_simd.h XSSE2 path: engaged" | tee -a "$ENV_FILE"
else
    cat "$WORKDIR/simd_probe.err" >&2 || true
    die "zend_simd.h did not compile/engage the vectorized (XSSE2) path on this host - the SIMD code under test would silently fall back to scalar, making this benchmark meaningless. Fix the environment before continuing."
fi

# ============================================================================
# 2. Build branch + baseline binaries (disposable worktrees - your actual
#    working tree is never modified or stashed)
# ============================================================================
log "Building binaries"

WORKTREES=()
cleanup_worktrees() {
    for wt in "${WORKTREES[@]:-}"; do
        [[ -n "$wt" ]] && git worktree remove --force "$wt" >/dev/null 2>&1 || true
    done
}
trap cleanup_worktrees EXIT

build_ref() {
    local ref="$1" wt_dir="$2" outfile="$3" logfile="$4"
    rm -rf "$wt_dir"
    git worktree add --detach "$wt_dir" "$ref" >/dev/null
    WORKTREES+=("$wt_dir")
    (
        cd "$wt_dir"
        ./buildconf --force
        ./configure --disable-all --disable-cgi
        make -j"$NPROC" sapi/cli/php
    ) >"$logfile" 2>&1 || { tail -100 "$logfile" >&2; die "build failed for ref '$ref' - see $logfile"; }
    cp "$wt_dir/sapi/cli/php" "$outfile"
}

PHP_BRANCH="$WORKDIR/php-branch"
PHP_BASELINE="$WORKDIR/php-baseline"

log "Building BRANCH ($PATCH_REF @ $PATCH_SHA)"
build_ref "$PATCH_REF" "$WORKDIR/branch-worktree" "$PHP_BRANCH" "$WORKDIR/build_branch.log"

log "Building BASELINE ($BASELINE_REF @ $BASELINE_SHA)"
build_ref "$BASELINE_REF" "$WORKDIR/baseline-worktree" "$PHP_BASELINE" "$WORKDIR/build_baseline.log"

"$PHP_BRANCH"   -v | tee "$OUT_DIR/php_branch_version.txt"
"$PHP_BASELINE" -v | tee "$OUT_DIR/php_baseline_version.txt"

# ============================================================================
# 3. Correctness gate - must pass on both binaries before any timing
# ============================================================================
log "Correctness gate"

cat > "$WORKDIR/correctness.php" <<'PHP'
<?php
$fail = 0;

// bin2hex: boundary lengths, byte-for-byte, full 0-255 value coverage.
$all = '';
for ($i = 0; $i < 256; $i++) $all .= chr($i);
foreach ([0,1,15,16,17,31,32,33,1000] as $len) {
    $s = substr(str_repeat($all, 5), 0, $len);
    $h = bin2hex($s);
    $ref = '';
    static $tab = '0123456789abcdef';
    for ($i = 0; $i < strlen($s); $i++) {
        $b = ord($s[$i]);
        $ref .= $tab[$b >> 4] . $tab[$b & 0xf];
    }
    if ($h !== $ref) { fwrite(STDERR, "bin2hex MISMATCH len=$len\n"); $fail++; }
    if (hex2bin($h) !== $s) { fwrite(STDERR, "roundtrip MISMATCH len=$len\n"); $fail++; }
}

// hex2bin: invalid byte at every offset 0..63 across two 32-char SIMD chunks.
$valid64 = str_repeat('0123456789abcdef', 4);
foreach (['g','G','z','!',' ',"\xFF","\x00",'-'] as $bad) {
    for ($pos = 0; $pos < 64; $pos++) {
        $s = $valid64;
        $s[$pos] = $bad;
        if (@hex2bin($s) !== false) {
            fwrite(STDERR, "hex2bin FAIL: pos=$pos char=" . bin2hex($bad) . " not rejected\n");
            $fail++;
        }
    }
}

// round-trip fuzz, fixed seed
mt_srand(1234567);
for ($i = 0; $i < 500; $i++) {
    $len = mt_rand(0, 200);
    $bytes = '';
    for ($j = 0; $j < $len; $j++) $bytes .= chr(mt_rand(0, 255));
    $hex = bin2hex($bytes);
    if (bin2hex(hex2bin($hex)) !== $hex) { fwrite(STDERR, "fuzz MISMATCH i=$i len=$len\n"); $fail++; }
}

echo $fail === 0 ? "ALL OK\n" : "FAILURES: $fail\n";
exit($fail === 0 ? 0 : 1);
PHP

for bin in branch baseline; do
    varname="PHP_${bin^^}"
    echo "-- $bin --"
    "${!varname}" -n "$WORKDIR/correctness.php" | tee "$RESULTS/correctness_$bin.txt"
done

log "Existing phpt suite (both binaries, resolved against current checkout)"
PHPT_CANDIDATES=(
    ext/standard/tests/strings/bin2hex.phpt
    ext/standard/tests/strings/bin2hex_001.phpt
    ext/standard/tests/strings/bin2hex_basic.phpt
    ext/standard/tests/strings/hex2bin_basic.phpt
    ext/standard/tests/strings/hex2bin_error.phpt
    ext/standard/tests/strings/bin2hex_simd_boundary.phpt
    ext/standard/tests/strings/bin2hex_hex2bin_simd_fuzz.phpt
    ext/standard/tests/strings/hex2bin_simd_boundary.phpt
)
PHPT_FILES=()
for f in "${PHPT_CANDIDATES[@]}"; do
    if [[ -f "$REPO_ROOT/$f" ]]; then
        PHPT_FILES+=("$f")
    else
        warn "phpt not found in current checkout, skipping: $f"
    fi
done

if [[ ${#PHPT_FILES[@]} -gt 0 ]]; then
    for bin in branch baseline; do
        varname="PHP_${bin^^}"
        "${!varname}" run-tests.php -q -p "${!varname}" \
            "${PHPT_FILES[@]}" \
            2>&1 | tee "$RESULTS/phpt_$bin.txt" | tail -8
        grep -qE 'Tests failed[[:space:]]*:[[:space:]]*0[[:space:]]' "$RESULTS/phpt_$bin.txt" || die "phpt failures on $bin - see $RESULTS/phpt_$bin.txt"
    done
else
    warn "no phpt files found in current checkout - skipping phpt suite (boundary-matrix fuzz above still ran)"
fi

log "Correctness gate passed on both binaries - proceeding to benchmarks"

# ============================================================================
# 4. Shared PHP benchmark helper
# ============================================================================
cat > "$WORKDIR/bench_lib.php" <<'PHP'
<?php
// Batched-loop timing: time $iters calls as one block, divide by $iters.
// See this script's header comment for why (hrtime() self-cost vs. the
// smallest per-call times under test).
//
// Deliberately NOT a generic bench_fn(callable $fn, ...) helper: an
// intermediate closure call adds a few ns of its own per iteration, which
// is negligible at 1KB+ but measurably compresses the visible speedup at
// the smallest (most important - see the crypto-primitive corpus) sizes,
// since both binaries pay the same closure tax on top of a now-smaller
// true difference. Each corpus loop below calls bin2hex()/hex2bin()
// directly, matching the interactive methodology this script mirrors.
function stats_of(array $samplesNs): array {
    sort($samplesNs);
    $n = count($samplesNs);
    $mean = array_sum($samplesNs) / $n;
    $variance = 0.0;
    foreach ($samplesNs as $s) $variance += ($s - $mean) ** 2;
    $variance /= max($n - 1, 1);
    $ci95 = 1.96 * sqrt($variance) / sqrt($n);
    return ['mean' => $mean, 'ci95' => $ci95, 'n' => $n];
}
PHP

cat > "$WORKDIR/timer_overhead.php" <<'PHP'
<?php
$n = 5000000;
$t0 = hrtime(true);
for ($i = 0; $i < $n; $i++) { $x = hrtime(true); }
$t1 = hrtime(true);
printf("hrtime() self-cost: %.2f ns/call\n", ($t1 - $t0) / $n);
PHP

log "Timer overhead (sanity check vs. smallest corpus below)"
"$PHP_BRANCH" -n "$WORKDIR/timer_overhead.php" | tee "$RESULTS/timer_overhead.txt"

# ============================================================================
# 5. Small-size sweep (below the SIMD threshold), order-controlled
# ============================================================================
log "Small-size sweep: bin2hex 1..15B, hex2bin output 1..20B - order A/B"

cat > "$WORKDIR/bench_small.php" <<PHP
<?php
require '$WORKDIR/bench_lib.php';
\$trials = $TRIALS_SMALL;
\$iters = 2_000_000;

\$warm = random_bytes(20);
for (\$i = 0; \$i < 500000; \$i++) { bin2hex(\$warm); hex2bin(bin2hex(\$warm)); }

echo "== bin2hex ==\n";
for (\$len = 1; \$len <= 15; \$len++) {
    \$data = random_bytes(\$len);
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { bin2hex(\$data); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    printf("len=%-3d mean=%8.3f ns  ci95=%6.3f ns\n", \$len, \$r['mean'], \$r['ci95']);
}
echo "== hex2bin ==\n";
for (\$outLen = 1; \$outLen <= 20; \$outLen++) {
    \$hex = bin2hex(random_bytes(\$outLen));
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { hex2bin(\$hex); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    printf("out=%-3d mean=%8.3f ns  ci95=%6.3f ns\n", \$outLen, \$r['mean'], \$r['ci95']);
}
PHP

"$PHP_BRANCH"   -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderA_branch.txt"
"$PHP_BASELINE" -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderA_baseline.txt"
"$PHP_BASELINE" -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderB_baseline.txt"
"$PHP_BRANCH"   -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderB_branch.txt"

# ============================================================================
# 6. Crypto-primitive sizes
# ============================================================================
log "Crypto-primitive sizes"

cat > "$WORKDIR/bench_crypto.php" <<PHP
<?php
require '$WORKDIR/bench_lib.php';
\$trials = $TRIALS_CRYPTO;
\$sizes = [
    '4B  (CRC32)'           => 4,
    '6B  (MAC addr)'        => 6,
    '16B (MD5/UUID/AES128)' => 16,
    '20B (SHA-1)'           => 20,
    '32B (SHA-256/AES256)'  => 32,
    '48B (SHA-384)'         => 48,
    '64B (SHA-512/Ed25519)' => 64,
    '256B (RSA-2048 sig)'   => 256,
    '512B (RSA-4096 sig)'   => 512,
];

\$w = random_bytes(64);
for (\$i = 0; \$i < 500000; \$i++) { bin2hex(\$w); hex2bin(bin2hex(\$w)); }

\$iters = 2_000_000;
echo "== bin2hex ==\n";
foreach (\$sizes as \$label => \$len) {
    \$data = random_bytes(\$len);
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { bin2hex(\$data); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    printf("%-24s mean=%8.3f ns  ci95=%6.3f ns\n", \$label, \$r['mean'], \$r['ci95']);
}
echo "== hex2bin ==\n";
foreach (\$sizes as \$label => \$len) {
    \$hex = bin2hex(random_bytes(\$len));
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { hex2bin(\$hex); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    printf("%-24s mean=%8.3f ns  ci95=%6.3f ns\n", \$label, \$r['mean'], \$r['ci95']);
}
PHP

"$PHP_BASELINE" -n "$WORKDIR/bench_crypto.php" > "$RESULTS/crypto_baseline.txt"
"$PHP_BRANCH"   -n "$WORKDIR/bench_crypto.php" > "$RESULTS/crypto_branch.txt"

# ============================================================================
# 7. Full corpus / cache+allocator boundary (16B..16MB), GB/s
# ============================================================================
log "Full corpus (cache/allocator boundary)"

cat > "$WORKDIR/bench_full.php" <<PHP
<?php
require '$WORKDIR/bench_lib.php';
\$trials = $TRIALS_FULL;
\$sizes = [
    '16B' => 16, '32B' => 32, '256B' => 256, '1KB' => 1024, '10KB' => 10*1024,
    '100KB' => 100*1024, '512KB' => 512*1024, '1MB' => 1024*1024,
    '2MB' => 2*1024*1024, '4MB' => 4*1024*1024, '16MB' => 16*1024*1024,
];

function iters_for(int \$len): int {
    if (\$len >= 1024*1024) return max(3, (int)(300_000_000 / \$len));
    return max(3, (int)(50_000_000 / max(\$len, 1)));
}

echo "== bin2hex ==\n";
foreach (\$sizes as \$label => \$len) {
    \$data = random_bytes(\$len);
    \$iters = iters_for(\$len);
    for (\$i = 0; \$i < 3; \$i++) bin2hex(\$data);
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { bin2hex(\$data); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    \$gbps = \$len / \$r['mean'];
    printf("%-6s len=%-9d iters=%-6d mean=%12.1f ns  ci95=%9.1f ns  throughput=%6.2f GB/s\n", \$label, \$len, \$iters, \$r['mean'], \$r['ci95'], \$gbps);
}
echo "== hex2bin ==\n";
foreach (\$sizes as \$label => \$len) {
    \$hex = bin2hex(random_bytes(\$len));
    \$iters = iters_for(\$len);
    for (\$i = 0; \$i < 3; \$i++) hex2bin(\$hex);
    \$samples = [];
    for (\$t = 0; \$t < \$trials; \$t++) {
        \$start = hrtime(true);
        for (\$i = 0; \$i < \$iters; \$i++) { hex2bin(\$hex); }
        \$samples[] = (hrtime(true) - \$start) / \$iters;
    }
    \$r = stats_of(\$samples);
    \$gbps = \$len / \$r['mean'];
    printf("%-6s out=%-9d iters=%-6d mean=%12.1f ns  ci95=%9.1f ns  throughput=%6.2f GB/s\n", \$label, \$len, \$iters, \$r['mean'], \$r['ci95'], \$gbps);
}
PHP

"$PHP_BASELINE" -n "$WORKDIR/bench_full.php" > "$RESULTS/full_baseline.txt"
"$PHP_BRANCH"   -n "$WORKDIR/bench_full.php" > "$RESULTS/full_branch.txt"

# ============================================================================
# 8. Allocator-boundary confirmation (mmap/munmap counts either side of the
#    ZEND_MM_CHUNK_SIZE=2MB crossover) - only if strace is available.
# ============================================================================
if command -v strace >/dev/null 2>&1; then
    log "Allocator-boundary confirmation (strace mmap/munmap counts)"

    cat > "$WORKDIR/alloc_below.php" <<'PHP'
<?php
$d = random_bytes(512*1024);
for ($i=0;$i<20;$i++) bin2hex($d);
PHP
    cat > "$WORKDIR/alloc_above.php" <<'PHP'
<?php
$d = random_bytes(1024*1024);
for ($i=0;$i<20;$i++) bin2hex($d);
PHP

    {
        echo "-- bin2hex, 512KB input (output ~1MB, under 2MB huge-alloc threshold), 20 calls, BRANCH binary --"
        strace -f -c -e trace=mmap,munmap "$PHP_BRANCH" -n "$WORKDIR/alloc_below.php" 2>&1 | tail -8
        echo
        echo "-- bin2hex, 1MB input (output ~2MB, crosses 2MB huge-alloc threshold), 20 calls, BRANCH binary --"
        strace -f -c -e trace=mmap,munmap "$PHP_BRANCH" -n "$WORKDIR/alloc_above.php" 2>&1 | tail -8
    } | tee "$RESULTS/allocator_boundary.txt"
else
    warn "strace not found - skipping allocator-boundary mmap/munmap confirmation (results/full_*.txt GB/s columns still show whether the falloff exists)."
    echo "strace not available on this host" > "$RESULTS/allocator_boundary.txt"
fi

# ============================================================================
# 9. Report
# ============================================================================
log "Writing report"

REPORT="$OUT_DIR/REPORT.md"
{
    echo "# bin2hex()/hex2bin() SIMD benchmark"
    echo
    echo "Branch:   \`$PATCH_REF\` ($PATCH_SHA)"
    echo "Baseline: \`$BASELINE_REF\` ($BASELINE_SHA)"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Environment"
    echo '```'
    cat "$ENV_FILE"
    echo '```'
    echo
    echo "## Correctness gate"
    echo "Branch: \`$(cat "$RESULTS/correctness_branch.txt")\`, phpt: see raw/phpt_branch.txt"
    echo "Baseline: \`$(cat "$RESULTS/correctness_baseline.txt")\`, phpt: see raw/phpt_baseline.txt"
    echo
    echo "## Timer overhead sanity check"
    echo '```'
    cat "$RESULTS/timer_overhead.txt"
    echo '```'
    echo
    echo "## Small-size sweep (order A: branch-first, order B: baseline-first)"
    echo "Raw data in raw/small_order{A,B}_{branch,baseline}.txt - if A and B"
    echo "disagree noticeably, treat the difference as measurement noise, not signal."
    echo
    echo "## Crypto-primitive sizes"
    echo '```'
    echo "-- baseline --"; cat "$RESULTS/crypto_baseline.txt"
    echo "-- branch --"; cat "$RESULTS/crypto_branch.txt"
    echo '```'
    echo
    echo "## Full corpus / cache+allocator boundary"
    echo '```'
    echo "-- baseline --"; cat "$RESULTS/full_baseline.txt"
    echo "-- branch --"; cat "$RESULTS/full_branch.txt"
    echo '```'
    echo
    echo "## Allocator-boundary confirmation (mmap/munmap counts, branch binary)"
    echo '```'
    cat "$RESULTS/allocator_boundary.txt"
    echo '```'
} > "$REPORT"

log "Done"
echo "Report: $REPORT"
echo "Raw data: $RESULTS"

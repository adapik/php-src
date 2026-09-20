#!/usr/bin/env bash
#
# bin2hex()/hex2bin() SIMD benchmark - aarch64/NEON runner.
#
# Same methodology used to benchmark the SSE2 encode/decode paths on x86-64
# during development of this patch:
#   - Two binaries built from this checkout: "patched" (current working-tree
#     changes to Zend/zend_string.c and ext/standard/string.c) and
#     "unpatched" (same tree with those two files reverted to HEAD).
#   - A correctness gate that must pass on BOTH binaries before any timing
#     runs - includes the invalid-hex-byte-at-every-offset-0..63 matrix
#     (catches an off-by-one at a SIMD chunk boundary, which is exactly the
#     kind of bug a vectorized rewrite breaks silently) and the full existing
#     ext/standard/tests/strings/bin2hex*.phpt / hex2bin*.phpt suite.
#   - Batched-loop timing (time N iterations, divide by N), NOT per-call
#     hrtime() sampling: hrtime() itself costs ~20ns/call on the x86-64 dev
#     host this was authored on, which is *larger* than a single patched
#     bin2hex(16 bytes) call (~13ns) - per-call sampling (the style used in
#     scripts/json/cross-cpu-bench-work/suite/bench.php, appropriate there
#     since a JSON-encode call is orders of magnitude more expensive) would
#     be swamped by timer overhead for exactly the small/crypto sizes this
#     suite cares about most. Measure hrtime()'s own cost on the ARM host
#     too (this script does, see the "timer overhead" line in the report)
#     and sanity-check it against the smallest corpus's per-call time.
#   - Small-size sweep run in BOTH binary orders (patched-first and
#     unpatched-first) to rule out thermal/scheduling drift biasing one
#     side - if the two orders disagree, trust neither in isolation.
#   - Named crypto-primitive sizes (CRC32/MAC/MD5/SHA-1/SHA-256/.../RSA sig),
#     not just round power-of-two corpora, since that's what a reviewer
#     will actually ask "does this matter for MY use case" about.
#   - A cache/allocator-boundary corpus (16B..16MB) reporting GB/s, plus an
#     strace-based mmap/munmap count to confirm (not just theorize) whether
#     any large-buffer falloff is Zend MM's huge-allocation path
#     (ZEND_MM_CHUNK_SIZE, 2MB) rather than a SIMD/cache effect - this
#     mattered on x86-64: bin2hex's cliff was at 1MB input (2x output
#     crosses 2MB), hex2bin's was at 2MB output (1x output == crossing
#     point directly). Confirm the crossover point lands at the same
#     algebraic place on ARM (it's an allocator property, not an ISA one,
#     so it should - but confirm, don't assume).
#
# Usage:
#   ./scripts/bin2hex_hex2bin/bench_arm.sh
#   TRIALS=15 ./scripts/bin2hex_hex2bin/bench_arm.sh   # tighter CI, slower
#   WORKDIR=/tmp/mybench ./scripts/bin2hex_hex2bin/bench_arm.sh
#
# Requires: this script to be run from (or given the path to) a php-src
# checkout that already has the bin2hex/hex2bin SIMD changes as *uncommitted*
# working-tree modifications to Zend/zend_string.c and ext/standard/string.c
# (the default flow: `git stash` those two files to get the "unpatched"
# baseline, build, `git stash pop`). If you've since committed the patch,
# pass BASE_REF to diff against instead (see below).
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
BASE_REF="${BASE_REF:-}"   # if set, diff against this ref via a worktree instead of stashing
PATCHED_FILES=(Zend/zend_string.c ext/standard/string.c)

log()  { printf '\n== %s ==\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cd "$REPO_ROOT"
command -v git  >/dev/null || die "git required"
command -v make >/dev/null || die "make required"
command -v cc   >/dev/null || die "a C compiler (cc) required"

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
    warn "uname -m reports '$ARCH', not aarch64/arm64 - continuing, but this" \
         "script is meant to be run ON the ARM host/container, not cross-compiled."
fi

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
    echo "arch: $ARCH"
    echo "cpu_cores: $NPROC"
    if [[ -r /proc/cpuinfo ]]; then
        echo "cpu_model: $(grep -m1 -E 'model name|Model' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//' || echo unknown)"
        echo "neon_asimd: $(grep -m1 '^Features' /proc/cpuinfo | grep -qo 'asimd' && echo yes || echo 'no (or not reported)')"
    fi
    echo "git_commit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "git_branch: $(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)"
} | tee "$ENV_FILE"

# Confirm the zend_simd.h NEON path actually compiles here (XSSE2 requires
# __aarch64__ per that header - it does NOT support 32-bit ARM NEON at all,
# so this is a real gate, not a formality).
cat > "$WORKDIR/neon_probe.c" <<'CEOF'
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
if cc -I"$REPO_ROOT" -o "$WORKDIR/neon_probe" "$WORKDIR/neon_probe.c" 2>"$WORKDIR/neon_probe.err" && "$WORKDIR/neon_probe"; then
    echo "zend_simd.h XSSE2/NEON path: engaged" | tee -a "$ENV_FILE"
else
    cat "$WORKDIR/neon_probe.err" >&2 || true
    die "zend_simd.h did not compile/engage the NEON (XSSE2) path on this host - the SIMD code under test would silently fall back to scalar, making this benchmark meaningless. Fix the environment before continuing."
fi

# ============================================================================
# 2. Build patched + unpatched binaries
# ============================================================================
log "Building binaries"

if [[ ! -f Makefile ]]; then
    log "Configuring (no existing Makefile found)"
    ./buildconf --force
    ./configure --disable-all --disable-cgi
fi

build_current_tree() {
    local outfile="$1"
    make -j"$NPROC" sapi/cli/php >"$WORKDIR/build.log" 2>&1 || { tail -100 "$WORKDIR/build.log" >&2; die "build failed - see $WORKDIR/build.log"; }
    cp sapi/cli/php "$outfile"
}

HAVE_UNCOMMITTED=0
if [[ -z "$(git status --porcelain -- "${PATCHED_FILES[@]}" 2>/dev/null)" ]]; then
    HAVE_UNCOMMITTED=0
else
    HAVE_UNCOMMITTED=1
fi

PHP_PATCHED="$WORKDIR/php-patched"
PHP_UNPATCHED="$WORKDIR/php-unpatched"

if [[ -n "$BASE_REF" ]]; then
    log "Building PATCHED (current tree) and UNPATCHED (git worktree at $BASE_REF)"
    build_current_tree "$PHP_PATCHED"

    WT_DIR="$WORKDIR/unpatched-worktree"
    rm -rf "$WT_DIR"
    git worktree add --detach "$WT_DIR" "$BASE_REF" >/dev/null
    trap 'git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true' EXIT
    (
        cd "$WT_DIR"
        ./buildconf --force
        ./configure --disable-all --disable-cgi
        make -j"$NPROC" sapi/cli/php
    ) >"$WORKDIR/build_unpatched.log" 2>&1 || { tail -100 "$WORKDIR/build_unpatched.log" >&2; die "unpatched build failed"; }
    cp "$WT_DIR/sapi/cli/php" "$PHP_UNPATCHED"
    git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true
    trap - EXIT

elif [[ "$HAVE_UNCOMMITTED" == "1" ]]; then
    log "Building PATCHED (current uncommitted changes)"
    build_current_tree "$PHP_PATCHED"

    log "Stashing SIMD changes, building UNPATCHED baseline"
    git stash push --quiet --message "bin2hex_hex2bin_arm_bench.sh baseline" -- "${PATCHED_FILES[@]}"
    trap 'git stash pop --quiet || true' EXIT
    build_current_tree "$PHP_UNPATCHED"
    git stash pop --quiet
    trap - EXIT

else
    die "No uncommitted changes found in ${PATCHED_FILES[*]}, and no BASE_REF given." \
        "Either run this with the SIMD patch applied as uncommitted changes," \
        "or set BASE_REF=<commit-before-the-patch> to compare against."
fi

"$PHP_PATCHED"   -v | tee "$OUT_DIR/php_patched_version.txt"
"$PHP_UNPATCHED" -v | tee "$OUT_DIR/php_unpatched_version.txt"

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

for bin in patched unpatched; do
    varname="PHP_${bin^^}"
    echo "-- $bin --"
    "${!varname}" -n "$WORKDIR/correctness.php" | tee "$RESULTS/correctness_$bin.txt"
done

log "Existing phpt suite (both binaries)"
for bin in patched unpatched; do
    varname="PHP_${bin^^}"
    "${!varname}" run-tests.php -q -p "${!varname}" \
        ext/standard/tests/strings/bin2hex.phpt \
        ext/standard/tests/strings/bin2hex_001.phpt \
        ext/standard/tests/strings/bin2hex_basic.phpt \
        ext/standard/tests/strings/hex2bin_basic.phpt \
        ext/standard/tests/strings/hex2bin_error.phpt \
        ext/standard/tests/strings/bin2hex_simd_boundary.phpt \
        ext/standard/tests/strings/bin2hex_hex2bin_simd_fuzz.phpt \
        ext/standard/tests/strings/hex2bin_simd_boundary.phpt \
        2>&1 | tee "$RESULTS/phpt_$bin.txt" | tail -8
    grep -qE 'Tests failed[[:space:]]*:[[:space:]]*0[[:space:]]' "$RESULTS/phpt_$bin.txt" || die "phpt failures on $bin - see $RESULTS/phpt_$bin.txt"
done

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
"$PHP_PATCHED" -n "$WORKDIR/timer_overhead.php" | tee "$RESULTS/timer_overhead.txt"

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

"$PHP_PATCHED"   -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderA_patched.txt"
"$PHP_UNPATCHED" -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderA_unpatched.txt"
"$PHP_UNPATCHED" -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderB_unpatched.txt"
"$PHP_PATCHED"   -n "$WORKDIR/bench_small.php" > "$RESULTS/small_orderB_patched.txt"

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

"$PHP_UNPATCHED" -n "$WORKDIR/bench_crypto.php" > "$RESULTS/crypto_unpatched.txt"
"$PHP_PATCHED"   -n "$WORKDIR/bench_crypto.php" > "$RESULTS/crypto_patched.txt"

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

"$PHP_UNPATCHED" -n "$WORKDIR/bench_full.php" > "$RESULTS/full_unpatched.txt"
"$PHP_PATCHED"   -n "$WORKDIR/bench_full.php" > "$RESULTS/full_patched.txt"

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
        echo "-- bin2hex, 512KB input (output ~1MB, under 2MB huge-alloc threshold), 20 calls --"
        strace -f -c -e trace=mmap,munmap "$PHP_PATCHED" -n "$WORKDIR/alloc_below.php" 2>&1 | tail -8
        echo
        echo "-- bin2hex, 1MB input (output ~2MB, crosses 2MB huge-alloc threshold), 20 calls --"
        strace -f -c -e trace=mmap,munmap "$PHP_PATCHED" -n "$WORKDIR/alloc_above.php" 2>&1 | tail -8
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
    echo "# bin2hex()/hex2bin() SIMD benchmark - $(uname -m)"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Environment"
    echo '```'
    cat "$ENV_FILE"
    echo '```'
    echo
    echo "## Correctness gate"
    echo "Patched: \`$(cat "$RESULTS/correctness_patched.txt")\`, phpt: see raw/phpt_patched.txt"
    echo "Unpatched: \`$(cat "$RESULTS/correctness_unpatched.txt")\`, phpt: see raw/phpt_unpatched.txt"
    echo
    echo "## Timer overhead sanity check"
    echo '```'
    cat "$RESULTS/timer_overhead.txt"
    echo '```'
    echo
    echo "## Small-size sweep (order A: patched-first, order B: unpatched-first)"
    echo "Raw data in raw/small_order{A,B}_{patched,unpatched}.txt - if A and B"
    echo "disagree noticeably, treat the difference as measurement noise, not signal."
    echo
    echo "## Crypto-primitive sizes"
    echo '```'
    echo "-- unpatched --"; cat "$RESULTS/crypto_unpatched.txt"
    echo "-- patched --"; cat "$RESULTS/crypto_patched.txt"
    echo '```'
    echo
    echo "## Full corpus / cache+allocator boundary"
    echo '```'
    echo "-- unpatched --"; cat "$RESULTS/full_unpatched.txt"
    echo "-- patched --"; cat "$RESULTS/full_patched.txt"
    echo '```'
    echo
    echo "## Allocator-boundary confirmation (mmap/munmap counts)"
    echo '```'
    cat "$RESULTS/allocator_boundary.txt"
    echo '```'
} > "$REPORT"

log "Done"
echo "Report: $REPORT"
echo "Raw data: $RESULTS"

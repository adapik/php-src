#!/usr/bin/env bash
#
# Self-contained, N-way JSON-encoder benchmark: compares php/php-src's
# master branch against any number of fork branches in one run, using the
# exact same corpus-generation / correctness-gating / statistical-trial
# methodology as cross_cpu_bench.sh (that script's 2-way sibling) -- just
# generalized from "unpatched vs patched" to "baseline vs N contenders".
#
# Default variants (override via VARIANTS, see below):
#   - master:  php/php-src @ master
#   - ptqa:    https://github.com/ptqa/php-src/tree/agent/improve-json-encode-ascii-performance
#   - adapik:  https://github.com/adapik/php-src/tree/perf/json-sse2-escape
#
# On macOS this defaults to a NATIVE build (no Docker), because Docker
# Desktop/OrbStack on macOS runs the container inside a virtualized Linux
# VM, not the host's own kernel -- and for this specific json-escaping
# workload (a tight byte-classification loop touching a small static
# table), that virtualization layer was found to introduce a large,
# reproducible ~20-40% slowdown on Apple Silicon that reversed into a
# speedup once measured with a genuinely native macOS build of the exact
# same source. On Linux, Docker stays the default (no VM layer there --
# namespaces/cgroups on the same kernel -- so it's still useful for
# cross-machine toolchain consistency). Override with USE_DOCKER=0/1.
#
# Usage:
#   ./multi_fork_bench.sh
#   TRIALS=15 ./multi_fork_bench.sh
#   VARIANTS="master:https://github.com/php/php-src.git:master ptqa:https://github.com/ptqa/php-src.git:agent/improve-json-encode-ascii-performance" ./multi_fork_bench.sh
#   USE_DOCKER=1 ./multi_fork_bench.sh   # force Docker even on macOS
#
# VARIANTS format: space-separated "label:repo:ref" triples. The FIRST
# variant listed is always the correctness reference ("baseline") that the
# others are compared against and the speedup denominator in the report.
#
# Output: ./cross-variant-results/<hostname>_<os>_<arch>_<timestamp>/
#   REPORT.md (includes the summary table), env.txt, results/, corpora/
#
set -euo pipefail

# ============================================================================
# Configuration (all env-overridable)
# ============================================================================
DEFAULT_VARIANTS="master:https://github.com/php/php-src.git:master ptqa:https://github.com/ptqa/php-src.git:agent/improve-json-encode-ascii-performance adapik:https://github.com/adapik/php-src.git:perf/json-sse2-escape"
VARIANTS="${VARIANTS:-$DEFAULT_VARIANTS}"

WORKDIR="${WORKDIR:-$PWD/cross-variant-bench-work}"
OUT_BASE="${OUT_BASE:-$PWD/cross-variant-results}"
CORE="${CORE:-}"
TRIALS="${TRIALS:-7}"
CC_OVERRIDE="${CC:-}"
CFLAGS_OVERRIDE="${CFLAGS:-}"
CONFIGURE_EXTRA="${CONFIGURE_EXTRA:-}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    USE_DOCKER="${USE_DOCKER:-0}"
else
    USE_DOCKER="${USE_DOCKER:-1}"
fi
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:24.04}"
DOCKER_CPUSET="${DOCKER_CPUSET:-}"

log() { printf '\n== %s ==\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ============================================================================
# Parse VARIANTS into parallel arrays: LABELS[i] / REPOS[i] / REFS[i].
# ============================================================================
LABELS=()
REPOS=()
REFS=()
for entry in $VARIANTS; do
    label="${entry%%:*}"
    rest="${entry#*:}"
    repo="${rest%:*}"
    ref="${rest##*:}"
    [[ -n "$label" && -n "$repo" && -n "$ref" ]] || die "malformed VARIANTS entry: '$entry' (expected label:repo:ref)"
    LABELS+=("$label")
    REPOS+=("$repo")
    REFS+=("$ref")
done
(( ${#LABELS[@]} >= 2 )) || die "need at least 2 variants (baseline + 1 contender), got ${#LABELS[@]}"
BASE_LABEL="${LABELS[0]}"

# ============================================================================
# Docker outer wrapper: same idea as cross_cpu_bench.sh -- builds/reuses a
# container with the toolchain, re-invokes this script inside it, copies
# results back out. Skipped if USE_DOCKER=0 or already inside the container.
# ============================================================================
if [[ "$USE_DOCKER" == "1" && -z "${INSIDE_CONTAINER:-}" ]]; then
    command -v docker >/dev/null 2>&1 || die "USE_DOCKER=1 but 'docker' was not found. Install Docker, or set USE_DOCKER=0 to build natively (needs autoconf/automake/libtool/bison/re2c/pkg-config/a C compiler on the host)."

    HOST_TAG="$(hostname 2>/dev/null || echo host)_$(uname -s)_$(uname -m)"
    CONTAINER_NAME="${CONTAINER_NAME:-json-multi-bench-$(echo "$HOST_TAG" | tr -c 'A-Za-z0-9' '-')}"

    log "Docker mode: preparing container '$CONTAINER_NAME' ($DOCKER_IMAGE)"
    if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        RUN_ARGS=(-d --name "$CONTAINER_NAME")
        [[ -n "$DOCKER_CPUSET" ]] && RUN_ARGS+=(--cpuset-cpus="$DOCKER_CPUSET")
        docker run "${RUN_ARGS[@]}" "$DOCKER_IMAGE" sleep infinity >/dev/null
    elif [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
        docker start "$CONTAINER_NAME" >/dev/null
    fi

    if ! docker exec "$CONTAINER_NAME" bash -c 'command -v autoconf && command -v bison && command -v re2c && command -v libtoolize && command -v cc' >/dev/null 2>&1; then
        log "Installing build toolchain in the container (first run only)"
        docker exec "$CONTAINER_NAME" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential autoconf automake libtool bison re2c pkg-config git ca-certificates >/dev/null'
        if [[ -n "$CC_OVERRIDE" && "$CC_OVERRIDE" == clang* ]]; then
            docker exec "$CONTAINER_NAME" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang >/dev/null'
        fi
    fi

    docker exec "$CONTAINER_NAME" mkdir -p /work /out
    docker cp "$0" "$CONTAINER_NAME:/work/multi_fork_bench.sh"

    log "Running the benchmark inside the container"
    EXEC_ENV=(
        -e INSIDE_CONTAINER=1
        -e VARIANTS="$VARIANTS"
        -e WORKDIR="/work/run"
        -e OUT_BASE="/out"
        -e CORE="$CORE"
        -e TRIALS="$TRIALS"
        -e USE_DOCKER=0
    )
    [[ -n "$CC_OVERRIDE" ]] && EXEC_ENV+=(-e CC="$CC_OVERRIDE")
    [[ -n "$CFLAGS_OVERRIDE" ]] && EXEC_ENV+=(-e CFLAGS="$CFLAGS_OVERRIDE")
    [[ -n "$CONFIGURE_EXTRA" ]] && EXEC_ENV+=(-e CONFIGURE_EXTRA="$CONFIGURE_EXTRA")
    docker exec "${EXEC_ENV[@]}" "$CONTAINER_NAME" bash /work/multi_fork_bench.sh

    mkdir -p "$OUT_BASE"
    log "Copying results back out of the container"
    for d in $(docker exec "$CONTAINER_NAME" bash -c 'ls -1 /out'); do
        docker cp "$CONTAINER_NAME:/out/$d" "$OUT_BASE/$d"
        echo "Report: $OUT_BASE/$d/REPORT.md"
    done
    echo
    echo "Container '$CONTAINER_NAME' left running for reuse. Remove it with:"
    echo "  docker rm -f $CONTAINER_NAME"
    exit 0
fi

# ============================================================================
# From here on: the actual build + benchmark, native or inside the container.
# ============================================================================
STAMP="$(date +%Y%m%d_%H%M%S)"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
HOST_NAME="$(hostname 2>/dev/null || echo unknown-host)"
OUT_DIR="$OUT_BASE/${HOST_NAME}_${OS_NAME}_${ARCH_NAME}_${STAMP}"

mkdir -p "$WORKDIR" "$OUT_DIR"

if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory '*' 2>/dev/null || true
fi

# ============================================================================
# 1. Environment fingerprint
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
    fi
    CC_FOR_INFO="${CC_OVERRIDE:-cc}"
    echo "compiler: $("$CC_FOR_INFO" --version 2>&1 | head -1 || echo unknown)"
    echo "variants:"
    for i in "${!LABELS[@]}"; do
        echo "  - ${LABELS[$i]}: ${REPOS[$i]} @ ${REFS[$i]}"
    done
    echo "baseline_label: $BASE_LABEL"
    echo "trials: $TRIALS"
    echo "cc_override: ${CC_OVERRIDE:-<default>}"
    echo "cflags_override: ${CFLAGS_OVERRIDE:-<default>}"
} | tee "$OUT_DIR/env.txt"

# ============================================================================
# 2. Dependency check (native path only)
# ============================================================================
log "Checking build dependencies"
MISSING=()
for tool in autoconf automake bison re2c pkg-config make; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
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
    else
        echo "Install with:  sudo apt-get install -y autoconf automake libtool bison re2c pkg-config build-essential"
        echo "Or set USE_DOCKER=1 to let this script use Docker instead."
    fi
    die "install the above, then re-run this script"
fi
echo "All required build tools found."

# ============================================================================
# 3. Fetch every variant, fresh (no pinned commits).
# ============================================================================
clone_or_update_ref() {
    local repo="$1" ref="$2" dir="$3" label="$4"
    if [[ ! -d "$dir/.git" ]]; then
        log "Initializing repo for $label ($repo)"
        git init --quiet "$dir"
        git -C "$dir" remote add origin "$repo"
    fi
    log "Fetching latest '$ref' for $label [shallow, --depth 1]"
    # Always a fresh shallow fetch of just this one ref, regardless of the
    # remote's default branch -- works identically whether ref is a branch
    # name, tag, or commit-ish, and never pulls other branches' history.
    git -C "$dir" fetch --quiet --depth 1 origin "$ref" || die "could not fetch ref '$ref' from $repo for $label"
    git -C "$dir" checkout --quiet --detach FETCH_HEAD
    git -C "$dir" reset --hard --quiet FETCH_HEAD
    git -C "$dir" clean --quiet -fdx
}

COMMITS=()
SRC_DIRS=()
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    src_dir="$WORKDIR/src-$label"
    clone_or_update_ref "${REPOS[$i]}" "${REFS[$i]}" "$src_dir" "$label"
    commit="$(git -C "$src_dir" rev-parse HEAD)"
    echo "$label (${REPOS[$i]}@${REFS[$i]}) at: $commit"
    COMMITS+=("$commit")
    SRC_DIRS+=("$src_dir")
    echo "commit_$label: $commit" >> "$OUT_DIR/env.txt"
done

# ============================================================================
# 4. Prepare + build every variant's own tree.
# ============================================================================
log "Preparing build trees"
BUILD_DIRS=()
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    build_dir="$WORKDIR/build-$label"
    rm -rf "$build_dir"
    cp -r "${SRC_DIRS[$i]}" "$build_dir"
    ( cd "$build_dir" && git clean -qfdx >/dev/null 2>&1 || true )
    BUILD_DIRS+=("$build_dir")
done

build_tree() {
    local dir="$1" label="$2"
    log "Building $label ($dir)"
    ( cd "$dir" && ./buildconf --force ) > "$OUT_DIR/${label}_buildconf.log" 2>&1
    local configure_cmd=(./configure --disable-all --disable-cgi --disable-phpdbg)
    [[ -n "$CONFIGURE_EXTRA" ]] && configure_cmd+=($CONFIGURE_EXTRA)
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

PHP_BINS=()
for i in "${!LABELS[@]}"; do
    build_tree "${BUILD_DIRS[$i]}" "${LABELS[$i]}"
    PHP_BINS+=("${BUILD_DIRS[$i]}/sapi/cli/php")
done

# ============================================================================
# 5. Write the embedded PHP benchmark suite (same corpora/methodology as
#    cross_cpu_bench.sh's suite, generalized to N binaries).
# ============================================================================
log "Writing benchmark suite to $WORKDIR/suite"
SUITE="$WORKDIR/suite"
mkdir -p "$SUITE"

cat > "$SUITE/lib.php" <<'PHP_EOF'
<?php

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
    $variance /= max(1, $n - 1);
    $stddev = sqrt($variance);
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

function make_rng(int $seed): Closure {
    $state = $seed ?: 1;
    return function (int $max) use (&$state): int {
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

function build_corpus_by_size(Closure $gen, int $targetBytes, int $seed): array {
    $rng = make_rng($seed);
    $out = [];
    $total = 0;
    while ($total < $targetBytes) {
        $s = $gen($rng);
        $out[] = $s;
        $total += strlen($s) + 8;
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

const DIR = __DIR__ . '/corpora';

$sizeTiers = [
    'small'  => 200,
    'medium' => 30 * 1024,
    'large'  => 1536 * 1024,
];

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

echo serialize($summary), "\n";
PHP_EOF

# ============================================================================
# 6. Run: correctness (every variant vs. the baseline), then timed trials
#    (every corpus x every variant, order rotated per trial), then report.
# ============================================================================
RESULTS="$SUITE/results"
rm -rf "$RESULTS" "$SUITE/corpora"
mkdir -p "$RESULTS"

log "Generating corpora (using ${LABELS[0]} as generator)"
"${PHP_BINS[0]}" -n "$SUITE/generate_corpora.php"

log "Correctness check (every variant vs. baseline '$BASE_LABEL', byte-for-byte)"
for i in "${!LABELS[@]}"; do
    "${PHP_BINS[$i]}" -n "$SUITE/correctness.php" > "$RESULTS/correctness_${LABELS[$i]}.txt"
done

cat > "$SUITE/list_failed_corpora.php" <<'PHP_EOF'
<?php
function load(string $file): array {
    $out = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        [$name, $flags, $b64, $err] = explode('|', $line, 4);
        $out[$name][$flags] = [$b64, $err];
    }
    return $out;
}
$baseFile = array_shift($argv); // script name
$baseFile = array_shift($argv); // baseline file
$base = load($baseFile);
foreach ($argv as $otherFile) {
    $other = load($otherFile);
    foreach ($base as $name => $byFlags) {
        foreach ($byFlags as $flags => [$b64b, $errb]) {
            [$b64o, $erro] = $other[$name][$flags] ?? [null, null];
            if ($b64b !== $b64o || $errb !== $erro) {
                echo "$otherFile|$name\n";
                continue 2;
            }
        }
    }
}
PHP_EOF

BASE_CORRECTNESS="$RESULTS/correctness_${BASE_LABEL}.txt"
OTHER_CORRECTNESS_FILES=()
for i in "${!LABELS[@]}"; do
    [[ "${LABELS[$i]}" == "$BASE_LABEL" ]] && continue
    OTHER_CORRECTNESS_FILES+=("$RESULTS/correctness_${LABELS[$i]}.txt")
done
"${PHP_BINS[0]}" -n "$SUITE/list_failed_corpora.php" "$BASE_CORRECTNESS" "${OTHER_CORRECTNESS_FILES[@]}" > "$RESULTS/failed_corpora_by_variant.txt" || true
NUM_FAILED=$(wc -l < "$RESULTS/failed_corpora_by_variant.txt" | tr -d ' ')
if [[ "$NUM_FAILED" -eq 0 ]]; then
    echo "PASS: every variant produced identical output to '$BASE_LABEL' for every corpus x flag combination"
else
    echo "FAIL: $NUM_FAILED (variant, corpus) pairs differ from '$BASE_LABEL':"
    cat "$RESULTS/failed_corpora_by_variant.txt"
fi

# A plain string, not an array: "${PIN_CMD[@]}" on an empty-but-declared
# array is a genuine bash bug on versions before 4.4 (spurious "unbound
# variable" under `set -u`) -- and macOS ships 3.2 by default. taskset
# invocations never contain spaces/quoting that would need array-safety,
# so unquoted word-splitting below is fine.
PIN_CMD=""
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
        PIN_CMD="taskset -c $PIN_CORE"
        echo "Pinning timed runs to CPU $PIN_CORE"
    else
        warn "could not determine a valid CPU to pin to -- running without pinning"
    fi
else
    warn "no CPU pinning available on this OS (taskset not found) -- results may be noisier"
fi

# Portable on purpose: no `declare -A` (associative arrays need bash 4+,
# but macOS ships bash 3.2 by default -- Apple hasn't updated it since
# GPLv3, and most Mac users never install a newer one -- so this script
# has to work under 3.2 too). A case statement works everywhere.
warmup_iters_for_tier() {
    case "$1" in
        small)  echo "3000 30000" ;;
        medium) echo "500 4000" ;;
        large)  echo "80 400" ;;
        *)      echo "500 4000" ;;
    esac
}

log "Timed trials ($TRIALS trials x ${#LABELS[@]} variants/corpus, rotating order)"
NUM_VARIANTS=${#LABELS[@]}
for corpus_path in "$SUITE"/corpora/*.php; do
    name="$(basename "$corpus_path" .php)"

    if grep -qE "\|$name\$" "$RESULTS/failed_corpora_by_variant.txt" 2>/dev/null; then
        echo "-- $name: at least one variant failed correctness, will be withheld per-variant in the report --"
    fi

    if [[ "$name" == boundary_* ]]; then
        wi="5000 40000"
    else
        tier="${name##*_}"
        wi="$(warmup_iters_for_tier "$tier")"
    fi
    warmup="${wi% *}"
    iters="${wi#* }"

    echo "-- $name (warmup=$warmup iters=$iters) --"
    for trial in $(seq 1 "$TRIALS"); do
        # Rotate the starting variant each trial so no single variant always
        # goes first/last -- spreads thermal/scheduling drift evenly across
        # all N variants instead of just alternating a pair.
        rot=$(( (trial - 1) % NUM_VARIANTS ))
        for offset in $(seq 0 $((NUM_VARIANTS - 1))); do
            idx=$(( (rot + offset) % NUM_VARIANTS ))
            label="${LABELS[$idx]}"
            bin="${PHP_BINS[$idx]}"
            out="$RESULTS/${name}__${label}__trial${trial}.json"
            $PIN_CMD "$bin" -n "$SUITE/bench.php" "$name" 0 "$warmup" "$iters" > "$out"
        done
    done
done

# ============================================================================
# 7. Report: aggregate results/*.json into a summary table, baseline vs.
#    every contender, correctness-gated per (corpus, variant).
# ============================================================================
cat > "$SUITE/report.php" <<PHP_EOF
<?php

require __DIR__ . '/lib.php';

\$resultsDir = __DIR__ . '/results';
\$labels = [$(printf "'%s'," "${LABELS[@]}" | sed 's/,$//')];
\$baseLabel = '$BASE_LABEL';

function load_correctness(string \$file): array {
    \$out = [];
    if (!is_file(\$file)) return \$out;
    foreach (file(\$file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as \$line) {
        [\$name, \$flags, \$b64, \$err] = explode('|', \$line, 4);
        \$out[\$name][\$flags] = [\$b64, \$err];
    }
    return \$out;
}

\$correctnessByLabel = [];
foreach (\$labels as \$label) {
    \$correctnessByLabel[\$label] = load_correctness("\$resultsDir/correctness_\$label.txt");
}
\$baseC = \$correctnessByLabel[\$baseLabel];

// correct[corpus][label] = bool (baseline is always true)
\$correct = [];
foreach (\$baseC as \$name => \$byFlags) {
    foreach (\$labels as \$label) {
        if (\$label === \$baseLabel) { \$correct[\$name][\$label] = true; continue; }
        \$otherC = \$correctnessByLabel[\$label][\$name] ?? null;
        \$pass = true;
        if (\$otherC === null) {
            \$pass = false;
        } else {
            foreach (\$byFlags as \$flags => [\$b64b, \$errb]) {
                [\$b64o, \$erro] = \$otherC[\$flags] ?? [null, null];
                if (\$b64b !== \$b64o || \$errb !== \$erro) { \$pass = false; break; }
            }
        }
        \$correct[\$name][\$label] = \$pass;
    }
}

\$files = glob("\$resultsDir/*__*__trial*.json");
\$pooled = [];
\$meta = [];
foreach (\$files as \$file) {
    \$base = basename(\$file, '.json');
    if (!preg_match('/^(.+)__(.+)__trial\d+\$/', \$base, \$m)) continue;
    [, \$corpus, \$label] = \$m;
    \$j = @unserialize(file_get_contents(\$file));
    if (\$j === false) continue;
    foreach (\$j['samples_ns'] as \$s) {
        \$pooled[\$corpus][\$label][] = \$s;
    }
    \$meta[\$corpus] = ['encoded_bytes' => \$j['encoded_bytes']];
}
ksort(\$pooled);

\$rows = [];
foreach (\$pooled as \$corpus => \$byLabel) {
    if (!isset(\$byLabel[\$baseLabel])) continue;
    \$baseStats = stats_ns(\$byLabel[\$baseLabel]);
    \$row = ['corpus' => \$corpus, 'bytes' => \$meta[\$corpus]['encoded_bytes'] ?? null, 'base' => \$baseStats, 'variants' => []];
    foreach (\$labels as \$label) {
        if (\$label === \$baseLabel) continue;
        if (!isset(\$byLabel[\$label])) { \$row['variants'][\$label] = null; continue; }
        \$isCorrect = \$correct[\$corpus][\$label] ?? null;
        if (\$isCorrect === false) {
            \$row['variants'][\$label] = ['correct' => false];
            continue;
        }
        \$s = stats_ns(\$byLabel[\$label]);
        \$speedup = \$s['mean_ms'] > 0 ? \$baseStats['mean_ms'] / \$s['mean_ms'] : NAN;
        \$relSemB = \$baseStats['rel_sem_pct'] / 100;
        \$relSemO = \$s['rel_sem_pct'] / 100;
        \$ciPct = 1.96 * sqrt(\$relSemB ** 2 + \$relSemO ** 2) * 100;
        \$row['variants'][\$label] = [
            'correct' => true,
            'stats' => \$s,
            'speedup' => \$speedup,
            'ci_pct' => \$ciPct,
            'regression' => \$speedup < 0.97,
            'uncertain' => \$ciPct > 2.0,
        ];
    }
    \$rows[] = \$row;
}

\$out = [];
\$out[] = "# JSON encoder benchmark: " . implode(' vs. ', \$labels);
\$out[] = "";

\$anyFail = false;
foreach (\$correct as \$name => \$byLabel) {
    foreach (\$byLabel as \$label => \$pass) {
        if (!\$pass) \$anyFail = true;
    }
}
if (\$anyFail) {
    \$out[] = "## CORRECTNESS FAILURES (blocks performance reporting for that corpus x variant)";
    \$out[] = "";
    foreach (\$correct as \$name => \$byLabel) {
        foreach (\$byLabel as \$label => \$pass) {
            if (!\$pass) \$out[] = "- \`\$name\` vs \$label: output or json_last_error() differs from \$baseLabel";
        }
    }
    \$out[] = "";
} else {
    \$out[] = "## Correctness: PASS -- every variant matches '\$baseLabel' byte-for-byte on every corpus x flag combination.";
    \$out[] = "";
}

\$out[] = "## Summary table";
\$out[] = "";
\$out[] = "Speedup = baseline mean / variant mean (>1.00x = variant is faster). \"±95% CI\" is";
\$out[] = "the approximate 95% confidence interval on the speedup ratio itself.";
\$out[] = "";

\$header = "| Corpus | Bytes | \$baseLabel (mean) |";
\$sep = "|---|---|---|";
foreach (\$labels as \$label) {
    if (\$label === \$baseLabel) continue;
    \$header .= " \$label (mean) | \$label speedup | \$label ±95% CI |";
    \$sep .= "---|---|---|";
}
\$out[] = \$header;
\$out[] = \$sep;

foreach (\$rows as \$r) {
    \$line = sprintf("| %s | %s | %s |", \$r['corpus'], number_format((int)(\$r['bytes'] ?? 0)), fmt_ns(\$r['base']['mean_ns']));
    foreach (\$labels as \$label) {
        if (\$label === \$baseLabel) continue;
        \$v = \$r['variants'][\$label] ?? null;
        if (\$v === null) {
            \$line .= " (no data) | - | - |";
        } elseif (\$v['correct'] === false) {
            \$line .= " CORRECTNESS FAILURE | - | - |";
        } else {
            \$flags = [];
            if (\$v['regression']) \$flags[] = 'REGRESSION';
            if (\$v['uncertain']) \$flags[] = 'UNCERTAIN';
            \$flagStr = \$flags ? ' [' . implode(',', \$flags) . ']' : '';
            \$line .= sprintf(" %s | %.2fx%s | ±%.2f%% |", fmt_ns(\$v['stats']['mean_ns']), \$v['speedup'], \$flagStr, \$v['ci_pct']);
        }
    }
    \$out[] = \$line;
}
\$out[] = "";

foreach (\$labels as \$label) {
    if (\$label === \$baseLabel) continue;
    \$best = null; \$worst = null;
    foreach (\$rows as \$r) {
        if (strpos(\$r['corpus'], 'boundary') === 0) continue;
        \$v = \$r['variants'][\$label] ?? null;
        if (\$v === null || \$v['correct'] === false) continue;
        if (\$best === null || \$v['speedup'] > \$best[1]) \$best = [\$r['corpus'], \$v['speedup']];
        if (\$worst === null || \$v['speedup'] < \$worst[1]) \$worst = [\$r['corpus'], \$v['speedup']];
    }
    \$out[] = "### \$label vs \$baseLabel";
    if (\$best) \$out[] = sprintf("- Best: **%s** at %.2fx", \$best[0], \$best[1]);
    if (\$worst) \$out[] = sprintf("- Worst: **%s** at %.2fx", \$worst[0], \$worst[1]);
    \$out[] = "";
}

file_put_contents(__DIR__ . '/REPORT.md', implode("\n", \$out) . "\n");
echo implode("\n", \$out), "\n";
PHP_EOF

log "Generating final report"
"${PHP_BINS[0]}" -n -d memory_limit=2G "$SUITE/report.php" | tee "$OUT_DIR/REPORT_BODY.md"

# ============================================================================
# 8. Assemble the final, self-describing report for this machine
# ============================================================================
{
    echo "# Multi-fork benchmark run: $HOST_NAME ($OS_NAME/$ARCH_NAME)"
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

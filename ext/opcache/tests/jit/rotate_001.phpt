--TEST--
JIT: 64-bit rotate idiom (x << k) | ((x >> (64 - k)) & mask) gives the same result as the interpreter
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.jit=tracing
opcache.jit_buffer_size=32M
opcache.jit_hot_loop=1
opcache.jit_hot_func=1
--FILE--
<?php

// Reference: rotate through two 32-bit halves, no 64-bit shifts involved.
function rotl_ref(int $x, int $k): int {
    $hi = ($x >> 32) & 0xFFFFFFFF;
    $lo = $x & 0xFFFFFFFF;
    if ($k >= 32) {
        [$hi, $lo] = [$lo, $hi];
        $k -= 32;
    }
    if ($k === 0) {
        return ($hi << 32) | $lo;
    }
    $nh = (($hi << $k) | ($lo >> (32 - $k))) & 0xFFFFFFFF;
    $nl = (($lo << $k) | ($hi >> (32 - $k))) & 0xFFFFFFFF;
    return ($nh << 32) | $nl;
}

// The idiom under test, with constant counts so the JIT sees constants.
function rot(int $x): array {
    return [
        ($x << 1) | (($x >> 63) & 0x1),
        ($x << 3) | (($x >> 61) & 0x7),
        ($x << 8) | (($x >> 56) & 0xFF),
        ($x << 31) | (($x >> 33) & 0x7FFFFFFF),
        ($x << 32) | (($x >> 32) & 0xFFFFFFFF),
        ($x << 45) | (($x >> 19) & 0x1FFFFFFFFFFF),
        ($x << 63) | (($x >> 1) & 0x7FFFFFFFFFFFFFFF),
    ];
}
const KS = [1, 3, 8, 31, 32, 45, 63];

$values = [0, 1, -1, 2, PHP_INT_MAX, PHP_INT_MIN, 0x123456789ABCDEF, -0x123456789ABCDEF,
           0x5555555555555555, -6148914691236517206];
mt_srand(42);
for ($i = 0; $i < 200; $i++) {
    $values[] = (mt_rand() << 33) ^ (mt_rand() << 11) ^ mt_rand();
}

$bad = 0;
for ($round = 0; $round < 5; $round++) {
    foreach ($values as $v) {
        $got = rot($v);
        foreach (KS as $i => $k) {
            if ($got[$i] !== rotl_ref($v, $k)) {
                $bad++;
            }
        }
    }
}
var_dump($bad);

// A mask that is NOT exactly ~0 >> N must keep its meaning.
function not_a_rotate(int $x): int {
    return ($x >> 4) & 0xFF;
}
for ($i = 0; $i < 300; $i++) {
    $v = (mt_rand() << 33) ^ mt_rand();
    if (not_a_rotate($v) !== (($v >> 4) & 0xFF)) {
        $bad++;
    }
}
var_dump($bad);
?>
--EXPECT--
int(0)
int(0)

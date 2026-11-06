--TEST--
Strict comparison (===, !==, match) of strings and integers
--FILE--
<?php

function dyn(string $s): string { return $s . ''; }
function show(string $label, bool ...$r): void {
    echo $label, ': ', implode(' ', array_map(fn($b) => $b ? 'T' : 'F', $r)), "\n";
}

$empty = '';
$nul = "a\0b";
$nul2 = "a\0c";

echo "-- strings (literal vs variable) --\n";
$s = 'alpha';
show('same literal', $s === 'alpha', $s !== 'alpha');
show('different', $s === 'beta', $s !== 'beta');
show('prefix', $s === 'alph', $s === 'alphab', $s !== 'alph');
show('case', $s === 'ALPHA', $s !== 'ALPHA');
show('empty', $empty === '', $empty !== '', $s === '', '' === $s);

echo "-- non-interned strings --\n";
$d1 = dyn('hello');
$d2 = dyn('hello');
$d3 = dyn('hellp');
show('dyn/dyn', $d1 === $d2, $d1 !== $d2, $d1 === $d3, $d1 !== $d3);
show('dyn/literal', $d1 === 'hello', 'hello' === $d1, $d1 !== 'hello', $d3 === 'hello');

echo "-- binary strings --\n";
show('nul', $nul === "a\0b", $nul === $nul2, $nul === "a", $nul !== $nul2);
show('nul prefix', "a\0" === "a", "a" === "a\0", "\0" === "\0\0", "\0" === "");

echo "-- numeric strings are strings --\n";
show('numeric', '1' === '1', '1' === '01', '1' === '1.0', '1e1' === '10', '10' === ' 10', '0' === '', '0' === '-0');
$n = '1';
show('str vs int', $n === 1, 1 === $n, $n !== 1, '1' !== 1);
show('str vs float', '1.5' === 1.5, '1.5' !== 1.5);
show('str vs bool/null', '' === null, '' === false, '1' === true, '0' === false, '' !== null);
show('str vs array', 'Array' === [], 'a' === ['a']);

echo "-- integers --\n";
$i = 3;
show('same', $i === 3, 3 === $i, $i !== 3);
show('different', $i === 4, $i !== 4, $i === -3, $i === 0);
show('zero', 0 === 0, 0 === -0, 0 !== 0);
show('int min/max', PHP_INT_MIN === PHP_INT_MIN, PHP_INT_MAX === PHP_INT_MAX, PHP_INT_MIN === PHP_INT_MAX, PHP_INT_MIN !== PHP_INT_MIN);
$min = PHP_INT_MIN;
$max = PHP_INT_MAX;
show('min var', $min === PHP_INT_MIN, $min === -PHP_INT_MAX - 1, $min === -$max, $min !== $max, $min === 0);
show('int vs float', $i === 3.0, 3 === 3.0, $i !== 3.0);
show('int vs bool/null', 1 === true, 0 === false, 0 === null, 1 !== true);
show('int vs numeric string', 5 === '5', '5' === 5);

echo "-- float, bool, null, array (other types) --\n";
$nan = NAN;
show('nan', $nan === NAN, $nan !== NAN, NAN === NAN);
show('zero float', 0.0 === -0.0, 0.0 !== -0.0);
show('float', 1.5 === 1.5, 1.5 === 1.6, 1.5 !== 1.5);
show('null/bool', null === null, true === true, false === false, true === false, null === false);
show('array', [1] === [1], [1] === [1, 2], [1, 2] === [2 => 1], ['a' => 1] === ['a' => 1], [1, 2] === [1 => 2, 0 => 1]);

echo "-- match --\n";
function m(mixed $v): string {
    return match ($v) {
        'alpha' => 'string alpha',
        '' => 'empty string',
        "a\0b" => 'nul string',
        '1' => 'string 1',
        1 => 'int 1',
        PHP_INT_MIN => 'int min',
        PHP_INT_MAX => 'int max',
        1.5 => 'float',
        null => 'null',
        true => 'true',
        default => 'default',
    };
}
foreach (['alpha', dyn('alpha'), '', "a\0b", "a\0c", '1', 1, PHP_INT_MIN, PHP_INT_MAX, 1.5, null, true, false, 0, '0', 'ALPHA', [], 1.0] as $v) {
    echo str_pad(var_export($v, true), 24), ' => ', m($v), "\n";
}

echo "-- match (true) with identity conditions --\n";
$a = dyn('x'); $b = dyn('x'); $c = dyn('y');
echo match (true) { $a === $b => 'eq', default => 'ne' }, "\n";
echo match (true) { $a === $c => 'eq', default => 'ne' }, "\n";
echo match (true) { $a !== $c => 'ne', default => 'eq' }, "\n";

echo "-- references --\n";
$x = 'ref'; $r = &$x;
show('ref string', $r === 'ref', $x === $r, $r !== 'ref');
$y = 7; $ry = &$y;
show('ref int', $ry === 7, $ry === '7', $ry !== 7);

echo "-- result used as value --\n";
var_dump('a' === 'a', 'a' !== 'a', 1 === 1, 1 !== 1);
$t = [dyn('k') === 'k', dyn('k') !== 'k'];
var_dump($t);

?>
--EXPECT--
-- strings (literal vs variable) --
same literal: T F
different: F T
prefix: F F T
case: F T
empty: T F F F
-- non-interned strings --
dyn/dyn: T F F T
dyn/literal: T T F F
-- binary strings --
nul: T F F T
nul prefix: F F F F
-- numeric strings are strings --
numeric: T F F F F F F
str vs int: F F T T
str vs float: F T
str vs bool/null: F F F F T
str vs array: F F
-- integers --
same: T T F
different: F T F F
zero: T T F
int min/max: T T F F
min var: T T F T F
int vs float: F F T
int vs bool/null: F F F T
int vs numeric string: F F
-- float, bool, null, array (other types) --
nan: F T F
zero float: T F
float: T F F
null/bool: T T T F F
array: T F F T F
-- match --
'alpha'                  => string alpha
'alpha'                  => string alpha
''                       => empty string
'a' . "\0" . 'b'         => nul string
'a' . "\0" . 'c'         => default
'1'                      => string 1
1                        => int 1
-9223372036854775807-1   => int min
9223372036854775807      => int max
1.5                      => float
NULL                     => null
true                     => true
false                    => default
0                        => default
'0'                      => default
'ALPHA'                  => default
array (
)                => default
1.0                      => default
-- match (true) with identity conditions --
eq
ne
ne
-- references --
ref string: T T F
ref int: T F F
-- result used as value --
bool(true)
bool(false)
bool(true)
bool(false)
array(2) {
  [0]=>
  bool(true)
  [1]=>
  bool(false)
}

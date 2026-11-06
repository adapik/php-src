--TEST--
in_array()/array_search()/array_keys() strict mode with a string needle
--FILE--
<?php

function dyn(string $s): string { return $s . ''; }

$list = ['alpha', 'beta', 'gamma', '', "a\0b", 'kappa'];

echo "-- found / not found --\n";
var_dump(in_array('kappa', $list, true));
var_dump(in_array('nope', $list, true));
var_dump(in_array('', $list, true));
var_dump(in_array("a\0b", $list, true));
var_dump(in_array("a\0c", $list, true));
var_dump(in_array("a", $list, true));
var_dump(array_search('gamma', $list, true));
var_dump(array_search('nope', $list, true));
var_dump(array_search('', $list, true));
var_dump(array_search("a\0b", $list, true));

echo "-- non-interned needle and elements --\n";
$dyn = array_map('dyn', ['alpha', 'beta']);
var_dump(in_array(dyn('beta'), $dyn, true));
var_dump(array_search(dyn('alpha'), $dyn, true));
var_dump(in_array(dyn('alpha'), ['alpha'], true));
var_dump(in_array('alpha', [dyn('alpha')], true));

echo "-- string and integer keys --\n";
var_dump(array_search('b', ['x' => 'a', 'y' => 'b', 7 => 'c'], true));
var_dump(array_search('c', ['x' => 'a', 'y' => 'b', 7 => 'c'], true));
var_dump(array_search('z', ['x' => 'a'], true));

echo "-- type juggling must not match --\n";
var_dump(in_array('1', [1, 1.0, true, [1], null], true));
var_dump(in_array('', [null, false, 0, []], true));
var_dump(in_array('0', [0, false, null, 0.0], true));
var_dump(in_array('1e1', ['10', 10, 10.0], true));
var_dump(in_array('abc', [0, true, new stdClass], true));
var_dump(in_array('1', ['01', ' 1', '1 ', '1.0'], true));
var_dump(array_search('1', [1, '1'], true));

echo "-- references --\n";
$s = 'ref';
$arr = [1, &$s, 3];
var_dump(in_array('ref', $arr, true));
var_dump(array_search('ref', $arr, true));
$s = 'changed';
var_dump(in_array('ref', $arr, true));
var_dump(array_search('changed', $arr, true));
$i = 5;
$arr = ['a', &$i];
var_dump(in_array('5', $arr, true));

echo "-- packed array with holes --\n";
$packed = ['a', 'b', 'c', 'd'];
unset($packed[1], $packed[2]);
var_dump(in_array('b', $packed, true));
var_dump(array_search('d', $packed, true));
var_dump(array_search('a', $packed, true));

echo "-- hash array with holes --\n";
$hash = ['x' => 'a', 'y' => 'b', 'z' => 'c'];
unset($hash['y']);
var_dump(in_array('b', $hash, true));
var_dump(array_search('c', $hash, true));

echo "-- same length, same prefix --\n";
var_dump(in_array('abcd', ['abce', 'abcc', 'abcd'], true));
var_dump(array_search('abcd', ['abce', 'abcc'], true));

echo "-- empty array --\n";
var_dump(in_array('a', [], true));
var_dump(array_search('a', [], true));

echo "-- array_keys --\n";
var_dump(array_keys(['a', 'b', 'a', 1, '1', 'a'], 'a', true));
var_dump(array_keys(['x' => 'a', 'y' => 'b', 'z' => 'a'], 'a', true));
var_dump(array_keys([1, '1', 1.0, true, 'a'], '1', true));
var_dump(array_keys(['q', 'r'], 'zz', true));
var_dump(array_keys(['a', 'b'], dyn('b'), true));
$s = 'ref';
var_dump(array_keys([&$s, 'ref', 'other'], 'ref', true));

echo "-- other needle types still work --\n";
var_dump(in_array(1.5, [1, 1.5], true));
var_dump(in_array(NAN, [NAN], true));
var_dump(in_array(0.0, [-0.0], true));
var_dump(in_array(null, [0, null], true));
var_dump(in_array(true, [1, true], true));
var_dump(in_array([1, 2], [[1, 2]], true));
var_dump(in_array([1, 2], [[2, 1]], true));
var_dump(array_search(PHP_INT_MIN, ['a', PHP_INT_MIN], true));
var_dump(array_search(PHP_INT_MAX, ['9223372036854775807', PHP_INT_MAX], true));

?>
--EXPECT--
-- found / not found --
bool(true)
bool(false)
bool(true)
bool(true)
bool(false)
bool(false)
int(2)
bool(false)
int(3)
int(4)
-- non-interned needle and elements --
bool(true)
int(0)
bool(true)
bool(true)
-- string and integer keys --
string(1) "y"
int(7)
bool(false)
-- type juggling must not match --
bool(false)
bool(false)
bool(false)
bool(false)
bool(false)
bool(false)
int(1)
-- references --
bool(true)
int(1)
bool(false)
int(1)
bool(false)
-- packed array with holes --
bool(false)
int(3)
int(0)
-- hash array with holes --
bool(false)
string(1) "z"
-- same length, same prefix --
bool(true)
bool(false)
-- empty array --
bool(false)
bool(false)
-- array_keys --
array(3) {
  [0]=>
  int(0)
  [1]=>
  int(2)
  [2]=>
  int(5)
}
array(2) {
  [0]=>
  string(1) "x"
  [1]=>
  string(1) "z"
}
array(1) {
  [0]=>
  int(1)
}
array(0) {
}
array(1) {
  [0]=>
  int(1)
}
array(2) {
  [0]=>
  int(0)
  [1]=>
  int(1)
}
-- other needle types still work --
bool(true)
bool(false)
bool(true)
bool(true)
bool(true)
bool(true)
bool(false)
int(1)
int(1)

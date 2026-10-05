--TEST--
array_map() with first-class callable and constant string array argument does not leak
--FILE--
<?php
try {
    array_map(strtoupper(...), "str");
} catch (TypeError $e) {
    echo $e->getMessage(), "\n";
}
?>
--EXPECT--
array_map(): Argument #2 ($array) must be of type array, string given

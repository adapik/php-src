--TEST--
Readonly property error must not leave a primed cache slot that bypasses scope checks in __clone()
--FILE--
<?php

class Test {
    public function __construct(public readonly int $prop) {}
    public function __clone() { write($this); }
}

function write($t) {
    try {
        $t->prop = 42;
        echo "write ok\n";
    } catch (Error $e) {
        echo $e->getMessage(), "\n";
    }
}

$t = new Test(1);
write($t);
$c = clone $t;
var_dump($c->prop);

?>
--EXPECT--
Cannot modify readonly property Test::$prop
Cannot modify protected(set) readonly property Test::$prop from global scope
int(1)

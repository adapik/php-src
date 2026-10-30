--TEST--
Asymmetric visibility: write forwarded to __set() must not prime the cache slot for the fast path
--FILE--
<?php

class A {
    public private(set) int $p;
    public function __set($name, $value) {
        echo "__set\n";
        $this->p = $value;
    }
    public function drop() {
        unset($this->p);
    }
}

function write($o, $v) {
    try {
        $o->p = $v;
        echo "write ok\n";
    } catch (Error $e) {
        echo $e->getMessage(), "\n";
    }
}

$a = new A;
$a->drop();
write($a, 1);
var_dump($a->p);
write($a, 2);
var_dump($a->p);

?>
--EXPECT--
__set
write ok
int(1)
Cannot modify private(set) property A::$p from global scope
int(1)

--TEST--
No trailing zeros are left when an exact tie is rounded down during float to string conversion
--INI--
precision=14
serialize_precision=10
--FILE--
<?php

var_dump(sprintf('%.3G', 370500.0));
var_dump(sprintf('%.9g', -81320560005.0));
var_dump((string) 183037915746105.0);
var_dump(var_export(81320560005.0, true));
var_dump(json_encode(81320560005.0));
var_dump(serialize(81320560005.0));

?>
--EXPECT--
string(6) "3.7E+5"
string(13) "-8.132056e+10"
string(18) "1.830379157461E+14"
string(12) "8.132056E+10"
string(12) "8.132056e+10"
string(15) "d:8.132056E+10;"

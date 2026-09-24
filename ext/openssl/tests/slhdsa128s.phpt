--TEST--
openssl_*() with SLH-DSA-SHA2-128s (post-quantum signature) keys
--EXTENSIONS--
openssl
--SKIPIF--
<?php
if (OPENSSL_VERSION_NUMBER < 0x30500000) die("skip requires OpenSSL >= 3.5");
if (openssl_pkey_get_private("file://" . __DIR__ . "/pqc_slhdsa128s_1.key") === false) {
    die("skip SLH-DSA-SHA2-128s not available in this OpenSSL build");
}
?>
--FILE--
<?php
echo "Testing openssl_pkey_get_private/openssl_pkey_get_public\n";
$priv1 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_slhdsa128s_1.key");
var_dump($priv1);
$pub1 = openssl_pkey_get_public("file://" . __DIR__ . "/pqc_slhdsa128s_1.pub");
var_dump($pub1);
$priv2 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_slhdsa128s_2.key");
var_dump($priv2);

echo "Testing openssl_pkey_get_details\n";
$d1 = openssl_pkey_get_details($priv1);
// The bit length is fixed by the FIPS 205 SLH-DSA-SHA2-128s parameter set.
var_dump($d1["bits"] === 256);
var_dump(str_starts_with($d1["key"], "-----BEGIN PUBLIC KEY-----"));
$pub1_from_details = openssl_pkey_get_public($d1["key"]);
var_dump($pub1_from_details);
$d1_pub = openssl_pkey_get_details($pub1_from_details);
var_dump($d1["key"] === $d1_pub["key"]);
$d_pub1 = openssl_pkey_get_details($pub1);
var_dump($d1["key"] === $d_pub1["key"]);

echo "Testing openssl_sign and openssl_verify with algorithm = 0\n";
$payload = "Testing SLH-DSA-SHA2-128s signatures";
var_dump(openssl_sign($payload, $signature, $priv1, 0));
var_dump(openssl_verify($payload, $signature, $pub1, 0));

echo "Verification fails for tampered data\n";
var_dump(openssl_verify($payload . "!", $signature, $pub1, 0));

echo "Verification fails for a different key\n";
$pub2 = openssl_pkey_get_public("file://" . __DIR__ . "/pqc_slhdsa128s_2.pub");
var_dump(openssl_verify($payload, $signature, $pub2, 0));

echo "Signing with the default digest algorithm fails without a warning-free crash\n";
var_dump(@openssl_sign($payload, $unused, $priv1));
?>
--EXPECTF--
Testing openssl_pkey_get_private/openssl_pkey_get_public
object(OpenSSLAsymmetricKey)#%d (0) {
}
object(OpenSSLAsymmetricKey)#%d (0) {
}
object(OpenSSLAsymmetricKey)#%d (0) {
}
Testing openssl_pkey_get_details
bool(true)
bool(true)
object(OpenSSLAsymmetricKey)#%d (0) {
}
bool(true)
bool(true)
Testing openssl_sign and openssl_verify with algorithm = 0
bool(true)
int(1)
Verification fails for tampered data
int(0)
Verification fails for a different key
int(0)
Signing with the default digest algorithm fails without a warning-free crash
bool(false)

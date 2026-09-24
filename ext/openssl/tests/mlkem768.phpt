--TEST--
openssl_*() with ML-KEM-768 (post-quantum KEM) keys
--EXTENSIONS--
openssl
--SKIPIF--
<?php
if (OPENSSL_VERSION_NUMBER < 0x30500000) die("skip requires OpenSSL >= 3.5");
if (openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mlkem768.key") === false) {
    die("skip ML-KEM-768 not available in this OpenSSL build");
}
?>
--FILE--
<?php
echo "Testing openssl_pkey_get_private/openssl_pkey_get_public\n";
$priv = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mlkem768.key");
var_dump($priv);
$pub = openssl_pkey_get_public("file://" . __DIR__ . "/pqc_mlkem768.pub");
var_dump($pub);

echo "Testing openssl_pkey_get_details\n";
$d = openssl_pkey_get_details($priv);
// The bit length is fixed by the FIPS 203 ML-KEM-768 parameter set.
var_dump($d["bits"] === 768);
var_dump(str_starts_with($d["key"], "-----BEGIN PUBLIC KEY-----"));

// The public key PEM exposed via get_details() must itself be loadable.
$pub_from_details = openssl_pkey_get_public($d["key"]);
var_dump($pub_from_details);
$d_pub_from_details = openssl_pkey_get_details($pub_from_details);
var_dump($d["key"] === $d_pub_from_details["key"]);
var_dump($d["bits"] === $d_pub_from_details["bits"]);

// Public key derived from the private key must match the standalone public key fixture.
$d_pub = openssl_pkey_get_details($pub);
var_dump($d["key"] === $d_pub["key"]);
?>
--EXPECTF--
Testing openssl_pkey_get_private/openssl_pkey_get_public
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
bool(true)

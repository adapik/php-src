--TEST--
openssl_*() with ML-DSA-65 (post-quantum signature) keys
--EXTENSIONS--
openssl
--SKIPIF--
<?php
if (OPENSSL_VERSION_NUMBER < 0x30500000) die("skip requires OpenSSL >= 3.5");
if (openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_1.key") === false) {
    die("skip ML-DSA-65 not available in this OpenSSL build");
}
?>
--FILE--
<?php
echo "Testing openssl_pkey_get_private/openssl_pkey_get_public\n";
$priv1 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_1.key");
var_dump($priv1);
$pub1 = openssl_pkey_get_public("file://" . __DIR__ . "/pqc_mldsa65_1.pub");
var_dump($pub1);
$priv2 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_2.key");
var_dump($priv2);

echo "Testing openssl_pkey_get_details\n";
$d1 = openssl_pkey_get_details($priv1);
// The bit length is fixed by the FIPS 204 ML-DSA-65 parameter set.
var_dump($d1["bits"] === 15616);
var_dump(str_starts_with($d1["key"], "-----BEGIN PUBLIC KEY-----"));
// The public key PEM exposed via get_details() must itself be loadable.
$pub1_from_details = openssl_pkey_get_public($d1["key"]);
var_dump($pub1_from_details);
$d1_pub = openssl_pkey_get_details($pub1_from_details);
var_dump($d1["key"] === $d1_pub["key"]);
var_dump($d1["bits"] === $d1_pub["bits"]);
// Public key derived from the private key must match the standalone public key fixture.
$d_pub1 = openssl_pkey_get_details($pub1);
var_dump($d1["key"] === $d_pub1["key"]);

echo "Testing openssl_sign and openssl_verify with algorithm = 0\n";
$payload = "Testing ML-DSA-65 signatures";
var_dump(openssl_sign($payload, $signature, $priv1, 0));
var_dump(openssl_verify($payload, $signature, $pub1, 0));

echo "Verification fails for tampered data\n";
var_dump(openssl_verify($payload . "!", $signature, $pub1, 0));

echo "Verification fails for a different key\n";
$pub2 = openssl_pkey_get_public("file://" . __DIR__ . "/pqc_mldsa65_2.pub");
var_dump(openssl_verify($payload, $signature, $pub2, 0));

echo "Signing with the default digest algorithm fails without a warning-free crash\n";
var_dump(@openssl_sign($payload, $unused, $priv1));

echo "Testing CSR and self-signed certificate generation\n";
$dn = array(
    "countryName" => "US",
    "organizationName" => "PHP",
    "commonName" => "ML-DSA-65 test certificate",
);
$config = __DIR__ . DIRECTORY_SEPARATOR . 'openssl.cnf';
$args = array(
    "config" => $config,
    "digest_alg" => "null",
);

$csr = openssl_csr_new($dn, $priv1, $args);
var_dump($csr);

$pubkey_csr = openssl_pkey_get_details(openssl_csr_get_public_key($csr));
var_dump($pubkey_csr["key"] === $d1["key"]);

// Long validity so the fixture-independent certificate never expires.
$x509 = openssl_csr_sign($csr, null, $priv1, 7300, $args);
var_dump($x509);

echo "Testing openssl_x509_parse signature algorithm name\n";
$parsed = openssl_x509_parse($x509);
// The textual name is stable across OpenSSL 3.5 and 4.x; the numeric NID is not asserted.
var_dump($parsed["signatureTypeSN"] === "id-ml-dsa-65");
var_dump($parsed["signatureTypeLN"] === "ML-DSA-65");

echo "Testing openssl_x509_verify and openssl_x509_check_private_key\n";
var_dump(openssl_x509_verify($x509, $pub1));
var_dump(openssl_x509_check_private_key($x509, $priv1));
var_dump(openssl_x509_check_private_key($x509, $priv2));
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
Testing CSR and self-signed certificate generation
object(OpenSSLCertificateSigningRequest)#%d (0) {
}
bool(true)
object(OpenSSLCertificate)#%d (0) {
}
Testing openssl_x509_parse signature algorithm name
bool(true)
bool(true)
Testing openssl_x509_verify and openssl_x509_check_private_key
int(1)
bool(true)
bool(false)

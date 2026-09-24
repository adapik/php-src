--TEST--
openssl_cms_sign() and openssl_cms_verify() with an ML-DSA-65 certificate
--EXTENSIONS--
openssl
--SKIPIF--
<?php
if (OPENSSL_VERSION_NUMBER < 0x40000000) die("skip requires OpenSSL >= 4.0 for CMS with ML-DSA-65");
if (openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_1.key") === false) {
    die("skip ML-DSA-65 not available in this OpenSSL build");
}
?>
--FILE--
<?php
// Self-signed certificate generated on the fly with a long validity period
// so that this fixture-independent certificate never expires.
function make_cert($key, $cn) {
    $dn = array(
        "countryName" => "US",
        "organizationName" => "PHP",
        "commonName" => $cn,
    );
    $args = array(
        "config" => __DIR__ . DIRECTORY_SEPARATOR . 'openssl.cnf',
        "digest_alg" => "null",
    );
    $csr = openssl_csr_new($dn, $key, $args);
    return openssl_csr_sign($csr, null, $key, 7300, $args);
}

$priv1 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_1.key");
$x509_1 = make_cert($priv1, "ML-DSA-65 CMS test certificate");

$priv2 = openssl_pkey_get_private("file://" . __DIR__ . "/pqc_mldsa65_2.key");
$x509_2 = make_cert($priv2, "ML-DSA-65 CMS test certificate (other key)");

$infile = __DIR__ . "/plain.txt";
$outfile = tempnam(sys_get_temp_dir(), "pqc_cms");
$vout = $outfile . ".vout";

echo "Testing openssl_cms_sign\n";
var_dump(openssl_cms_sign($infile, $outfile, $x509_1, $priv1, []));

echo "Testing openssl_cms_verify with the signing certificate\n";
var_dump(openssl_cms_verify($outfile, OPENSSL_CMS_NOVERIFY, null, [], null, $vout));
// CMS/S-MIME canonicalizes line endings to CRLF, so normalize before comparing.
$normalize = fn($s) => str_replace("\r\n", "\n", $s);
var_dump($normalize(file_get_contents($vout)) === $normalize(file_get_contents($infile)));

echo "Testing openssl_cms_verify with a different certificate\n";
var_dump(@openssl_cms_verify($outfile, OPENSSL_CMS_NOINTERN | OPENSSL_CMS_NOVERIFY, null, [], "file://" . __DIR__ . "/pqc_mldsa65_1.pub"));
openssl_x509_export($x509_2, $other_cert_pem);
$other_certfile = tempnam(sys_get_temp_dir(), "pqc_cms_other_cert");
file_put_contents($other_certfile, $other_cert_pem);
var_dump(@openssl_cms_verify($outfile, OPENSSL_CMS_NOINTERN | OPENSSL_CMS_NOVERIFY, null, [], $other_certfile));

unlink($outfile);
unlink($vout);
unlink($other_certfile);
?>
--EXPECT--
Testing openssl_cms_sign
bool(true)
Testing openssl_cms_verify with the signing certificate
bool(true)
bool(true)
Testing openssl_cms_verify with a different certificate
bool(false)
bool(false)

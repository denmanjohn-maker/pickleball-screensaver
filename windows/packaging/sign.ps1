param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
if (-not $env:WINDOWS_SIGNING_PFX_BASE64 -or -not $env:WINDOWS_SIGNING_PASSWORD -or -not $env:WINDOWS_TIMESTAMP_URL) {
    throw 'Explicit Windows signing identity, password and timestamp URL are required'
}
$url = [Uri]$env:WINDOWS_TIMESTAMP_URL
if ($url.Scheme -ne 'https') { throw 'Timestamp server must use HTTPS' }
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [Convert]::FromBase64String($env:WINDOWS_SIGNING_PFX_BASE64),$env:WINDOWS_SIGNING_PASSWORD,
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
try {
    if (-not $certificate.HasPrivateKey) { throw 'Certificate has no private key' }
    $signature = Set-AuthenticodeSignature -FilePath $Path -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $url.AbsoluteUri
    if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) { throw 'Signing or trusted timestamp validation failed' }
} finally { $certificate.Dispose() }

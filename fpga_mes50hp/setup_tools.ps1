$ErrorActionPreference = 'Stop'
$archiveHash = '5FD5AE5177D88999E333DB21CDFA1796E60E557586DF10BC0BDD378B94E9EB71'
$executableHash = '1F3C2B96E212592E6F4A2ECFF3209F211277834540D8A9309ECEE50A45ADC699'
$downloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('pds-sv2v-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $downloadDirectory | Out-Null
$archivePath = Join-Path $downloadDirectory 'sv2v-Windows.zip'
curl.exe -fLsS --connect-timeout 15 --max-time 180 --retry 2 'https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Windows.zip' -o $archivePath
if ($LASTEXITCODE -ne 0) { throw 'sv2v download failed.' }
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $archiveHash) { throw 'Unexpected sv2v archive checksum.' }
Expand-Archive -LiteralPath $archivePath -DestinationPath $downloadDirectory
$extractedDirectory = Join-Path $downloadDirectory 'sv2v-Windows'
if ((Get-FileHash -LiteralPath (Join-Path $extractedDirectory 'sv2v.exe') -Algorithm SHA256).Hash -ne $executableHash) { throw 'Unexpected sv2v executable checksum.' }
$toolDirectory = Join-Path $PSScriptRoot 'tools\sv2v'
New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
foreach ($filename in @('sv2v.exe', 'LICENSE', 'NOTICE', 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $extractedDirectory $filename) -Destination $toolDirectory
}
Write-Output ('Installed sv2v v0.0.13 in ' + $toolDirectory)

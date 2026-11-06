#requires -Version 5.1
function Get-DefaultBranding {
    [pscustomobject]@{Name='Directory Lens'; Subtitle='DIRECTORY LOOKUP'; Accent='#1469C0'; Logo=$false}
}
function Test-Branding($Brand) {
    if (-not $Brand -or [string]::IsNullOrWhiteSpace($Brand.Name) -or $Brand.Name.Length -gt 48 -or $Brand.Name -match '[\x00-\x1f]') { throw 'App name must contain 1-48 characters without line breaks.' }
    if ($null -eq $Brand.Subtitle -or $Brand.Subtitle.Length -gt 64 -or $Brand.Subtitle -match '[\x00-\x1f]') { throw 'Subtitle must contain at most 64 characters without line breaks.' }
    if ($Brand.Accent -notmatch '^#[0-9a-fA-F]{6}$') { throw 'Accent color must be a six-digit hex color, for example #1469C0.' }
    if ($Brand.Logo -isnot [bool]) { throw 'Logo setting must be true or false.' }
}
function Read-Branding([string]$Root) {
    $path=Join-Path $Root 'branding\settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return Get-DefaultBranding }
    $brand=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Branding $brand
    return $brand
}
function Write-Branding([string]$Root,$Brand) {
    Test-Branding $Brand
    $dir=Join-Path $Root 'branding'
    [void][IO.Directory]::CreateDirectory($dir)
    $temp=Join-Path $dir ([guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($temp,($Brand | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination (Join-Path $dir 'settings.json') -Force
}
function Get-BrandLogo([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 5MB) { throw 'Choose a PNG logo smaller than 5 MB.' }
    $stream=[IO.File]::OpenRead($Path)
    try {
        $decoder=[Windows.Media.Imaging.PngBitmapDecoder]::new($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame=$decoder.Frames[0]
        if ($frame.PixelWidth -gt 4096 -or $frame.PixelHeight -gt 4096) { throw 'Logo dimensions must not exceed 4096 pixels.' }
        $frame.Freeze()
        return $frame
    } finally { $stream.Dispose() }
}

param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Runtime = "win-x64",
    [ValidateSet("uat", "preview", "prod")]
    [string]$Environment = "preview",
    [string]$Channel = "",
    [string]$OutputDir = ".\Releases",
    [string]$Framework = "net8.0-x64-desktop",
    [switch]$Upload,
    [string]$R2Endpoint = $env:R2_ENDPOINT,
    [string]$R2Bucket = $env:R2_BUCKET,
    [string]$R2KeyId = $env:R2_KEY_ID,
    [string]$R2Secret = $env:R2_SECRET,
    [string]$R2Region = "auto",
    [int]$KeepMaxReleases = 8,
    [string]$InnoSetupCompiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = "Stop"

$packageId = "lobster-input"
$packageTitle = "龙虾输入法"
if ([string]::IsNullOrWhiteSpace($Channel)) {
    $Channel = $Environment
}

if ($Version -notmatch '^\d+\.\d+\.\d+([\-+][0-9A-Za-z\-.+]+)?$') {
    throw "Version must be SemVer2 without a fourth version segment, for example 1.2.3 or 1.2.3-beta.1."
}

if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) {
    throw "Velopack CLI 'vpk' was not found. Install it first, then rerun this script."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$publishDir = Join-Path $repoRoot "artifacts\publish\$Runtime"
$projectPath = Join-Path $repoRoot "LobsterInput\LobsterInput.csproj"
$iconPath = Join-Path $repoRoot "LobsterInput\Resources\Images\lobster.ico"
$constants = switch ($Environment) {
    "uat" { "LOBSTER_UAT" }
    "prod" { "LOBSTER_PROD" }
    default { "" }
}
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $repoRoot $OutputDir
}
$channelOutputDir = Join-Path $outputRoot $Channel

Remove-Item -LiteralPath $publishDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
New-Item -ItemType Directory -Path $channelOutputDir -Force | Out-Null

dotnet publish $projectPath `
    -c Release `
    -r $Runtime `
    -o $publishDir `
    --self-contained false `
    /p:Version=$Version `
    /p:DefineConstants=$constants

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

vpk pack `
    --packId $packageId `
    --packTitle $packageTitle `
    --packAuthors $packageTitle `
    --packVersion $Version `
    --packDir $publishDir `
    --mainExe LobsterInput.exe `
    --icon $iconPath `
    --framework $Framework `
    --runtime $Runtime `
    --shortcuts None `
    --channel $Channel `
    --outputDir $channelOutputDir

if ($LASTEXITCODE -ne 0) {
    throw "Velopack pack failed with exit code $LASTEXITCODE."
}

$innoScript = Join-Path $repoRoot "installer\lobster-input-setup.iss"
if (Test-Path $InnoSetupCompiler) {
    & $InnoSetupCompiler `
        "/DAppVersion=$Version" `
        "/DChannel=$Channel" `
        $innoScript

    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
}
else {
    Write-Warning "Inno Setup compiler was not found at '$InnoSetupCompiler'. Velopack package was generated, but the formal installer was skipped."
}

if ($Upload) {
    if ([string]::IsNullOrWhiteSpace($R2Endpoint) -or
        [string]::IsNullOrWhiteSpace($R2Bucket) -or
        [string]::IsNullOrWhiteSpace($R2KeyId) -or
        [string]::IsNullOrWhiteSpace($R2Secret)) {
        throw "R2 upload requires R2_ENDPOINT, R2_BUCKET, R2_KEY_ID and R2_SECRET."
    }

    $uploadArgs = @(
        "upload", "s3",
        "--outputDir", $channelOutputDir,
        "--channel", $Channel,
        "--bucket", $R2Bucket,
        "--prefix", "$Environment/windows",
        "--keyId", $R2KeyId,
        "--secret", $R2Secret,
        "--keepMaxReleases", "$KeepMaxReleases"
    )

    if (-not [string]::IsNullOrWhiteSpace($R2Endpoint)) {
        $uploadArgs += @("--endpoint", $R2Endpoint)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($R2Region)) {
        $uploadArgs += @("--region", $R2Region)
    }

    & vpk @uploadArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Velopack upload failed with exit code $LASTEXITCODE."
    }
}

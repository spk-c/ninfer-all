
# Build and publish verified RTX 4090 binaries for an EXISTING GitHub release tag.
# Run this script on your RTX 4090 Windows PC. GitHub Actions is not required.
# The script builds in a detached worktree at the RELEASE TAG, not at master.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Model,
    [string]$Tag = 'rtx4090-v0.1.0',
    [ValidateRange(1,32)][int]$Jobs = 8,
    [ValidateRange(1024,65535)][int]$SmokePort = 18091,
    [switch]$KeepWorktree
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Repo = 'spk-c/ninfer-all-rtx4090'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Model = (Resolve-Path -LiteralPath $Model -ErrorAction Stop).Path
$Notes = Join-Path $Root 'docs/releases/rtx4090-v0.1.0.md'
$Worktree = Join-Path ([IO.Path]::GetTempPath()) ("ninfer-rtx4090-release-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$WorktreeAdded = $false
$Success = $false
$Server = $null
$PreviousVersion = $env:NINFER_VERSION

function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

try {
    foreach ($command in @('git','gh','cmake','ninja','7z','nvidia-smi')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required executable missing: $command" }
    }
    if (-not (Test-Path -LiteralPath $Notes -PathType Leaf)) { throw 'Release notes missing; first update the fork checkout' }
    $Gpus = @(& nvidia-smi --query-gpu=name --format=csv,noheader)
    if ($LASTEXITCODE -ne 0 -or -not ($Gpus | Where-Object { $_ -match 'GeForce RTX 4090' })) { throw 'No RTX 4090 detected; refusing to qualify the build' }
    Run 'gh' @('auth','status','--hostname','github.com')
    Run 'gh' @('release','view',$Tag,'--repo',$Repo)
    Run 'git' @('-C',$Root,'fetch','origin',('refs/tags/{0}:refs/tags/{0}' -f $Tag))
    $TagCommit = (& git -C $Root rev-parse ('refs/tags/{0}^{{commit}}' -f $Tag)).Trim()
    if ($LASTEXITCODE -ne 0 -or $TagCommit -notmatch '^[a-f0-9]{40}$') { throw 'Cannot resolve release source revision' }
    Write-Host "Release tag $Tag points to $TagCommit"
    Run 'git' @('-C',$Root,'worktree','add','--detach',$Worktree,$TagCommit)
    $WorktreeAdded = $true
    $env:NINFER_VERSION = $Tag
    $BuildDir = Join-Path $Worktree 'build-rtx4090-release'
    $Builder = Join-Path $Worktree 'scripts/build.ps1'
    & $Builder -Arch 89 -CudaVersion 13.4 -BuildDir $BuildDir -Jobs $Jobs -Test -Package
    if (-not $?) { throw 'Build / test / package command failed' }
    $Dist = Join-Path $Worktree 'dist'
    $Prefix = 'ninfer-windows-x64-cuda13.4-sm89-' + $TagCommit.Substring(0,12)
    $Product = Join-Path $Dist $Prefix
    $MetaPath = Join-Path $Product 'BUILD-INFO.json'
    if (-not (Test-Path $MetaPath)) { throw "Packager did not create BUILD-INFO.json at $MetaPath" }
    $Meta = Get-Content -LiteralPath $MetaPath -Raw | ConvertFrom-Json
    if ($Meta.source_revision -ne $TagCommit -or $Meta.version -ne $Tag -or $Meta.cuda -ne '13.4' -or
        @($Meta.architectures).Count -ne 1 -or $Meta.architectures[0] -ne '89' -or $Meta.modified_sources) {
        throw 'Package revision/version/CUDA/SM89 metadata mismatch'
    }
    $Assets = @(Get-ChildItem -LiteralPath $Dist -File | Where-Object {
        $_.Name -match ('^' + [regex]::Escape($Prefix) + '[.]7z[.][0-9]{3}$')
    } | Sort-Object Name)
    $Checksums = Join-Path $Dist ('SHA256SUMS-' + $Prefix + '.txt')
    if ($Assets.Count -eq 0 -or -not (Test-Path $Checksums)) { throw 'Verified archive volumes or SHA256SUMS manifest missing' }
    $Assets += Get-Item $Checksums
    $AssetNames = @($Assets | ForEach-Object Name)
    $RemoteNames = @(& gh release view $Tag --repo $Repo --json assets --jq '.assets[].name')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read existing GitHub release assets' }
    foreach ($name in $AssetNames) {
        if ($name -in $RemoteNames) { throw "Remote asset already exists, refusing destructive overwrite: $name" }
    }

    $Exe = Join-Path $Product 'ninfer-serve.exe'
    if (-not (Test-Path $Exe)) { throw 'Packaged ninfer-serve.exe not found' }
    $Psi = [Diagnostics.ProcessStartInfo]::new()
    $Psi.FileName = $Exe
    $Psi.WorkingDirectory = $Product
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $SmokeArgs = @($Model,'--model-id','release-smoke','--host','127.0.0.1','--port',[string]$SmokePort,
        '--max-context','4096','--kv-capacity','auto','--kv-dtype','rk4v4','--gdn-state-fp16',
        '--max-concurrency','1','--spec','dflash2','--draft-tokens','5')
    foreach ($arg in $SmokeArgs) { [void]$Psi.ArgumentList.Add($arg) }
    $Server = [Diagnostics.Process]::Start($Psi)
    if (-not $Server) { throw 'Could not start portable inference server' }
    $Ready = $false
    for ($i=0; $i -lt 90; $i++) {
        if ($Server.HasExited) { throw "Portable server exited with code $($Server.ExitCode)" }
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$SmokePort/v1/models" -TimeoutSec 3
            $Ready = $true
            break
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $Ready) { throw 'Portable server not ready within 180 seconds' }
    $Body = @{ model='release-smoke'; messages=@(@{ role='user'; content='Reply with one short sentence.' }); max_tokens=24 } | ConvertTo-Json -Depth 6
    $Answer = Invoke-RestMethod -Uri "http://127.0.0.1:$SmokePort/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $Body -TimeoutSec 120
    if (-not $Answer.choices -or -not $Answer.choices[0].message.content) { throw 'Packaged server produced no text in the real RTX 4090 inference test' }
    Write-Host 'Verified packaged server + model inference on RTX 4090 / CUDA 13.4 / DFlash2.'
    Stop-Process -Id $Server.Id -Force -ErrorAction SilentlyContinue
    $Server.WaitForExit(5000) | Out-Null
    $Server = $null

    $UploadArgs = @('release','upload',$Tag) + @($Assets | ForEach-Object FullName) + @('--repo',$Repo)
    Run 'gh' $UploadArgs
    $Uploaded = @(& gh release view $Tag --repo $Repo --json assets --jq '.assets[].name')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify uploaded GitHub release assets' }
    foreach ($name in $AssetNames) {
        if ($name -notin $Uploaded) { throw "Missing uploaded asset: $name" }
    }
    Run 'gh' @('release','edit',$Tag,'--repo',$Repo,'--prerelease=false','--latest',
        '--title','NInfer-all RTX 4090 v0.1.0 - CUDA 13.4 / SM89 (Windows x64)',
        '--notes-file',$Notes)
    $Published = & gh release view $Tag --repo $Repo --json isPrerelease,assets,url | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $Published.isPrerelease -or $Published.assets.Count -lt $Assets.Count) {
        throw 'Could not verify GitHub marked the release stable with all binary assets'
    }
    Write-Host "STABLE WINDOWS RELEASE PUBLISHED: $($Published.url)"
    $Success = $true
} finally {
    if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id -Force -ErrorAction SilentlyContinue }
    $env:NINFER_VERSION = $PreviousVersion
    if ($WorktreeAdded) {
        if ($Success -and -not $KeepWorktree) {
            & git -C $Root worktree remove --force $Worktree
            if ($LASTEXITCODE -ne 0) { Write-Warning "Worktree cleanup failed: $Worktree" }
        } else { Write-Host "Worktree retained for diagnostics: $Worktree" }
    }
}

<#
Deploys this repo's Claude Code config into the Claude config directory.
  -Dest     Target dir. Default: $env:CLAUDE_CONFIG_DIR, else ~/.claude
  -Source   Repo dir (default: this script's folder)
  -DryRun   Show what would change; write nothing
  -Update   git pull --ff-only in Source first; abort if it fails
  -AdoptExistingClaudeMd  Replace an existing CLAUDE.md that has no managed block (backed up first)
  -Restore  Restore a backup by stamp, or 'latest'
Repo-owned: managed block in CLAUDE.md, listed settings keys, listed agents. Everything else is left alone.
#>
[CmdletBinding()]
param([string]$Dest, [string]$Source = $PSScriptRoot, [switch]$DryRun, [switch]$Update,
      [switch]$AdoptExistingClaudeMd, [string]$Restore)
$ErrorActionPreference = 'Stop'
$Begin = '<!-- claude-config:begin (managed by Claude-Config install.ps1; edit the repo, not this block) -->'
$End = '<!-- claude-config:end -->'
$Forbidden = 'permissions', 'hooks', 'apiKeyHelper', 'awsAuthRefresh', 'awsCredentialExport'
$Enc = New-Object System.Text.UTF8Encoding($false)

function Norm([string]$s) { ($s -replace "`r`n", "`n").TrimEnd() }
function Json($o) { ConvertTo-Json $o -Depth 20 -Compress }
function ConvertTo-Hash($o) {
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
    return $h
  }
  if ($o -is [System.Collections.IList]) { return , @($o | ForEach-Object { ConvertTo-Hash $_ }) }
  return $o
}
function Read-JsonHash([string]$path) {
  $raw = [IO.File]::ReadAllText($path)
  if (-not $raw.Trim()) { return [ordered]@{} }
  try { $o = $raw | ConvertFrom-Json } catch { throw "Invalid JSON in $path : $($_.Exception.Message)" }
  $h = ConvertTo-Hash $o
  if ($h -isnot [System.Collections.IDictionary]) { throw "$path must contain a JSON object" }
  return $h
}
function Write-Text([string]$path, [string]$text) {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [IO.File]::WriteAllText($path, $text, $Enc)
}

try {
  if (-not $Dest) { $Dest = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' } }
  $BackupRoot = Join-Path $Dest 'claude-config-backups'

  if ($Restore) {
    if (-not (Test-Path $BackupRoot)) { throw "No backups found in $BackupRoot" }
    $stamp = $Restore
    if ($Restore -eq 'latest') { $stamp = (Get-ChildItem $BackupRoot -Directory | Sort-Object Name | Select-Object -Last 1).Name }
    $bdir = Join-Path $BackupRoot $stamp
    $mf = Join-Path $bdir 'restore.json'
    if (-not $stamp -or -not (Test-Path $mf)) { throw "Backup '$Restore' not found in $BackupRoot" }
    foreach ($e in (Get-Content $mf -Raw | ConvertFrom-Json)) {
      $t = Join-Path $Dest $e.rel
      if ($e.existed) { New-Item -ItemType Directory -Force (Split-Path $t -Parent) | Out-Null; Copy-Item (Join-Path $bdir $e.rel) $t -Force }
      elseif (Test-Path $t) { Remove-Item $t -Force }
      Write-Host "restored $($e.rel)$(if (-not $e.existed) { ' (removed; did not exist before)' })"
    }
    Write-Host "Restore complete from $stamp. Restart Claude Code."
    exit 0
  }

  if ($Update) {
    git -C $Source pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE); nothing installed" }
  }

  # --- validate sources before touching the destination ---
  $manifestPath = Join-Path $Source 'manifest.json'
  if (-not (Test-Path $manifestPath)) { throw "Missing $manifestPath" }
  $manifest = Read-JsonHash $manifestPath
  foreach ($k in 'claudeMd', 'settings', 'agents') { if (-not $manifest.Contains($k)) { throw "manifest.json missing '$k'" } }
  $files = @($manifest.claudeMd, $manifest.settings) + @($manifest.agents)
  foreach ($f in $files) { if (-not (Test-Path (Join-Path $Source $f))) { throw "Missing source file: $f" } }
  $block = [IO.File]::ReadAllText((Join-Path $Source $manifest.claudeMd)).TrimEnd()
  if (-not $block) { throw "$($manifest.claudeMd) is empty" }
  $owned = Read-JsonHash (Join-Path $Source $manifest.settings)
  foreach ($k in $owned.Keys) { if ($Forbidden -contains $k) { throw "Repo settings may not own '$k'" } }
  foreach ($a in $manifest.agents) {
    $t = [IO.File]::ReadAllText((Join-Path $Source $a))
    if ($t -notmatch '(?s)^---\r?\n.*\bname:\s*\S+.*\r?\n---') { throw "Agent $a lacks valid frontmatter" }
  }
  $destSettingsPath = Join-Path $Dest 'settings.json'
  $cfg = if (Test-Path $destSettingsPath) { Read-JsonHash $destSettingsPath } else { [ordered]@{} }

  # --- compute new content in memory ---
  $notes = @()
  $new = [ordered]@{}   # rel -> text
  $oldSettingsJson = Json $cfg
  foreach ($k in $owned.Keys) {
    $v = $owned[$k]
    if ($v -is [System.Collections.IDictionary]) {
      if (-not ($cfg.Contains($k) -and $cfg[$k] -is [System.Collections.IDictionary])) {
        if ($cfg.Contains($k)) { $notes += "settings: '$k' replaced (existing value was not an object)" }
        $cfg[$k] = [ordered]@{}
      }
      foreach ($sk in $v.Keys) {
        if ($cfg[$k].Contains($sk) -and (Json $cfg[$k][$sk]) -ne (Json $v[$sk])) { $notes += "settings: $k.$sk changed: $(Json $cfg[$k][$sk]) -> $(Json $v[$sk])" }
        $cfg[$k][$sk] = $v[$sk]
      }
    } else {
      if ($cfg.Contains($k) -and (Json $cfg[$k]) -ne (Json $v)) { $notes += "settings: $k changed: $(Json $cfg[$k]) -> $(Json $v)" }
      $cfg[$k] = $v
    }
  }
  if ((Json $cfg) -ne $oldSettingsJson) { $new['settings.json'] = (ConvertTo-Json $cfg -Depth 20) + "`n" }

  $mdPath = Join-Path $Dest 'CLAUDE.md'
  $managed = "$Begin`n$block`n$End"
  $old = if (Test-Path $mdPath) { ([IO.File]::ReadAllText($mdPath)) -replace "`r`n", "`n" } else { $null }
  if ($null -eq $old -or -not $old.Trim()) { $md = "$managed`n" }
  else {
    $b = $old.IndexOf('<!-- claude-config:begin'); $e = $old.IndexOf($End)
    if ($b -ge 0 -and $e -gt $b) { $md = $old.Substring(0, $b) + $managed + $old.Substring($e + $End.Length) }
    elseif ($AdoptExistingClaudeMd) { $md = "$managed`n"; $notes += 'CLAUDE.md: existing unmanaged content replaced (-AdoptExistingClaudeMd); see backup' }
    else { $md = $old.TrimEnd() + "`n`n$managed`n"; $notes += 'CLAUDE.md: existing content kept above the managed block; remove any duplicated rules by hand, or re-run with -AdoptExistingClaudeMd' }
  }
  if ($null -eq $old -or (Norm $md) -ne (Norm $old)) { $new['CLAUDE.md'] = $md }

  foreach ($a in $manifest.agents) {
    $rel = $a -replace '/', '\'
    $text = [IO.File]::ReadAllText((Join-Path $Source $a))
    $cur = Join-Path $Dest $rel
    if (-not (Test-Path $cur) -or (Norm ([IO.File]::ReadAllText($cur))) -ne (Norm $text)) { $new[$rel] = $text }
  }

  foreach ($n in $notes) { Write-Host "note: $n" }
  if ($new.Count -eq 0) { Write-Host "Already up to date ($Dest)."; exit 0 }
  Write-Host ("{0}: {1}" -f $(if ($DryRun) { 'Would change' } else { 'Changing' }), ($new.Keys -join ', '))
  if ($DryRun) { exit 0 }

  # --- unique backup, then write, then verify ---
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $n = 1; $bdir = Join-Path $BackupRoot $stamp
  while (Test-Path $bdir) { $n++; $bdir = Join-Path $BackupRoot "$stamp-$n" }
  $stamp = Split-Path $bdir -Leaf
  $entries = @()
  foreach ($rel in $new.Keys) {
    $cur = Join-Path $Dest $rel; $existed = Test-Path $cur
    if ($existed) { $bt = Join-Path $bdir $rel; New-Item -ItemType Directory -Force (Split-Path $bt -Parent) | Out-Null; Copy-Item $cur $bt }
    $entries += [pscustomobject]@{ rel = $rel; existed = $existed }
  }
  New-Item -ItemType Directory -Force $bdir | Out-Null
  Write-Text (Join-Path $bdir 'restore.json') (ConvertTo-Json @($entries) -Depth 5)
  foreach ($rel in $new.Keys) { Write-Text (Join-Path $Dest $rel) $new[$rel] }
  foreach ($rel in $new.Keys) {
    $got = [IO.File]::ReadAllText((Join-Path $Dest $rel))
    if ((Norm $got) -ne (Norm $new[$rel])) { throw "Verification failed for $rel (backup: $bdir)" }
  }
  $chk = Read-JsonHash $destSettingsPath
  foreach ($k in $owned.Keys) { if (-not $chk.Contains($k)) { throw "Verification failed: settings key '$k' missing (backup: $bdir)" } }
  Write-Host "Installed to $Dest. Restart Claude Code. Undo with: .\install.ps1 -Restore $stamp"
}
catch {
  [Console]::Error.WriteLine("install failed: $($_.Exception.Message)")
  exit 1
}

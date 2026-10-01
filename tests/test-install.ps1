# Tests install.ps1 against temporary destinations only (never touches ~/.claude).
# Run: pwsh -NoProfile -File tests\test-install.ps1   (or powershell.exe -NoProfile -File ...)
param([string]$ShellExe = (Get-Process -Id $PID).Path)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ("cc-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null
$script:fail = 0; $script:pass = 0
$enc = New-Object System.Text.UTF8Encoding($false)

function Check($name, $cond) { if ($cond) { $script:pass++; Write-Host "  ok   $name" } else { $script:fail++; Write-Host "  FAIL $name" -ForegroundColor Red } }
function New-Src {
  $s = Join-Path $root ("src" + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory "$s\agents" | Out-Null
  foreach ($f in 'CLAUDE.md', 'settings.json', 'manifest.json', 'install.ps1', 'agents\grunt.md') { Copy-Item "$repo\$f" "$s\$f" }
  $s
}
function New-Dst { Join-Path $root ("dst" + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
function Run($src, $dst, [string[]]$more = @()) {
  $ErrorActionPreference = 'Continue'   # 5.1 turns native stderr into a terminating error otherwise
  $out = & $ShellExe -NoProfile -File "$src\install.ps1" -Source $src -Dest $dst @more 2>&1 | Out-String
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  [pscustomobject]@{ Code = $code; Out = $out }
}
function Hash($p) { if (Test-Path $p) { (Get-FileHash $p).Hash } else { 'absent' } }
function Backups($d) { if (Test-Path "$d\claude-config-backups") { @(Get-ChildItem "$d\claude-config-backups" -Directory) } else { @() } }

Write-Host "Shell under test: $ShellExe"

Write-Host "missing source file"
$s = New-Src; $d = New-Dst; Remove-Item "$s\agents\grunt.md"
$r = Run $s $d
Check 'exit 1' ($r.Code -eq 1); Check 'names the file' ($r.Out -match 'grunt'); Check 'no success message' ($r.Out -notmatch 'Installed to'); Check 'dest not created' (-not (Test-Path $d))

Write-Host "malformed repo settings.json"
$s = New-Src; $d = New-Dst; [IO.File]::WriteAllText("$s\settings.json", '{ bad json', $enc)
$r = Run $s $d
Check 'exit 1' ($r.Code -eq 1); Check 'dest not created' (-not (Test-Path $d))

Write-Host "repo may not own permissions/hooks"
$s = New-Src; $d = New-Dst; [IO.File]::WriteAllText("$s\settings.json", '{"permissions":{"allow":["*"]}}', $enc)
$r = Run $s $d
Check 'exit 1' ($r.Code -eq 1); Check 'dest not created' (-not (Test-Path $d))

Write-Host "malformed destination settings.json"
$s = New-Src; $d = New-Dst; New-Item -ItemType Directory $d | Out-Null; [IO.File]::WriteAllText("$d\settings.json", '{ nope', $enc)
$h = Hash "$d\settings.json"; $r = Run $s $d
Check 'exit 1' ($r.Code -eq 1); Check 'settings unchanged' ((Hash "$d\settings.json") -eq $h); Check 'no CLAUDE.md written' (-not (Test-Path "$d\CLAUDE.md"))

Write-Host "fresh install"
$s = New-Src; $d = New-Dst; $r = Run $s $d
$cfg = Get-Content "$d\settings.json" -Raw | ConvertFrom-Json
Check 'exit 0' ($r.Code -eq 0)
Check 'CLAUDE.md has markers' ((Get-Content "$d\CLAUDE.md" -Raw) -match 'claude-config:begin' -and (Get-Content "$d\CLAUDE.md" -Raw) -match 'claude-config:end')
Check 'model opusplan' ($cfg.model -eq 'opusplan')
Check 'superpowers disabled' ($cfg.enabledPlugins.'superpowers@superpowers-dev' -eq $false)
Check 'grunt installed' (Test-Path "$d\agents\grunt.md")
Check 'one backup dir' ((Backups $d).Count -eq 1)

Write-Host "repeat install is a no-op"
$r = Run $s $d
Check 'exit 0' ($r.Code -eq 0); Check 'up to date' ($r.Out -match 'up to date'); Check 'no new backup' ((Backups $d).Count -eq 1)

Write-Host "existing nested settings and unrelated CLAUDE.md preserved"
$s = New-Src; $d = New-Dst; New-Item -ItemType Directory $d | Out-Null
$orig = '{"theme":"dark","model":"sonnet","permissions":{"allow":["Bash(git status)"],"deny":["Read(.env)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]},"env":{"FOO":"bar","ANTHROPIC_DEFAULT_OPUS_MODEL":"old"},"enabledPlugins":{"other@x":true}}'
[IO.File]::WriteAllText("$d\settings.json", $orig, $enc); [IO.File]::WriteAllText("$d\CLAUDE.md", "# My own rules`nAlways say hi.`n", $enc)
$r = Run $s $d; $cfg = Get-Content "$d\settings.json" -Raw | ConvertFrom-Json; $o = $orig | ConvertFrom-Json
Check 'exit 0' ($r.Code -eq 0)
Check 'theme kept' ($cfg.theme -eq 'dark')
Check 'permissions identical' ((ConvertTo-Json $cfg.permissions -Depth 9 -Compress) -eq (ConvertTo-Json $o.permissions -Depth 9 -Compress))
Check 'hooks identical' ((ConvertTo-Json $cfg.hooks -Depth 9 -Compress) -eq (ConvertTo-Json $o.hooks -Depth 9 -Compress))
Check 'env.FOO kept' ($cfg.env.FOO -eq 'bar'); Check 'env pin set' ($cfg.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'claude-opus-5-5')
Check 'other plugin kept' ($cfg.enabledPlugins.'other@x' -eq $true)
Check 'conflict reported (model)' ($r.Out -match 'model changed')
Check 'conflict reported (env pin)' ($r.Out -match 'ANTHROPIC_DEFAULT_OPUS_MODEL changed')
$md = Get-Content "$d\CLAUDE.md" -Raw
Check 'user CLAUDE.md content kept' ($md -match 'Always say hi'); Check 'block appended' ($md -match 'claude-config:begin'); Check 'duplication warning' ($r.Out -match 'existing content kept')

Write-Host "managed block updates in place, user text kept"
Add-Content "$s\CLAUDE.md" "- New rule from repo."
$r = Run $s $d; $md = Get-Content "$d\CLAUDE.md" -Raw
Check 'exit 0' ($r.Code -eq 0); Check 'new rule present' ($md -match 'New rule from repo'); Check 'user text kept' ($md -match 'Always say hi')
Check 'single block' (([regex]::Matches($md, 'claude-config:begin')).Count -eq 1)

Write-Host "dry run writes nothing"
$s = New-Src; $d = New-Dst; $r = Run $s $d @('-DryRun')
Check 'exit 0' ($r.Code -eq 0); Check 'says would change' ($r.Out -match 'Would change'); Check 'dest not created' (-not (Test-Path $d))

Write-Host "restore"
$s = New-Src; $d = New-Dst; New-Item -ItemType Directory $d | Out-Null
[IO.File]::WriteAllText("$d\settings.json", $orig, $enc); [IO.File]::WriteAllText("$d\CLAUDE.md", "# Mine`n", $enc)
$hs = Hash "$d\settings.json"; $hm = Hash "$d\CLAUDE.md"
$null = Run $s $d
Check 'install changed settings' ((Hash "$d\settings.json") -ne $hs)
$r = Run $s $d @('-Restore', 'latest')
Check 'restore exit 0' ($r.Code -eq 0); Check 'settings restored' ((Hash "$d\settings.json") -eq $hs); Check 'CLAUDE.md restored' ((Hash "$d\CLAUDE.md") -eq $hm)
Check 'agent removed (did not exist before)' (-not (Test-Path "$d\agents\grunt.md"))
$r = Run $s $d @('-Restore', 'nonexistent'); Check 'unknown backup fails' ($r.Code -eq 1)

Write-Host "-Update aborts when git fails"
$s = New-Src; $d = New-Dst; $r = Run $s $d @('-Update')
Check 'exit 1' ($r.Code -eq 1); Check 'nothing installed' (-not (Test-Path $d))

Remove-Item $root -Recurse -Force
Write-Host "`n$script:pass passed, $script:fail failed"
exit $(if ($script:fail) { 1 } else { 0 })

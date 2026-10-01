# Copies this repo's Claude Code config into ~/.claude (existing files are backed up as *.bak).
$src = $PSScriptRoot; $dst = Join-Path $HOME ".claude"
New-Item -ItemType Directory -Force "$dst\agents" | Out-Null
foreach ($f in "CLAUDE.md","settings.json","agents\grunt.md") {
  $t = Join-Path $dst $f
  if (Test-Path $t) { Copy-Item $t "$t.bak" -Force }
  Copy-Item (Join-Path $src $f) $t -Force
}
Write-Host "Installed to $dst. Restart Claude Code."

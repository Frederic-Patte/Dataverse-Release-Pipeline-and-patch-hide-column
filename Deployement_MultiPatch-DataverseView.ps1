param(
  [Parameter(Mandatory=$true)]
  [string]$ConfigPath  # e.g.: .\config.release.json
)

# -------------------- UI Helpers --------------------
function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host $m -ForegroundColor Green }
function Warn2($m){ Write-Warning $m }
function Die($m){ throw $m }

# -------------------- Load Config --------------------
if (-not (Test-Path $ConfigPath)) { Die "❌ Config file not found: $ConfigPath" }
$cfgRaw = Get-Content -LiteralPath $ConfigPath -Raw
$cfg = $cfgRaw | ConvertFrom-Json

# Minimal validation
if (-not $cfg.solution.solutionName) { Die "❌ Missing 'solution.solutionName'." }
if (-not $cfg.urls.dev -or -not $cfg.urls.uat) { Die "❌ 'urls.dev' and 'urls.uat' are required." }
if (-not $cfg.release.major -or -not $cfg.release.minor) { Die "❌ 'release.major' and 'release.minor' are required." }

# Aliases
$SolutionName = $cfg.solution.solutionName
$DevUrl = $cfg.urls.dev
$UatUrl = $cfg.urls.uat
$PrdUrl = $cfg.urls.prd
$DeployToProd = [bool]$cfg.release.deployToProd

$UseExistingAuth = $true
if ($cfg.auth.useExistingAuth -ne $null) { $UseExistingAuth = [bool]$cfg.auth.useExistingAuth }

# -------------------- File & JSON Helpers --------------------
function Ensure-Folders {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$Names
  )
  $map = @{}
  foreach($n in $Names){
    $full = Join-Path $Root $n
    if (-not (Test-Path $full)) {
      New-Item -ItemType Directory -Force -Path $full | Out-Null
      Info "📁 Created: $full"
    } else {
      Info "📁 Exists: $full"
    }
    $map[$n] = $full
  }
  return $map
}

function Get-JsonDepth {
  param([Parameter(Mandatory=$true)][object]$JsonObject)
  function Get-Depth {
    param([object]$Object,[int]$CurrentDepth=1)
    $max=$CurrentDepth
    if ($Object -is [pscustomobject] -or $Object -is [hashtable]) {
      foreach ($p in $Object.PSObject.Properties){
        $d=Get-Depth -Object $p.Value -CurrentDepth ($CurrentDepth+1)
        if ($d -gt $max){$max=$d}
      }
    } elseif ($Object -is [array]) {
      foreach ($i in $Object){
        $d=Get-Depth -Object $i -CurrentDepth ($CurrentDepth+1)
        if ($d -gt $max){$max=$d}
      }
    }
    return $max
  }
  Get-Depth -Object $JsonObject
}

function Reuse-DeploymentSettingsValues {
  param(
    [Parameter(Mandatory)][string]$TemplatePath,
    [Parameter(Mandatory)][string]$ExistingPath
  )
  $tpl = Get-Content -Raw $TemplatePath | ConvertFrom-Json
  $old = Get-Content -Raw $ExistingPath | ConvertFrom-Json

  # EnvironmentVariables
  for ($i=0; $i -lt $tpl.EnvironmentVariables.Count; $i++){
    $sn = $tpl.EnvironmentVariables[$i].SchemaName
    $val = ($old.EnvironmentVariables | Where-Object { $_.SchemaName -eq $sn }).Value
    if ($null -eq $val){ $val = "" }
    $tpl.EnvironmentVariables[$i].Value = $val
  }
  # ConnectionReferences
  for ($j=0; $j -lt $tpl.ConnectionReferences.Count; $j++){
    $ln = $tpl.ConnectionReferences[$j].LogicalName
    $id = ($old.ConnectionReferences | Where-Object { $_.LogicalName -eq $ln }).ConnectionId
    if ($null -eq $id){ $id = "" }
    $tpl.ConnectionReferences[$j].ConnectionId = $id
  }
  return $tpl
}

# -------------------- View Patch Helpers --------------------
function Resolve-ViewFiles {
  param(
    [string]$BaseFolder,  # e.g., .\solution_unpacked
    [string]$TableName,
    [string]$ViewId
  )
  $entitiesRoot = Join-Path $BaseFolder "Entities"
  if (-not (Test-Path $entitiesRoot)) { Die "❌ 'Entities' folder not found under '$BaseFolder'." }

  $targets = @()

  # Target tables
  if ([string]::IsNullOrWhiteSpace($TableName) -or $TableName -eq "*") {
    $tableDirs = Get-ChildItem -Path $entitiesRoot -Directory -ErrorAction SilentlyContinue
  } else {
    $specific = Join-Path $entitiesRoot $TableName
    if (-not (Test-Path $specific)) { Die "❌ Table '$TableName' not found in the unpacked solution." }
    $tableDirs = ,(Get-Item $specific)
  }

  foreach ($td in $tableDirs) {
    $savedQ = Join-Path $td.FullName "SavedQueries"
    if (-not (Test-Path $savedQ)) { continue }

    if (-not [string]::IsNullOrWhiteSpace($ViewId)) {
      $hit = Select-String -Path (Join-Path $savedQ "*.xml") -Pattern $ViewId -List -ErrorAction SilentlyContinue
      if ($hit) { $targets += $hit.Path; continue }
    }
  }

  # Fallback: global search if no specific table provided
  if ($targets.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ViewId) -and ([string]::IsNullOrWhiteSpace($TableName) -or $TableName -eq "*")) {
    $hitAll = Select-String -Path (Join-Path $entitiesRoot "*/SavedQueries/*.xml") -Pattern $ViewId -List -ErrorAction SilentlyContinue
    if ($hitAll) { $targets += $hitAll.Path }
  }

  $targets | Select-Object -Unique
}

function Patch-ViewFile {
  param(
    [string]$ViewFile,
    [string[]]$Columns,
    [switch]$DryRun
  )
  [xml]$xml = Get-Content -LiteralPath $ViewFile
  $nodes = $xml.SelectNodes("//layoutxml//grid//row//cell")
  if (-not $nodes) { return 0 }

  $patchedThis = 0
  foreach ($col in $Columns) {
    $cell = $xml.SelectSingleNode("//layoutxml//grid//row//cell[@name='$col']")
    if ($cell) {
      if (-not $DryRun) { $cell.SetAttribute("ishidden","1") }
      $patchedThis++
    }
  }
  if ($patchedThis -gt 0 -and -not $DryRun) { $xml.Save($ViewFile) }
  return $patchedThis
}

# -------------------- Auth Management --------------------
function Select-Or-CreateAuth {
  param(
    [Parameter(Mandatory)][string]$Url,
    [string]$Name,
    [bool]$UseExisting = $true
  )
  if ($UseExisting -and $Name){
    Info "🔐 Selecting existing auth: $Name"
    pac auth select -n $Name | Out-Null
  } else {
    $nm = $Name; if (-not $nm) { $nm = "Auth_" + ($Url -replace 'https?://','').Split('.')[0] }
    Info "🔐 Creating auth: $nm ($Url)"
    pac auth create --url $Url --name $nm | Out-Null
    pac auth select --name $nm | Out-Null
  }
}

# -------------------- Folders --------------------
$root = $cfg.paths.root
if (-not $root) { Die "❌ Missing 'paths.root' in config." }

$folders = @(
  $cfg.paths.unmanaged,
  $cfg.paths.managed,
  $cfg.paths.uatSettings,
  $cfg.paths.prdSettings,
  $cfg.paths.tempUnpack
) | Where-Object { $_ -ne $null -and $_ -ne "" }

$folderMap = Ensure-Folders -Root $root -Names $folders
$unmanagedDir = $folderMap[$cfg.paths.unmanaged]
$managedDir   = $folderMap[$cfg.paths.managed]
$uatSetDir    = $folderMap[$cfg.paths.uatSettings]
$prdSetDir    = $folderMap[$cfg.paths.prdSettings]
$tempUnpack   = $folderMap[$cfg.paths.tempUnpack]

# -------------------- DEV Versioning --------------------
Select-Or-CreateAuth -Url $DevUrl -Name $cfg.auth.devName -UseExisting:$UseExistingAuth

$dateStamp = Get-Date -Format "yyMMdd"
$major = $cfg.release.major
$minor = $cfg.release.minor

Info "🔎 Reading current DEV version for '$SolutionName'…"
$line = (pac solution list --environment $DevUrl | findstr $SolutionName)
if (-not $line) { Die "❌ Solution not found in DEV: $SolutionName" }

$regex = '\b(\d+\.\d+\.\d+\.\d+)\b'
if ($line -match $regex) { $current = $matches[1] } else { Die "❌ DEV version not detected." }

$currentNoRev = ($current.Split('.'))[0..2] -join '.'
$targetNoRev  = "$major.$minor.$dateStamp"

if ([version]$currentNoRev -gt [version]$targetNoRev) {
  Die "❌ DEV version ($currentNoRev) > target ($targetNoRev). Adjust 'major/minor' in config."
}
elseif ($currentNoRev -eq $targetNoRev) {
  $rev = [int]$current.Split('.')[3]; $newVersion = "$targetNoRev." + ($rev+1)
} else {
  $newVersion = "$targetNoRev.0"
}
Ok "🆕 New version to apply: $newVersion"
pac solution online-version -env $DevUrl -sn $SolutionName -sv $newVersion

# -------------------- Exports --------------------
$zipBaseName = ($SolutionName + "_" + $newVersion.Replace('.', '_'))

$unmanagedZip = Join-Path $unmanagedDir "$zipBaseName.zip"
$managedZip   = Join-Path $managedDir   "${zipBaseName}_Managed.zip"

Info "📦 Export Unmanaged → $unmanagedZip"
pac solution export -env $DevUrl -p $unmanagedZip -n $SolutionName
if (-not (Test-Path $unmanagedZip)) { Die "❌ Missing unmanaged export: $unmanagedZip" }
Ok "Unmanaged OK"

Info "📦 Export Managed → $managedZip"
pac solution export -env $DevUrl -p $managedZip -n $SolutionName -m
if (-not (Test-Path $managedZip)) { Die "❌ Missing managed export: $managedZip" }
Ok "Managed OK"

# -------------------- Optional Patch (applied on Managed) --------------------
$deployManagedZip = $managedZip
$applyPatch = $false
if ($cfg.patch -and $cfg.patch.enabled -and $cfg.patches -and $cfg.patches.Count -gt 0) { $applyPatch = $true }

if ($applyPatch) {
  $dryRun = [bool]$cfg.options.dryRun
  if (-not $tempUnpack) { Die "❌ 'paths.tempUnpack' required for patching." }

  # Clean up if exists
  if (Test-Path $tempUnpack) { Remove-Item $tempUnpack -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $tempUnpack | Out-Null

  Info "📂 Unpack (Managed) → $tempUnpack"
  pac solution unpack --zipFile $managedZip --folder $tempUnpack --packagetype Managed
  if (-not (Test-Path $tempUnpack)) { Die "❌ Missing unpack folder: $tempUnpack" }

  $totalPatched = 0
  foreach ($job in $cfg.patches) {
    $t   = $job.tableName
    $vid = $job.viewId
    $cols = @($job.columns)

    if ($cols.Count -eq 0) { Warn2 "Warning: no columns for table='$t' viewId='$vid'"; continue }
    if ([string]::IsNullOrWhiteSpace($vid)) { Die "❌ Provide 'viewId' for table '$t'." }

    Info "🔎 Resolving views | Table='$t' | ViewId='$vid'"
    $viewFiles = Resolve-ViewFiles -BaseFolder $tempUnpack -TableName $t -ViewId $vid
    if ($viewFiles.Count -eq 0) { Die "❌ No view found (table='$t' / id='$vid')." }

    foreach ($vf in $viewFiles) {
      $patched = Patch-ViewFile -ViewFile $vf -Columns $cols -DryRun:$dryRun
      try {
        [xml]$xx = Get-Content -LiteralPath $vf
        $n = ($xx.SelectSingleNode("/*[local-name()='savedquery']/*[local-name()='name']")).InnerText
        $i = ($xx.SelectSingleNode("/*[local-name()='savedquery']/*[local-name()='savedqueryid']")).InnerText
        if ($dryRun) { Write-Host ("🔎 DryRun → {0} (Name={1} | Id={2}) : {3} col(s)" -f (Split-Path $vf -Leaf), $n, $i, $patched) -ForegroundColor Yellow }
        else { Ok ("✅ Patched: {0} (Name={1} | Id={2}) : {3} col(s)" -f (Split-Path $vf -Leaf), $n, $i, $patched) }
      } catch {
        if ($dryRun) { Write-Host ("🔎 DryRun → {0} : {1} col(s)" -f (Split-Path $vf -Leaf), $patched) -ForegroundColor Yellow }
        else { Ok ("✅ Patched: {0} : {1} col(s)" -f (Split-Path $vf -Leaf), $patched) }
      }
      $totalPatched += $patched
    }
  }

  if ($dryRun) {
    Warn2 "🔎 DryRun — no files modified, no pack, no import."
  } else {
    $patchedManagedZip = Join-Path $managedDir "${zipBaseName}_Managed_Patched.zip"
    Info "📦 Pack (Managed patched) → $patchedManagedZip"
    pac solution pack --folder $tempUnpack --zipFile $patchedManagedZip --packagetype Managed
    if (-not (Test-Path $patchedManagedZip)) { Die "❌ Missing packed file: $patchedManagedZip" }
    Ok "Pack patched OK"
    $deployManagedZip = $patchedManagedZip
  }

  if (-not $cfg.options.keepUnpacked -and (Test-Path $tempUnpack)) {
    Remove-Item $tempUnpack -Recurse -Force
    Write-Host "🧹 Unpacked folder deleted" -ForegroundColor DarkGray
  }
}

# -------------------- Deployment Settings (UAT / PRD) --------------------
Start-Sleep -Seconds 5  # small delay to avoid transient issues

# UAT
$uatSettingsFile = Join-Path $uatSetDir ("deploymentsettings_UAT_{0}.json" -f $newVersion)
$tries=0; $ok=$false
do {
  try {
    Info "📝 Creating UAT settings → $uatSettingsFile"
    pac solution create-settings -z $deployManagedZip -s $uatSettingsFile
    $ok=$true
  } catch {
    Warn2 "-- create-settings error (attempt $tries)"; Start-Sleep -Seconds 3; $tries++
  }
} until ($ok -or $tries -ge 5)
if (-not $ok){ Die "❌ create-settings UAT failed" }

$prevUAT = Get-ChildItem $uatSetDir -Filter "deploymentsettings_UAT_*.json" -ErrorAction SilentlyContinue | Sort-Object {
  $_.Name -match "deploymentsettings_UAT_(\d+\.\d+\.\d+\.\d+)\.json" | Out-Null
  try { [version]$matches[1] } catch { [version]"0.0.0.0" }
} | Select-Object -Last 1

if ($prevUAT -and ($prevUAT.FullName -ne $uatSettingsFile)) {
  Info "♻️ Reusing UAT values from: $($prevUAT.Name)"
  $merged = Reuse-DeploymentSettingsValues -TemplatePath $uatSettingsFile -ExistingPath $prevUAT.FullName
  $merged | ConvertTo-Json -Depth (Get-JsonDepth -JsonObject $merged) | Set-Content $uatSettingsFile
}

# PRD (optional)
if ($DeployToProd -and $PrdUrl) {
  $prdSettingsFile = Join-Path $prdSetDir ("deploymentsettings_PRD_{0}.json" -f $newVersion)
  $tries=0; $ok=$false
  do {
    try {
      Info "📝 Creating PRD settings → $prdSettingsFile"
      pac solution create-settings -z $deployManagedZip -s $prdSettingsFile
      $ok=$true
    } catch {
      Warn2 "-- create-settings PRD error (attempt $tries)"; Start-Sleep -Seconds 3; $tries++
    }
  } until ($ok -or $tries -ge 5)
  if (-not $ok){ Die "❌ create-settings PRD failed" }

  $prevPRD = Get-ChildItem $prdSetDir -Filter "deploymentsettings_PRD_*.json" -ErrorAction SilentlyContinue | Sort-Object {
    $_.Name -match "deploymentsettings_PRD_(\d+\.\d+\.\d+\.\d+)\.json" | Out-Null
    try { [version]$matches[1] } catch { [version]"0.0.0.0" }
  } | Select-Object -Last 1

  if ($prevPRD -and ($prevPRD.FullName -ne $prdSettingsFile)) {
    Info "♻️ Reusing PRD values from: $($prevPRD.Name)"
    $merged = Reuse-DeploymentSettingsValues -TemplatePath $prdSettingsFile -ExistingPath $prevPRD.FullName
    $merged | ConvertTo-Json -Depth (Get-JsonDepth -JsonObject $merged) | Set-Content $prdSettingsFile
  }
}

# -------------------- UAT Import (with confirmation) --------------------
$proceedUAT = $true
if ($cfg.options.confirmPrompts -ne $false) {
  $ans = Read-Host "Confirm UAT import? Ensure the UAT settings file is up to date. (y/n)"
  $proceedUAT = ($ans -eq "y")
}
if ($proceedUAT) {
  Select-Or-CreateAuth -Url $UatUrl -Name $cfg.auth.uatName -UseExisting:$UseExistingAuth
  Info "⬆️ Import UAT → $UatUrl"
  pac solution import -env $UatUrl -p $deployManagedZip --settings-file $uatSettingsFile -f -up -slv -a -ap
  Ok "🎉 UAT import completed"
} else {
  Warn2 "⏭️ UAT import canceled by user."
}

# -------------------- PRD Import (optional + confirmation) --------------------
if ($DeployToProd -and $PrdUrl -and $proceedUAT) {
  $proceedPRD = $true
  if ($cfg.options.confirmPrompts -ne $false) {
    $ans2 = Read-Host "Confirm PRD import? Ensure the PRD settings file is up to date. (y/n)"
    $proceedPRD = ($ans2 -eq "y")
  }
  if ($proceedPRD) {
    Select-Or-CreateAuth -Url $PrdUrl -Name $cfg.auth.prdName -UseExisting:$UseExistingAuth
    Info "⬆️ Import PRD → $PrdUrl"
    $prdSettingsFile = Join-Path $prdSetDir ("deploymentsettings_PRD_{0}.json" -f $newVersion)
    pac solution import -env $PrdUrl -p $deployManagedZip --settings-file $prdSettingsFile -f -up -slv -a -ap
    Ok "🎉 PRD import completed"
  } else {
    Warn2 "⏭️ PRD import canceled by user."
  }
} else {
  Info "## Skip PRD Deployment ##"
}

Ok "✅ DONE — Release $SolutionName version $newVersion"
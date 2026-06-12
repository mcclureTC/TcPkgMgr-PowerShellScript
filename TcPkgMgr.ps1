<#
.SYNOPSIS
    Interactive numbered-menu console and task runner for the TwinCAT
    Package Manager (tcpkg).

.DESCRIPTION
    Part 1 - a menu front end over the most common tcpkg operations
             (packages/workloads, sources/feeds, configuration).
    Part 2 - a lightweight task runner that lets you save and replay a
             named *sequence* of tcpkg commands as a "task", with optional
             {{token}} prompts and a global dry-run mode.

    Tasks are stored as JSON next to this script (tcpkg-tasks.json), so you
    can hand-edit, version-control, or share them.

.NOTES
    - Most tcpkg actions require administrator rights.
    - Runs in Windows PowerShell, PowerShell ISE, and PowerShell 7+.
    - Commands verified against Beckhoff infosys + the community
      tcpkg cheatsheet. Verify destructive tasks before running them.
#>

# ============================================================================
#  Configuration
# ============================================================================

$Script:TcpkgExe = 'tcpkg'

# Where to persist tasks. $PSScriptRoot is empty when code is pasted into a
# console, so fall back to the current directory.
$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:TasksFile = Join-Path $baseDir 'tcpkg-tasks.json'

# When $true, commands are printed but never executed.
$Script:DryRun = $false

# Exit code of the most recent tcpkg invocation (set by Invoke-Tcpkg).
$Script:LastExit = 0

# Beckhoff feed presets: name -> @{ Url; Priority }
$Script:BeckhoffFeeds = [ordered]@{
    'Stable'   = @{ Url = 'https://public.tcpkg.beckhoff-cloud.com/api/v1/feeds/stable/';   Priority = 1 }
    'Outdated' = @{ Url = 'https://public.tcpkg.beckhoff-cloud.com/api/v1/feeds/outdated/'; Priority = 2 }
    'Testing'  = @{ Url = 'https://public.tcpkg.beckhoff-cloud.com/api/v1/feeds/testing/';  Priority = 3 }
    'Preview'  = @{ Url = 'https://public.tcpkg.beckhoff-cloud.com/api/v1/feeds/preview/';  Priority = 4 }
}

# ============================================================================
#  Low-level helpers
# ============================================================================

function Test-TcpkgAvailable {
    [bool](Get-Command $Script:TcpkgExe -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Split a command-line string into arguments, keeping "quoted segments" whole.
function Split-CommandLine {
    param([string]$Line)
    [regex]::Matches($Line, '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    }
}

# Run tcpkg with an argument array. Honours dry-run. Returns the exit code.
function Invoke-Tcpkg {
    param(
        [Parameter(Mandatory)] [string[]] $ArgList,
        [switch] $Quiet
    )
    $display = "$Script:TcpkgExe $($ArgList -join ' ')"

    if ($Script:DryRun) {
        Write-Host "  [dry-run] $display" -ForegroundColor DarkYellow
        $Script:LastExit = 0
        return
    }

    if (-not (Test-TcpkgAvailable)) {
        Write-Host "  tcpkg was not found on PATH. Install the TwinCAT Package Manager," -ForegroundColor Red
        Write-Host "  or enable dry-run mode from the main menu to preview commands." -ForegroundColor Red
        $Script:LastExit = 1
        return
    }

    if (-not $Quiet) { Write-Host "  > $display" -ForegroundColor DarkGray }

    # tcpkg writes its version banner to stderr on every invocation. PowerShell
    # wraps any stderr output as an ErrorRecord and raises NativeCommandError
    # even when the command succeeds. Suppress that for this call only, then
    # restore the previous preference so real errors elsewhere still surface.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & $Script:TcpkgExe @ArgList
    $Script:LastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
}

function Wait-Continue {
    [void](Read-Host "`n  Press Enter to continue")
}

function Read-Value {
    param([string]$Prompt, [switch]$AllowEmpty, [switch]$CancelOnBlank)
    while ($true) {
        $v = Read-Host "  $Prompt"
        if ([string]::IsNullOrWhiteSpace($v)) {
            if ($AllowEmpty)    { return $v }
            if ($CancelOnBlank) { return $null }
            Write-Host '  A value is required (or leave blank to cancel).' -ForegroundColor Yellow
        } else {
            return $v
        }
    }
}

function Confirm-YesNo {
    param([string]$Prompt, [switch]$DefaultYes)
    Write-Host "  $Prompt"
    Write-Host '    1. Yes'
    Write-Host '    0. No'
    while ($true) {
        $a = (Read-Host '  Choice').Trim()
        if ($a -eq '1') { return $true }
        if ($a -eq '0') { return $false }
        if ($a -eq '' -and $PSBoundParameters.ContainsKey('DefaultYes')) { return [bool]$DefaultYes }
        Write-Host '  Please enter 1 (Yes) or 0 (No).' -ForegroundColor Yellow
    }
}

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host "  TwinCAT Package Manager Console   |   $Title" -ForegroundColor Cyan
    $mode      = if ($Script:DryRun) { 'DRY-RUN (no changes made)' } else { 'LIVE' }
    $modeColor = if ($Script:DryRun) { 'Yellow' } else { 'Green' }
    Write-Host -NoNewline '  Mode: '
    Write-Host $mode -ForegroundColor $modeColor
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host ''
}

# Print a numbered, column-aligned list. Each column is described by a hashtable
# @{ Header = '...'; Expr = { $_.Property }; Align = 'Left'|'Right' }. A leading
# right-aligned '#' column is added automatically; its numbers match the order
# of $Items, so callers can index back into $Items with (choice - 1).
function Show-SelectableList {
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [hashtable[]] $Columns,
        [string] $Indent = '   ',
        [switch] $NoNumber
    )
    $items = @($Items)
    if ($NoNumber) {
        $headers = @($Columns | ForEach-Object { [string]$_.Header })
        $aligns  = @($Columns | ForEach-Object { if ($_.Align) { $_.Align } else { 'Left' } })
    } else {
        $headers = @('#') + ($Columns | ForEach-Object { [string]$_.Header })
        $aligns  = @('Right') + ($Columns | ForEach-Object { if ($_.Align) { $_.Align } else { 'Left' } })
    }
    $colCount = $headers.Count

    # Build each data row as an array of string cells (leading number first).
    $dataRows = @()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $cells = [System.Collections.Generic.List[string]]::new()
        if (-not $NoNumber) { $cells.Add(('{0}.' -f ($i + 1))) }
        foreach ($c in $Columns) {
            $cells.Add([string]($items[$i] | ForEach-Object $c.Expr))
        }
        $dataRows += , $cells.ToArray()
    }

    # Column widths = widest cell (including the header) in each column.
    $widths = @(0) * $colCount
    foreach ($row in (@(, $headers) + $dataRows)) {
        for ($i = 0; $i -lt $colCount; $i++) {
            $len = ([string]$row[$i]).Length
            if ($len -gt $widths[$i]) { $widths[$i] = $len }
        }
    }

    $pad = {
        param([string]$Text, [int]$Width, [string]$Align)
        if ($Align -eq 'Right') { $Text.PadLeft($Width) } else { $Text.PadRight($Width) }
    }

    $hdr = for ($i = 0; $i -lt $colCount; $i++) { & $pad $headers[$i] $widths[$i] $aligns[$i] }
    Write-Host ($Indent + ($hdr -join '  ')) -ForegroundColor DarkCyan
    Write-Host ($Indent + ((($widths | ForEach-Object { '-' * $_ }) -join '  '))) -ForegroundColor DarkGray
    foreach ($row in $dataRows) {
        $line = for ($i = 0; $i -lt $colCount; $i++) {
            $cell = if ($i -lt $row.Count) { [string]$row[$i] } else { '' }
            & $pad $cell $widths[$i] $aligns[$i]
        }
        Write-Host ($Indent + ($line -join '  '))
    }
}

function Get-DefaultTasks {
    @(
        [pscustomobject]@{
            Name            = 'System inventory (read-only)'
            Description     = 'Dump installed packages, upgradable packages, sources and config.'
            ContinueOnError = $true
            Steps           = @('list -i', 'list -o', 'source list', 'config list')
        }
        [pscustomobject]@{
            Name            = 'Install a package'
            Description     = 'Prompts for a package name and installs it unattended. Demonstrates {{tokens}}.'
            ContinueOnError = $false
            Steps           = @('install {{PackageName}} -y')
        }
        [pscustomobject]@{
            Name            = 'Upgrade everything (DESTRUCTIVE)'
            Description     = 'Upgrades all installed packages without prompting. Review before running.'
            ContinueOnError = $false
            Steps           = @('upgrade all -y')
        }
    )
}

function Get-Tasks {
    if (Test-Path $Script:TasksFile) {
        try {
            return @(Get-Content $Script:TasksFile -Raw -ErrorAction Stop | ConvertFrom-Json)
        } catch {
            Write-Host "  Could not read $Script:TasksFile : $_" -ForegroundColor Red
            Write-Host '  Falling back to built-in default tasks.' -ForegroundColor Yellow
            return Get-DefaultTasks
        }
    }
    # First run: seed the file with examples.
    $defaults = Get-DefaultTasks
    Save-Tasks -Tasks $defaults
    return $defaults
}

function Save-Tasks {
    param([Parameter(Mandatory)] $Tasks)
    try {
        ,@($Tasks) | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:TasksFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "  Failed to save tasks: $_" -ForegroundColor Red
    }
}

# ============================================================================
#  Task execution
# ============================================================================

function Invoke-Task {
    param([Parameter(Mandatory)] $Task)

    $steps = @($Task.Steps)
    if ($steps.Count -eq 0) {
        Write-Host '  This task has no steps.' -ForegroundColor Yellow
        return
    }

    # 1. Collect distinct {{tokens}} across all steps and prompt once each.
    $tokenValues = @{}
    foreach ($s in $steps) {
        foreach ($m in [regex]::Matches($s, '\{\{\s*([^}]+?)\s*\}\}')) {
            $name = $m.Groups[1].Value
            if (-not $tokenValues.ContainsKey($name)) { $tokenValues[$name] = $null }
        }
    }
    if ($tokenValues.Count -gt 0) {
        Write-Host '  This task needs some values (blank any field to cancel):' -ForegroundColor Cyan
        foreach ($name in @($tokenValues.Keys)) {
            $v = Read-Value -Prompt "$name =" -CancelOnBlank
            if ($null -eq $v) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
            $tokenValues[$name] = $v
        }
        Write-Host ''
    }

    # 2. Resolve each step (literal replace avoids regex-substitution pitfalls).
    $resolvedSteps = foreach ($s in $steps) {
        $r = $s
        foreach ($m in [regex]::Matches($s, '\{\{\s*([^}]+?)\s*\}\}')) {
            $r = $r.Replace($m.Value, [string]$tokenValues[$m.Groups[1].Value])
        }
        $r
    }
    $resolvedSteps = @($resolvedSteps)

    # 3. Preview + confirm.
    Write-Host "  Task: $($Task.Name)" -ForegroundColor White
    Write-Host '  The following commands will run in order:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $resolvedSteps.Count; $i++) {
        Write-Host ("    {0}. {1} {2}" -f ($i + 1), $Script:TcpkgExe, $resolvedSteps[$i])
    }
    $coe = [bool]$Task.ContinueOnError
    Write-Host ("  On error: {0}" -f $(if ($coe) { 'continue to next step' } else { 'stop the task' })) -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Confirm-YesNo -Prompt 'Run this task now?')) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return
    }
    Write-Host ''

    # 4. Execute.
    $stepNo = 0
    foreach ($step in $resolvedSteps) {
        $stepNo++
        Write-Host ("  --- Step {0}/{1} ---" -f $stepNo, $resolvedSteps.Count) -ForegroundColor Cyan
        Invoke-Tcpkg -ArgList (Split-CommandLine $step)
        $code = $Script:LastExit
        if ($code -ne 0) {
            Write-Host ("  Step {0} exited with code {1}." -f $stepNo, $code) -ForegroundColor Red
            if (-not $coe) {
                Write-Host '  Stopping task (ContinueOnError = false).' -ForegroundColor Red
                return
            }
        }
    }
    Write-Host "`n  Task complete." -ForegroundColor Green
}

# ============================================================================
#  Task menu
# ============================================================================

function Show-TaskList {
    param([Parameter(Mandatory)] $Tasks)
    if (@($Tasks).Count -eq 0) {
        Write-Host '  (no tasks defined)' -ForegroundColor DarkGray
        return
    }
    Show-SelectableList -Items @($Tasks) -Columns @(
        @{ Header = 'Task';        Expr = { $_.Name } },
        @{ Header = 'Steps';       Expr = { @($_.Steps).Count }; Align = 'Right' },
        @{ Header = 'On error';    Expr = { if ([bool]$_.ContinueOnError) { 'continue' } else { 'stop' } } },
        @{ Header = 'Description';  Expr = { $d = [string]$_.Description; if ($d.Length -gt 50) { $d.Substring(0, 47) + '...' } else { $d } } }
    )
}

function Select-Task {
    param([Parameter(Mandatory)] $Tasks, [string]$Verb = 'select')
    if (@($Tasks).Count -eq 0) { Write-Host '  No tasks available.' -ForegroundColor Yellow; return $null }
    Show-TaskList -Tasks $Tasks
    $sel = Read-Host "`n  Number of task to $Verb (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le @($Tasks).Count) {
        return [int]$sel - 1
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

function New-TaskInteractive {
    Write-Host '  Create a new task. Each step is the argument string passed to tcpkg' -ForegroundColor Cyan
    Write-Host '  (do NOT type the leading "tcpkg"). Use {{Name}} for values to prompt at' -ForegroundColor Cyan
    Write-Host '  run time. Enter a blank line to finish adding steps.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Examples:  install TF6310.TcpIp.XAE -y' -ForegroundColor DarkGray
    Write-Host '             upgrade {{PackageName}} --allow-downgrade' -ForegroundColor DarkGray
    Write-Host ''

    $name = Read-Value -Prompt 'Task name (blank to cancel):' -CancelOnBlank
    if ($null -eq $name) { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
    $desc = Read-Value -Prompt 'Description (optional):' -AllowEmpty
    $coe  = Confirm-YesNo -Prompt 'Continue to next step if a step fails?'

    $steps = New-Object System.Collections.Generic.List[string]
    $n = 1
    while ($true) {
        $line = Read-Host "  Step $n (blank = done)"
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $steps.Add($line.Trim())
        $n++
    }

    if ($steps.Count -eq 0) {
        Write-Host '  No steps entered; task not created.' -ForegroundColor Yellow
        return
    }

    $task = [pscustomobject]@{
        Name            = $name
        Description     = $desc
        ContinueOnError = $coe
        Steps           = @($steps)
    }

    $tasks = @(Get-Tasks)
    $tasks += $task
    Save-Tasks -Tasks $tasks
    Write-Host "`n  Saved '$name' ($($steps.Count) step(s)) to $Script:TasksFile" -ForegroundColor Green
}

function Show-TaskDetails {
    param([Parameter(Mandatory)] $Task)
    Write-Host "  Name        : $($Task.Name)" -ForegroundColor White
    Write-Host "  Description : $($Task.Description)"
    Write-Host "  On error    : $(if ([bool]$Task.ContinueOnError) { 'continue' } else { 'stop' })"
    Write-Host '  Steps:'
    $i = 1
    foreach ($s in @($Task.Steps)) {
        Write-Host ("    {0}. {1} {2}" -f $i, $Script:TcpkgExe, $s)
        $i++
    }
}

function Invoke-TasksMenu {
    while ($true) {
        Show-Header -Title 'Tasks (automation)'
        Write-Host "  Tasks file: $Script:TasksFile" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1. List tasks'
        Write-Host '   2. Run a task'
        Write-Host '   3. Create a task'
        Write-Host '   4. Show task details'
        Write-Host '   5. Delete a task'
        Write-Host '   0. Back'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' { Write-Host ''; Show-TaskList -Tasks (Get-Tasks); Wait-Continue }
            '2' {
                Write-Host ''
                $tasks = @(Get-Tasks)
                $idx = Select-Task -Tasks $tasks -Verb 'run'
                if ($null -ne $idx) { Write-Host ''; Invoke-Task -Task $tasks[$idx] }
                Wait-Continue
            }
            '3' { Write-Host ''; New-TaskInteractive; Wait-Continue }
            '4' {
                Write-Host ''
                $tasks = @(Get-Tasks)
                $idx = Select-Task -Tasks $tasks -Verb 'view'
                if ($null -ne $idx) { Write-Host ''; Show-TaskDetails -Task $tasks[$idx] }
                Wait-Continue
            }
            '5' {
                Write-Host ''
                $tasks = @(Get-Tasks)
                $idx = Select-Task -Tasks $tasks -Verb 'delete'
                if ($null -ne $idx) {
                    $name = $tasks[$idx].Name
                    if (Confirm-YesNo -Prompt "Delete '$name'?") {
                        # Exclude by index (safe even with duplicate names).
                        $kept = @()
                        for ($k = 0; $k -lt $tasks.Count; $k++) {
                            if ($k -ne $idx) { $kept += $tasks[$k] }
                        }
                        Save-Tasks -Tasks $kept
                        Write-Host "  Deleted '$name'." -ForegroundColor Green
                    }
                }
                Wait-Continue
            }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# ============================================================================
#  Packages & workloads menu
# ============================================================================

# Run `tcpkg resolve <name> --dependency-tree`, capturing output as UTF-8 and
# printing each line with Write-Host so the box-drawing characters (├── └── │)
# render correctly regardless of the console's default output encoding.
function Invoke-DependencyTree {
    param([Parameter(Mandatory)] [string] $PackageName)
    if ($Script:DryRun) {
        Write-Host ("  [dry-run] {0} resolve {1} --dependency-tree" -f $Script:TcpkgExe, $PackageName) -ForegroundColor DarkYellow
        return
    }
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH.' -ForegroundColor Red
        return
    }
    Write-Host ("  > {0} resolve {1} --dependency-tree" -f $Script:TcpkgExe, $PackageName) -ForegroundColor DarkGray
    Write-Host ''

    # Capture output bytes with UTF-8 encoding, then decode and print each line.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $lines = & $Script:TcpkgExe resolve $PackageName '--dependency-tree' 2>&1
    $Script:LastExit = $LASTEXITCODE
    [Console]::OutputEncoding = $prevEnc
    $ErrorActionPreference = $prev

    foreach ($line in $lines) {
        # Each line arrives as a string; re-encode from the bytes tcpkg wrote.
        $raw  = [System.Text.Encoding]::UTF8.GetBytes([string]$line)
        $text = [System.Text.Encoding]::UTF8.GetString($raw)
        Write-Host $text
    }
}

# Ask which feed to query. Returns:
#   $null            - user cancelled
#   @()              - all feeds (no filter)
#   @('-n', <name>)  - filter args for `tcpkg list` (-n, --name <feed>)
# Only enabled feeds are offered, since a disabled feed cannot be searched.
function Select-FeedFilter {
    $feeds = @(Get-SourceList | Where-Object { $_.Enabled } | Sort-Object Priority)
    if ($feeds.Count -eq 0) {
        # No feeds could be read (e.g. tcpkg missing); fall back to unfiltered.
        return ,@()
    }
    $names = @($feeds | ForEach-Object { $_.Name }) + 'All feeds'
    Write-Host '  Retrieve the list from which feed?' -ForegroundColor Cyan
    Show-SelectableList -Items $names -Columns @(
        @{ Header = 'Feed'; Expr = { $_ } }
    )
    $sel = Read-Host "`n  Choice (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $names.Count) {
        $pick = $names[[int]$sel - 1]
        if ($pick -eq 'All feeds') { return ,@() }
        return @('-n', $pick)
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

# Run a `tcpkg list ...` command with --as-json and parse the packages.
# Confirmed schema (TcPkg 2.4.70, plain list): Id, Version, Source, IsPreview,
# Workload, Variant, Category, Title, Description, ProjectUrl, LicenseUrl,
# Authors, Tags, InstallDate, Icon, PackageDependencies.
# Upgradable entries (list -o) use a confirmed minimal schema:
#   Id, InstalledVersion, LatestVersion, Source
# (matched by the candidate lists below; extra candidates are kept as
# harmless fallbacks for other tcpkg versions). Returns an object with:
#   Ok      - $true if packages could be parsed
#   Items   - normalized objects (Name = Id, plus display fields)
#   Columns - column definitions for Show-SelectableList (only non-empty ones)
function Get-PackageList {
    param([Parameter(Mandatory)] [string[]] $ListArgs)
    $fail = [pscustomobject]@{ Ok = $false; Items = @(); Columns = @() }
    if (-not (Test-TcpkgAvailable)) { return $fail }

    Write-Host ("  > {0} {1} --as-json" -f $Script:TcpkgExe, ($ListArgs -join ' ')) -ForegroundColor DarkGray
    $raw  = & $Script:TcpkgExe @ListArgs '--as-json' 2>&1
    $text = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
    # Installed packages embed their icons as huge base64 data-URI strings; drop
    # them before parsing (they are never displayed and bloat ConvertFrom-Json).
    # Safe because a base64/data-URI value cannot contain a quote character.
    $text = [regex]::Replace($text, '"Icon"\s*:\s*"[^"]*"', '"Icon":null')
    $start = $text.IndexOf('[')
    $end   = $text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) { return $fail }
    $json = $null
    try { $json = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { return $fail }

    $items = @($json)
    if ($items.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Items = @(); Columns = @() } }

    $props = @($items[0].PSObject.Properties.Name)
    $nameProp = if ($props -contains 'Id') { 'Id' } elseif ($props -contains 'Name') { 'Name' } else { $null }
    if (-not $nameProp) { return $fail }

    # Null-safe string read of a value.
    $str = { param($v) if ($null -eq $v) { '' } else { [string]$v } }
    # First non-empty among candidate property names.
    $pick = {
        param($obj, [string[]]$cands)
        foreach ($c in $cands) {
            if ($obj.PSObject.Properties.Name -contains $c) {
                $v = $obj.$c
                if ($null -ne $v -and '' -ne [string]$v) { return [string]$v }
            }
        }
        return ''
    }

    $norm = foreach ($i in $items) {
        $date = & $str $i.InstallDate
        if ($date -match '^(\d{4}-\d{2}-\d{2})') { $date = $Matches[1] }   # trim time part
        [pscustomobject]@{
            Name        = [string]$i.$nameProp
            Version     = & $str $i.Version
            Title       = & $str $i.Title
            InstVer     = & $pick $i @('InstalledVersion','CurrentVersion')
            Latest      = & $pick $i @('LatestVersion','AvailableVersion','NewVersion')
            Source      = & $str $i.Source
            Category    = & $str $i.Category
            Variant     = & $str $i.Variant
            Workload    = if ($i.Workload -eq $true) { 'Yes' } else { '' }
            Preview     = if ($i.IsPreview -eq $true) { 'Yes' } else { '' }
            InstallDate = $date
        }
    }
    $norm = @($norm)

    # Package column always; the rest only when at least one row has a value.
    $cols = New-Object System.Collections.Generic.List[hashtable]
    $cols.Add(@{ Header = 'Package'; Expr = { $_.Name } })
    if (@($norm | Where-Object { $_.Version     }).Count -gt 0) { $cols.Add(@{ Header = 'Version';      Expr = { $_.Version } }) }
    if (@($norm | Where-Object { $_.Title       }).Count -gt 0) { $cols.Add(@{ Header = 'Title';        Expr = { $_.Title } }) }
    if (@($norm | Where-Object { $_.InstVer     }).Count -gt 0) { $cols.Add(@{ Header = 'Installed';    Expr = { $_.InstVer } }) }
    if (@($norm | Where-Object { $_.Latest      }).Count -gt 0) { $cols.Add(@{ Header = 'Latest';       Expr = { $_.Latest } }) }
    if (@($norm | Where-Object { $_.Source      }).Count -gt 0) { $cols.Add(@{ Header = 'Source';       Expr = { $_.Source } }) }
    if (@($norm | Where-Object { $_.Category    }).Count -gt 0) { $cols.Add(@{ Header = 'Category';     Expr = { $_.Category } }) }
    if (@($norm | Where-Object { $_.Variant     }).Count -gt 0) { $cols.Add(@{ Header = 'Variant';      Expr = { $_.Variant } }) }
    if (@($norm | Where-Object { $_.Workload    }).Count -gt 0) { $cols.Add(@{ Header = 'Workload';     Expr = { $_.Workload } }) }
    if (@($norm | Where-Object { $_.Preview     }).Count -gt 0) { $cols.Add(@{ Header = 'Preview';      Expr = { $_.Preview } }) }
    if (@($norm | Where-Object { $_.InstallDate }).Count -gt 0) { $cols.Add(@{ Header = 'Install Date'; Expr = { $_.InstallDate } }) }

    return [pscustomobject]@{ Ok = $true; Items = $norm; Columns = $cols.ToArray() }
}

# Show a numbered package table and return the chosen package object (or $null).
function Select-PackageFromTable {
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] $Columns,
        [string] $Verb = 'act on'
    )
    $list = @($Items)
    Show-SelectableList -Items $list -Columns $Columns
    $sel = Read-Host "`n  Number of package to $Verb (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $list.Count) {
        return $list[[int]$sel - 1]
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

# Build a hashtable of name (lowercase) -> installed version from tcpkg list -i.
# Fetched once per browser session and passed around so we don't hammer the CLI.
function Get-InstalledIndex {
    $idx = @{}
    if (-not (Test-TcpkgAvailable)) { return $idx }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & $Script:TcpkgExe list '-i' '--as-json' 2>&1
    $ErrorActionPreference = $prev
    $text = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
    $text = [regex]::Replace($text, '"Icon"\s*:\s*"[^"]*"', '"Icon":null')
    $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
    if ($s -lt 0 -or $e -le $s) { return $idx }
    try {
        $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
        foreach ($j in @($json)) {
            $key = ([string]$j.Id).ToLower()
            if ($key -and -not $idx.ContainsKey($key)) { $idx[$key] = [string]$j.Version }
        }
    } catch {}
    return $idx
}

# Determine install status for a package given the installed index and the
# feed version string. Returns one of: 'not-installed', 'up-to-date',
# 'upgradable', 'newer-than-feed'.
function Get-InstallStatus {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [hashtable] $InstalledIndex,
        [string] $FeedVersion = ''
    )
    $instVer = $InstalledIndex[$Name.ToLower()]
    if ([string]::IsNullOrEmpty($instVer)) { return 'not-installed' }
    if ([string]::IsNullOrEmpty($FeedVersion)) { return 'up-to-date' }
    try {
        # Compare as System.Version; fall back to string compare.
        $iv = [System.Version]$instVer
        $fv = [System.Version]$FeedVersion
        if ($iv -lt $fv) { return 'upgradable' }
        if ($iv -gt $fv) { return 'newer-than-feed' }
        return 'up-to-date'
    } catch {
        if ($instVer -eq $FeedVersion) { return 'up-to-date' }
        return 'up-to-date'   # can't compare; treat as current
    }
}

# Dynamic numbered action menu for a selected package.
# Only shows actions that are valid for the current install status.
# Returns the chosen action name or $null.
function Select-PackageAction {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [hashtable] $InstalledIndex,
        [string] $FeedVersion = ''
    )
    $status    = Get-InstallStatus -Name $Name -InstalledIndex $InstalledIndex -FeedVersion $FeedVersion
    $instVer   = $InstalledIndex[$Name.ToLower()]
    $statusMsg = switch ($status) {
        'not-installed'    { 'not installed' }
        'up-to-date'       { "installed  v$instVer  (up to date)" }
        'upgradable'       { "installed  v$instVer  -> v$FeedVersion available" }
        'newer-than-feed'  { "installed  v$instVer  (feed has v$FeedVersion)" }
    }

    # Build the dynamic action list with its tcpkg command label.
    $actions = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($status -eq 'not-installed') {
        $actions.Add([pscustomobject]@{ Label = 'Install';        Cmd = 'tcpkg install <package>';  Action = 'install' })
    }
    if ($status -eq 'upgradable') {
        $actions.Add([pscustomobject]@{ Label = 'Upgrade';        Cmd = 'tcpkg upgrade <package>';  Action = 'upgrade' })
    }
    if ($status -in @('up-to-date','upgradable','newer-than-feed')) {
        $actions.Add([pscustomobject]@{ Label = 'Repair';         Cmd = 'tcpkg repair <package>';   Action = 'repair' })
        $actions.Add([pscustomobject]@{ Label = 'Uninstall';      Cmd = 'tcpkg uninstall <package>';Action = 'uninstall' })
    }
    $actions.Add([pscustomobject]@{ Label = 'Show details';   Cmd = 'tcpkg show <package>';     Action = 'show' })

    Write-Host "  $($Name)" -ForegroundColor White
    Write-Host "  Status : $statusMsg" -ForegroundColor $(
        switch ($status) {
            'not-installed'   { 'DarkGray' }
            'up-to-date'      { 'Green' }
            'upgradable'      { 'Yellow' }
            'newer-than-feed' { 'Cyan' }
        }
    )
    Write-Host ''
    Write-Host '  Available actions:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $actions.Count; $i++) {
        $a = $actions[$i]
        Write-Host ("   {0}. {1,-14}  ({2})" -f ($i + 1), $a.Label, $a.Cmd)
    }
    Write-Host '   0. Back'
    Write-Host ''

    $sel = (Read-Host '  Choice').Trim()
    if ($sel -eq '0' -or [string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $actions.Count) {
        return $actions[[int]$sel - 1].Action
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

# List packages, then let the user repeatedly pick one by number and run an
# action on it. Falls back to plain output if the JSON can't be parsed.
function Invoke-PackageBrowser {
    param([Parameter(Mandatory)] [string[]] $ListArgs)
    $res = Get-PackageList -ListArgs $ListArgs
    if (-not $res.Ok) {
        Write-Host '  Package data could not be read as JSON; showing the standard output.' -ForegroundColor Yellow
        Write-Host ''
        Invoke-Tcpkg -ArgList $ListArgs
        Wait-Continue
        return
    }
    if (@($res.Items).Count -eq 0) {
        Write-Host '  No packages found.' -ForegroundColor Yellow
        Wait-Continue
        return
    }

    # Fetch the installed index once for the whole browser session.
    Write-Host '  Checking installed packages...' -ForegroundColor DarkGray
    $installed = Get-InstalledIndex

    while ($true) {
        Write-Host ''
        $pkg = Select-PackageFromTable -Items $res.Items -Columns $res.Columns
        if (-not $pkg) { return }
        Write-Host ''
        $action = Select-PackageAction -Name $pkg.Name -InstalledIndex $installed -FeedVersion $pkg.Version
        if ($action) {
            Write-Host ''
            Invoke-PackageAction -Action $action -Name $pkg.Name
            Wait-Continue
            # Refresh installed index after any mutating action.
            if ($action -in @('install','upgrade','repair','uninstall')) {
                Write-Host '  Refreshing installed package list...' -ForegroundColor DarkGray
                $installed = Get-InstalledIndex
            }
        }
    }
}

# Run a single tcpkg action against a package name, with the usual flag prompts.
# For 'install', fetches available versions via tcpkg list -a and presents them
# as a numbered list instead of a free-text version prompt.
function Invoke-PackageAction {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Name
    )
    switch ($Action) {
        'show' {
            Write-Host ''
            Invoke-Tcpkg -ArgList @('show', $Name)
        }
        'install' {
            # Fetch available versions for this package.
            Write-Host '  Fetching available versions...' -ForegroundColor DarkGray
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            $raw  = & $Script:TcpkgExe list '-a' $Name '--as-json' 2>&1
            $ErrorActionPreference = $prev
            $text  = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
            $si    = $text.IndexOf('['); $ei = $text.LastIndexOf(']')
            $versions = @()
            if ($si -ge 0 -and $ei -gt $si) {
                try {
                    $json = $text.Substring($si, $ei - $si + 1) | ConvertFrom-Json
                    $versions = @($json | Where-Object { $null -ne $_.Version } |
                                  ForEach-Object { [string]$_.Version } |
                                  Select-Object -Unique)
                } catch {}
            }

            $spec = $null
            if ($versions.Count -gt 0) {
                Write-Host ''
                Write-Host "  Available versions of $Name :" -ForegroundColor Cyan
                # Newest first via System.Version sort; fall back to string sort.
                try   { $sorted = @($versions | Sort-Object { [System.Version]$_ } -Descending) }
                catch { $sorted = @($versions | Sort-Object -Descending) }
                for ($i = 0; $i -lt $sorted.Count; $i++) {
                    Write-Host ("   {0}. {1}" -f ($i + 1), $sorted[$i])
                }
                Write-Host ("   {0}. Latest (let tcpkg decide)" -f ($sorted.Count + 1))
                Write-Host '   0. Cancel'
                Write-Host ''
                $vs = (Read-Host '  Choice').Trim()
                if ($vs -eq '0' -or [string]::IsNullOrWhiteSpace($vs)) { return }
                if ($vs -match '^\d+$' -and [int]$vs -ge 1 -and [int]$vs -le $sorted.Count) {
                    $spec = "$Name=$($sorted[[int]$vs - 1])"
                } elseif ($vs -eq [string]($sorted.Count + 1)) {
                    $spec = $Name
                } else {
                    Write-Host '  Invalid selection.' -ForegroundColor Yellow; return
                }
            } else {
                Write-Host '  Could not retrieve version list; installing latest.' -ForegroundColor Yellow
                $spec = $Name
            }

            $a = @('install', $spec)
            if (Confirm-YesNo -Prompt 'Unattended (-y, no prompts)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'upgrade' {
            $a = @('upgrade', $Name)
            if (Confirm-YesNo -Prompt 'Allow downgrade (--allow-downgrade)?') { $a += '--allow-downgrade' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'repair' {
            $a = @('repair', $Name)
            if (Confirm-YesNo -Prompt 'Include dependencies (--include-dependencies)?') { $a += '--include-dependencies' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'uninstall' {
            $a = @('uninstall', $Name)
            if (Confirm-YesNo -Prompt 'Include dependencies (--include-dependencies)?') { $a += '--include-dependencies' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
    }
}

function Invoke-PackagesMenu {
    while ($true) {
        Show-Header -Title 'Packages & workloads'
        Write-Host '   1. List available packages        (tcpkg list)'
        Write-Host '   2. List installed (local)         (tcpkg list -i)'
        Write-Host '   3. List upgradable                (tcpkg list -o)'
        Write-Host '   4. List workloads                 (tcpkg list -t workload)'
        Write-Host '   5. Show package details           (tcpkg show <name>)'
        Write-Host '   6. List all versions of a package (tcpkg list -a <name>)'
        Write-Host '   7. Show dependency tree           (tcpkg resolve <name> --dependency-tree)'
        Write-Host '   8. Install a package              (tcpkg install <package>)'
        Write-Host '   9. Upgrade a package / all        (tcpkg upgrade <package>|all)'
        Write-Host '  10. Repair a package               (tcpkg repair <package>)'
        Write-Host '  11. Uninstall a package / all      (tcpkg uninstall <package>|all)'
        Write-Host '  12. Search for a package           (tcpkg list <term>)'
        Write-Host '   0. Back'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs (@('list') + $filter)
                }
            }
            '2' { Write-Host ''; Invoke-PackageBrowser -ListArgs @('list','-i') }
            '3' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs (@('list','-o') + $filter)
                }
            }
            '4' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs (@('list','-t','workload') + $filter)
                }
            }
            '5' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    $res = Get-PackageList -ListArgs (@('list') + $filter)
                    if ($res.Ok -and @($res.Items).Count -gt 0) {
                        Write-Host ''
                        $pkg = Select-PackageFromTable -Items $res.Items -Columns $res.Columns -Verb 'show'
                        if ($pkg) {
                            Write-Host ''
                            Invoke-Tcpkg -ArgList @('show', $pkg.Name)
                        }
                    } elseif ($res.Ok) {
                        Write-Host '  No packages found in that feed.' -ForegroundColor Yellow
                    } else {
                        Write-Host '  Could not read the package list; enter the name manually.' -ForegroundColor Yellow
                        $n = Read-Value 'Package name:'
                        Invoke-Tcpkg -ArgList @('show', $n)
                    }
                    Wait-Continue
                }
            }
            '6' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    $res = Get-PackageList -ListArgs (@('list') + $filter)
                    if ($res.Ok -and @($res.Items).Count -gt 0) {
                        Write-Host ''
                        $pkg = Select-PackageFromTable -Items $res.Items -Columns $res.Columns -Verb 'list versions of'
                        if ($pkg) {
                            Write-Host ''
                            Invoke-Tcpkg -ArgList (@('list', '-a', $pkg.Name) + $filter)
                        }
                    } elseif ($res.Ok) {
                        Write-Host '  No packages found in that feed.' -ForegroundColor Yellow
                    } else {
                        Write-Host '  Could not read the package list; enter the name manually.' -ForegroundColor Yellow
                        $n = Read-Value 'Package name:'
                        Invoke-Tcpkg -ArgList @('list', '-a', $n)
                    }
                    Wait-Continue
                }
            }
            '7' {
                Write-Host ''
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    $res = Get-PackageList -ListArgs (@('list') + $filter)
                    if ($res.Ok -and @($res.Items).Count -gt 0) {
                        Write-Host ''
                        $pkg = Select-PackageFromTable -Items $res.Items -Columns $res.Columns -Verb 'resolve'
                        if ($pkg) {
                            Write-Host ''
                            Invoke-DependencyTree -PackageName $pkg.Name
                        }
                    } elseif ($res.Ok) {
                        Write-Host '  No packages found in that feed.' -ForegroundColor Yellow
                    } else {
                        Write-Host '  Could not read the package list; enter the name manually.' -ForegroundColor Yellow
                        $n = Read-Value 'Package name (optionally name=version):'
                        Invoke-DependencyTree -PackageName $n
                    }
                    Wait-Continue
                }
            }
            '8' {
                Write-Host ''
                $term = Read-Value 'Search term (blank = list all available):' -AllowEmpty
                $filter = Select-FeedFilter
                if ($null -ne $filter) {
                    $listArgs = @('list')
                    if (-not [string]::IsNullOrWhiteSpace($term)) { $listArgs += $term }
                    $listArgs += $filter
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs $listArgs
                }
            }
            '9' {
                Write-Host ''
                Write-Host '   1. Choose from upgradable packages  (tcpkg list -o)'
                Write-Host '   2. Upgrade ALL packages              (tcpkg upgrade all)'
                Write-Host '   0. Back'
                Write-Host ''
                $sub = (Read-Host '  Choice').Trim()
                if ($sub -eq '1') {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs @('list','-o')
                } elseif ($sub -eq '2') {
                    Write-Host ''
                    $a = @('upgrade','all')
                    if (Confirm-YesNo -Prompt 'Allow downgrade (--allow-downgrade)?') { $a += '--allow-downgrade' }
                    if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
                    Write-Host ''
                    Invoke-Tcpkg -ArgList $a
                    Wait-Continue
                }
            }
            '10' {
                Write-Host ''
                Invoke-PackageBrowser -ListArgs @('list','-i')
            }
            '11' {
                Write-Host ''
                Write-Host '   1. Choose from installed packages  (tcpkg list -i)'
                Write-Host '   2. Uninstall ALL packages          (tcpkg uninstall all)'
                Write-Host '   0. Back'
                Write-Host ''
                $sub = (Read-Host '  Choice').Trim()
                if ($sub -eq '1') {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs @('list','-i')
                } elseif ($sub -eq '2') {
                    Write-Host ''
                    Write-Host '  This removes ALL TwinCAT packages from this machine.' -ForegroundColor Red
                    if (Confirm-YesNo -Prompt 'Are you sure you want to uninstall everything?') {
                        $a = @('uninstall','all')
                        if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
                        Write-Host ''
                        Invoke-Tcpkg -ArgList $a
                    }
                    Wait-Continue
                }
            }
            '12' {
                Write-Host ''
                $term = Read-Value 'Search term (blank to cancel):' -CancelOnBlank
                if ($null -ne $term) {
                    Write-Host ''
                    Write-Host '  Match type:' -ForegroundColor Cyan
                    Write-Host '   1. Partial match  (tcpkg list <term>)'
                    Write-Host '   2. Exact match    (tcpkg list <term> --exact)'
                    Write-Host ''
                    $mt = (Read-Host '  Choice').Trim()
                    if ($mt -eq '1' -or $mt -eq '2') {
                        $listArgs = @('list', $term)
                        if ($mt -eq '2') { $listArgs += '--exact' }
                        Write-Host ''
                        $filter = Select-FeedFilter
                        if ($null -ne $filter) {
                            Write-Host ''
                            Invoke-PackageBrowser -ListArgs ($listArgs + $filter)
                        }
                    }
                }
            }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# ============================================================================
#  Sources (feeds) menu
# ============================================================================

# Run `tcpkg source list` and parse it into objects:
#   Name, Priority, Enabled, Auth, BypassProxy, Prereleases, Take, Url
# Prefers `--as-json` (robust against display-format changes); falls back to
# parsing the plain-text output if the JSON can't be read. Read-only, so it
# runs even in dry-run mode (we need real data to plan).
function Get-SourceList {
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH; cannot read sources.' -ForegroundColor Red
        return @()
    }

    # --- Preferred path: JSON ---
    $rawJson = & $Script:TcpkgExe source list --as-json 2>&1
    $text = (@($rawJson) | ForEach-Object { [string]$_ }) -join "`n"
    # Tolerate any banner/log lines around the JSON by trimming to the array.
    $start = $text.IndexOf('[')
    $end   = $text.LastIndexOf(']')
    if ($start -ge 0 -and $end -gt $start) {
        try {
            $json = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
            $result = foreach ($j in @($json)) {
                [pscustomobject]@{
                    Name        = [string]$j.Name
                    Priority    = [int]$j.Priority
                    Enabled     = [bool]$j.Enabled
                    Auth        = if ([string]::IsNullOrEmpty([string]$j.User)) { 'Unauthenticated' } else { 'Authenticated' }
                    BypassProxy = if ($j.BypassProxy) { 'True' } else { 'False' }
                    Prereleases = if ($j.IncludePrereleases) { 'True' } else { 'False' }
                    Take        = if ($null -eq $j.Take) { 'Default' } else { [string]$j.Take }
                    Url         = [string]$j.Source
                }
            }
            return @($result)
        } catch {
            # fall through to the text parser
        }
    }

    # --- Fallback: parse the plain-text listing ---
    $raw = & $Script:TcpkgExe source list 2>&1
    $result = foreach ($line in $raw) {
        $text = [string]$line
        # Source lines look like:
        #   <Name> - <URL> [DISABLED] (Authenticated) | Priority - <N> | Bypass Proxy - <bool> | Include Prereleases - <bool> | Take - <value>
        if ($text -match '\|\s*Priority\s*-\s*(\d+)') {
            $priority = [int]$Matches[1]
            $name = (($text -split '\s-\shttps?://', 2)[0]).Trim()
            $enabled = ($text -notmatch '\[DISABLED\]')
            $url = ''
            if ($text -match '(https?://\S+)') { $url = $Matches[1] }
            $auth = if ($text -match '\(Authenticated\)') { 'Authenticated' }
                    elseif ($text -match '\(Unauthenticated\)') { 'Unauthenticated' }
                    else { '' }
            $bypass = if ($text -match '\|\s*Bypass Proxy\s*-\s*(\S+)') { $Matches[1] } else { '' }
            $prerel = if ($text -match '\|\s*Include Prereleases\s*-\s*(\S+)') { $Matches[1] } else { '' }
            $take   = if ($text -match '\|\s*Take\s*-\s*(\S+)') { $Matches[1] } else { '' }
            [pscustomobject]@{
                Name        = $name
                Priority    = $priority
                Enabled     = $enabled
                Auth        = $auth
                BypassProxy = $bypass
                Prereleases = $prerel
                Take        = $take
                Url         = $url
            }
        }
    }
    return @($result)
}

# Display sources as an aligned table (no selection numbers), including the URL.
function Show-SourceTable {
    param([Parameter(Mandatory)] $Sources)
    $cols = @(
        @{ Header = 'Source';       Expr = { $_.Name } },
        @{ Header = 'Priority';     Expr = { $_.Priority }; Align = 'Right' },
        @{ Header = 'State';        Expr = { if ($_.Enabled) { 'enabled' } else { 'disabled' } } },
        @{ Header = 'Auth';         Expr = { $_.Auth } },
        @{ Header = 'Bypass Proxy'; Expr = { $_.BypassProxy } },
        @{ Header = 'Prereleases';  Expr = { $_.Prereleases } },
        @{ Header = 'Take';         Expr = { $_.Take } },
        @{ Header = 'URL';          Expr = { $_.Url } }
    )
    Show-SelectableList -Items (@($Sources) | Sort-Object Priority) -Columns $cols -NoNumber
}
# Pass -Sources to reuse an already-fetched list instead of querying again.
function Select-Source {
    param([string]$Verb = 'select', $Sources)
    if (-not $Sources) { $Sources = Get-SourceList }
    $list = @($Sources | Sort-Object Priority)
    if ($list.Count -eq 0) {
        Write-Host '  No sources are configured (or none could be read).' -ForegroundColor Yellow
        return $null
    }
    Write-Host '  Configured sources:' -ForegroundColor Cyan
    Show-SelectableList -Items $list -Columns @(
        @{ Header = 'Source';   Expr = { $_.Name } },
        @{ Header = 'Priority'; Expr = { $_.Priority }; Align = 'Right' },
        @{ Header = 'State';    Expr = { if ($_.Enabled) { 'enabled' } else { 'disabled' } } }
    )
    $sel = Read-Host "`n  Number of source to $Verb (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $list.Count) {
        return $list[[int]$sel - 1]
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

# Move a source to a target position, cascading the others. tcpkg refuses a
# priority that is already in use, so we apply changes in two passes:
#   1. "park" every affected source at a temporary high priority (frees slots)
#   2. assign the final, contiguous 1..N priorities
# This is collision-free regardless of the starting layout.
function Set-SourcePriorityCascade {
    param(
        [Parameter(Mandatory)] $AllSources,
        [Parameter(Mandatory)] [string] $SelectedName,
        [Parameter(Mandatory)] [int] $Target
    )
    $ordered = @($AllSources | Sort-Object Priority)
    $count   = $ordered.Count
    if ($Target -lt 1)      { $Target = 1 }
    if ($Target -gt $count) { $Target = $count }

    $selected = $ordered | Where-Object { $_.Name -eq $SelectedName } | Select-Object -First 1
    if (-not $selected) { Write-Host "  Source '$SelectedName' not found." -ForegroundColor Red; return }
    $rest = @($ordered | Where-Object { $_.Name -ne $SelectedName })

    # Build the new ordering with the selected source inserted at $Target.
    $newOrder = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $rest.Count; $i++) {
        if ($i -eq ($Target - 1)) { $newOrder.Add($selected) }
        $newOrder.Add($rest[$i])
    }
    if (($Target - 1) -ge $rest.Count) { $newOrder.Add($selected) }

    # Determine which sources actually change (new contiguous priority != current).
    $changes = @()
    for ($i = 0; $i -lt $newOrder.Count; $i++) {
        $final = $i + 1
        if ($newOrder[$i].Priority -ne $final) {
            $changes += [pscustomobject]@{ Name = $newOrder[$i].Name; From = $newOrder[$i].Priority; To = $final }
        }
    }
    if ($changes.Count -eq 0) {
        Write-Host "  '$SelectedName' is already at priority $Target. Nothing to do." -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '  Planned priority changes:' -ForegroundColor Cyan
    foreach ($c in $changes) { Write-Host ("    {0}: {1} -> {2}" -f $c.Name, $c.From, $c.To) }
    Write-Host ''
    if (-not (Confirm-YesNo -Prompt 'Apply these changes?')) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        return
    }

    $maxPri   = ($AllSources | Measure-Object -Property Priority -Maximum).Maximum
    $parkBase = [int]$maxPri + 1000

    Write-Host "`n  Pass 1/2 - parking affected sources to free the slots..." -ForegroundColor DarkGray
    $k = 0
    foreach ($c in $changes) {
        Invoke-Tcpkg -ArgList @('source', 'edit', $c.Name, "--priority=$($parkBase + $k)", '-y')
        if ($Script:LastExit -ne 0 -and -not $Script:DryRun) {
            Write-Host "  Failed to park '$($c.Name)' (exit $Script:LastExit). Aborting before final pass." -ForegroundColor Red
            Write-Host '  Some sources may be left at a temporary priority; re-run to finish.' -ForegroundColor Yellow
            return
        }
        $k++
    }

    Write-Host "`n  Pass 2/2 - assigning final priorities..." -ForegroundColor DarkGray
    foreach ($c in $changes) {
        Invoke-Tcpkg -ArgList @('source', 'edit', $c.Name, "--priority=$($c.To)", '-y')
        if ($Script:LastExit -ne 0 -and -not $Script:DryRun) {
            Write-Host "  Failed to set '$($c.Name)' to priority $($c.To) (exit $Script:LastExit)." -ForegroundColor Red
        }
    }
    Write-Host "`n  Done. '$SelectedName' is now priority $Target." -ForegroundColor Green
}

function Invoke-SourcesMenu {
    while ($true) {
        Show-Header -Title 'Sources (feeds)'
        Write-Host '   1. List sources              (tcpkg source list)'
        Write-Host '   2. Verify a source           (tcpkg source verify <name>)'
        Write-Host '   3. Add a Beckhoff feed       (Stable / Outdated / Testing / Preview)'
        Write-Host '   4. Add a custom source       (tcpkg source add ...)'
        Write-Host '   5. Enable / disable a source (tcpkg source edit <name> --enabled ...)'
        Write-Host '   6. Change a source priority  (tcpkg source edit <name> --priority=...)'
        Write-Host '   0. Back'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' {
                Write-Host ''
                $sources = Get-SourceList
                if (@($sources).Count -eq 0) {
                    Write-Host '  No sources are configured (or none could be read).' -ForegroundColor Yellow
                } else {
                    Show-SourceTable -Sources $sources
                }
                Wait-Continue
            }
            '2' {
                Write-Host ''
                $s = Select-Source -Verb 'verify'
                if ($s) { Write-Host ''; Invoke-Tcpkg -ArgList @('source','verify',$s.Name) }
                Wait-Continue
            }
            '3' {
                Write-Host ''
                $names = @($Script:BeckhoffFeeds.Keys)
                Show-SelectableList -Items $names -Columns @(
                    @{ Header = 'Feed';     Expr = { $_ } },
                    @{ Header = 'Priority'; Expr = { $Script:BeckhoffFeeds[$_].Priority }; Align = 'Right' }
                )
                $sel = Read-Host "`n  Feed number (blank to cancel)"
                if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $names.Count) {
                    $name = $names[[int]$sel - 1]
                    $feed = $Script:BeckhoffFeeds[$name]
                    $user = Read-Value 'myBeckhoff email (username, blank to cancel):' -CancelOnBlank
                    if ($null -eq $user) { continue }
                    $argList = @('source','add','-n',$name,'-s',$feed.Url,"--priority=$($feed.Priority)",'-u',$user)
                    Write-Host '  (tcpkg will prompt for the account password.)' -ForegroundColor DarkGray
                    Write-Host ''
                    Invoke-Tcpkg -ArgList $argList
                }
                Wait-Continue
            }
            '4' {
                Write-Host ''
                $name = Read-Value 'Source name (blank to cancel):' -CancelOnBlank
                if ($null -eq $name) { continue }
                $url  = Read-Value 'Feed URL (blank to cancel):' -CancelOnBlank
                if ($null -eq $url) { continue }
                $prio = Read-Value 'Priority (number, blank to cancel):' -CancelOnBlank
                if ($null -eq $prio) { continue }
                $user = Read-Value 'Username (blank = none):' -AllowEmpty
                $argList = @('source','add','-n',$name,'-s',$url,"--priority=$prio")
                if (-not [string]::IsNullOrWhiteSpace($user)) { $argList += @('-u',$user) }
                Write-Host ''
                Invoke-Tcpkg -ArgList $argList; Wait-Continue
            }
            '5' {
                Write-Host ''
                $s = Select-Source -Verb 'enable/disable'
                if ($s) {
                    $current = if ($s.Enabled) { 'enabled' } else { 'disabled' }
                    Write-Host "  '$($s.Name)' is currently $current." -ForegroundColor DarkGray
                    $en = if (Confirm-YesNo -Prompt 'Enable this source? (No = disable)') { 'true' } else { 'false' }
                    Write-Host ''
                    Invoke-Tcpkg -ArgList @('source','edit',$s.Name,'--enabled',$en)
                }
                Wait-Continue
            }
            '6' {
                Write-Host ''
                $sources = Get-SourceList
                $s = Select-Source -Verb 'reprioritize' -Sources $sources
                if ($s) {
                    $count = @($sources).Count
                    Write-Host ''
                    $t = Read-Value "New position for '$($s.Name)' (1 = highest, max $count, blank to cancel):" -CancelOnBlank
                    if ($null -eq $t) { continue }
                    if ($t -match '^\d+$') {
                        Set-SourcePriorityCascade -AllSources $sources -SelectedName $s.Name -Target ([int]$t)
                    } else {
                        Write-Host '  Priority must be a whole number.' -ForegroundColor Yellow
                    }
                }
                Wait-Continue
            }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# ============================================================================
#  Configuration menu
# ============================================================================

# Run `tcpkg config list` and parse "<Setting>: <Value>" lines into objects.
# Read-only, so it runs even in dry-run mode.
function Get-ConfigList {
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH; cannot read configuration.' -ForegroundColor Red
        return @()
    }
    $raw = & $Script:TcpkgExe config list 2>&1
    $result = foreach ($line in $raw) {
        $text = [string]$line
        # Setting names contain no colon, so split on the first colon only.
        if ($text -match '^\s*([^:]+):\s*(.*)$') {
            [pscustomobject]@{
                Setting = $Matches[1].Trim()
                Value   = $Matches[2].Trim()
            }
        }
    }
    return @($result)
}

function Show-ConfigTable {
    param([Parameter(Mandatory)] $Config)
    Show-SelectableList -Items @($Config) -Columns @(
        @{ Header = 'Setting'; Expr = { $_.Setting } },
        @{ Header = 'Value';   Expr = { $_.Value } }
    ) -NoNumber
}

# Descriptor table for all known tcpkg config options.
# Type: 'toggle' (no -v, just -n), 'enum' (fixed value list), 'number' (free integer)
$Script:ConfigOptions = @(
    [pscustomobject]@{ Name = 'useVS2017';          Type = 'toggle'; Values = @();                          Description = 'Visual Studio 2017 integration' }
    [pscustomobject]@{ Name = 'useVS2019';          Type = 'toggle'; Values = @();                          Description = 'Visual Studio 2019 integration' }
    [pscustomobject]@{ Name = 'useVS2022';          Type = 'toggle'; Values = @();                          Description = 'Visual Studio 2022 integration' }
    [pscustomobject]@{ Name = 'useVS2026';          Type = 'toggle'; Values = @();                          Description = 'Visual Studio 2026 integration' }
    [pscustomobject]@{ Name = 'useTcXaeShell';      Type = 'toggle'; Values = @();                          Description = 'TcXaeShell integration' }
    [pscustomobject]@{ Name = 'useTcXaeShell64';    Type = 'toggle'; Values = @();                          Description = 'TcXaeShell 64-bit integration' }
    [pscustomobject]@{ Name = 'verifySignatures';   Type = 'toggle'; Values = @();                          Description = 'Verify package signatures (default: enabled)' }
    [pscustomobject]@{ Name = 'tcPkgVersionOutput'; Type = 'toggle'; Values = @();                          Description = 'Print TcPkg version at start of each command (default: enabled)' }
    [pscustomobject]@{ Name = 'trackInstalledFiles';Type = 'toggle'; Values = @();                          Description = 'Track installed files for repair operations' }
    [pscustomobject]@{ Name = 'logLevel';           Type = 'enum';   Values = @('verbose','information');   Description = 'Log file verbosity (default: information)' }
    [pscustomobject]@{ Name = 'xarMode';            Type = 'enum';   Values = @('UM','KM','KMWithUM');       Description = 'Runtime mode (default: based on system)' }
    [pscustomobject]@{ Name = 'defaultTake';        Type = 'number'; Values = @();                          Description = 'Max results per page when searching feeds (default: 500)' }
)

# Show a numbered table of config options with their current live values and
# let the user pick one. Returns the chosen option object or $null.
function Select-ConfigOption {
    param([string] $Verb = 'configure')
    $current = @{}
    foreach ($c in @(Get-ConfigList)) { $current[$c.Setting.ToLower()] = $c.Value }

    $items = $Script:ConfigOptions
    $cols = @(
        @{ Header = 'Option';       Expr = { $_.Name } },
        @{ Header = 'Current';      Expr = { $v = $current[$_.Name.ToLower()]; if ($v) { $v } else { '(not set)' } } },
        @{ Header = 'Type';         Expr = { $_.Type } },
        @{ Header = 'Values';       Expr = { $_.Values -join ' | ' } },
        @{ Header = 'Description';  Expr = { $_.Description } }
    )
    Show-SelectableList -Items $items -Columns $cols
    $sel = Read-Host "`n  Number of option to $Verb (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le @($items).Count) {
        return $items[[int]$sel - 1]
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

function Invoke-ConfigMenu {
    while ($true) {
        Show-Header -Title 'Configuration'
        Write-Host '   1. View configuration   (tcpkg config list)'
        Write-Host '   2. Set an option        (tcpkg config set -n <opt> [-v <value>])'
        Write-Host '   3. Unset an option      (tcpkg config unset -n <opt>)'
        Write-Host '   4. Set proxy            (tcpkg config set proxy -d <ip:port> -u <user>)'
        Write-Host '   0. Back'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' {
                Write-Host ''
                $config = Get-ConfigList
                if (@($config).Count -eq 0) {
                    Write-Host '  No configuration was returned.' -ForegroundColor Yellow
                } else {
                    Show-ConfigTable -Config $config
                }
                Wait-Continue
            }
            '2' {
                Write-Host ''
                $opt = Select-ConfigOption -Verb 'set'
                if ($opt) {
                    Write-Host ''
                    switch ($opt.Type) {
                        'toggle' {
                            Write-Host ("  '{0}' is a toggle — setting it enables it." -f $opt.Name) -ForegroundColor DarkGray
                            Write-Host ''
                            Invoke-Tcpkg -ArgList @('config','set','-n',$opt.Name,'-y')
                        }
                        'enum' {
                            Write-Host ("  Choose a value for '{0}':" -f $opt.Name) -ForegroundColor Cyan
                            $vals = @($opt.Values)
                            for ($i = 0; $i -lt $vals.Count; $i++) {
                                Write-Host ("   {0}. {1}" -f ($i + 1), $vals[$i])
                            }
                            $vs = Read-Host "`n  Choice (blank to cancel)"
                            if (-not [string]::IsNullOrWhiteSpace($vs) -and $vs -match '^\d+$' -and [int]$vs -ge 1 -and [int]$vs -le $vals.Count) {
                                $chosen = $vals[[int]$vs - 1]
                                Write-Host ''
                                Invoke-Tcpkg -ArgList @('config','set','-n',$opt.Name,'-v',$chosen,'-y')
                            } elseif (-not [string]::IsNullOrWhiteSpace($vs)) {
                                Write-Host '  Invalid selection.' -ForegroundColor Yellow
                            }
                        }
                        'number' {
                            $n = Read-Value ("Value for '{0}' (e.g. 100, 200, 500, blank to cancel):" -f $opt.Name) -CancelOnBlank
                            if ($null -eq $n) { continue }
                            if ($n -match '^\d+$') {
                                Write-Host ''
                                Invoke-Tcpkg -ArgList @('config','set','-n',$opt.Name,'-v',$n,'-y')
                            } else {
                                Write-Host '  Must be a whole number.' -ForegroundColor Yellow
                            }
                        }
                    }
                    Wait-Continue
                }
            }
            '3' {
                Write-Host ''
                $opt = Select-ConfigOption -Verb 'unset'
                if ($opt) {
                    Write-Host ''
                    Invoke-Tcpkg -ArgList @('config','unset','-n',$opt.Name,'-y')
                    Wait-Continue
                }
            }
            '4' {
                Write-Host ''
                $dest = Read-Value 'Proxy address (ip:port) (blank to cancel):' -CancelOnBlank
                if ($null -eq $dest) { continue }
                $user = Read-Value 'Proxy user (blank to cancel):' -CancelOnBlank
                if ($null -eq $user) { continue }
                Write-Host '  (tcpkg will prompt for the proxy password.)' -ForegroundColor DarkGray
                Write-Host ''
                Invoke-Tcpkg -ArgList @('config','set','proxy','-d',$dest,'-u',$user); Wait-Continue
            }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# ============================================================================
#  Main menu
# ============================================================================

function Invoke-RawCommand {
    Write-Host ''
    Write-Host '  Enter the tcpkg arguments only (no leading "tcpkg").' -ForegroundColor Cyan
    $line = Read-Host '  tcpkg'
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-Host ''
        Invoke-Tcpkg -ArgList (Split-CommandLine $line)
    }
    Wait-Continue
}

# ============================================================================
#  Package file search (local cached packages and feed packages)
# ============================================================================

# Confirmed TcPkg local package library path.
$Script:SearchRoots = @(
    'C:\ProgramData\Beckhoff\TcPkg\lib'
)

# Core search logic: open each .nupkg in $NupkgPaths as a ZIP, match entry
# names against $Term/$MatchType, display results and offer to open in Explorer.
function Search-NupkgFiles {
    param(
        [Parameter(Mandatory)] [string[]] $NupkgPaths,
        [Parameter(Mandatory)] [string]   $Term,
        [Parameter(Mandatory)] [string]   $MatchType   # '1' = partial, '2' = exact
    )
    $matchFn = if ($MatchType -eq '2') {
        { param($n) $n -eq $Term }
    } else {
        { param($n) $n -like "*$Term*" }
    }

    Write-Host ''
    Write-Host ("  Searching inside {0} package file(s)..." -f $NupkgPaths.Count) -ForegroundColor Cyan

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $hits    = New-Object System.Collections.Generic.List[pscustomobject]
    $scanned = 0
    foreach ($pkg in $NupkgPaths) {
        $scanned++
        if ($scanned % 10 -eq 0) {
            Write-Host ("  ...{0}/{1}" -f $scanned, $NupkgPaths.Count) -ForegroundColor DarkGray
        }
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($pkg)
            try {
                foreach ($entry in $zip.Entries) {
                    $entryName = [System.IO.Path]::GetFileName($entry.FullName)
                    if ([string]::IsNullOrEmpty($entryName)) { continue }
                    if (& $matchFn $entryName) {
                        $hits.Add([pscustomobject]@{
                            File      = $entryName
                            EntryPath = $entry.FullName
                            SizeKB    = [math]::Round($entry.Length / 1KB, 1)
                            Package   = [System.IO.Path]::GetFileNameWithoutExtension($pkg)
                            NupkgPath = $pkg
                        })
                    }
                }
            } finally { $zip.Dispose() }
        } catch {
            Write-Host ("  Warning: could not read '{0}': {1}" -f [System.IO.Path]::GetFileName($pkg), $_) -ForegroundColor Yellow
        }
    }

    Write-Host ''

    if ($hits.Count -eq 0) {
        Write-Host ("  No entries matching '{0}' found in {1} package(s)." -f $Term, $NupkgPaths.Count) -ForegroundColor Yellow
        Wait-Continue
        return
    }

    Write-Host ("  Found {0} match(es) across {1} package(s):" -f $hits.Count, $NupkgPaths.Count) -ForegroundColor Green
    Write-Host ''

    Write-Host '  Open the folder containing a package file in Explorer?' -ForegroundColor Cyan
    $uniquePkgs = @($hits | Select-Object -Property Package, NupkgPath -Unique)
    Show-SelectableList -Items $uniquePkgs -Columns @(
        @{ Header = 'Package';  Expr = { $_.Package } },
        @{ Header = 'Location'; Expr = { $_.NupkgPath } }
    )
    $sel = Read-Host "`n  Number to open folder (blank to skip)"
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $uniquePkgs.Count) {
        $folder = Split-Path -Parent $uniquePkgs[[int]$sel - 1].NupkgPath
        if ($Script:DryRun) {
            Write-Host "  [dry-run] explorer.exe '$folder'" -ForegroundColor DarkYellow
        } else {
            Start-Process explorer.exe -ArgumentList $folder
        }
    }

    Wait-Continue
}

function Invoke-PackageFileSearch {
    Show-Header -Title 'Search files in local packages'

    Write-Host '  Default search root:' -ForegroundColor Cyan
    $root   = $Script:SearchRoots[0]
    $exists = Test-Path $root
    $marker = if ($exists) { '  ' } else { '* (not found)' }
    Write-Host "     $marker$root" -ForegroundColor $(if ($exists) { 'White' } else { 'Yellow' })
    Write-Host ''
    $extra = Read-Value 'Additional search path (blank to skip):' -AllowEmpty
    $roots  = @($Script:SearchRoots)
    if (-not [string]::IsNullOrWhiteSpace($extra)) { $roots += $extra.Trim() }

    Write-Host ''
    $term = Read-Value 'File name to search for (partial, e.g. Tc3_Motion):' -CancelOnBlank
    if ($null -eq $term) { return }

    Write-Host ''
    Write-Host '  Match type:' -ForegroundColor Cyan
    Write-Host '   1. Partial match  (*<term>*)'
    Write-Host '   2. Exact match    (<term>)'
    Write-Host '   0. Cancel'
    Write-Host ''
    $mt = (Read-Host '  Choice').Trim()
    if ($mt -eq '0' -or [string]::IsNullOrWhiteSpace($mt)) { return }

    $nupkgs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) {
            Write-Host "  Path not found, skipping: $r" -ForegroundColor Yellow
            continue
        }
        Get-ChildItem -Path $r -Filter '*.nupkg' -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $nupkgs.Add($_.FullName) }
    }

    if ($nupkgs.Count -eq 0) {
        Write-Host '  No .nupkg files found under the search root(s).' -ForegroundColor Yellow
        Wait-Continue
        return
    }

    Search-NupkgFiles -NupkgPaths $nupkgs.ToArray() -Term $term -MatchType $mt
}

function Invoke-FeedFileSearch {
    Show-Header -Title 'Search files in feed packages'

    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH.' -ForegroundColor Red
        Wait-Continue
        return
    }

    # Step 1: find the package(s) to inspect.
    Write-Host '  First, find the package(s) to search inside.' -ForegroundColor Cyan
    Write-Host ''
    $pkgTerm = Read-Value 'Package name search term (blank to cancel):' -CancelOnBlank
    if ($null -eq $pkgTerm) { return }

    $filter = Select-FeedFilter
    if ($null -eq $filter) { return }

    Write-Host ''
    $res = Get-PackageList -ListArgs (@('list', $pkgTerm) + $filter)
    if (-not $res.Ok -or @($res.Items).Count -eq 0) {
        Write-Host "  No packages found matching '$pkgTerm'." -ForegroundColor Yellow
        Wait-Continue
        return
    }

    # Step 2: pick which package(s) to download and search.
    Write-Host ''
    Write-Host '  Which packages do you want to search inside?' -ForegroundColor Cyan
    Show-SelectableList -Items $res.Items -Columns $res.Columns
    Write-Host ''
    Write-Host '  Enter numbers separated by commas, or blank to cancel' -ForegroundColor DarkGray
    $raw = (Read-Host '  Choice').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    $selections = @()
    foreach ($part in ($raw -split ',')) {
        $n = $part.Trim()
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le @($res.Items).Count) {
            $selections += $res.Items[[int]$n - 1]
        }
    }
    if ($selections.Count -eq 0) {
        Write-Host '  No valid selections.' -ForegroundColor Yellow
        return
    }

    # Step 3: file name search term and match type.
    Write-Host ''
    $fileTerm = Read-Value 'File name to search for (partial, e.g. Tc3_Motion):' -CancelOnBlank
    if ($null -eq $fileTerm) { return }

    Write-Host ''
    Write-Host '  Match type:' -ForegroundColor Cyan
    Write-Host '   1. Partial match  (*<term>*)'
    Write-Host '   2. Exact match    (<term>)'
    Write-Host '   0. Cancel'
    Write-Host ''
    $mt = (Read-Host '  Choice').Trim()
    if ($mt -eq '0' -or [string]::IsNullOrWhiteSpace($mt)) { return }

    # Step 4: download to temp, search, always clean up.
    # Extract the feed name from $filter (@('-n','FeedName') or @() for all feeds).
    $feedArgs = @()
    if ($filter.Count -eq 2 -and $filter[0] -eq '-n') { $feedArgs = @('-n', $filter[1]) }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcPkgSearch_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        foreach ($pkg in $selections) {
            # Use lowercase ID — tcpkg download is case-sensitive on some feeds.
            $id   = $pkg.Name.ToLower()
            $spec = if ($pkg.Version) { "$id=$($pkg.Version)" } else { $id }
            Write-Host ''
            Write-Host ("  Downloading {0}..." -f $spec) -ForegroundColor Cyan
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            & $Script:TcpkgExe download $spec '--exclude-dependencies' '-y' '-o' $tempDir @feedArgs
            $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -ne 0) {
                Write-Host ("  Warning: download exited with code {0}." -f $code) -ForegroundColor Yellow
            }
        }

        # Collect all nupkgs after all downloads complete.
        # tcpkg may create sub-folders inside the output directory.
        $allNupkgs = @(Get-ChildItem -Path $tempDir -Filter '*.nupkg' -Recurse -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty FullName)

        if ($allNupkgs.Count -eq 0) {
            Write-Host ''
            Write-Host ('  No .nupkg files found in {0}' -f $tempDir) -ForegroundColor Yellow
            Write-Host '  This usually means the download failed (see the exit code above).' -ForegroundColor Yellow
            Write-Host '  Try running the equivalent command manually to see the full error:' -ForegroundColor DarkGray
            foreach ($pkg in $selections) {
                $id   = $pkg.Name.ToLower()
                $spec = if ($pkg.Version) { "$id=$($pkg.Version)" } else { $id }
                $fStr = if ($feedArgs.Count -gt 0) { " $($feedArgs -join ' ')" } else { '' }
                Write-Host ("    tcpkg download $spec --exclude-dependencies -y -o <folder>$fStr") -ForegroundColor DarkGray
            }
            Wait-Continue
            return
        }

        Search-NupkgFiles -NupkgPaths $allNupkgs -Term $fileTerm -MatchType $mt

    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-TcPkgConsole {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Note: not running as Administrator. Most tcpkg actions need elevation.' -ForegroundColor Yellow
        if (Confirm-YesNo -Prompt 'Relaunch this script as Administrator?') {
            $scriptPath = $PSCommandPath
            if ($scriptPath) {
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"" `
                    -Verb RunAs
                return
            } else {
                Write-Host 'Cannot self-elevate (script path unknown - likely pasted into console).' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    if (-not (Test-TcpkgAvailable)) {
        Write-Host 'Warning: tcpkg was not found on PATH.' -ForegroundColor Yellow
        Write-Host 'You can still explore the menus; enable dry-run to preview commands.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }

    while ($true) {
        Show-Header -Title 'Main menu'
        Write-Host '   1. Packages & workloads'
        Write-Host '   2. Sources (feeds)'
        Write-Host '   3. Configuration'
        Write-Host '   4. Tasks (automation)'
        Write-Host '   5. Search files in local packages'
        Write-Host '   6. Search files in feed packages'
        Write-Host '   7. Toggle dry-run mode'
        Write-Host '   8. Run a raw tcpkg command'
        Write-Host '   0. Exit'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' { Invoke-PackagesMenu }
            '2' { Invoke-SourcesMenu }
            '3' { Invoke-ConfigMenu }
            '4' { Invoke-TasksMenu }
            '5' { Invoke-PackageFileSearch }
            '6' { Invoke-FeedFileSearch }
            '7' {
                $Script:DryRun = -not $Script:DryRun
                $state = if ($Script:DryRun) { 'ON' } else { 'OFF' }
                Write-Host "  Dry-run is now $state." -ForegroundColor Cyan
                Start-Sleep -Milliseconds 800
            }
            '8' { Invoke-RawCommand }
            '0' { Write-Host ''; Write-Host '  Goodbye.' -ForegroundColor Cyan; return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# Entry point
Start-TcPkgConsole
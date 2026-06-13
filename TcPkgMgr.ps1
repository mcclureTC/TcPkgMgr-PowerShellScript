<#
.SYNOPSIS
    Interactive numbered-menu console and task runner for the TwinCAT
    Package Manager (tcpkg).

.DESCRIPTION
    Part 1 - a menu front end over the most common tcpkg operations
             (packages/workloads, sources/feeds, configuration).
    Part 2 - a lightweight task runner that lets you save and replay a
             named *sequence* of tcpkg commands as a "task", with optional
             {{token}} prompts and a global read-only mode.

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
$Script:ReadOnly = $true

# Exit code of the most recent tcpkg invocation (set by Invoke-Tcpkg).
$Script:LastExit = 0

# Internet access setting of the most recently selected remote target.
# Set by Invoke-PackageBrowser; read by Invoke-PackageAction -> Confirm-RemoteFeeds.
$Script:LastRemoteInternetAccess = ''

# Name of a remote target that had its internet access temporarily disabled.
# Set by Confirm-RemoteFeeds option 1; cleared after restore.
$Script:RemoteToRestore = ''

# Feed credentials collected once in batch operations for reuse across targets.
$Script:BatchFeedUser     = ''
$Script:BatchFeedPlainPwd = ''

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

# Run tcpkg with an argument array. Honours read-only.
# Shows a live elapsed-time indicator on the same line during silent periods
# so the user knows the command is still running.
function Invoke-Tcpkg {
    param(
        [Parameter(Mandatory)] [string[]] $ArgList,
        [switch] $Quiet
    )
    $display = "$Script:TcpkgExe $($ArgList -join ' ')"

    if ($Script:ReadOnly) {
        Write-Host "  [read-only] $display" -ForegroundColor DarkYellow
        $Script:LastExit = 0
        return
    }

    if (-not (Test-TcpkgAvailable)) {
        Write-Host "  tcpkg was not found on PATH. Install the TwinCAT Package Manager," -ForegroundColor Red
        Write-Host "  or enable read-only mode from the main menu to preview commands." -ForegroundColor Red
        $Script:LastExit = 1
        return
    }

    if (-not $Quiet) { Write-Host "  > $display" -ForegroundColor DarkGray }

    # Determine whether this command is likely to take time (install/upgrade/
    # repair/download). For short commands (list, show, config, etc.) the
    # spinner adds noise without benefit.
    $slowCommands = @('install','upgrade','repair','uninstall','download')
    $isSlow = $slowCommands | Where-Object { $ArgList -contains $_ }

    if (-not $isSlow) {
        # Fast path: stream output directly as before.
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & $Script:TcpkgExe @ArgList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host ([string]$_) -ForegroundColor Red }
            else { Write-Host ([string]$_) }
        }
        $Script:LastExit = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($Script:LastExit -ne 0) {
            Write-Host ("  Command exited with code {0}." -f $Script:LastExit) -ForegroundColor Red
        }
        return
    }

    # Slow path: run tcpkg in a child process. stderr is merged into stdout
    # via the argument string so only one stream needs reading, avoiding any
    # thread or deadlock issues in Windows PowerShell ISE.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName    = 'cmd.exe'
    # Wrap in cmd /c so stderr can be merged into stdout with 2>&1.
    $innerArgs = ($ArgList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"','\"') + '"' } else { $_ }
    }) -join ' '
    $tcpkgPath = (Get-Command $Script:TcpkgExe -ErrorAction SilentlyContinue).Source
    if (-not $tcpkgPath) { $tcpkgPath = $Script:TcpkgExe }
    $psi.Arguments              = "/c `"$tcpkgPath`" $innerArgs 2>&1"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false   # merged into stdout via shell redirect
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $proc      = [System.Diagnostics.Process]::Start($psi)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Start an async read of all stdout so the buffer never fills and deadlocks.
    $readTask = $proc.StandardOutput.ReadToEndAsync()

    # Show elapsed time while waiting for the process to finish.
    while (-not $proc.WaitForExit(500)) {
        Write-Progress -Activity "tcpkg $($ArgList[0])" `
                       -Status ("Elapsed: {0:mm\:ss}" -f $stopwatch.Elapsed) `
                       -SecondsRemaining -1
    }

    # Wait for the async read to complete and get all output.
    $allOutput = $readTask.Result
    Write-Progress -Activity "tcpkg $($ArgList[0])" -Completed
    $stopwatch.Stop()

    $Script:LastExit = $proc.ExitCode

    # Print each line, colouring lines that look like errors red.
    foreach ($l in ($allOutput -split "`n")) {
        $l = $l.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if ($l -match '^TcPkg \d') { continue }   # suppress version banner
        if ($l -match '^Error|^error|FAILED|failed|Exit code [^0]') {
            Write-Host $l -ForegroundColor Red
        } else {
            Write-Host $l
        }
    }

    $elapsed = $stopwatch.Elapsed
    Write-Host ("  Completed in {0:mm\:ss}." -f $elapsed) -ForegroundColor DarkGray
    if ($Script:LastExit -ne 0) {
        Write-Host ("  Command exited with code {0}." -f $Script:LastExit) -ForegroundColor Red
    }
}

function Wait-Continue {
    [void](Read-Host "`n  Press Enter to continue")
}

# Print the standard '  > tcpkg ...' command echo used throughout the script.
function Write-Command {
    param([Parameter(Mandatory)] [string[]] $ArgList)
    Write-Host ("  > {0} {1}" -f $Script:TcpkgExe, ($ArgList -join ' ')) -ForegroundColor DarkGray
}

# Parse a selection string like "1,3,5..8,11" or "1,3,5-8,11" into a flat
# list of integers within [1..$Max]. Supports both .. and - as range separators,
# individual numbers, and any combination. Returns sorted unique 1-based indices.
function Expand-SelectionRange {
    param(
        [Parameter(Mandatory)] [string] $RawInput,
        [Parameter(Mandatory)] [int]    $Max
    )
    $indices = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($part in ($RawInput -split ',')) {
        $part = $part.Trim()
        # Match N..M or N-M range patterns.
        if ($part -match '^(\d+)\.\.(\d+)$' -or $part -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $from,$to = $to,$from }   # allow reverse ranges
            for ($i = $from; $i -le $to; $i++) {
                if ($i -ge 1 -and $i -le $Max) { [void]$indices.Add($i) }
            }
        } elseif ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $Max) { [void]$indices.Add($n) }
        }
    }
    return @($indices)
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
    $mode      = if ($Script:ReadOnly) { 'READ-ONLY (no changes made)' } else { 'LIVE' }
    $modeColor = if ($Script:ReadOnly) { 'Yellow' } else { 'Green' }
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
    if ($Script:ReadOnly) {
        Write-Host ("  [read-only] {0} resolve {1} --dependency-tree" -f $Script:TcpkgExe, $PackageName) -ForegroundColor DarkYellow
        return
    }
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH.' -ForegroundColor Red
        return
    }
    Write-Command -ArgList @('resolve', $PackageName, '--dependency-tree')
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
    Write-Host '  [Feed] Retrieve the list from which feed?' -ForegroundColor Cyan
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

    Write-Command -ArgList ($ListArgs + @('--as-json'))
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
    param([string[]] $RemoteArgs = @())
    $idx = @{}
    if (-not (Test-TcpkgAvailable)) { return $idx }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    Write-Command -ArgList (@('list','-i','--as-json') + $RemoteArgs)
    $raw  = & $Script:TcpkgExe list '-i' '--as-json' @RemoteArgs 2>&1
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
        [string]   $FeedVersion = '',
        [string[]] $RemoteArgs  = @()
    )
    $target = if ($RemoteArgs.Count -ge 2) { "  Target : $($RemoteArgs[1])" } else { "  Target : local" }    $status    = Get-InstallStatus -Name $Name -InstalledIndex $InstalledIndex -FeedVersion $FeedVersion
    $instVer   = $InstalledIndex[$Name.ToLower()]
    if     ($status -eq 'not-installed')   { $statusMsg = 'not installed' }
    elseif ($status -eq 'up-to-date')      { $statusMsg = "installed  v$instVer  (up to date)" }
    elseif ($status -eq 'upgradable')      { $statusMsg = "installed  v$instVer  -> v$FeedVersion available" }
    elseif ($status -eq 'newer-than-feed') { $statusMsg = "installed  v$instVer  (feed has v$FeedVersion)" }
    else                                   { $statusMsg = $status }

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
    Write-Host $target -ForegroundColor DarkGray
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

    # Determine whether this is a local installed-packages list (-i flag present).
    # For installed lists, -r must be passed to list too (the data lives on the remote).
    # For feed lists, -r must NOT be passed to list (search the local feed index),
    # only to the action commands (install, upgrade, etc.).
    $isInstalledList = $ListArgs -contains '-i'

    # Ask which target to work against first so all subsequent commands use it.
    Write-Host ''
    $remoteTarget = Select-RemoteTarget
    $remoteArgs   = $remoteTarget.Args
    $targetLabel  = $remoteTarget.Label
    $internetAccess = $remoteTarget.InternetAccess
    $Script:LastRemoteInternetAccess = $internetAccess

    # Show internet access context so the user knows which feeds will be used.
    if ($remoteArgs.Count -ge 2) {
        if ($internetAccess -eq 'True') {
            Write-Host ("  [Target: {0}] Internet Access: True — target uses its own feeds for install/upgrade." -f $targetLabel) -ForegroundColor DarkGray
        } else {
            Write-Host ("  [Target: {0}] Internet Access: False — local feeds will be used to push packages." -f $targetLabel) -ForegroundColor DarkGray
        }
    }

    # Fetch the package list:
    #   - installed list: include -r so results come from the remote machine.
    #   - feed list: omit -r so the local feed index is searched.
    $listWithRemote = if ($isInstalledList) { $ListArgs + $remoteArgs } else { $ListArgs }
    Write-Host ''
    if ($isInstalledList) {
        Write-Host ("  [Target: {0}] Searching installed packages..." -f $targetLabel) -ForegroundColor Cyan
    } else {
        Write-Host '  [Feed] Searching feed for available packages...' -ForegroundColor Cyan
    }
    $res = Get-PackageList -ListArgs $listWithRemote
    if (-not $res.Ok) {
        Write-Host '  Package data could not be read as JSON; showing raw output.' -ForegroundColor Yellow
        Write-Host ''
        Invoke-Tcpkg -ArgList $listWithRemote
        Wait-Continue
        return
    }
    if (@($res.Items).Count -eq 0) {
        Write-Host '  No packages found.' -ForegroundColor Yellow
        Wait-Continue
        return
    }

    # Fetch the installed index from the chosen target.
    Write-Host ''
    Write-Host ("  [Target: {0}] Checking installed packages..." -f $targetLabel) -ForegroundColor Cyan
    $installed = Get-InstalledIndex -RemoteArgs $remoteArgs

    while ($true) {
        Write-Host ''
        Write-Host ("  [Feed] Available packages   |   [Target: {0}] Install status" -f $targetLabel) -ForegroundColor DarkGray
        $pkg = Select-PackageFromTable -Items $res.Items -Columns $res.Columns
        if (-not $pkg) { return }
        Write-Host ''
        $action = Select-PackageAction -Name $pkg.Name -InstalledIndex $installed `
                      -FeedVersion $pkg.Version -RemoteArgs $remoteArgs
        if ($action) {
            Write-Host ''
            Invoke-PackageAction -Action $action -Name $pkg.Name -RemoteArgs $remoteArgs
            # Restore internet access if it was temporarily set to False for local-push.
            if ($Script:RemoteToRestore) {
                Write-Host ("  [Target: {0}] Restoring Internet Access to True..." -f $Script:RemoteToRestore) -ForegroundColor Cyan
                Invoke-Tcpkg -ArgList @('remote','edit',$Script:RemoteToRestore,'--internet-access','True','-y')
                $Script:RemoteToRestore = ''
            }
            Wait-Continue
            # Refresh installed index after any mutating action.
            if ($action -in @('install','upgrade','repair','uninstall')) {
                Write-Host ("  [Target: {0}] Refreshing installed packages..." -f $targetLabel) -ForegroundColor Cyan
                $installed = Get-InstalledIndex -RemoteArgs $remoteArgs
            }
        }
    }
}

# Check feed configuration before installing on a remote target.
#
#   Internet Access = False (default): tcpkg downloads from LOCAL feeds and pushes
#                          to the remote over SSH. The remote does NOT need the
#                          feed configured. Skip the check — just install.
#
#   Internet Access = True: tcpkg tells the remote to fetch from ITS OWN feeds.
#                          The remote must have the required feed configured.
#                          If missing, show the command to add it on the remote.
#
# Returns $true to proceed with install, $false to abort.
function Confirm-RemoteFeeds {
    param(
        [Parameter(Mandatory)] [string]   $RemoteName,
        [Parameter(Mandatory)] [string]   $RequiredFeedName,
        [Parameter(Mandatory)] [string[]] $RemoteArgs,
        [Parameter(Mandatory)] [string]   $InternetAccess,
        [switch]                           $AutoPushFromLocal,
        [switch]                           $AutoAddFeed,
        [switch]                           $AutoSkipMissing
    )

    if ($InternetAccess -ne 'True') {
        # Internet Access = No: packages come from local feeds pushed over SSH.
        # Remote feed configuration is irrelevant.
        Write-Host ("  [Target: {0}] Internet Access: False — packages will be fetched from local feeds and pushed to the target." -f $RemoteName) -ForegroundColor DarkGray
        return $true
    }

    # Internet Access = True: remote fetches from its own feeds. Check if present.
    Write-Host ("  [Target: {0}] Internet Access: True — checking remote feed configuration..." -f $RemoteName) -ForegroundColor Cyan
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    Write-Command -ArgList (@('source','list','--as-json') + $RemoteArgs)
    $raw  = & $Script:TcpkgExe source list '--as-json' @RemoteArgs 2>&1
    $ErrorActionPreference = $prev

    $text = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
    $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
    $remoteFeeds = @()
    if ($s -ge 0 -and $e -gt $s) {
        try {
            $remoteFeeds = @(($text.Substring($s, $e - $s + 1) | ConvertFrom-Json) |
                             ForEach-Object { [string]$_.Name })
        } catch {}
    }

    if ($remoteFeeds -contains $RequiredFeedName) {
        Write-Host ("  Feed '{0}' is already configured on {1}." -f $RequiredFeedName, $RemoteName) -ForegroundColor Green
        return $true
    }

    # Feed is missing on the remote — offer two options, or auto-push if requested.
    $localFeed = Get-SourceList | Where-Object { $_.Name -eq $RequiredFeedName } | Select-Object -First 1
    $feedUrl   = if ($localFeed) { $localFeed.Url } else { '<feed-url>' }

    Write-Host ("  Feed '{0}' is not configured on {1}." -f $RequiredFeedName, $RemoteName) -ForegroundColor Yellow

    if ($AutoPushFromLocal) {
        Write-Host '  Auto-selecting: Push from local feeds.' -ForegroundColor Cyan
        $choice = '1'
    } elseif ($AutoAddFeed) {
        Write-Host '  Auto-selecting: Add feed remotely.' -ForegroundColor Cyan
        $choice = '2'
    } elseif ($AutoSkipMissing) {
        Write-Host ("  Skipping '{0}' — feed not configured." -f $RemoteName) -ForegroundColor Yellow
        return $false
    } else {
        Write-Host ''
        Write-Host '  How would you like to proceed?' -ForegroundColor Cyan
        Write-Host '   1. Push from local      — set Internet Access to False, install from local feeds'
        Write-Host '   2. Add feed remotely    — add the feed to the remote via tcpkg source add -r'
        Write-Host '                             (authenticated feeds: requires interactive login on remote)'
        Write-Host '   3. Manual instructions  — show the command to run on the remote machine'
        Write-Host '   0. Cancel'
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()
    }

    if ($choice -eq '1') {
        Write-Host ("  [Target: {0}] Setting Internet Access to False..." -f $RemoteName) -ForegroundColor Cyan
        Invoke-Tcpkg -ArgList @('remote','edit',$RemoteName,'--internet-access','False','-y')
        if ($Script:LastExit -ne 0) {
            Write-Host '  Failed to update remote target. Aborting.' -ForegroundColor Red
            return $false
        }
        Write-Host '  Internet Access set to False. Proceeding with local-push install.' -ForegroundColor Green
        $Script:RemoteToRestore = $RemoteName
        return $true

    } elseif ($choice -eq '2') {
        # Add the feed to the remote using ProcessStartInfo so we can pipe the
        # password to stdin without the output pipeline interfering.
        if (-not $localFeed) {
            Write-Host ("  Cannot find '{0}' in local sources — URL unknown." -f $RequiredFeedName) -ForegroundColor Red
            return $false
        }
        # Use pre-collected batch credentials if available, otherwise prompt.
        if ($AutoAddFeed -and -not [string]::IsNullOrWhiteSpace($Script:BatchFeedUser)) {
            $user     = $Script:BatchFeedUser
            $plainPwd = $Script:BatchFeedPlainPwd
        } else {
            $user = Read-Value ("  Username for '{0}' feed (blank to skip credentials):" -f $RequiredFeedName) -AllowEmpty
            $plainPwd = ''
            if (-not [string]::IsNullOrWhiteSpace($user)) {
                $securePwd = Read-Host '  Password' -AsSecureString
                $plainPwd  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                 [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
            }
        }

        $addArgs = @('source','add',
                     '-n', $RequiredFeedName,
                     '-s', $feedUrl,
                     '--priority','99',
                     '-r', $RemoteName,
                     '-y')
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $addArgs += @('-u', $user)
            if ($plainPwd) { $addArgs += '--password-stdin' }
        }

        Write-Host ''
        Write-Command -ArgList $addArgs

        # Use ProcessStartInfo so stdin (password) is independent of stdout pipe.
        $tcpkgExe = (Get-Command $Script:TcpkgExe -ErrorAction SilentlyContinue).Source
        if (-not $tcpkgExe) { $tcpkgExe = $Script:TcpkgExe }
        $argStr = ($addArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $tcpkgExe
        $psi.Arguments              = $argStr
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

        $proc    = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if ($plainPwd) {
            $proc.StandardInput.WriteLine($plainPwd)
        }
        $proc.StandardInput.Close()
        $proc.WaitForExit()

        $stdout = $outTask.Result; $stderr = $errTask.Result
        foreach ($line in (($stdout + "`n" + $stderr) -split "`n")) {
            $line = $line.TrimEnd("`r")
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^TcPkg \d') { continue }
            Write-Host $line
        }

        if ($proc.ExitCode -eq 0) {
            Write-Host ("  Feed '{0}' added to {1} successfully." -f $RequiredFeedName, $RemoteName) -ForegroundColor Green
            return $true
        } else {
            Write-Host ("  Failed to add feed (exit {0})." -f $proc.ExitCode) -ForegroundColor Red
            # tcpkg does not support --password-stdin for source add -r.
            # Automatically fall back to push-from-local.
            Write-Host '  tcpkg does not support non-interactive authenticated feed add on remote targets.' -ForegroundColor Yellow
            Write-Host '  Falling back to push-from-local for this target.' -ForegroundColor Yellow
            Invoke-Tcpkg -ArgList @('remote','edit',$RemoteName,'--internet-access','False','-y')
            if ($Script:LastExit -eq 0) {
                Write-Host '  Internet Access set to False. Proceeding with local-push install.' -ForegroundColor Green
                $Script:RemoteToRestore = $RemoteName
                return $true
            } else {
                Write-Host '  Failed to switch to local-push. Aborting.' -ForegroundColor Red
                return $false
            }
        }

    } elseif ($choice -eq '3') {
        Write-Host ''
        Write-Host '  Connect to the remote machine, open PowerShell, and run:' -ForegroundColor Cyan
        Write-Host ("    tcpkg source add -n `"$RequiredFeedName`" -s `"$feedUrl`" --priority 99 -u <username> -p <password> -y") -ForegroundColor White
        Write-Host '  Note: replace <username> and <password> with your myBeckhoff credentials. Run in PowerShell, not cmd.exe.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  After adding the feed, retry the install from this menu.' -ForegroundColor DarkGray
        return (Confirm-YesNo -Prompt 'Proceed with install now anyway?')

    } else {
        return $false
    }
}

# Run a single tcpkg action against a package name, with the usual flag prompts.
# For 'install', fetches available versions via tcpkg list -a and presents them
# as a numbered list instead of a free-text version prompt.
function Invoke-PackageAction {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $RemoteArgs = @()
    )
    switch ($Action) {
        'show' {
            Write-Host ''
            Invoke-Tcpkg -ArgList (@('show', $Name) + $RemoteArgs)
        }
        'install' {
            # Fetch available versions for this package.
            Write-Host '  Fetching available versions...' -ForegroundColor DarkGray
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            Write-Command -ArgList @('list','-a',$Name,'--as-json')
            $raw  = & $Script:TcpkgExe list '-a' $Name '--as-json' 2>&1
            $ErrorActionPreference = $prev
            $text  = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
            $si    = $text.IndexOf('['); $ei = $text.LastIndexOf(']')
            $verItems = @()
            if ($si -ge 0 -and $ei -gt $si) {
                try {
                    $json = $text.Substring($si, $ei - $si + 1) | ConvertFrom-Json
                    # Collect unique version+source pairs; keep first source seen per version.
                    $seen = @{}
                    foreach ($j in @($json | Where-Object { $null -ne $_.Version })) {
                        $v = [string]$j.Version
                        if (-not $seen.ContainsKey($v)) {
                            $seen[$v] = if ($j.Source) { [string]$j.Source } else { '' }
                        }
                    }
                    $verItems = @($seen.GetEnumerator() | ForEach-Object {
                        [pscustomobject]@{ Version = $_.Key; Source = $_.Value }
                    })
                } catch {}
            }

            $spec = $null
            if ($verItems.Count -gt 0) {
                # Sort newest first via System.Version; fall back to string sort.
                try   { $sorted = @($verItems | Sort-Object { [System.Version]$_.Version } -Descending) }
                catch { $sorted = @($verItems | Sort-Object { $_.Version } -Descending) }

                Write-Host ''
                Write-Host ("  Available versions of $Name :") -ForegroundColor Cyan
                Show-SelectableList -Items $sorted -Columns @(
                    @{ Header = 'Version'; Expr = { $_.Version } },
                    @{ Header = 'Feed';    Expr = { $_.Source } }
                )
                Write-Host ("   {0}. Latest (let tcpkg decide)" -f ($sorted.Count + 1))
                Write-Host '   0. Cancel'
                Write-Host ''
                $vs = (Read-Host '  Choice').Trim()
                if ($vs -eq '0' -or [string]::IsNullOrWhiteSpace($vs)) { return }
                if ($vs -match '^\d+$' -and [int]$vs -ge 1 -and [int]$vs -le $sorted.Count) {
                    $spec = "$($Name.ToLower())=$($sorted[[int]$vs - 1].Version)"
                } elseif ($vs -eq [string]($sorted.Count + 1)) {
                    $spec = $Name.ToLower()
                } else {
                    Write-Host '  Invalid selection.' -ForegroundColor Yellow; return
                }
            } else {
                Write-Host '  Could not retrieve version list; installing latest.' -ForegroundColor Yellow
                $spec = $Name.ToLower()
            }

            $sourceFeed = if ($spec -and $sorted.Count -gt 0) {
                $chosenVer = if ($spec -match '=(.+)$') { $Matches[1] } else { '' }
                $match = $sorted | Where-Object { $_.Version -eq $chosenVer } | Select-Object -First 1
                if ($match) { $match.Source } else { '' }
            } else { '' }

            # For remote targets with internet access, check the remote has the
            # required feed and offer to add it if missing.
            if ($RemoteArgs.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($sourceFeed)) {
                $remoteName = $RemoteArgs[1]
                $proceed = Confirm-RemoteFeeds -RemoteName $remoteName -RequiredFeedName $sourceFeed -RemoteArgs $RemoteArgs -InternetAccess $Script:LastRemoteInternetAccess
                if (-not $proceed) { return }
            }

            $a = @('install', $spec) + $RemoteArgs
            if (Confirm-YesNo -Prompt 'Unattended (-y, no prompts)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'upgrade' {
            $a = @('upgrade', $Name) + $RemoteArgs
            if (Confirm-YesNo -Prompt 'Allow downgrade (--allow-downgrade)?') { $a += '--allow-downgrade' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'repair' {
            $a = @('repair', $Name) + $RemoteArgs
            if (Confirm-YesNo -Prompt 'Include dependencies (--include-dependencies)?') { $a += '--include-dependencies' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
        'uninstall' {
            $a = @('uninstall', $Name) + $RemoteArgs
            if (Confirm-YesNo -Prompt 'Include dependencies (--include-dependencies)?') { $a += '--include-dependencies' }
            if (Confirm-YesNo -Prompt 'Unattended (-y)?') { $a += '-y' }
            Write-Host ''
            Invoke-Tcpkg -ArgList $a
        }
    }
}


# ============================================================================
#  Batch operations — run install / upgrade / uninstall on multiple targets
# ============================================================================

function Invoke-BatchOperation {
    param([string] $PresetAction = '')   # 'install', 'upgrade', or 'uninstall'
    Show-Header -Title 'Batch operation'

    # Step 1: choose action (skip if pre-set by caller).
    $action = $PresetAction.ToLower()
    if ($action -notin @('install','upgrade','uninstall')) {
        Write-Host '  Action to perform on all selected targets:' -ForegroundColor Cyan
        Write-Host '   1. Install   — tcpkg install <package> -r <target> -y'
        Write-Host '   2. Upgrade   — tcpkg upgrade <package> -r <target> -y'
        Write-Host '   3. Uninstall — tcpkg uninstall <package> -r <target> -y'
        Write-Host '   0. Cancel'
        Write-Host ''
        $actionChoice = (Read-Host '  Choice').Trim()
        if ($actionChoice -eq '0' -or [string]::IsNullOrWhiteSpace($actionChoice)) { return }
        if ($actionChoice -notin @('1','2','3')) { Write-Host '  Invalid choice.' -ForegroundColor Yellow; return }
        if     ($actionChoice -eq '1') { $action = 'install'   }
        elseif ($actionChoice -eq '2') { $action = 'upgrade'   }
        elseif ($actionChoice -eq '3') { $action = 'uninstall' }
    } else {
        Write-Host ("  Action: {0}" -f $action.ToUpper()) -ForegroundColor Cyan
    }

    # Step 2: choose the package.
    Write-Host ''
    if ($action -eq 'install') {
        # Search feed for the package.
        $term = Read-Value 'Package name search term (blank to cancel):' -CancelOnBlank
        if ($null -eq $term) { return }
            $filter = Select-FeedFilter
            if ($null -eq $filter) { return }
        Write-Host ''
        $res = Get-PackageList -ListArgs (@('list', $term) + $filter)
            if (-not $res.Ok -or @($res.Items).Count -eq 0) {
            Write-Host "  No packages found matching '$term'." -ForegroundColor Yellow
            Wait-Continue; return
        }
        Write-Host ''
        Write-Host '  Select the package to install:' -ForegroundColor Cyan
        Show-SelectableList -Items $res.Items -Columns $res.Columns
        $pkgSel = Read-Host "`n  Package number (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($pkgSel)) { return }
        if ($pkgSel -notmatch '^\d+$' -or [int]$pkgSel -lt 1 -or [int]$pkgSel -gt @($res.Items).Count) {
            Write-Host '  Invalid selection.' -ForegroundColor Yellow; return
        }
        $pkg = $res.Items[[int]$pkgSel - 1]
    
        # Pick version.
        Write-Host ''
        Write-Host '  Fetching available versions...' -ForegroundColor DarkGray
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        Write-Command -ArgList @('list','-a',$pkg.Name,'--as-json')
        $rawV = & $Script:TcpkgExe list '-a' $pkg.Name '--as-json' 2>&1
        $ErrorActionPreference = $prev
        $textV = (@($rawV) | ForEach-Object { [string]$_ }) -join "`n"
        $si = $textV.IndexOf('['); $ei = $textV.LastIndexOf(']')
        $verItems = @()
        if ($si -ge 0 -and $ei -gt $si) {
            try {
                $json = $textV.Substring($si, $ei - $si + 1) | ConvertFrom-Json
                $seen = @{}
                foreach ($j in @($json | Where-Object { $null -ne $_.Version })) {
                    $v = [string]$j.Version
                    if (-not $seen.ContainsKey($v)) { $seen[$v] = if ($j.Source) { [string]$j.Source } else { '' } }
                }
                $verItems = @($seen.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Version = $_.Key; Source = $_.Value } })
            } catch {}
        }
        if ($verItems.Count -gt 0) {
            try   { $sortedV = @($verItems | Sort-Object { [System.Version]$_.Version } -Descending) }
            catch { $sortedV = @($verItems | Sort-Object { $_.Version } -Descending) }
            Write-Host ''
            Write-Host ("  Available versions of $($pkg.Name) :") -ForegroundColor Cyan
            Show-SelectableList -Items $sortedV -Columns @(
                @{ Header = 'Version'; Expr = { $_.Version } },
                @{ Header = 'Feed';    Expr = { $_.Source } }
            )
            Write-Host ("   {0}. Latest (let tcpkg decide)" -f ($sortedV.Count + 1))
            Write-Host '   0. Cancel'
            Write-Host ''
            $vs = (Read-Host '  Choice').Trim()
            if ($vs -eq '0' -or [string]::IsNullOrWhiteSpace($vs)) { return }
            if ($vs -match '^\d+$' -and [int]$vs -ge 1 -and [int]$vs -le $sortedV.Count) {
                $packageSpec  = "$($pkg.Name.ToLower())=$($sortedV[[int]$vs - 1].Version)"
                $batchFeedName = $sortedV[[int]$vs - 1].Source
            } elseif ($vs -eq [string]($sortedV.Count + 1)) {
                $packageSpec  = $pkg.Name.ToLower()
                $batchFeedName = ''
            } else { Write-Host '  Invalid selection.' -ForegroundColor Yellow; return }
        } else {
            Write-Host '  Could not retrieve versions; using latest.' -ForegroundColor Yellow
            $packageSpec   = $pkg.Name.ToLower()
            $batchFeedName = ''
        }
    } else {
        $batchFeedName = ''
        if ($action -eq 'uninstall') {
            # Search installed packages on a representative remote target.
            Write-Host '  Select a remote target to check installed packages on:' -ForegroundColor Cyan
            $remoteList = @(Get-RemoteList)
            if ($remoteList.Count -gt 0) {
                Show-SelectableList -Items $remoteList -Columns @(
                    @{ Header = 'Name'; Expr = { $_.Name } },
                    @{ Header = 'Host'; Expr = { $_.Host } }
                )
                $rSel = Read-Host "`n  Target number (blank = search local)"
                if ($rSel -match '^\d+$' -and [int]$rSel -ge 1 -and [int]$rSel -le $remoteList.Count) {
                    $searchRemoteArgs = @('-r', $remoteList[[int]$rSel - 1].Name)
                    Write-Host ("  Searching installed packages on '{0}'..." -f $remoteList[[int]$rSel - 1].Name) -ForegroundColor DarkGray
                } else {
                    $searchRemoteArgs = @()
                    Write-Host '  Searching locally installed packages...' -ForegroundColor DarkGray
                }
            } else {
                $searchRemoteArgs = @()
                Write-Host '  No remotes configured; searching locally installed packages...' -ForegroundColor DarkGray
            }

            $term = Read-Value 'Search term (blank = list all installed):' -AllowEmpty
            $listArgs = if ([string]::IsNullOrWhiteSpace($term)) {
                @('list','-i') + $searchRemoteArgs
            } else {
                @('list', $term, '-i') + $searchRemoteArgs
            }
            $res = Get-PackageList -ListArgs $listArgs
            if ($res.Ok -and @($res.Items).Count -gt 0) {
                Write-Host ''
                Write-Host '  Select the package to uninstall:' -ForegroundColor Cyan
                Show-SelectableList -Items $res.Items -Columns $res.Columns
                $pkgSel = Read-Host "`n  Package number (blank to cancel)"
                if ([string]::IsNullOrWhiteSpace($pkgSel)) { return }
                if ($pkgSel -notmatch '^\d+$' -or [int]$pkgSel -lt 1 -or [int]$pkgSel -gt @($res.Items).Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Yellow; return
                }
                $packageSpec = $res.Items[[int]$pkgSel - 1].Name.ToLower()
            } else {
                Write-Host '  No installed packages found; enter the name manually.' -ForegroundColor Yellow
                $packageSpec = Read-Value 'Package name (blank to cancel):' -CancelOnBlank
                if ($null -eq $packageSpec) { return }
                $packageSpec = $packageSpec.ToLower()
            }
        } elseif ($action -eq 'upgrade') {
            # Search feed for the package to upgrade.
            $term = Read-Value 'Package name search term (blank to cancel):' -CancelOnBlank
            if ($null -eq $term) { return }
            $filter = Select-FeedFilter
            if ($null -eq $filter) { return }
            Write-Host ''
            $res = Get-PackageList -ListArgs (@('list', $term) + $filter)
            if ($res.Ok -and @($res.Items).Count -gt 0) {
                Write-Host ''
                Write-Host '  Select the package to upgrade:' -ForegroundColor Cyan
                Show-SelectableList -Items $res.Items -Columns $res.Columns
                $pkgSel = Read-Host "`n  Package number (blank to cancel)"
                if ([string]::IsNullOrWhiteSpace($pkgSel)) { return }
                if ($pkgSel -notmatch '^\d+$' -or [int]$pkgSel -lt 1 -or [int]$pkgSel -gt @($res.Items).Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Yellow; return
                }
                $packageSpec = $res.Items[[int]$pkgSel - 1].Name.ToLower()
            } else {
                Write-Host '  No packages found; enter the name manually.' -ForegroundColor Yellow
                $packageSpec = Read-Value 'Package name (blank to cancel):' -CancelOnBlank
                if ($null -eq $packageSpec) { return }
                $packageSpec = $packageSpec.ToLower()
            }
        }
    }

    # Step 3: select target machines (multi-select).
    Write-Host ''
    $remotes = @(Get-RemoteList)
    if ($remotes.Count -eq 0) {
        Write-Host '  No remote targets are configured.' -ForegroundColor Yellow
        Wait-Continue; return
    }
    Write-Host '  Select target machines (e.g. 1,3,5..8 or 1,3,5-8 — numbers and ranges, blank to cancel):' -ForegroundColor Cyan
    Show-SelectableList -Items $remotes -Columns @(
        @{ Header = 'Name';            Expr = { $_.Name } },
        @{ Header = 'Host';            Expr = { $_.Host } },
        @{ Header = 'Internet Access'; Expr = { $_.InternetAccess } }
    )
    Write-Host ''
    $raw = (Read-Host '  Targets').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    $targets = @()
    foreach ($idx in (Expand-SelectionRange -RawInput $raw -Max $remotes.Count)) {
        $targets += $remotes[$idx - 1]
    }
    if ($targets.Count -eq 0) { Write-Host '  No valid targets selected.' -ForegroundColor Yellow; return }

    # Step 4: confirm and choose execution mode.
    Write-Host ''
    Write-Host '  Summary:' -ForegroundColor Cyan
    Write-Host ("   Action  : {0}" -f $action.ToUpper())
    Write-Host ("   Package : {0}" -f $packageSpec)
    Write-Host ("   Targets : {0}" -f (($targets | ForEach-Object { $_.Name }) -join ', '))
    Write-Host ''
    Write-Host '  Execution mode:' -ForegroundColor Cyan
    Write-Host '   1. Sequential — one target at a time (only supported mode)'
    Write-Host '      Note: tcpkg holds a system-wide lock for the full duration'
    Write-Host '      of each command. Parallel execution from one machine is not'
    Write-Host '      possible regardless of Internet Access or feed configuration.'
    Write-Host '   0. Cancel'
    Write-Host ''
    $modeChoice = (Read-Host '  Choice').Trim()
    if ($modeChoice -eq '0' -or [string]::IsNullOrWhiteSpace($modeChoice)) { return }
    $parallel = $false   # always sequential

    if ($Script:ReadOnly) {
        Write-Host ''
        Write-Host '  READ-ONLY MODE IS ON — commands will be shown but not executed.' -ForegroundColor Yellow
        Write-Host '  Select option 8 from the main menu to turn read-only mode off.' -ForegroundColor Yellow
    }

    # For installs, ask once how to handle missing feeds on remote targets.
    $batchFeedStrategy   = 'push'   # default
    $batchFeedUser       = ''
    $batchFeedPlainPwd   = ''
    if ($action -eq 'install' -and -not [string]::IsNullOrWhiteSpace($batchFeedName)) {
        Write-Host ''
        Write-Host '  If a required feed is not configured on a remote target:' -ForegroundColor Cyan
        Write-Host '   1. Push from local  — set Internet Access to False, push via local feeds'
        Write-Host '   2. Add feed         — add the feed via tcpkg source add -r'
        Write-Host '                         (unauthenticated feeds only; authenticated feeds'
        Write-Host '                          will fall back to push-from-local automatically)'
        Write-Host '   3. Skip target      — skip targets that are missing the feed'
        Write-Host ''
        $fsChoice = (Read-Host '  Feed strategy (blank = Push from local)').Trim()
        if     ($fsChoice -eq '2') { $batchFeedStrategy = 'add' }
        elseif ($fsChoice -eq '3') { $batchFeedStrategy = 'skip' }
        else                        { $batchFeedStrategy = 'push' }

        if ($batchFeedStrategy -eq 'add') {
            Write-Host ''
            Write-Host ("  Credentials for the '{0}' feed (collected once for all targets):" -f $batchFeedName) -ForegroundColor Cyan
            $batchFeedUser = Read-Value '  Username (blank = no credentials):' -AllowEmpty
            if (-not [string]::IsNullOrWhiteSpace($batchFeedUser)) {
                $securePwd       = Read-Host '  Password' -AsSecureString
                $batchFeedPlainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
            }
            # Store for use in Confirm-RemoteFeeds via script-scope variables.
            $Script:BatchFeedUser     = $batchFeedUser
            $Script:BatchFeedPlainPwd = $batchFeedPlainPwd
        }
    }

    # Pre-process all targets: handle feed checks and internet-access toggles
    # before launching any processes, since those steps are interactive.
    Write-Host ''
    $plan = @()
    foreach ($target in $targets) {
        $proceed   = $true
        $argList   = @($action, $packageSpec, '-r', $target.Name, '-y')
        $restoreIA = $false

        if ($action -eq 'install' -and $target.InternetAccess -eq 'True') {
            if (-not [string]::IsNullOrWhiteSpace($batchFeedName)) {
                if ($batchFeedStrategy -eq 'push') {
                    $proceed = Confirm-RemoteFeeds `
                        -RemoteName       $target.Name `
                        -RequiredFeedName $batchFeedName `
                        -RemoteArgs       @('-r', $target.Name) `
                        -InternetAccess   $target.InternetAccess `
                        -AutoPushFromLocal
                } elseif ($batchFeedStrategy -eq 'add') {
                    $proceed = Confirm-RemoteFeeds `
                        -RemoteName       $target.Name `
                        -RequiredFeedName $batchFeedName `
                        -RemoteArgs       @('-r', $target.Name) `
                        -InternetAccess   $target.InternetAccess `
                        -AutoAddFeed
                } else {
                    # 'skip' — check if feed is present; skip target if not.
                    $proceed = Confirm-RemoteFeeds `
                        -RemoteName       $target.Name `
                        -RequiredFeedName $batchFeedName `
                        -RemoteArgs       @('-r', $target.Name) `
                        -InternetAccess   $target.InternetAccess `
                        -AutoSkipMissing
                }
                if ($Script:RemoteToRestore -eq $target.Name) {
                    $restoreIA = $true
                    $Script:RemoteToRestore = ''
                }
            }
        }

        $plan += [pscustomobject]@{
            Target    = $target
            ArgList   = $argList
            Proceed   = $proceed
            RestoreIA = $restoreIA
        }
    }

    $results = @()

    if ($parallel) {
        # tcpkg holds a system-wide lock for the entire duration of every command,
        # including the compatibility check phase that runs before any download.
        # This means no two tcpkg processes can run simultaneously on this machine
        # regardless of Internet Access setting or feed configuration.
        # Parallel mode is therefore not supported — always use sequential.
        Write-Host ''
        Write-Host '  Note: tcpkg holds a system-wide lock for the full duration of each' -ForegroundColor Yellow
        Write-Host '  command. Parallel execution is not possible from one machine.' -ForegroundColor Yellow
        Write-Host '  Switching to sequential mode.' -ForegroundColor Yellow
        $parallel = $false
    }

    # ── Sequential mode ────────────────────────────────────────────────────
    foreach ($item in $plan) {
        $num   = $results.Count + 1
        $tName = $item.Target.Name
        Write-Host ('  ── [{0}/{1}] {2} on {3} ──' -f $num, $plan.Count, $action.ToUpper(), $tName) -ForegroundColor Cyan

        $exitCode = 0
        if ($item.Proceed) {
            Invoke-Tcpkg -ArgList $item.ArgList
            $exitCode = $Script:LastExit

            if ($item.RestoreIA) {
                Write-Host ("  [Target: {0}] Restoring Internet Access to True..." -f $tName) -ForegroundColor Cyan
                Invoke-Tcpkg -ArgList @('remote','edit',$tName,'--internet-access','True','-y')
            }
        } else {
            $exitCode = -1
        }

        $status = if (-not $item.Proceed) { 'Skipped' } elseif ($exitCode -eq 0) { 'OK' } else { "Failed ($exitCode)" }
        $color  = if ($status -eq 'OK') { 'Green' } elseif ($status -eq 'Skipped') { 'Yellow' } else { 'Red' }
        Write-Host ("  Result: {0}" -f $status) -ForegroundColor $color
        Write-Host ''
        $results += [pscustomobject]@{ Target = $tName; Package = $packageSpec; Status = $status }
    }

    # Summary table.
    Write-Host '  Batch complete:' -ForegroundColor Cyan
    Show-SelectableList -Items $results -Columns @(
        @{ Header = 'Target';  Expr = { $_.Target } },
        @{ Header = 'Package'; Expr = { $_.Package } },
        @{ Header = 'Status';  Expr = { $_.Status } }
    ) -NoNumber
    Wait-Continue
}

function Invoke-PackagesMenu {
    while ($true) {
        Show-Header -Title 'Packages & workloads'
        Write-Host '   1. List available packages        (tcpkg list)'
        Write-Host '   2. Search / list installed         (tcpkg list -i [<term>])'
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
        Write-Host '  13. Batch operation on targets     (install/upgrade/uninstall on multiple PCs)'
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
            '2' {
                Write-Host ''
                $term = Read-Value 'Search term (blank = list all installed):' -AllowEmpty
                # tcpkg list expects: list [<term>] -i [--exact]
                # The positional <package> argument must come before the flags.
                if (-not [string]::IsNullOrWhiteSpace($term)) {
                    Write-Host ''
                    Write-Host '  Match type:' -ForegroundColor Cyan
                    Write-Host '   1. Partial match  (*<term>*)'
                    Write-Host '   2. Exact match    (--exact)'
                    Write-Host '   0. Cancel'
                    Write-Host ''
                    $mt = (Read-Host '  Choice').Trim()
                    if ($mt -eq '0' -or [string]::IsNullOrWhiteSpace($mt)) { continue }
                    $listArgs = @('list', $term, '-i')
                    if ($mt -eq '2') { $listArgs += '--exact' }
                } else {
                    $listArgs = @('list','-i')
                }
                Write-Host ''
                Invoke-PackageBrowser -ListArgs $listArgs
            }
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
                Write-Host '   1. Install on one target    (choose from feed)'
                Write-Host '   2. Install on multiple targets  (batch operation)'
                Write-Host '   0. Back'
                Write-Host ''
                $sub = (Read-Host '  Choice').Trim()
                if ($sub -eq '2') {
                    Write-Host ''
                    Invoke-BatchOperation -PresetAction 'install'
                } elseif ($sub -eq '1') {
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
            }
            '9' {
                Write-Host ''
                Write-Host '   1. Choose from upgradable packages on one target  (tcpkg list -o)'
                Write-Host '   2. Upgrade on multiple targets                    (batch operation)'
                Write-Host '   3. Upgrade ALL packages on one target             (tcpkg upgrade all)'
                Write-Host '   0. Back'
                Write-Host ''
                $sub = (Read-Host '  Choice').Trim()
                if ($sub -eq '1') {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs @('list','-o')
                } elseif ($sub -eq '2') {
                    Write-Host ''
                    Invoke-BatchOperation -PresetAction 'upgrade'
                } elseif ($sub -eq '3') {
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
                Write-Host '   1. Choose from installed packages on one target  (tcpkg list -i)'
                Write-Host '   2. Uninstall on multiple targets                 (batch operation)'
                Write-Host '   3. Uninstall ALL packages on one target          (tcpkg uninstall all)'
                Write-Host '   0. Back'
                Write-Host ''
                $sub = (Read-Host '  Choice').Trim()
                if ($sub -eq '1') {
                    Write-Host ''
                    Invoke-PackageBrowser -ListArgs @('list','-i')
                } elseif ($sub -eq '2') {
                    Write-Host ''
                    Invoke-BatchOperation -PresetAction 'uninstall'
                } elseif ($sub -eq '3') {
                    Write-Host ''
                    Write-Host '  This removes ALL TwinCAT packages from the selected machine.' -ForegroundColor Red
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
            '13' { Write-Host ''; Invoke-BatchOperation }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}
# ============================================================================

# Run `tcpkg source list` and parse it into objects:
#   Name, Priority, Enabled, Auth, BypassProxy, Prereleases, Take, Url
# Prefers `--as-json` (robust against display-format changes); falls back to
# parsing the plain-text output if the JSON can't be read. Read-only, so it
# runs even in read-only mode (we need real data to plan).
function Get-SourceList {
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH; cannot read sources.' -ForegroundColor Red
        return @()
    }

    # --- Preferred path: JSON ---
    Write-Command -ArgList @('source','list','--as-json')
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
    Write-Command -ArgList @('source','list')
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
        if ($Script:LastExit -ne 0 -and -not $Script:ReadOnly) {
            Write-Host "  Failed to park '$($c.Name)' (exit $Script:LastExit). Aborting before final pass." -ForegroundColor Red
            Write-Host '  Some sources may be left at a temporary priority; re-run to finish.' -ForegroundColor Yellow
            return
        }
        $k++
    }

    Write-Host "`n  Pass 2/2 - assigning final priorities..." -ForegroundColor DarkGray
    foreach ($c in $changes) {
        Invoke-Tcpkg -ArgList @('source', 'edit', $c.Name, "--priority=$($c.To)", '-y')
        if ($Script:LastExit -ne 0 -and -not $Script:ReadOnly) {
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
# Read-only, so it runs even in read-only mode.
function Get-ConfigList {
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH; cannot read configuration.' -ForegroundColor Red
        return @()
    }
    Write-Command -ArgList @('config','list')
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


# ============================================================================
#  Remote targets menu
# ============================================================================

# Run `tcpkg remote list --as-json` and parse into objects.
# Read-only; runs even in read-only mode.
function Get-RemoteList {
    if (-not (Test-TcpkgAvailable)) {
        Write-Host '  tcpkg was not found on PATH; cannot read remote targets.' -ForegroundColor Red
        return @()
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    Write-Command -ArgList @('remote','list','--as-json')
    $raw  = & $Script:TcpkgExe remote list '--as-json' 2>&1
    $ErrorActionPreference = $prev
    $text = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
    $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
    if ($s -ge 0 -and $e -gt $s) {
        try {
            $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
            return @($json | ForEach-Object {
                [pscustomobject]@{
                    Name           = [string]$_.Name
                    Host           = [string]$_.Host
                    Port           = if ($_.Port)          { [string]$_.Port }          else { '22' }
                    User           = [string]$_.User
                    InternetAccess = if ($_.InternetAccess -eq $true) { 'True' } else { 'False' }
                }
            })
        } catch {}
    }
    # Fallback: plain-text parse for older tcpkg builds without --as-json on remote list.
    $result = foreach ($line in $raw) {
        $text2 = [string]$line
        if ($text2 -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s+(\S+)') {
            [pscustomobject]@{
                Name           = $Matches[1]; Host = $Matches[2]
                Port           = $Matches[3]; User = $Matches[4]
                InternetAccess = ''
            }
        }
    }
    return @($result)
}

# Show a numbered table of remotes and return the chosen object (or $null).
function Select-Remote {
    param([string]$Verb = 'select', $Remotes)
    if (-not $Remotes) { $Remotes = Get-RemoteList }
    $list = @($Remotes)
    if ($list.Count -eq 0) {
        Write-Host '  No remote targets are configured.' -ForegroundColor Yellow
        return $null
    }
    Show-SelectableList -Items $list -Columns @(
        @{ Header = 'Name';            Expr = { $_.Name } },
        @{ Header = 'Host';            Expr = { $_.Host } },
        @{ Header = 'Port';            Expr = { $_.Port };            Align = 'Right' },
        @{ Header = 'User';            Expr = { $_.User } },
        @{ Header = 'Internet Access'; Expr = { $_.InternetAccess } }
    )
    $sel = Read-Host "`n  Number of target to $Verb (blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $list.Count) {
        return $list[[int]$sel - 1]
    }
    Write-Host '  Invalid selection.' -ForegroundColor Yellow
    return $null
}

# Optional remote picker used inside package actions. Returns a hashtable:
#   Args           - @() for local, @('-r','name') for remote
#   InternetAccess - 'True'/'False'/'' for local
#   Label          - display name of the target
function Select-RemoteTarget {
    $remotes = Get-RemoteList
    $items   = @([pscustomobject]@{ Label = 'Local (this machine)'; Name = ''; InternetAccess = '' }) +
               @($remotes | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Name = $_.Name; InternetAccess = $_.InternetAccess } })
    Write-Host '  [Target] Run package actions on which machine?' -ForegroundColor Cyan
    Show-SelectableList -Items $items -Columns @(
        @{ Header = 'Target';          Expr = { $_.Label } },
        @{ Header = 'Internet Access'; Expr = { $_.InternetAccess } }
    )
    $sel = Read-Host "`n  Choice (blank = Local)"
    if ([string]::IsNullOrWhiteSpace($sel) -or $sel -eq '1') {
        return @{ Args = @(); Label = 'local'; InternetAccess = '' }
    }
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $items.Count) {
        $item = $items[[int]$sel - 1]
        if ([string]::IsNullOrEmpty($item.Name)) {
            return @{ Args = @(); Label = 'local'; InternetAccess = '' }
        }
        return @{ Args = @('-r', $item.Name); Label = $item.Name; InternetAccess = $item.InternetAccess }
    }
    Write-Host '  Invalid selection; running locally.' -ForegroundColor Yellow
    return @{ Args = @(); Label = 'local'; InternetAccess = '' }
}


# Export the current remote target list to a CSV file.
# CSV columns: Name, Host, Port, User, InternetAccess
# Passwords are NOT exported for security reasons.
function Export-RemoteTargets {
    $remotes = Get-RemoteList
    if (@($remotes).Count -eq 0) {
        Write-Host '  No remote targets to export.' -ForegroundColor Yellow
        return
    }

    $defaultPath = Join-Path (Split-Path $PSCommandPath -Parent) 'TcPkgRemotes.csv'
    $path = Read-Value ("CSV file path (blank = {0}):" -f $defaultPath) -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $defaultPath }

    Write-Host ''
    Write-Host '  Include passwords in the export?' -ForegroundColor Cyan
    Write-Host '   1. No  — passwords omitted (recommended)'
    Write-Host '   2. Yes — passwords stored in plain text (use with caution)'
    Write-Host ''
    $pwChoice = (Read-Host '  Choice').Trim()

    $plainPwd = $null
    if ($pwChoice -eq '2') {
        Write-Host ''
        Write-Host '  Warning: passwords will be stored as plain text in the CSV.' -ForegroundColor Yellow
        Write-Host '  Ensure the file is kept secure and not shared publicly.' -ForegroundColor Yellow
        Write-Host ''
        $securePwd = Read-Host '  Password to embed in CSV (single password for all targets)' -AsSecureString
        $plainPwd  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
    }

    try {
        $rows = $remotes | ForEach-Object {
            $obj = [ordered]@{
                Name           = $_.Name
                Host           = $_.Host
                Port           = $_.Port
                User           = $_.User
                InternetAccess = $_.InternetAccess
                Password       = if ($plainPwd) { $plainPwd } else { '' }
            }
            [pscustomobject]$obj
        }
        $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        Write-Host ("  Exported {0} target(s) to:" -f @($remotes).Count) -ForegroundColor Green
        Write-Host "    $path" -ForegroundColor White
        if (-not $plainPwd) {
            Write-Host '  Password column is empty — you will be prompted during import.' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("  Failed to export: {0}" -f $_) -ForegroundColor Red
    }
}

# Import remote targets from a CSV file.
# Required CSV columns: Name, Host, Port, User, InternetAccess
# Optional CSV column:  Password (plain text)
# Password strategy for new targets is chosen once before processing starts.
function Import-RemoteTargets {
    $defaultPath = Join-Path (Split-Path $PSCommandPath -Parent) 'TcPkgRemotes.csv'
    $path = Read-Value ("CSV file path (blank = {0}):" -f $defaultPath) -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $defaultPath }

    if (-not (Test-Path $path)) {
        Write-Host "  File not found: $path" -ForegroundColor Red
        return
    }

    try {
        $rows = @(Import-Csv -Path $path -Encoding UTF8)
    } catch {
        Write-Host ("  Failed to read CSV: {0}" -f $_) -ForegroundColor Red
        return
    }

    if ($rows.Count -eq 0) {
        Write-Host '  CSV file is empty.' -ForegroundColor Yellow
        return
    }

    # Validate required columns.
    $required = @('Name','Host','Port','User','InternetAccess')
    $missing  = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
    if ($missing) {
        Write-Host ("  CSV is missing required columns: {0}" -f ($missing -join ', ')) -ForegroundColor Red
        Write-Host '  Expected columns: Name, Host, Port, User, InternetAccess, Password (optional)' -ForegroundColor DarkGray
        return
    }

    $hasPwdColumn = 'Password' -in $rows[0].PSObject.Properties.Name

    Write-Host ("  Found {0} target(s) in CSV." -f $rows.Count) -ForegroundColor Cyan
    Write-Host ''

    # Count how many are new (need a password) vs existing (no password needed).
    $existingMap = @{}
    foreach ($e in Get-RemoteList) { $existingMap[$e.Name] = $e }
    $newCount = @($rows | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Name) -and
        -not $existingMap.ContainsKey($_.Name.Trim())
    }).Count

    # Choose password strategy for new targets.
    $pwStrategy = 'per-target'   # default
    $sharedPwd  = $null

    if ($newCount -gt 0) {
        Write-Host ("  {0} new target(s) will be added and require an SSH password." -f $newCount) -ForegroundColor Cyan
        Write-Host ''
        if ($hasPwdColumn) {
            Write-Host '  Password source:'
            Write-Host '   1. Use Password column from CSV'
            Write-Host '   2. Enter one shared password for all new targets'
            Write-Host '   3. Prompt individually for each new target'
        } else {
            Write-Host '  Password source (no Password column in CSV):'
            Write-Host '   1. Enter one shared password for all new targets'
            Write-Host '   2. Prompt individually for each new target'
        }
        Write-Host ''
        $pwChoice = (Read-Host '  Choice').Trim()

        if ($hasPwdColumn) {
            switch ($pwChoice) {
                '1' { $pwStrategy = 'csv' }
                '2' {
                    $pwStrategy = 'shared'
                    $secure = Read-Host '  Shared SSH password' -AsSecureString
                    $sharedPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
                }
                default { $pwStrategy = 'per-target' }
            }
        } else {
            switch ($pwChoice) {
                '1' {
                    $pwStrategy = 'shared'
                    $secure = Read-Host '  Shared SSH password' -AsSecureString
                    $sharedPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
                }
                default { $pwStrategy = 'per-target' }
            }
        }
        Write-Host ''
    }

    $added = 0; $skipped = 0; $updated = 0; $failed = 0
    $skipUnreachable = Confirm-YesNo -Prompt 'Automatically skip targets that cannot be reached on their SSH port?'
    Write-Host ''

    foreach ($row in $rows) {
        $name = $row.Name.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        if ($existingMap.ContainsKey($name)) {
            $current   = $existingMap[$name]
            $csvAccess = $row.InternetAccess.Trim()
            $csvHost   = $row.Host.Trim()
            $csvPort   = $row.Port.Trim()

            # Collect only the properties that have actually changed.
            $editArgs = @('remote','edit',$name)
            $changes  = @()
            if ($csvHost -and $csvHost -ne $current.Host) {
                $editArgs += @('--host',$csvHost)
                $changes  += ("Host: {0} -> {1}" -f $current.Host, $csvHost)
            }
            if ($csvPort -and $csvPort -ne $current.Port) {
                $editArgs += @('--port',$csvPort)
                $changes  += ("Port: {0} -> {1}" -f $current.Port, $csvPort)
            }
            if ($csvAccess -and $csvAccess -ne $current.InternetAccess) {
                $editArgs += @('--internet-access',$csvAccess)
                $changes  += ("Internet Access: {0} -> {1}" -f $current.InternetAccess, $csvAccess)
            }

            if ($changes.Count -eq 0) {
                Write-Host ("  Skipping '{0}' — already configured and up to date." -f $name) -ForegroundColor DarkGray
                $skipped++
            } else {
                $editArgs += '-y'
                Write-Host ("  Updating '{0}':" -f $name) -ForegroundColor Cyan
                foreach ($c in $changes) { Write-Host "    $c" -ForegroundColor DarkGray }
                Write-Command -ArgList $editArgs
                if ($Script:ReadOnly) {
                    Write-Host '  [read-only] command not executed.' -ForegroundColor DarkYellow
                    $updated++
                } else {
                    Invoke-Tcpkg -ArgList $editArgs
                    if ($Script:LastExit -eq 0) {
                        Write-Host ("  '{0}' updated successfully." -f $name) -ForegroundColor Green
                        $updated++
                    } else {
                        Write-Host ("  Failed to update '{0}'." -f $name) -ForegroundColor Red
                        $failed++
                    }
                }
            }
            continue
        }

        # New target — resolve the password.
        if ($pwStrategy -eq 'csv') {
            $plainPwd = $row.Password
        } elseif ($pwStrategy -eq 'shared') {
            $plainPwd = $sharedPwd
        } else {
            $sec = Read-Host ("  SSH password for {0}@{1}" -f $row.User.Trim(), $row.Host.Trim()) -AsSecureString
            $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }

        if ([string]::IsNullOrEmpty($plainPwd)) {
            Write-Host ("  Skipping '{0}' — no password available." -f $name) -ForegroundColor Yellow
            $failed++
            continue
        }

        # Pre-check: test TCP reachability on the SSH port before attempting
        # remote add, which always validates the SSH connection and fails with
        # exit 1201 if the host is unreachable.
        $portNum = [int]($row.Port.Trim())
        Write-Host ("  Checking connectivity to {0}:{1}..." -f $row.Host.Trim(), $portNum) -ForegroundColor DarkGray
        $connected = $false
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connected = $tcp.ConnectAsync($row.Host.Trim(), $portNum).Wait(2000)
            $tcp.Dispose()
        } catch { $connected = $false }

        if (-not $connected) {
            Write-Host ("  Warning: '{0}' ({1}:{2}) is not reachable on port {2}." -f $name, $row.Host.Trim(), $portNum) -ForegroundColor Yellow
            if ($skipUnreachable -or -not (Confirm-YesNo -Prompt "Attempt to add '$name' anyway?")) {
                Write-Host ("  Skipping '{0}'." -f $name) -ForegroundColor DarkGray
                $skipped++
                continue
            }
        }

        Write-Host ("  Adding '{0}' ({1}@{2}:{3})..." -f $name, $row.User.Trim(), $row.Host.Trim(), $row.Port.Trim()) -ForegroundColor Cyan

        $argList = @('remote','add',
                     '-n',    $name,
                     '--host', $row.Host.Trim(),
                     '--port', $row.Port.Trim(),
                     '-u',    $row.User.Trim())
        if ($row.InternetAccess.Trim() -eq 'True') { $argList += '--internet-access','True' }
        $argList += '--password-stdin','-y'

        Write-Command -ArgList $argList
        if ($Script:ReadOnly) {
            Write-Host '  [read-only] command not executed.' -ForegroundColor DarkYellow
            $added++
        } else {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            $plainPwd | & $Script:TcpkgExe @argList 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host ([string]$_) -ForegroundColor Red }
                else { Write-Host ([string]$_) }
            }
            $code = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($code -eq 0) {
                Write-Host ("  '{0}' added successfully." -f $name) -ForegroundColor Green
                $added++
            } else {
                Write-Host ("  Failed to add '{0}' (exit {1})." -f $name, $code) -ForegroundColor Red
                $failed++
            }
        }
        Write-Host ''
    }

    Write-Host ('  Import complete: {0} added, {1} updated, {2} skipped, {3} failed.' -f $added, $updated, $skipped, $failed) -ForegroundColor $(
        if ($failed -gt 0) { 'Yellow' } else { 'Green' }
    )

    # Refresh the display so the updated list is visible.
    if (($added -gt 0 -or $updated -gt 0) -and -not $Script:ReadOnly) {
        Write-Host ''
        Write-Host '  Updated remote target list:' -ForegroundColor Cyan
        $refreshed = Get-RemoteList
        Show-SelectableList -Items $refreshed -Columns @(
            @{ Header = 'Name';            Expr = { $_.Name } },
            @{ Header = 'Host';            Expr = { $_.Host } },
            @{ Header = 'Port';            Expr = { $_.Port };            Align = 'Right' },
            @{ Header = 'User';            Expr = { $_.User } },
            @{ Header = 'Internet Access'; Expr = { $_.InternetAccess } }
        ) -NoNumber
    }
}

function Invoke-RemoteMenu {
    while ($true) {
        Show-Header -Title 'Remote targets'
        Write-Host '   1. List remote targets            (tcpkg remote list)'
        Write-Host '   2. Verify a target                (tcpkg remote verify <name>)'
        Write-Host '   3. Add a remote target            (tcpkg remote add ...)'
        Write-Host '   4. Edit a remote target           (tcpkg remote edit <name> ...)'
        Write-Host '   5. Remove a remote target         (tcpkg remote remove <name>)'
        Write-Host '   6. Export targets to CSV'
        Write-Host '   7. Import targets from CSV'
        Write-Host '   0. Back'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' {
                Write-Host ''
                $remotes = Get-RemoteList
                if (@($remotes).Count -eq 0) {
                    Write-Host '  No remote targets configured.' -ForegroundColor Yellow
                } else {
                    Show-SelectableList -Items $remotes -Columns @(
                        @{ Header = 'Name';            Expr = { $_.Name } },
                        @{ Header = 'Host';            Expr = { $_.Host } },
                        @{ Header = 'Port';            Expr = { $_.Port };            Align = 'Right' },
                        @{ Header = 'User';            Expr = { $_.User } },
                        @{ Header = 'Internet Access'; Expr = { $_.InternetAccess } }
                    ) -NoNumber
                }
                Wait-Continue
            }
            '2' {
                Write-Host ''
                $r = Select-Remote -Verb 'verify'
                if ($r) { Write-Host ''; Invoke-Tcpkg -ArgList @('remote','verify',$r.Name) }
                Wait-Continue
            }
            '3' {
                Write-Host ''
                $name = Read-Value 'Name for the new target (blank to cancel):' -CancelOnBlank
                if ($null -eq $name) { continue }
                $hostAddr = Read-Value 'Host address (blank to cancel):' -CancelOnBlank
                if ($null -eq $hostAddr) { continue }
                $port = Read-Value 'Port (blank = 22):' -AllowEmpty
                if ([string]::IsNullOrWhiteSpace($port)) { $port = '22' }
                $user = Read-Value 'User (blank to cancel):' -CancelOnBlank
                if ($null -eq $user) { continue }
                $argList = @('remote','add','-n',$name,'--host',$hostAddr,'--port',$port,'-u',$user)
                Write-Host ''
                Write-Host '  Auth method:' -ForegroundColor Cyan
                Write-Host '   1. Password (tcpkg will prompt)'
                Write-Host '   2. Private key file'
                Write-Host '   0. Cancel'
                Write-Host ''
                $auth = (Read-Host '  Choice').Trim()
                if ($auth -eq '0') { continue }
                if ($auth -eq '1') {
                    $securePwd = Read-Host '  Password' -AsSecureString
                    $plainPwd  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
                    $argList += '--password-stdin'
                } elseif ($auth -eq '2') {
                    $keyPath = Read-Value 'Path to private key file (blank to cancel):' -CancelOnBlank
                    if ($null -eq $keyPath) { continue }
                    $argList += @('-k', $keyPath)
                }
                if (Confirm-YesNo -Prompt 'Does this target have its own internet access?') {
                    $argList += '--internet-access'
                }
                Write-Host ''
                Write-Command -ArgList ($argList + @('-y'))
                if ($Script:ReadOnly) {
                    Write-Host '  [read-only] command not executed.' -ForegroundColor DarkYellow
                } else {
                    if ($argList -contains '--password-stdin') {
                        # -y suppresses the fingerprint trust confirmation.
                        # --password-stdin reads the password from the pipe.
                        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                        $plainPwd | & $Script:TcpkgExe @argList '-y' 2>&1
                        $Script:LastExit = $LASTEXITCODE
                        $ErrorActionPreference = $prev
                    } else {
                        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                        & $Script:TcpkgExe @argList '-y'
                        $Script:LastExit = $LASTEXITCODE
                        $ErrorActionPreference = $prev
                    }
                }
                Wait-Continue
            }
            '4' {
                Write-Host ''
                $r = Select-Remote -Verb 'edit'
                if ($r) {
                    Write-Host ''
                    Write-Host "  Editing '$($r.Name)'. Leave any field blank to keep its current value." -ForegroundColor Cyan
                    $argList = @('remote','edit',$r.Name)
                    $newName = Read-Value ('New name (current: {0}):' -f $r.Name) -AllowEmpty
                    if (-not [string]::IsNullOrWhiteSpace($newName)) { $argList += @('-n',$newName) }
                    $newHost = Read-Value ('New host (current: {0}):' -f $r.Host) -AllowEmpty
                    if (-not [string]::IsNullOrWhiteSpace($newHost)) { $argList += @('--host',$newHost) }
                    $newPort = Read-Value ('New port (current: {0}):' -f $r.Port) -AllowEmpty
                    if (-not [string]::IsNullOrWhiteSpace($newPort)) { $argList += @('--port',$newPort) }
                    $newUser = Read-Value ('New user (current: {0}):' -f $r.User) -AllowEmpty
                    if (-not [string]::IsNullOrWhiteSpace($newUser)) { $argList += @('-u',$newUser) }
                    $plainPwd = $null
                    if (Confirm-YesNo -Prompt 'Update password?') {
                        $securePwd = Read-Host '  New password' -AsSecureString
                        $plainPwd  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
                        $argList += '--password-stdin'
                    }
                    if (Confirm-YesNo -Prompt 'Update internet access setting?') {
                        if (Confirm-YesNo -Prompt 'Does this target have its own internet access?') {
                            $argList += '--internet-access'
                        }
                    }
                    $argList += '-y'
                    Write-Host ''
                    Write-Command -ArgList $argList
                    if ($Script:ReadOnly) {
                        Write-Host '  [read-only] command not executed.' -ForegroundColor DarkYellow
                    } else {
                        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                        if ($argList -contains '--password-stdin') {
                            $plainPwd | & $Script:TcpkgExe @argList
                        } else {
                            & $Script:TcpkgExe @argList
                        }
                        $Script:LastExit = $LASTEXITCODE
                        $ErrorActionPreference = $prev
                    }
                }
                Wait-Continue
            }
            '5' {
                Write-Host ''
                $r = Select-Remote -Verb 'remove'
                if ($r) {
                    if (Confirm-YesNo -Prompt "Remove target '$($r.Name)'?") {
                        Write-Host ''
                        Invoke-Tcpkg -ArgList @('remote','remove',$r.Name)
                    }
                }
                Wait-Continue
            }
            '6' { Write-Host ''; Export-RemoteTargets; Wait-Continue }
            '7' { Write-Host ''; Import-RemoteTargets; Wait-Continue }
            '0' { return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

function Invoke-ConfigMenu {
    while ($true) {
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
        if ($Script:ReadOnly) {
            Write-Host "  [read-only] explorer.exe '$folder'" -ForegroundColor DarkYellow
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
    Write-Host '  Enter numbers or ranges (e.g. 1,3,5..8 or 1,3,5-8), or blank to cancel' -ForegroundColor DarkGray
    $raw = (Read-Host '  Choice').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    $selections = @()
    foreach ($idx in (Expand-SelectionRange -RawInput $raw -Max @($res.Items).Count)) {
        $selections += $res.Items[$idx - 1]
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
            Write-Command -ArgList (@('download',$spec,'--exclude-dependencies','-y','-o',$tempDir) + $feedArgs)
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
        Write-Host 'You can still explore the menus; read-only mode will show what commands would run.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }

    # Show the read-only explanation on first launch.
    Show-Header -Title 'Welcome'
    Write-Host '  Read-only mode is ON.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  In read-only mode, no commands that make changes are executed.' -ForegroundColor Cyan
    Write-Host '  This includes install, upgrade, repair, uninstall, and all configuration' -ForegroundColor Cyan
    Write-Host '  changes such as adding/editing feeds, remote targets, or settings.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Instead, the exact tcpkg command that would be issued is displayed, e.g.:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    [read-only] tcpkg install twincat.standard.xae=4026.23.1 -r DCC-2 -y' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '  Use read-only mode to:' -ForegroundColor Cyan
    Write-Host '   - Explore the menus and understand what each option does' -ForegroundColor Cyan
    Write-Host '   - Verify the correct command will be issued before making any changes' -ForegroundColor Cyan
    Write-Host '   - Learn tcpkg syntax without risk of modifying your system' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Commands that always run (read-only data, used to populate menus):' -ForegroundColor DarkGray
    Write-Host '   tcpkg list, source list, config list, remote list' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  To make real changes, select option 8 on the main menu to turn read-only OFF.' -ForegroundColor Cyan
    Write-Host ''
    Wait-Continue

    while ($true) {
        Show-Header -Title 'Main menu'
        Write-Host '   1. Packages & workloads'
        Write-Host '   2. Sources (feeds)'
        Write-Host '   3. Configuration'
        Write-Host '   4. Tasks (automation)'
        Write-Host '   5. Remote targets'
        Write-Host '   6. Search files in local packages'
        Write-Host '   7. Search files in feed packages'
        $dryLabel = if ($Script:ReadOnly) { 'ON  — commands shown but not executed' } else { 'OFF — commands will execute' }
        Write-Host ("   8. Read-only mode: {0}" -f $dryLabel) -ForegroundColor $(if ($Script:ReadOnly) { 'Yellow' } else { 'Green' })
        Write-Host '   9. Run a raw tcpkg command'
        Write-Host '   0. Exit'
        Write-Host ''
        switch ((Read-Host '  Choice').Trim()) {
            '1' { Invoke-PackagesMenu }
            '2' { Invoke-SourcesMenu }
            '3' { Invoke-ConfigMenu }
            '4' { Invoke-TasksMenu }
            '5' { Invoke-RemoteMenu }
            '6' { Invoke-PackageFileSearch }
            '7' { Invoke-FeedFileSearch }
            '8' {
                $Script:ReadOnly = -not $Script:ReadOnly
                if ($Script:ReadOnly) {
                    Write-Host '  Read-only mode ON  — commands will be shown but not executed.' -ForegroundColor Yellow
                } else {
                    Write-Host '  Read-only mode OFF — commands will execute and make real changes.' -ForegroundColor Green
                }
                Start-Sleep -Milliseconds 1200
            }
            '9' { Invoke-RawCommand }
            '0' { Write-Host ''; Write-Host '  Goodbye.' -ForegroundColor Cyan; return }
            default { Write-Host '  Unknown choice.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

# Entry point
Start-TcPkgConsole
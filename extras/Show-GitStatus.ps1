function global:Show-GitStatus {
    <#
    .SYNOPSIS
    Better git status

    .DESCRIPTION
    Better git diff status

    .EXAMPLE
    PS> Show-GitStatus

    .EXAMPLE
    PS> gs

    .COMPONENT

    #>

    # --- Helper: Check if inside a git repo ---
    function Test-InGitRepo {
        $inside = git rev-parse --is-inside-work-tree 2>$null
        return ($inside -eq "true")
    }

    # --- Helper: Parse branch status ---
    function Get-BranchStatus($statusLines) {
        $branch   = ($statusLines | Where-Object { $_ -like '# branch.head*' }) -replace '# branch.head ', ''
        $upstream = ($statusLines | Where-Object { $_ -like '# branch.upstream*' }) -replace '# branch.upstream ', ''
        $aheadInfo= ($statusLines | Where-Object { $_ -like '# branch.ab*' }) -replace '# branch.ab ', ''

        $aheadCount = 0
        $behindCount = 0
        if ($aheadInfo) {
            $split = $aheadInfo.Split(' ')
            $aheadCount = [int]($split[0].Replace('+',''))
            $behindCount = [int]($split[1].Replace('-',''))
        }
        [PSCustomObject]@{
            Branch      = $branch
            Upstream    = $upstream
            AheadCount  = $aheadCount
            BehindCount = $behindCount
        }
    }

    # --- Helper: Get tag info ---
    function Get-TagInfo($upstream) {
        $tagAtHead   = git describe --tags --exact-match 2>$null
        $nearestTag  = git describe --tags 2>$null
        $localTags   = git tag --points-at HEAD

        # Only hit the network if there's actually a local tag at HEAD to check.
        $remoteTags  = @()
        if ($upstream -and $localTags) {
            $remoteTags = (git ls-remote --tags $upstream 2>$null) -replace '.*refs/tags/', ''
        }
        $unpushedTags = $localTags | Where-Object { $_ -and ($_ -notin $remoteTags) }

        [PSCustomObject]@{
            TagAtHead    = $tagAtHead
            NearestTag   = $nearestTag
            UnpushedTags = $unpushedTags
        }
    }

    # --- Helper: Get stash info ---
    function Get-StashInfo {
        $entries = git stash list --pretty=format:"%gd %s" 2>$null
        [PSCustomObject]@{
            Entries = @($entries)
        }
    }

    # --- Helper: Get commit info for ahead/behind ---
    function Get-CommitInfo($branchStatus) {
        $remoteCommits = @()
        if ($branchStatus.Upstream -and $branchStatus.BehindCount -gt 0) {
            $remoteCommits = git log "HEAD..$($branchStatus.Upstream)" --pretty=format:"%h %s" -n $branchStatus.BehindCount
        }
        $unpushed     = @()
        if ($branchStatus.Upstream) {
            $unpushed = git log "$($branchStatus.Upstream)..HEAD" --pretty=format:"%H"
        }
        [PSCustomObject]@{
            RemoteCommits = $remoteCommits
            Unpushed      = $unpushed
        }
    }

    # --- Helper: Parse porcelain status into buckets ---
    function Get-FileBuckets($statusLines) {
        $staged     = @()
        $unstaged   = @()
        $untracked  = @()
        $conflicted = @()

        foreach ($line in $statusLines) {
            if ($line -match '^\? (.+)$') {
                $untracked += $matches[1]
                continue
            }

            $type = $line.Substring(0, 1)

            if ($type -eq '1') {
                # 1 XY sub mH mI mW hH hI <path>  (9 space-separated tokens, path may contain spaces)
                $parts = $line -split ' ', 9
                if ($parts.Count -lt 9) { continue }
                $X = $parts[1][0]; $Y = $parts[1][1]; $file = $parts[8]

                if ($X -ne '.') { $staged += "$X $file" }
                if ($Y -ne '.') { $unstaged += "$Y $file" }
            }
            elseif ($type -eq '2') {
                # 2 XY sub mH mI mW hH hI Xscore <path>`t<origPath>  (10 tokens, path`torigPath preserved)
                $parts = $line -split ' ', 10
                if ($parts.Count -lt 10) { continue }
                $X = $parts[1][0]; $Y = $parts[1][1]
                $file = ($parts[9] -split "`t", 2)[0]

                if ($X -ne '.') { $staged += "$X $file" }
                if ($Y -ne '.') { $unstaged += "$Y $file" }
            }
            elseif ($type -eq 'u') {
                # u XY sub m1 m2 m3 mW h1 h2 h3 <path>  (11 tokens, path may contain spaces)
                $parts = $line -split ' ', 11
                if ($parts.Count -lt 11) { continue }
                $code = $parts[1]; $file = $parts[10]

                $conflicted += "$code $file"
            }
        }
        [PSCustomObject]@{
            Staged     = $staged
            Unstaged   = $unstaged
            Untracked  = $untracked
            Conflicted = $conflicted
        }
    }

    # --- Helper: Build a map of file -> {Added, Deleted, IsBinary} from git --numstat output ---
    function Get-NumstatMap {
        param(
            [string]$DiffArgs
        )
        $map = @{}

        # Use tabs as separators; numstat format: added<TAB>deleted<TAB>path
        # Only pass $DiffArgs when non-empty - git treats a bare "" positional arg as an ambiguous revision.
        if ($DiffArgs) {
            $lines = & git diff $DiffArgs --numstat 2>$null
        } else {
            $lines = & git diff --numstat 2>$null
        }
        foreach ($l in $lines) {
            if (-not $l) { continue }
            # split into three parts at tabs (handles filenames with spaces)
            $parts = $l -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $addedRaw = $parts[0]
            $deletedRaw = $parts[1]
            $path = $parts[2]

            $isBinary = $false
            if ($addedRaw -eq '-' -or $deletedRaw -eq '-') {
                $isBinary = $true
                $added = 0
                $deleted = 0
            } else {
                $added = [int]$addedRaw
                $deleted = [int]$deletedRaw
            }

            $map[$path] = [PSCustomObject]@{ Added = $added; Deleted = $deleted; IsBinary = $isBinary }
        }

        return $map
    }

    # Look up the add/delete counts for a file given a numstat map
    function Get-ChangeCounts($file, $map) {
        if (-not $map) { return $null }
        if ($map.ContainsKey($file)) { return $map[$file] }
        # sometimes the status path and numstat path differ (rename notation). Try a fallback: match by suffix
        foreach ($k in $map.Keys) {
            if ($k -and $file.EndsWith($k)) { return $map[$k] }
        }
        return $null
    }

    # --- Box rendering helpers ---
    function New-Seg($text, $color) {
        [PSCustomObject]@{ Text = $text; Color = $color }
    }

    # Build the " (+A | -D)" / " (binary)" segments for a file given a numstat map
    function Get-DiffStatSegments($counts, $fallbackColor) {
        if (-not $counts) { return @() }
        if ($counts.IsBinary) { return @((New-Seg " (binary)" $fallbackColor)) }
        return @(
            (New-Seg " (" $fallbackColor),
            (New-Seg "+$($counts.Added)" 'Green'),
            (New-Seg " | " $fallbackColor),
            (New-Seg "-$($counts.Deleted)" 'Red'),
            (New-Seg ")" $fallbackColor)
        )
    }

    function Write-BoxTop($title, $boxWidth) {
        $prefix = "+-- $title "
        $prefix = $prefix.Replace('+', [char]0x250C).Replace('-', [char]0x2500)
        $fillCount = $boxWidth - $prefix.Length - 1
        if ($fillCount -lt 0) { $fillCount = 0 }
        $line = $prefix + ([string][char]0x2500 * $fillCount) + [char]0x2510
        Write-Host $line -ForegroundColor DarkGray
    }

    function Write-BoxBottom($boxWidth) {
        $line = [char]0x2514 + ([string][char]0x2500 * ($boxWidth - 2)) + [char]0x2518
        Write-Host $line -ForegroundColor DarkGray
    }

    function Write-BoxLine($segments, $boxWidth) {
        $contentWidth = $boxWidth - 4
        if ($contentWidth -lt 1) { $contentWidth = 1 }
        Write-Host "$([char]0x2502) " -NoNewline -ForegroundColor DarkGray
        $used = 0
        foreach ($seg in $segments) {
            $text = $seg.Text
            if (-not $text) { continue }
            $remaining = $contentWidth - $used
            if ($remaining -le 0) { break }
            if ($text.Length -gt $remaining) {
                if ($remaining -ge 2) {
                    $text = $text.Substring(0, $remaining - 1) + [char]0x2026
                } else {
                    $text = $text.Substring(0, $remaining)
                }
            }
            Write-Host $text -NoNewline -ForegroundColor $seg.Color
            $used += $text.Length
        }
        if ($used -lt $contentWidth) {
            Write-Host (' ' * ($contentWidth - $used)) -NoNewline
        }
        Write-Host " $([char]0x2502)" -ForegroundColor DarkGray
    }

    function Write-Box($title, $lines, $boxWidth) {
        if ($lines.Count -eq 0) { return }
        Write-BoxTop $title $boxWidth
        foreach ($line in $lines) {
            Write-BoxLine $line $boxWidth
        }
        Write-BoxBottom $boxWidth
    }

    # Render a small lane-based commit graph (gitgraph.nvim-style smooth junctions)
    # for the last 7 commits, instead of reusing git's raw ASCII --graph output.
    # Returns a list of lines, each a list of (Text,Color) segments.
    function Get-PrettyGraphLines($unpushed) {
        $resultLines = New-Object System.Collections.Generic.List[object]
        $sep = [char]0x1f
        $raw = git log --topo-order -n 12 --pretty=format:"%H$sep%h$sep%P$sep%d$sep%s"
        $commits = @()
        foreach ($l in $raw) {
            if (-not $l) { continue }
            $f = $l -split [regex]::Escape($sep)
            if ($f.Count -lt 5) { continue }
            $parents = @()
            if ($f[2]) { $parents = $f[2] -split ' ' }
            $deco = $f[3].Trim()
            if ($deco.StartsWith('(') -and $deco.EndsWith(')')) { $deco = $deco.Substring(1, $deco.Length - 2) }
            $commits += [PSCustomObject]@{
                Hash    = $f[0]
                Abbrev  = $f[1]
                Parents = $parents
                Deco    = $deco
                Subject = $f[4]
            }
        }

        $lanes = New-Object System.Collections.Generic.List[string]

        foreach ($commit in $commits) {
            # --- claim a lane for this commit ---
            $idx = -1
            for ($j = 0; $j -lt $lanes.Count; $j++) {
                if ($lanes[$j] -eq $commit.Hash) { $idx = $j; break }
            }
            if ($idx -eq -1) {
                $freeIdx = -1
                for ($j = 0; $j -lt $lanes.Count; $j++) {
                    if (-not $lanes[$j]) { $freeIdx = $j; break }
                }
                if ($freeIdx -ge 0) { $idx = $freeIdx; $lanes[$idx] = $commit.Hash }
                else { $idx = $lanes.Count; $lanes.Add($commit.Hash) }
            }

            $isMerge = $commit.Parents.Count -gt 1

            # --- commit row ---
            $rowSegs = New-Object System.Collections.Generic.List[object]
            for ($col = 0; $col -lt $lanes.Count; $col++) {
                if ($col -gt 0) { $rowSegs.Add((New-Seg ' ' 'DarkGray')) }
                if ($col -eq $idx) {
                    if ($isMerge) { $rowSegs.Add((New-Seg ([char]0x25CF) 'Magenta')) } else { $rowSegs.Add((New-Seg ([char]0x25CB) 'Cyan')) }
                } elseif ($lanes[$col]) {
                    $rowSegs.Add((New-Seg ([char]0x2502) 'DarkGray'))
                } else {
                    $rowSegs.Add((New-Seg ' ' 'DarkGray'))
                }
            }
            $hashColor = if ($unpushed -and ($unpushed -contains $commit.Hash)) { 'Green' } else { 'Yellow' }
            $rowSegs.Add((New-Seg " $($commit.Abbrev)" $hashColor))
            if ($commit.Deco) { $rowSegs.Add((New-Seg " ($($commit.Deco))" 'Green')) }
            $rowSegs.Add((New-Seg " $($commit.Subject)" 'Gray'))
            $resultLines.Add($rowSegs)

            # --- resolve parents into lanes ---
            # Every parent (not just extra merge parents) can turn out to already be
            # claimed by another active lane - that's a branch rejoining the mainline.
            $newTargets = @()
            $closeTargets = @()
            $primaryLaneKept = $false

            foreach ($parentHash in $commit.Parents) {
                $existing = -1
                for ($j = 0; $j -lt $lanes.Count; $j++) {
                    if ($j -ne $idx -and $lanes[$j] -eq $parentHash) { $existing = $j; break }
                }
                if ($existing -ge 0) {
                    $closeTargets += $existing
                } elseif (-not $primaryLaneKept) {
                    $lanes[$idx] = $parentHash
                    $primaryLaneKept = $true
                } else {
                    $freeIdx = -1
                    for ($j = 0; $j -lt $lanes.Count; $j++) {
                        if ($j -ne $idx -and -not $lanes[$j]) { $freeIdx = $j; break }
                    }
                    if ($freeIdx -ge 0) { $lanes[$freeIdx] = $parentHash; $newTargets += $freeIdx }
                    else { $lanes.Add($parentHash); $newTargets += ($lanes.Count - 1) }
                }
            }

            if (-not $primaryLaneKept) { $lanes[$idx] = $null }

            # --- transition row ---
            $bridges = @()
            foreach ($t in $newTargets)   { $bridges += [PSCustomObject]@{ From = $idx; To = $t; New = $true } }
            foreach ($t in $closeTargets) { $bridges += [PSCustomObject]@{ From = $idx; To = $t; New = $false } }

            if ($bridges.Count -gt 0) {
                $laneWidth = ($lanes.Count * 2) - 1
                $buf = New-Object 'object[]' $laneWidth
                for ($col = 0; $col -lt $lanes.Count; $col++) {
                    $buf[$col * 2] = if ($lanes[$col]) { [char]0x2502 } else { ' ' }
                    if ($col -lt $lanes.Count - 1) { $buf[$col * 2 + 1] = ' ' }
                }
                foreach ($b in $bridges) {
                    $fromPos = $b.From * 2
                    $toPos = $b.To * 2
                    $lo = [Math]::Min($fromPos, $toPos)
                    $hi = [Math]::Max($fromPos, $toPos)
                    $goingRight = $toPos -gt $fromPos
                    for ($pos = $lo; $pos -le $hi; $pos++) {
                        if ($pos -eq $fromPos) {
                            # origin: 3-way if its own lane also continues below (fork, or a kept primary),
                            # otherwise (fully closing) a 2-way corner with no downward stroke.
                            if ($b.New -or $primaryLaneKept) {
                                $buf[$pos] = if ($goingRight) { [char]0x251C } else { [char]0x2524 }
                            } else {
                                $buf[$pos] = if ($goingRight) { [char]0x2570 } else { [char]0x256F }
                            }
                        } elseif ($pos -eq $toPos) {
                            if ($b.New) {
                                # brand-new lane: no upward stroke, just arrives and continues down.
                                $buf[$pos] = if ($goingRight) { [char]0x256E } else { [char]0x256D }
                            } else {
                                # existing lane: was already active above and keeps going below.
                                $buf[$pos] = if ($goingRight) { [char]0x2524 } else { [char]0x251C }
                            }
                        } elseif ($pos % 2 -eq 1) {
                            $buf[$pos] = [char]0x2500
                        } else {
                            $buf[$pos] = if ($buf[$pos] -eq [char]0x2502) { [char]0x253C } else { [char]0x2500 }
                        }
                    }
                }
                $transSegs = New-Object System.Collections.Generic.List[object]
                for ($pos = 0; $pos -lt $laneWidth; $pos++) {
                    $ch = $buf[$pos]; if (-not $ch) { $ch = ' ' }
                    $transSegs.Add((New-Seg $ch 'DarkGray'))
                }
                $resultLines.Add($transSegs)
            }

            while ($lanes.Count -gt 0 -and -not $lanes[$lanes.Count - 1]) {
                $lanes.RemoveAt($lanes.Count - 1)
            }
        }

        return $resultLines
    }

    if (-not (Test-InGitRepo)) {
        Write-Host " Not a git repository." -ForegroundColor Red
        return
    }

    $statusRaw = git status --porcelain=v2 --branch
    if (-not $statusRaw) {
        Write-Host " Clean working tree!" -ForegroundColor Green
        return
    }

    $branchStatus = Get-BranchStatus $statusRaw
    $tagInfo = Get-TagInfo $branchStatus.Upstream
    $stashInfo = Get-StashInfo
    $commitInfo = Get-CommitInfo $branchStatus
    $stagedNumstat = Get-NumstatMap "--cached"
    $unstagedNumstat = Get-NumstatMap ""
    $buckets = Get-FileBuckets $statusRaw

    $boxWidth = 80
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 10) { $boxWidth = $w - 1 }
    } catch {}

    Write-Host ""

    # --- Branches box ---
    $branchLines = New-Object System.Collections.Generic.List[object]

    if ($tagInfo.TagAtHead) {
        $branchLines.Add(@((New-Seg "  On tag:" 'DarkYellow'), (New-Seg " $($tagInfo.TagAtHead)" 'Cyan')))
    } elseif ($tagInfo.NearestTag) {
        $branchLines.Add(@((New-Seg "  Nearest tag:" 'DarkYellow'), (New-Seg " $($tagInfo.NearestTag)" 'DarkCyan')))
    }
    foreach ($t in $tagInfo.UnpushedTags) {
        $branchLines.Add(@((New-Seg "  Unpushed tag:" 'DarkYellow'), (New-Seg " $t" 'Magenta')))
    }

    if (-not $branchStatus.Upstream) {
        $branchLines.Add(@(
            (New-Seg "  Remote: " 'Magenta'),
            (New-Seg "     " 'DarkGray'),
            (New-Seg " | no upstream" 'DarkGray'),
            (New-Seg " | (git push -u origin $($branchStatus.Branch))" 'DarkGray')
        ))
    } elseif ($branchStatus.BehindCount -gt 0) {
        $branchLines.Add(@(
            (New-Seg "  Remote: " 'Magenta'),
            (New-Seg "[ $($branchStatus.BehindCount)]" 'DarkMagenta'),
            (New-Seg " | $($branchStatus.Upstream)" 'Green'),
            (New-Seg " | (git pull)" 'DarkGray')
        ))
        foreach ($c in $commitInfo.RemoteCommits) {
            $branchLines.Add(@((New-Seg "   󰇚 $c" 'DarkRed')))
        }
    } else {
        $branchLines.Add(@(
            (New-Seg "  Remote: " 'Magenta'),
            (New-Seg "[ $($branchStatus.BehindCount)]" 'DarkGray'),
            (New-Seg " | $($branchStatus.Upstream)" 'Green'),
            (New-Seg " | (git fetch)" 'DarkGray')
        ))
    }

    if ($branchStatus.AheadCount -gt 0) {
        $headSegs = New-Object System.Collections.Generic.List[object]
        $headSegs.Add((New-Seg "  HEAD:   " 'Magenta'))
        $headSegs.Add((New-Seg "[ $($branchStatus.AheadCount)]" 'DarkCyan'))
        $headSegs.Add((New-Seg " | $($branchStatus.Branch)" 'Yellow'))
        if (($branchStatus.Branch -eq "master") -or ($branchStatus.Branch -eq "main")) { $headSegs.Add((New-Seg " " 'Red')) }
        $headSegs.Add((New-Seg " | (git push | git reset --soft HEAD~$($branchStatus.AheadCount))" 'DarkGray'))
        $branchLines.Add($headSegs)
    } else {
        $headSegs = New-Object System.Collections.Generic.List[object]
        $headSegs.Add((New-Seg "  HEAD:   " 'Magenta'))
        $headSegs.Add((New-Seg "[ $($branchStatus.AheadCount)]" 'DarkGray'))
        $headSegs.Add((New-Seg " | $($branchStatus.Branch)" 'Yellow'))
        if (($branchStatus.Branch -eq "master") -or ($branchStatus.Branch -eq "main")) { $headSegs.Add((New-Seg " " 'Red')) }
        $branchLines.Add($headSegs)
    }

    Write-Box "Branches" $branchLines $boxWidth

    # --- Stashes box ---
    if ($stashInfo.Entries) {
        $stashLines = New-Object System.Collections.Generic.List[object]
        $stashLines.Add(@(
            (New-Seg " $([char]0xF187) Stashes: " 'Magenta'),
            (New-Seg "[ $($stashInfo.Entries.Count)]" 'DarkYellow'),
            (New-Seg " | (git stash pop)" 'DarkGray')
        ))
        $stashInfo.Entries | Select-Object -First 5 | ForEach-Object {
            $stashLines.Add(@((New-Seg "   $_" 'DarkMagenta')))
        }
        Write-Box "Stashes" $stashLines $boxWidth
    }

    # --- Files box ---
    $fileLines = New-Object System.Collections.Generic.List[object]

    if ((-not $buckets.Conflicted) -and (-not $buckets.Staged) -and (-not $buckets.Unstaged) -and (-not $buckets.Untracked)) {
        $fileLines.Add(@((New-Seg " No changes" 'DarkGray')))
    }

    if ($buckets.Conflicted) {
        $fileLines.Add(@((New-Seg " Conflicted ($($buckets.Conflicted.Count))" 'Red'), (New-Seg " | (git mergetool | git add)" 'DarkGray')))
        foreach ($entry in $buckets.Conflicted) {
            $parts = $entry.Split(" ", 2)
            $code, $file = $parts
            $fileLines.Add(@((New-Seg "   $code " 'DarkRed'), (New-Seg "$file" 'White')))
        }
        $fileLines.Add(@())
    }

    if ($buckets.Staged) {
        $fileLines.Add(@((New-Seg "  Staged changes ($($buckets.Staged.Count))" 'Green'), (New-Seg " | (git commit | git restore --staged)" 'DarkGray')))
        foreach ($entry in $buckets.Staged) {
            $parts = $entry.Split(" ",2)
            $code,$file = $parts
            $counts = Get-ChangeCounts $file $stagedNumstat
            $codeIcon = switch ($code) {
                'M' { '' } 'A' { '' } 'D' { '' } 'R' { '' } default { '' }
            }
            $prefix = if ($codeIcon) { "    $codeIcon  " } else { "    " }
            $line = New-Object System.Collections.Generic.List[object]
            $line.Add((New-Seg $prefix 'DarkGreen'))
            $line.Add((New-Seg "$file" 'White'))
            foreach ($seg in (Get-DiffStatSegments $counts 'DarkGreen')) { $line.Add($seg) }
            $fileLines.Add($line)
        }
        $fileLines.Add(@())
    }

    if ($buckets.Unstaged) {
        $fileLines.Add(@((New-Seg "  Unstaged changes ($($buckets.Unstaged.Count))" 'Yellow'), (New-Seg " | (git add | git restore)" 'DarkGray')))
        foreach ($entry in $buckets.Unstaged) {
            $parts = $entry.Split(" ",2)
            $code,$file = $parts
            $counts = Get-ChangeCounts $file $unstagedNumstat
            $codeIcon = switch ($code) {
                'M' { '' } 'D' { '' } default { '' }
            }
            $prefix = if ($codeIcon) { "    $codeIcon  " } else { "    " }
            $line = New-Object System.Collections.Generic.List[object]
            $line.Add((New-Seg $prefix 'DarkYellow'))
            $line.Add((New-Seg "$file" 'White'))
            foreach ($seg in (Get-DiffStatSegments $counts 'DarkYellow')) { $line.Add($seg) }
            $fileLines.Add($line)
        }
        $fileLines.Add(@())
    }

    if ($buckets.Untracked) {
        $fileLines.Add(@((New-Seg "  Untracked ($($buckets.Untracked.Count))" 'Magenta'), (New-Seg " | (git add)" 'DarkGray')))
        # For untracked files we can't easily get numstat; mark as (new)
        $buckets.Untracked | ForEach-Object {
            $fileLines.Add(@(
                (New-Seg "      " 'DarkMagenta'),
                (New-Seg "$_" 'White'),
                (New-Seg " (new)" 'DarkMagenta')
            ))
        }
        $fileLines.Add(@())
    }

    while ($fileLines.Count -gt 0 -and $fileLines[$fileLines.Count - 1].Count -eq 0) {
        $fileLines.RemoveAt($fileLines.Count - 1)
    }

    Write-Box "Files" $fileLines $boxWidth

    # --- Graph box ---
    $graphLines = Get-PrettyGraphLines $commitInfo.Unpushed
    Write-Box "Graph" $graphLines $boxWidth
}

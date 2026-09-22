<#
.SYNOPSIS
Run a SQL Server oriented SAN benchmark with DiskSpd.

.DESCRIPTION
Executes several DiskSpd profiles aligned with typical SQL Server workloads:
- DATA random read
- DATA OLTP mixed read/write
- LOG sequential write
- TEMPDB random mixed read/write
- BACKUP sequential read and write

Results are exported in CSV, JSON and raw XML per test.

.NOTES
Author: GitHub Copilot
Date: 2026/09/10

.PARAMETER DiskSpdPath
Full path to diskspd.exe.

.PARAMETER TestFile
Full path to the DiskSpd test file.

.PARAMETER FileSize
Size of the test file created by DiskSpd.

.PARAMETER DurationSeconds
Duration of each test in seconds, excluding warmup and cooldown.

.PARAMETER WarmupSeconds
Warmup duration in seconds.

.PARAMETER CooldownSeconds
Cooldown duration in seconds.

.PARAMETER ResultFolder
Directory where CSV, JSON and XML files will be stored.

.PARAMETER HtmlTitle
Title used in the generated HTML report.

.PARAMETER ThreadCounts
Thread counts to test.

.PARAMETER OutstandingIoValues
Outstanding I/O values to test.

.PARAMETER DisableHardwareCache
Adds -Sh to disable software and hardware caching where supported.

.PARAMETER MeasureLatency
Adds -L to collect latency statistics in DiskSpd XML results.

.PARAMETER UseLargePages
Adds -l to request large pages.

.EXAMPLE
.\Invoke-DiskSpdSqlServerBenchmark.ps1 -TestFile "L:\Data\test.dat"

.EXAMPLE
.\Invoke-DiskSpdSqlServerBenchmark.ps1 -TestFile "L:\Data\test.dat" -DiskSpdPath "D:\Tools\DiskSpd_2.3\amd64\diskspd.exe" -FileSize "200G" -DurationSeconds 180 -OutstandingIoValues 1,4,8,16
#>
[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string]$TestFile = "L:\Data\test.dat",

    [ValidateNotNullOrEmpty()]
    [string]$DiskSpdPath = "D:\Tools\DiskSpd_2.3\amd64\diskspd.exe",

    [ValidateNotNullOrEmpty()]
    [string]$FileSize = "200G",

    [ValidateRange(30, 3600)]
    [int]$DurationSeconds = 180,

    [ValidateRange(0, 600)]
    [int]$WarmupSeconds = 15,

    [ValidateRange(0, 600)]
    [int]$CooldownSeconds = 10,

    [ValidateNotNullOrEmpty()]
    [int[]]$ThreadCounts = @(1, 4),

    [ValidateNotNullOrEmpty()]
    [int[]]$OutstandingIoValues = @(1, 4, 8, 16),

    [switch]$DisableHardwareCache,

    [bool]$MeasureLatency = $true,

    [switch]$UseLargePages,

    [switch]$SkipBackupProfiles,

    [switch]$SkipTempDbProfile,

    [string]$ResultFolder,

    [string]$HtmlTitle = 'DiskSpd SQL Server Benchmark Report'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResultFolder)) {
    $baseResultPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $ResultFolder = Join-Path -Path $baseResultPath -ChildPath 'result'
}

function Test-DiskSpdXmlValue {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    return $null -ne $Value -and [string]::IsNullOrWhiteSpace([string]$Value) -eq $false
}

function Get-DiskSpdDouble {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if (-not (Test-DiskSpdXmlValue -Value $Value)) {
        return 0D
    }

    return [double]$Value
}

function Get-XmlPropertyValue {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if (-not $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]

    if (-not $property) {
        return $null
    }

    return $property.Value
}

function Get-DiskSpdTargetStats {
    param (
        [Parameter(Mandatory = $true)]
        [xml]$Xml
    )

    $targets = @($Xml.Results.TimeSpan.Thread.Target)

    if ($targets.Count -eq 0) {
        throw 'DiskSpd XML does not contain any target statistics.'
    }

    $readCount = ($targets | Measure-Object -Property ReadCount -Sum).Sum
    $writeCount = ($targets | Measure-Object -Property WriteCount -Sum).Sum
    $readBytes = ($targets | Measure-Object -Property ReadBytes -Sum).Sum
    $writeBytes = ($targets | Measure-Object -Property WriteBytes -Sum).Sum

    return [PSCustomObject]@{
        ReadCount = Get-DiskSpdDouble -Value $readCount
        WriteCount = Get-DiskSpdDouble -Value $writeCount
        ReadBytes = Get-DiskSpdDouble -Value $readBytes
        WriteBytes = Get-DiskSpdDouble -Value $writeBytes
    }
}

function New-DiskSpdProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$BlockSize,

        [ValidateRange(0, 100)]
        [int]$WritePercent,

        [Parameter(Mandatory = $true)]
        [bool]$Random,

        [Parameter(Mandatory = $true)]
        [string]$TargetArea
    )

    return [PSCustomObject]@{
        Name = $Name
        Description = $Description
        BlockSize = $BlockSize
        WritePercent = $WritePercent
        Random = $Random
        TargetArea = $TargetArea
    }
}

function Get-DiskSpdChartSeries {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Total_MBps', 'Avg_Latency_ms')]
        [string]$ValueProperty,

        [Parameter(Mandatory = $true)]
        [ValidateSet('max', 'min')]
        [string]$SelectionMode
    )

    $series = foreach ($targetGroup in ($Results | Group-Object -Property TargetArea | Sort-Object -Property Name)) {
        $points = foreach ($oioGroup in ($targetGroup.Group | Group-Object -Property OutstandingIo | Sort-Object -Property Name)) {
            $bestRow = if ($SelectionMode -eq 'max') {
                $oioGroup.Group | Sort-Object -Property $ValueProperty -Descending | Select-Object -First 1
            }
            else {
                $oioGroup.Group | Sort-Object -Property $ValueProperty | Select-Object -First 1
            }

            [PSCustomObject]@{
                OutstandingIo = [int]$oioGroup.Name
                Threads = [int]$bestRow.Threads
                Test = $bestRow.Test
                Value = [double]$bestRow.$ValueProperty
            }
        }

        [PSCustomObject]@{
            TargetArea = $targetGroup.Name
            Points = @($points)
        }
    }

    return @($series)
}

function Get-DiskSpdResultHighlights {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Results
    )

    $bestThroughput = $Results |
        Sort-Object -Property Total_MBps -Descending |
        Select-Object -First 1

    $worstLatency = $Results |
        Sort-Object -Property Avg_Latency_ms -Descending |
        Select-Object -First 1

    return [PSCustomObject]@{
        BestThroughput = $bestThroughput
        WorstLatency = $worstLatency
    }
}

function ConvertTo-SvgCurvePath {
    param (
        [Parameter(Mandatory = $true)]
        [double[]]$X,

        [Parameter(Mandatory = $true)]
        [double[]]$Y
    )

    if ($X.Count -eq 0) {
        return ''
    }

    if ($X.Count -eq 1) {
        return ('M {0},{1}' -f $X[0], $Y[0])
    }

    $path = 'M {0},{1}' -f $X[0], $Y[0]

    for ($index = 0; $index -lt ($X.Count - 1); $index++) {
        $x0 = if ($index -gt 0) { $X[$index - 1] } else { $X[$index] }
        $y0 = if ($index -gt 0) { $Y[$index - 1] } else { $Y[$index] }
        $x1 = $X[$index]
        $y1 = $Y[$index]
        $x2 = $X[$index + 1]
        $y2 = $Y[$index + 1]
        $x3 = if (($index + 2) -lt $X.Count) { $X[$index + 2] } else { $X[$index + 1] }
        $y3 = if (($index + 2) -lt $Y.Count) { $Y[$index + 2] } else { $Y[$index + 1] }

        $c1x = $x1 + (($x2 - $x0) / 6)
        $c1y = $y1 + (($y2 - $y0) / 6)
        $c2x = $x2 - (($x3 - $x1) / 6)
        $c2y = $y2 - (($y3 - $y1) / 6)

        $path += ' C {0},{1} {2},{3} {4},{5}' -f $c1x, $c1y, $c2x, $c2y, $x2, $y2
    }

    return $path
}

function New-DiskSpdSvgChart {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Subtitle,

        [Parameter(Mandatory = $true)]
        [string]$YAxisLabel,

        [Parameter(Mandatory = $true)]
        [int[]]$Categories,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Series,

        [Parameter(Mandatory = $true)]
        [string]$ValueFormat,

        [Parameter(Mandatory = $true)]
        [string[]]$Colors
    )

    if ($Categories.Count -eq 0 -or $Series.Count -eq 0) {
        return '<p>Aucune donnée graphique disponible.</p>'
    }

    $width = 980
    $height = 360
    $paddingLeft = 70
    $paddingRight = 40
    $paddingTop = 56
    $paddingBottom = 64
    $plotWidth = $width - $paddingLeft - $paddingRight
    $plotHeight = $height - $paddingTop - $paddingBottom

    $allValues = foreach ($serie in $Series) { foreach ($point in $serie.Points) { [double]$point.Value } }
    $minValue = ($allValues | Measure-Object -Minimum).Minimum
    $maxValue = ($allValues | Measure-Object -Maximum).Maximum

    if ($null -eq $minValue) {
        return '<p>Aucune donnée graphique disponible.</p>'
    }

    if ($maxValue -le $minValue) {
        $maxValue = $minValue + 1
    }

    $valueRange = $maxValue - $minValue
    $yMin = [math]::Floor($minValue - ($valueRange * 0.1))
    if ($yMin -lt 0) {
        $yMin = 0
    }

    $yMax = [math]::Ceiling($maxValue + ($valueRange * 0.1))
    if ($yMax -le $yMin) {
        $yMax = $yMin + 1
    }

    $yRange = $yMax - $yMin
    $tickCount = 5
    $xStep = if ($Categories.Count -gt 1) { $plotWidth / ($Categories.Count - 1) } else { 0 }

    $lines = New-Object System.Text.StringBuilder
    [void]$lines.AppendLine('<div class="chart-card">')
    [void]$lines.AppendLine(('<h2>{0}</h2>' -f $Title))
    [void]$lines.AppendLine(('<p class="chart-subtitle">{0}</p>' -f $Subtitle))
    [void]$lines.AppendLine(('<svg class="chart-svg" viewBox="0 0 {0} {1}" role="img" aria-label="{2}">' -f $width, $height, $Title))
    [void]$lines.AppendLine('<rect x="0" y="0" width="100%" height="100%" rx="16" ry="16" fill="#ffffff" />')

    for ($tickIndex = 0; $tickIndex -le $tickCount; $tickIndex++) {
        $value = $yMin + (($yRange / $tickCount) * $tickIndex)
        $y = $paddingTop + ($plotHeight - (($value - $yMin) / $yRange) * $plotHeight)
        [void]$lines.AppendLine(('<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" class="grid-line" />' -f $paddingLeft, ([math]::Round($y, 2)), ($width - $paddingRight), ([math]::Round($y, 2))))
        [void]$lines.AppendLine(('<text x="{0}" y="{1}" class="axis-label y-label">{2}</text>' -f ($paddingLeft - 10), ([math]::Round($y + 4, 2)), ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $ValueFormat, $value))))
    }

    foreach ($categoryIndex in 0..($Categories.Count - 1)) {
        $x = if ($Categories.Count -gt 1) { $paddingLeft + ($xStep * $categoryIndex) } else { $paddingLeft + ($plotWidth / 2) }
        [void]$lines.AppendLine(('<line x1="{0}" y1="{1}" x2="{2}" y2="{3}" class="grid-line" />' -f ([math]::Round($x, 2)), $paddingTop, ([math]::Round($x, 2)), ($height - $paddingBottom)))
        [void]$lines.AppendLine(('<text x="{0}" y="{1}" class="axis-label x-label">OIO {2}</text>' -f ([math]::Round($x, 2)), ($height - 28), $Categories[$categoryIndex]))
    }

    [void]$lines.AppendLine(('<text x="18" y="{0}" class="axis-title">{1}</text>' -f ([math]::Round($paddingTop + ($plotHeight / 2), 2)), $YAxisLabel))

    $legendItems = New-Object System.Text.StringBuilder
    $plotX = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Categories.Count; $i++) {
        $x = if ($Categories.Count -gt 1) { $paddingLeft + ($xStep * $i) } else { $paddingLeft + ($plotWidth / 2) }
        $plotX.Add([double]$x)
    }

    for ($seriesIndex = 0; $seriesIndex -lt $Series.Count; $seriesIndex++) {
        $serie = $Series[$seriesIndex]
        $color = $Colors[$seriesIndex % $Colors.Count]
        $seriePoints = @($serie.Points | Sort-Object -Property OutstandingIo)

        $plotY = New-Object System.Collections.Generic.List[double]
        foreach ($category in $Categories) {
            $matchingPoint = $seriePoints | Where-Object { $_.OutstandingIo -eq $category } | Select-Object -First 1
            if ($matchingPoint) {
                $normalizedY = $paddingTop + (($yMax - [double]$matchingPoint.Value) / $yRange) * $plotHeight
                $plotY.Add([double]$normalizedY)
            }
            else {
                $plotY.Add([double]($paddingTop + $plotHeight))
            }
        }

        $path = ConvertTo-SvgCurvePath -X $plotX.ToArray() -Y $plotY.ToArray()
        [void]$lines.AppendLine(('<path d="{0}" class="series-line" stroke="{1}" />' -f $path, $color))

        for ($pointIndex = 0; $pointIndex -lt $plotX.Count; $pointIndex++) {
            $pointValue = $seriePoints | Where-Object { $_.OutstandingIo -eq $Categories[$pointIndex] } | Select-Object -First 1
            if ($pointValue) {
                [void]$lines.AppendLine(('<circle cx="{0}" cy="{1}" r="4.5" fill="{2}" class="series-point" />' -f ([math]::Round($plotX[$pointIndex], 2)), ([math]::Round($plotY[$pointIndex], 2)), $color))
            }
        }

        [void]$legendItems.AppendLine(('<div class="legend-item"><span class="legend-swatch" style="background:{0}"></span><span>{1}</span></div>' -f $color, $serie.TargetArea))
    }

    [void]$lines.AppendLine('</svg>')
    [void]$lines.AppendLine('<div class="legend">')
    [void]$lines.Append($legendItems.ToString())
    [void]$lines.AppendLine('</div>')
    [void]$lines.AppendLine('</div>')

    return $lines.ToString()
}

function Convert-DiskSpdResultsToHtml {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory = $false)]
        [object[]]$Failures = @(),

        [Parameter(Mandatory = $true)]
        [string]$HtmlFile,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Timestamp,

        [Parameter(Mandatory = $true)]
        [string]$CsvFile,

        [Parameter(Mandatory = $true)]
        [string]$JsonFile
    )

    $Failures = @($Failures)

    $style = @"
<style>
body {
    font-family: Segoe UI, Arial, sans-serif;
    margin: 24px;
    background: #f6f8fb;
    color: #1f2937;
}
h1, h2 {
    color: #0f172a;
}
.chart-grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 24px;
    margin-bottom: 24px;
}
.summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 16px;
    margin: 0 0 24px 0;
}
.summary-card {
    background: linear-gradient(180deg, #ffffff 0%, #f9fbfd 100%);
    border: 1px solid #dbe2ea;
    border-radius: 16px;
    padding: 18px;
    box-shadow: 0 10px 24px rgba(15, 23, 42, 0.06);
}
.summary-card strong {
    display: block;
    margin-bottom: 8px;
    font-size: 1rem;
}
.summary-card p {
    margin: 0;
    color: #334155;
    line-height: 1.45;
}
.summary-good {
    border-left: 6px solid #0f766e;
}
.summary-bad {
    border-left: 6px solid #b45309;
}
.chart-card {
    background: linear-gradient(180deg, #ffffff 0%, #f9fbfd 100%);
    border: 1px solid #dbe2ea;
    border-radius: 16px;
    padding: 18px 18px 12px 18px;
    box-shadow: 0 10px 24px rgba(15, 23, 42, 0.06);
}
.chart-card h2 {
    margin: 0 0 6px 0;
}
.chart-subtitle {
    margin: 0 0 10px 0;
    color: #475569;
    font-size: 0.95rem;
}
.chart-svg {
    width: 100%;
    height: auto;
    overflow: visible;
}
.grid-line {
    stroke: #e2e8f0;
    stroke-width: 1;
    shape-rendering: crispEdges;
}
.series-line {
    fill: none;
    stroke-width: 3.5;
    stroke-linecap: round;
    stroke-linejoin: round;
}
.series-point {
    stroke: #ffffff;
    stroke-width: 2;
}
.legend {
    display: flex;
    flex-wrap: wrap;
    gap: 12px 18px;
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid #e2e8f0;
}
.legend-item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 0.95rem;
    color: #334155;
}
.legend-swatch {
    width: 18px;
    height: 4px;
    border-radius: 999px;
    display: inline-block;
}
.axis-label {
    fill: #64748b;
    font-size: 12px;
}
.axis-title {
    fill: #334155;
    font-size: 12px;
    font-weight: 600;
}
.meta {
    margin: 0 0 20px 0;
    padding: 16px;
    background: #ffffff;
    border: 1px solid #dbe2ea;
    border-radius: 8px;
}
table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 24px;
    background: #ffffff;
}
th {
    background: #0f766e;
    color: #ffffff;
    padding: 10px;
    text-align: left;
    position: sticky;
    top: 0;
}
td {
    border-bottom: 1px solid #e5e7eb;
    padding: 8px 10px;
}
tr:nth-child(even) td {
    background: #f8fafc;
}
.warning th {
    background: #b45309;
}
</style>
"@

    $resultRows = $Results |
        Sort-Object -Property TargetArea, Test |
        Select-Object Test, TargetArea, Description, BlockSize, ReadPercent, WritePercent, Random, Threads, OutstandingIo, DurationSeconds, Total_IOPS, Read_IOPS, Write_IOPS, Total_MBps, Read_MBps, Write_MBps, Avg_Latency_ms, Read_Latency_ms, Write_Latency_ms, XmlFile |
        ConvertTo-Html -Fragment -PreContent '<h2>Results</h2>'

    $highlights = Get-DiskSpdResultHighlights -Results $Results
    $bestThroughput = $highlights.BestThroughput
    $worstLatency = $highlights.WorstLatency

    $summarySection = @"
<div class="summary-grid">
<div class="summary-card summary-good">
<strong>Point fort</strong>
<p><b>$($bestThroughput.TargetArea)</b> sur <b>$($bestThroughput.Test)</b> avec <b>$($bestThroughput.Total_MBps)</b> MB/s, <b>$($bestThroughput.Total_IOPS)</b> IOPS et <b>$($bestThroughput.Avg_Latency_ms)</b> ms de latence moyenne.</p>
</div>
<div class="summary-card summary-bad">
<strong>Point faible relatif</strong>
<p><b>$($worstLatency.TargetArea)</b> sur <b>$($worstLatency.Test)</b> avec <b>$($worstLatency.Total_MBps)</b> MB/s et <b>$($worstLatency.Avg_Latency_ms)</b> ms de latence moyenne. C'est le profil à surveiller en priorité.</p>
</div>
</div>
"@

    $outstandingIoCategories = @($Results | Select-Object -ExpandProperty OutstandingIo -Unique | Sort-Object)
    $throughputSeries = Get-DiskSpdChartSeries -Results $Results -ValueProperty 'Total_MBps' -SelectionMode 'max'
    $latencySeries = Get-DiskSpdChartSeries -Results $Results -ValueProperty 'Avg_Latency_ms' -SelectionMode 'min'
    $colors = @('#0f766e', '#2563eb', '#b45309', '#7c3aed', '#dc2626', '#0891b2')

    $chartSection = @"
<div class="chart-grid">
$(New-DiskSpdSvgChart -Title 'Débit maximal observé' -Subtitle 'Pour chaque workload et niveau d''OIO, la courbe retient le meilleur débit entre T1 et T4.' -YAxisLabel 'MB/s' -Categories $outstandingIoCategories -Series $throughputSeries -ValueFormat '{0:N0}' -Colors $colors)
$(New-DiskSpdSvgChart -Title 'Latence moyenne la plus basse' -Subtitle 'Même logique, mais en gardant le point le plus favorable pour lire les zones de confort.' -YAxisLabel 'ms' -Categories $outstandingIoCategories -Series $latencySeries -ValueFormat '{0:N2}' -Colors $colors)
</div>
"@

    $failureRows = if ($Failures.Count -gt 0) {
        ($Failures | ConvertTo-Html -Fragment -PreContent '<h2>Failures</h2>') -replace '<table>', '<table class="warning">'
    }
    else {
        '<h2>Failures</h2><p>No failure recorded.</p>'
    }

    $preContent = @"
<h1>$Title</h1>
<div class="meta">
<p><strong>Generated:</strong> $Timestamp</p>
<p><strong>DiskSpd:</strong> $DiskSpdPath</p>
<p><strong>Test file:</strong> $TestFile</p>
<p><strong>File size:</strong> $FileSize</p>
<p><strong>Duration:</strong> $DurationSeconds s | <strong>Warmup:</strong> $WarmupSeconds s | <strong>Cooldown:</strong> $CooldownSeconds s</p>
<p><strong>Threads:</strong> $($ThreadCounts -join ', ') | <strong>Outstanding IO:</strong> $($OutstandingIoValues -join ', ')</p>
<p><strong>CSV:</strong> $CsvFile</p>
<p><strong>JSON:</strong> $JsonFile</p>
</div>
$summarySection
$chartSection
"@

    try {
        ConvertTo-Html -Title $Title -Head $style -PreContent $preContent -Body @($resultRows, $failureRows) |
            Out-File -FilePath $HtmlFile -Encoding utf8
    }
    catch {
        $fallbackRows = @()

        foreach ($result in $Results) {
            $fallbackRows += [PSCustomObject]@{
                Test = $result.Test
                TargetArea = $result.TargetArea
                Threads = $result.Threads
                OutstandingIo = $result.OutstandingIo
                Total_MBps = $result.Total_MBps
                Avg_Latency_ms = $result.Avg_Latency_ms
            }
        }

        $fallbackBody = @"
<h1>$Title</h1>
<div class="meta">
<p><strong>Generated:</strong> $Timestamp</p>
<p><strong>HTML chart rendering failed, fallback report was generated instead.</strong></p>
</div>
$(($fallbackRows | ConvertTo-Html -Fragment -PreContent '<h2>Results</h2>'))
$(if ($Failures.Count -gt 0) { $Failures | ConvertTo-Html -Fragment -PreContent '<h2>Failures</h2>' } else { '<h2>Failures</h2><p>No failure recorded.</p>' })
"@

        ConvertTo-Html -Title $Title -Head $style -Body $fallbackBody |
            Out-File -FilePath $HtmlFile -Encoding utf8
    }
}

function Invoke-DiskSpdProfile {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Profile,

        [Parameter(Mandatory = $true)]
        [int]$ThreadCount,

        [Parameter(Mandatory = $true)]
        [int]$OutstandingIo,

        [Parameter(Mandatory = $true)]
        [string]$Timestamp
    )

    $testName = '{0}_T{1}_O{2}' -f $Profile.Name, $ThreadCount, $OutstandingIo
    $xmlFile = Join-Path -Path $ResultFolder -ChildPath ($testName + '_' + $Timestamp + '.xml')

    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host (' TEST : {0}' -f $testName) -ForegroundColor Cyan
    Write-Host (' {0}' -f $Profile.Description)
    Write-Host (' Area={0} | Block={1} | Write={2}% | Random={3} | Threads={4} | OIO={5}' -f `
        $Profile.TargetArea,
        $Profile.BlockSize,
        $Profile.WritePercent,
        $Profile.Random,
        $ThreadCount,
        $OutstandingIo)
    Write-Host '====================================================' -ForegroundColor Cyan

    $arguments = @(
        ('-c{0}' -f $FileSize)
        ('-d{0}' -f $DurationSeconds)
        ('-W{0}' -f $WarmupSeconds)
        ('-C{0}' -f $CooldownSeconds)
        ('-b{0}' -f $Profile.BlockSize)
        ('-w{0}' -f $Profile.WritePercent)
        ('-t{0}' -f $ThreadCount)
        ('-o{0}' -f $OutstandingIo)
        '-Rxml'
    )

    if ($MeasureLatency) {
        $arguments += '-L'
    }

    if ($Profile.Random) {
        $arguments += '-r'
    }
    elseif ($ThreadCount -gt 1) {
        $arguments += '-si'
    }

    if ($DisableHardwareCache.IsPresent) {
        $arguments += '-Sh'
    }

    if ($UseLargePages.IsPresent) {
        $arguments += '-l'
    }

    $arguments += $TestFile

    Write-Host 'Lancement DiskSpd...'

    & $DiskSpdPath $arguments | Out-File -FilePath $xmlFile -Encoding utf8

    if ($LASTEXITCODE -ne 0) {
        throw ('DiskSpd exited with code {0} for test {1}.' -f $LASTEXITCODE, $testName)
    }

    [xml]$xml = Get-Content -Path $xmlFile

    if (-not (Test-DiskSpdXmlValue -Value $xml.Results.TimeSpan.TestTimeSeconds)) {
        throw ('DiskSpd XML is missing TestTimeSeconds for test {0}.' -f $testName)
    }

    $testTime = [double]$xml.Results.TimeSpan.TestTimeSeconds

    if ($testTime -le 0) {
        throw ('DiskSpd XML returned a non-positive test duration for test {0}.' -f $testName)
    }

    $stats = Get-DiskSpdTargetStats -Xml $xml
    $latency = $xml.Results.TimeSpan.Latency

    if (-not $latency) {
        $latency = $xml.Results.Latency
    }

    $readLatencyValue = if ($latency) { Get-XmlPropertyValue -Object $latency -PropertyName 'AverageReadMilliseconds' } else { $null }
    $writeLatencyValue = if ($latency) { Get-XmlPropertyValue -Object $latency -PropertyName 'AverageWriteMilliseconds' } else { $null }

    $readLatencyMs = Get-DiskSpdDouble -Value $readLatencyValue
    $writeLatencyMs = Get-DiskSpdDouble -Value $writeLatencyValue

    $readIops = $stats.ReadCount / $testTime
    $writeIops = $stats.WriteCount / $testTime
    $totalIops = $readIops + $writeIops

    $readMBps = ($stats.ReadBytes / $testTime) / 1MB
    $writeMBps = ($stats.WriteBytes / $testTime) / 1MB
    $totalMBps = $readMBps + $writeMBps

    $totalIo = $stats.ReadCount + $stats.WriteCount
    $avgLatencyMs = 0D

    if ($totalIo -gt 0) {
        $avgLatencyMs = (($readLatencyMs * $stats.ReadCount) + ($writeLatencyMs * $stats.WriteCount)) / $totalIo
    }

    return [PSCustomObject]@{
        Test = $testName
        TargetArea = $Profile.TargetArea
        Description = $Profile.Description
        BlockSize = $Profile.BlockSize
        ReadPercent = 100 - $Profile.WritePercent
        WritePercent = $Profile.WritePercent
        Random = $Profile.Random
        Threads = $ThreadCount
        OutstandingIo = $OutstandingIo
        DurationSeconds = [math]::Round($testTime, 2)
        Total_IOPS = [math]::Round($totalIops, 0)
        Read_IOPS = [math]::Round($readIops, 0)
        Write_IOPS = [math]::Round($writeIops, 0)
        Total_MBps = [math]::Round($totalMBps, 2)
        Read_MBps = [math]::Round($readMBps, 2)
        Write_MBps = [math]::Round($writeMBps, 2)
        Avg_Latency_ms = [math]::Round($avgLatencyMs, 3)
        Read_Latency_ms = [math]::Round($readLatencyMs, 3)
        Write_Latency_ms = [math]::Round($writeLatencyMs, 3)
        XmlFile = $xmlFile
    }
}

if (-not (Test-Path -Path $DiskSpdPath)) {
    throw ('DiskSpd executable not found: {0}' -f $DiskSpdPath)
}

$testFolder = Split-Path -Path $TestFile -Parent

if (-not (Test-Path -Path $testFolder)) {
    New-Item -ItemType Directory -Path $testFolder -Force | Out-Null
}

if (-not (Test-Path -Path $ResultFolder)) {
    New-Item -ItemType Directory -Path $ResultFolder -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvFile = Join-Path -Path $ResultFolder -ChildPath ('DiskSpd_SQL_' + $timestamp + '.csv')
$jsonFile = Join-Path -Path $ResultFolder -ChildPath ('DiskSpd_SQL_' + $timestamp + '.json')
$htmlFile = Join-Path -Path $ResultFolder -ChildPath ('DiskSpd_SQL_' + $timestamp + '.html')

$profiles = @(
    (New-DiskSpdProfile -Name '01_DATA_RandomRead_8K' -Description 'SQL Server DATA - random read 8K' -BlockSize '8K' -WritePercent 0 -Random $true -TargetArea 'DATA')
    (New-DiskSpdProfile -Name '02_DATA_OLTP_8K_70R30W' -Description 'SQL Server DATA - OLTP 8K 70 percent read 30 percent write' -BlockSize '8K' -WritePercent 30 -Random $true -TargetArea 'DATA')
    (New-DiskSpdProfile -Name '03_LOG_SequentialWrite_64K' -Description 'SQL Server LOG - sequential write 64K' -BlockSize '64K' -WritePercent 100 -Random $false -TargetArea 'LOG')
)

if (-not $SkipTempDbProfile.IsPresent) {
    $profiles += New-DiskSpdProfile -Name '04_TEMPDB_8K_50R50W' -Description 'SQL Server TEMPDB - random 8K 50 percent read 50 percent write' -BlockSize '8K' -WritePercent 50 -Random $true -TargetArea 'TEMPDB'
}

if (-not $SkipBackupProfiles.IsPresent) {
    $profiles += @(
        (New-DiskSpdProfile -Name '05_BACKUP_SequentialRead_1M' -Description 'SQL Server BACKUP/RESTORE - sequential read 1M' -BlockSize '1M' -WritePercent 0 -Random $false -TargetArea 'BACKUP')
        (New-DiskSpdProfile -Name '06_BACKUP_SequentialWrite_1M' -Description 'SQL Server BACKUP - sequential write 1M' -BlockSize '1M' -WritePercent 100 -Random $false -TargetArea 'BACKUP')
    )
}

$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]

foreach ($profile in $profiles) {
    foreach ($threadCount in $ThreadCounts) {
        foreach ($outstandingIo in $OutstandingIoValues) {
            try {
                $result = Invoke-DiskSpdProfile -Profile $profile -ThreadCount $threadCount -OutstandingIo $outstandingIo -Timestamp $timestamp
                $results.Add($result)
                $result | Format-Table -AutoSize
            }
            catch {
                $failure = [PSCustomObject]@{
                    Test = '{0}_T{1}_O{2}' -f $profile.Name, $threadCount, $outstandingIo
                    Error = $_.Exception.Message
                }

                $failures.Add($failure)
                Write-Host ('ERREUR: {0}' -f $failure.Error) -ForegroundColor Red
            }
        }
    }
}

if ($results.Count -eq 0) {
    throw 'No benchmark result was collected. Check DiskSpd configuration and target storage.'
}

$results |
    Sort-Object -Property TargetArea, Test |
    Export-Csv -Path $csvFile -Delimiter ';' -NoTypeInformation -Encoding UTF8

$results |
    Sort-Object -Property TargetArea, Test |
    ConvertTo-Json -Depth 4 |
    Out-File -FilePath $jsonFile -Encoding utf8

Convert-DiskSpdResultsToHtml -Results $results -Failures $failures -HtmlFile $htmlFile -Title $HtmlTitle -Timestamp $timestamp -CsvFile $csvFile -JsonFile $jsonFile

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host ' TESTS TERMINES' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host ''
Write-Host ('CSV  : {0}' -f $csvFile) -ForegroundColor Yellow
Write-Host ('JSON : {0}' -f $jsonFile) -ForegroundColor Yellow
Write-Host ('HTML : {0}' -f $htmlFile) -ForegroundColor Yellow
Write-Host ''

$results |
    Sort-Object -Property TargetArea, Test |
    Format-Table Test, TargetArea, Threads, OutstandingIo, Total_IOPS, Total_MBps, Avg_Latency_ms, Read_Latency_ms, Write_Latency_ms -AutoSize

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'ECHECS :' -ForegroundColor Yellow
    $failures | Format-Table -AutoSize
}


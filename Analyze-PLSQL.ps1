<#
.SYNOPSIS
    PL/SQL 分析ツール - INSERT/UPDATE文を解析
.DESCRIPTION
    Windows PowerShell 5.1 および PowerShell Core 対応
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$FileName = ""
)

$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$inDir = Join-Path $scriptPath "in"
$outDir = Join-Path $scriptPath "out"
$logDir = Join-Path $scriptPath "log"

foreach ($dir in @($outDir, $logDir)) {
    if (!(Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
}

if ($FileName) {
    $sqlFiles = Get-ChildItem -Path $inDir -Filter $FileName -ErrorAction SilentlyContinue
} else {
    $sqlFiles = Get-ChildItem -Path $inDir -Filter "*.sql" -ErrorAction SilentlyContinue
}

if (!$sqlFiles) {
    Write-Host "SQLファイルが見つかりません。in/ フォルダにファイルを配置してください。" -ForegroundColor Yellow
    exit 1
}

$logFile = Join-Path $logDir ("analyze_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".log")
function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$ts - $msg" -Encoding UTF8
}

function Get-SQLStatements {
    param([string]$Content, [string]$Keyword)

    $statements = @()
    $startPos = 0

    while ($true) {
        $idx = $Content.ToUpper().IndexOf($Keyword.ToUpper(), $startPos)
        if ($idx -lt 0) { break }

        $endPos = $Content.IndexOf(";", $idx)
        if ($endPos -lt 0) { $endPos = $Content.Length - 1 }

        $stmt = $Content.Substring($idx, $endPos - $idx + 1)
        $statements += $stmt
        $startPos = $endPos + 1
    }

    return $statements
}

function Get-TableName {
    param([string]$Statement, [string]$Keyword)

    $upper = $Statement.ToUpper()
    if ($Keyword -eq "INSERT") {
        $idx = $upper.IndexOf("INSERT INTO")
        if ($idx -ge 0) {
            $rest = $Statement.Substring($idx + 11).TrimStart()
            $endIdx = 0
            for ($i = 0; $i -lt $rest.Length; $i++) {
                $c = $rest[$i]
                if ($c -eq ' ' -or $c -eq '(' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r") {
                    $endIdx = $i
                    break
                }
                $endIdx = $i + 1
            }
            return $rest.Substring(0, $endIdx)
        }
    } elseif ($Keyword -eq "UPDATE") {
        $idx = $upper.IndexOf("UPDATE")
        if ($idx -ge 0) {
            $rest = $Statement.Substring($idx + 6).TrimStart()
            $endIdx = 0
            for ($i = 0; $i -lt $rest.Length; $i++) {
                $c = $rest[$i]
                if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r") {
                    $endIdx = $i
                    break
                }
                $endIdx = $i + 1
            }
            return $rest.Substring(0, $endIdx)
        }
    }
    return ""
}

function Get-Columns {
    param([string]$Statement)

    $cols = @()
    $upper = $Statement.ToUpper()
    $intoIdx = $upper.IndexOf("INTO")
    if ($intoIdx -lt 0) { return $cols }

    $lpIdx = $Statement.IndexOf("(", $intoIdx)
    if ($lpIdx -lt 0) { return $cols }

    $depth = 1
    $rpIdx = -1
    for ($i = $lpIdx + 1; $i -lt $Statement.Length; $i++) {
        if ($Statement[$i] -eq '(') { $depth++ }
        elseif ($Statement[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) {
                $rpIdx = $i
                break
            }
        }
    }

    if ($rpIdx -gt $lpIdx) {
        $colStr = $Statement.Substring($lpIdx + 1, $rpIdx - $lpIdx - 1)
        $cols = $colStr -split "," | ForEach-Object { $_.Trim() }
    }

    return $cols
}

function Get-ValueSource {
    param([string]$Statement)

    $upper = $Statement.ToUpper()
    if ($upper.Contains("VALUES")) {
        return "直接値指定"
    } elseif ($upper.Contains("SELECT")) {
        return "SELECT文から取得"
    }
    return "不明"
}

function Get-SourceTables {
    param([string]$Statement)

    $tables = @()
    $upper = $Statement.ToUpper()

    $fromIdx = 0
    while ($true) {
        $idx = $upper.IndexOf("FROM ", $fromIdx)
        if ($idx -lt 0) { break }

        $rest = $Statement.Substring($idx + 5).TrimStart()
        $endIdx = 0
        for ($i = 0; $i -lt $rest.Length; $i++) {
            $c = $rest[$i]
            if ($c -eq ' ' -or $c -eq ',' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r" -or $c -eq '(') {
                $endIdx = $i
                break
            }
            $endIdx = $i + 1
        }
        $tbl = $rest.Substring(0, $endIdx)
        if ($tbl -and $tbl.ToUpper() -ne "DUAL") {
            $tables += $tbl
        }
        $fromIdx = $idx + 5
    }

    $joinIdx = 0
    while ($true) {
        $idx = $upper.IndexOf("JOIN ", $joinIdx)
        if ($idx -lt 0) { break }

        $rest = $Statement.Substring($idx + 5).TrimStart()
        $endIdx = 0
        for ($i = 0; $i -lt $rest.Length; $i++) {
            $c = $rest[$i]
            if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r") {
                $endIdx = $i
                break
            }
            $endIdx = $i + 1
        }
        $tbl = $rest.Substring(0, $endIdx)
        if ($tbl) {
            $tables += $tbl
        }
        $joinIdx = $idx + 5
    }

    return ($tables | Select-Object -Unique)
}

function Get-WhereConditions {
    param([string]$Statement)

    $conditions = @()
    $upper = $Statement.ToUpper()

    $whereIdx = -1
    $depth = 0
    for ($i = 0; $i -lt $Statement.Length; $i++) {
        if ($Statement[$i] -eq '(') { $depth++ }
        elseif ($Statement[$i] -eq ')') { $depth-- }
        elseif ($depth -eq 0 -and $i + 5 -lt $Statement.Length) {
            if ($upper.Substring($i, 6) -eq "WHERE ") {
                $whereIdx = $i
            }
        }
    }

    if ($whereIdx -ge 0) {
        $wherePart = $Statement.Substring($whereIdx + 6)
        $wherePart = $wherePart.TrimEnd(';', ' ')

        $parts = $wherePart -split "\sAND\s"
        foreach ($p in $parts) {
            $trimmed = $p.Trim()
            if ($trimmed) {
                $conditions += $trimmed
            }
        }
    }

    return $conditions
}

function Get-CaseLogic {
    param([string]$Statement)

    $logic = @()
    $upper = $Statement.ToUpper()

    $caseIdx = 0
    while ($true) {
        $idx = $upper.IndexOf("CASE WHEN", $caseIdx)
        if ($idx -lt 0) { break }

        $endIdx = $upper.IndexOf(" END", $idx)
        if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END,", $idx) }
        if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END)", $idx) }
        if ($endIdx -lt 0) { break }

        $caseExpr = $Statement.Substring($idx, $endIdx - $idx + 4)

        $whenIdx = 0
        $caseUpper = $caseExpr.ToUpper()
        while ($true) {
            $wIdx = $caseUpper.IndexOf("WHEN ", $whenIdx)
            if ($wIdx -lt 0) { break }

            $tIdx = $caseUpper.IndexOf(" THEN ", $wIdx)
            if ($tIdx -lt 0) { break }

            $condition = $caseExpr.Substring($wIdx + 5, $tIdx - $wIdx - 5).Trim()

            $valueStart = $tIdx + 6
            $valueEnd = $caseExpr.Length

            $nextWhen = $caseUpper.IndexOf("WHEN ", $valueStart)
            $nextElse = $caseUpper.IndexOf("ELSE ", $valueStart)
            $nextEnd = $caseUpper.IndexOf("END", $valueStart)

            if ($nextWhen -gt 0 -and $nextWhen -lt $valueEnd) { $valueEnd = $nextWhen }
            if ($nextElse -gt 0 -and $nextElse -lt $valueEnd) { $valueEnd = $nextElse }
            if ($nextEnd -gt 0 -and $nextEnd -lt $valueEnd) { $valueEnd = $nextEnd }

            $value = $caseExpr.Substring($valueStart, $valueEnd - $valueStart).Trim()
            $value = $value.Trim("'", " ", ",")

            $logic += @{ Condition = $condition; Value = $value }
            $whenIdx = $tIdx + 6
        }

        $elseIdx = $caseUpper.IndexOf("ELSE ")
        if ($elseIdx -gt 0) {
            $endKeyword = $caseUpper.IndexOf("END", $elseIdx)
            if ($endKeyword -gt $elseIdx) {
                $elseValue = $caseExpr.Substring($elseIdx + 5, $endKeyword - $elseIdx - 5).Trim()
                $elseValue = $elseValue.Trim("'", " ")
                $logic += @{ Condition = "その他"; Value = $elseValue }
            }
        }

        $caseIdx = $endIdx + 3
    }

    return $logic
}

function Get-SetColumns {
    param([string]$Statement)

    $columns = @()
    $upper = $Statement.ToUpper()

    $setIdx = $upper.IndexOf(" SET ")
    if ($setIdx -lt 0) { return $columns }

    $whereIdx = -1
    $depth = 0
    for ($i = $setIdx; $i -lt $Statement.Length; $i++) {
        if ($Statement[$i] -eq '(') { $depth++ }
        elseif ($Statement[$i] -eq ')') { $depth-- }
        elseif ($depth -eq 0 -and $i + 6 -lt $Statement.Length) {
            if ($upper.Substring($i, 6) -eq "WHERE ") {
                $whereIdx = $i
                break
            }
        }
    }

    $setPart = ""
    if ($whereIdx -gt 0) {
        $setPart = $Statement.Substring($setIdx + 5, $whereIdx - $setIdx - 5)
    } else {
        $setPart = $Statement.Substring($setIdx + 5)
    }
    $setPart = $setPart.TrimEnd(';', ' ')

    $items = @()
    $current = ""
    $depth = 0
    foreach ($c in $setPart.ToCharArray()) {
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') { $depth-- }

        if ($c -eq ',' -and $depth -eq 0) {
            if ($current.Trim()) { $items += $current.Trim() }
            $current = ""
        } else {
            $current += $c
        }
    }
    if ($current.Trim()) { $items += $current.Trim() }

    foreach ($item in $items) {
        $eqIdx = $item.IndexOf("=")
        if ($eqIdx -gt 0) {
            $colName = $item.Substring(0, $eqIdx).Trim()
            $colValue = $item.Substring($eqIdx + 1).Trim()

            $hasSubQuery = $colValue.ToUpper().Contains("SELECT")
            $caseLogic = @()
            if ($colValue.ToUpper().Contains("CASE WHEN")) {
                $caseLogic = Get-CaseLogic -Statement $colValue
            }

            $columns += @{
                Column = $colName
                Value = $colValue
                HasSubQuery = $hasSubQuery
                Logic = $caseLogic
            }
        }
    }

    return $columns
}

function Generate-Report {
    param($Inserts, $Updates, $FileName)

    $lines = @()
    $lines += "=" * 80
    $lines += "PL/SQL 解析レポート"
    $lines += "=" * 80
    $lines += ""
    $lines += "ファイル名: $FileName"
    $lines += "解析日時: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += ""
    $lines += "-" * 80
    $lines += "[概要]"
    $lines += "-" * 80
    $lines += "  - INSERT文の数: $($Inserts.Count)"
    $lines += "  - UPDATE文の数: $($Updates.Count)"
    $lines += ""

    $allTables = @()
    foreach ($i in $Inserts) { if ($i.TableName) { $allTables += $i.TableName } }
    foreach ($u in $Updates) { if ($u.TableName) { $allTables += $u.TableName } }
    $allTables = $allTables | Select-Object -Unique

    $lines += "対象テーブル:"
    foreach ($t in $allTables) {
        $lines += "  - $t"
    }
    $lines += ""

    if ($Inserts.Count -gt 0) {
        $lines += "=" * 80
        $lines += "[INSERT文 詳細]"
        $lines += "=" * 80
        $lines += ""

        $num = 1
        foreach ($ins in $Inserts) {
            $lines += "-" * 60
            $lines += "INSERT #$num"
            $lines += "-" * 60
            $lines += ""
            $lines += "対象テーブル: $($ins.TableName)"
            $lines += ""
            $lines += "挿入カラム:"
            foreach ($c in $ins.Columns) {
                $lines += "  - $c"
            }
            $lines += ""
            $lines += "データ取得元: $($ins.ValueSource)"

            if ($ins.SourceTables.Count -gt 0) {
                $lines += ""
                $lines += "参照テーブル:"
                foreach ($t in $ins.SourceTables) {
                    $lines += "  - $t"
                }
            }

            if ($ins.Conditions.Count -gt 0) {
                $lines += ""
                $lines += "抽出条件 (WHERE):"
                foreach ($c in $ins.Conditions) {
                    $lines += "  - $c"
                }
            }

            if ($ins.CaseLogic.Count -gt 0) {
                $lines += ""
                $lines += "条件分岐 (CASE):"
                foreach ($l in $ins.CaseLogic) {
                    $lines += "  - [$($l.Condition)] の場合 -> [$($l.Value)]"
                }
            }

            $lines += ""
            $num++
        }
    }

    if ($Updates.Count -gt 0) {
        $lines += "=" * 80
        $lines += "[UPDATE文 詳細]"
        $lines += "=" * 80
        $lines += ""

        $num = 1
        foreach ($upd in $Updates) {
            $lines += "-" * 60
            $lines += "UPDATE #$num"
            $lines += "-" * 60
            $lines += ""
            $lines += "対象テーブル: $($upd.TableName)"
            $lines += ""
            $lines += "更新カラム:"

            foreach ($col in $upd.SetColumns) {
                $lines += ""
                $lines += "  カラム名: $($col.Column)"
                if ($col.Logic.Count -gt 0) {
                    $lines += "  更新ロジック:"
                    foreach ($l in $col.Logic) {
                        $lines += "    - [$($l.Condition)] の場合 -> [$($l.Value)]"
                    }
                } elseif ($col.HasSubQuery) {
                    $lines += "  新しい値: (サブクエリで計算)"
                } else {
                    $lines += "  新しい値: $($col.Value)"
                }
            }

            if ($upd.Conditions.Count -gt 0) {
                $lines += ""
                $lines += "更新条件 (WHERE):"
                foreach ($c in $upd.Conditions) {
                    $lines += "  - $c"
                }
            }

            $lines += ""
            $num++
        }
    }

    $lines += "=" * 80
    $lines += "レポート終了"
    $lines += "=" * 80

    return ($lines -join "`r`n")
}

# Main
foreach ($sqlFile in $sqlFiles) {
    Write-Host "解析中: $($sqlFile.Name)" -ForegroundColor Cyan
    Write-Log "Start: $($sqlFile.Name)"

    try {
        $content = ""
        try {
            $bytes = [System.IO.File]::ReadAllBytes($sqlFile.FullName)
            $content = [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            $content = Get-Content -Path $sqlFile.FullName -Raw -Encoding Default
        }

        if (!$content) {
            Write-Host "ファイルを読み込めません" -ForegroundColor Red
            continue
        }

        $content = [regex]::Replace($content, "--[^\r\n]*", "")
        $content = [regex]::Replace($content, "/\*[\s\S]*?\*/", "")
        $content = [regex]::Replace($content, "\s+", " ")

        $insertStmts = Get-SQLStatements -Content $content -Keyword "INSERT INTO"
        $inserts = @()
        foreach ($stmt in $insertStmts) {
            $ins = @{
                TableName = Get-TableName -Statement $stmt -Keyword "INSERT"
                Columns = @(Get-Columns -Statement $stmt)
                ValueSource = Get-ValueSource -Statement $stmt
                SourceTables = @(Get-SourceTables -Statement $stmt)
                Conditions = @(Get-WhereConditions -Statement $stmt)
                CaseLogic = @(Get-CaseLogic -Statement $stmt)
            }
            $inserts += $ins
        }

        $updateStmts = Get-SQLStatements -Content $content -Keyword "UPDATE"
        $updates = @()
        foreach ($stmt in $updateStmts) {
            $upd = @{
                TableName = Get-TableName -Statement $stmt -Keyword "UPDATE"
                SetColumns = @(Get-SetColumns -Statement $stmt)
                Conditions = @(Get-WhereConditions -Statement $stmt)
            }
            $updates += $upd
        }

        $report = Generate-Report -Inserts $inserts -Updates $updates -FileName $sqlFile.Name

        $outFile = Join-Path $outDir ($sqlFile.BaseName + "_report.txt")
        [System.IO.File]::WriteAllText($outFile, $report, [System.Text.Encoding]::UTF8)

        Write-Host "完了! 出力先: $outFile" -ForegroundColor Green
        Write-Log "Done: $outFile"

        Write-Host ""
        Write-Host $report

    } catch {
        Write-Host "エラー: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        Write-Log "Error: $_"
    }
}

Write-Host ""
Write-Host "全ての処理が完了しました!" -ForegroundColor Green

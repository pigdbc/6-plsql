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

# 括弧を考慮してカンマで分割
function Split-ByComma {
    param([string]$Text)

    $items = @()
    $current = ""
    $depth = 0

    foreach ($c in $Text.ToCharArray()) {
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

    return $items
}

# VALUES部分の値を取得
function Get-ValuesContent {
    param([string]$Statement)

    $upper = $Statement.ToUpper()
    $valIdx = $upper.IndexOf("VALUES")
    if ($valIdx -lt 0) { return @() }

    # VALUES後の最初の(を探す
    $lpIdx = $Statement.IndexOf("(", $valIdx)
    if ($lpIdx -lt 0) { return @() }

    # 対応する)を探す
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
        $valStr = $Statement.Substring($lpIdx + 1, $rpIdx - $lpIdx - 1)
        return Split-ByComma -Text $valStr
    }

    return @()
}

# SELECT部分の値を取得
function Get-SelectColumns {
    param([string]$Statement)

    $upper = $Statement.ToUpper()
    $selIdx = $upper.IndexOf("SELECT")
    if ($selIdx -lt 0) { return @() }

    $fromIdx = $upper.IndexOf(" FROM ", $selIdx)
    if ($fromIdx -lt 0) { return @() }

    $selPart = $Statement.Substring($selIdx + 6, $fromIdx - $selIdx - 6).Trim()
    return Split-ByComma -Text $selPart
}

# CASE文を解析して説明文字列を生成
function Format-CaseExpression {
    param([string]$Expr)

    $upper = $Expr.ToUpper()
    if (-not $upper.Contains("CASE")) { return $null }

    $result = @()

    $caseIdx = $upper.IndexOf("CASE WHEN")
    if ($caseIdx -lt 0) { return $null }

    $endIdx = $upper.IndexOf(" END", $caseIdx)
    if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END,", $caseIdx) }
    if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END)", $caseIdx) }
    if ($endIdx -lt 0) { return $null }

    $caseExpr = $Expr.Substring($caseIdx, $endIdx - $caseIdx + 4)
    $caseUpper = $caseExpr.ToUpper()

    $whenIdx = 0
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

        $value = $caseExpr.Substring($valueStart, $valueEnd - $valueStart).Trim().Trim("'", " ", ",")

        $result += "[$condition] -> [$value]"
        $whenIdx = $tIdx + 6
    }

    $elseIdx = $caseUpper.IndexOf("ELSE ")
    if ($elseIdx -gt 0) {
        $endKeyword = $caseUpper.IndexOf("END", $elseIdx)
        if ($endKeyword -gt $elseIdx) {
            $elseValue = $caseExpr.Substring($elseIdx + 5, $endKeyword - $elseIdx - 5).Trim().Trim("'", " ")
            $result += "[その他] -> [$elseValue]"
        }
    }

    return $result
}

# 値の説明を生成
function Format-ValueDescription {
    param([string]$Value)

    $val = $Value.Trim()
    $upper = $val.ToUpper()

    # CASE文
    if ($upper.Contains("CASE WHEN")) {
        $caseLines = Format-CaseExpression -Expr $val
        if ($caseLines) {
            return @{ Type = "CASE"; Lines = $caseLines }
        }
    }

    # シーケンス
    if ($upper.Contains(".NEXTVAL")) {
        return @{ Type = "SIMPLE"; Text = "(シーケンス自動採番)" }
    }

    # SYSDATE/SYSTIMESTAMP
    if ($upper -eq "SYSDATE" -or $upper -eq "SYSTIMESTAMP") {
        return @{ Type = "SIMPLE"; Text = "(現在日時)" }
    }

    # NVL
    if ($upper.StartsWith("NVL(")) {
        return @{ Type = "SIMPLE"; Text = $val + " (NULLの場合はデフォルト値)" }
    }

    # 関数呼び出し (SUM, COUNT, AVG, ROUND, TO_CHAR等)
    if ($upper -match "^(SUM|COUNT|AVG|ROUND|TO_CHAR|TRUNC|MAX|MIN)\s*\(") {
        return @{ Type = "SIMPLE"; Text = $val }
    }

    # テーブル.カラム形式
    if ($val -match "^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_\u3000-\u9FFF][a-zA-Z0-9_\u3000-\u9FFF]*$") {
        return @{ Type = "SIMPLE"; Text = $val + " から取得" }
    }

    # 計算式 (例: od.数量 * p.単価)
    if ($val -match "\*|\+|\-|\/") {
        return @{ Type = "SIMPLE"; Text = $val + " (計算)" }
    }

    # 文字列リテラル
    if ($val.StartsWith("'") -and $val.EndsWith("'")) {
        return @{ Type = "SIMPLE"; Text = "固定値: $val" }
    }

    # 数値リテラル
    if ($val -match "^\d+$") {
        return @{ Type = "SIMPLE"; Text = "固定値: $val" }
    }

    # 変数 (v_で始まる)
    if ($val -match "^v_") {
        return @{ Type = "SIMPLE"; Text = "変数: $val" }
    }

    # エイリアス付きカラム (例: c.顧客ID)
    if ($val -match "^[a-zA-Z]+\..+$") {
        return @{ Type = "SIMPLE"; Text = $val + " から取得" }
    }

    return @{ Type = "SIMPLE"; Text = $val }
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
        # GROUP BYやORDER BYがあればそこまで
        $groupIdx = $wherePart.ToUpper().IndexOf(" GROUP BY")
        $orderIdx = $wherePart.ToUpper().IndexOf(" ORDER BY")
        if ($groupIdx -gt 0) { $wherePart = $wherePart.Substring(0, $groupIdx) }
        if ($orderIdx -gt 0) { $wherePart = $wherePart.Substring(0, $orderIdx) }
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

    $items = Split-ByComma -Text $setPart

    foreach ($item in $items) {
        $eqIdx = $item.IndexOf("=")
        if ($eqIdx -gt 0) {
            $colName = $item.Substring(0, $eqIdx).Trim()
            $colValue = $item.Substring($eqIdx + 1).Trim()

            $valueDesc = Format-ValueDescription -Value $colValue

            $columns += @{
                Column = $colName
                Value = $colValue
                ValueDesc = $valueDesc
            }
        }
    }

    return $columns
}

# INSERT文を解析
function Parse-InsertStatement {
    param([string]$Statement)

    $columns = Get-Columns -Statement $Statement
    $upper = $Statement.ToUpper()

    $columnDetails = @()

    if ($upper.Contains("VALUES")) {
        $values = Get-ValuesContent -Statement $Statement
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $col = $columns[$i]
            $val = if ($i -lt $values.Count) { $values[$i] } else { "" }
            $valueDesc = Format-ValueDescription -Value $val

            $columnDetails += @{
                Column = $col
                Value = $val
                ValueDesc = $valueDesc
            }
        }
    } elseif ($upper.Contains("SELECT")) {
        $selectCols = Get-SelectColumns -Statement $Statement
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $col = $columns[$i]
            $val = if ($i -lt $selectCols.Count) { $selectCols[$i] } else { "" }
            $valueDesc = Format-ValueDescription -Value $val

            $columnDetails += @{
                Column = $col
                Value = $val
                ValueDesc = $valueDesc
            }
        }
    }

    return @{
        TableName = Get-TableName -Statement $Statement -Keyword "INSERT"
        ColumnDetails = $columnDetails
        ValueSource = Get-ValueSource -Statement $Statement
        SourceTables = @(Get-SourceTables -Statement $Statement)
        Conditions = @(Get-WhereConditions -Statement $Statement)
    }
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
            $lines += "データ取得元: $($ins.ValueSource)"

            if ($ins.SourceTables.Count -gt 0) {
                $lines += "参照テーブル: " + ($ins.SourceTables -join ", ")
            }

            if ($ins.Conditions.Count -gt 0) {
                $lines += ""
                $lines += "抽出条件 (WHERE):"
                foreach ($c in $ins.Conditions) {
                    $lines += "  - $c"
                }
            }

            $lines += ""
            $lines += "カラム詳細:"
            $lines += ""

            foreach ($col in $ins.ColumnDetails) {
                $lines += "  [$($col.Column)]"
                if ($col.ValueDesc.Type -eq "CASE") {
                    $lines += "    条件分岐:"
                    foreach ($caseLine in $col.ValueDesc.Lines) {
                        $lines += "      $caseLine"
                    }
                } else {
                    $lines += "    <- $($col.ValueDesc.Text)"
                }
                $lines += ""
            }

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

            if ($upd.Conditions.Count -gt 0) {
                $lines += ""
                $lines += "更新条件 (WHERE):"
                foreach ($c in $upd.Conditions) {
                    $lines += "  - $c"
                }
            }

            $lines += ""
            $lines += "更新カラム:"
            $lines += ""

            foreach ($col in $upd.SetColumns) {
                $lines += "  [$($col.Column)]"
                if ($col.ValueDesc.Type -eq "CASE") {
                    $lines += "    条件分岐:"
                    foreach ($caseLine in $col.ValueDesc.Lines) {
                        $lines += "      $caseLine"
                    }
                } else {
                    $lines += "    <- $($col.ValueDesc.Text)"
                }
                $lines += ""
            }

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
        $bytes = [System.IO.File]::ReadAllBytes($sqlFile.FullName)

        # SJIS (Shift-JIS / cp932) を優先的に試す
        $sjis = [System.Text.Encoding]::GetEncoding(932)
        $utf8 = [System.Text.Encoding]::UTF8

        # UTF-8 BOMチェック
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $content = $utf8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            # SJISとして読み込む（日本語Windows環境）
            $content = $sjis.GetString($bytes)
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
            $ins = Parse-InsertStatement -Statement $stmt
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

        # 出力ファイル（UTF-8 BOM付きで保存 - Windowsメモ帳対応）
        $outFile = Join-Path $outDir ($sqlFile.BaseName + "_report.txt")
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($outFile, $report, $utf8Bom)

        Write-Host "完了! 出力先: $outFile" -ForegroundColor Green
        Write-Log "Done: $outFile"

        # コンソール出力（SJISで出力）
        Write-Host ""
        $sjisOut = [System.Text.Encoding]::GetEncoding(932)
        [Console]::OutputEncoding = $sjisOut
        Write-Host $report

    } catch {
        Write-Host "エラー: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        Write-Log "Error: $_"
    }
}

Write-Host ""
Write-Host "全ての処理が完了しました!" -ForegroundColor Green

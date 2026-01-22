<#
.SYNOPSIS
    PL/SQL 分析ツール - INSERT/UPDATE文を解析（変数追跡機能付き）
.DESCRIPTION
    Windows PowerShell 5.1 および PowerShell Core 対応
    SJIS/UTF-8 両対応
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

# グローバル変数マップ（変数名 -> 値/ソース情報）
$script:VariableMap = @{}
$script:VariableHistory = @{}

function Set-VariableEntry {
    param([string]$VarName, [hashtable]$Entry)

    $key = $VarName.ToUpper()
    if ($script:VariableMap.ContainsKey($key)) {
        $existing = $script:VariableMap[$key]
        if ($existing.Index -gt $Entry.Index) { return }
    }

    $script:VariableMap[$key] = $Entry
}

# 変数代入を解析（:= 形式）
function Parse-Assignments {
    param([string]$Content)

    $script:VariableMap = @{}
    $script:VariableHistory = @{}
    $conditionalAssignIndex = @{}

    # IF文内の代入を探す（条件付き代入、日本語変数名対応）
    # (?<!ELS)IF でELSIFを除外
    $ifPattern = "(?<!ELS)IF\s+([^;]+?)\s+THEN\s+(\S+)\s*:=\s*([^;]+);"
    $ifMatches = [regex]::Matches($Content, $ifPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

    # ELSIF/ELSE内の代入（日本語変数名対応）
    $elsifPattern = "ELSIF\s+(.+?)\s+THEN\s+(\S+)\s*:=\s*([^;]+);"
    $elsifMatches = [regex]::Matches($Content, $elsifPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $elsePattern = "ELSE\s+(\S+)\s*:=\s*([^;]+);"
    $elseMatches = [regex]::Matches($Content, $elsePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $ifMatches) {
        $conditionalAssignIndex[$m.Groups[2].Index] = $true
    }
    foreach ($m in $elsifMatches) {
        $conditionalAssignIndex[$m.Groups[2].Index] = $true
    }
    foreach ($m in $elseMatches) {
        $conditionalAssignIndex[$m.Groups[1].Index] = $true
    }

    # := 代入を探す（日本語変数名対応）
    $pattern = "(\S+)\s*:=\s*([^;]+);"
    $matches = [regex]::Matches($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $matches) {
        if ($conditionalAssignIndex.ContainsKey($m.Index)) { continue }
        $varName = $m.Groups[1].Value.Trim()
        $varValue = $m.Groups[2].Value.Trim()

        # 変数マップに追加（後の代入で上書き）
        Set-VariableEntry -VarName $varName -Entry @{
            Value = $varValue
            Type = "ASSIGN"
            Index = $m.Index
        }

        # 履歴
        $key = $varName.ToUpper()
        if (-not $script:VariableHistory.ContainsKey($key)) { $script:VariableHistory[$key] = @() }
        $script:VariableHistory[$key] += @{
            Type = "ASSIGN"
            Value = $varValue
            Index = $m.Index
        }
    }

    # SELECT INTO を探す
    $selectIntoPattern = "SELECT\s+(.+?)\s+INTO\s+([^;]+?)\s+FROM"
    $selectMatches = [regex]::Matches($Content, $selectIntoPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

    foreach ($m in $selectMatches) {
        $selectCols = $m.Groups[1].Value.Trim()
        $intoVars = $m.Groups[2].Value.Trim()

        $cols = Split-ByComma -Text $selectCols
        $vars = Split-ByComma -Text $intoVars

        for ($i = 0; $i -lt $vars.Count; $i++) {
            $varName = [string]$vars[$i]
            $varName = $varName.Trim()
            $colValue = if ($i -lt $cols.Count) { [string]$cols[$i] } else { "?" }
            $colValue = $colValue.Trim()

            Set-VariableEntry -VarName $varName -Entry @{
                Value = $colValue
                Type = "SELECT_INTO"
                Index = $m.Index
            }

            $key = $varName.ToUpper()
            if (-not $script:VariableHistory.ContainsKey($key)) { $script:VariableHistory[$key] = @() }
            $script:VariableHistory[$key] += @{
                Type = "SELECT_INTO"
                Value = $colValue
                Index = $m.Index
            }
        }
    }

    foreach ($m in $ifMatches) {
        $condition = $m.Groups[1].Value.Trim()
        $varName = $m.Groups[2].Value.Trim()
        $varValue = $m.Groups[3].Value.Trim()

        $key = $varName.ToUpper()
        if ($script:VariableMap.ContainsKey($key)) {
            $existing = $script:VariableMap[$key]
            if ($existing.Type -eq "CONDITIONAL" -and $existing.Index -le $m.Index) {
                $existing.Conditions += @{ Condition = $condition; Value = $varValue }
            } else {
                $newEntry = @{
                    Type = "CONDITIONAL"
                    Conditions = @(
                        @{ Condition = "DEFAULT"; Value = $existing.Value },
                        @{ Condition = $condition; Value = $varValue }
                    )
                    Index = $m.Index
                }
                Set-VariableEntry -VarName $varName -Entry $newEntry
            }
        } else {
            $newEntry = @{
                Type = "CONDITIONAL"
                Conditions = @(@{ Condition = $condition; Value = $varValue })
                Index = $m.Index
            }
            Set-VariableEntry -VarName $varName -Entry $newEntry
        }

        if (-not $script:VariableHistory.ContainsKey($key)) { $script:VariableHistory[$key] = @() }
        $script:VariableHistory[$key] += @{
            Type = "CONDITIONAL"
            Condition = $condition
            Value = $varValue
            Index = $m.Index
        }
    }

    foreach ($m in $elsifMatches) {
        $condition = $m.Groups[1].Value.Trim()
        $varName = $m.Groups[2].Value.Trim()
        $varValue = $m.Groups[3].Value.Trim()

        $key = $varName.ToUpper()
        if ($script:VariableMap.ContainsKey($key) -and $script:VariableMap[$key].Type -eq "CONDITIONAL" -and $script:VariableMap[$key].Index -le $m.Index) {
            $script:VariableMap[$key].Conditions += @{ Condition = $condition; Value = $varValue }
        }

        if (-not $script:VariableHistory.ContainsKey($key)) { $script:VariableHistory[$key] = @() }
        $script:VariableHistory[$key] += @{
            Type = "CONDITIONAL"
            Condition = $condition
            Value = $varValue
            Index = $m.Index
        }
    }

    foreach ($m in $elseMatches) {
        $varName = $m.Groups[1].Value.Trim()
        $varValue = $m.Groups[2].Value.Trim()

        $key = $varName.ToUpper()
        if ($script:VariableMap.ContainsKey($key) -and $script:VariableMap[$key].Type -eq "CONDITIONAL" -and $script:VariableMap[$key].Index -le $m.Index) {
            $script:VariableMap[$key].Conditions += @{ Condition = "その他"; Value = $varValue }
        }

        if (-not $script:VariableHistory.ContainsKey($key)) { $script:VariableHistory[$key] = @() }
        $script:VariableHistory[$key] += @{
            Type = "CONDITIONAL"
            Condition = "その他"
            Value = $varValue
            Index = $m.Index
        }
    }
}

# 変数の値チェーンを追跡
function Trace-VariableChain {
    param([string]$VarName, [int]$MaxDepth = 5)

    $chain = @()
    $current = $VarName.ToUpper()
    $visited = @{}
    $depth = 0

    while ($depth -lt $MaxDepth) {
        if ($visited.ContainsKey($current)) { break }
        $visited[$current] = $true

        if (-not $script:VariableMap.ContainsKey($current)) { break }

        $info = $script:VariableMap[$current]

        if ($info.Type -eq "CONDITIONAL") {
            return @{
                Type = "CONDITIONAL"
                VarName = $VarName
                Conditions = $info.Conditions
            }
        }

        $chain += @{
            Var = $current
            Value = $info.Value
            Type = $info.Type
        }

        # 次の変数を探す（日本語変数名対応: v_で始まる変数）
        $nextValue = $info.Value
        if ($nextValue -match "^v_\S+$" -and $nextValue.ToUpper() -ne $current) {
            $current = $nextValue.ToUpper()
        } else {
            break
        }

        $depth++
    }

    if ($chain.Count -eq 0) {
        return $null
    }

    return @{
        Type = "CHAIN"
        Chain = $chain
    }
}

# 変数の完全な説明を生成
function Format-VariableTrace {
    param([string]$VarName)

    $trace = Trace-VariableChain -VarName $VarName

    if ($null -eq $trace) {
        return $null
    }

    if ($trace.Type -eq "CONDITIONAL") {
        $lines = Expand-ConditionalLines -VarName $VarName -TargetVar $VarName -PrefixCond "" -Visited @{}
        return @{ Type = "CONDITIONAL"; Lines = $lines }
    }

    if ($trace.Type -eq "CHAIN" -and $trace.Chain.Count -gt 0) {
        $chainText = Convert-ChainToText -Chain $trace.Chain
        return @{ Type = "CHAIN"; Text = $chainText }
    }

    return $null
}

function Get-ValueTraceText {
    param([string]$Value, [string]$TargetVar)

    $val = $Value.Trim()

    if ($val -match "^v_\S+$") {
        $subTrace = Trace-VariableChain -VarName $val
        if ($subTrace) {
            if ($subTrace.Type -eq "CHAIN") {
                $subText = Convert-ChainToText -Chain $subTrace.Chain
                return $subText
            }
            if ($subTrace.Type -eq "CONDITIONAL") {
                return "条件分岐"
            }
        }
        return $val
    }

    $varsInExpr = Get-VariablesInText -Text $val
    if ($varsInExpr.Count -gt 0) {
        $exprText = Get-ExpressionTraceText -Expr $val
        return $exprText
    }

    return (Format-ValueForTrace -Value $val)
}

function Format-ValueForTrace {
    param([string]$Value)

    $val = $Value.Trim()
    $upper = $val.ToUpper()

    if ($upper -eq "NULL") { return "NULL" }
    if ($val.StartsWith("'") -and $val.EndsWith("'")) { return $val }
    if ($val -match "^-?\d+(\.\d+)?$") { return $val }
    if ($val -match "^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_\u3000-\u9FFF][a-zA-Z0-9_\u3000-\u9FFF]*$") { return $val }

    $varsInExpr = Get-VariablesInText -Text $val
    if ($varsInExpr.Count -gt 0) {
        return Get-ExpressionTraceText -Expr $val
    }

    return $val
}

function Get-VariablesInText {
    param([string]$Text)

    $vars = @()
    $matches = [regex]::Matches($Text, "v_[^\s,\)\+\-\*\/]+", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches) {
        $vars += $m.Value
    }

    return ($vars | Select-Object -Unique)
}

function Get-OriginTextForVar {
    param([string]$VarName, [hashtable]$Visited)

    if (-not $Visited) { $Visited = @{} }
    $key = $VarName.ToUpper()
    if ($Visited.ContainsKey($key)) {
        return "前回値"
    }
    $Visited[$key] = $true

    $trace = Trace-VariableChain -VarName $VarName
    if (-not $trace) { return "未定義" }

    if ($trace.Type -eq "CHAIN") {
        $first = $trace.Chain[0]
        if ($first -and $first.Value -and ($first.Value.ToUpper().Contains($VarName.ToUpper()))) {
            return "前回値"
        }
        return Convert-ChainToText -Chain $trace.Chain
    }
    if ($trace.Type -eq "CONDITIONAL") {
        return "条件分岐"
    }

    return "不明"
}

function Get-ExpressionTraceText {
    param([string]$Expr)

    $vars = Get-VariablesInText -Text $Expr
    if ($vars.Count -eq 0) {
        return "式: $Expr"
    }

    $replaced = $Expr
    $visited = @{}
    foreach ($v in $vars) {
        $origin = Get-OriginTextForVar -VarName $v -Visited $visited
        $replaced = [regex]::Replace($replaced, "\b$([regex]::Escape($v))\b", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $origin })
    }

    return "式: $replaced"
}

function Copy-Visited {
    param([hashtable]$Visited)

    $copy = @{}
    foreach ($k in $Visited.Keys) {
        $copy[$k] = $true
    }
    return $copy
}

function Expand-ConditionalLines {
    param(
        [string]$VarName,
        [string]$TargetVar,
        [string]$PrefixCond,
        [hashtable]$Visited
    )

    $lines = @()
    $key = $VarName.ToUpper()
    if ($Visited.ContainsKey($key)) {
        if ($PrefixCond) {
            $lines += "[$PrefixCond] -> 循環参照"
        } else {
            $lines += "循環参照"
        }
        return $lines
    }
    $Visited[$key] = $true

    $trace = Trace-VariableChain -VarName $VarName
    if (-not $trace) {
        if ($PrefixCond) {
            $lines += "[$PrefixCond] -> 未定義"
        } else {
            $lines += "未定義"
        }
        return $lines
    }

    if ($trace.Type -ne "CONDITIONAL") {
        $text = Get-ValueTraceText -Value $VarName -TargetVar $TargetVar
        if ($PrefixCond) {
            $lines += "[$PrefixCond] -> $text"
        } else {
            $lines += $text
        }
        return $lines
    }

    foreach ($cond in $trace.Conditions) {
        $condText = $cond.Condition.Trim()
        $combined = if ($PrefixCond) { "$PrefixCond AND $condText" } else { $condText }
        $condVal = $cond.Value.Trim()

        if ($condVal -match "^v_\S+$") {
            $subTrace = Trace-VariableChain -VarName $condVal
            if ($subTrace -and $subTrace.Type -eq "CONDITIONAL") {
                $subVisited = Copy-Visited -Visited $Visited
                $lines += Expand-ConditionalLines -VarName $condVal -TargetVar $TargetVar -PrefixCond $combined -Visited $subVisited
                continue
            }
        }

        $lines += "[$combined] -> " + (Get-ValueTraceText -Value $condVal -TargetVar $TargetVar)
    }

    return $lines
}

function Convert-ChainToText {
    param($Chain)

    if (-not $Chain -or $Chain.Count -eq 0) { return "" }

    $parts = @()
    $lastValue = $Chain[-1].Value
    $parts += (Format-ValueForTrace -Value $lastValue)

    return ($parts -join " ")
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

function Get-ValuesContent {
    param([string]$Statement)

    $upper = $Statement.ToUpper()
    $valIdx = $upper.IndexOf("VALUES")
    if ($valIdx -lt 0) { return @() }

    $lpIdx = $Statement.IndexOf("(", $valIdx)
    if ($lpIdx -lt 0) { return @() }

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

        # 値が変数の場合は追跡（条件分岐は多層展開）
        $valueDisplay = $value
        $handled = $false
        if ($value -match "^v_\S+$") {
            $trace = Trace-VariableChain -VarName $value
            if ($trace) {
                if ($trace.Type -eq "CHAIN") {
                    $valueDisplay = Convert-ChainToText -Chain $trace.Chain
                } elseif ($trace.Type -eq "CONDITIONAL") {
                    $condLines = Expand-ConditionalLines -VarName $value -TargetVar $value -PrefixCond "" -Visited @{}
                    foreach ($cl in $condLines) {
                        $result += "[$condition] / $cl"
                    }
                    $handled = $true
                }
            }
        }

        if (-not $handled) {
            $result += "[$condition] -> $valueDisplay"
        }
        $whenIdx = $tIdx + 6
    }

    $elseIdx = $caseUpper.IndexOf("ELSE ")
    if ($elseIdx -gt 0) {
        $endKeyword = $caseUpper.IndexOf("END", $elseIdx)
        if ($endKeyword -gt $elseIdx) {
            $elseValue = $caseExpr.Substring($elseIdx + 5, $endKeyword - $elseIdx - 5).Trim().Trim("'", " ")

            $valueDisplay = $elseValue
            $handled = $false
            if ($elseValue -match "^v_\S+$") {
                $trace = Trace-VariableChain -VarName $elseValue
                if ($trace) {
                    if ($trace.Type -eq "CHAIN") {
                        $valueDisplay = Convert-ChainToText -Chain $trace.Chain
                    } elseif ($trace.Type -eq "CONDITIONAL") {
                        $condLines = Expand-ConditionalLines -VarName $elseValue -TargetVar $elseValue -PrefixCond "" -Visited @{}
                        foreach ($cl in $condLines) {
                            $result += "[その他] / $cl"
                        }
                        $handled = $true
                    }
                }
            }

            if (-not $handled) {
                $result += "[その他] -> $valueDisplay"
            }
        }
    }

    return $result
}

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

    # 変数 (v_で始まる)
    if ($val -match "^v_\S+$") {
        $trace = Format-VariableTrace -VarName $val
        if ($trace) {
            if ($trace.Type -eq "CHAIN") {
                return @{ Type = "SIMPLE"; Text = $trace.Text }
            } elseif ($trace.Type -eq "CONDITIONAL") {
                return @{ Type = "CASE"; Lines = $trace.Lines }
            }
        }
        return @{ Type = "SIMPLE"; Text = "変数: $val (未定義)" }
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
        # NVL内の変数も追跡
        if ($val -match "NVL\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)") {
            $nvlVar = $Matches[1].Trim()
            $nvlDefault = $Matches[2].Trim()

            if ($nvlVar -match "^v_\S+$") {
                $trace = Format-VariableTrace -VarName $nvlVar
                if ($trace -and $trace.Type -eq "CHAIN") {
                    return @{ Type = "SIMPLE"; Text = "$($trace.Text) (NULLなら $nvlDefault)" }
                }
            }
        }
        return @{ Type = "SIMPLE"; Text = "$val (NULLの場合はデフォルト値)" }
    }

    $varsInExpr = Get-VariablesInText -Text $val
    if ($varsInExpr.Count -gt 0) {
        return @{ Type = "SIMPLE"; Text = (Get-ExpressionTraceText -Expr $val) }
    }

    # 関数呼び出し
    if ($upper -match "^(SUM|COUNT|AVG|ROUND|TO_CHAR|TRUNC|MAX|MIN)\s*\(") {
        return @{ Type = "SIMPLE"; Text = $val }
    }

    # テーブル.カラム形式
    if ($val -match "^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_\u3000-\u9FFF][a-zA-Z0-9_\u3000-\u9FFF]*$") {
        return @{ Type = "SIMPLE"; Text = $val + " から取得" }
    }

    # 計算式
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

    # エイリアス付きカラム
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

function Get-AliasMap {
    param([string]$Statement)

    $map = @{}
    $pattern = "(?i)\b(FROM|JOIN)\s+([^\s\(\),]+)\s+([^\s\(\),]+)"
    $matches = [regex]::Matches($Statement, $pattern)
    $skip = @("ON","WHERE","INNER","LEFT","RIGHT","FULL","CROSS","JOIN","GROUP","ORDER","USING")

    foreach ($m in $matches) {
        $table = $m.Groups[2].Value.Trim()
        $alias = $m.Groups[3].Value.Trim()
        if (-not $alias) { continue }
        if ($skip -contains $alias.ToUpper()) { continue }
        $map[$alias] = $table
    }

    return $map
}

function Replace-AliasInText {
    param([string]$Text, [hashtable]$AliasMap)

    if (-not $AliasMap -or $AliasMap.Count -eq 0) { return $Text }
    $result = $Text
    foreach ($alias in $AliasMap.Keys) {
        $table = $AliasMap[$alias]
        $result = [regex]::Replace($result, "\b$([regex]::Escape($alias))\.", "$table.")
    }
    return $result
}

function Replace-VariablesInText {
    param([string]$Text)

    $vars = Get-VariablesInText -Text $Text
    if ($vars.Count -eq 0) { return $Text }

    $result = $Text
    $visited = @{}
    foreach ($v in $vars) {
        $origin = Get-OriginTextForVar -VarName $v -Visited $visited
        $result = [regex]::Replace($result, "\b$([regex]::Escape($v))\b", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $origin })
    }

    return $result
}

function Get-WhereConditions {
    param([string]$Statement, [hashtable]$AliasMap = $null)

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
        $groupIdx = $wherePart.ToUpper().IndexOf(" GROUP BY")
        $orderIdx = $wherePart.ToUpper().IndexOf(" ORDER BY")
        if ($groupIdx -gt 0) { $wherePart = $wherePart.Substring(0, $groupIdx) }
        if ($orderIdx -gt 0) { $wherePart = $wherePart.Substring(0, $orderIdx) }
        $wherePart = $wherePart.TrimEnd(';', ' ')

        $parts = $wherePart -split "\sAND\s"
        foreach ($p in $parts) {
            $trimmed = $p.Trim()
            if ($trimmed) {
                $text = Replace-AliasInText -Text $trimmed -AliasMap $AliasMap
                $text = Replace-VariablesInText -Text $text
                $conditions += $text
            }
        }
    }

    return $conditions
}

function Get-SetColumns {
    param([string]$Statement, [hashtable]$AliasMap = $null)

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
            $colValue = Replace-AliasInText -Text $colValue -AliasMap $AliasMap
            $colValue = Replace-VariablesInText -Text $colValue

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

function Parse-InsertStatement {
    param([string]$Statement)

    $columns = Get-Columns -Statement $Statement
    $upper = $Statement.ToUpper()
    $aliasMap = Get-AliasMap -Statement $Statement

    $columnDetails = @()

    if ($upper.Contains("VALUES")) {
        $values = Get-ValuesContent -Statement $Statement
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $col = $columns[$i]
            $val = if ($i -lt $values.Count) { $values[$i] } else { "" }
            $val = Replace-AliasInText -Text $val -AliasMap $aliasMap
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
            $val = Replace-AliasInText -Text $val -AliasMap $aliasMap
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
        Conditions = @(Get-WhereConditions -Statement $Statement -AliasMap $aliasMap)
    }
}

function Generate-Report {
    param($Inserts, $Updates, $FileName, $VariableCount)

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
    $lines += "  - 検出した変数代入: $VariableCount 件"
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

        $sjis = [System.Text.Encoding]::GetEncoding(932)
        $utf8 = [System.Text.Encoding]::UTF8

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            # UTF-8 with BOM
            $content = $utf8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            # Try UTF-8 first (check for invalid sequences)
            $isValidUtf8 = $true
            try {
                $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                $content = $utf8Strict.GetString($bytes)
            } catch {
                $isValidUtf8 = $false
            }

            if (-not $isValidUtf8) {
                # Fall back to SJIS
                $content = $sjis.GetString($bytes)
            }
        }

        if (!$content) {
            Write-Host "ファイルを読み込めません" -ForegroundColor Red
            continue
        }

        # 変数代入を先に解析
        Parse-Assignments -Content $content

        # コメント削除
        $contentClean = [regex]::Replace($content, "--[^\r\n]*", "")
        $contentClean = [regex]::Replace($contentClean, "/\*[\s\S]*?\*/", "")
        $contentClean = [regex]::Replace($contentClean, "\s+", " ")

        $insertStmts = Get-SQLStatements -Content $contentClean -Keyword "INSERT INTO"
        $inserts = @()
        foreach ($stmt in $insertStmts) {
            $ins = Parse-InsertStatement -Statement $stmt
            $inserts += $ins
        }

        $updateStmts = Get-SQLStatements -Content $contentClean -Keyword "UPDATE"
        $updates = @()
        foreach ($stmt in $updateStmts) {
            $aliasMap = Get-AliasMap -Statement $stmt
            $upd = @{
                TableName = Get-TableName -Statement $stmt -Keyword "UPDATE"
                SetColumns = @(Get-SetColumns -Statement $stmt -AliasMap $aliasMap)
                Conditions = @(Get-WhereConditions -Statement $stmt -AliasMap $aliasMap)
            }
            $updates += $upd
        }

        $report = Generate-Report -Inserts $inserts -Updates $updates -FileName $sqlFile.Name -VariableCount $script:VariableMap.Count

        $outFile = Join-Path $outDir ($sqlFile.BaseName + "_report.txt")
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($outFile, $report, $utf8Bom)

        Write-Host "完了! 出力先: $outFile" -ForegroundColor Green
        Write-Log "Done: $outFile"

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

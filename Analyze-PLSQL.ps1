<#
.SYNOPSIS
    PL/SQL 分析工具 - 分析日语SQL代码中的INSERT和UPDATE操作
.DESCRIPTION
    兼容 Windows PowerShell 5.1 和 PowerShell Core
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$FileName = ""
)

# 设置编码
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$inDir = Join-Path $scriptPath "in"
$outDir = Join-Path $scriptPath "out"
$logDir = Join-Path $scriptPath "log"

# 确保目录存在
foreach ($dir in @($outDir, $logDir)) {
    if (!(Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
}

# 获取SQL文件
if ($FileName) {
    $sqlFiles = Get-ChildItem -Path $inDir -Filter $FileName -ErrorAction SilentlyContinue
} else {
    $sqlFiles = Get-ChildItem -Path $inDir -Filter "*.sql" -ErrorAction SilentlyContinue
}

if (!$sqlFiles) {
    Write-Host "未找到SQL文件。请将.sql文件放入 in/ 目录。" -ForegroundColor Yellow
    exit 1
}

# 日志
$logFile = Join-Path $logDir ("analyze_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".log")
function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$ts - $msg" -Encoding UTF8
}

# 提取语句（处理分号结尾）
function Get-SQLStatements {
    param([string]$Content, [string]$Keyword)

    $statements = @()
    $pattern = "$Keyword\s+"
    $startPos = 0

    while ($true) {
        $idx = $Content.ToUpper().IndexOf($Keyword.ToUpper(), $startPos)
        if ($idx -lt 0) { break }

        # 找分号
        $endPos = $Content.IndexOf(";", $idx)
        if ($endPos -lt 0) { $endPos = $Content.Length - 1 }

        $stmt = $Content.Substring($idx, $endPos - $idx + 1)
        $statements += $stmt
        $startPos = $endPos + 1
    }

    return $statements
}

# 提取表名
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

# 提取括号内列名
function Get-Columns {
    param([string]$Statement)

    $cols = @()
    $upper = $Statement.ToUpper()
    $intoIdx = $upper.IndexOf("INTO")
    if ($intoIdx -lt 0) { return $cols }

    # 找第一个左括号
    $lpIdx = $Statement.IndexOf("(", $intoIdx)
    if ($lpIdx -lt 0) { return $cols }

    # 找匹配的右括号
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

# 判断数据来源
function Get-ValueSource {
    param([string]$Statement)

    $upper = $Statement.ToUpper()
    if ($upper.Contains("VALUES")) {
        return "直接指定值"
    } elseif ($upper.Contains("SELECT")) {
        return "从其他表查询"
    }
    return "未知"
}

# 提取FROM表
function Get-SourceTables {
    param([string]$Statement)

    $tables = @()
    $upper = $Statement.ToUpper()

    # 找FROM
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

    # 找JOIN
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

# 提取WHERE条件
function Get-WhereConditions {
    param([string]$Statement)

    $conditions = @()
    $upper = $Statement.ToUpper()

    # 找最后一个顶级WHERE
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
        # 移除末尾分号
        $wherePart = $wherePart.TrimEnd(';', ' ')

        # 按AND分割（简单处理）
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

# 提取CASE逻辑
function Get-CaseLogic {
    param([string]$Statement)

    $logic = @()
    $upper = $Statement.ToUpper()

    $caseIdx = 0
    while ($true) {
        $idx = $upper.IndexOf("CASE WHEN", $caseIdx)
        if ($idx -lt 0) { break }

        # 找END
        $endIdx = $upper.IndexOf(" END", $idx)
        if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END,", $idx) }
        if ($endIdx -lt 0) { $endIdx = $upper.IndexOf("END)", $idx) }
        if ($endIdx -lt 0) { break }

        $caseExpr = $Statement.Substring($idx, $endIdx - $idx + 4)

        # 提取WHEN...THEN
        $whenIdx = 0
        $caseUpper = $caseExpr.ToUpper()
        while ($true) {
            $wIdx = $caseUpper.IndexOf("WHEN ", $whenIdx)
            if ($wIdx -lt 0) { break }

            $tIdx = $caseUpper.IndexOf(" THEN ", $wIdx)
            if ($tIdx -lt 0) { break }

            $condition = $caseExpr.Substring($wIdx + 5, $tIdx - $wIdx - 5).Trim()

            # 找值（到下一个WHEN或ELSE或END）
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

        # 提取ELSE
        $elseIdx = $caseUpper.IndexOf("ELSE ")
        if ($elseIdx -gt 0) {
            $endKeyword = $caseUpper.IndexOf("END", $elseIdx)
            if ($endKeyword -gt $elseIdx) {
                $elseValue = $caseExpr.Substring($elseIdx + 5, $endKeyword - $elseIdx - 5).Trim()
                $elseValue = $elseValue.Trim("'", " ")
                $logic += @{ Condition = "其他情况"; Value = $elseValue }
            }
        }

        $caseIdx = $endIdx + 3
    }

    return $logic
}

# 提取SET列
function Get-SetColumns {
    param([string]$Statement)

    $columns = @()
    $upper = $Statement.ToUpper()

    $setIdx = $upper.IndexOf(" SET ")
    if ($setIdx -lt 0) { return $columns }

    # 找顶级WHERE
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

    # 按逗号分割（考虑括号）
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

# 生成报告
function Generate-Report {
    param($Inserts, $Updates, $FileName)

    $lines = @()
    $lines += "=" * 80
    $lines += "PL/SQL 代码分析报告"
    $lines += "=" * 80
    $lines += ""
    $lines += "文件名: $FileName"
    $lines += "分析时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += ""
    $lines += "-" * 80
    $lines += "【概要】"
    $lines += "-" * 80
    $lines += "  - INSERT 操作数: $($Inserts.Count)"
    $lines += "  - UPDATE 操作数: $($Updates.Count)"
    $lines += ""

    # 所有表
    $allTables = @()
    foreach ($i in $Inserts) { if ($i.TableName) { $allTables += $i.TableName } }
    foreach ($u in $Updates) { if ($u.TableName) { $allTables += $u.TableName } }
    $allTables = $allTables | Select-Object -Unique

    $lines += "涉及的表:"
    foreach ($t in $allTables) {
        $lines += "  - $t"
    }
    $lines += ""

    # INSERT详细
    if ($Inserts.Count -gt 0) {
        $lines += "=" * 80
        $lines += "【INSERT 操作详细】"
        $lines += "=" * 80
        $lines += ""

        $num = 1
        foreach ($ins in $Inserts) {
            $lines += "-" * 60
            $lines += "INSERT #$num"
            $lines += "-" * 60
            $lines += ""
            $lines += "目标表: $($ins.TableName)"
            $lines += ""
            $lines += "插入的列:"
            foreach ($c in $ins.Columns) {
                $lines += "  - $c"
            }
            $lines += ""
            $lines += "数据来源: $($ins.ValueSource)"

            if ($ins.SourceTables.Count -gt 0) {
                $lines += ""
                $lines += "数据来源表:"
                foreach ($t in $ins.SourceTables) {
                    $lines += "  - $t"
                }
            }

            if ($ins.Conditions.Count -gt 0) {
                $lines += ""
                $lines += "筛选条件 (WHERE):"
                foreach ($c in $ins.Conditions) {
                    $lines += "  - $c"
                }
            }

            if ($ins.CaseLogic.Count -gt 0) {
                $lines += ""
                $lines += "条件逻辑 (CASE):"
                foreach ($l in $ins.CaseLogic) {
                    $lines += "  - 当 [$($l.Condition)] 时 -> 值为 [$($l.Value)]"
                }
            }

            $lines += ""
            $num++
        }
    }

    # UPDATE详细
    if ($Updates.Count -gt 0) {
        $lines += "=" * 80
        $lines += "【UPDATE 操作详细】"
        $lines += "=" * 80
        $lines += ""

        $num = 1
        foreach ($upd in $Updates) {
            $lines += "-" * 60
            $lines += "UPDATE #$num"
            $lines += "-" * 60
            $lines += ""
            $lines += "目标表: $($upd.TableName)"
            $lines += ""
            $lines += "更新的列:"

            foreach ($col in $upd.SetColumns) {
                $lines += ""
                $lines += "  列名: $($col.Column)"
                if ($col.Logic.Count -gt 0) {
                    $lines += "  更新逻辑:"
                    foreach ($l in $col.Logic) {
                        $lines += "    - 当 [$($l.Condition)] 时 -> 值为 [$($l.Value)]"
                    }
                } elseif ($col.HasSubQuery) {
                    $lines += "  新值: (基于子查询计算)"
                } else {
                    $lines += "  新值: $($col.Value)"
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
    $lines += "报告结束"
    $lines += "=" * 80

    return ($lines -join "`r`n")
}

# 主处理
foreach ($sqlFile in $sqlFiles) {
    Write-Host "正在分析: $($sqlFile.Name)" -ForegroundColor Cyan
    Write-Log "开始分析: $($sqlFile.Name)"

    try {
        # 读取文件
        $content = ""
        try {
            $bytes = [System.IO.File]::ReadAllBytes($sqlFile.FullName)
            # 尝试UTF8
            $content = [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            $content = Get-Content -Path $sqlFile.FullName -Raw -Encoding Default
        }

        if (!$content) {
            Write-Host "无法读取文件" -ForegroundColor Red
            continue
        }

        # 移除注释
        # 单行注释
        $content = [regex]::Replace($content, "--[^\r\n]*", "")
        # 多行注释
        $content = [regex]::Replace($content, "/\*[\s\S]*?\*/", "")
        # 规范化空白
        $content = [regex]::Replace($content, "\s+", " ")

        # 提取INSERT
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

        # 提取UPDATE
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

        # 生成报告
        $report = Generate-Report -Inserts $inserts -Updates $updates -FileName $sqlFile.Name

        # 保存
        $outFile = Join-Path $outDir ($sqlFile.BaseName + "_分析报告.txt")
        [System.IO.File]::WriteAllText($outFile, $report, [System.Text.Encoding]::UTF8)

        Write-Host "分析完成! 报告保存到: $outFile" -ForegroundColor Green
        Write-Log "完成: $outFile"

        Write-Host ""
        Write-Host $report

    } catch {
        Write-Host "错误: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        Write-Log "错误: $_"
    }
}

Write-Host ""
Write-Host "全部处理完成!" -ForegroundColor Green

# ============================================
# PL/SQL 分析工具
# 用于分析日语PL/SQL文件中的INSERT和UPDATE操作
# ============================================

param(
    [Parameter(Mandatory=$false)]
    [string]$FileName = ""
)

$ErrorActionPreference = "Stop"
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$inDir = Join-Path $scriptPath "in"
$outDir = Join-Path $scriptPath "out"
$logDir = Join-Path $scriptPath "log"

# 确保输出目录存在
@($outDir, $logDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# 获取要处理的文件
if ($FileName) {
    $sqlFiles = @(Get-ChildItem -Path $inDir -Filter $FileName -ErrorAction SilentlyContinue)
} else {
    $sqlFiles = @(Get-ChildItem -Path $inDir -Filter "*.sql" -ErrorAction SilentlyContinue)
}

if ($sqlFiles.Count -eq 0) {
    Write-Host "未找到SQL文件。请将.sql文件放入 in/ 目录。" -ForegroundColor Yellow
    exit 1
}

# 日志函数
$logFile = Join-Path $logDir "analyze_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

# 解析INSERT语句
function Parse-InsertStatement {
    param([string]$Statement)

    $result = @{
        TableName = ""
        Columns = @()
        ValueSource = ""
        Conditions = @()
        CaseLogic = @()
    }

    # 提取表名 - 支持 INSERT INTO schema.table 格式
    if ($Statement -match "INSERT\s+INTO\s+([^\s(]+)") {
        $result.TableName = $Matches[1]
    }

    # 提取列名
    if ($Statement -match "INSERT\s+INTO\s+[^\s(]+\s*\(([^)]+)\)") {
        $columnsPart = $Matches[1]
        $result.Columns = $columnsPart -split "," | ForEach-Object { $_.Trim() }
    }

    # 判断是VALUES还是SELECT
    if ($Statement -match "VALUES\s*\(") {
        $result.ValueSource = "直接指定值"

        # 提取VALUES部分
        if ($Statement -match "VALUES\s*\((.+)\)\s*;?\s*$") {
            $valuesPart = $Matches[1]
            # 解析CASE语句
            $caseMatches = [regex]::Matches($valuesPart, "CASE\s+WHEN\s+(.+?)\s+END", [System.Text.RegularExpressions.RegexOptions]::Singleline)
            foreach ($case in $caseMatches) {
                $caseContent = $case.Groups[1].Value
                # 提取每个WHEN条件
                $whenMatches = [regex]::Matches($caseContent, "WHEN\s+(.+?)\s+THEN\s+([^\s]+)")
                foreach ($when in $whenMatches) {
                    $result.CaseLogic += @{
                        Condition = $when.Groups[1].Value.Trim()
                        Value = $when.Groups[2].Value.Trim()
                    }
                }
                # 提取ELSE
                if ($caseContent -match "ELSE\s+([^\s]+)") {
                    $result.CaseLogic += @{
                        Condition = "其他情况"
                        Value = $Matches[1].Trim()
                    }
                }
            }
        }
    } elseif ($Statement -match "SELECT") {
        $result.ValueSource = "从其他表查询"

        # 提取FROM子句中的表
        $fromMatches = [regex]::Matches($Statement, "FROM\s+([^\s]+)")
        $joinMatches = [regex]::Matches($Statement, "(?:INNER\s+)?JOIN\s+([^\s]+)")

        $sourceTables = @()
        foreach ($m in $fromMatches) {
            $sourceTables += $m.Groups[1].Value
        }
        foreach ($m in $joinMatches) {
            $sourceTables += $m.Groups[1].Value
        }
        $result.SourceTables = $sourceTables | Select-Object -Unique

        # 提取WHERE条件
        if ($Statement -match "WHERE\s+(.+?)(?:GROUP|ORDER|;|\s*$)") {
            $wherePart = $Matches[1]
            $conditions = $wherePart -split "\s+AND\s+" | ForEach-Object { $_.Trim() }
            $result.Conditions = $conditions
        }

        # 提取CASE逻辑
        $caseMatches = [regex]::Matches($Statement, "CASE\s+WHEN\s+(.+?)\s+END", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        foreach ($case in $caseMatches) {
            $caseContent = $case.Groups[1].Value
            $whenMatches = [regex]::Matches($caseContent, "WHEN\s+(.+?)\s+THEN\s+'?([^']+)'?(?=\s+(?:WHEN|ELSE|END))")
            foreach ($when in $whenMatches) {
                $result.CaseLogic += @{
                    Condition = $when.Groups[1].Value.Trim()
                    Value = $when.Groups[2].Value.Trim()
                }
            }
            if ($caseContent -match "ELSE\s+'?([^']+)'?") {
                $result.CaseLogic += @{
                    Condition = "其他情况"
                    Value = $Matches[1].Trim()
                }
            }
        }
    }

    return $result
}

# 提取平衡括号内的内容
function Get-BalancedContent {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    $depth = 0
    $start = $StartIndex
    $result = ""

    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($char -eq '(') { $depth++ }
        if ($char -eq ')') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($StartIndex, $i - $StartIndex + 1)
            }
        }
    }
    return $Text.Substring($StartIndex)
}

# 智能分割SET子句（考虑括号嵌套）
function Split-SetClause {
    param([string]$SetPart)

    $items = @()
    $currentItem = ""
    $parenDepth = 0

    foreach ($char in $SetPart.ToCharArray()) {
        if ($char -eq '(') { $parenDepth++ }
        if ($char -eq ')') { $parenDepth-- }

        if ($char -eq ',' -and $parenDepth -eq 0) {
            if ($currentItem.Trim()) {
                $items += $currentItem.Trim()
            }
            $currentItem = ""
        } else {
            $currentItem += $char
        }
    }
    if ($currentItem.Trim()) {
        $items += $currentItem.Trim()
    }

    return $items
}

# 简化子查询显示
function Simplify-SubQuery {
    param([string]$Text)

    $result = $Text
    $startIndex = 0

    while (($selectPos = $result.IndexOf("(SELECT", $startIndex)) -ge 0) {
        # 找到匹配的右括号
        $depth = 0
        $endPos = -1

        for ($i = $selectPos; $i -lt $result.Length; $i++) {
            if ($result[$i] -eq '(') { $depth++ }
            if ($result[$i] -eq ')') {
                $depth--
                if ($depth -eq 0) {
                    $endPos = $i
                    break
                }
            }
        }

        if ($endPos -gt $selectPos) {
            $subQuery = $result.Substring($selectPos, $endPos - $selectPos + 1)

            # 提取表名
            if ($subQuery -match "FROM\s+([^\s\)]+)") {
                $tableName = $Matches[1]
                $replacement = "(子查询:从${tableName}获取)"
                $result = $result.Substring(0, $selectPos) + $replacement + $result.Substring($endPos + 1)
                $startIndex = $selectPos + $replacement.Length
            } else {
                $startIndex = $endPos + 1
            }
        } else {
            break
        }
    }

    return $result
}

# 解析CASE表达式
function Parse-CaseExpression {
    param([string]$CaseExpr)

    $logic = @()

    # 匹配 WHEN ... THEN ... 模式
    $whenPattern = "WHEN\s+(.+?)\s+THEN\s+'?([^']+?)'?(?=\s+(?:WHEN|ELSE|END))"
    $whenMatches = [regex]::Matches($CaseExpr, $whenPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    foreach ($when in $whenMatches) {
        $condition = $when.Groups[1].Value.Trim()
        $value = $when.Groups[2].Value.Trim()

        # 简化子查询显示
        $condition = Simplify-SubQuery -Text $condition

        $logic += @{
            Condition = $condition
            Value = $value
        }
    }

    # 提取ELSE
    if ($CaseExpr -match "ELSE\s+'?([^']+?)'?\s*END") {
        $logic += @{
            Condition = "其他情况"
            Value = $Matches[1].Trim()
        }
    }

    return $logic
}

# 解析UPDATE语句
function Parse-UpdateStatement {
    param([string]$Statement)

    $result = @{
        TableName = ""
        SetColumns = @()
        Conditions = @()
        CaseLogic = @()
        SubQueries = @()
    }

    # 提取表名
    if ($Statement -match "UPDATE\s+([^\s]+)") {
        $result.TableName = $Matches[1]
    }

    # 找到最后一个顶级WHERE的位置
    $parenDepth = 0
    $lastWherePos = -1
    $setStartPos = -1

    for ($i = 0; $i -lt $Statement.Length; $i++) {
        $char = $Statement[$i]
        if ($char -eq '(') { $parenDepth++ }
        if ($char -eq ')') { $parenDepth-- }

        if ($parenDepth -eq 0) {
            if ($Statement.Substring($i) -match "^\s*SET\s+" -and $setStartPos -eq -1) {
                $setStartPos = $i
            }
            if ($Statement.Substring($i) -match "^\s*WHERE\s+") {
                $lastWherePos = $i
            }
        }
    }

    # 提取SET部分
    if ($setStartPos -ge 0) {
        $setMatch = [regex]::Match($Statement.Substring($setStartPos), "SET\s+(.+)", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($setMatch.Success) {
            $setPart = $setMatch.Groups[1].Value

            # 如果有顶级WHERE，截取到WHERE之前
            if ($lastWherePos -gt $setStartPos) {
                # 计算SET内容开始位置（SET关键词后的位置）
                $setContentStart = $setStartPos + $setMatch.Groups[1].Index
                $whereOffset = $lastWherePos - $setContentStart
                if ($whereOffset -gt 0 -and $whereOffset -lt $setPart.Length) {
                    $setPart = $setPart.Substring(0, $whereOffset).Trim()
                }
            }

            # 移除末尾分号和可能残留的WHERE
            $setPart = $setPart -replace "\s+WHERE\s*$", ""
            $setPart = $setPart -replace ";\s*$", ""

            # 智能分割SET项
            $setItems = Split-SetClause -SetPart $setPart

            foreach ($item in $setItems) {
                # 只匹配第一个等号
                $eqPos = $item.IndexOf("=")
                if ($eqPos -gt 0) {
                    $colName = $item.Substring(0, $eqPos).Trim()
                    $colValue = $item.Substring($eqPos + 1).Trim()

                    $setInfo = @{
                        Column = $colName
                        Value = $colValue
                        Logic = @()
                        HasSubQuery = $false
                    }

                    # 检查是否包含子查询
                    if ($colValue -match "\(SELECT\s+") {
                        $setInfo.HasSubQuery = $true
                        # 提取子查询信息
                        $subQueryMatches = [regex]::Matches($colValue, "\(SELECT\s+.+?\s+FROM\s+([^\s]+)")
                        foreach ($sq in $subQueryMatches) {
                            $result.SubQueries += $sq.Groups[1].Value
                        }
                    }

                    # 检查是否包含CASE
                    if ($colValue -match "CASE\s+WHEN") {
                        $setInfo.Logic = Parse-CaseExpression -CaseExpr $colValue
                    }

                    $result.SetColumns += $setInfo
                }
            }
        }
    }

    # 提取顶级WHERE条件
    if ($lastWherePos -ge 0) {
        $wherePart = $Statement.Substring($lastWherePos)
        if ($wherePart -match "WHERE\s+(.+?)(?:;|\s*$)") {
            $whereContent = $Matches[1]
            # 简单分割（不在括号内的AND）
            $conditions = @()
            $currentCond = ""
            $parenDepth = 0

            $words = $whereContent -split "\s+"
            for ($i = 0; $i -lt $words.Count; $i++) {
                $word = $words[$i]

                # 计算括号深度
                $parenDepth += ($word.ToCharArray() | Where-Object { $_ -eq '(' }).Count
                $parenDepth -= ($word.ToCharArray() | Where-Object { $_ -eq ')' }).Count

                if ($word -eq "AND" -and $parenDepth -eq 0) {
                    if ($currentCond.Trim()) {
                        $conditions += $currentCond.Trim()
                    }
                    $currentCond = ""
                } else {
                    $currentCond += " $word"
                }
            }
            if ($currentCond.Trim()) {
                $conditions += $currentCond.Trim()
            }

            $result.Conditions = $conditions
        }
    }

    return $result
}

# 生成分析报告
function Generate-Report {
    param(
        [array]$Inserts,
        [array]$Updates,
        [string]$FileName
    )

    $report = @()
    $report += "=" * 80
    $report += "PL/SQL 代码分析报告"
    $report += "=" * 80
    $report += ""
    $report += "文件名: $FileName"
    $report += "分析时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += ""
    $report += "-" * 80
    $report += "【概要】"
    $report += "-" * 80
    $report += "  - INSERT 操作数: $($Inserts.Count)"
    $report += "  - UPDATE 操作数: $($Updates.Count)"
    $report += ""

    # 提取所有涉及的表
    $allTables = @()
    $Inserts | ForEach-Object { $allTables += $_.TableName }
    $Updates | ForEach-Object { $allTables += $_.TableName }
    $allTables = $allTables | Select-Object -Unique

    $report += "涉及的表:"
    foreach ($table in $allTables) {
        $report += "  - $table"
    }
    $report += ""

    # INSERT详细信息
    if ($Inserts.Count -gt 0) {
        $report += "=" * 80
        $report += "【INSERT 操作详细】"
        $report += "=" * 80
        $report += ""

        $insertNum = 1
        foreach ($ins in $Inserts) {
            $report += "-" * 60
            $report += "INSERT #$insertNum"
            $report += "-" * 60
            $report += ""
            $report += "目标表: $($ins.TableName)"
            $report += ""
            $report += "插入的列:"
            foreach ($col in $ins.Columns) {
                $report += "  - $col"
            }
            $report += ""
            $report += "数据来源: $($ins.ValueSource)"

            if ($ins.SourceTables -and $ins.SourceTables.Count -gt 0) {
                $report += ""
                $report += "数据来源表:"
                foreach ($st in $ins.SourceTables) {
                    $report += "  - $st"
                }
            }

            if ($ins.Conditions -and $ins.Conditions.Count -gt 0) {
                $report += ""
                $report += "筛选条件 (WHERE):"
                foreach ($cond in $ins.Conditions) {
                    $report += "  - $cond"
                }
            }

            if ($ins.CaseLogic -and $ins.CaseLogic.Count -gt 0) {
                $report += ""
                $report += "条件逻辑 (CASE):"
                foreach ($logic in $ins.CaseLogic) {
                    $report += "  - 当 [$($logic.Condition)] 时 -> 值为 [$($logic.Value)]"
                }
            }

            $report += ""
            $insertNum++
        }
    }

    # UPDATE详细信息
    if ($Updates.Count -gt 0) {
        $report += "=" * 80
        $report += "【UPDATE 操作详细】"
        $report += "=" * 80
        $report += ""

        $updateNum = 1
        foreach ($upd in $Updates) {
            $report += "-" * 60
            $report += "UPDATE #$updateNum"
            $report += "-" * 60
            $report += ""
            $report += "目标表: $($upd.TableName)"
            $report += ""
            $report += "更新的列:"
            foreach ($setCol in $upd.SetColumns) {
                $report += ""
                $report += "  列名: $($setCol.Column)"
                if ($setCol.Logic -and $setCol.Logic.Count -gt 0) {
                    $report += "  更新逻辑:"
                    foreach ($logic in $setCol.Logic) {
                        $report += "    - 当 [$($logic.Condition)] 时 -> 值为 [$($logic.Value)]"
                    }
                } elseif ($setCol.HasSubQuery) {
                    $report += "  新值: (基于子查询计算)"
                    $report += "  详情: $($setCol.Value -replace '\s+', ' ')"
                } else {
                    $report += "  新值: $($setCol.Value)"
                }
            }

            if ($upd.Conditions -and $upd.Conditions.Count -gt 0) {
                $report += ""
                $report += "更新条件 (WHERE):"
                foreach ($cond in $upd.Conditions) {
                    $report += "  - $cond"
                }
            }

            if ($upd.SubQueries -and $upd.SubQueries.Count -gt 0) {
                $report += ""
                $report += "依赖的子查询表:"
                foreach ($sq in ($upd.SubQueries | Select-Object -Unique)) {
                    $report += "  - $sq"
                }
            }

            $report += ""
            $updateNum++
        }
    }

    $report += "=" * 80
    $report += "报告结束"
    $report += "=" * 80

    return $report -join "`n"
}

# 主处理逻辑
foreach ($sqlFile in $sqlFiles) {
    Write-Host "正在分析: $($sqlFile.Name)" -ForegroundColor Cyan
    Write-Log "开始分析文件: $($sqlFile.Name)"

    try {
        # 读取SQL文件内容
        $content = Get-Content -Path $sqlFile.FullName -Raw -Encoding UTF8

        # 移除注释
        $content = $content -replace "--[^\n]*", ""
        $content = $content -replace "/\*[\s\S]*?\*/", ""

        # 规范化空白
        $content = $content -replace "\s+", " "

        # 提取INSERT语句
        $insertPattern = "INSERT\s+INTO\s+[^;]+;"
        $insertMatches = [regex]::Matches($content, $insertPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $inserts = @()
        foreach ($match in $insertMatches) {
            $parsed = Parse-InsertStatement -Statement $match.Value
            $inserts += $parsed
        }

        # 提取UPDATE语句
        $updatePattern = "UPDATE\s+[^;]+;"
        $updateMatches = [regex]::Matches($content, $updatePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $updates = @()
        foreach ($match in $updateMatches) {
            $parsed = Parse-UpdateStatement -Statement $match.Value
            $updates += $parsed
        }

        # 生成报告
        $report = Generate-Report -Inserts $inserts -Updates $updates -FileName $sqlFile.Name

        # 输出报告文件
        $outputFile = Join-Path $outDir "$($sqlFile.BaseName)_分析报告.txt"
        $report | Out-File -FilePath $outputFile -Encoding UTF8

        Write-Host "分析完成! 报告已保存到: $outputFile" -ForegroundColor Green
        Write-Log "分析完成，输出文件: $outputFile"

        # 在控制台也显示报告
        Write-Host ""
        Write-Host $report

    } catch {
        Write-Host "分析出错: $_" -ForegroundColor Red
        Write-Log "错误: $_"
    }
}

Write-Host ""
Write-Host "全部处理完成!" -ForegroundColor Green

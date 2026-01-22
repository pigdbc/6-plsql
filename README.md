# 6-plsql

PL/SQL 分析工具（PowerShell 5.1 / Core），用于解析 INSERT/UPDATE 语句并追踪值来源（支持 SJIS）。

## 功能概览
- 解析 INSERT/UPDATE
- 追踪变量来源，输出“最终来源”（不显示中间变量名）
- 条件分支（IF/ELSIF/ELSE）会展开全部分支
- JOIN 别名统一替换为表名.字段
- 支持 SJIS/UTF-8 自动识别

## 使用方法
1. 将 SQL 文件放到 `in/` 目录
2. 运行：
   ```powershell
   pwsh -NoProfile -File .\Analyze-PLSQL.ps1
   ```
   或指定文件名：
   ```powershell
   pwsh -NoProfile -File .\Analyze-PLSQL.ps1 -FileName sample.sql
   ```
3. 输出报告在 `out/` 目录

## 输出说明
- INSERT/UPDATE 的每个字段会显示“最终来源”
- 条件分支会列出所有分支
- 变量来源会展开到表字段/固定值/表达式
- 自引用表达式会显示为“前回値”
- 未找到来源时显示“未定義”

## 目录结构
```
6-plsql/
  Analyze-PLSQL.ps1
  in/
  out/
  log/
```

## 备注
- Windows PowerShell 5.1 环境可用
- 日文 SQL（SJIS）可正常解析

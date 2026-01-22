-- ============================================
-- サンプルPL/SQLスクリプト
-- 顧客管理システム データ更新処理
-- ============================================

-- 顧客マスタへの新規登録
INSERT INTO GPRIME.顧客マスタ (
    顧客ID,
    顧客名,
    顧客区分,
    登録日,
    有効フラグ
) VALUES (
    SEQ_顧客ID.NEXTVAL,
    'テスト株式会社',
    CASE
        WHEN v_売上金額 >= 1000000 THEN 'A'
        WHEN v_売上金額 >= 500000 THEN 'B'
        ELSE 'C'
    END,
    SYSDATE,
    1
);

-- 注文データの挿入（別テーブルから取得）
INSERT INTO GPRIME.注文履歴 (
    注文ID,
    顧客ID,
    商品コード,
    数量,
    単価,
    合計金額,
    注文日,
    ステータス
)
SELECT
    SEQ_注文ID.NEXTVAL,
    c.顧客ID,
    p.商品コード,
    od.数量,
    p.単価,
    od.数量 * p.単価,
    SYSDATE,
    CASE
        WHEN od.数量 > 100 THEN '要確認'
        WHEN c.顧客区分 = 'A' THEN '優先処理'
        ELSE '通常'
    END
FROM GPRIME.顧客マスタ c
INNER JOIN GPRIME.注文明細_temp od ON c.顧客ID = od.顧客ID
INNER JOIN GPRIME.商品マスタ p ON od.商品コード = p.商品コード
WHERE c.有効フラグ = 1
  AND od.処理済フラグ = 0
  AND p.販売終了日 IS NULL;

-- 在庫テーブルの更新
UPDATE GPRIME.在庫管理
SET
    在庫数 = 在庫数 - v_出庫数量,
    最終更新日 = SYSDATE,
    更新者ID = v_ユーザID,
    更新区分 = CASE
        WHEN 在庫数 - v_出庫数量 <= 安全在庫数 THEN '要発注'
        WHEN 在庫数 - v_出庫数量 <= 0 THEN '在庫切れ'
        ELSE '正常'
    END
WHERE 商品コード = v_商品コード
  AND 倉庫コード = v_倉庫コード;

-- 売上集計テーブルへの挿入（月次集計）
INSERT INTO GPRIME.売上月次集計 (
    集計年月,
    部門コード,
    売上合計,
    件数,
    平均単価,
    集計区分
)
SELECT
    TO_CHAR(SYSDATE, 'YYYYMM'),
    d.部門コード,
    SUM(s.売上金額),
    COUNT(*),
    ROUND(AVG(s.売上金額), 0),
    CASE
        WHEN SUM(s.売上金額) >= 10000000 THEN '達成'
        WHEN SUM(s.売上金額) >= 5000000 THEN '未達成'
        ELSE '要改善'
    END
FROM GPRIME.売上明細 s
INNER JOIN GPRIME.部門マスタ d ON s.部門コード = d.部門コード
WHERE s.売上日 BETWEEN TRUNC(SYSDATE, 'MM') AND LAST_DAY(SYSDATE)
  AND s.取消フラグ = 0
GROUP BY d.部門コード;

-- ログテーブルへの記録
INSERT INTO GPRIME.処理ログ (
    ログID,
    処理種別,
    処理結果,
    エラーコード,
    処理日時
) VALUES (
    SEQ_ログID.NEXTVAL,
    'バッチ処理',
    CASE WHEN v_エラー件数 = 0 THEN '成功' ELSE '一部失敗' END,
    NVL(v_エラーコード, '0000'),
    SYSTIMESTAMP
);

-- 顧客ランク更新
UPDATE GPRIME.顧客マスタ
SET
    顧客ランク = CASE
        WHEN (SELECT SUM(合計金額) FROM GPRIME.注文履歴 WHERE 顧客ID = GPRIME.顧客マスタ.顧客ID AND 注文日 >= ADD_MONTHS(SYSDATE, -12)) >= 5000000 THEN 'プラチナ'
        WHEN (SELECT SUM(合計金額) FROM GPRIME.注文履歴 WHERE 顧客ID = GPRIME.顧客マスタ.顧客ID AND 注文日 >= ADD_MONTHS(SYSDATE, -12)) >= 1000000 THEN 'ゴールド'
        WHEN (SELECT SUM(合計金額) FROM GPRIME.注文履歴 WHERE 顧客ID = GPRIME.顧客マスタ.顧客ID AND 注文日 >= ADD_MONTHS(SYSDATE, -12)) >= 500000 THEN 'シルバー'
        ELSE 'ブロンズ'
    END,
    ランク更新日 = SYSDATE
WHERE 有効フラグ = 1;

COMMIT;

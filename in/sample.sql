-- ============================================
-- サンプルPL/SQLスクリプト
-- 顧客管理システム データ更新処理
-- ============================================

DECLARE
    v_顧客ID NUMBER;
    v_売上金額 NUMBER;
    v_ステータス VARCHAR2(20);
    v_フラグ NUMBER;
    v_区分コード VARCHAR2(10);
BEGIN
    -- 変数への代入（SELECT INTO）
    SELECT SUM(売上金額), COUNT(*)
    INTO v_売上金額, v_件数
    FROM GPRIME.売上明細
    WHERE 顧客ID = p_顧客ID;

    -- 条件分岐による変数代入
    IF v_売上金額 >= 1000000 THEN
        v_区分コード := 'A';
    ELSIF v_売上金額 >= 500000 THEN
        v_区分コード := 'B';
    ELSE
        v_区分コード := 'C';
    END IF;

    -- 変数から変数への代入
    v_ステータス := v_区分コード;
    v_フラグ := 1;

    -- 固定値の代入
    v_処理結果 := '成功';

    -- 顧客マスタへの新規登録（変数を使用）
    INSERT INTO GPRIME.顧客マスタ (
        顧客ID,
        顧客名,
        顧客区分,
        ステータス,
        有効フラグ,
        登録日
    ) VALUES (
        SEQ_顧客ID.NEXTVAL,
        'テスト株式会社',
        v_区分コード,
        v_ステータス,
        v_フラグ,
        SYSDATE
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

    -- ログテーブルへの記録（変数追跡テスト）
    INSERT INTO GPRIME.処理ログ (
        ログID,
        処理種別,
        処理結果,
        エラーコード,
        処理日時
    ) VALUES (
        SEQ_ログID.NEXTVAL,
        'バッチ処理',
        v_処理結果,
        NVL(v_エラーコード, '0000'),
        SYSTIMESTAMP
    );

    COMMIT;
END;

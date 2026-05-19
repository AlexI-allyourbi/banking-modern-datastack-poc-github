{{
    config(
        materialized='ephemeral'
    )
}}

{#
    Intermediate model: Enrich credit operations with pre-approval data,
    exclude restructured products, and calculate installment numbers.
    
    Converts temp tables #2 through AUX4 from the original stored procedure:
    1. Left join with pre-approved credit (Campanhas..Preaprovados_Nic_Limites_Histo)
    2. Remove restructured products (subfamilies 51, 53, 28, 40, 52 and specific product codes)
    3. Calculate the last installment number via ranking of historical processing dates
#}

{% set posicao = var('posicao') %}

-- Step 1: Enrich with pre-approval data
WITH preapproved AS (
    SELECT
        a.d_produto,
        a.c_produto,
        a.d_situacao,
        a.c_situacao,
        a.dt_processamento,
        a.c_nuc,
        a.c_nic,
        a.num_operacao,
        a.num_operacao_ant,
        a.c_orgao_resp,
        a.vl_emprestimo,
        a.vl_devedor,
        a.dt_ini_incump,
        a.vl_total_util,
        a.num_total_prest,
        a.num_ult_prest,
        a.dt_ult_prest,
        a.prazo_carencia,
        a.prazo_amortiz,
        a.dt_abertura,
        a.dt_vencimento,
        a.c_period_cobr_utiliz,
        a.dt_carregamento,
        a.dt_prim_utilizacao,
        a.dt_prox_prest,
        a.fl_pre_aprov_cred_imediato,
        a.vl_pre_aprov_cred_imediato,
        a.id,
        MAX(b.dt_processamento) AS dt_pre_aprov_cred_imediato

    FROM {{ ref('int_credit_ops_recent') }} AS a
    LEFT JOIN {{ source('campanhas', 'preaprovados_nic_limites_histo') }} AS b
        ON a.c_nic = b.c_nic
        AND a.dt_abertura >= b.dt_processamento
        AND b.c_categoria = 32
        AND b.vl_risco_disponivel > 0

    GROUP BY
        a.d_produto, a.c_produto, a.d_situacao, a.c_situacao, a.dt_processamento,
        a.c_nuc, a.c_nic, a.num_operacao, a.num_operacao_ant, a.c_orgao_resp,
        a.vl_emprestimo, a.vl_devedor, a.dt_ini_incump, a.vl_total_util,
        a.num_total_prest, a.num_ult_prest, a.dt_ult_prest, a.prazo_carencia,
        a.prazo_amortiz, a.dt_abertura, a.dt_vencimento, a.c_period_cobr_utiliz,
        a.dt_carregamento, a.dt_prim_utilizacao, a.dt_prox_prest,
        a.fl_pre_aprov_cred_imediato, a.vl_pre_aprov_cred_imediato, a.id
),

-- Step 2: Remove restructured products
filtered AS (
    SELECT
        a.*,
        -- Nullify pre-approval date when flag is 0
        CASE
            WHEN a.fl_pre_aprov_cred_imediato = 0 THEN NULL
            ELSE a.dt_pre_aprov_cred_imediato
        END AS dt_pre_aprov_cred_imediato_adj
    FROM preapproved AS a
    INNER JOIN {{ source('datamart', 'l_produto_histo') }} AS b
        ON a.c_produto = b.c_produto
        AND b.dt_referencia = '{{ posicao }}'::DATE
    WHERE b.c_subfammis NOT IN (51, 53, 28, 40, 52)
      AND a.c_produto NOT IN (1808, 1873, 1249, 1403, 1809, 1874)
),

-- Step 3: Calculate installment numbers
-- AUX1: First installment date per operation
aux1_first_installment AS (
    SELECT
        a.num_operacao,
        MIN(b.dt_ult_prest) AS dt_ult_prest
    FROM filtered AS a
    INNER JOIN {{ source('datamart', 'operacoes_credito_cp_global_histo') }} AS b
        ON a.num_operacao = b.num_operacao
    WHERE b.dt_ult_prest > '1900-01-01'
    GROUP BY a.num_operacao
),

-- AUX2: Processing dates from first installment onward (month-end boundaries)
aux2_processing_dates AS (
    SELECT
        b.dt_processamento,
        b.dt_abertura,
        a.num_operacao,
        b.c_situacao
    FROM aux1_first_installment AS a
    INNER JOIN {{ source('datamart', 'operacoes_credito_cp_global_histo') }} AS b
        ON a.num_operacao = b.num_operacao
    INNER JOIN {{ source('datamart', 't_dia') }} AS c
        ON b.dt_processamento = c.prox_fim_mes
    WHERE b.dt_processamento >= a.dt_ult_prest
    GROUP BY b.dt_processamento, b.dt_abertura, a.num_operacao, b.c_situacao
),

-- AUX3: Rank processing dates per operation
aux3_ranked AS (
    SELECT
        dt_processamento,
        num_operacao,
        c_situacao,
        RANK() OVER (PARTITION BY num_operacao ORDER BY dt_processamento) AS prim_rank
    FROM aux2_processing_dates
),

-- AUX4: Last installment number per operation
aux4_last_installment AS (
    SELECT
        num_operacao,
        MAX(prim_rank) AS num_ult_prest_calc
    FROM aux3_ranked
    GROUP BY num_operacao
)

-- Final: Join installment calculation back to filtered operations
SELECT
    f.d_produto,
    f.c_produto,
    f.d_situacao,
    f.c_situacao,
    f.dt_processamento,
    f.c_nuc,
    f.c_nic,
    f.num_operacao,
    f.num_operacao_ant,
    f.c_orgao_resp,
    f.vl_emprestimo,
    f.vl_devedor,
    f.dt_ini_incump,
    f.vl_total_util,
    f.num_total_prest,
    COALESCE(aux4.num_ult_prest_calc, f.num_ult_prest) AS num_ult_prest,
    f.dt_ult_prest,
    f.prazo_carencia,
    f.prazo_amortiz,
    f.dt_abertura,
    f.dt_vencimento,
    f.c_period_cobr_utiliz,
    f.dt_carregamento,
    f.dt_prim_utilizacao,
    f.dt_prox_prest,
    f.fl_pre_aprov_cred_imediato,
    f.vl_pre_aprov_cred_imediato,
    f.id,
    f.dt_pre_aprov_cred_imediato_adj AS dt_pre_aprov_cred_imediato

FROM filtered AS f
LEFT JOIN aux4_last_installment AS aux4
    ON f.num_operacao = aux4.num_operacao

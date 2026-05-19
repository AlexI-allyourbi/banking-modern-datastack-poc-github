{{
    config(materialized='ephemeral')
}}

{#
    Intermediate: Active Financial Margin Operations
    
    Replaces: First part of DMKE_TEMP..RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1
    (the initial SELECT INTO + all UPDATEs)
    
    Joins operations margins with:
    - Product lookup (active side: c_grande_rubrica_agr = 1)
    - Current RWA data
    - NUC universe
    
    Then applies fallback RWA from 2 months prior where current is NULL,
    sets defaults where still NULL, and calculates capital allocated.
    
    Consolidates 4 separate UPDATE statements into a single declarative SELECT.
#}

{% set posicao = var('posicao') %}

WITH params AS (
    SELECT taxa_nvl_cap_proprio
    FROM {{ source('dmke_base', 'rentabilidade_be_param') }}
    WHERE dt_processamento = '{{ posicao }}'::DATE
),

-- Step 1: Base join — operations + product + RWA + NUC universe
base_operations AS (
    SELECT
        CAST(TO_CHAR(a.dt_referencia, 'YYYYMM') AS INT)    AS c_mes,
        a.dt_referencia::DATE                                AS dt_referencia,
        d.nif                                                AS num_contribuinte,
        a.c_nic,
        a.c_nuc,
        CASE
            WHEN b.c_produto = 80001804 THEN b.c_produto
            WHEN b.c_produto = 500101   THEN b.c_produto
            ELSE a.c_produto
        END                                                  AS c_produto,
        a.num_operacao,
        a.c_moeda,
        a.vl_saldo_medio,
        a.vl_margem,
        CAST(NULL AS DECIMAL(15,2))                          AS vl_margem_passiva,
        CAST(NULL AS DECIMAL(15,2))                          AS vl_margem_comissoes,
        c.c_mes                                              AS c_mes_rw,
        c.vl_rw,
        c.vl_rw_rent,
        c.vl_rwa,
        c.vl_imparidade

    FROM {{ ref('stg_operations_margins') }} AS a
    INNER JOIN {{ source('datamart', 'l_produto') }} AS b
        ON a.c_produto = CASE
            WHEN b.c_produto = 80001804 THEN 1804
            WHEN b.c_produto = 500101   THEN 6867
            ELSE b.c_produto
        END
        AND b.c_grande_rubrica_agr = 1
    LEFT JOIN {{ ref('stg_rwa_current') }} AS c
        ON a.dt_referencia = c.dt_processamento
        AND CAST(a.num_operacao AS VARCHAR(50)) = c.num_operacao
        AND b.c_produto = c.c_produto
        AND a.c_nic = c.c_nic
        AND RIGHT(c.key_dgr, 1) <> 'f'
        AND a.chave = c.chave
    INNER JOIN {{ ref('stg_nuc_universe') }} AS d
        ON a.c_nuc = d.c_nuc

    WHERE a.c_nuc NOT IN (999999999, 0)
      AND a.c_nuc IS NOT NULL
      AND (
          (a.vl_margem <> 0)
          OR (a.c_aplicacao = 'GARANTIAS' AND a.vl_saldo_medio <> 0)
          OR (a.c_aplicacao = 'ESTRANG'   AND a.vl_saldo_medio <> 0)
      )
      AND a.dt_referencia = '{{ posicao }}'::DATE
),

-- Step 2: Apply fallback RWA from 2 months prior where current is NULL
with_fallback_rwa AS (
    SELECT
        a.c_mes,
        a.dt_referencia,
        a.num_contribuinte,
        a.c_nic,
        a.c_nuc,
        a.c_produto,
        a.num_operacao,
        a.c_moeda,
        a.vl_saldo_medio,
        a.vl_margem,
        a.vl_margem_passiva,
        a.vl_margem_comissoes,
        COALESCE(a.c_mes_rw,      fb.c_mes_rw)      AS c_mes_rw,
        COALESCE(a.vl_rw,         fb.vl_rw)          AS vl_rw,
        COALESCE(a.vl_rw_rent,    fb.vl_rw_rent)     AS vl_rw_rent,
        COALESCE(a.vl_rwa,        fb.vl_rwa)         AS vl_rwa,
        COALESCE(a.vl_imparidade, fb.vl_imparidade)  AS vl_imparidade

    FROM base_operations AS a
    LEFT JOIN {{ ref('stg_rwa_2months_prior') }} AS fb
        ON a.c_produto = fb.c_produto
        AND a.num_operacao = fb.num_operacao
        AND a.vl_rw_rent IS NULL
),

-- Step 3: Apply defaults where RWA is still NULL + calculate capital allocated
final_active AS (
    SELECT
        a.c_mes,
        a.dt_referencia,
        a.num_contribuinte,
        a.c_nic,
        a.c_nuc,
        a.c_produto,
        a.num_operacao,
        a.c_moeda,
        a.vl_saldo_medio,
        a.vl_margem,
        a.vl_margem_passiva,
        a.vl_margem_comissoes,
        -- Capital allocated calculation
        CASE
            WHEN a.c_produto = 1804 THEN 0
            ELSE (
                (a.vl_saldo_medio * p.taxa_nvl_cap_proprio * COALESCE(a.vl_rw_rent, 1))
                / 360
            ) * DAY(EOMONTH('{{ posicao }}'::DATE))
        END                                                  AS vl_capital_afecto,
        COALESCE(a.c_mes_rw, 190001)                         AS c_mes_rw,
        a.vl_rw,
        COALESCE(a.vl_rw_rent, 1)                            AS vl_rw_rent,
        a.vl_rwa,
        a.vl_imparidade

    FROM with_fallback_rwa AS a
    CROSS JOIN params AS p
)

SELECT
    c_mes,
    dt_referencia,
    num_contribuinte,
    c_nic,
    c_nuc,
    c_produto,
    num_operacao,
    c_moeda,
    vl_saldo_medio,
    vl_margem,
    vl_margem_passiva,
    vl_margem_comissoes,
    vl_capital_afecto,
    c_mes_rw,
    vl_rw,
    vl_rw_rent,
    vl_rwa,
    vl_imparidade

FROM final_active

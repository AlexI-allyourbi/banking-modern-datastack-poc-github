{{
    config(
        materialized='incremental',
        unique_key=['dt_processamento', 'c_nuc', 'c_produto'],
        incremental_strategy='delete+insert'
    )
}}

{#
    Fact: BE Profitability (Rentabilidade BE)
    
    Replaces: DELETE + INSERT INTO DMKE_BASE..RENTABILIDADE_BE_HISTO
    
    Aggregates all three margin components (active, passive, commissions)
    by (date, month, NUC, product) into a single profitability record.
    
    Original SP: RENTAB005_CALCULA_RENTABILIDADE_BE
#}

{% set posicao = var('posicao') %}

WITH all_operations AS (
    -- Active financial margins (with RWA + capital allocated)
    SELECT * FROM {{ ref('int_active_margin_operations') }}
    UNION ALL
    -- Passive financial margins
    SELECT * FROM {{ ref('int_passive_margin_operations') }}
    UNION ALL
    -- Commission revenues
    SELECT * FROM {{ ref('int_commission_operations') }}
),

validated AS (
    SELECT a.*
    FROM all_operations AS a
    INNER JOIN {{ ref('stg_nuc_universe') }} AS b
        ON a.c_nuc = b.c_nuc
    INNER JOIN {{ source('datamart', 'l_produto') }} AS c
        ON a.c_produto = c.c_produto
)

SELECT
    dt_referencia                                   AS dt_processamento,
    c_mes                                           AS cod_anomes,
    c_nuc                                           AS nuc,
    c_produto                                       AS cod_produto,
    SUM(COALESCE(vl_margem, 0))                     AS mrg_fin_act,
    SUM(COALESCE(vl_margem_passiva, 0))             AS mrg_fin_pass,
    SUM(COALESCE(vl_margem_comissoes, 0))           AS mrg_comissao,
    SUM(COALESCE(vl_capital_afecto, 0))             AS cpa,
    CAST(NULL AS VARCHAR)                           AS origem_info

FROM validated
GROUP BY
    c_mes,
    dt_referencia,
    c_nuc,
    c_produto

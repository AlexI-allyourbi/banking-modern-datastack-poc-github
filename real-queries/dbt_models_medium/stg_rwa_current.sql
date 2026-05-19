{{
    config(materialized='ephemeral')
}}

{#
    Staging: Current RWA (Risk-Weighted Assets) History
    
    Replaces: DMKE_TEMP..RENTAB005_D_RENTABILIDADE_RWA_HISTO
    
    Gets the most recent RWA data up to the reporting date.
    Deduplicates with ROW_NUMBER and fixes operation codes for product 500101.
#}

{% set posicao = var('posicao') %}

WITH max_dt AS (
    SELECT MAX(dt_processamento) AS dt_processamento
    FROM {{ source('dmke_base', 'rentabilidade_be_rwa_histo') }}
    WHERE dt_processamento <= '{{ posicao }}'::DATE
),

rwa_raw AS (
    SELECT
        a.*,
        ROW_NUMBER() OVER (
            PARTITION BY a.dt_processamento, a.num_operacao, a.c_produto, a.c_nic
            ORDER BY a.vl_oper DESC
        ) AS chave
    FROM {{ source('datamart', 'rentabilidade_be_rwa_histo') }} AS a
    INNER JOIN max_dt AS b
        ON a.dt_processamento = b.dt_processamento
)

SELECT
    dt_processamento,
    c_mes,
    -- Fix operation code: strip '500101' prefix for product 500101
    CASE
        WHEN c_produto = '500101'
        THEN REPLACE(num_operacao, '500101', '')
        ELSE num_operacao
    END AS num_operacao,
    c_produto,
    c_nic,
    vl_oper,
    vl_rw,
    vl_rw_rent,
    vl_rwa,
    vl_imparidade,
    key_dgr,
    chave

FROM rwa_raw

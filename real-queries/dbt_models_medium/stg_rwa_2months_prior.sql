{{
    config(materialized='ephemeral')
}}

{#
    Staging: RWA from 2 Months Prior (Fallback)
    
    Replaces: DMKE_TEMP..RENTAB005_D_RENTABILIDADE_RWA_2MESES_ANT
    
    Used as a fallback when current-period RWA data is missing for an operation.
    Fixes operation codes for product 500101.
#}

{% set posicao = var('posicao') %}

SELECT DISTINCT
    c_mes,
    -- Fix operation code: strip '500101' prefix for product 500101
    CASE
        WHEN c_produto = '500101'
        THEN REPLACE(num_operacao, '500101', '')
        ELSE num_operacao
    END AS num_operacao,
    c_produto,
    c_mes       AS c_mes_rw,
    vl_rw,
    vl_rw_rent,
    vl_rwa,
    vl_imparidade

FROM {{ source('datamart', 'rentabilidade_be_rwa_histo') }}
WHERE dt_processamento = EOMONTH(DATEADD(MONTH, -2, '{{ posicao }}'::DATE))
  AND RIGHT(key_dgr, 1) <> 'f'
  AND vl_rw IS NOT NULL
  AND num_operacao IS NOT NULL
  AND c_produto IS NOT NULL

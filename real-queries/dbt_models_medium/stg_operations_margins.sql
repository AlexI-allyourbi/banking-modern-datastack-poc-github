{{
    config(materialized='ephemeral')
}}

{#
    Staging: Operations Margins with Dedup Key
    
    Replaces: DMKE_TEMP..RENTAB005_D_OPERACOES_MARGENS
    
    Gets operations margins for the reporting date.
    Adds a deduplication key (CHAVE) for product 6867 specifically,
    using ROW_NUMBER partitioned by (date, operation, product, NIC).
#}

{% set posicao = var('posicao') %}

SELECT
    a.*,
    CASE
        WHEN a.c_produto = 6867
        THEN ROW_NUMBER() OVER (
            PARTITION BY a.dt_referencia, a.num_operacao, a.c_produto, a.c_nic
            ORDER BY a.vl_saldo_fim_periodo DESC, a.vl_saldo_medio DESC
        )
        ELSE 1
    END AS chave

FROM {{ source('datamart', 'operacoes_margens_histo') }} AS a
WHERE a.dt_referencia = '{{ posicao }}'::DATE

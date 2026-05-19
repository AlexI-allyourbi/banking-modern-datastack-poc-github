{{
    config(materialized='ephemeral')
}}

{#
    Intermediate: Commission Operations
    
    Replaces: The third INSERT INTO DMKE_TEMP..RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1
    (commissions from COMISSOES_CONSOLIDADA_HISTO)
    
    These are fee/commission revenues attributed to each NUC and product.
#}

{% set posicao = var('posicao') %}

SELECT
    a.c_mes,
    EOMONTH(a.dt_processamento)                          AS dt_referencia,
    CAST(NULL AS VARCHAR)                                AS num_contribuinte,
    CAST(NULL AS INT)                                    AS c_nic,
    a.c_nuc,
    a.c_produto,
    CAST(NULL AS VARCHAR)                                AS num_operacao,
    CAST(NULL AS VARCHAR)                                AS c_moeda,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_saldo_medio,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_margem,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_margem_passiva,
    a.vl_comissao                                        AS vl_margem_comissoes,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_capital_afecto,
    CAST(NULL AS INT)                                    AS c_mes_rw,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rw,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rw_rent,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rwa,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_imparidade

FROM {{ source('dmke_base', 'comissoes_consolidada_histo') }} AS a
INNER JOIN {{ source('dmke_base', 'comissoes_l_itens') }} AS b
    ON a.c_item = b.c_item
INNER JOIN {{ ref('stg_nuc_universe') }} AS c
    ON a.c_nuc = c.c_nuc

WHERE a.dt_processamento = '{{ posicao }}'::DATE

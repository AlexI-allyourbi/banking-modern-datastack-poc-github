{{
    config(materialized='ephemeral')
}}

{#
    Intermediate: Passive Financial Margin Operations
    
    Replaces: The second INSERT INTO DMKE_TEMP..RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1
    (passive margins where c_grande_rubrica_agr = 2)
    
    These are liability-side operations (deposits, funding) that contribute
    passive financial margin to the profitability calculation.
#}

{% set posicao = var('posicao') %}

SELECT
    CAST(TO_CHAR(a.dt_referencia, 'YYYYMM') AS INT)    AS c_mes,
    a.dt_referencia::DATE                                AS dt_referencia,
    d.nif                                                AS num_contribuinte,
    a.c_nic,
    a.c_nuc,
    a.c_produto,
    a.num_operacao,
    a.c_moeda,
    a.vl_saldo_medio,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_margem,
    a.vl_margem                                          AS vl_margem_passiva,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_margem_comissoes,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_capital_afecto,
    CAST(NULL AS INT)                                    AS c_mes_rw,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rw,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rw_rent,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_rwa,
    CAST(NULL AS DECIMAL(15,2))                          AS vl_imparidade

FROM {{ ref('stg_operations_margins') }} AS a
INNER JOIN {{ source('datamart', 'l_produto') }} AS i
    ON a.c_produto = i.c_produto
    AND i.c_grande_rubrica_agr = 2
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

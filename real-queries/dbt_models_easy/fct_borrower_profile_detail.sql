{{
    config(
        materialized='incremental',
        unique_key=['c_indicador', 'dt_processamento', 'num_operacao'],
        incremental_strategy='delete+insert'
    )
}}

{#
    Fact model: Borrower Profile Failure — Detail Level
    
    Indicator 2 (RO 231): "Falha na avaliação do perfil do mutuário"
    Measures operations contracted in last 6 months that are now in 
    Mora (delinquency) or Contencioso (litigation), enriched with 
    organizational hierarchy (branch, area, region, network).
    
    Replaces: INSERT INTO GOBK_ICN_F_Valores_Detalhe_HISTO
    Original SP: GOBK_ICN_11_IND_Falha_Perfil_Mutuario
#}

{% set posicao = var('posicao') %}
{% set c_indicador = 2 %}

SELECT
    t6.c_trim                           AS c_periodo,
    t1.dt_processamento,
    t5.c_rede,
    t5.d_rede,
    t4.c_regiao,
    t4.d_regiao,
    t3.c_area,
    t3.d_area,
    t2.c_orgao_resp,
    t2.d_orgao_resp,
    {{ c_indicador }}                   AS c_indicador,
    t1.c_produto,
    t1.d_produto,
    t1.c_situacao,
    t1.d_situacao,
    t1.c_nuc,
    t1.c_nic,
    t1.num_operacao,
    t1.num_operacao_ant,
    t1.vl_emprestimo,
    t1.vl_devedor,
    t1.dt_ini_incump,
    t1.vl_total_util,
    t1.num_total_prest,
    t1.num_ult_prest,
    t1.dt_ult_prest,
    t1.prazo_carencia,
    t1.prazo_amortiz,
    t1.dt_abertura,
    t1.dt_vencimento,
    t1.c_period_cobr_utiliz,
    t1.dt_carregamento,
    t1.dt_prim_utilizacao,
    t1.dt_prox_prest,
    t1.fl_pre_aprov_cred_imediato,
    t1.vl_pre_aprov_cred_imediato,
    t1.id,
    t1.dt_pre_aprov_cred_imediato

FROM {{ ref('int_credit_ops_enriched') }} AS t1
INNER JOIN {{ source('datamart', 'l_orgao') }} AS t2
    ON t2.c_orgao_resp = t1.c_orgao_resp
INNER JOIN {{ source('datamart', 'l_area') }} AS t3
    ON t3.c_area = t2.c_area
INNER JOIN {{ source('datamart', 'l_regiao') }} AS t4
    ON t4.c_regiao = t2.c_regiao
INNER JOIN {{ source('datamart', 'l_rede') }} AS t5
    ON t5.c_rede = t2.c_rede
INNER JOIN {{ source('datamart', 'l_dia') }} AS t6
    ON t6.c_dia = t1.dt_processamento

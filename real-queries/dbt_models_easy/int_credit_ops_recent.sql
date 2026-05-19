{{
    config(
        materialized='ephemeral'
    )
}}

{#
    Intermediate model: Base credit operations opened in the last 6 months.
    
    Converts the first temp table (#TMP_OPERACOES_CREDITO_CP_HISTO) from the 
    original stored procedure. Filters operations by:
    - Opened within 180 days of the reporting date
    - Excludes situation 15 (litigation with agreement, creates new ops)
    - Excludes product codes 1402, 10016 (immediate consumer credit)
#}

{% set posicao = var('posicao') %}

SELECT
    b.d_produto,
    a.c_produto,
    x.d_situacao,
    x.c_situacao,
    a.dt_processamento,
    a.c_nuc,
    a.c_nic,
    a.num_operacao,
    a.num_operacao_ant,
    d.c_orgao_resp,
    a.vl_emprestimo,
    a.vl_devedor,
    a.dt_ini_incump,
    a.vl_total_util,
    a.num_total_prest,
    0                               AS num_ult_prest,
    a.dt_ult_prest,
    a.prazo_carencia,
    a.prazo_amortiz,
    a.dt_abertura,
    a.dt_vencimento,
    a.c_period_cobr_utiliz,
    a.dt_carregamento,
    a.dt_prim_utilizacao,
    a.dt_prox_prest,
    CAST(0 AS SMALLINT)             AS fl_pre_aprov_cred_imediato,
    CAST(NULL AS DECIMAL(13,2))     AS vl_pre_aprov_cred_imediato,
    ROW_NUMBER() OVER (ORDER BY a.num_operacao) AS id

FROM {{ source('datamart', 'operacoes_credito_cp_histo') }} AS a
INNER JOIN {{ source('datamart', 'nuc_histo') }} AS d
    ON a.c_nuc = d.c_nuc
    AND a.dt_processamento = d.dt_processamento
INNER JOIN {{ source('datamart', 'l_produto_histo') }} AS b
    ON a.c_produto = b.c_produto
    AND b.dt_referencia = '{{ posicao }}'::DATE
INNER JOIN {{ source('datamart', 'l_situacao') }} AS x
    ON a.c_situacao = x.c_situacao

WHERE DATEDIFF('day', a.dt_abertura, '{{ posicao }}'::DATE) <= 180
  AND a.dt_processamento = '{{ posicao }}'::DATE
  AND a.c_situacao <> 15
  AND a.c_produto NOT IN (1402, 10016)

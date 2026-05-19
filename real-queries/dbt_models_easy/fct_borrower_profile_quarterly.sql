{{
    config(
        materialized='table'
    )
}}

{#
    Fact model: Borrower Profile Failure — Quarterly Aggregation
    
    Aggregates the monthly indicator values into quarterly summaries.
    Uses AVG for the indicator value (averaging the monthly percentages)
    and SUM for the operation counts.
    
    Replaces: INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Trimestral
    Original SP: GOBK_ICN_11_IND_Falha_Perfil_Mutuario
#}

{% set c_indicador = 2 %}

SELECT
    c_periodo,
    c_nivel,
    c_rede,
    d_rede,
    c_regiao,
    d_regiao,
    c_area,
    d_area,
    c_orgao_resp,
    d_orgao_resp,
    c_indicador,
    SUM(numoper_total)      AS numoper_total,
    SUM(numoper_irreg)      AS numoper_irreg,
    AVG(vl_indicador)       AS vl_indicador

FROM {{ ref('fct_borrower_profile_monthly') }}
WHERE c_indicador = {{ c_indicador }}
GROUP BY
    c_periodo, c_nivel,
    c_rede, d_rede,
    c_regiao, d_regiao,
    c_area, d_area,
    c_orgao_resp, d_orgao_resp,
    c_indicador

ORDER BY c_periodo, c_nivel, c_rede, c_regiao, c_area, c_orgao_resp

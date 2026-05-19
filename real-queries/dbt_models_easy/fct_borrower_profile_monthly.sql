{{
    config(
        materialized='table'
    )
}}

{#
    Fact model: Borrower Profile Failure — Monthly Aggregation
    
    Aggregates the detail records at 4 hierarchical levels:
    - Level 4: Branch (Orgao)
    - Level 3: Area
    - Level 2: Region (Regiao)
    - Level 1: Network (Rede)
    
    Calculates the indicator: (irregular operations / total operations) * 100
    
    Replaces: INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Mensal
    Original SP: GOBK_ICN_11_IND_Falha_Perfil_Mutuario
#}

{% set c_indicador = 2 %}

WITH base AS (
    SELECT
        t2.c_trim                                   AS c_periodo,
        t1.dt_processamento,
        t1.c_rede,
        t1.d_rede,
        t1.c_regiao,
        t1.d_regiao,
        t1.c_area,
        t1.d_area,
        t1.c_orgao_resp,
        t1.d_orgao_resp,
        t1.c_indicador,
        COUNT(DISTINCT t1.num_operacao)              AS numoper_total,
        COUNT(DISTINCT
            CASE
                WHEN t1.c_situacao IN (11, 16)       -- 11 = Mora, 16 = Contencioso
                THEN t1.num_operacao
            END
        )                                            AS numoper_irreg
    FROM {{ ref('fct_borrower_profile_detail') }} AS t1
    INNER JOIN {{ source('datamart', 'l_dia') }} AS t2
        ON t2.c_dia = t1.dt_processamento
    WHERE t1.c_indicador = {{ c_indicador }}
    GROUP BY
        t2.c_trim, t1.dt_processamento,
        t1.c_rede, t1.d_rede,
        t1.c_regiao, t1.d_regiao,
        t1.c_area, t1.d_area,
        t1.c_orgao_resp, t1.d_orgao_resp,
        t1.c_indicador
),

-- Level 4: Branch (Orgao) aggregation
agreg_orgao AS (
    SELECT
        c_periodo,
        dt_processamento,
        4                                           AS c_nivel,
        c_rede, d_rede,
        c_regiao, d_regiao,
        c_area, d_area,
        c_orgao_resp, d_orgao_resp,
        c_indicador,
        SUM(numoper_total)                          AS numoper_total,
        SUM(numoper_irreg)                          AS numoper_irreg,
        (SUM(numoper_irreg) / NULLIF(CAST(SUM(numoper_total) AS DECIMAL(18,5)), 0)) * 100
                                                    AS vl_indicador
    FROM base
    GROUP BY
        c_periodo, dt_processamento,
        c_rede, d_rede, c_regiao, d_regiao,
        c_area, d_area, c_orgao_resp, d_orgao_resp, c_indicador
),

-- Level 3: Area aggregation
agreg_area AS (
    SELECT
        c_periodo,
        dt_processamento,
        3                                           AS c_nivel,
        c_rede, d_rede,
        c_regiao, d_regiao,
        c_area, d_area,
        CAST(NULL AS VARCHAR)                       AS c_orgao_resp,
        CAST(NULL AS VARCHAR)                       AS d_orgao_resp,
        c_indicador,
        SUM(numoper_total)                          AS numoper_total,
        SUM(numoper_irreg)                          AS numoper_irreg,
        (SUM(numoper_irreg) / NULLIF(CAST(SUM(numoper_total) AS DECIMAL(18,5)), 0)) * 100
                                                    AS vl_indicador
    FROM base
    GROUP BY
        c_periodo, dt_processamento,
        c_rede, d_rede, c_regiao, d_regiao,
        c_area, d_area, c_indicador
),

-- Level 2: Region aggregation
agreg_regiao AS (
    SELECT
        c_periodo,
        dt_processamento,
        2                                           AS c_nivel,
        c_rede, d_rede,
        c_regiao, d_regiao,
        CAST(NULL AS VARCHAR)                       AS c_area,
        CAST(NULL AS VARCHAR)                       AS d_area,
        CAST(NULL AS VARCHAR)                       AS c_orgao_resp,
        CAST(NULL AS VARCHAR)                       AS d_orgao_resp,
        c_indicador,
        SUM(numoper_total)                          AS numoper_total,
        SUM(numoper_irreg)                          AS numoper_irreg,
        (SUM(numoper_irreg) / NULLIF(CAST(SUM(numoper_total) AS DECIMAL(18,5)), 0)) * 100
                                                    AS vl_indicador
    FROM base
    GROUP BY
        c_periodo, dt_processamento,
        c_rede, d_rede, c_regiao, d_regiao, c_indicador
),

-- Level 1: Network aggregation
agreg_rede AS (
    SELECT
        c_periodo,
        dt_processamento,
        1                                           AS c_nivel,
        c_rede, d_rede,
        CAST(NULL AS VARCHAR)                       AS c_regiao,
        CAST(NULL AS VARCHAR)                       AS d_regiao,
        CAST(NULL AS VARCHAR)                       AS c_area,
        CAST(NULL AS VARCHAR)                       AS d_area,
        CAST(NULL AS VARCHAR)                       AS c_orgao_resp,
        CAST(NULL AS VARCHAR)                       AS d_orgao_resp,
        c_indicador,
        SUM(numoper_total)                          AS numoper_total,
        SUM(numoper_irreg)                          AS numoper_irreg,
        (SUM(numoper_irreg) / NULLIF(CAST(SUM(numoper_total) AS DECIMAL(18,5)), 0)) * 100
                                                    AS vl_indicador
    FROM base
    GROUP BY
        c_periodo, dt_processamento,
        c_rede, d_rede, c_indicador
)

SELECT * FROM agreg_orgao
UNION ALL
SELECT * FROM agreg_area
UNION ALL
SELECT * FROM agreg_regiao
UNION ALL
SELECT * FROM agreg_rede

ORDER BY c_periodo, dt_processamento, c_nivel, c_rede, c_regiao, c_area, c_orgao_resp

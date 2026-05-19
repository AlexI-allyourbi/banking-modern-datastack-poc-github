{{
    config(materialized='ephemeral')
}}

{#
    Staging: NUC (Client Unit) Universe
    
    Replaces: DMKE_TEMP..RENTAB005_D_nuc_4redes_histo
    Gets all client units with their tax ID, manager, branch, and name.
#}

SELECT
    nuc         AS c_nuc,
    num_contribuinte AS nif,
    cod_gestor_nuc   AS c_gestor,
    cod_balcao_resp  AS c_orgao,
    nome_nuc

FROM {{ source('datamart_00', 'a_resumo_nuc_fm') }}

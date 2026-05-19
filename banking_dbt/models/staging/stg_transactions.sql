{{ config(materialized='view') }}

SELECT
    v:id::string                 AS transaction_id,
    v:account_id::string         AS account_id,
    v:amount::float              AS amount,
    v:txn_type::string           AS transaction_type,
    v:related_account_id::string AS related_account_id,
    v:status::string             AS status,
    to_timestamp(v:created_at::number / 1000000) AS transaction_time,
    CURRENT_TIMESTAMP            AS load_timestamp
FROM {{ source('raw', 'transactions') }}
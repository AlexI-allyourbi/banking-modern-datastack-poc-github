# Stored Procedure to dbt Conversion: GOBK_ICN_11_IND_Falha_Perfil_Mutuario

## What the Original Stored Procedure Does

**Indicator RO 231 — "Falha na avaliação do perfil do mutuário"** (Failure in Borrower Profile Assessment)

This banking risk indicator measures the ratio of credit operations contracted in the **last 6 months** that are currently in a problematic state (**Mora** = delinquency, or **Contencioso** = litigation), broken down by organizational hierarchy (branch → area → region → network).

- **Numerator:** Number of recent operations now in Mora or Contencioso
- **Denominator:** Total number of operations contracted in the last 6 months
- **Formula:** `(irregular operations / total operations) × 100`

---

## Original Procedure Flow (SQL Server)

The stored procedure uses a heavily procedural approach with **6 temp tables**, **UPDATE/DELETE** statements, and **multiple INSERT INTO** calls:

```
@POSICAO (input parameter — reporting date)
    │
    ▼
#TMP_OPERACOES_CREDITO_CP_HISTO
    │  Base credit operations from last 6 months
    │  Joins: OPERACOES_CREDITO_CP_HISTO + NUC_HISTO + L_PRODUTO_HISTO + L_SITUACAO
    │  Filters: 180 days, exclude situation 15, exclude products 1402/10016
    ▼
#TMP_OPERACOES_CREDITO_CP_HISTO_Preaprovados
    │  Left join with pre-approved credit limits
    │  UPDATE: nullify pre-approval date where flag = 0
    │  DELETE: remove restructured products (subfamilies 51,53,28,40,52)
    ▼
#AUX1 → #AUX2 → #AUX3 → #AUX4
    │  Chain of 4 temp tables to calculate last installment number
    │  Uses historical global operations + calendar for month-end boundaries
    │  RANK() to number installments, then MAX to get the last one
    │  UPDATE: write back num_ult_prest to the main temp table
    ▼
INSERT INTO GOBK_ICN_F_Valores_Detalhe_HISTO
    │  Detail records with organizational hierarchy joins
    ▼
INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Mensal
    │  Monthly aggregation using CTEs at 4 levels (branch/area/region/network)
    │  Calculates the indicator percentage
    ▼
INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Trimestral
       Quarterly aggregation (AVG of monthly indicator, SUM of counts)
```

### Key Problems with the Procedural Approach
- **6 temp tables** created and dropped — hard to test or debug individually
- **Mutable state** — UPDATE and DELETE statements modify temp tables in-place
- **No version control** — stored procedure lives in the database, not in code
- **No lineage** — impossible to trace where data comes from
- **No testing** — no built-in way to validate intermediate results

---

## dbt Conversion Strategy

### Principles Applied

| Procedural (SP) | Declarative (dbt) |
|---|---|
| `CREATE TABLE #temp` | CTE or `ephemeral` model |
| `UPDATE #temp SET ...` | `CASE WHEN` / `COALESCE` in SELECT |
| `DELETE FROM #temp WHERE ...` | `WHERE NOT (...)` filter in SELECT |
| `INSERT INTO target SELECT ...` | Materialized model (`table` / `incremental`) |
| `@POSICAO` parameter | `{{ var('posicao') }}` |
| Temp table chain (AUX1→AUX4) | Chained CTEs within a single model |

### Model Dependency Graph (DAG)

```
sources (datamart.*, campanhas.*)
    │
    ▼
int_credit_ops_recent          ← ephemeral (base operations, last 6 months)
    │
    ▼
int_credit_ops_enriched        ← ephemeral (+ pre-approvals, - restructured, + installment calc)
    │
    ▼
fct_borrower_profile_detail    ← incremental (detail records + org hierarchy)
    │
    ├──▶ fct_borrower_profile_monthly     ← table (4-level aggregation, indicator %)
    │         │
    │         ▼
    └──▶ fct_borrower_profile_quarterly   ← table (quarterly roll-up)
```

---

## File-by-File Explanation

### 1. `sources.yml` — Source Definitions

Declares all external tables referenced by the models. In the original SP, these were accessed directly via `DATAMART..table_name` and `Campanhas..table_name` syntax (cross-database queries in SQL Server). In dbt, these become `{{ source('datamart', 'table_name') }}`.

**Sources defined:**
- `datamart.operacoes_credito_cp_histo` — Main credit operations table
- `datamart.nuc_histo` — Client unit history (for responsible branch)
- `datamart.l_produto_histo` — Product lookup
- `datamart.l_situacao` — Status lookup
- `datamart.operacoes_credito_cp_global_histo` — Global operations (installment tracking)
- `datamart.t_dia` — Calendar (month-end boundaries)
- `datamart.l_orgao` / `l_area` / `l_regiao` / `l_rede` — Organizational hierarchy
- `datamart.l_dia` — Calendar (quarter mapping)
- `campanhas.preaprovados_nic_limites_histo` — Pre-approved credit limits

---

### 2. `int_credit_ops_recent.sql` — Base Operations (Ephemeral)

**Replaces:** `#TMP_OPERACOES_CREDITO_CP_HISTO` (first temp table)

Selects credit operations opened in the last 180 days from the reporting date. Key filters:
- `DATEDIFF('day', dt_abertura, posicao) <= 180` — last 6 months only
- `c_situacao <> 15` — exclude litigation with agreement (creates new operations, so the opening date would be misleading)
- `c_produto NOT IN (1402, 10016)` — exclude immediate consumer credit

The `IDENTITY(int,1,1)` column from SQL Server is replaced with `ROW_NUMBER() OVER (ORDER BY num_operacao)`.

**Materialized as `ephemeral`** — this is a building block, not queried directly. dbt inlines it as a CTE.

---

### 3. `int_credit_ops_enriched.sql` — Enriched Operations (Ephemeral)

**Replaces:** `#TMP_OPERACOES_CREDITO_CP_HISTO_Preaprovados` + all 4 AUX temp tables + their UPDATE/DELETE operations

This model chains 6 CTEs to replicate what the SP did across 5 temp tables and 3 UPDATE/DELETE statements:

| CTE | Replaces | Purpose |
|---|---|---|
| `preapproved` | Temp table #2 creation | Left join with pre-approval data, get max processing date |
| `filtered` | UPDATE + DELETE on #2 | Nullify pre-approval date (CASE), exclude restructured products (WHERE) |
| `aux1_first_installment` | #AUX1 | Find first installment date per operation |
| `aux2_processing_dates` | #AUX2 | Get month-end processing dates from that point onward |
| `aux3_ranked` | #AUX3 | RANK installments by date per operation |
| `aux4_last_installment` | #AUX4 | Get last installment number (MAX of rank) |

The final SELECT joins the filtered operations with the calculated installment number using `COALESCE` (replacing the `UPDATE ... SET` pattern).

**Key conversion patterns used:**
- `DELETE WHERE condition` → `WHERE NOT condition` in the `filtered` CTE
- `UPDATE SET column = NULL WHERE flag = 0` → `CASE WHEN flag = 0 THEN NULL ELSE value END`
- `UPDATE SET col = b.col FROM a JOIN b` → `LEFT JOIN` + `COALESCE` in final SELECT

---

### 4. `fct_borrower_profile_detail.sql` — Detail Fact (Incremental)

**Replaces:** `INSERT INTO GOBK_ICN_F_Valores_Detalhe_HISTO`

Joins the enriched operations with the organizational hierarchy lookups:
- `l_orgao` → branch code and name
- `l_area` → area code and name
- `l_regiao` → region code and name
- `l_rede` → network code and name
- `l_dia` → quarter code (`c_trim`)

The `@C_INDICADOR = 2` constant is set as a Jinja variable.

**Materialized as `incremental`** with `delete+insert` strategy, keyed on `(c_indicador, dt_processamento, num_operacao)`. This replaces the `DELETE WHERE ... AND Dt_Processamento = @POSICAO` + `INSERT` pattern — dbt handles the delete+insert atomically.

---

### 5. `fct_borrower_profile_monthly.sql` — Monthly Aggregation (Table)

**Replaces:** `INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Mensal` (the CTE block)

The original SP used 5 CTEs (`CTE_Base` + 4 aggregation levels) and `UNION ALL`. The dbt model preserves this exact structure:

| CTE | Level | Granularity |
|---|---|---|
| `base` | — | Raw counts by full hierarchy |
| `agreg_orgao` | 4 | Branch level |
| `agreg_area` | 3 | Area level (branch = NULL) |
| `agreg_regiao` | 2 | Region level (area + branch = NULL) |
| `agreg_rede` | 1 | Network level (region + area + branch = NULL) |

Each level calculates: `(SUM(irregular) / SUM(total)) × 100`

**Materialized as `table`** — full rebuild each run (replaces the `DELETE ALL WHERE indicator = 2` + `INSERT` pattern).

Division by zero is handled with `NULLIF(..., 0)` instead of SQL Server's implicit behavior.

---

### 6. `fct_borrower_profile_quarterly.sql` — Quarterly Aggregation (Table)

**Replaces:** `INSERT INTO GOBK_ICN_F_Valores_Agreg_HISTO_Trimestral`

Groups the monthly data by quarter (`c_periodo`). Uses `AVG(vl_indicador)` for the indicator value (average of monthly percentages) and `SUM` for operation counts.

---

## How to Run

```bash
# Run with a specific reporting date
dbt run --select +fct_borrower_profile_quarterly --vars '{"posicao": "2026-05-15"}'

# Run just the detail model
dbt run --select fct_borrower_profile_detail --vars '{"posicao": "2026-05-15"}'
```

The `+` prefix runs all upstream dependencies (the intermediate models).

---

## SQL Server → Snowflake Syntax Changes

| SQL Server | Snowflake (dbt) |
|---|---|
| `DATEDIFF(DD, a, b)` | `DATEDIFF('day', a, b)` |
| `CONVERT(TINYINT, 0)` | `CAST(0 AS SMALLINT)` |
| `CONVERT(Decimal(18,5), x)` | `CAST(x AS DECIMAL(18,5))` |
| `IDENTITY(int,1,1)` | `ROW_NUMBER() OVER (ORDER BY ...)` |
| `If object_id('tempdb..#t') is not null Drop Table #t` | Not needed (CTEs/ephemeral) |
| `Delete From target Where ...` + `Insert Into target` | `incremental` with `delete+insert` strategy |
| `DATAMART..table_name` | `{{ source('datamart', 'table_name') }}` |
| `@VARIABLE` | `{{ var('variable_name') }}` |

---

## Summary of Improvements

| Aspect | Stored Procedure | dbt Models |
|---|---|---|
| **Temp tables** | 6 mutable temp tables | 0 (CTEs + ephemeral models) |
| **Mutability** | UPDATE, DELETE on intermediate data | Pure SELECT transforms (immutable) |
| **Testability** | None | Each model testable independently |
| **Lineage** | Hidden inside SP | Full DAG visibility in dbt docs |
| **Version control** | Stored in database | Files in Git |
| **Idempotency** | Manual DELETE + INSERT | dbt handles via materialization |
| **Documentation** | SQL comments only | dbt docs, YAML descriptions, this guide |

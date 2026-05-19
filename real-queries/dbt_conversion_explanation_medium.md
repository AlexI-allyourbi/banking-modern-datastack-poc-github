# Stored Procedure to dbt Conversion: RENTAB005_CALCULA_RENTABILIDADE_BE

## What the Original Stored Procedure Does

**RENTAB005_CALCULA_RENTABILIDADE_BE** calculates **profitability (rentabilidade)** for the banking entity (BE). It combines three revenue components — active financial margin, passive financial margin, and commissions — per client unit (NUC) and product, adjusted for risk-weighted assets (RWA) and allocated capital.

**Parameters:**
- `@posicao` — reporting date
- `@periodicidade` — 'D' (daily) or 'M' (monthly)

**Final output:** One row per `(date, month, NUC, product)` with summed active margin, passive margin, commissions, and capital allocated → inserted into `RENTABILIDADE_BE_HISTO`.

---

## Original Procedure Flow (SQL Server)

```
@posicao, @periodicidade (input parameters)
    │
    ▼
Date logic: If 'D' and not month-end → shift to previous month-end, switch to 'M'
    │
    ▼
RENTAB005_D_nuc_4redes_histo                   ← NUC universe (all client units)
    │
    ├──▶ RENTAB005_D_RENTABILIDADE_RWA_HISTO   ← Current RWA data (deduped + code fix)
    │
    ├──▶ RENTAB005_D_OPERACOES_MARGENS         ← Operations margins (deduped for product 6867)
    │
    ▼
Parameter validation: Ensure RENTABILIDADE_BE_PARAM exists for position
    │
    ▼
RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1       ← Main working table (5 mutations!)
    │  1. SELECT INTO: Active margins + RWA join
    │  2. UPDATE: Fallback RWA from 2 months ago where NULL
    │  3. UPDATE: Default RWA values where still NULL
    │  4. UPDATE: Calculate VL_CAPITAL_AFECTO
    │  5. INSERT: Passive margin rows (c_grande_rubrica_agr = 2)
    │  6. INSERT: Commission rows
    ▼
DELETE + INSERT INTO RENTABILIDADE_BE_HISTO     ← Final aggregated output
    │  SUM(margin, passive, commissions, capital) GROUP BY (date, NUC, product)
    ▼
exec MSQLDB040_MANUT_TABELA 'RENTABILIDADE_BE' ← Maintenance/logging (not converted)
```

### Key Complexity
The main challenge is `RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1` — a single temp table that gets:
- **Created** with active margin data
- **Updated 3 times** (fallback RWA, defaults, capital calculation)
- **Inserted into 2 more times** (passive margins, commissions)

This mutable pattern is the core of what makes the SP hard to maintain and test.

---

## dbt Conversion Strategy

### Decomposition Approach

The single mutable temp table is split into **three separate models** (one per revenue stream), each producing an immutable dataset:

| SP Operation | dbt Model | Type |
|---|---|---|
| NUC universe temp table | `stg_nuc_universe` | ephemeral |
| RWA dedup + code fix | `stg_rwa_current` | ephemeral |
| RWA 2-month fallback | `stg_rwa_2months_prior` | ephemeral |
| Margins dedup | `stg_operations_margins` | ephemeral |
| AUX1 creation + 3 UPDATEs | `int_active_margin_operations` | ephemeral |
| AUX1 passive INSERT | `int_passive_margin_operations` | ephemeral |
| AUX1 commission INSERT | `int_commission_operations` | ephemeral |
| Final DELETE + INSERT | `fct_profitability_be` | incremental |

### Model Dependency Graph (DAG)

```
sources
  │
  ├──▶ stg_nuc_universe
  │       │
  ├──▶ stg_rwa_current ──────────────────┐
  │                                       │
  ├──▶ stg_rwa_2months_prior ────────────┐│
  │                                      ││
  ├──▶ stg_operations_margins ──┐        ││
  │                              │        ││
  │                              ▼        ▼▼
  │                     int_active_margin_operations
  │                              │
  │                     int_passive_margin_operations
  │                              │
  │                     int_commission_operations
  │                              │
  │                              ▼
  └──────────────────▶ fct_profitability_be (UNION ALL + aggregate)
```

---

## File-by-File Explanation

### 1. `sources.yml` — Source Definitions

Defines all external tables across three source databases:
- **datamart_00** — Legacy datamart with NUC summaries
- **datamart** — Main datamart (RWA history, operations margins, product lookup)
- **dmke_base** — Reference tables (parameters, commissions)

---

### 2. `stg_nuc_universe.sql` — Client Unit Universe

**Replaces:** `DMKE_TEMP..RENTAB005_D_nuc_4redes_histo`

Simple SELECT from `A_RESUMO_NUC_FM` to get all client units (NUCs) with their tax ID, manager, branch, and name.

The original SP had commented-out legacy code with a more complex query (filtering by network codes, joining with TED_ORGAOS_DW). The current version just reads the full NUC summary.

---

### 3. `stg_rwa_current.sql` — Current RWA Data

**Replaces:** `DMKE_TEMP..RENTAB005_D_RENTABILIDADE_RWA_HISTO`

1. Finds the most recent RWA processing date ≤ the reporting date
2. Gets all RWA records for that date
3. Adds a deduplication key via `ROW_NUMBER() OVER (PARTITION BY date, operation, product, NIC ORDER BY value DESC)`
4. Fixes operation codes: strips `'500101'` prefix for product 500101

**Conversion note:** The original SP did the code fix as a separate `UPDATE` statement. In dbt, it's a `CASE WHEN` in the `SELECT`.

---

### 4. `stg_rwa_2months_prior.sql` — Fallback RWA

**Replaces:** `DMKE_TEMP..RENTAB005_D_RENTABILIDADE_RWA_2MESES_ANT`

Gets RWA data from 2 months before the reporting date. Used as a fallback when current-period RWA is missing for an operation.

Filters: excludes records where `RIGHT(key_dgr, 1) = 'f'`, and requires non-null RWA/operation/product.

---

### 5. `stg_operations_margins.sql` — Operations Margins

**Replaces:** `DMKE_TEMP..RENTAB005_D_OPERACOES_MARGENS`

Gets all margin operations for the reporting date. Adds a deduplication key specifically for product 6867 (using `ROW_NUMBER` by saldo descending). All other products get `CHAVE = 1`.

---

### 6. `int_active_margin_operations.sql` — Active Margins (Core Logic)

**Replaces:** The entire lifecycle of `RENTAB005_D_RENTABILIDADE_OPERACOES_AUX1` (initial creation + 3 UPDATE statements)

This is the most complex model, using 4 CTEs to replace 4 mutable operations:

| CTE | Replaces | What It Does |
|---|---|---|
| `params` | `@TAXA_NVL_CAP_PROPRIO` variable | Reads capital ratio parameter |
| `base_operations` | SELECT INTO AUX1 | Joins margins + product + RWA + NUC |
| `with_fallback_rwa` | UPDATE from 2-month-old RWA | `COALESCE(current, fallback)` |
| `final_active` | UPDATE defaults + UPDATE capital | Defaults + capital calculation |

**Key conversion patterns:**
- `UPDATE SET col = b.col WHERE a.col IS NULL` → `COALESCE(a.col, b.col)` in CTE
- `UPDATE SET default WHERE IS NULL` → `COALESCE(col, default)` in final CTE
- `UPDATE SET calculated = formula` → Inline `CASE WHEN` in SELECT

**Product code mapping (preserved from original):**
- Product lookup 80001804 → matches operation product 1804, output as 80001804
- Product lookup 500101 → matches operation product 6867, output as 500101
- All others → direct match, output operation's product code

**Capital allocation formula:**
```
VL_CAPITAL_AFECTO = ((VL_SALDO_MEDIO × TAXA_NVL_CAP_PROPRIO × VL_RW_RENT) / 360) × days_in_month
```
Exception: Product 1804 always gets 0.

---

### 7. `int_passive_margin_operations.sql` — Passive Margins

**Replaces:** Second INSERT INTO AUX1 (where `c_grande_rubrica_agr = 2`)

Selects liability-side operations (deposits, funding). The margin value goes into `vl_margem_passiva` instead of `vl_margem`. All RWA and capital fields are NULL since these don't carry risk weights.

---

### 8. `int_commission_operations.sql` — Commissions

**Replaces:** Third INSERT INTO AUX1 (from `COMISSOES_CONSOLIDADA_HISTO`)

Fee and commission revenues by NUC and product. Uses `EOMONTH(dt_processamento)` as the reference date (matching the original logic). Most fields are NULL since commissions don't have operations, balances, or RWA.

---

### 9. `fct_profitability_be.sql` — Final Profitability Fact

**Replaces:** `DELETE + INSERT INTO RENTABILIDADE_BE_HISTO`

1. `UNION ALL` of all three margin models (active + passive + commissions)
2. Validates against NUC universe and product lookup (matching original JOINs)
3. Aggregates with `SUM(COALESCE(column, 0))` for each margin component
4. Groups by `(date, month, NUC, product)`

**Output columns:**
| Column | Source |
|---|---|
| `dt_processamento` | Reference date |
| `cod_anomes` | Year-month code (YYYYMM) |
| `nuc` | Client unit ID |
| `cod_produto` | Product code |
| `mrg_fin_act` | Sum of active financial margin |
| `mrg_fin_pass` | Sum of passive financial margin |
| `mrg_comissao` | Sum of commissions |
| `cpa` | Sum of capital allocated |
| `origem_info` | NULL (placeholder) |

**Materialized as `incremental`** with `delete+insert` strategy, keyed on `(dt_processamento, c_nuc, c_produto)`.

---

## How to Run

```bash
# Run the full profitability model with all dependencies
dbt run --select +fct_profitability_be --vars '{"posicao": "2025-05-31"}'
```

---

## Procedural Logic Not Converted (and Why)

| Original SP Logic | Reason Not Converted |
|---|---|
| `@periodicidade` date shifting | Scheduling concern — dbt should run at the correct date via Airflow |
| `MSQLDB_APAGAR_TEMP` (drop temp tables) | No temp tables in dbt |
| `RENTABILIDADE_BE_PARAM` insert if missing | Administrative/seed data — use `dbt seed` or manual process |
| `RAISERROR` duplicate param check | Convert to a `dbt test` (see below) |
| `MSQLDB040_MANUT_TABELA` maintenance call | Operational concern — handle in orchestration layer |

### Recommended dbt Test (for the RAISERROR validation)

Add to a `schema.yml`:
```yaml
models:
  - name: fct_profitability_be
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [dt_processamento, nuc, cod_produto]
```

---

## SQL Server → Snowflake Syntax Changes

| SQL Server | Snowflake (dbt) |
|---|---|
| `CONVERT(VARCHAR(6), date, 112)` | `TO_CHAR(date, 'YYYYMM')` |
| `CONVERT(date, CAST(...))` | `col::DATE` |
| `EOMONTH(DATEADD(mm, -2, @pos))` | `EOMONTH(DATEADD(MONTH, -2, '...'::DATE))` |
| `DAY(EOMONTH(@pos))` | `DAY(EOMONTH('...'::DATE))` |
| `ISNULL(col, 0)` | `COALESCE(col, 0)` |
| `CONVERT(DECIMAL(15,2), NULL)` | `CAST(NULL AS DECIMAL(15,2))` |
| `RIGHT(col, 1)` | `RIGHT(col, 1)` (same) |
| `DROP TABLE IF EXISTS` | Not needed (ephemeral/CTE) |
| `UPDATE a SET ... FROM a JOIN b` | `COALESCE` / `CASE` in SELECT |
| Multiple `INSERT INTO` same table | `UNION ALL` across models |

---

## Summary: Original vs dbt

| Aspect | Stored Procedure | dbt Models |
|---|---|---|
| **Temp tables** | 6 mutable temp tables | 0 (ephemeral + CTEs) |
| **UPDATE statements** | 5 (on 2 different tables) | 0 (COALESCE/CASE in SELECT) |
| **INSERT INTO same table** | 3 times into AUX1 | 3 separate models + UNION ALL |
| **Models** | 1 monolithic SP (220 lines) | 8 focused models |
| **Testability** | None | Each model independently testable |
| **Lineage** | Hidden | Full DAG in dbt docs |
| **Revenue streams** | Mixed in one table | Separated: active / passive / commissions |

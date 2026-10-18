-- =============================================================================
-- 04_segmentation.sql
-- Segmentazione clienti: RFM + analisi di Pareto (concentrazione del fatturato)
--
-- Domande di business:
--   1. Chi sono i clienti di maggior valore e chi stiamo perdendo?
--   2. Quanto è concentrato il fatturato? Vale la "regola 80/20"?
--
-- Input : data/processed/orders_clean.parquet (creato da 01_data_quality.sql)
--         una riga = un prodotto in un ordine (quantity è sempre 1, quindi
--         il fatturato di riga coincide con price)
-- Output: results/04_*.csv
--
-- Esecuzione (dalla root del progetto):
--   duckdb data/jewelry.duckdb < sql/04_segmentation.sql
-- =============================================================================


-- -----------------------------------------------------------------------------
-- CARICAMENTO DELLA TABELLA PULITA
-- Come in 02 e 03, una vista legge direttamente il file Parquet:
-- percorsi completi: lo script funziona da qualsiasi cartella lo lanci.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW order_lines AS
SELECT * FROM '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/data/processed/orders_clean.parquet';


-- -----------------------------------------------------------------------------
-- 0. Data di riferimento dell'analisi
-- Il dataset è storico: "oggi" = giorno successivo all'ultimo ordine.
-- Usare CURRENT_DATE gonfierebbe la recency di tutti di ~5 anni.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE params AS
SELECT CAST(MAX(order_ts) AS DATE) + INTERVAL 1 DAY AS snapshot_date
FROM order_lines;


-- -----------------------------------------------------------------------------
-- 1. Metriche RFM grezze per cliente
--    Recency   = giorni dall'ultimo ordine
--    Frequency = numero di ordini distinti (non di righe/prodotti)
--    Monetary  = fatturato totale
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer_rfm AS
WITH order_totals AS (                -- prima aggrego a livello ordine
    SELECT
        user_id,
        order_id,
        MIN(order_ts)         AS order_ts,
        SUM(price * quantity) AS order_value
    FROM order_lines
    GROUP BY user_id, order_id
)
SELECT
    o.user_id,
    MIN(o.order_ts)                                    AS first_order,
    MAX(o.order_ts)                                    AS last_order,
    DATE_DIFF('day', MAX(o.order_ts), p.snapshot_date) AS recency_days,
    COUNT(*)                                           AS frequency,
    ROUND(SUM(o.order_value), 2)                       AS monetary,
    ROUND(AVG(o.order_value), 2)                       AS avg_order_value
FROM order_totals o
CROSS JOIN params p
GROUP BY o.user_id, p.snapshot_date;


-- -----------------------------------------------------------------------------
-- 2. Punteggi RFM (1 = peggio, 5 = meglio)
--
-- Scelta metodologica (da saper spiegare a colloquio):
--  - R e M: quintili con NTILE(5) -> ogni classe ha ~20% dei clienti.
--  - F: soglie fisse di business, NON quintili. ~73% dei clienti ha 1 solo
--    ordine: con NTILE clienti identici (frequency = 1) finirebbero in classi
--    diverse in modo arbitrario. Le soglie fisse evitano questo artefatto.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer_scores AS
SELECT
    *,
    6 - NTILE(5) OVER (ORDER BY recency_days)       AS r_score,  -- più recente = 5
    CASE
        WHEN frequency = 1               THEN 1
        WHEN frequency = 2               THEN 2
        WHEN frequency = 3               THEN 3
        WHEN frequency BETWEEN 4 AND 5   THEN 4
        ELSE 5
    END                                             AS f_score,
    NTILE(5) OVER (ORDER BY monetary)               AS m_score   -- spesa alta = 5
FROM customer_rfm;


-- -----------------------------------------------------------------------------
-- 3. Segmenti CRM
-- Regole su R e F (M serve a dare priorità dentro i segmenti).
-- L'ordine dei WHEN conta: vince la prima condizione vera.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer_segments AS
SELECT
    *,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 THEN '01 Champions'
        WHEN r_score >= 3 AND f_score >= 3 THEN '02 Loyal'
        WHEN r_score >= 4 AND f_score  = 2 THEN '03 Potential Loyalist'
        WHEN r_score  = 5 AND f_score  = 1 THEN '04 New Customers'
        WHEN r_score  = 4 AND f_score  = 1 THEN '05 Promising'
        WHEN r_score <= 2 AND f_score >= 4 THEN '06 Cant Lose Them'
        WHEN r_score <= 3 AND f_score >= 2 THEN '07 At Risk'
        WHEN r_score  = 3 AND f_score  = 1 THEN '08 About to Sleep'
        ELSE                                    '09 Lost / Hibernating'
    END AS segment
FROM customer_scores;


-- -----------------------------------------------------------------------------
-- 4. Profilo dei segmenti -> tabella principale per il README
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE segment_summary AS
SELECT
    segment,
    COUNT(*)                                                     AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_customers,
    ROUND(SUM(monetary), 0)                                      AS revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue,
    ROUND(AVG(recency_days), 0)                                  AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                     AS avg_frequency,
    ROUND(AVG(monetary), 0)                                      AS avg_monetary,
    ROUND(SUM(monetary) / SUM(frequency), 0)                     AS avg_order_value
FROM customer_segments
GROUP BY segment
ORDER BY segment;

SELECT * FROM segment_summary;

COPY segment_summary TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_rfm_segment_summary.csv' (HEADER);


-- Griglia R x F: numero clienti per ogni combinazione (base per una heatmap)
COPY (
    SELECT r_score, f_score,
           COUNT(*)               AS customers,
           ROUND(SUM(monetary),0) AS revenue
    FROM customer_scores
    GROUP BY r_score, f_score
    ORDER BY r_score DESC, f_score
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_rfm_grid.csv' (HEADER);


-- Dettaglio cliente (utile per una lista di attivazione CRM)
COPY (
    SELECT user_id, segment, recency_days, frequency, monetary,
           r_score, f_score, m_score,
           CONCAT(r_score, f_score, m_score) AS rfm_code
    FROM customer_segments
    ORDER BY segment, monetary DESC
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_customer_segments.csv' (HEADER);


-- =============================================================================
-- 5. ANALISI DI PARETO
-- Ordino i clienti per fatturato decrescente e calcolo la quota cumulata.
-- =============================================================================
CREATE OR REPLACE TABLE pareto AS
SELECT
    user_id,
    monetary,
    ROW_NUMBER() OVER (ORDER BY monetary DESC)                        AS rank_desc,
    100.0 * ROW_NUMBER() OVER (ORDER BY monetary DESC)
          / COUNT(*) OVER ()                                          AS cum_pct_customers,
    100.0 * SUM(monetary) OVER (ORDER BY monetary DESC
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(monetary) OVER ()                                     AS cum_pct_revenue
FROM customer_rfm;


-- 5a. La risposta in una riga: quale % di clienti genera l'80% del fatturato?
SELECT
    ROUND(MIN(cum_pct_customers), 1) AS pct_customers_for_80pct_revenue
FROM pareto
WHERE cum_pct_revenue >= 80;


-- 5b. Quota di fatturato dei top 1% / 5% / 10% / 20% / 50% clienti
COPY (
    SELECT
        t.top_pct                        AS top_pct_customers,
        ROUND(MAX(p.cum_pct_revenue), 1) AS pct_revenue
    FROM (VALUES (1), (5), (10), (20), (50)) AS t(top_pct)
    JOIN pareto p ON p.cum_pct_customers <= t.top_pct
    GROUP BY t.top_pct
    ORDER BY t.top_pct
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_pareto_summary.csv' (HEADER);


-- 5c. Curva di Pareto per decile (10 punti, perfetta per un grafico)
COPY (
    SELECT
        CEIL(cum_pct_customers / 10) * 10 AS customer_decile_pct,
        ROUND(MAX(cum_pct_revenue), 1)    AS cum_pct_revenue
    FROM pareto
    GROUP BY 1
    ORDER BY 1
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_pareto_curve.csv' (HEADER);


-- 5d. Contesto: clienti one-shot vs ricorrenti (spiega la forma della curva)
COPY (
    SELECT
        CASE WHEN frequency = 1 THEN 'one-time' ELSE 'repeat' END    AS customer_type,
        COUNT(*)                                                     AS customers,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_customers,
        ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue
    FROM customer_rfm
    GROUP BY 1
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_one_time_vs_repeat.csv' (HEADER);


-- 5e. Test di sensibilità: quanto pesano i clienti "anomali"?
-- Alcuni account hanno centinaia di ordini: probabilmente rivenditori/B2B,
-- non consumatori finali. Ricalcolo la quota dei top 20% senza di loro:
-- se cambia molto, la concentrazione è guidata da pochi outlier.
COPY (
    WITH b2c AS (
        SELECT monetary,
               100.0 * ROW_NUMBER() OVER (ORDER BY monetary DESC) / COUNT(*) OVER () AS cum_pct_customers,
               100.0 * SUM(monetary) OVER (ORDER BY monetary DESC
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                     / SUM(monetary) OVER ()                                       AS cum_pct_revenue
        FROM customer_rfm
        WHERE frequency < 50                 -- soglia esplicita, da dichiarare nel README
    )
    SELECT
        (SELECT COUNT(*) FROM customer_rfm WHERE frequency >= 50)             AS excluded_customers,
        ROUND(MAX(cum_pct_revenue) FILTER (WHERE cum_pct_customers <= 20), 1) AS top20_pct_revenue_excl_outliers,
        ROUND(MIN(cum_pct_customers) FILTER (WHERE cum_pct_revenue >= 80), 1) AS pct_customers_for_80pct_excl_outliers
    FROM b2c
) TO '/Users/macbookpro13/Desktop/Riccardo /Develop/CRM RFM ANALYSYS/jewelry-customer-retention-analys/results/04_pareto_sensitivity.csv' (HEADER);
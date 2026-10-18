-- =============================================================================
-- 03_retention.sql
-- Progetto: Jewelry Customer Retention Analysis
-- Obiettivo: raggruppare i clienti per mese del primo acquisto (coorte) e
--            misurare quanti tornano a comprare nei mesi successivi.
--
-- Input:  data/processed/orders_clean.parquet  (prodotto da 01_data_quality.sql)
-- Output: results/cohort_retention.csv  (matrice per i grafici)
--
-- Come eseguirlo (dalla cartella principale del progetto):
--     duckdb jewelry.duckdb
--     .read sql/03_retention.sql
--
-- Due definizioni di retention, perché la gioielleria si compra di rado:
--   - retention MENSILE: % della coorte che ordina proprio nel mese k.
--     È la definizione classica, ma qui darà valori bassi (pochi punti %).
--   - retention CUMULATA: % della coorte che ha fatto almeno un secondo
--     ordine entro k mesi. Più adatta a un acquisto poco frequente.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CARICAMENTO DELLA TABELLA PULITA
-- Una vista non copia i dati: legge direttamente il file Parquet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW order_lines AS
SELECT * FROM 'data/processed/orders_clean.parquet';


-- -----------------------------------------------------------------------------
-- 2. DA RIGHE A ORDINI
-- Il file ha una riga per articolo, ma per la retention ci serve una riga
-- per ordine. Nel punto 01 abbiamo verificato che ogni ordine ha un solo
-- cliente e un solo timestamp, quindi possiamo raggruppare in sicurezza.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE orders AS
SELECT
    order_id,
    user_id,
    MIN(order_ts)              AS order_ts,
    SUM(price * quantity)      AS order_value,
    COUNT(*)                   AS n_articoli
FROM order_lines
GROUP BY order_id, user_id;

-- Valore medio dell'ordine e articoli per ordine
SELECT
    COUNT(*)                           AS ordini,
    ROUND(AVG(order_value), 2)         AS scontrino_medio,
    ROUND(median(order_value), 2)      AS scontrino_mediano,
    ROUND(AVG(n_articoli), 2)          AS articoli_medi_per_ordine
FROM orders;


-- -----------------------------------------------------------------------------
-- 3. ASSEGNAZIONE DELLA COORTE
-- Per ogni cliente: data del primo ordine e mese di coorte.
-- Numeriamo anche gli ordini di ciascun cliente in ordine cronologico
-- (1 = primo acquisto, 2 = secondo, ...): ci servirà ai punti 6 e 7.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE orders_with_cohort AS
SELECT
    o.*,
    MIN(order_ts) OVER (PARTITION BY user_id)                       AS first_order_ts,
    date_trunc('month', MIN(order_ts) OVER (PARTITION BY user_id))  AS cohort_month,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_ts, order_id) AS order_number
FROM orders AS o;

-- Distanza in mesi tra il mese dell'ordine e il mese di coorte
-- (0 = mese del primo acquisto, 1 = mese successivo, ...)
CREATE OR REPLACE TABLE orders_with_cohort AS
SELECT
    *,
    datediff('month', cohort_month, date_trunc('month', order_ts)) AS month_number
FROM orders_with_cohort;

-- Dimensione delle coorti: quanti nuovi clienti acquisiti ogni mese?
SELECT
    cohort_month,
    COUNT(DISTINCT user_id) AS nuovi_clienti
FROM orders_with_cohort
GROUP BY cohort_month
ORDER BY cohort_month;


-- -----------------------------------------------------------------------------
-- 4. RETENTION MENSILE (formato lungo)
-- Per ogni coorte e ogni mese k: quanti clienti della coorte hanno ordinato
-- nel mese k, diviso la dimensione della coorte.
-- Il mese 0 vale per definizione 100%.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE cohort_retention AS
WITH dimensione_coorte AS (
    SELECT cohort_month, COUNT(DISTINCT user_id) AS cohort_size
    FROM orders_with_cohort
    GROUP BY cohort_month
),
attivi AS (
    SELECT cohort_month, month_number, COUNT(DISTINCT user_id) AS clienti_attivi
    FROM orders_with_cohort
    GROUP BY cohort_month, month_number
)
SELECT
    a.cohort_month,
    d.cohort_size,
    a.month_number,
    a.clienti_attivi,
    ROUND(100.0 * a.clienti_attivi / d.cohort_size, 2) AS retention_pct
FROM attivi AS a
JOIN dimensione_coorte AS d USING (cohort_month)
ORDER BY a.cohort_month, a.month_number;


-- -----------------------------------------------------------------------------
-- 5. MATRICE DI COORTE (formato largo, primi 12 mesi)
-- Una riga per coorte, una colonna per mese: è la classica "triangle chart".
-- Le celle vuote in basso a destra non sono zeri: sono mesi non ancora
-- osservabili perché i dati finiscono a novembre 2021.
-- -----------------------------------------------------------------------------
SELECT
    cohort_month,
    cohort_size,
    MAX(retention_pct) FILTER (WHERE month_number = 1)  AS m1,
    MAX(retention_pct) FILTER (WHERE month_number = 2)  AS m2,
    MAX(retention_pct) FILTER (WHERE month_number = 3)  AS m3,
    MAX(retention_pct) FILTER (WHERE month_number = 4)  AS m4,
    MAX(retention_pct) FILTER (WHERE month_number = 5)  AS m5,
    MAX(retention_pct) FILTER (WHERE month_number = 6)  AS m6,
    MAX(retention_pct) FILTER (WHERE month_number = 9)  AS m9,
    MAX(retention_pct) FILTER (WHERE month_number = 12) AS m12
FROM cohort_retention
GROUP BY cohort_month, cohort_size
ORDER BY cohort_month;


-- -----------------------------------------------------------------------------
-- 6. RETENTION CUMULATA: % di clienti tornati entro k mesi
-- Scoperta importante: circa il 41% dei "secondi ordini" avviene nello
-- STESSO GIORNO del primo (ordini separati nella stessa sessione).
-- Non sono veri ritorni e gonfierebbero la retention. Definiamo quindi
-- "ritorno" il primo ordine fatto in un GIORNO SUCCESSIVO al primo acquisto.
--   - second_order_ts: secondo ordine in assoluto (anche stesso giorno)
--   - return_ts:       primo ordine in un giorno successivo = vero ritorno
-- Attenzione alla censura a destra: una coorte di ottobre 2021 non ha
-- avuto 6 mesi per tornare. Per questo calcoliamo ogni finestra solo sui
-- clienti che hanno avuto il tempo di completarla (fine dati: 30/11/2021).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer_first_repeat AS
SELECT
    user_id,
    cohort_month,
    first_order_ts,
    MIN(order_ts) FILTER (WHERE order_number = 2)                     AS second_order_ts,
    MIN(order_ts) FILTER (WHERE CAST(order_ts AS DATE)
                                > CAST(first_order_ts AS DATE))       AS return_ts
FROM orders_with_cohort
GROUP BY user_id, cohort_month, first_order_ts;

-- Quanto cambia il tasso di riacquisto con la definizione corretta?
SELECT
    COUNT(*)                                                         AS clienti,
    ROUND(100.0 * COUNT(second_order_ts) / COUNT(*), 1)              AS riacquisto_ingenuo_pct,
    ROUND(100.0 * COUNT(return_ts) / COUNT(*), 1)                    AS ritorno_reale_pct
FROM customer_first_repeat;

WITH finestre AS (
    SELECT unnest([1, 3, 6, 12]) AS mesi
)
SELECT
    f.mesi                                          AS entro_mesi,
    COUNT(*)                                        AS clienti_osservabili,
    COUNT(*) FILTER (
        WHERE c.return_ts <= c.first_order_ts + to_months(f.mesi)
    )                                               AS clienti_tornati,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE c.return_ts <= c.first_order_ts + to_months(f.mesi)
    ) / COUNT(*), 1)                                AS retention_cumulata_pct
FROM finestre AS f
JOIN customer_first_repeat AS c
  -- teniamo solo i clienti il cui primo ordine è abbastanza vecchio
  ON c.first_order_ts + to_months(f.mesi) <= TIMESTAMP '2021-12-01'
GROUP BY f.mesi
ORDER BY f.mesi;
-- Nota per l'interpretazione: la finestra a 12 mesi include solo clienti
-- acquisiti fino a novembre 2020, cioè le coorti piccole e "storiche".
-- Le finestre non sono quindi confrontabili tra loro come composizione.


-- -----------------------------------------------------------------------------
-- 7. TEMPO AL RITORNO
-- Tra chi torna davvero (giorno successivo o oltre), dopo quanti giorni
-- lo fa? Utile per decidere QUANDO inviare una campagna di riattivazione.
-- -----------------------------------------------------------------------------
WITH gap AS (
    SELECT datediff('day', first_order_ts, return_ts) AS giorni
    FROM customer_first_repeat
    WHERE return_ts IS NOT NULL
)
SELECT
    COUNT(*)                        AS clienti_tornati,
    quantile_cont(giorni, 0.25)     AS q1_giorni,
    median(giorni)                  AS mediana_giorni,
    quantile_cont(giorni, 0.75)     AS q3_giorni
FROM gap;

-- Distribuzione per fasce: quando avviene il ritorno?
SELECT
    CASE
        WHEN giorni <= 7   THEN '1. entro 7 giorni'
        WHEN giorni <= 30  THEN '2. 8-30 giorni'
        WHEN giorni <= 90  THEN '3. 31-90 giorni'
        WHEN giorni <= 180 THEN '4. 91-180 giorni'
        WHEN giorni <= 365 THEN '5. 181-365 giorni'
        ELSE                    '6. oltre un anno'
    END                                            AS fascia,
    COUNT(*)                                       AS clienti,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS perc
FROM (
    SELECT datediff('day', first_order_ts, return_ts) AS giorni
    FROM customer_first_repeat
    WHERE return_ts IS NOT NULL
)
GROUP BY fascia
ORDER BY fascia;


-- -----------------------------------------------------------------------------
-- 8. LE COORTI STAGIONALI TORNANO DI MENO?
-- Ipotesi: chi compra per la prima volta a dicembre (regalo di Natale)
-- è un cliente occasionale e torna meno di chi arriva in un mese "normale".
-- Confronto a parità di finestra: ritorno entro 6 mesi,
-- solo clienti con almeno 6 mesi di storia osservabile.
-- -----------------------------------------------------------------------------
SELECT
    CASE
        WHEN month(cohort_month) = 12      THEN 'dicembre (Natale)'
        WHEN month(cohort_month) = 11      THEN 'novembre (Black Friday)'
        WHEN month(cohort_month) IN (2, 3) THEN 'feb-mar (San Valentino / 8 marzo)'
        ELSE 'altri mesi'
    END                                            AS tipo_coorte,
    COUNT(*)                                       AS clienti,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE return_ts <= first_order_ts + INTERVAL 6 MONTH
    ) / COUNT(*), 1)                               AS ritorno_entro_6_mesi_pct
FROM customer_first_repeat
WHERE first_order_ts + INTERVAL 6 MONTH <= TIMESTAMP '2021-12-01'
GROUP BY tipo_coorte
ORDER BY ritorno_entro_6_mesi_pct DESC;


-- -----------------------------------------------------------------------------
-- 8b. PRIMA E DOPO DICEMBRE 2020
-- Dalla matrice del punto 5 si vede un salto: le coorti da dicembre 2020 in
-- poi sono molto più grandi ma tornano molto meno. Lo quantifichiamo.
-- Il calo inizia prima dei problemi di prezzo a zero (da aprile 2021),
-- quindi non è un effetto della pulizia dei dati.
-- -----------------------------------------------------------------------------
SELECT
    CASE WHEN cohort_month < DATE '2020-12-01'
         THEN '1. fino a nov 2020' ELSE '2. da dic 2020' END   AS periodo,
    COUNT(*)                                                   AS clienti,
    ROUND(COUNT(*) / COUNT(DISTINCT cohort_month), 0)          AS nuovi_clienti_al_mese,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE return_ts <= first_order_ts + INTERVAL 3 MONTH
    ) / COUNT(*), 1)                                           AS ritorno_entro_3_mesi_pct
FROM customer_first_repeat
WHERE first_order_ts + INTERVAL 3 MONTH <= TIMESTAMP '2021-12-01'
GROUP BY periodo
ORDER BY periodo;


-- -----------------------------------------------------------------------------
-- 9. ESPORTAZIONE della matrice per i grafici (heatmap di coorte)
-- -----------------------------------------------------------------------------
COPY cohort_retention TO 'results/cohort_retention.csv' (HEADER, DELIMITER ',');

-- =============================================================================
-- 02_eda.sql
-- Progetto: Jewelry Customer Retention Analysis
-- Obiettivo: analisi esplorativa del business: trend nel tempo, stagionalità,
--            e prodotti (categorie, pietre, metalli, fasce di prezzo).
--
-- Input:  data/processed/orders_clean.parquet  (prodotto da 01_data_quality.sql)
-- Output: results/eda_monthly_trend.csv
--         results/eda_categories.csv
--         results/eda_price_bands.csv
--
-- Come eseguirlo (dalla cartella principale del progetto):
--     duckdb jewelry.duckdb
--     .read sql/02_eda.sql
--
-- Nota sui conteggi: il file ha una riga per articolo. Gli ORDINI si contano
-- sempre con COUNT(DISTINCT order_id), mai con COUNT(*), che conta gli articoli.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CARICAMENTO DELLA TABELLA PULITA
-- Una vista non copia i dati: legge direttamente il file Parquet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW order_lines AS
SELECT * FROM 'data/processed/orders_clean.parquet';


-- -----------------------------------------------------------------------------
-- 2. KPI PER ANNO
-- Attenzione: il 2018 contiene solo dicembre e il 2021 si ferma a novembre,
-- quindi il confronto onesto è tra 2019 e 2020 (anni completi).
-- -----------------------------------------------------------------------------
SELECT
    year(order_ts)                                       AS anno,
    COUNT(DISTINCT date_trunc('month', order_ts))        AS mesi_coperti,
    COUNT(DISTINCT order_id)                             AS ordini,
    COUNT(DISTINCT user_id)                              AS clienti,
    ROUND(SUM(price * quantity), 0)                      AS fatturato,
    ROUND(SUM(price * quantity) / COUNT(DISTINCT order_id), 2) AS scontrino_medio
FROM order_lines
GROUP BY anno
ORDER BY anno;


-- -----------------------------------------------------------------------------
-- 3. TREND MENSILE
-- Ordini, clienti, fatturato e scontrino medio per mese.
-- Aggiungiamo la crescita rispetto allo stesso mese dell'anno prima (YoY),
-- che neutralizza la stagionalità: confrontare dicembre con novembre
-- direbbe poco, confrontare dicembre con il dicembre precedente sì.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE eda_monthly_trend AS
WITH mensile AS (
    SELECT
        date_trunc('month', order_ts)            AS mese,
        COUNT(DISTINCT order_id)                 AS ordini,
        COUNT(DISTINCT user_id)                  AS clienti,
        ROUND(SUM(price * quantity), 0)          AS fatturato
    FROM order_lines
    GROUP BY mese
)
SELECT
    mese,
    ordini,
    clienti,
    fatturato,
    ROUND(fatturato / ordini, 2)                                     AS scontrino_medio,
    -- LAG(..., 12) prende il valore di 12 righe prima = stesso mese anno precedente
    ROUND(100.0 * (fatturato / LAG(fatturato, 12) OVER (ORDER BY mese) - 1), 1) AS crescita_fatturato_yoy_pct
FROM mensile
ORDER BY mese;

SELECT * FROM eda_monthly_trend;


-- -----------------------------------------------------------------------------
-- 4. STAGIONALITÀ
-- 4a. I giorni con più ordini: dove cadono i picchi?
-- Ci aspettiamo Black Friday (fine novembre) e i giorni prima di Natale.
-- -----------------------------------------------------------------------------
SELECT
    CAST(order_ts AS DATE)        AS giorno,
    dayname(order_ts)             AS giorno_settimana,
    COUNT(DISTINCT order_id)      AS ordini
FROM order_lines
GROUP BY giorno, giorno_settimana
ORDER BY ordini DESC
LIMIT 10;

-- 4b. Peso di novembre e dicembre sul fatturato annuo (solo anni completi)
SELECT
    year(order_ts)                                                    AS anno,
    ROUND(100.0 * SUM(price) FILTER (WHERE month(order_ts) IN (11, 12))
          / SUM(price), 1)                                            AS quota_nov_dic_pct
FROM order_lines
WHERE year(order_ts) IN (2019, 2020)
GROUP BY anno
ORDER BY anno;

-- 4c. Giorno della settimana
-- isodow: 1 = lunedì ... 7 = domenica, serve solo per ordinare
SELECT
    isodow(order_ts)              AS n_giorno,
    dayname(order_ts)             AS giorno_settimana,
    COUNT(DISTINCT order_id)      AS ordini,
    ROUND(100.0 * COUNT(DISTINCT order_id)
          / SUM(COUNT(DISTINCT order_id)) OVER (), 1) AS perc_ordini
FROM order_lines
GROUP BY n_giorno, giorno_settimana
ORDER BY n_giorno;

-- 4d. Ora del giorno
-- Gli orari sono in UTC. Se il negozio è russo, come suggeriscono i dati
-- (vedi 01), l'ora locale di Mosca è UTC+3: un picco alle 10-11 UTC
-- corrisponde a 13-14 ora locale, cioè la pausa pranzo.
SELECT
    hour(order_ts)                AS ora_utc,
    COUNT(DISTINCT order_id)      AS ordini
FROM order_lines
GROUP BY ora_utc
ORDER BY ora_utc;


-- -----------------------------------------------------------------------------
-- 5. PRODOTTI: CATEGORIE
-- Per ogni categoria: articoli venduti, fatturato, quota sul totale e prezzo
-- mediano. Il prezzo mediano è più robusto della media, che sarebbe tirata
-- su dai pochi gioielli molto costosi.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE eda_categories AS
SELECT
    COALESCE(category_code, 'non specificata')                        AS categoria,
    COUNT(*)                                                          AS articoli,
    ROUND(SUM(price * quantity), 0)                                   AS fatturato,
    ROUND(100.0 * SUM(price * quantity) / SUM(SUM(price * quantity)) OVER (), 1) AS quota_fatturato_pct,
    ROUND(median(price), 2)                                           AS prezzo_mediano
FROM order_lines
GROUP BY categoria
ORDER BY fatturato DESC;

SELECT * FROM eda_categories;


-- -----------------------------------------------------------------------------
-- 6. PRODOTTI: PIETRE, METALLI, COLORI
-- -----------------------------------------------------------------------------
-- Pietre: le prime 10 per fatturato
SELECT
    COALESCE(main_gem, 'non specificata')                             AS pietra,
    COUNT(*)                                                          AS articoli,
    ROUND(SUM(price * quantity), 0)                                   AS fatturato,
    ROUND(100.0 * SUM(price * quantity) / SUM(SUM(price * quantity)) OVER (), 1) AS quota_fatturato_pct,
    ROUND(median(price), 2)                                           AS prezzo_mediano
FROM order_lines
GROUP BY pietra
ORDER BY fatturato DESC
LIMIT 10;

-- Metalli
SELECT
    COALESCE(main_metal, 'non specificato')                           AS metallo,
    COUNT(*)                                                          AS articoli,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS quota_articoli_pct,
    ROUND(median(price), 2)                                           AS prezzo_mediano
FROM order_lines
GROUP BY metallo
ORDER BY articoli DESC;

-- Colore del metallo: 'red' = oro rosso, il prodotto di riferimento del negozio
SELECT
    COALESCE(main_color, 'non specificato')                           AS colore,
    COUNT(*)                                                          AS articoli,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS quota_articoli_pct,
    ROUND(median(price), 2)                                           AS prezzo_mediano
FROM order_lines
GROUP BY colore
ORDER BY articoli DESC;

-- Genere a cui è destinato il prodotto (metà delle righe non è specificata)
SELECT
    COALESCE(target_gender, 'non specificato')                        AS genere,
    COUNT(*)                                                          AS articoli,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS quota_articoli_pct
FROM order_lines
GROUP BY genere
ORDER BY articoli DESC;


-- -----------------------------------------------------------------------------
-- 7. FASCE DI PREZZO
-- Dove si concentrano volumi e fatturato? Spesso pochi articoli costosi
-- pesano molto sul fatturato: lo verifichiamo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE eda_price_bands AS
SELECT
    CASE
        WHEN price < 100   THEN '1. < 100'
        WHEN price < 250   THEN '2. 100-249'
        WHEN price < 500   THEN '3. 250-499'
        WHEN price < 1000  THEN '4. 500-999'
        WHEN price < 2000  THEN '5. 1.000-1.999'
        ELSE                    '6. 2.000+'
    END                                                               AS fascia_prezzo,
    COUNT(*)                                                          AS articoli,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS quota_articoli_pct,
    ROUND(SUM(price * quantity), 0)                                   AS fatturato,
    ROUND(100.0 * SUM(price * quantity) / SUM(SUM(price * quantity)) OVER (), 1) AS quota_fatturato_pct
FROM order_lines
GROUP BY fascia_prezzo
ORDER BY fascia_prezzo;

SELECT * FROM eda_price_bands;


-- -----------------------------------------------------------------------------
-- 8. PRODOTTI PIÙ VENDUTI
-- I nomi dei prodotti non sono nel dataset: li descriviamo con i loro
-- attributi (categoria, metallo, pietra).
-- -----------------------------------------------------------------------------
SELECT
    product_id,
    ANY_VALUE(category_code)          AS categoria,
    ANY_VALUE(main_metal)             AS metallo,
    ANY_VALUE(main_gem)               AS pietra,
    COUNT(*)                          AS articoli_venduti,
    ROUND(median(price), 2)           AS prezzo_mediano,
    ROUND(SUM(price * quantity), 0)   AS fatturato
FROM order_lines
GROUP BY product_id
ORDER BY articoli_venduti DESC
LIMIT 10;

-- Concentrazione del catalogo: quanti prodotti fanno l'80% del fatturato?
WITH per_prodotto AS (
    SELECT product_id, SUM(price * quantity) AS fatturato
    FROM order_lines
    GROUP BY product_id
),
cumulato AS (
    SELECT
        fatturato,
        SUM(fatturato) OVER (ORDER BY fatturato DESC) / SUM(fatturato) OVER () AS quota_cumulata
    FROM per_prodotto
)
SELECT
    (SELECT COUNT(*) FROM per_prodotto)                                AS prodotti_totali,
    COUNT(*) FILTER (WHERE quota_cumulata <= 0.8)                      AS prodotti_per_80pct_fatturato,
    ROUND(100.0 * COUNT(*) FILTER (WHERE quota_cumulata <= 0.8) / COUNT(*), 1) AS perc_catalogo
FROM cumulato;


-- -----------------------------------------------------------------------------
-- 9. ESPORTAZIONE dei risultati per i grafici del README
-- (la cartella results/ deve esistere)
-- -----------------------------------------------------------------------------
COPY eda_monthly_trend TO 'results/eda_monthly_trend.csv' (HEADER, DELIMITER ',');
COPY eda_categories    TO 'results/eda_categories.csv'    (HEADER, DELIMITER ',');
COPY eda_price_bands   TO 'results/eda_price_bands.csv'   (HEADER, DELIMITER ',');

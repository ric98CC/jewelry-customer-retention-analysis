-- =============================================================================
-- 05_basket.sql
-- Progetto: Jewelry Customer Retention Analysis
-- Obiettivo: market basket analysis. Quali prodotti e categorie vengono
--            acquistati insieme nello stesso ordine? Serve a costruire
--            bundle, cross-selling nelle email post-acquisto e raccomandazioni.
--
-- Input:  data/processed/orders_clean.parquet  (prodotto da 01_data_quality.sql)
-- Output: results/05_basket_size.csv
--         results/05_category_pairs.csv
--         results/05_product_pairs.csv
--
-- Come eseguirlo (dalla cartella principale del progetto):
--     duckdb data/jewelry.duckdb < sql/05_basket.sql
--
-- Le tre metriche classiche dell'analisi del carrello, per una coppia A-B:
--   - support    = % di ordini che contengono sia A che B
--                  (quanto è frequente la coppia)
--   - confidence = % degli ordini con A che contengono anche B
--                  (se compro A, quanto è probabile che compri anche B?)
--   - lift       = confidence / % di ordini che contengono B
--                  lift > 1: A e B si comprano insieme PIÙ del caso
--                  lift = 1: nessuna relazione
--                  lift < 1: tendono a escludersi
--   Il lift è la metrica più importante: una coppia può essere frequente
--   solo perché entrambi i prodotti sono molto venduti (es. orecchini e
--   anelli), senza che ci sia un vero legame tra loro.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CARICAMENTO DELLA TABELLA PULITA
-- Come negli script precedenti, una vista legge direttamente il file Parquet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW order_lines AS
SELECT * FROM 'data/processed/orders_clean.parquet';


-- -----------------------------------------------------------------------------
-- 2. DIMENSIONE DEL CARRELLO
-- Prima domanda: quanti ordini contengono più di un articolo?
-- Se sono pochi, l'analisi delle coppie si basa su un campione ridotto
-- e va interpretata con cautela (da dichiarare nel README).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE basket_size AS
WITH articoli_per_ordine AS (
    SELECT order_id, COUNT(*) AS n_articoli
    FROM order_lines
    GROUP BY order_id
)
SELECT
    CASE WHEN n_articoli >= 4 THEN '4+' ELSE CAST(n_articoli AS VARCHAR) END AS articoli_nell_ordine,
    COUNT(*)                                                                AS ordini,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS perc_ordini
FROM articoli_per_ordine
GROUP BY articoli_nell_ordine
ORDER BY articoli_nell_ordine;

SELECT * FROM basket_size;

-- Lo scontrino medio cresce con il numero di articoli?
-- Se sì, spingere il secondo articolo (bundle, "completa il set") conviene.
SELECT
    CASE WHEN n_articoli = 1 THEN 'mono-articolo' ELSE 'multi-articolo' END AS tipo_ordine,
    COUNT(*)                                                               AS ordini,
    ROUND(AVG(valore), 2)                                                  AS scontrino_medio,
    ROUND(median(valore), 2)                                               AS scontrino_mediano
FROM (
    SELECT order_id, COUNT(*) AS n_articoli, SUM(price * quantity) AS valore
    FROM order_lines
    GROUP BY order_id
)
GROUP BY tipo_ordine
ORDER BY tipo_ordine;


-- -----------------------------------------------------------------------------
-- 3. COPPIE DI CATEGORIE
-- Lavoriamo a livello di categoria e non di singolo prodotto: con circa
-- 8.500 prodotti diversi, quasi ogni coppia di prodotti compare troppo poche
-- volte per dire qualcosa. Le categorie danno segnali più solidi.
-- Le righe senza categoria vengono escluse da questa analisi.
-- -----------------------------------------------------------------------------

-- 3a. Categorie distinte per ordine (un ordine con due anelli conta "ring" una volta)
-- Solo ordini con almeno 2 articoli. Scelta importante: oltre l'80% degli
-- ordini contiene un solo articolo. Se li includessimo nel denominatore,
-- ogni coppia risulterebbe "più rara del caso" (lift < 1 per tutte),
-- non perché le categorie si escludano, ma perché quasi nessuno compra
-- più di un pezzo. La domanda corretta è: QUANDO un cliente compra più
-- articoli, quali categorie abbina?
CREATE OR REPLACE TABLE order_categories AS
SELECT DISTINCT
    order_id,
    replace(category_code, 'jewelry.', '') AS categoria
FROM order_lines
WHERE category_code IS NOT NULL
  AND order_id IN (
      SELECT order_id FROM order_lines GROUP BY order_id HAVING COUNT(*) >= 2
  );

-- 3b. Coppie, support, confidence e lift
-- La condizione a.categoria < b.categoria evita di contare due volte la stessa
-- coppia (anello-orecchino e orecchino-anello) e le coppie di una categoria
-- con sé stessa. Calcoliamo la confidence in entrambe le direzioni,
-- perché non è simmetrica: P(B|A) è diversa da P(A|B).
CREATE OR REPLACE TABLE category_pairs AS
WITH totale AS (
    SELECT COUNT(DISTINCT order_id) AS n_ordini FROM order_categories
),
per_categoria AS (
    SELECT categoria, COUNT(*) AS ordini_con_categoria
    FROM order_categories
    GROUP BY categoria
),
coppie AS (
    SELECT a.categoria AS categoria_a, b.categoria AS categoria_b, COUNT(*) AS ordini_insieme
    FROM order_categories AS a
    JOIN order_categories AS b
      ON a.order_id = b.order_id
     AND a.categoria < b.categoria
    GROUP BY categoria_a, categoria_b
)
SELECT
    c.categoria_a,
    c.categoria_b,
    c.ordini_insieme,
    ROUND(100.0 * c.ordini_insieme / t.n_ordini, 2)                    AS support_pct,
    ROUND(100.0 * c.ordini_insieme / pa.ordini_con_categoria, 1)       AS confidence_a_b_pct,
    ROUND(100.0 * c.ordini_insieme / pb.ordini_con_categoria, 1)       AS confidence_b_a_pct,
    ROUND((1.0 * c.ordini_insieme / pa.ordini_con_categoria)
          / (1.0 * pb.ordini_con_categoria / t.n_ordini), 2)           AS lift
FROM coppie AS c
CROSS JOIN totale AS t
JOIN per_categoria AS pa ON pa.categoria = c.categoria_a
JOIN per_categoria AS pb ON pb.categoria = c.categoria_b
WHERE c.ordini_insieme >= 20          -- soglia minima: sotto, il lift è rumore
ORDER BY lift DESC;

SELECT * FROM category_pairs;

-- 3c. Più pezzi della STESSA categoria nello stesso ordine
-- Le coppie sopra escludono "anello + anello". Ma in gioielleria comprare
-- due pezzi uguali o simili (es. due paia di orecchini, fedi di coppia)
-- è un comportamento a sé, che conviene misurare separatamente.
SELECT
    replace(category_code, 'jewelry.', '')                  AS categoria,
    COUNT(*)                                                AS ordini_con_piu_pezzi,
    ROUND(AVG(pezzi), 2)                                    AS pezzi_medi
FROM (
    SELECT order_id, category_code, COUNT(*) AS pezzi
    FROM order_lines
    WHERE category_code IS NOT NULL
    GROUP BY order_id, category_code
    HAVING COUNT(*) >= 2
)
GROUP BY categoria
ORDER BY ordini_con_piu_pezzi DESC;


-- -----------------------------------------------------------------------------
-- 4. COPPIE DI PRODOTTI
-- A livello di singolo prodotto guardiamo solo le coppie più frequenti,
-- descritte con i loro attributi (il dataset non ha i nomi dei prodotti).
-- Usiamo i prodotti distinti per ordine, come per le categorie.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE product_pairs AS
WITH prodotti_ordine AS (
    SELECT DISTINCT order_id, product_id
    FROM order_lines
),
attributi AS (
    -- un prodotto ha sempre gli stessi attributi: ne prendiamo uno qualsiasi
    SELECT
        product_id,
        ANY_VALUE(replace(category_code, 'jewelry.', '')) AS categoria,
        ANY_VALUE(main_gem)                                AS pietra,
        ROUND(median(price), 2)                            AS prezzo_mediano
    FROM order_lines
    GROUP BY product_id
),
coppie AS (
    SELECT a.product_id AS prodotto_a, b.product_id AS prodotto_b, COUNT(*) AS ordini_insieme
    FROM prodotti_ordine AS a
    JOIN prodotti_ordine AS b
      ON a.order_id = b.order_id
     AND a.product_id < b.product_id
    GROUP BY prodotto_a, prodotto_b
)
SELECT
    c.prodotto_a,
    aa.categoria       AS categoria_a,
    aa.pietra          AS pietra_a,
    aa.prezzo_mediano  AS prezzo_a,
    c.prodotto_b,
    ab.categoria       AS categoria_b,
    ab.pietra          AS pietra_b,
    ab.prezzo_mediano  AS prezzo_b,
    c.ordini_insieme
FROM coppie AS c
JOIN attributi AS aa ON aa.product_id = c.prodotto_a
JOIN attributi AS ab ON ab.product_id = c.prodotto_b
ORDER BY c.ordini_insieme DESC
LIMIT 20;

SELECT * FROM product_pairs;


-- -----------------------------------------------------------------------------
-- 5. ESPORTAZIONE dei risultati per i grafici del README
-- -----------------------------------------------------------------------------
COPY basket_size    TO 'results/05_basket_size.csv'    (HEADER, DELIMITER ',');
COPY category_pairs TO 'results/05_category_pairs.csv' (HEADER, DELIMITER ',');
COPY product_pairs  TO 'results/05_product_pairs.csv'  (HEADER, DELIMITER ',');

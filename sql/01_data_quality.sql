-- =============================================================================
-- 01_data_quality.sql
-- Progetto: Jewelry Customer Retention Analysis
-- Obiettivo: caricare i dati grezzi, diagnosticare i problemi di qualità,
--            correggerli e salvare una tabella pulita per le analisi successive.

-- -----------------------------------------------------------------------------
-- 1. CARICAMENTO DEI DATI GREZZI
-- Il CSV non ha intestazione: assegniamo noi i nomi alle colonne.
-- Carichiamo tutto come testo (VARCHAR) per due motivi:
--   - gli ID sono numeri a 19 cifre: come testo non perdiamo precisione;
--   - alcune righe sono sfasate (vedi punto 2) e una conversione immediata
--     a numero fallirebbe o produrrebbe valori sbagliati.
-- Alcune righe hanno 11 campi invece di 13: null_padding = true le carica
-- comunque, riempiendo con NULL le colonne mancanti in fondo.
-- auto_detect = false: il rilevamento automatico del formato si confonde
-- proprio per queste righe più corte, quindi gli indichiamo noi il formato.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw_orders AS
SELECT *
FROM read_csv(
    'data/raw/jewelry_raw_data.csv',
    header = false,
    delim = ',',
    quote = '"',
    auto_detect = false,
    null_padding = true,
    columns = {
        'event_time':    'VARCHAR',  -- data e ora dell'ordine (UTC)
        'order_id':      'VARCHAR',  -- ID ordine (un ordine può avere più righe)
        'product_id':    'VARCHAR',  -- ID prodotto
        'quantity':      'VARCHAR',  -- quantità della riga
        'category_id':   'VARCHAR',  -- ID categoria
        'category_code': 'VARCHAR',  -- nome categoria, es. jewelry.ring
        'brand_id':      'VARCHAR',  -- brand (codificato come numero)
        'price':         'VARCHAR',  -- prezzo dell'articolo (valuta non specificata)
        'user_id':       'VARCHAR',  -- ID cliente
        'target_gender': 'VARCHAR',  -- genere a cui è destinato il prodotto (f/m)
        'main_color':    'VARCHAR',  -- colore principale
        'main_metal':    'VARCHAR',  -- metallo principale
        'main_gem':      'VARCHAR'   -- pietra principale
    }
);

-- Quante righe abbiamo caricato?
SELECT COUNT(*) AS righe_totali FROM raw_orders;


-- -----------------------------------------------------------------------------
-- 2. DIAGNOSI: righe con colonne sfasate
-- Circa il 5,6% delle righe nel file ha 11 campi invece di 13: mancano
-- category_code e brand, e anche tutti gli attributi di prodotto (genere,
-- colore, metallo, pietra) sono vuoti. Una volta caricate, il prezzo finisce
-- nella colonna category_code e l'ID cliente nella colonna brand_id.
-- Le riconosciamo così: category_id è vuoto e category_code contiene un numero.
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*) AS righe_sfasate,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM raw_orders), 1) AS perc_sul_totale
FROM raw_orders
WHERE category_id IS NULL
  AND regexp_matches(category_code, '^[0-9]+(\.[0-9]+)?$');

-- Esempio di righe sfasate, per vedere il problema con i propri occhi
SELECT *
FROM raw_orders
WHERE category_id IS NULL
  AND regexp_matches(category_code, '^[0-9]+(\.[0-9]+)?$')
LIMIT 5;


-- -----------------------------------------------------------------------------
-- 3. CORREZIONE: riallineiamo le righe sfasate e convertiamo i tipi di dato
-- Invece di eliminare le righe sfasate (perderemmo il 5,6% degli ordini),
-- spostiamo prezzo e ID cliente nelle colonne corrette.
-- Normalizziamo anche i valori mancanti "travestiti": 'unknown-color'
-- in main_color diventa NULL, come gli altri colori non specificati.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE orders_fixed AS
WITH flagged AS (
    SELECT
        *,
        (category_id IS NULL
         AND regexp_matches(category_code, '^[0-9]+(\.[0-9]+)?$')) AS is_shifted
    FROM raw_orders
)
SELECT
    -- la data arriva come "2018-12-01 11:40:29 UTC": togliamo " UTC" e convertiamo
    CAST(replace(event_time, ' UTC', '') AS TIMESTAMP)                  AS order_ts,
    order_id,
    product_id,
    CAST(quantity AS INTEGER)                                           AS quantity,
    category_id,
    CASE WHEN is_shifted THEN NULL ELSE category_code END               AS category_code,
    CASE WHEN is_shifted THEN NULL ELSE brand_id END                    AS brand_id,
    CAST(CASE WHEN is_shifted THEN category_code ELSE price END
         AS DECIMAL(10, 2))                                             AS price,
    CASE WHEN is_shifted THEN brand_id ELSE user_id END                 AS user_id,
    target_gender,
    NULLIF(main_color, 'unknown-color')                                 AS main_color,
    main_metal,
    main_gem,
    is_shifted                                                          AS was_realigned
FROM flagged;

-- Verifica: dopo la correzione, quanti prezzi e clienti mancano ancora?
SELECT
    COUNT(*) FILTER (WHERE price IS NULL)    AS prezzi_mancanti,
    COUNT(*) FILTER (WHERE user_id IS NULL)  AS clienti_mancanti,
    COUNT(*) FILTER (WHERE was_realigned)    AS righe_riallineate
FROM orders_fixed;


-- -----------------------------------------------------------------------------
-- 4. PANORAMICA: periodo coperto e numeri chiave del business
-- La calcoliamo DOPO il riallineamento: sui dati grezzi l'ID cliente delle
-- righe sfasate è ancora nella colonna sbagliata e i clienti risulterebbero
-- sottostimati.
-- -----------------------------------------------------------------------------
SELECT
    MIN(order_ts)                AS primo_ordine,
    MAX(order_ts)                AS ultimo_ordine,
    COUNT(DISTINCT order_id)     AS ordini_unici,
    COUNT(DISTINCT user_id)      AS clienti_unici,
    COUNT(DISTINCT product_id)   AS prodotti_unici
FROM orders_fixed;

-- Controllo di coerenza: ogni ordine deve avere un solo cliente e un solo
-- timestamp, così possiamo usare order_id come chiave affidabile.
SELECT
    COUNT(*) FILTER (WHERE n_clienti > 1)    AS ordini_con_piu_clienti,
    COUNT(*) FILTER (WHERE n_timestamp > 1)  AS ordini_con_piu_timestamp
FROM (
    SELECT
        order_id,
        COUNT(DISTINCT user_id)   AS n_clienti,
        COUNT(DISTINCT order_ts)  AS n_timestamp
    FROM orders_fixed
    GROUP BY order_id
);


-- -----------------------------------------------------------------------------
-- 5. DIAGNOSI: valori mancanti e valori delle categorie
-- I vuoti negli attributi di prodotto (categoria, pietra, genere) non sono
-- errori da correggere: li teniamo e li tratteremo come "non specificato".
-- -----------------------------------------------------------------------------
SELECT
    ROUND(100.0 * COUNT(*) FILTER (WHERE category_code IS NULL) / COUNT(*), 1) AS perc_null_categoria,
    ROUND(100.0 * COUNT(*) FILTER (WHERE brand_id      IS NULL) / COUNT(*), 1) AS perc_null_brand,
    ROUND(100.0 * COUNT(*) FILTER (WHERE target_gender IS NULL) / COUNT(*), 1) AS perc_null_genere,
    ROUND(100.0 * COUNT(*) FILTER (WHERE main_color    IS NULL) / COUNT(*), 1) AS perc_null_colore,
    ROUND(100.0 * COUNT(*) FILTER (WHERE main_metal    IS NULL) / COUNT(*), 1) AS perc_null_metallo,
    ROUND(100.0 * COUNT(*) FILTER (WHERE main_gem      IS NULL) / COUNT(*), 1) AS perc_null_pietra
FROM orders_fixed;

-- Categorie presenti. Nota: compare anche 'electronics.clocks' (orologi).
-- La teniamo come categoria a sé: sono acquisti reali degli stessi clienti
-- e contano per la retention.
SELECT category_code, COUNT(*) AS righe
FROM orders_fixed
GROUP BY category_code
ORDER BY righe DESC;

-- Colori presenti. 'red' domina (circa il 72%) su prodotti quasi tutti in oro:
-- indica quasi certamente l'oro rosso, non pietre rosse.
SELECT main_color, COUNT(*) AS righe
FROM orders_fixed
GROUP BY main_color
ORDER BY righe DESC;


-- -----------------------------------------------------------------------------
-- 6. DIAGNOSI: righe duplicate
-- Righe identiche in tutte le colonne. Attenzione all'interpretazione:
-- quantity vale sempre 1, quindi due pezzi uguali nello stesso ordine
-- potrebbero generare due righe identiche. Alcuni gruppi hanno 3-5 copie.
-- Ipotesi adottata: si tratta di registrazioni doppie, e le rimuoviamo.
-- Impatto sulla retention minimo (il numero di ordini per cliente non cambia);
-- impatto sul fatturato da dichiarare come limite nel README.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM orders_fixed)) AS righe_duplicate
FROM orders_fixed;

-- Quante copie ha ciascun gruppo di duplicati?
SELECT copie, COUNT(*) AS gruppi
FROM (
    SELECT COUNT(*) AS copie
    FROM orders_fixed
    GROUP BY order_ts, order_id, product_id, quantity, category_id,
             category_code, brand_id, price, user_id, target_gender,
             main_color, main_metal, main_gem, was_realigned
)
WHERE copie > 1
GROUP BY copie
ORDER BY copie;


-- -----------------------------------------------------------------------------
-- 7. DIAGNOSI: anomalie su quantità, prezzi e periodo
-- -----------------------------------------------------------------------------
-- Quantità: ci aspettiamo sempre 1 (una riga = un articolo)
SELECT quantity, COUNT(*) AS righe
FROM orders_fixed
GROUP BY quantity
ORDER BY righe DESC;

-- Distribuzione dei prezzi: minimo, quartili, massimo
SELECT
    MIN(price)                              AS prezzo_min,
    quantile_cont(price, 0.25)              AS q1,
    median(price)                           AS mediana,
    quantile_cont(price, 0.75)              AS q3,
    quantile_cont(price, 0.99)              AS p99,
    MAX(price)                              AS prezzo_max
FROM orders_fixed;

-- Prezzi a zero: quanti sono e da dove vengono?
-- Scoperta: si trovano TUTTI nelle righe riallineate.
SELECT
    COUNT(*) FILTER (WHERE price = 0)                    AS righe_prezzo_zero,
    COUNT(*) FILTER (WHERE price = 0 AND was_realigned)  AS di_cui_riallineate
FROM orders_fixed;

-- Quando compaiono? Solo da aprile 2021: prima le righe riallineate hanno
-- sempre un prezzo valido, dopo è a zero circa l'82%.
-- È un difetto di esportazione della sorgente (non omaggi o resi).
-- Escluderle è corretto, ma riduce leggermente gli ordini di aprile-novembre
-- 2021: limite da citare nel README.
SELECT
    date_trunc('month', order_ts)                         AS mese,
    COUNT(*) FILTER (WHERE was_realigned)                 AS righe_riallineate,
    COUNT(*) FILTER (WHERE was_realigned AND price = 0)   AS di_cui_prezzo_zero
FROM orders_fixed
GROUP BY mese
HAVING COUNT(*) FILTER (WHERE was_realigned) > 0
ORDER BY mese;

-- Quanti ordini sono composti SOLO da articoli a prezzo zero?
WITH totali_ordine AS (
    SELECT order_id, SUM(price) AS totale
    FROM orders_fixed
    GROUP BY order_id
)
SELECT COUNT(*) AS ordini_a_valore_zero
FROM totali_ordine
WHERE totale = 0;

-- I 10 prezzi più alti: sono gioielli di lusso plausibili o errori?
SELECT order_ts, order_id, category_code, main_metal, main_gem, price
FROM orders_fixed
ORDER BY price DESC NULLS LAST
LIMIT 10;

-- Ordini per mese: individuiamo mesi incompleti (es. dicembre 2021)
SELECT
    date_trunc('month', order_ts)  AS mese,
    COUNT(DISTINCT order_id)       AS ordini
FROM orders_fixed
GROUP BY mese
ORDER BY mese;


-- -----------------------------------------------------------------------------
-- 8. TABELLA PULITA FINALE
-- Regole applicate:
--   - rimozione dei duplicati esatti (ipotesi: registrazioni doppie, vedi punto 6);
--   - esclusione delle righe senza cliente o con prezzo mancante o pari a zero:
--     i prezzi a zero sono un difetto della sorgente e gonfierebbero ordini e
--     frequenza d'acquisto nell'analisi di retention;
--   - esclusione di dicembre 2021, che contiene un solo giorno di dati
--     e falserebbe i trend mensili.
-- I prezzi molto alti vengono tenuti: in gioielleria sono plausibili.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE orders_clean AS
SELECT DISTINCT *
FROM orders_fixed
WHERE price > 0
  AND user_id IS NOT NULL
  AND order_ts < TIMESTAMP '2021-12-01';

-- Riepilogo: quante righe abbiamo tenuto rispetto ai dati grezzi?
SELECT
    (SELECT COUNT(*) FROM raw_orders)            AS righe_grezze,
    COUNT(*)                                     AS righe_pulite,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM raw_orders), 1) AS perc_tenuta,
    COUNT(DISTINCT order_id)                     AS ordini,
    COUNT(DISTINCT user_id)                      AS clienti,
    ROUND(SUM(price * quantity), 0)              AS fatturato_totale
FROM orders_clean;

-- Primo indicatore di retention: quota di clienti con più di un ordine
WITH ordini_per_cliente AS (
    SELECT user_id, COUNT(DISTINCT order_id) AS n_ordini
    FROM orders_clean
    GROUP BY user_id
)
SELECT
    COUNT(*)                                                     AS clienti,
    COUNT(*) FILTER (WHERE n_ordini > 1)                         AS clienti_ricorrenti,
    ROUND(100.0 * COUNT(*) FILTER (WHERE n_ordini > 1) / COUNT(*), 1) AS perc_riacquisto
FROM ordini_per_cliente;


-- -----------------------------------------------------------------------------
-- 9. ESPORTAZIONE in Parquet per le fasi successive
-- (i file in data/ sono esclusi da Git tramite .gitignore)
-- -----------------------------------------------------------------------------
COPY orders_clean TO 'data/processed/orders_clean.parquet' (FORMAT PARQUET);

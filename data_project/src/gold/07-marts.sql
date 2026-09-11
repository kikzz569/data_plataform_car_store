CREATE OR REPLACE TABLE lakehouse.gold.mart_vendas_por_vendedor
USING DELTA
COMMENT 'Desempenho mensal por vendedor; contagens representam registros de venda, nao quantidade comprovada de veiculos.'
AS
SELECT
    V.SK_VENDEDOR,
    CAST(date_format(D.DATA, 'yyyyMM01') AS INT) AS SK_MES_ENTREGA,
    CAST(sum(V.VALOR_FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
    CAST(sum(V.MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM_BRUTA_CALCULADA,
    count(*) AS REGISTROS_VENDA,
    count(DISTINCT V.ID_CLIENTE_ORIGEM) AS CLIENTES_DISTINTOS,
    CAST(sum(V.VALOR_FATURAMENTO) / count(*) AS DECIMAL(18, 2)) AS TICKET_MEDIO_POR_REGISTRO
FROM lakehouse.gold.fato_vendas V
JOIN lakehouse.gold.dim_calendario D ON V.SK_DATA_ENTREGA = D.SK_DATA
GROUP BY V.SK_VENDEDOR, CAST(date_format(D.DATA, 'yyyyMM01') AS INT);

CREATE OR REPLACE TABLE lakehouse.gold.mart_produto_performance
USING DELTA
COMMENT 'Vendas e posicao de estoque por produto e mes, agregadas separadamente antes do relacionamento.'
AS
WITH vendas AS (
    SELECT
        V.SK_PRODUTO,
        CAST(date_format(D.DATA, 'yyyyMM01') AS INT) AS SK_MES,
        CAST(sum(V.VALOR_FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(V.MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM_BRUTA_CALCULADA,
        count(*) AS REGISTROS_VENDA
    FROM lakehouse.gold.fato_vendas V
    JOIN lakehouse.gold.dim_calendario D ON V.SK_DATA_ENTREGA = D.SK_DATA
    GROUP BY V.SK_PRODUTO, CAST(date_format(D.DATA, 'yyyyMM01') AS INT)
),
estoque AS (
    SELECT
        E.SK_PRODUTO,
        E.SK_DATA_REFERENCIA AS SK_MES,
        E.QUANTIDADE_ESTOQUE
    FROM lakehouse.gold.fato_estoque_mensal E
),
produto_mes AS (
    SELECT
        coalesce(V.SK_PRODUTO, E.SK_PRODUTO) AS SK_PRODUTO,
        coalesce(V.SK_MES, E.SK_MES) AS SK_MES,
        coalesce(V.FATURAMENTO, CAST(0 AS DECIMAL(18, 2))) AS FATURAMENTO,
        coalesce(V.MARGEM_BRUTA_CALCULADA, CAST(0 AS DECIMAL(18, 2))) AS MARGEM_BRUTA_CALCULADA,
        coalesce(V.REGISTROS_VENDA, 0) AS REGISTROS_VENDA,
        E.QUANTIDADE_ESTOQUE
    FROM vendas V
    FULL OUTER JOIN estoque E
        ON V.SK_PRODUTO = E.SK_PRODUTO AND V.SK_MES = E.SK_MES
),
participacao AS (
    SELECT
        *,
        sum(FATURAMENTO) OVER (PARTITION BY SK_MES) AS FATURAMENTO_MES,
        sum(FATURAMENTO) OVER (
            PARTITION BY SK_MES
            ORDER BY FATURAMENTO DESC, SK_PRODUTO
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS FATURAMENTO_ACUMULADO
    FROM produto_mes
)
SELECT
    SK_PRODUTO,
    SK_MES,
    FATURAMENTO,
    MARGEM_BRUTA_CALCULADA,
    CAST(
        CASE WHEN FATURAMENTO = 0 THEN NULL
            ELSE MARGEM_BRUTA_CALCULADA / FATURAMENTO * 100
        END AS DECIMAL(9, 4)
    ) AS MARGEM_PCT,
    REGISTROS_VENDA,
    CASE
        WHEN REGISTROS_VENDA = 0 THEN 'Sem Venda'
        WHEN FATURAMENTO_MES = 0 THEN 'C'
        WHEN FATURAMENTO_ACUMULADO / FATURAMENTO_MES <= 0.80 THEN 'A'
        WHEN FATURAMENTO_ACUMULADO / FATURAMENTO_MES <= 0.95 THEN 'B'
        ELSE 'C'
    END AS CURVA_ABC,
    QUANTIDADE_ESTOQUE
FROM participacao;

CREATE OR REPLACE TABLE lakehouse.gold.mart_financeiro
USING DELTA
COMMENT 'Valores financeiros mensais conciliados aos registros de venda pela data de entrega.'
AS
SELECT
    CAST(date_format(D.DATA, 'yyyyMM01') AS INT) AS SK_MES_ENTREGA,
    CAST(sum(V.VALOR_PADRAO) AS DECIMAL(18, 2)) AS VALOR_PADRAO,
    CAST(sum(V.DESCONTO) AS DECIMAL(18, 2)) AS DESCONTO,
    CAST(sum(V.VALOR_FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
    CAST(sum(V.CUSTO) AS DECIMAL(18, 2)) AS CUSTO,
    CAST(sum(V.MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM_BRUTA_CALCULADA
FROM lakehouse.gold.fato_vendas V
JOIN lakehouse.gold.dim_calendario D ON V.SK_DATA_ENTREGA = D.SK_DATA
GROUP BY CAST(date_format(D.DATA, 'yyyyMM01') AS INT);

CREATE OR REPLACE TABLE lakehouse.gold.mart_funil_comercial
USING DELTA
COMMENT 'Oportunidades por canal, produto, mes de interesse e etapa; nao representa historico completo de transicoes.'
AS
SELECT
    O.SK_CANAL,
    O.SK_PRODUTO,
    CAST(date_format(D.DATA, 'yyyyMM01') AS INT) AS SK_MES_INTERESSE,
    O.ETAPA,
    count(*) AS REGISTROS_OPORTUNIDADE,
    count(DISTINCT O.ID_CLIENTE_ORIGEM) AS CLIENTES_DISTINTOS,
    count_if(O.FEZ_TEST_DRIVE = true) AS REGISTROS_COM_TEST_DRIVE
FROM lakehouse.gold.fato_oportunidade O
JOIN lakehouse.gold.dim_calendario D ON O.SK_DATA_INTERESSE = D.SK_DATA
GROUP BY
    O.SK_CANAL,
    O.SK_PRODUTO,
    CAST(date_format(D.DATA, 'yyyyMM01') AS INT),
    O.ETAPA;

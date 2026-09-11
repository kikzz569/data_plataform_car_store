-- Os nove contratos sao avaliados juntos para que a saida mostre todos os resultados.
-- A consulta final levanta uma excecao unica contendo cada teste reprovado e interrompe o job.
CREATE OR REPLACE TEMP VIEW _gold_testes AS
WITH financeiro_silver AS (
    SELECT
        CAST(sum(VALOR_PADRAO) AS DECIMAL(18, 2)) AS VALOR_PADRAO,
        CAST(sum(DESCONTO) AS DECIMAL(18, 2)) AS DESCONTO,
        CAST(sum(VALOR_FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(CUSTO) AS DECIMAL(18, 2)) AS CUSTO,
        CAST(sum(VALOR_FATURAMENTO - CUSTO) AS DECIMAL(18, 2)) AS MARGEM
    FROM lakehouse.silver.erp
),
financeiro_fato AS (
    SELECT
        CAST(sum(VALOR_PADRAO) AS DECIMAL(18, 2)) AS VALOR_PADRAO,
        CAST(sum(DESCONTO) AS DECIMAL(18, 2)) AS DESCONTO,
        CAST(sum(VALOR_FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(CUSTO) AS DECIMAL(18, 2)) AS CUSTO,
        CAST(sum(MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM
    FROM lakehouse.gold.fato_vendas
),
rastreio_vendas AS (
    SELECT
        (SELECT count(*) FROM lakehouse.gold.fato_vendas) AS LINHAS_GOLD,
        (SELECT count(DISTINCT ID_REGISTRO) FROM lakehouse.gold.fato_vendas) AS IDS_GOLD,
        (SELECT count(*) FROM lakehouse.silver.erp) AS LINHAS_SILVER,
        (SELECT count(*) FROM lakehouse.silver.erp S
            LEFT ANTI JOIN lakehouse.gold.fato_vendas G ON S.ID_REGISTRO = G.ID_REGISTRO) AS AUSENTES,
        (SELECT count(*) FROM lakehouse.gold.fato_vendas G
            LEFT ANTI JOIN lakehouse.silver.erp S ON G.ID_REGISTRO = S.ID_REGISTRO) AS EXTRAS
),
rastreio_oportunidades AS (
    SELECT
        (SELECT count(*) FROM lakehouse.gold.fato_oportunidade) AS LINHAS_GOLD,
        (SELECT count(DISTINCT ID_REGISTRO) FROM lakehouse.gold.fato_oportunidade) AS IDS_GOLD,
        (SELECT count(*) FROM lakehouse.silver.crm) AS LINHAS_SILVER,
        (SELECT count(*) FROM lakehouse.silver.crm S
            LEFT ANTI JOIN lakehouse.gold.fato_oportunidade G ON S.ID_REGISTRO = G.ID_REGISTRO) AS AUSENTES,
        (SELECT count(*) FROM lakehouse.gold.fato_oportunidade G
            LEFT ANTI JOIN lakehouse.silver.crm S ON G.ID_REGISTRO = S.ID_REGISTRO) AS EXTRAS
),
rastreio_estoque AS (
    SELECT
        (SELECT count(*) FROM lakehouse.gold.fato_estoque_mensal) AS LINHAS_GOLD,
        (SELECT count(*) FROM lakehouse.gold.quarentena_estoque_mensal) AS LINHAS_QUARENTENA,
        (SELECT count(*) FROM lakehouse.silver.estoque) AS LINHAS_SILVER,
        (SELECT count(*) FROM (
            SELECT SK_PRODUTO, SK_DATA_REFERENCIA
            FROM lakehouse.gold.fato_estoque_mensal
            GROUP BY SK_PRODUTO, SK_DATA_REFERENCIA
            HAVING count(*) > 1
        )) AS GRAOS_DUPLICADOS,
        (SELECT count(*)
            FROM lakehouse.silver.estoque S
            LEFT ANTI JOIN (
                SELECT ID_REGISTRO FROM lakehouse.gold.fato_estoque_mensal
                UNION ALL
                SELECT ID_REGISTRO FROM lakehouse.gold.quarentena_estoque_mensal
            ) G ON S.ID_REGISTRO = G.ID_REGISTRO) AS AUSENTES,
        (SELECT count(*)
            FROM (
                SELECT ID_REGISTRO FROM lakehouse.gold.fato_estoque_mensal
                UNION ALL
                SELECT ID_REGISTRO FROM lakehouse.gold.quarentena_estoque_mensal
            ) G
            LEFT ANTI JOIN lakehouse.silver.estoque S ON G.ID_REGISTRO = S.ID_REGISTRO) AS EXTRAS,
        (SELECT count(*)
            FROM lakehouse.gold.fato_estoque_mensal F
            JOIN lakehouse.gold.quarentena_estoque_mensal Q ON F.ID_REGISTRO = Q.ID_REGISTRO) AS SOBREPOSICOES
),
orfaos AS (
    SELECT
        (SELECT count(*)
            FROM lakehouse.gold.fato_vendas F
            LEFT JOIN lakehouse.gold.dim_cliente C ON F.SK_CLIENTE = C.SK_CLIENTE
            LEFT JOIN lakehouse.gold.dim_produto P ON F.SK_PRODUTO = P.SK_PRODUTO
            LEFT JOIN lakehouse.gold.dim_vendedor V ON F.SK_VENDEDOR = V.SK_VENDEDOR
            LEFT JOIN lakehouse.gold.dim_pagamento PG ON F.SK_PAGAMENTO = PG.SK_PAGAMENTO
            LEFT JOIN lakehouse.gold.dim_calendario D ON F.SK_DATA_ENTREGA = D.SK_DATA
            LEFT JOIN lakehouse.gold.quarentena_cliente_identidade Q
                ON F.ID_CLIENTE_ORIGEM = Q.ID_CLIENTE
            WHERE (F.SK_CLIENTE IS NULL AND Q.ID_CLIENTE IS NULL)
                OR (F.SK_CLIENTE IS NOT NULL AND C.SK_CLIENTE IS NULL)
                OR (F.SK_CLIENTE IS NOT NULL AND Q.ID_CLIENTE IS NOT NULL)
                OR P.SK_PRODUTO IS NULL OR V.SK_VENDEDOR IS NULL
                OR PG.SK_PAGAMENTO IS NULL OR D.SK_DATA IS NULL) AS VENDAS,
        (SELECT count(*)
            FROM lakehouse.gold.fato_oportunidade F
            LEFT JOIN lakehouse.gold.dim_cliente C ON F.SK_CLIENTE = C.SK_CLIENTE
            LEFT JOIN lakehouse.gold.dim_produto P ON F.SK_PRODUTO = P.SK_PRODUTO
            LEFT JOIN lakehouse.gold.dim_pagamento PG ON F.SK_PAGAMENTO = PG.SK_PAGAMENTO
            LEFT JOIN lakehouse.gold.dim_canal CN ON F.SK_CANAL = CN.SK_CANAL
            LEFT JOIN lakehouse.gold.dim_calendario DI ON F.SK_DATA_INTERESSE = DI.SK_DATA
            LEFT JOIN lakehouse.gold.dim_calendario DU ON F.SK_DATA_ULTIMO_CONTATO = DU.SK_DATA
            LEFT JOIN lakehouse.gold.quarentena_cliente_identidade Q
                ON F.ID_CLIENTE_ORIGEM = Q.ID_CLIENTE
            WHERE (F.SK_CLIENTE IS NULL AND Q.ID_CLIENTE IS NULL)
                OR (F.SK_CLIENTE IS NOT NULL AND C.SK_CLIENTE IS NULL)
                OR (F.SK_CLIENTE IS NOT NULL AND Q.ID_CLIENTE IS NOT NULL)
                OR P.SK_PRODUTO IS NULL OR PG.SK_PAGAMENTO IS NULL
                OR CN.SK_CANAL IS NULL OR DI.SK_DATA IS NULL OR DU.SK_DATA IS NULL) AS OPORTUNIDADES,
        (SELECT count(*)
            FROM lakehouse.gold.fato_estoque_mensal F
            LEFT JOIN lakehouse.gold.dim_produto P ON F.SK_PRODUTO = P.SK_PRODUTO
            LEFT JOIN lakehouse.gold.dim_calendario D ON F.SK_DATA_REFERENCIA = D.SK_DATA
            WHERE P.SK_PRODUTO IS NULL OR D.SK_DATA IS NULL) AS ESTOQUE
),
mart_vendedor AS (
    SELECT
        CAST(sum(FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM,
        sum(REGISTROS_VENDA) AS REGISTROS
    FROM lakehouse.gold.mart_vendas_por_vendedor
),
mart_produto AS (
    SELECT
        CAST(sum(FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM,
        sum(REGISTROS_VENDA) AS REGISTROS,
        (SELECT count(*)
            FROM lakehouse.gold.fato_estoque_mensal E
            LEFT ANTI JOIN lakehouse.gold.mart_produto_performance M
                ON E.SK_PRODUTO = M.SK_PRODUTO AND E.SK_DATA_REFERENCIA = M.SK_MES) AS ESTOQUES_AUSENTES
    FROM lakehouse.gold.mart_produto_performance
),
resumo_mart_financeiro AS (
    SELECT
        CAST(sum(VALOR_PADRAO) AS DECIMAL(18, 2)) AS VALOR_PADRAO,
        CAST(sum(DESCONTO) AS DECIMAL(18, 2)) AS DESCONTO,
        CAST(sum(FATURAMENTO) AS DECIMAL(18, 2)) AS FATURAMENTO,
        CAST(sum(CUSTO) AS DECIMAL(18, 2)) AS CUSTO,
        CAST(sum(MARGEM_BRUTA_CALCULADA) AS DECIMAL(18, 2)) AS MARGEM
    FROM lakehouse.gold.mart_financeiro
),
funil_esperado AS (
    SELECT
        O.SK_CANAL,
        O.SK_PRODUTO,
        CAST(date_format(D.DATA, 'yyyyMM01') AS INT) AS SK_MES_INTERESSE,
        O.ETAPA,
        count(*) AS REGISTROS,
        count(DISTINCT O.ID_CLIENTE_ORIGEM) AS CLIENTES,
        count_if(O.FEZ_TEST_DRIVE = true) AS TEST_DRIVES
    FROM lakehouse.gold.fato_oportunidade O
    JOIN lakehouse.gold.dim_calendario D ON O.SK_DATA_INTERESSE = D.SK_DATA
    GROUP BY O.SK_CANAL, O.SK_PRODUTO, CAST(date_format(D.DATA, 'yyyyMM01') AS INT), O.ETAPA
),
funil_comparacao AS (
    SELECT
        count_if(NOT (
            M.REGISTROS_OPORTUNIDADE <=> E.REGISTROS
            AND M.CLIENTES_DISTINTOS <=> E.CLIENTES
            AND M.REGISTROS_COM_TEST_DRIVE <=> E.TEST_DRIVES
        )) AS GRUPOS_DIVERGENTES,
        sum(M.REGISTROS_OPORTUNIDADE) AS REGISTROS_MART,
        (SELECT count(*) FROM lakehouse.gold.fato_oportunidade) AS REGISTROS_FATO,
        sum(M.REGISTROS_COM_TEST_DRIVE) AS TEST_DRIVES_MART,
        (SELECT count_if(FEZ_TEST_DRIVE = true) FROM lakehouse.gold.fato_oportunidade) AS TEST_DRIVES_FATO
    FROM lakehouse.gold.mart_funil_comercial M
    FULL OUTER JOIN funil_esperado E
        ON M.SK_CANAL <=> E.SK_CANAL
        AND M.SK_PRODUTO <=> E.SK_PRODUTO
        AND M.SK_MES_INTERESSE <=> E.SK_MES_INTERESSE
        AND M.ETAPA <=> E.ETAPA
)
SELECT
    1 AS ORDEM,
    'financeiro_fato_vs_erp' AS TESTE,
    to_json(named_struct('faturamento', G.FATURAMENTO, 'margem', G.MARGEM)) AS VALOR_CALCULADO,
    to_json(named_struct('faturamento', S.FATURAMENTO, 'margem', S.MARGEM)) AS VALOR_ESPERADO,
    abs(G.FATURAMENTO - S.FATURAMENTO) <= 0.01 AND abs(G.MARGEM - S.MARGEM) <= 0.01 AS PASSOU
FROM financeiro_fato G CROSS JOIN financeiro_silver S
UNION ALL
SELECT 2, 'rastreabilidade_fato_vendas',
    to_json(named_struct('linhas', LINHAS_GOLD, 'ids', IDS_GOLD, 'ausentes', AUSENTES, 'extras', EXTRAS)),
    to_json(named_struct('linhas', LINHAS_SILVER, 'ids', LINHAS_SILVER, 'ausentes', 0, 'extras', 0)),
    LINHAS_GOLD = LINHAS_SILVER AND IDS_GOLD = LINHAS_GOLD AND AUSENTES = 0 AND EXTRAS = 0
FROM rastreio_vendas
UNION ALL
SELECT 3, 'rastreabilidade_fato_oportunidade',
    to_json(named_struct('linhas', LINHAS_GOLD, 'ids', IDS_GOLD, 'ausentes', AUSENTES, 'extras', EXTRAS)),
    to_json(named_struct('linhas', LINHAS_SILVER, 'ids', LINHAS_SILVER, 'ausentes', 0, 'extras', 0)),
    LINHAS_GOLD = LINHAS_SILVER AND IDS_GOLD = LINHAS_GOLD AND AUSENTES = 0 AND EXTRAS = 0
FROM rastreio_oportunidades
UNION ALL
SELECT 4, 'grao_e_rastreabilidade_estoque',
    to_json(named_struct('aceitas', LINHAS_GOLD, 'quarentena', LINHAS_QUARENTENA,
        'total_silver', LINHAS_SILVER, 'graos_duplicados', GRAOS_DUPLICADOS,
        'ausentes', AUSENTES, 'extras', EXTRAS, 'sobreposicoes', SOBREPOSICOES)),
    to_json(named_struct('aceitas_mais_quarentena', LINHAS_SILVER, 'graos_duplicados', 0,
        'ausentes', 0, 'extras', 0, 'sobreposicoes', 0)),
    LINHAS_GOLD + LINHAS_QUARENTENA = LINHAS_SILVER
        AND GRAOS_DUPLICADOS = 0 AND AUSENTES = 0 AND EXTRAS = 0 AND SOBREPOSICOES = 0
FROM rastreio_estoque
UNION ALL
SELECT 5, 'integridade_dimensional',
    to_json(named_struct('vendas_orfas', VENDAS, 'oportunidades_orfas', OPORTUNIDADES, 'estoque_orfao', ESTOQUE)),
    '{"vendas_orfas":0,"oportunidades_orfas":0,"estoque_orfao":0}',
    VENDAS = 0 AND OPORTUNIDADES = 0 AND ESTOQUE = 0
FROM orfaos
UNION ALL
SELECT 6, 'mart_vendas_por_vendedor_vs_fato',
    to_json(named_struct('faturamento', M.FATURAMENTO, 'margem', M.MARGEM, 'registros', M.REGISTROS)),
    to_json(named_struct('faturamento', F.FATURAMENTO, 'margem', F.MARGEM,
        'registros', (SELECT count(*) FROM lakehouse.gold.fato_vendas))),
    abs(M.FATURAMENTO - F.FATURAMENTO) <= 0.01
        AND abs(M.MARGEM - F.MARGEM) <= 0.01
        AND M.REGISTROS = (SELECT count(*) FROM lakehouse.gold.fato_vendas)
FROM mart_vendedor M CROSS JOIN financeiro_fato F
UNION ALL
SELECT 7, 'mart_produto_performance_vs_fatos',
    to_json(named_struct('faturamento', M.FATURAMENTO, 'margem', M.MARGEM,
        'registros', M.REGISTROS, 'estoques_ausentes', M.ESTOQUES_AUSENTES)),
    to_json(named_struct('faturamento', F.FATURAMENTO, 'margem', F.MARGEM,
        'registros', (SELECT count(*) FROM lakehouse.gold.fato_vendas), 'estoques_ausentes', 0)),
    abs(M.FATURAMENTO - F.FATURAMENTO) <= 0.01
        AND abs(M.MARGEM - F.MARGEM) <= 0.01
        AND M.REGISTROS = (SELECT count(*) FROM lakehouse.gold.fato_vendas)
        AND M.ESTOQUES_AUSENTES = 0
FROM mart_produto M CROSS JOIN financeiro_fato F
UNION ALL
SELECT 8, 'mart_financeiro_vs_fato',
    to_json(named_struct('valor_padrao', M.VALOR_PADRAO, 'desconto', M.DESCONTO,
        'faturamento', M.FATURAMENTO, 'custo', M.CUSTO, 'margem', M.MARGEM)),
    to_json(named_struct('valor_padrao', F.VALOR_PADRAO, 'desconto', F.DESCONTO,
        'faturamento', F.FATURAMENTO, 'custo', F.CUSTO, 'margem', F.MARGEM)),
    abs(M.VALOR_PADRAO - F.VALOR_PADRAO) <= 0.01
        AND abs(M.DESCONTO - F.DESCONTO) <= 0.01
        AND abs(M.FATURAMENTO - F.FATURAMENTO) <= 0.01
        AND abs(M.CUSTO - F.CUSTO) <= 0.01
        AND abs(M.MARGEM - F.MARGEM) <= 0.01
FROM resumo_mart_financeiro M CROSS JOIN financeiro_fato F
UNION ALL
SELECT 9, 'mart_funil_comercial_vs_fato',
    to_json(named_struct('grupos_divergentes', GRUPOS_DIVERGENTES, 'registros', REGISTROS_MART,
        'test_drives', TEST_DRIVES_MART)),
    to_json(named_struct('grupos_divergentes', 0, 'registros', REGISTROS_FATO, 'test_drives', TEST_DRIVES_FATO)),
    GRUPOS_DIVERGENTES = 0 AND REGISTROS_MART = REGISTROS_FATO AND TEST_DRIVES_MART = TEST_DRIVES_FATO
FROM funil_comparacao;

SELECT TESTE, VALOR_CALCULADO, VALOR_ESPERADO, PASSOU
FROM _gold_testes
ORDER BY ORDEM;

SELECT CASE
    WHEN count_if(NOT PASSOU) > 0 THEN raise_error(concat(
        'Testes Gold falharam: ',
        concat_ws('; ', sort_array(collect_list(IF(
            NOT PASSOU,
            concat(TESTE, ' calculado=', VALOR_CALCULADO, ' esperado=', VALOR_ESPERADO),
            NULL
        ))))
    ))
    ELSE '9/9 testes Gold passaram.'
END AS RESULTADO
FROM _gold_testes;

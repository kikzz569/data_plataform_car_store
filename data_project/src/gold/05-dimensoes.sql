-- Conflitos conhecidos sao materializados antes das dimensoes. A Gold continua sem
-- unir identidades ambiguas nem escolher um saldo entre versoes do mesmo produto/mes.
CREATE OR REPLACE TABLE lakehouse.gold.quarentena_cliente_identidade
USING DELTA
COMMENT 'IDs de cliente com atributos incompatíveis no CRM ou ERP; permanecem fora da dimensão até revisão.'
AS
WITH atributos_cliente AS (
    SELECT ID_CLIENTE, CLIENTE AS NOME, GENERO, CONTATO, CAST(NULL AS DATE) AS DATA_NASCIMENTO
    FROM lakehouse.silver.crm
    UNION ALL
    SELECT ID_CLIENTE, NOME_CLIENTE AS NOME, CAST(NULL AS STRING), CAST(NULL AS STRING), DATA_NASCIMENTO
    FROM lakehouse.silver.erp
)
SELECT
    ID_CLIENTE,
    sort_array(collect_set(NOME)) AS NOMES,
    sort_array(collect_set(CAST(DATA_NASCIMENTO AS STRING))) AS NASCIMENTOS,
    sort_array(collect_set(GENERO)) AS GENEROS,
    sort_array(collect_set(CONTATO)) AS CONTATOS,
    'Atributos incompatíveis para o mesmo ID_CLIENTE; nenhuma identidade foi escolhida.' AS MOTIVO_QUARENTENA
FROM atributos_cliente
GROUP BY ID_CLIENTE
HAVING size(collect_set(NOME)) > 1
    OR size(collect_set(DATA_NASCIMENTO)) > 1
    OR size(collect_set(GENERO)) > 1
    OR size(collect_set(CONTATO)) > 1;

ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN ID_CLIENTE COMMENT 'ID compartilhado pelas origens que não pode receber uma identidade conformada sem regra de resolução.';
ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN NOMES COMMENT 'Nomes distintos e não nulos encontrados para o ID.';
ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN NASCIMENTOS COMMENT 'Datas de nascimento distintas e não nulas encontradas para o ID.';
ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN GENEROS COMMENT 'Gêneros distintos e não nulos encontrados para o ID.';
ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN CONTATOS COMMENT 'Contatos distintos e não nulos encontrados para o ID.';
ALTER TABLE lakehouse.gold.quarentena_cliente_identidade ALTER COLUMN MOTIVO_QUARENTENA COMMENT 'Regra de qualidade que impediu a conformação da identidade.';

CREATE OR REPLACE TABLE lakehouse.gold.quarentena_estoque_mensal
USING DELTA
COMMENT 'Registros Silver pertencentes a um produto/mês duplicado; nenhum saldo é escolhido ou somado na Gold.'
AS
WITH graos_conflitantes AS (
    SELECT
        COD_PRODUTO, MES_REFERENCIA
    FROM lakehouse.silver.estoque
    GROUP BY COD_PRODUTO, MES_REFERENCIA
    HAVING count(*) > 1
)
SELECT
    E.ID_REGISTRO,
    E.COD_PRODUTO,
    E.PRODUTO,
    E.MES_REFERENCIA,
    E.ESTOQUE_ATUAL,
    E.CAMPANHA_ATUAL,
    'Mais de um registro Silver para o mesmo produto/mês; nenhum saldo foi escolhido ou somado.' AS MOTIVO_QUARENTENA
FROM lakehouse.silver.estoque E
JOIN graos_conflitantes G
    ON E.COD_PRODUTO = G.COD_PRODUTO AND E.MES_REFERENCIA = G.MES_REFERENCIA;

ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN ID_REGISTRO COMMENT 'Identificador Silver preservado para rastreabilidade.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN COD_PRODUTO COMMENT 'Código do produto pertencente ao grão mensal conflitante.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN PRODUTO COMMENT 'Nome comercial do produto pertencente ao grão mensal conflitante.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN MES_REFERENCIA COMMENT 'Primeiro dia do mês cujo saldo possui mais de uma versão.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN ESTOQUE_ATUAL COMMENT 'Saldo preservado exatamente como chegou da Silver; não é somado nem escolhido.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN CAMPANHA_ATUAL COMMENT 'Campanha preservada exatamente como chegou da Silver.';
ALTER TABLE lakehouse.gold.quarentena_estoque_mensal ALTER COLUMN MOTIVO_QUARENTENA COMMENT 'Regra de qualidade que impediu a entrada no fato mensal.';

SELECT
    (SELECT count(*) FROM lakehouse.gold.quarentena_cliente_identidade) AS IDS_CLIENTE_EM_QUARENTENA,
    (SELECT count(DISTINCT struct(COD_PRODUTO, MES_REFERENCIA))
        FROM lakehouse.gold.quarentena_estoque_mensal) AS GRAOS_ESTOQUE_EM_QUARENTENA;

CREATE OR REPLACE TABLE lakehouse.gold.dim_cliente
USING DELTA
COMMENT 'Clientes identificados de forma conformada entre CRM e ERP, sem resolver automaticamente conflitos de identidade.'
AS
WITH atributos AS (
    SELECT ID_CLIENTE, CLIENTE AS NOME, GENERO, CONTATO, CAST(NULL AS DATE) AS DATA_NASCIMENTO
    FROM lakehouse.silver.crm
    UNION ALL
    SELECT ID_CLIENTE, NOME_CLIENTE, CAST(NULL AS STRING), CAST(NULL AS STRING), DATA_NASCIMENTO
    FROM lakehouse.silver.erp
),
clientes_validos AS (
    SELECT ID_CLIENTE
    FROM atributos
    GROUP BY ID_CLIENTE
    HAVING size(collect_set(NOME)) <= 1
        AND size(collect_set(DATA_NASCIMENTO)) <= 1
        AND size(collect_set(GENERO)) <= 1
        AND size(collect_set(CONTATO)) <= 1
)
SELECT
    xxhash64(concat('cliente|', A.ID_CLIENTE)) AS SK_CLIENTE,
    A.ID_CLIENTE,
    max(A.NOME) AS NOME,
    max(A.DATA_NASCIMENTO) AS DATA_NASCIMENTO,
    max(A.GENERO) AS GENERO,
    max(A.CONTATO) AS CONTATO
FROM atributos A
JOIN clientes_validos V ON A.ID_CLIENTE = V.ID_CLIENTE
GROUP BY A.ID_CLIENTE;

ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN SK_CLIENTE COMMENT 'Chave substituta deterministica calculada somente para uma identidade sem conflito conhecido.';
ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN ID_CLIENTE COMMENT 'Vinculo de origem entre CRM e ERP; IDs conflitantes ficam na quarentena e nao sao resolvidos por semelhanca de nome.';
ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN NOME COMMENT 'Nome unico observado para o ID de origem apos o preflight de identidade.';
ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN DATA_NASCIMENTO COMMENT 'Nascimento informado pelo ERP; ausencia permanece NULL e nao e inferida pela idade do CRM.';
ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN GENERO COMMENT 'Genero informado pelo CRM; ausencia permanece NULL.';
ALTER TABLE lakehouse.gold.dim_cliente ALTER COLUMN CONTATO COMMENT 'Canal de contato informado pelo CRM; ausencia ou formato invalido na Silver permanece NULL.';

CREATE OR REPLACE TABLE lakehouse.gold.dim_produto
USING DELTA
COMMENT 'Linhas comerciais de veiculos conformadas pelo mapeamento explicito entre nome e codigo de estoque.'
AS
WITH mapeamento_produto(cod_produto, nome_produto) AS (
    SELECT * FROM VALUES
        ('VW-POL', 'Polo'),
        ('VW-NIV', 'Nivus'),
        ('VW-SAV', 'Saveiro'),
        ('VW-VIR', 'Virtus'),
        ('VW-TCR', 'T-Cross'),
        ('VW-TAO', 'Taos'),
        ('VW-AMA', 'Amarok'),
        ('VW-TIG', 'Tiguan Allspace')
)
SELECT
    xxhash64(concat('produto|', COD_PRODUTO)) AS SK_PRODUTO,
    COD_PRODUTO,
    NOME_PRODUTO
FROM mapeamento_produto;

ALTER TABLE lakehouse.gold.dim_produto ALTER COLUMN SK_PRODUTO COMMENT 'Chave substituta deterministica da linha comercial, baseada no codigo oficial do estoque.';
ALTER TABLE lakehouse.gold.dim_produto ALTER COLUMN COD_PRODUTO COMMENT 'Codigo comercial do estoque associado explicitamente ao nome usado no CRM e ERP.';
ALTER TABLE lakehouse.gold.dim_produto ALTER COLUMN NOME_PRODUTO COMMENT 'Linha comercial, nao um veiculo individual, versao, cor ou ano.';

WITH produtos_origem AS (
    SELECT 'CRM' AS SISTEMA, CAST(NULL AS STRING) AS COD_PRODUTO, PRODUTO_INTERESSE AS NOME_PRODUTO
    FROM lakehouse.silver.crm
    UNION ALL
    SELECT 'ERP', CAST(NULL AS STRING), PRODUTO
    FROM lakehouse.silver.erp
    UNION ALL
    SELECT 'ESTOQUE', COD_PRODUTO, PRODUTO
    FROM lakehouse.silver.estoque
),
produtos_invalidos AS (
    SELECT DISTINCT O.SISTEMA, O.COD_PRODUTO, O.NOME_PRODUTO
    FROM produtos_origem O
    LEFT JOIN lakehouse.gold.dim_produto P
        ON O.NOME_PRODUTO = P.NOME_PRODUTO
        AND (O.COD_PRODUTO IS NULL OR O.COD_PRODUTO = P.COD_PRODUTO)
    WHERE P.SK_PRODUTO IS NULL
)
SELECT CASE WHEN count(*) > 0 THEN raise_error(concat(
    'Mapeamento de produto inválido: ',
    concat_ws('; ', sort_array(collect_list(concat(
        SISTEMA, ':', coalesce(COD_PRODUTO, '<sem código>'), '/', coalesce(NOME_PRODUTO, '<sem nome>')
    ))))
)) ELSE 'Mapeamento explícito dos oito produtos validado.' END AS RESULTADO
FROM produtos_invalidos;

CREATE OR REPLACE TABLE lakehouse.gold.dim_vendedor
USING DELTA
COMMENT 'Vendedores presentes nos registros de venda do ERP.'
AS
SELECT
    xxhash64(concat('vendedor|', VENDEDOR)) AS SK_VENDEDOR,
    VENDEDOR AS NOME
FROM lakehouse.silver.erp
GROUP BY VENDEDOR;

ALTER TABLE lakehouse.gold.dim_vendedor ALTER COLUMN SK_VENDEDOR COMMENT 'Chave substituta deterministica do vendedor.';
ALTER TABLE lakehouse.gold.dim_vendedor ALTER COLUMN NOME COMMENT 'Nome padronizado do vendedor informado pelo ERP.';

CREATE OR REPLACE TABLE lakehouse.gold.dim_pagamento
USING DELTA
COMMENT 'Formas de pagamento compartilhadas pelas vendas e oportunidades.'
AS
WITH formas AS (
    SELECT FORMA_PAGAMENTO FROM lakehouse.silver.crm
    UNION
    SELECT FORMA_PAGAMENTO FROM lakehouse.silver.erp
)
SELECT
    xxhash64(concat('pagamento|', FORMA_PAGAMENTO)) AS SK_PAGAMENTO,
    FORMA_PAGAMENTO
FROM formas;

ALTER TABLE lakehouse.gold.dim_pagamento ALTER COLUMN SK_PAGAMENTO COMMENT 'Chave substituta deterministica da forma de pagamento.';
ALTER TABLE lakehouse.gold.dim_pagamento ALTER COLUMN FORMA_PAGAMENTO COMMENT 'Forma de pagamento declarada no CRM ou ERP.';

CREATE OR REPLACE TABLE lakehouse.gold.dim_canal
USING DELTA
COMMENT 'Fontes de aquisicao declaradas nas oportunidades do CRM.'
AS
SELECT
    xxhash64(concat('canal|', FONTE)) AS SK_CANAL,
    FONTE
FROM lakehouse.silver.crm
GROUP BY FONTE;

ALTER TABLE lakehouse.gold.dim_canal ALTER COLUMN SK_CANAL COMMENT 'Chave substituta deterministica da fonte de aquisicao.';
ALTER TABLE lakehouse.gold.dim_canal ALTER COLUMN FONTE COMMENT 'Fonte pela qual a oportunidade chegou a concessionaria.';

CREATE OR REPLACE TABLE lakehouse.gold.dim_calendario
USING DELTA
COMMENT 'Calendario diario compartilhado por entregas, nascimentos, oportunidades, contatos e referencias de estoque.'
AS
WITH datas AS (
    SELECT DATA_INTERESSE AS DATA FROM lakehouse.silver.crm
    UNION ALL
    SELECT DATA_ULTIMO_CONTATO FROM lakehouse.silver.crm
    UNION ALL
    SELECT DATA_NASCIMENTO FROM lakehouse.silver.erp
    UNION ALL
    SELECT DATA_ENTREGA FROM lakehouse.silver.erp
    UNION ALL
    SELECT MES_REFERENCIA FROM lakehouse.silver.estoque
),
limites AS (
    SELECT min(DATA) AS DATA_MINIMA, max(DATA) AS DATA_MAXIMA
    FROM datas
    WHERE DATA IS NOT NULL
),
calendario AS (
    SELECT explode(sequence(DATA_MINIMA, DATA_MAXIMA, INTERVAL 1 DAY)) AS DATA
    FROM limites
)
SELECT
    CAST(date_format(DATA, 'yyyyMMdd') AS INT) AS SK_DATA,
    DATA,
    year(DATA) AS ANO,
    month(DATA) AS MES,
    CASE month(DATA)
        WHEN 1 THEN 'Janeiro' WHEN 2 THEN 'Fevereiro' WHEN 3 THEN 'Março'
        WHEN 4 THEN 'Abril' WHEN 5 THEN 'Maio' WHEN 6 THEN 'Junho'
        WHEN 7 THEN 'Julho' WHEN 8 THEN 'Agosto' WHEN 9 THEN 'Setembro'
        WHEN 10 THEN 'Outubro' WHEN 11 THEN 'Novembro' WHEN 12 THEN 'Dezembro'
    END AS NOME_MES,
    quarter(DATA) AS TRIMESTRE,
    CASE dayofweek(DATA)
        WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda-feira' WHEN 3 THEN 'Terça-feira'
        WHEN 4 THEN 'Quarta-feira' WHEN 5 THEN 'Quinta-feira'
        WHEN 6 THEN 'Sexta-feira' WHEN 7 THEN 'Sábado'
    END AS DIA_SEMANA
FROM calendario;

ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN SK_DATA COMMENT 'Chave da data no formato numerico AAAAMMDD.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN DATA COMMENT 'Dia civil valido observado no intervalo das datas Silver; datas desconhecidas nao recebem membro artificial.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN ANO COMMENT 'Ano civil da data.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN MES COMMENT 'Numero do mes civil, de 1 a 12.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN NOME_MES COMMENT 'Nome do mes em portugues.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN TRIMESTRE COMMENT 'Trimestre civil, de 1 a 4.';
ALTER TABLE lakehouse.gold.dim_calendario ALTER COLUMN DIA_SEMANA COMMENT 'Nome do dia da semana em portugues.';

SELECT assert_true(count(*) = count(DISTINCT SK_CLIENTE), 'dim_cliente: colisao de SK_CLIENTE') AS SK_UNICA
FROM lakehouse.gold.dim_cliente;
SELECT assert_true(count(*) = count(DISTINCT SK_PRODUTO), 'dim_produto: colisao de SK_PRODUTO') AS SK_UNICA
FROM lakehouse.gold.dim_produto;
SELECT assert_true(count(*) = count(DISTINCT SK_VENDEDOR), 'dim_vendedor: colisao de SK_VENDEDOR') AS SK_UNICA
FROM lakehouse.gold.dim_vendedor;
SELECT assert_true(count(*) = count(DISTINCT SK_PAGAMENTO), 'dim_pagamento: colisao de SK_PAGAMENTO') AS SK_UNICA
FROM lakehouse.gold.dim_pagamento;
SELECT assert_true(count(*) = count(DISTINCT SK_CANAL), 'dim_canal: colisao de SK_CANAL') AS SK_UNICA
FROM lakehouse.gold.dim_canal;
SELECT assert_true(count(*) = count(DISTINCT SK_DATA), 'dim_calendario: colisao de SK_DATA') AS SK_UNICA
FROM lakehouse.gold.dim_calendario;

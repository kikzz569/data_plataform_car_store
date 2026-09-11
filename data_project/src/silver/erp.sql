-- Uma linha por registro original distinto. Metadados de ingestao nao definem duplicidade.
-- A ordem pelo conteudo original conserva versoes que ficam iguais apos a limpeza.
CREATE OR REPLACE TABLE lakehouse.silver.erp
USING DELTA
COMMENT 'Registros do ERP tipados e padronizados. Valores negativos e versoes divergentes sao preservados; nao ha identificador de pedido.'
AS
WITH originais AS (
    SELECT
        id_cliente, nome_cliente, data_nascimento, vendedor, valor_padrao, desconto, valor_faturamento, forma_pagamento, banco, custo, produto, cor_produto, ano, modelo, data_entrega, zero_km_ou_seminovo,
        count(*) AS _linhas_origem
    FROM lakehouse.bronze.erp
    GROUP BY ALL
),
conteudo AS (
    SELECT *, to_json(named_struct(
        'id_cliente', id_cliente,
        'nome_cliente', nome_cliente,
        'data_nascimento', data_nascimento,
        'vendedor', vendedor,
        'valor_padrao', valor_padrao,
        'desconto', desconto,
        'valor_faturamento', valor_faturamento,
        'forma_pagamento', forma_pagamento,
        'banco', banco,
        'custo', custo,
        'produto', produto,
        'cor_produto', cor_produto,
        'ano', ano,
        'modelo', modelo,
        'data_entrega', data_entrega,
        'zero_km_ou_seminovo', zero_km_ou_seminovo
    ), map('ignoreNullFields', 'false')) AS _conteudo
    FROM originais
),
numerados AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY upper(trim(id_cliente))
            ORDER BY sha2(_conteudo, 256), _conteudo
        ) AS _versao
    FROM conteudo
),
detectados AS (
    SELECT *,
        CASE
            -- A virgula decimal nao escapada dividiu um campo em dois tokens.
            -- Os marcadores de produto/cor/ano/data identificam o deslocamento de UMA posicao.
            WHEN lower(trim(cor_produto)) IN ('polo', 'nivus', 'saveiro', 'virtus', 't-cross', 'taos', 'amarok', 'tiguan allspace')
                AND trim(modelo) RLIKE '^[0-9]{4}$'
                AND coalesce(try_to_date(trim(zero_km_ou_seminovo), 'dd/MM/yyyy'), try_to_date(trim(zero_km_ou_seminovo), 'MM/dd/yyyy'),
        try_to_date(trim(zero_km_ou_seminovo), 'yyyy-MM-dd')) IS NOT NULL
            THEN CASE
                WHEN lower(trim(banco)) IN ('financiamento', 'à vista') THEN CASE
                    WHEN trim(valor_padrao) RLIKE '^-?[0-9]{1,3}([.][0-9]{3})+$'
                        AND trim(desconto) RLIKE '^[0-9]{2}$' THEN 'valor_padrao'
                    WHEN trim(desconto) RLIKE '^-?[0-9]{1,3}([.][0-9]{3})+$'
                        AND trim(valor_faturamento) RLIKE '^[0-9]{2}$' THEN 'desconto'
                    WHEN trim(valor_faturamento) RLIKE '^-?[0-9]{1,3}([.][0-9]{3})+$'
                        AND trim(forma_pagamento) RLIKE '^[0-9]{2}$' THEN 'valor_faturamento'
                    ELSE raise_error(concat('ERP: deslocamento monetario ambiguo em ', id_cliente))
                END
                WHEN lower(trim(forma_pagamento)) IN ('financiamento', 'à vista')
                    AND trim(custo) RLIKE '^-?[0-9]{1,3}([.][0-9]{3})+$'
                    AND trim(produto) RLIKE '^[0-9]{2}$' THEN 'custo'
                ELSE raise_error(concat('ERP: deslocamento nao reconhecido em ', id_cliente))
            END
            ELSE 'nenhum'
        END AS _deslocamento
    FROM numerados
),
realinhados AS (
    SELECT
        id_cliente, nome_cliente, data_nascimento, vendedor, _versao, _linhas_origem,
        CASE WHEN _deslocamento = 'valor_padrao'
            THEN concat(replace(trim(valor_padrao), '.', ''), '.', trim(desconto))
            ELSE valor_padrao END AS valor_padrao,
        CASE
            WHEN _deslocamento = 'valor_padrao' THEN valor_faturamento
            WHEN _deslocamento = 'desconto'
                THEN concat(replace(trim(desconto), '.', ''), '.', trim(valor_faturamento))
            ELSE desconto END AS desconto,
        CASE
            WHEN _deslocamento IN ('valor_padrao', 'desconto') THEN forma_pagamento
            WHEN _deslocamento = 'valor_faturamento'
                THEN concat(replace(trim(valor_faturamento), '.', ''), '.', trim(forma_pagamento))
            ELSE valor_faturamento END AS valor_faturamento,
        IF(_deslocamento IN ('valor_padrao', 'desconto', 'valor_faturamento'), banco, forma_pagamento)
            AS forma_pagamento,
        IF(_deslocamento IN ('valor_padrao', 'desconto', 'valor_faturamento'), custo, banco) AS banco,
        CASE
            WHEN _deslocamento IN ('valor_padrao', 'desconto', 'valor_faturamento') THEN produto
            WHEN _deslocamento = 'custo' THEN concat(replace(trim(custo), '.', ''), '.', trim(produto))
            ELSE custo END AS custo,
        IF(_deslocamento = 'nenhum', produto, cor_produto) AS produto,
        IF(_deslocamento = 'nenhum', cor_produto, ano) AS cor_produto,
        IF(_deslocamento = 'nenhum', ano, modelo) AS ano,
        IF(_deslocamento = 'nenhum', modelo, data_entrega) AS modelo,
        IF(_deslocamento = 'nenhum', data_entrega, zero_km_ou_seminovo) AS data_entrega,
        -- O ultimo token foi descartado na bronze: nao ha como reconstruir a condicao do veiculo.
        IF(_deslocamento = 'nenhum', zero_km_ou_seminovo, NULL) AS zero_km_ou_seminovo
    FROM detectados
)
SELECT
    concat(upper(trim(id_cliente)), '-', cast(_versao AS STRING)) AS ID_REGISTRO,
    upper(trim(id_cliente)) AS ID_CLIENTE,
    initcap(nullif(trim(nome_cliente), '')) AS NOME_CLIENTE,
    coalesce(try_to_date(trim(data_nascimento), 'dd/MM/yyyy'), try_to_date(trim(data_nascimento), 'MM/dd/yyyy'),
        try_to_date(trim(data_nascimento), 'yyyy-MM-dd')) AS DATA_NASCIMENTO,
    initcap(nullif(trim(vendedor), '')) AS VENDEDOR,
    try_cast(trim(valor_padrao) AS DECIMAL(15,2)) AS VALOR_PADRAO,
    try_cast(trim(desconto) AS DECIMAL(15,2)) AS DESCONTO,
    try_cast(trim(valor_faturamento) AS DECIMAL(15,2)) AS VALOR_FATURAMENTO,
    CASE lower(trim(forma_pagamento))
        WHEN 'financiamento' THEN 'Financiamento'
        WHEN 'à vista' THEN 'À Vista'
        ELSE nullif(trim(forma_pagamento), '') END AS FORMA_PAGAMENTO,
    CASE lower(trim(banco))
        WHEN 'montadora' THEN 'Montadora'
        WHEN 'bradesco' THEN 'Bradesco'
        WHEN 'santander' THEN 'Santander'
        WHEN 'bv' THEN 'BV'
        ELSE nullif(trim(banco), '') END AS BANCO,
    try_cast(trim(custo) AS DECIMAL(15,2)) AS CUSTO,
    CASE lower(trim(produto))
        WHEN 'polo' THEN 'Polo'
        WHEN 'nivus' THEN 'Nivus'
        WHEN 'saveiro' THEN 'Saveiro'
        WHEN 'virtus' THEN 'Virtus'
        WHEN 't-cross' THEN 'T-Cross'
        WHEN 'taos' THEN 'Taos'
        WHEN 'amarok' THEN 'Amarok'
        WHEN 'tiguan allspace' THEN 'Tiguan Allspace'
        ELSE nullif(trim(produto), '') END AS PRODUTO,
    CASE lower(trim(cor_produto))
        WHEN 'branco' THEN 'Branco'
        WHEN 'prata' THEN 'Prata'
        WHEN 'preto' THEN 'Preto'
        WHEN 'cinza' THEN 'Cinza'
        WHEN 'vermelho' THEN 'Vermelho'
        WHEN 'azul' THEN 'Azul'
        WHEN 'brnaco' THEN 'Branco'
        WHEN 'pratta' THEN 'Prata'
        WHEN 'pretoo' THEN 'Preto'
        ELSE nullif(trim(cor_produto), '') END AS COR_PRODUTO,
    try_cast(trim(ano) AS INT) AS ANO,
    -- initcap preserva a maioria dos modelos; a grafia T-Cross exige ajuste do C apos o hifen.
    replace(initcap(nullif(trim(modelo), '')), 'T-cross', 'T-Cross') AS MODELO,
    coalesce(try_to_date(trim(data_entrega), 'dd/MM/yyyy'), try_to_date(trim(data_entrega), 'MM/dd/yyyy'),
        try_to_date(trim(data_entrega), 'yyyy-MM-dd')) AS DATA_ENTREGA,
    CASE lower(trim(zero_km_ou_seminovo))
        WHEN '0 km' THEN '0 KM'
        WHEN 'semi novo' THEN 'Semi Novo'
        ELSE nullif(trim(zero_km_ou_seminovo), '') END AS ZERO_KM_OU_SEMINOVO,
    current_timestamp() AS _processado_em,
    _linhas_origem
FROM realinhados;

ALTER TABLE lakehouse.silver.erp ALTER COLUMN ID_REGISTRO COMMENT 'Chave tecnica: chave natural mais sequencial ordenado por hash e conteudo bruto. Estavel para o mesmo snapshot; novas versoes podem renumerar o grupo. Nao resolve identidade ou conflito de negocio.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN _processado_em COMMENT 'Instante de processamento deste snapshot silver.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN _linhas_origem COMMENT 'Quantidade de linhas bronze integralmente iguais nas colunas de negocio consolidadas neste registro. A soma reconcilia com a bronze.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN ID_CLIENTE COMMENT 'Vinculo de origem CRM-ERP em maiusculas. Repeticoes divergentes preservadas; nao e chave unica ou identidade comprovada.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN NOME_CLIENTE COMMENT 'Nome com trim e iniciais capitalizadas; nao participa de resolucao automatica de identidade.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN DATA_NASCIMENTO COMMENT 'Data por try_to_date nos formatos brasileiro, americano e ISO. Ausencia ou data invalida permanece NULL; nao infere pela idade.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN VENDEDOR COMMENT 'Nome do vendedor com espacos externos removidos e iniciais capitalizadas.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN VALOR_PADRAO COMMENT 'Preco informado decimal(15,2). Virgula decimal nao escapada e reconstruida apenas quando a estrutura confirma deslocamento. Negativos preservados.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN DESCONTO COMMENT 'Desconto informado decimal(15,2), com realinhamento estrutural quando necessario. Negativo mantido sem supor devolucao.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN VALOR_FATURAMENTO COMMENT 'Faturamento informado decimal(15,2), recuperado por realinhamento estrutural. Nao recalculado por preco menos desconto; zeros e negativos mantidos.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN FORMA_PAGAMENTO COMMENT 'Financiamento ou À Vista; coluna realinhada quando virgula monetaria deslocou o CSV.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN BANCO COMMENT 'Banco realinhado e normalizado, preservando BV; ausencia mantida mesmo em financiamento, para revisao.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN CUSTO COMMENT 'Custo informado decimal(15,2), recuperado por realinhamento ou recomposicao dos centavos. Negativos e margem negativa preservados.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN PRODUTO COMMENT 'Linha comercial realinhada e normalizada; preserva T-Cross e nao representa veiculo individual.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN COR_PRODUTO COMMENT 'Cor realinhada e normalizada; Brnaco, Pratta e Pretoo corrigidos para Branco, Prata e Preto.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN ANO COMMENT 'Ano do veiculo realinhado e convertido para inteiro; nao usa a data de entrega para inventar ano.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN MODELO COMMENT 'Versao do veiculo realinhada, capitalizada e com T-Cross preservado.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN DATA_ENTREGA COMMENT 'Data realinhada e convertida com try_to_date nos formatos brasileiro, americano e ISO. Data obrigatoria, sem substituicao pela atual.';
ALTER TABLE lakehouse.silver.erp ALTER COLUMN ZERO_KM_OU_SEMINOVO COMMENT '0 KM ou Semi Novo em grafia canonica. NULL nas linhas deslocadas: a bronze descartou o 17o token do CSV, irrecuperavel a partir dela.';

-- Declarar novamente apenas os contratos desta feature torna a reexecucao idempotente.
ALTER TABLE lakehouse.silver.erp DROP CONSTRAINT IF EXISTS erp_chaves;
ALTER TABLE lakehouse.silver.erp ADD CONSTRAINT erp_chaves CHECK (
    ID_REGISTRO IS NOT NULL AND ID_REGISTRO RLIKE '^CLI[0-9]+-[1-9][0-9]*$' AND ID_CLIENTE IS NOT NULL AND ID_CLIENTE RLIKE '^CLI[0-9]+$'
);

ALTER TABLE lakehouse.silver.erp DROP CONSTRAINT IF EXISTS erp_obrigatorios;
ALTER TABLE lakehouse.silver.erp ADD CONSTRAINT erp_obrigatorios CHECK (
    NOME_CLIENTE IS NOT NULL AND length(NOME_CLIENTE) > 0 AND VENDEDOR IS NOT NULL AND length(VENDEDOR) > 0 AND ANO IS NOT NULL AND MODELO IS NOT NULL AND length(MODELO) > 0 AND DATA_ENTREGA IS NOT NULL
);

ALTER TABLE lakehouse.silver.erp DROP CONSTRAINT IF EXISTS erp_financeiro;
ALTER TABLE lakehouse.silver.erp ADD CONSTRAINT erp_financeiro CHECK (
    VALOR_PADRAO IS NOT NULL AND DESCONTO IS NOT NULL AND VALOR_FATURAMENTO IS NOT NULL AND CUSTO IS NOT NULL
);

ALTER TABLE lakehouse.silver.erp DROP CONSTRAINT IF EXISTS erp_dominios;
ALTER TABLE lakehouse.silver.erp ADD CONSTRAINT erp_dominios CHECK (
    FORMA_PAGAMENTO IS NOT NULL AND FORMA_PAGAMENTO IN ('Financiamento', 'À Vista')
    AND (BANCO IS NULL OR BANCO IN ('Montadora', 'Bradesco', 'Santander', 'BV'))
    AND PRODUTO IS NOT NULL AND PRODUTO IN ('Polo', 'Nivus', 'Saveiro', 'Virtus', 'T-Cross', 'Taos', 'Amarok', 'Tiguan Allspace')
    AND COR_PRODUTO IS NOT NULL AND COR_PRODUTO IN ('Branco', 'Prata', 'Preto', 'Cinza', 'Vermelho', 'Azul')
    AND (ZERO_KM_OU_SEMINOVO IS NULL OR ZERO_KM_OU_SEMINOVO IN ('0 KM', 'Semi Novo'))
);

ALTER TABLE lakehouse.silver.erp DROP CONSTRAINT IF EXISTS erp_auditoria;
ALTER TABLE lakehouse.silver.erp ADD CONSTRAINT erp_auditoria CHECK (
    _processado_em IS NOT NULL AND _linhas_origem IS NOT NULL AND _linhas_origem >= 1
);

-- CHECK avalia cada linha; unicidade e conciliacao exigem verificacao agregada.
SELECT assert_true(count(*) = count(DISTINCT ID_REGISTRO), 'erp: ID_REGISTRO duplicado') AS chave_unica,
    assert_true(sum(_linhas_origem) = (SELECT count(*) FROM lakehouse.bronze.erp),
        'erp: linhas de origem nao reconciliadas') AS origem_reconciliada
FROM lakehouse.silver.erp;

SELECT 'erp' AS tabela, count(*) AS registros_silver, sum(_linhas_origem) AS linhas_bronze,
    sum(_linhas_origem) - count(*) AS duplicatas_exatas_removidas
FROM lakehouse.silver.erp;

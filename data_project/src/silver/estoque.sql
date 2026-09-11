-- Uma linha por registro original distinto. Metadados de ingestao nao definem duplicidade.
-- A ordem pelo conteudo original conserva versoes que ficam iguais apos a limpeza.
CREATE OR REPLACE TABLE lakehouse.silver.estoque
USING DELTA
COMMENT 'Posicoes mensais do estoque. Conflitos produto/mes sao preservados para revisao; nao somar saldos de meses diferentes.'
AS
WITH originais AS (
    SELECT
        mes_referencia, cod_produto, produto, estoque_atual, campanha_atual,
        count(*) AS _linhas_origem
    FROM lakehouse.bronze.estoque
    GROUP BY ALL
),
conteudo AS (
    SELECT *, to_json(named_struct(
        'mes_referencia', mes_referencia,
        'cod_produto', cod_produto,
        'produto', produto,
        'estoque_atual', estoque_atual,
        'campanha_atual', campanha_atual
    ), map('ignoreNullFields', 'false')) AS _conteudo
    FROM originais
),
referencias AS (
    SELECT *, coalesce(
        try_to_date(concat(trim(mes_referencia), '-01'), 'yyyy-MM-dd'),
        try_to_date(concat(trim(mes_referencia), '/01'), 'yyyy/MM/dd'),
        try_to_date(concat('01/', trim(mes_referencia)), 'dd/MM/yyyy')
    ) AS _mes_referencia
    FROM conteudo
),
numerados AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY _mes_referencia, upper(trim(cod_produto))
            ORDER BY sha2(_conteudo, 256), _conteudo
        ) AS _versao
    FROM referencias
)
SELECT
    concat(date_format(_mes_referencia, 'yyyy-MM'), '-', upper(trim(cod_produto)), '-', cast(_versao AS STRING)) AS ID_REGISTRO,
    _mes_referencia AS MES_REFERENCIA,
    upper(trim(cod_produto)) AS COD_PRODUTO,
    CASE upper(trim(cod_produto))
        WHEN 'VW-POL' THEN 'Polo' WHEN 'VW-NIV' THEN 'Nivus'
        WHEN 'VW-SAV' THEN 'Saveiro' WHEN 'VW-VIR' THEN 'Virtus'
        WHEN 'VW-TCR' THEN 'T-Cross' WHEN 'VW-TAO' THEN 'Taos'
        WHEN 'VW-AMA' THEN 'Amarok' WHEN 'VW-TIG' THEN 'Tiguan Allspace'
        ELSE raise_error(concat('Estoque: codigo de produto desconhecido: ', cod_produto))
    END AS PRODUTO,
    coalesce(try_cast(nullif(trim(estoque_atual), '') AS INT),
        IF(nullif(trim(estoque_atual), '') IS NULL, NULL, raise_error('estoque: ESTOQUE_ATUAL invalido'))) AS ESTOQUE_ATUAL,
    CASE lower(trim(campanha_atual))
        WHEN 'nenhuma' THEN 'Nenhuma'
        WHEN 'desconto na entrada' THEN 'Desconto na Entrada'
        WHEN 'taxa zero' THEN 'Taxa Zero'
        WHEN 'bônus na troca' THEN 'Bônus na Troca'
        WHEN 'ipi reduzido' THEN 'IPI Reduzido'
        WHEN 'semana do consumidor' THEN 'Semana do Consumidor'
        ELSE nullif(trim(campanha_atual), '') END AS CAMPANHA_ATUAL,
    current_timestamp() AS _processado_em,
    _linhas_origem
FROM numerados;

ALTER TABLE lakehouse.silver.estoque ALTER COLUMN ID_REGISTRO COMMENT 'Chave tecnica: chave natural mais sequencial ordenado por hash e conteudo bruto. Estavel para o mesmo snapshot; novas versoes podem renumerar o grupo. Nao resolve identidade ou conflito de negocio.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN _processado_em COMMENT 'Instante de processamento deste snapshot silver.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN _linhas_origem COMMENT 'Quantidade de linhas bronze integralmente iguais nas colunas de negocio consolidadas neste registro. A soma reconcilia com a bronze.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN MES_REFERENCIA COMMENT 'Mes yyyy-MM, yyyy/MM ou MM/yyyy convertido com try_to_date para o primeiro dia. Saldo e uma posicao mensal, nao somavel entre meses.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN COD_PRODUTO COMMENT 'Codigo comercial em maiusculas. Conflitos no mesmo produto/mes sao preservados e exigem revisao antes da gold.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN PRODUTO COMMENT 'Nome canonico definido pelo codigo VW. Corrige grafias e divergencias codigo/nome sem eliminar registros originais distintos.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN ESTOQUE_ATUAL COMMENT 'Saldo mensal inteiro. Negativos preservados; ausencia permanece NULL. Nao somar versoes conflitantes do mesmo produto/mes.';
ALTER TABLE lakehouse.silver.estoque ALTER COLUMN CAMPANHA_ATUAL COMMENT 'Campanha com grafia e espacos padronizados, preservando IPI; Nenhuma representa ausencia declarada de campanha.';

-- Declarar novamente apenas os contratos desta feature torna a reexecucao idempotente.
ALTER TABLE lakehouse.silver.estoque DROP CONSTRAINT IF EXISTS estoque_chaves;
ALTER TABLE lakehouse.silver.estoque ADD CONSTRAINT estoque_chaves CHECK (
    ID_REGISTRO IS NOT NULL AND ID_REGISTRO RLIKE '^[0-9]{4}-[0-9]{2}-VW-[A-Z]{3}-[1-9][0-9]*$' AND COD_PRODUTO IS NOT NULL AND COD_PRODUTO IN ('VW-POL', 'VW-NIV', 'VW-SAV', 'VW-VIR', 'VW-TCR', 'VW-TAO', 'VW-AMA', 'VW-TIG')
);

ALTER TABLE lakehouse.silver.estoque DROP CONSTRAINT IF EXISTS estoque_mes;
ALTER TABLE lakehouse.silver.estoque ADD CONSTRAINT estoque_mes CHECK (
    MES_REFERENCIA IS NOT NULL AND dayofmonth(MES_REFERENCIA) = 1
);

ALTER TABLE lakehouse.silver.estoque DROP CONSTRAINT IF EXISTS estoque_dominios;
ALTER TABLE lakehouse.silver.estoque ADD CONSTRAINT estoque_dominios CHECK (
    PRODUTO IS NOT NULL AND PRODUTO IN ('Polo', 'Nivus', 'Saveiro', 'Virtus', 'T-Cross', 'Taos', 'Amarok', 'Tiguan Allspace')
    AND CAMPANHA_ATUAL IS NOT NULL AND CAMPANHA_ATUAL IN ('Nenhuma', 'Desconto na Entrada', 'Taxa Zero', 'Bônus na Troca', 'IPI Reduzido', 'Semana do Consumidor')
);

ALTER TABLE lakehouse.silver.estoque DROP CONSTRAINT IF EXISTS estoque_auditoria;
ALTER TABLE lakehouse.silver.estoque ADD CONSTRAINT estoque_auditoria CHECK (
    _processado_em IS NOT NULL AND _linhas_origem IS NOT NULL AND _linhas_origem >= 1
);

-- CHECK avalia cada linha; unicidade e conciliacao exigem verificacao agregada.
SELECT assert_true(count(*) = count(DISTINCT ID_REGISTRO), 'estoque: ID_REGISTRO duplicado') AS chave_unica,
    assert_true(sum(_linhas_origem) = (SELECT count(*) FROM lakehouse.bronze.estoque),
        'estoque: linhas de origem nao reconciliadas') AS origem_reconciliada
FROM lakehouse.silver.estoque;

SELECT 'estoque' AS tabela, count(*) AS registros_silver, sum(_linhas_origem) AS linhas_bronze,
    sum(_linhas_origem) - count(*) AS duplicatas_exatas_removidas
FROM lakehouse.silver.estoque;

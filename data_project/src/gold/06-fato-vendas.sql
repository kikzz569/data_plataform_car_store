-- gold.fato_vendas
-- Grao: uma linha por ID_REGISTRO distinto de lakehouse.silver.erp.
-- Registros contam eventos da origem; sem quantidade ou pedido nao comprovam quantos veiculos foram vendidos.
--
-- gold.fato_oportunidade
-- Grao: uma linha por ID_REGISTRO distinto de lakehouse.silver.crm.
-- Os registros disponiveis nao comprovam um historico completo de mudancas de etapa.
--
-- gold.fato_estoque_mensal
-- Grao: uma linha por produto e mes de referencia aceito de lakehouse.silver.estoque.
-- O saldo e uma posicao mensal: pode ser somado entre produtos no mesmo mes, nunca entre meses.
-- Graos com mais de uma versao ficam integralmente em quarentena, sem soma ou escolha arbitraria.

CREATE OR REPLACE TABLE lakehouse.gold.fato_vendas
USING DELTA
COMMENT 'Eventos de venda do ERP no mesmo grao e com o mesmo identificador da Silver.'
AS
SELECT
    E.ID_REGISTRO,
    E.ID_CLIENTE AS ID_CLIENTE_ORIGEM,
    C.SK_CLIENTE,
    P.SK_PRODUTO,
    V.SK_VENDEDOR,
    PG.SK_PAGAMENTO,
    D.SK_DATA AS SK_DATA_ENTREGA,
    E.BANCO,
    E.MODELO,
    E.COR_PRODUTO,
    E.ANO AS ANO_VEICULO,
    E.ZERO_KM_OU_SEMINOVO,
    CAST(E.VALOR_PADRAO AS DECIMAL(18, 2)) AS VALOR_PADRAO,
    CAST(E.DESCONTO AS DECIMAL(18, 2)) AS DESCONTO,
    CAST(E.VALOR_FATURAMENTO AS DECIMAL(18, 2)) AS VALOR_FATURAMENTO,
    CAST(E.CUSTO AS DECIMAL(18, 2)) AS CUSTO,
    CAST(E.VALOR_FATURAMENTO - E.CUSTO AS DECIMAL(18, 2)) AS MARGEM_BRUTA_CALCULADA
FROM lakehouse.silver.erp E
LEFT JOIN lakehouse.gold.dim_cliente C ON E.ID_CLIENTE = C.ID_CLIENTE
LEFT JOIN lakehouse.gold.dim_produto P ON E.PRODUTO = P.NOME_PRODUTO
LEFT JOIN lakehouse.gold.dim_vendedor V ON E.VENDEDOR = V.NOME
LEFT JOIN lakehouse.gold.dim_pagamento PG ON E.FORMA_PAGAMENTO = PG.FORMA_PAGAMENTO
LEFT JOIN lakehouse.gold.dim_calendario D ON E.DATA_ENTREGA = D.DATA;

ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN ID_REGISTRO COMMENT 'Identificador do registro distinto preservado do ERP Silver para rastreabilidade.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN ID_CLIENTE_ORIGEM COMMENT 'ID do cliente recebido do ERP; permanece disponível quando a identidade está em quarentena.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN SK_CLIENTE COMMENT 'Cliente identificado para a venda; fica NULL quando o ID de origem possui conflito documentado na quarentena.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN SK_PRODUTO COMMENT 'Linha comercial vendida, nao um veiculo individual.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN SK_VENDEDOR COMMENT 'Vendedor atribuido ao registro de venda.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN SK_PAGAMENTO COMMENT 'Forma de pagamento declarada na venda.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN SK_DATA_ENTREGA COMMENT 'Data em que o veiculo foi entregue segundo o ERP.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN BANCO COMMENT 'Banco informado para a venda; ausencia no ERP permanece NULL.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN MODELO COMMENT 'Versao ou modelo do veiculo vendido, mantido no evento e nao na linha comercial.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN COR_PRODUTO COMMENT 'Cor do veiculo vendido.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN ANO_VEICULO COMMENT 'Ano do veiculo informado no ERP.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN ZERO_KM_OU_SEMINOVO COMMENT 'Condicao 0 KM ou Semi Novo; ausencia irrecuperavel na Silver permanece NULL.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN VALOR_PADRAO COMMENT 'Valor de tabela informado no ERP; negativos sao preservados.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN DESCONTO COMMENT 'Desconto informado no ERP e ja refletido no faturamento; negativos sao preservados.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN VALOR_FATURAMENTO COMMENT 'Faturamento informado no ERP, sem recalcular ou descontar novamente.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN CUSTO COMMENT 'Custo informado no ERP para o registro, sem multiplicacao por quantidade inexistente.';
ALTER TABLE lakehouse.gold.fato_vendas ALTER COLUMN MARGEM_BRUTA_CALCULADA COMMENT 'Faturamento menos custo informado no ERP. O desconto ja esta refletido no faturamento. Nao desconta outras despesas comerciais, financeiras ou operacionais.';

CREATE OR REPLACE TABLE lakehouse.gold.fato_oportunidade
USING DELTA
COMMENT 'Oportunidades disponiveis no CRM; os registros nao comprovam um historico completo de transicoes de etapa.'
AS
SELECT
    O.ID_REGISTRO,
    O.ID_CLIENTE AS ID_CLIENTE_ORIGEM,
    C.SK_CLIENTE,
    P.SK_PRODUTO,
    PG.SK_PAGAMENTO,
    CN.SK_CANAL,
    DI.SK_DATA AS SK_DATA_INTERESSE,
    DU.SK_DATA AS SK_DATA_ULTIMO_CONTATO,
    CAST(O.ENTRADA_PCT AS DECIMAL(5, 2)) AS ENTRADA_PCT,
    O.IDADE,
    C.DATA_NASCIMENTO,
    O.ETAPA,
    O.TEMPERATURA,
    O.MOTIVO_INSUCESSO,
    O.FEZ_TEST_DRIVE
FROM lakehouse.silver.crm O
LEFT JOIN lakehouse.gold.dim_cliente C ON O.ID_CLIENTE = C.ID_CLIENTE
LEFT JOIN lakehouse.gold.dim_produto P ON O.PRODUTO_INTERESSE = P.NOME_PRODUTO
LEFT JOIN lakehouse.gold.dim_pagamento PG ON O.FORMA_PAGAMENTO = PG.FORMA_PAGAMENTO
LEFT JOIN lakehouse.gold.dim_canal CN ON O.FONTE = CN.FONTE
LEFT JOIN lakehouse.gold.dim_calendario DI ON O.DATA_INTERESSE = DI.DATA
LEFT JOIN lakehouse.gold.dim_calendario DU ON O.DATA_ULTIMO_CONTATO = DU.DATA;

ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN ID_REGISTRO COMMENT 'Identificador do registro distinto preservado do CRM Silver para rastreabilidade.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN ID_CLIENTE_ORIGEM COMMENT 'ID do cliente recebido do CRM; permanece disponível quando a identidade está em quarentena.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_CLIENTE COMMENT 'Cliente associado à oportunidade; fica NULL quando o ID de origem possui conflito documentado na quarentena.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_PRODUTO COMMENT 'Linha comercial de interesse mapeada explicitamente ao codigo de estoque.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_PAGAMENTO COMMENT 'Forma de pagamento considerada na oportunidade.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_CANAL COMMENT 'Fonte de aquisicao da oportunidade.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_DATA_INTERESSE COMMENT 'Data em que o interesse foi registrado no CRM.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN SK_DATA_ULTIMO_CONTATO COMMENT 'Data do ultimo contato disponivel no registro do CRM.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN ENTRADA_PCT COMMENT 'Percentual de entrada informado; nao deve ser somado entre oportunidades.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN IDADE COMMENT 'Idade informada no CRM, preservada sem inferir uma data de nascimento.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN DATA_NASCIMENTO COMMENT 'Nascimento informado no ERP para a identidade validada; ausencia permanece NULL.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN ETAPA COMMENT 'Etapa presente no registro; nao representa necessariamente uma transicao historica.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN TEMPERATURA COMMENT 'Classificacao comercial atribuida pelo vendedor.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN MOTIVO_INSUCESSO COMMENT 'Motivo de insucesso informado; ausencia permanece NULL.';
ALTER TABLE lakehouse.gold.fato_oportunidade ALTER COLUMN FEZ_TEST_DRIVE COMMENT 'Indica se o registro informa realizacao de test-drive; ausencia permanece NULL.';

CREATE OR REPLACE TABLE lakehouse.gold.fato_estoque_mensal
USING DELTA
COMMENT 'Posição mensal de estoque sem conflito por linha comercial; saldos conflitantes ficam na quarentena.'
AS
SELECT
    E.ID_REGISTRO,
    P.SK_PRODUTO,
    D.SK_DATA AS SK_DATA_REFERENCIA,
    E.ESTOQUE_ATUAL AS QUANTIDADE_ESTOQUE,
    E.CAMPANHA_ATUAL
FROM lakehouse.silver.estoque E
LEFT JOIN lakehouse.gold.dim_produto P ON E.COD_PRODUTO = P.COD_PRODUTO
LEFT JOIN lakehouse.gold.dim_calendario D ON E.MES_REFERENCIA = D.DATA
WHERE NOT EXISTS (
    SELECT 1
    FROM lakehouse.gold.quarentena_estoque_mensal Q
    WHERE Q.ID_REGISTRO = E.ID_REGISTRO
);

ALTER TABLE lakehouse.gold.fato_estoque_mensal ALTER COLUMN ID_REGISTRO COMMENT 'Identificador do registro mensal aceito; os IDs conflitantes permanecem na quarentena para rastreabilidade.';
ALTER TABLE lakehouse.gold.fato_estoque_mensal ALTER COLUMN SK_PRODUTO COMMENT 'Linha comercial cuja posicao de estoque foi informada.';
ALTER TABLE lakehouse.gold.fato_estoque_mensal ALTER COLUMN SK_DATA_REFERENCIA COMMENT 'Primeiro dia do mes ao qual o saldo de estoque se refere.';
ALTER TABLE lakehouse.gold.fato_estoque_mensal ALTER COLUMN QUANTIDADE_ESTOQUE COMMENT 'Saldo mensal informado pela loja. Negativos e ausencia permanecem como recebidos; nao somar entre meses.';
ALTER TABLE lakehouse.gold.fato_estoque_mensal ALTER COLUMN CAMPANHA_ATUAL COMMENT 'Campanha declarada para o produto no mes, mantida no fato enquanto nao houver atributos proprios de campanha.';

SELECT assert_true(
    count(*) = (SELECT count(*) FROM lakehouse.silver.erp)
        AND count(*) = count(DISTINCT ID_REGISTRO)
        AND count_if(F.SK_CLIENTE IS NULL AND Q.ID_CLIENTE IS NULL) = 0
        AND count_if(F.SK_CLIENTE IS NOT NULL AND Q.ID_CLIENTE IS NOT NULL) = 0
        AND count_if(SK_PRODUTO IS NULL OR SK_VENDEDOR IS NULL
            OR SK_PAGAMENTO IS NULL OR SK_DATA_ENTREGA IS NULL) = 0,
    'fato_vendas: relacionamento eliminou/multiplicou registros ou há chave ausente fora da quarentena'
) AS CONTRATO
FROM lakehouse.gold.fato_vendas F
LEFT JOIN lakehouse.gold.quarentena_cliente_identidade Q
    ON F.ID_CLIENTE_ORIGEM = Q.ID_CLIENTE;

SELECT assert_true(
    count(*) = (SELECT count(*) FROM lakehouse.silver.crm)
        AND count(*) = count(DISTINCT ID_REGISTRO)
        AND count_if(F.SK_CLIENTE IS NULL AND Q.ID_CLIENTE IS NULL) = 0
        AND count_if(F.SK_CLIENTE IS NOT NULL AND Q.ID_CLIENTE IS NOT NULL) = 0
        AND count_if(SK_PRODUTO IS NULL OR SK_PAGAMENTO IS NULL
            OR SK_CANAL IS NULL OR SK_DATA_INTERESSE IS NULL OR SK_DATA_ULTIMO_CONTATO IS NULL) = 0,
    'fato_oportunidade: relacionamento eliminou/multiplicou registros ou há chave ausente fora da quarentena'
) AS CONTRATO
FROM lakehouse.gold.fato_oportunidade F
LEFT JOIN lakehouse.gold.quarentena_cliente_identidade Q
    ON F.ID_CLIENTE_ORIGEM = Q.ID_CLIENTE;

SELECT assert_true(
    count(*) + (SELECT count(*) FROM lakehouse.gold.quarentena_estoque_mensal)
            = (SELECT count(*) FROM lakehouse.silver.estoque)
        AND count(*) = count(DISTINCT ID_REGISTRO)
        AND count(*) = count(DISTINCT struct(SK_PRODUTO, SK_DATA_REFERENCIA))
        AND count_if(SK_PRODUTO IS NULL OR SK_DATA_REFERENCIA IS NULL) = 0,
    'fato_estoque_mensal: registros aceitos e quarentenados não conciliam ou o grão produto/mês é inválido'
) AS CONTRATO
FROM lakehouse.gold.fato_estoque_mensal;

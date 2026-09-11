-- Uma linha por registro original distinto. Metadados de ingestao nao definem duplicidade.
-- A ordem pelo conteudo original conserva versoes que ficam iguais apos a limpeza.
CREATE OR REPLACE TABLE lakehouse.silver.crm
USING DELTA
COMMENT 'Oportunidades do CRM tipadas e padronizadas. ID_CLIENTE nao comprova identidade; versoes divergentes sao preservadas.'
AS
WITH originais AS (
    SELECT
        id_cliente, cliente, genero, idade, contato, fonte, produto_interesse, forma_pagamento, entrada_pct, fez_test_drive, data_interesse, etapa, motivo_insucesso, temperatura, data_ultimo_contato,
        count(*) AS _linhas_origem
    FROM lakehouse.bronze.crm
    GROUP BY ALL
),
conteudo AS (
    SELECT *, to_json(named_struct(
        'id_cliente', id_cliente,
        'cliente', cliente,
        'genero', genero,
        'idade', idade,
        'contato', contato,
        'fonte', fonte,
        'produto_interesse', produto_interesse,
        'forma_pagamento', forma_pagamento,
        'entrada_pct', entrada_pct,
        'fez_test_drive', fez_test_drive,
        'data_interesse', data_interesse,
        'etapa', etapa,
        'motivo_insucesso', motivo_insucesso,
        'temperatura', temperatura,
        'data_ultimo_contato', data_ultimo_contato
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
limpos AS (
    SELECT *,
        regexp_replace(trim(contato), '[^0-9]', '') AS _telefone
    FROM numerados
)
SELECT
    concat(upper(trim(id_cliente)), '-', cast(_versao AS STRING)) AS ID_REGISTRO,
    upper(trim(id_cliente)) AS ID_CLIENTE,
    initcap(nullif(trim(cliente), '')) AS CLIENTE,
    CASE lower(trim(genero))
        WHEN 'masculino' THEN 'Masculino'
        WHEN 'feminino' THEN 'Feminino'
        WHEN 'm' THEN 'Masculino'
        WHEN 'fem' THEN 'Feminino'
        WHEN 'feminno' THEN 'Feminino'
        ELSE nullif(trim(genero), '') END AS GENERO,
    coalesce(try_cast(nullif(trim(idade), '') AS INT),
        IF(nullif(trim(idade), '') IS NULL, NULL, raise_error('crm: IDADE invalido'))) AS IDADE,
    CASE
        -- Nao retirar letras para fabricar um telefone valido.
        WHEN trim(contato) NOT RLIKE '^[0-9() +.-]+$' THEN NULL
        WHEN length(_telefone) = 8 THEN concat(substr(_telefone, 1, 4), '-', substr(_telefone, 5))
        WHEN length(_telefone) = 9 THEN concat(substr(_telefone, 1, 5), '-', substr(_telefone, 6))
        WHEN length(_telefone) = 10 THEN concat('(', substr(_telefone, 1, 2), ') ',
            substr(_telefone, 3, 4), '-', substr(_telefone, 7))
        WHEN length(_telefone) = 11 THEN concat('(', substr(_telefone, 1, 2), ') ',
            substr(_telefone, 3, 5), '-', substr(_telefone, 8))
        ELSE NULL
    END AS CONTATO,
    CASE lower(trim(fonte))
        WHEN 'instagram' THEN 'Instagram'
        WHEN 'whatsapp' THEN 'WhatsApp'
        WHEN 'google ads' THEN 'Google Ads'
        WHEN 'site' THEN 'Site'
        WHEN 'loja física' THEN 'Loja Física'
        WHEN 'indicação' THEN 'Indicação'
        WHEN 'facebook ads' THEN 'Facebook Ads'
        WHEN 'olx' THEN 'OLX'
        ELSE nullif(trim(fonte), '') END AS FONTE,
    CASE lower(trim(produto_interesse))
        WHEN 'polo' THEN 'Polo'
        WHEN 'nivus' THEN 'Nivus'
        WHEN 'saveiro' THEN 'Saveiro'
        WHEN 'virtus' THEN 'Virtus'
        WHEN 't-cross' THEN 'T-Cross'
        WHEN 'taos' THEN 'Taos'
        WHEN 'amarok' THEN 'Amarok'
        WHEN 'tiguan allspace' THEN 'Tiguan Allspace'
        ELSE nullif(trim(produto_interesse), '') END AS PRODUTO_INTERESSE,
    CASE lower(trim(forma_pagamento))
        WHEN 'financiamento' THEN 'Financiamento'
        WHEN 'à vista' THEN 'À Vista'
        ELSE nullif(trim(forma_pagamento), '') END AS FORMA_PAGAMENTO,
    coalesce(try_cast(nullif(trim(entrada_pct), '') AS DECIMAL(5,2)),
        IF(nullif(trim(entrada_pct), '') IS NULL, NULL, raise_error('crm: ENTRADA_PCT invalido'))) AS ENTRADA_PCT,
    CASE lower(trim(fez_test_drive))
        WHEN 'sim' THEN true WHEN 's' THEN true WHEN '1' THEN true
        WHEN 'não' THEN false
        WHEN '' THEN NULL
        ELSE IF(fez_test_drive IS NULL, NULL, raise_error('CRM: FEZ_TEST_DRIVE desconhecido'))
    END AS FEZ_TEST_DRIVE,
    coalesce(try_to_date(trim(data_interesse), 'dd/MM/yyyy'), try_to_date(trim(data_interesse), 'MM/dd/yyyy'),
        try_to_date(trim(data_interesse), 'yyyy-MM-dd')) AS DATA_INTERESSE,
    CASE lower(trim(etapa))
        WHEN 'primeiro contato' THEN 'Primeiro Contato'
        WHEN 'agendamento' THEN 'Agendamento'
        WHEN 'negociação' THEN 'Negociação'
        WHEN 'interesse futuro' THEN 'Interesse Futuro'
        WHEN 'sucesso' THEN 'Sucesso'
        WHEN 'insucesso' THEN 'Insucesso'
        WHEN 'negociacao' THEN 'Negociação'
        ELSE nullif(trim(etapa), '') END AS ETAPA,
    CASE lower(trim(motivo_insucesso))
        WHEN 'financeiro' THEN 'Financeiro'
        WHEN 'produto indisponível' THEN 'Produto Indisponível'
        WHEN 'crédito negado' THEN 'Crédito Negado'
        WHEN 'comprou em outra concessionária' THEN 'Comprou em Outra Concessionária'
        WHEN 'comprou no particular' THEN 'Comprou no Particular'
        WHEN 'contato sem sucesso' THEN 'Contato Sem Sucesso'
        ELSE nullif(trim(motivo_insucesso), '') END AS MOTIVO_INSUCESSO,
    CASE lower(trim(temperatura))
        WHEN 'quente' THEN 'Quente'
        WHEN 'morno' THEN 'Morno'
        WHEN 'frio' THEN 'Frio'
        ELSE nullif(trim(temperatura), '') END AS TEMPERATURA,
    coalesce(try_to_date(trim(data_ultimo_contato), 'dd/MM/yyyy'), try_to_date(trim(data_ultimo_contato), 'MM/dd/yyyy'),
        try_to_date(trim(data_ultimo_contato), 'yyyy-MM-dd')) AS DATA_ULTIMO_CONTATO,
    current_timestamp() AS _processado_em,
    _linhas_origem
FROM limpos;

ALTER TABLE lakehouse.silver.crm ALTER COLUMN ID_REGISTRO COMMENT 'Chave tecnica: chave natural mais sequencial ordenado por hash e conteudo bruto. Estavel para o mesmo snapshot; novas versoes podem renumerar o grupo. Nao resolve identidade ou conflito de negocio.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN _processado_em COMMENT 'Instante de processamento deste snapshot silver.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN _linhas_origem COMMENT 'Quantidade de linhas bronze integralmente iguais nas colunas de negocio consolidadas neste registro. A soma reconcilia com a bronze.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN ID_CLIENTE COMMENT 'Vinculo de origem CRM-ERP em maiusculas. Repeticoes divergentes preservadas; nao e uma prova de identidade nem chave unica.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN CLIENTE COMMENT 'Nome com espacos externos removidos e iniciais capitalizadas; nao usado para unir pessoas.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN GENERO COMMENT 'Grafias M, Fem e Feminno mapeadas para Masculino ou Feminino. Ausencia permanece NULL.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN IDADE COMMENT 'Idade informada convertida para inteiro, inclusive negativos e extremos. Ausencia permanece NULL; nao infere nascimento.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN CONTATO COMMENT 'Telefone com pontuacao para 8/9 digitos locais ou 10/11 com DDD. Sem inferir DDD; letras, tamanho invalido ou ausencia tornam-se NULL. Origem nao contem CPF/CNPJ/email.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN FONTE COMMENT 'Canal com case e espacos padronizados em oito grafias comerciais, preservando WhatsApp e OLX.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN PRODUTO_INTERESSE COMMENT 'Linha comercial em grafia canonica, preservando T-Cross; nao identifica veiculo individual.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN FORMA_PAGAMENTO COMMENT 'Financiamento ou À Vista, com espacos e case normalizados.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN ENTRADA_PCT COMMENT 'Percentual informado em pontos percentuais, decimal com duas casas; NULL nao vira zero e negativos sao preservados.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN FEZ_TEST_DRIVE COMMENT 'Sim, S e 1 tornam-se true; Não torna-se false; ausencia permanece NULL e valor desconhecido interrompe a carga.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN DATA_INTERESSE COMMENT 'Data segura por try_to_date: dd/MM/yyyy, depois MM/dd/yyyy e yyyy-MM-dd. Ambiguidade dia/mes segue padrao brasileiro.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN ETAPA COMMENT 'Etapa com espacos, case e negociacao corrigidos. Registros nao comprovam historico completo de transicoes.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN MOTIVO_INSUCESSO COMMENT 'Motivo em grafia canonica; ausencia permanece NULL. Motivos fora da etapa Insucesso sao preservados para revisao.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN TEMPERATURA COMMENT 'Classificacao Frio, Morno ou Quente com case e espacos padronizados.';
ALTER TABLE lakehouse.silver.crm ALTER COLUMN DATA_ULTIMO_CONTATO COMMENT 'Data segura nos formatos brasileiro, americano e ISO, nessa ordem. Nao substitui data invalida pela atual.';

-- Declarar novamente apenas os contratos desta feature torna a reexecucao idempotente.
ALTER TABLE lakehouse.silver.crm DROP CONSTRAINT IF EXISTS crm_chaves;
ALTER TABLE lakehouse.silver.crm ADD CONSTRAINT crm_chaves CHECK (
    ID_REGISTRO IS NOT NULL AND ID_REGISTRO RLIKE '^CLI[0-9]+-[1-9][0-9]*$' AND ID_CLIENTE IS NOT NULL AND ID_CLIENTE RLIKE '^CLI[0-9]+$'
);

ALTER TABLE lakehouse.silver.crm DROP CONSTRAINT IF EXISTS crm_obrigatorios;
ALTER TABLE lakehouse.silver.crm ADD CONSTRAINT crm_obrigatorios CHECK (
    CLIENTE IS NOT NULL AND length(CLIENTE) > 0 AND DATA_INTERESSE IS NOT NULL AND DATA_ULTIMO_CONTATO IS NOT NULL
);

ALTER TABLE lakehouse.silver.crm DROP CONSTRAINT IF EXISTS crm_dominios;
ALTER TABLE lakehouse.silver.crm ADD CONSTRAINT crm_dominios CHECK (
    (GENERO IS NULL OR GENERO IN ('Masculino', 'Feminino'))
    AND FONTE IS NOT NULL AND FONTE IN ('Instagram', 'WhatsApp', 'Google Ads', 'Site', 'Loja Física', 'Indicação', 'Facebook Ads', 'OLX')
    AND PRODUTO_INTERESSE IS NOT NULL AND PRODUTO_INTERESSE IN ('Polo', 'Nivus', 'Saveiro', 'Virtus', 'T-Cross', 'Taos', 'Amarok', 'Tiguan Allspace')
    AND FORMA_PAGAMENTO IS NOT NULL AND FORMA_PAGAMENTO IN ('Financiamento', 'À Vista')
    AND ETAPA IS NOT NULL AND ETAPA IN ('Primeiro Contato', 'Agendamento', 'Negociação', 'Interesse Futuro', 'Sucesso', 'Insucesso')
    AND TEMPERATURA IS NOT NULL AND TEMPERATURA IN ('Quente', 'Morno', 'Frio')
    AND (MOTIVO_INSUCESSO IS NULL OR MOTIVO_INSUCESSO IN ('Financeiro', 'Produto Indisponível', 'Crédito Negado', 'Comprou em Outra Concessionária', 'Comprou no Particular', 'Contato Sem Sucesso'))
);

ALTER TABLE lakehouse.silver.crm DROP CONSTRAINT IF EXISTS crm_contato;
ALTER TABLE lakehouse.silver.crm ADD CONSTRAINT crm_contato CHECK (
    CONTATO IS NULL OR CONTATO RLIKE '^([(][0-9]{2}[)] )?[0-9]{4,5}-[0-9]{4}$'
);

ALTER TABLE lakehouse.silver.crm DROP CONSTRAINT IF EXISTS crm_auditoria;
ALTER TABLE lakehouse.silver.crm ADD CONSTRAINT crm_auditoria CHECK (
    _processado_em IS NOT NULL AND _linhas_origem IS NOT NULL AND _linhas_origem >= 1
);

-- CHECK avalia cada linha; unicidade e conciliacao exigem verificacao agregada.
SELECT assert_true(count(*) = count(DISTINCT ID_REGISTRO), 'crm: ID_REGISTRO duplicado') AS chave_unica,
    assert_true(sum(_linhas_origem) = (SELECT count(*) FROM lakehouse.bronze.crm),
        'crm: linhas de origem nao reconciliadas') AS origem_reconciliada
FROM lakehouse.silver.crm;

SELECT 'crm' AS tabela, count(*) AS registros_silver, sum(_linhas_origem) AS linhas_bronze,
    sum(_linhas_origem) - count(*) AS duplicatas_exatas_removidas
FROM lakehouse.silver.crm;

"""Contratos estaticos da camada Gold e de sua orquestracao."""

import re
from pathlib import Path

import yaml

PROJECT = Path(__file__).resolve().parents[1]
GOLD = PROJECT / "src" / "gold"

DIMENSIONS = {
    "dim_cliente",
    "dim_produto",
    "dim_vendedor",
    "dim_pagamento",
    "dim_canal",
    "dim_calendario",
}
QUARANTINES = {"quarentena_cliente_identidade", "quarentena_estoque_mensal"}
FACTS = {"fato_vendas", "fato_oportunidade", "fato_estoque_mensal"}
MARTS = {
    "mart_vendas_por_vendedor",
    "mart_produto_performance",
    "mart_financeiro",
    "mart_funil_comercial",
}


def read_gold(filename: str) -> str:
    return (GOLD / filename).read_text(encoding="utf-8")


def created_tables(sql: str) -> set[str]:
    return set(re.findall(r"CREATE OR REPLACE TABLE lakehouse\.gold\.(\w+)", sql, flags=re.IGNORECASE))


def test_gold_le_somente_silver_e_gold() -> None:
    for filename in ("05-dimensoes.sql", "06-fato-vendas.sql", "07-marts.sql", "08-testes.sql"):
        sql = read_gold(filename).lower()
        assert "lakehouse.bronze" not in sql
        assert "/volumes/" not in sql
        assert not re.search(r"\bfrom\s+(?!lakehouse\.(?:silver|gold)\b)(?:\w+\.){2}\w+", sql)


def test_conjunto_de_tabelas_gold() -> None:
    assert created_tables(read_gold("05-dimensoes.sql")) == DIMENSIONS | QUARANTINES
    assert created_tables(read_gold("06-fato-vendas.sql")) == FACTS
    assert created_tables(read_gold("07-marts.sql")) == MARTS


def test_conflitos_sao_quarentenados_sem_resolucao_arbitraria() -> None:
    sql = read_gold("05-dimensoes.sql")
    assert "quarentena_cliente_identidade" in sql
    assert "quarentena_estoque_mensal" in sql
    assert "clientes_validos" in sql
    assert "HAVING count(*) > 1" in sql
    assert "raise_error(" in sql
    assert sql.index("CREATE OR REPLACE TABLE") < sql.index("raise_error(")
    assert "nenhuma identidade foi escolhida" in sql
    assert "nenhum saldo foi escolhido ou somado" in sql


def test_chaves_e_mapeamento_de_produto_sao_deterministicos() -> None:
    sql = read_gold("05-dimensoes.sql")
    assert sql.count("xxhash64(") == 5
    assert "CAST(date_format(DATA, 'yyyyMMdd') AS INT) AS SK_DATA" in sql
    for code, product in {
        "VW-POL": "Polo",
        "VW-NIV": "Nivus",
        "VW-SAV": "Saveiro",
        "VW-VIR": "Virtus",
        "VW-TCR": "T-Cross",
        "VW-TAO": "Taos",
        "VW-AMA": "Amarok",
        "VW-TIG": "Tiguan Allspace",
    }.items():
        assert f"('{code}', '{product}')" in sql
    assert "INTERVAL 1 DAY" in sql
    assert "DATA_NASCIMENTO FROM lakehouse.silver.erp" in sql


def test_fatos_preservam_grao_formula_e_comentarios() -> None:
    sql = read_gold("06-fato-vendas.sql")
    assert "E.VALOR_FATURAMENTO - E.CUSTO" in sql
    assert sql.count("LEFT JOIN lakehouse.gold.dim_") == 13
    assert "count(*) = (SELECT count(*) FROM lakehouse.silver.erp)" in sql
    assert "count(*) = (SELECT count(*) FROM lakehouse.silver.crm)" in sql
    assert "quarentena_estoque_mensal" in sql
    assert "ID_CLIENTE_ORIGEM" in sql

    fact_columns = {
        "fato_vendas": (
            "ID_REGISTRO",
            "ID_CLIENTE_ORIGEM",
            "SK_CLIENTE",
            "SK_PRODUTO",
            "SK_VENDEDOR",
            "SK_PAGAMENTO",
            "SK_DATA_ENTREGA",
            "BANCO",
            "MODELO",
            "COR_PRODUTO",
            "ANO_VEICULO",
            "ZERO_KM_OU_SEMINOVO",
            "VALOR_PADRAO",
            "DESCONTO",
            "VALOR_FATURAMENTO",
            "CUSTO",
            "MARGEM_BRUTA_CALCULADA",
        ),
        "fato_oportunidade": (
            "ID_REGISTRO",
            "ID_CLIENTE_ORIGEM",
            "SK_CLIENTE",
            "SK_PRODUTO",
            "SK_PAGAMENTO",
            "SK_CANAL",
            "SK_DATA_INTERESSE",
            "SK_DATA_ULTIMO_CONTATO",
            "ENTRADA_PCT",
            "IDADE",
            "DATA_NASCIMENTO",
            "ETAPA",
            "TEMPERATURA",
            "MOTIVO_INSUCESSO",
            "FEZ_TEST_DRIVE",
        ),
        "fato_estoque_mensal": (
            "ID_REGISTRO",
            "SK_PRODUTO",
            "SK_DATA_REFERENCIA",
            "QUANTIDADE_ESTOQUE",
            "CAMPANHA_ATUAL",
        ),
    }
    for table, columns in fact_columns.items():
        for column in columns:
            pattern = rf"ALTER TABLE lakehouse\.gold\.{table} ALTER COLUMN {column} COMMENT '.+';"
            assert re.search(pattern, sql), (table, column)


def test_marts_agregam_fatos_antes_de_relacionar_estoque() -> None:
    sql = read_gold("07-marts.sql")
    assert "FULL OUTER JOIN estoque" in sql
    assert "coalesce(V.FATURAMENTO, CAST(0 AS DECIMAL(18, 2)))" in sql
    assert "E.QUANTIDADE_ESTOQUE" in sql
    assert "coalesce(E.QUANTIDADE_ESTOQUE" not in sql
    assert "<= 0.80 THEN 'A'" in sql
    assert "<= 0.95 THEN 'B'" in sql
    assert "WHEN REGISTROS_VENDA = 0 THEN 'Sem Venda'" in sql
    assert "mart_funil_comercial" in sql
    assert "fato_oportunidade" in sql
    assert sql.count("count(DISTINCT O.ID_CLIENTE_ORIGEM)") == 1
    assert sql.count("count(DISTINCT V.ID_CLIENTE_ORIGEM)") == 1


def test_arquivo_sql_contem_nove_testes_e_raise_error_final() -> None:
    sql = read_gold("08-testes.sql")
    assert sql.count("UNION ALL") >= 8
    assert "CREATE OR REPLACE TEMP VIEW _gold_testes" in sql
    assert "count_if(NOT PASSOU)" in sql
    assert "raise_error(" in sql
    for order in range(1, 10):
        assert re.search(rf"(?:SELECT\s+)?{order}(?: AS ORDEM)?,\s*'", sql)


def test_dag_gold_e_sequencial_com_testes_por_ultimo() -> None:
    config = yaml.safe_load((PROJECT / "resources" / "pipeline.job.yml").read_text(encoding="utf-8"))
    tasks = config["resources"]["jobs"]["concessionaria_pipeline"]["tasks"]
    by_key = {task["task_key"]: task for task in tasks}

    expected = {
        "gold_dimensoes": (["silver_crm", "silver_erp", "silver_estoque"], "05-dimensoes.sql"),
        "gold_fato_vendas": (["gold_dimensoes"], "06-fato-vendas.sql"),
        "gold_marts": (["gold_fato_vendas"], "07-marts.sql"),
        "testes": (["gold_marts"], "08-testes.sql"),
    }
    for key, (dependencies, filename) in expected.items():
        task = by_key[key]
        assert [item["task_key"] for item in task["depends_on"]] == dependencies
        assert task["run_if"] == "ALL_SUCCESS"
        assert task["sql_task"] == {
            "warehouse_id": "$" + "{var.warehouse_id}",
            "file": {"path": f"../src/gold/{filename}", "source": "WORKSPACE"},
        }

    assert tasks[-1]["task_key"] == "testes"


def test_prompt_registra_decisoes_da_feature() -> None:
    prompt = (PROJECT.parent / "llm" / "prompt4.md").read_text(encoding="utf-8")
    assert "testes do domínio da concessionária" in prompt
    assert "curva ABC é mensal" in prompt
    assert "tabelas de\n    quarentena" in prompt
    assert "a execução\n    continua" in prompt

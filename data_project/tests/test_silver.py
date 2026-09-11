"""Regressoes SQL executam a projecao real contra VALUES, sem escrever tabelas."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

PROJECT = Path(__file__).resolve().parents[1]
TABLES = ("crm", "erp", "estoque")


def read_sql(table: str) -> str:
    return (PROJECT / "src" / "silver" / f"{table}.sql").read_text(encoding="utf-8")


def projection(table: str) -> str:
    return re.split(r";\r?\n", re.split(r"(?m)^AS\r?\n", read_sql(table), maxsplit=1)[1], maxsplit=1)[0]


def fixture_data(table: str) -> dict:
    return json.loads((PROJECT / "fixtures" / f"silver_{table}.json").read_text(encoding="utf-8"))


def fixture_query(table: str, rows: list[list]) -> str:
    columns = fixture_data(table)["columns"]

    def literal(value: str | None) -> str:
        return "cast(NULL AS STRING)" if value is None else "'" + value.replace("'", "''") + "'"

    values = ",\n".join("(" + ", ".join(literal(v) for v in row) + ")" for row in rows)
    source = f"(SELECT * FROM VALUES {values} AS fixture({', '.join(columns)}))"
    return projection(table).replace(f"lakehouse.bronze.{table}", source)


@pytest.fixture(scope="module")
def warehouse_query(request):
    if not request.config.getoption("--sql-warehouse-tests"):
        pytest.skip("Use --sql-warehouse-tests --databricks-profile PROFILE para testes SQL")
    profile = request.config.getoption("--databricks-profile")
    if not profile:
        pytest.fail("--databricks-profile e obrigatorio para testes SQL")
    cli = shutil.which("databricks")
    if not cli:
        pytest.fail("Databricks CLI nao encontrado")

    def run(query: str, expect_error: str | None = None) -> list[dict]:
        result = subprocess.run(
            [cli, "experimental", "aitools", "tools", "query", "--profile", profile],
            input=query,
            capture_output=True,
            encoding="utf-8",
            timeout=180,
            check=False,
        )
        if expect_error:
            assert result.returncode != 0
            assert expect_error in result.stderr + result.stdout
            return []
        assert result.returncode == 0, result.stderr + result.stdout
        return json.loads(result.stdout)

    return run


@pytest.mark.parametrize("table", TABLES)
def test_sql_contrato_estatico(table: str) -> None:
    sql = read_sql(table)
    executable = re.sub(r"--[^\n]*", "", sql)
    assert f"CREATE OR REPLACE TABLE lakehouse.silver.{table}" in executable
    assert set(re.findall(r"lakehouse\.bronze\.(\w+)", executable)) == {table}
    assert not re.search(r"\b(?:to_date|date_trunc)\s*\(", executable, flags=re.IGNORECASE)
    assert not re.search(r"\bcast\s*\([^)]*\bAS\s+DATE\b", executable, flags=re.IGNORECASE)
    assert "IDENTIFIER(" not in sql and "/Volumes/" not in sql
    assert "GROUP BY ALL" in sql and "sha2(_conteudo, 256), _conteudo" in sql
    assert "assert_true(count(*) = count(DISTINCT ID_REGISTRO)" in sql
    assert "sum(_linhas_origem) = (SELECT count(*)" in sql
    assert f"ADD CONSTRAINT {table}_auditoria CHECK" in sql
    for column in ("ID_REGISTRO", "_processado_em", "_linhas_origem"):
        assert re.search(rf"ALTER COLUMN {column} COMMENT '.+';", sql)
    assert "USING DELTA\nCOMMENT" in sql


def test_dag_silver_paralelo() -> None:
    config = yaml.safe_load((PROJECT / "resources" / "pipeline.job.yml").read_text(encoding="utf-8"))
    tasks = config["resources"]["jobs"]["concessionaria_pipeline"]["tasks"]
    silver = [t for t in tasks if t["task_key"].startswith("silver_")]
    assert {t["task_key"] for t in silver} == {f"silver_{t}" for t in TABLES}
    for task in silver:
        table = task["task_key"].removeprefix("silver_")
        assert task["depends_on"] == [{"task_key": "bronze_ingestao"}]
        assert task["run_if"] == "ALL_SUCCESS"
        assert task["sql_task"] == {
            "warehouse_id": "$" + "{var.warehouse_id}",
            "file": {"path": f"../src/silver/{table}.sql", "source": "WORKSPACE"},
        }
    bundle = yaml.safe_load((PROJECT / "databricks.yml").read_text(encoding="utf-8"))
    assert bundle["variables"]["warehouse_id"]["lookup"]["warehouse"] == "Serverless Starter Warehouse"


@pytest.mark.parametrize("table", TABLES)
def test_transformacao_e_chaves_reproduziveis(table: str, warehouse_query) -> None:
    fixture = fixture_data(table)
    query = fixture_query(table, fixture["rows"])
    result = warehouse_query(f"WITH resultado AS ({query}) SELECT * EXCEPT (_processado_em) FROM resultado")
    assert len(result) == len(fixture["rows"]) - 1
    assert len({r["ID_REGISTRO"] for r in result}) == len(result)
    assert sum(int(r["_linhas_origem"]) for r in result) == len(fixture["rows"])
    for expected in fixture["expected"]:
        matches = [r for r in result if r.get("ID_CLIENTE", "") == expected.get("ID_CLIENTE", "")]
        assert matches
        for row in matches:
            for key, value in expected.items():
                actual = row[key]
                normalized = "" if actual is None else str(actual).lower() if isinstance(actual, bool) else str(actual)
                assert normalized == value, (table, key, actual, value)
    reversed_query = fixture_query(table, list(reversed(fixture["rows"])))
    repeated = warehouse_query(f"WITH resultado AS ({reversed_query}) SELECT * EXCEPT (_processado_em) FROM resultado")
    assert sorted(result, key=lambda r: r["ID_REGISTRO"]) == sorted(repeated, key=lambda r: r["ID_REGISTRO"])
    if table == "estoque":
        assert {r["ID_REGISTRO"] for r in result} == {f"2024-02-VW-NIV-{i}" for i in (1, 2, 3)}
        assert sorted(r["ESTOQUE_ATUAL"] for r in result) == ["", "-12", "5"]


@pytest.mark.parametrize(
    "table,date_column", [("crm", "data_interesse"), ("erp", "data_entrega"), ("estoque", "mes_referencia")]
)
def test_data_malformada_vira_null_e_viola_contrato(table: str, date_column: str, warehouse_query) -> None:
    fixture = fixture_data(table)
    row = fixture["rows"][0].copy()
    row[fixture["columns"].index(date_column)] = "data-invalida"
    query = fixture_query(table, [row])
    result = warehouse_query(
        f"WITH resultado AS ({query}) SELECT {date_column.upper()} IS NULL AS data_nula FROM resultado"
    )
    assert str(result[0]["data_nula"]).lower() == "true"
    constraints = re.findall(r"ADD CONSTRAINT (\w+) CHECK \((.*?)\n\);", read_sql(table), re.DOTALL)
    condition = next(expr for _, expr in constraints if f"{date_column.upper()} IS NOT NULL" in expr)
    result = warehouse_query(
        f"WITH resultado AS ({query}) SELECT coalesce(({condition}), false) AS contrato FROM resultado"
    )
    assert str(result[0]["contrato"]).lower() == "false"


@pytest.mark.parametrize("table,column", [("crm", "idade"), ("crm", "entrada_pct"), ("estoque", "estoque_atual")])
def test_numero_nao_vazio_invalido_nao_desaparece(table: str, column: str, warehouse_query) -> None:
    fixture = fixture_data(table)
    row = fixture["rows"][0].copy()
    row[fixture["columns"].index(column)] = "abc"
    query = fixture_query(table, [row])
    warehouse_query(
        f"WITH resultado AS ({query}) SELECT {column.upper()} FROM resultado",
        expect_error=f"{column.upper()} invalido",
    )


def test_booleano_desconhecido_falha(warehouse_query) -> None:
    fixture = fixture_data("crm")
    row = fixture["rows"][0].copy()
    row[fixture["columns"].index("fez_test_drive")] = "talvez"
    warehouse_query(
        f"WITH resultado AS ({fixture_query('crm', [row])}) SELECT FEZ_TEST_DRIVE FROM resultado",
        expect_error="FEZ_TEST_DRIVE desconhecido",
    )

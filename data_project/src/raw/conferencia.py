# Databricks notebook source
# ruff: noqa: F821  # spark e dbutils sao fornecidos pelo runtime Databricks.
import re

from pyspark.sql import functions as F
from pyspark.sql import types as T


dbutils.widgets.text("catalog", "lakehouse", "Catalog")
catalog = dbutils.widgets.get("catalog").strip()

if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", catalog):
    raise ValueError(f"Nome de catalogo invalido: {catalog!r}")


ARQUIVOS_ESPERADOS = (
    ("erp", "erp", "erp_concessionaria_2024_2025.csv"),
    ("crm", "crm", "crm_concessionaria_2024_2025.csv"),
    ("estoque", "loja", "estoque_concessionaria_2024_2025.csv"),
)


def localizar_arquivo(caminho: str):
    diretorio, nome = caminho.rsplit("/", 1)
    encontrados = [item for item in dbutils.fs.ls(diretorio) if item.name.rstrip("/") == nome]
    return encontrados[0] if encontrados else None


resultados = []
erros = []

for sistema, pasta, arquivo in ARQUIVOS_ESPERADOS:
    caminho = f"/Volumes/{catalog}/bronze/raw/{pasta}/{arquivo}"
    try:
        metadata = localizar_arquivo(caminho)
    except Exception as exc:
        erros.append(f"{sistema}: nao foi possivel listar {caminho}: {exc}")
        continue

    if metadata is None:
        erros.append(f"{sistema}: arquivo ausente: {caminho}")
        continue

    bytes_arquivo = int(metadata.size)
    total_linhas = spark.read.text(caminho).count() if bytes_arquivo > 0 else 0
    linhas_dados = max(total_linhas - 1, 0)

    if bytes_arquivo == 0 or linhas_dados == 0:
        erros.append(
            f"{sistema}: arquivo vazio ou sem linhas de dados: {caminho} "
            f"(bytes={bytes_arquivo}, linhas={linhas_dados})"
        )
        continue

    resultados.append((sistema, arquivo, bytes_arquivo, linhas_dados))

if erros:
    raise RuntimeError("Conferencia raw falhou:\n- " + "\n- ".join(erros))

schema = T.StructType(
    [
        T.StructField("sistema", T.StringType(), False),
        T.StructField("arquivo", T.StringType(), False),
        T.StructField("bytes", T.LongType(), False),
        T.StructField("linhas", T.LongType(), False),
    ]
)

controle = spark.createDataFrame(resultados, schema=schema).withColumn("conferido_em", F.current_timestamp())
tabela_controle = f"`{catalog}`.`bronze`.`_raw_arquivos`"

# Todas as entradas sao validadas antes deste overwrite. Assim, uma falha nao
# substitui o ultimo snapshot valido por um resultado parcial.
(
    controle.write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(tabela_controle)
)

spark.sql(
    f"COMMENT ON TABLE {tabela_controle} IS "
    "'Snapshot da ultima conferencia dos arquivos raw obrigatorios recebidos por sistema de origem'"
)

print(f"Conferencia concluida: {len(resultados)} arquivos validos.")
spark.table(tabela_controle).orderBy("sistema").show(n=len(resultados), truncate=False)

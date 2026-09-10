# Databricks notebook source
# ruff: noqa: F821  # spark e dbutils sao fornecidos pelo runtime Databricks.
import re
from dataclasses import dataclass

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql import types as T


@dataclass(frozen=True)
class TabelaBronze:
    """Define a origem raw e a tabela Delta correspondente na camada bronze."""

    sistema: str
    pasta: str
    arquivo: str
    tabela: str
    comentario: str


@dataclass(frozen=True)
class ResultadoIngestao:
    """Registra as contagens usadas na conferencia de uma tabela bronze."""

    tabela: str
    linhas_tabela: int
    linhas_esperadas: int

    @property
    def status(self) -> str:
        """Informa se a tabela preservou a quantidade de linhas conferida no raw."""
        return "OK" if self.linhas_tabela == self.linhas_esperadas else "DIVERGENTE"


TABELAS_BRONZE = (
    TabelaBronze(
        sistema="crm",
        pasta="crm",
        arquivo="crm_concessionaria_2024_2025.csv",
        tabela="crm",
        comentario="Dados brutos ingeridos do sistema de origem CRM, sem limpeza ou conversao de tipos",
    ),
    TabelaBronze(
        sistema="erp",
        pasta="erp",
        arquivo="erp_concessionaria_2024_2025.csv",
        tabela="erp",
        comentario="Dados brutos ingeridos do sistema de origem ERP, sem limpeza ou conversao de tipos",
    ),
    TabelaBronze(
        sistema="estoque",
        pasta="loja",
        arquivo="estoque_concessionaria_2024_2025.csv",
        tabela="estoque",
        comentario="Dados brutos ingeridos do controle de estoque da loja, sem limpeza ou conversao de tipos",
    ),
)

COLUNAS_METADADOS = {"_ingerido_em", "_arquivo_origem"}


def validar_catalogo(catalogo: str) -> str:
    """Valida e devolve um identificador simples de Unity Catalog."""
    catalogo = catalogo.strip()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", catalogo):
        raise ValueError(f"Nome de catalogo invalido: {catalogo!r}")
    return catalogo


def caminho_arquivo(catalogo: str, definicao: TabelaBronze) -> str:
    """Monta o caminho governado do arquivo raw no Volume."""
    return f"/Volumes/{catalogo}/bronze/raw/{definicao.pasta}/{definicao.arquivo}"


def nome_tabela(catalogo: str, tabela: str) -> str:
    """Monta um identificador de tabela bronze protegido por crases."""
    return f"`{catalogo}`.`bronze`.`{tabela}`"


def carregar_linhas_esperadas(
    spark_session: SparkSession,
    catalogo: str,
    definicoes: tuple[TabelaBronze, ...] = TABELAS_BRONZE,
) -> dict[str, int]:
    """Carrega do controle raw exatamente uma contagem para cada arquivo esperado."""
    controle = nome_tabela(catalogo, "_raw_arquivos")
    registros = spark_session.table(controle).select("sistema", "arquivo", "linhas").collect()
    por_origem: dict[tuple[str, str], list[int]] = {}

    for registro in registros:
        chave = (registro["sistema"], registro["arquivo"])
        por_origem.setdefault(chave, []).append(int(registro["linhas"]))

    erros = []
    esperadas = {}
    for definicao in definicoes:
        chave = (definicao.sistema, definicao.arquivo)
        contagens = por_origem.get(chave, [])
        if not contagens:
            erros.append(f"registro ausente para sistema={definicao.sistema}, arquivo={definicao.arquivo}")
        elif len(contagens) > 1:
            erros.append(f"registros duplicados para sistema={definicao.sistema}, arquivo={definicao.arquivo}")
        else:
            esperadas[definicao.tabela] = contagens[0]

    if erros:
        raise RuntimeError("Controle raw invalido:\n- " + "\n- ".join(erros))

    return esperadas


def ingerir_tabela(spark_session: SparkSession, catalogo: str, definicao: TabelaBronze) -> int:
    """Ingere um CSV fielmente como strings e devolve a contagem persistida."""
    caminho = caminho_arquivo(catalogo, definicao)
    origem = (
        spark_session.read.format("csv")
        .option("header", "true")
        .option("inferSchema", "false")
        .option("multiLine", "false")
        .load(caminho)
    )

    colunas_reservadas = COLUNAS_METADADOS.intersection(origem.columns)
    if colunas_reservadas:
        raise RuntimeError(f"Arquivo {definicao.arquivo} ja possui colunas reservadas: {sorted(colunas_reservadas)}")

    colunas_nao_string = [campo.name for campo in origem.schema.fields if not isinstance(campo.dataType, T.StringType)]
    if colunas_nao_string:
        raise RuntimeError(f"Arquivo {definicao.arquivo} produziu colunas nao string: {sorted(colunas_nao_string)}")

    bronze = origem.withColumn("_ingerido_em", F.current_timestamp()).withColumn("_arquivo_origem", F.lit(caminho))
    destino = nome_tabela(catalogo, definicao.tabela)

    bronze.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino)
    spark_session.sql(f"COMMENT ON TABLE {destino} IS '{definicao.comentario}'")

    return spark_session.table(destino).count()


def validar_contagens(resultados: list[ResultadoIngestao]) -> None:
    """Falha a execucao quando uma tabela diverge da conferencia raw."""
    divergencias = [resultado for resultado in resultados if resultado.status != "OK"]
    if divergencias:
        detalhes = [
            f"{resultado.tabela}: tabela={resultado.linhas_tabela}, esperado={resultado.linhas_esperadas}"
            for resultado in divergencias
        ]
        raise RuntimeError("Conferencia bronze falhou:\n- " + "\n- ".join(detalhes))


def main() -> None:
    """Executa a ingestao das fontes e apresenta a conferencia final."""
    dbutils.widgets.text("catalog", "lakehouse", "Catalog")
    catalogo = validar_catalogo(dbutils.widgets.get("catalog"))
    linhas_esperadas = carregar_linhas_esperadas(spark, catalogo)
    resultados = []

    for definicao in TABELAS_BRONZE:
        linhas_tabela = ingerir_tabela(spark, catalogo, definicao)
        resultados.append(
            ResultadoIngestao(
                tabela=definicao.tabela,
                linhas_tabela=linhas_tabela,
                linhas_esperadas=linhas_esperadas[definicao.tabela],
            )
        )

    schema_resultado = T.StructType(
        [
            T.StructField("tabela", T.StringType(), False),
            T.StructField("linhas_tabela", T.LongType(), False),
            T.StructField("linhas_esperadas", T.LongType(), False),
            T.StructField("status", T.StringType(), False),
        ]
    )
    resumo = spark.createDataFrame(
        [
            (resultado.tabela, resultado.linhas_tabela, resultado.linhas_esperadas, resultado.status)
            for resultado in resultados
        ],
        schema=schema_resultado,
    )

    print("Conferencia da ingestao bronze:")
    resumo.orderBy("tabela").show(n=len(resultados), truncate=False)
    validar_contagens(resultados)
    print(f"Ingestao bronze concluida: {len(resultados)} tabelas validas.")


if __name__ == "__main__":
    main()

import pytest

from src.bronze.ingestao import TABELAS_BRONZE, ResultadoIngestao, validar_catalogo, validar_contagens


def test_mapeamento_das_fontes_bronze() -> None:
    mapeamento = {
        definicao.tabela: (definicao.sistema, definicao.pasta, definicao.arquivo) for definicao in TABELAS_BRONZE
    }

    assert mapeamento == {
        "crm": ("crm", "crm", "crm_concessionaria_2024_2025.csv"),
        "erp": ("erp", "erp", "erp_concessionaria_2024_2025.csv"),
        "estoque": ("estoque", "loja", "estoque_concessionaria_2024_2025.csv"),
    }


@pytest.mark.parametrize("catalogo", ["lakehouse", "catalogo_2", "_catalogo"])
def test_validar_catalogo_aceita_identificadores_simples(catalogo: str) -> None:
    assert validar_catalogo(f"  {catalogo}  ") == catalogo


@pytest.mark.parametrize("catalogo", ["", "2lakehouse", "lake-house", "lakehouse.bronze", "lake house"])
def test_validar_catalogo_rejeita_identificadores_inseguros(catalogo: str) -> None:
    with pytest.raises(ValueError, match="Nome de catalogo invalido"):
        validar_catalogo(catalogo)


def test_validar_contagens_aceita_resultados_iguais() -> None:
    validar_contagens([ResultadoIngestao(tabela="crm", linhas_tabela=2324, linhas_esperadas=2324)])


def test_validar_contagens_falha_com_detalhes_da_divergencia() -> None:
    resultados = [ResultadoIngestao(tabela="erp", linhas_tabela=451, linhas_esperadas=452)]

    with pytest.raises(RuntimeError, match=r"erp: tabela=451, esperado=452"):
        validar_contagens(resultados)

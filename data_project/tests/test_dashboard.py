"""Contract tests for the versioned Databricks AI/BI dashboard."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DASHBOARD_PATH = PROJECT_ROOT / "resources" / "dashboard-comercial.lvdash.json"
RESOURCE_PATH = PROJECT_ROOT / "resources" / "dashboard.dashboard.yml"

EXPECTED_DATASETS = {"ds_vendas", "ds_oportunidades"}
EXPECTED_VERSIONS = {
    "counter": 2,
    "table": 2,
    "bar": 3,
    "custom-vega-viz": 1,
    "line": 3,
    "funnel": 1,
    "filter-single-select": 2,
}
EXPECTED_MEASURES = {
    "Receita",
    "Margem bruta",
    "Registros de venda",
    "Ticket médio por registro",
    "Margem %",
}


def _dashboard() -> dict[str, Any]:
    return json.loads(DASHBOARD_PATH.read_text(encoding="utf-8"))


def _widgets(dashboard: dict[str, Any]):
    for page in dashboard["pages"]:
        for item in page["layout"]:
            yield item["widget"]


def _field_names(value: Any) -> set[str]:
    names: set[str] = set()
    if isinstance(value, dict):
        if "fieldName" in value:
            names.add(value["fieldName"])
        for child in value.values():
            names.update(_field_names(child))
    elif isinstance(value, list):
        for child in value:
            names.update(_field_names(child))
    return names


def test_dashboard_and_bundle_resource_contract() -> None:
    dashboard = _dashboard()
    resource = yaml.safe_load(RESOURCE_PATH.read_text(encoding="utf-8"))
    datasets = {dataset["name"]: dataset for dataset in dashboard["datasets"]}

    assert set(datasets) == EXPECTED_DATASETS
    assert all(dataset["catalog"] == "lakehouse" for dataset in datasets.values())
    assert all(dataset["schema"] == "gold" for dataset in datasets.values())
    sales_measures = {column["displayName"] for column in datasets["ds_vendas"]["columns"]}
    assert sales_measures == EXPECTED_MEASURES

    config = resource["resources"]["dashboards"]["dashboard_comercial"]
    assert config == {
        "display_name": "Dashboard Comercial",
        "file_path": "./dashboard-comercial.lvdash.json",
        "warehouse_id": "${var.warehouse_id}",
        "dataset_catalog": "${var.catalog}",
        "dataset_schema": "gold",
    }
    assert (RESOURCE_PATH.parent / config["file_path"]).resolve() == DASHBOARD_PATH.resolve()


def test_dataset_sql_is_portable_and_uses_supported_gold_contract() -> None:
    for dataset in _dashboard()["datasets"]:
        query_lines = dataset["queryLines"]
        assert query_lines
        assert all(line[-1].isspace() for line in query_lines)
        assert all(parameter.get("displayName") for parameter in dataset.get("parameters", []))

        sql = "".join(query_lines)
        normalized = sql.casefold()
        assert re.search(r"\bcast\s*\(", normalized) is None
        assert "try_to_date(" not in normalized
        assert ";" not in sql

        relations = re.findall(r"\b(?:from|join)\s+([A-Za-z_][\w.]*)", sql, flags=re.IGNORECASE)
        assert relations
        assert all("." not in relation for relation in relations)


def test_pages_use_grid_and_rows_fill_twelve_columns() -> None:
    for page in _dashboard()["pages"]:
        assert page["pageType"] in {"PAGE_TYPE_CANVAS", "PAGE_TYPE_GLOBAL_FILTERS"}
        assert page["layoutVersion"] == "GRID_V1"

        rows: dict[int, int] = {}
        for item in page["layout"]:
            position = item["position"]
            rows[position["y"]] = rows.get(position["y"], 0) + position["width"]
        assert all(width == 12 for width in rows.values())


def test_widget_versions_names_and_field_bindings() -> None:
    dataset_parameters = {
        dataset["name"]: {parameter["keyword"] for parameter in dataset.get("parameters", [])}
        for dataset in _dashboard()["datasets"]
    }

    for widget in _widgets(_dashboard()):
        assert re.fullmatch(r"[A-Za-z0-9_-]{1,60}", widget["name"])
        if "multilineTextboxSpec" in widget:
            assert "spec" not in widget
            continue

        spec = widget["spec"]
        widget_type = spec["widgetType"]
        assert spec["version"] == EXPECTED_VERSIONS[widget_type]
        assert spec["frame"]["showTitle"] is True

        queries = {query["name"]: query["query"] for query in widget["queries"]}
        if widget_type.startswith("filter-"):
            for encoding in spec["encodings"]["fields"]:
                query = queries[encoding["queryName"]]
                if "fieldName" in encoding:
                    names = {field["name"] for field in query.get("fields", [])}
                    assert encoding["fieldName"] in names
                if "parameterName" in encoding:
                    names = {parameter["keyword"] for parameter in query.get("parameters", [])}
                    assert encoding["parameterName"] in names
                    assert encoding["parameterName"] in dataset_parameters[query["datasetName"]]
            continue

        query_fields = {field["name"] for query in queries.values() for field in query.get("fields", [])}
        assert _field_names(spec["encodings"]) <= query_fields


def test_removed_error_tables_and_theme_contract() -> None:
    dashboard = _dashboard()
    widgets = {widget["name"]: widget for widget in _widgets(dashboard)}
    assert "vendas-mensais-vendedor" not in widgets
    assert "margem-mensal-vendedor" not in widgets
    assert "forecast-registros" not in widgets
    assert "top-clientes" not in widgets
    assert all(widget.get("spec", {}).get("widgetType") != "table" for widget in widgets.values())

    theme = dashboard["uiSettings"]["theme"]
    assert theme["canvasBackgroundColor"] == {"light": "#FFFFFF", "dark": "#FFFFFF"}
    assert theme["widgetBackgroundColor"] == {"light": "#FFFFFF", "dark": "#FFFFFF"}
    assert theme["widgetBorderColor"] == theme["widgetBackgroundColor"]
    assert theme["gridLineColor"] == theme["widgetBackgroundColor"]
    assert theme["fontColor"] == {"light": "#263442", "dark": "#263442"}
    assert theme["selectionColor"] == {"light": "#6E8CA8", "dark": "#6E8CA8"}
    assert theme["visualizationColors"] == [
        "#6E8CA8",
        "#F3B8B5",
        "#A8BDCE",
        "#D8E2EA",
        "#C9D8CF",
        "#E5CDD7",
        "#D4CBE4",
    ]
    assert theme["fontFamily"] == "Poppins"


def test_requested_chart_cleanup_and_colors() -> None:
    widgets = {widget["name"]: widget for widget in _widgets(_dashboard())}

    for name, title in {
        "receita-mensal": "Receita — 24 meses",
        "margem-percentual-mensal": "Margem percentual",
    }.items():
        spec = widgets[name]["spec"]
        assert spec["frame"]["title"] == title
        assert spec["encodings"]["x"]["axis"]["hideTitle"] is True
        assert spec["encodings"]["y"]["axis"]["hideTitle"] is True

    car_widget = widgets["carros-receita-margem"]
    car_spec = json.loads(car_widget["spec"]["jsonSpec"]["spec"])
    assert car_widget["queries"][0]["query"]["disaggregated"] is True
    assert car_spec["encoding"]["x"]["axis"]["grid"] is False
    assert car_spec["encoding"]["x"]["title"] is None
    assert car_spec["encoding"]["y"]["title"] is None
    assert car_spec["encoding"]["color"]["scale"] == {
        "domain": ["Receita", "Margem bruta"],
        "range": ["#D8E2EA", "#6E8CA8"],
    }
    assert car_spec["encoding"]["color"]["legend"]["title"] is None

    widget = widgets["receita-margem-percentual-vendedor"]
    query = widget["queries"][0]["query"]

    assert query["disaggregated"] is True
    assert {field["name"] for field in query["fields"]} == {
        "vendedor",
        "valor_faturamento",
        "margem_bruta_calculada",
    }

    spec = json.loads(widget["spec"]["jsonSpec"]["spec"])
    assert spec["data"] == {"name": "databricks_query"}
    assert spec["transform"][1]["as"] == "margem_percentual"
    assert spec["layer"][0]["encoding"]["x"]["field"] == "receita_total"
    assert spec["layer"][1]["encoding"]["x"]["field"] == "margem_bruta"
    assert spec["encoding"]["y"]["title"] is None
    assert spec["layer"][0]["encoding"]["color"]["datum"] == "Receita"
    assert spec["layer"][1]["encoding"]["color"]["datum"] == "Margem bruta"
    assert spec["layer"][0]["encoding"]["color"]["scale"]["range"] == ["#D8E2EA", "#6E8CA8"]
    assert spec["layer"][0]["encoding"]["color"]["legend"]["title"] is None
    assert "showDescription" not in widget["spec"]["frame"]

    clients_spec = widgets["clientes-canal"]["spec"]
    assert clients_spec["encodings"]["y"]["axis"]["hideTitle"] is True
    assert _dashboard()["uiSettings"]["theme"]["visualizationColors"][0] == "#6E8CA8"

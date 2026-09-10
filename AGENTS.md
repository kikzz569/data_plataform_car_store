# Repository Guidelines

## Project Structure & Module Organization

The repository separates source data from the Databricks project:

- `raw/` contains CRM, ERP, and inventory CSV extracts for 2024–2025. Treat these files as source inputs; do not modify them in place without documenting why.
- `data_project/` is the Python 3.10–3.12 and Databricks Declarative Automation Bundle workspace.
- `data_project/src/` is the intended location for importable Python modules.
- `data_project/resources/` holds bundle resource YAML for jobs and pipelines.
- `data_project/tests/` contains pytest tests; shared Spark and fixture helpers belong in `conftest.py`.
- `data_project/fixtures/` stores small, deterministic CSV or JSON test datasets.

Run project commands from `data_project/` unless stated otherwise.

## Build, Test, and Development Commands

```powershell
cd data_project
uv sync --dev
uv run ruff check .
uv run ruff format --check .
uv run pytest
uv build
databricks bundle validate --target dev
databricks bundle deploy --target dev
```

`uv sync --dev` installs the locked development environment. Ruff checks style, pytest runs the test suite, and `uv build` creates the Python package. Validate the bundle before deployment. Production deployment (`--target prod`) requires deliberate approval and valid workspace credentials.

## Coding Style & Naming Conventions

Use four-space indentation, type hints for public functions, and concise docstrings for reusable modules and fixtures. Ruff is the formatter and linter; its configured line length is 120 characters. Name modules and functions with `snake_case`, classes with `PascalCase`, and constants with `UPPER_SNAKE_CASE`. Keep environment-specific values in bundle variables rather than embedding catalog or schema names in Python.

## Testing Guidelines

Use pytest and name files `test_<feature>.py` and tests `test_<behavior>()`. Prefer small fixtures in `fixtures/`; do not use full files from `raw/` for unit tests. The shared `spark` fixture initializes Databricks Connect and falls back to serverless compute, so configure Databricks authentication before running Spark tests. Add regression tests for transformations and schema changes.

## Commit & Pull Request Guidelines

History is currently minimal and does not establish a strict convention. Use short, imperative commit subjects, optionally scoped, such as `pipeline: add inventory normalization`. Keep commits focused. Pull requests should explain the data or bundle change, list validation and test commands run, link relevant issues, and call out schema, credential, or deployment impacts. Include screenshots only for UI or dashboard changes; never commit tokens, workspace credentials, generated build artifacts, or local `.databricks/` state.

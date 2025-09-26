.PHONY: run ruff-typecheck

run:
	uv run python -m watcher.main

ruff-c:
	uv run ruff check .

ruff-f:
	uv run ruff format .
	uv run ruff check . --fix

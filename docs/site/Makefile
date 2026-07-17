# agda-deps docs site (Pelican). See README.md for the layout.
#
#   make install   # create .venv and install pelican + markdown
#   make html      # stage content, then build into ../ (docs/)
#   make serve     # build, then serve docs/ on :8000
#   make clean     # remove staged content + caches (the published site under
#                  # docs/ is rebuilt fresh on each `make html`)
#
# Output goes to docs/ (OUTPUT_PATH in pelicanconf.py); the clean rebuild keeps
# this generator (docs/site) and docs/.nojekyll via OUTPUT_RETENTION.
# Pass STAGE_FLAGS=--internal to also render CLAUDE.md as an Internals page.

VENV    ?= .venv
PY       = $(VENV)/bin/python
PELICAN  = $(VENV)/bin/pelican
STAGE_FLAGS ?=

.PHONY: install stage html serve clean

install:
	python3 -m venv $(VENV)
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r requirements.txt

stage:
	$(PY) stage.py $(STAGE_FLAGS)

html: stage
	$(PELICAN) -s pelicanconf.py

serve: html
	@echo "Serving http://127.0.0.1:8000/  (docs/, Ctrl-C to stop)"
	cd .. && python3 -m http.server 8000 --bind 127.0.0.1

clean:
	rm -rf content/pages content/views __pycache__ plugins/__pycache__

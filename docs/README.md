# Documentation for the rocelet RoCE v2 reference design

This folder contains the Sphinx sources of the documentation for this reference design.

The pages are MyST Markdown, rendered as Jinja2 templates against `config/data.json` (the target
design tables are generated from it), so add or change a target design in `data.json`, not in the
pages.

## How to build the docs locally

You need Python 3 with Sphinx, the MyST parser and the ReadTheDocs Sphinx theme. The packages used
by Read the Docs are listed in `requirements.txt`:

```
python3 -m venv sphinx_venv
source sphinx_venv/bin/activate
pip install -r <path-of-this-repo>/docs/requirements.txt
sphinx-build -b html <path-of-this-repo>/docs/source <path-of-this-repo>/docs/build/html
```

To view the locally generated docs, open `<path-of-this-repo>/docs/build/html/index.html` in a
web browser.

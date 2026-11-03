# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Path setup --------------------------------------------------------------

# If extensions (or modules to document with autodoc) are in another directory,
# add these directories to sys.path here. If the directory is relative to the
# documentation root, use os.path.abspath to make it absolute, like shown here.
#
# import os
# import sys
# sys.path.insert(0, os.path.abspath('.'))
import sys
import os
numfig = True

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = 'rocelet RoCE v2 reference design for the 2x QSFP28 FMC'
copyright = '2026, Opsero Electronic Design Inc.'
author = 'Jeff Johnson'

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = [
  'myst_parser',
]

# Generate anchors for headings up to level 4 so that the pages can link to
# each other's sections with plain markdown links (page.md#section-slug).
myst_heading_anchors = 4

# Add any paths that contain templates here, relative to this directory.
templates_path = ['_templates']

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = []



# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = 'sphinx_rtd_theme'

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
# (no custom static files: an empty list keeps the build free of a
# 'html_static_path entry does not exist' warning)
html_static_path = []

import os
import json
from sphinx.util.fileutil import copy_asset
from jinja2 import Environment, FileSystemLoader

# Load the JSON data (config/data.json is the single source of truth for the
# target designs; the .md pages are Jinja2 templates rendered against it)
def load_json():
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'config', 'data.json')) as f:
        return json.load(f)

# Add the data as a context variable for Jinja2 templates
html_context = {
    'data': load_json(),
}

# Function to process Jinja2 templates in .md files
def render_jinja(app, docname, source):
    env = Environment(
        loader=FileSystemLoader(app.srcdir),
    )
    template = env.from_string(source[0])
    rendered_content = template.render(html_context)
    source[0] = rendered_content

# Connect the Jinja2 rendering function to the Sphinx build process
def setup(app):
    app.connect('source-read', render_jinja)

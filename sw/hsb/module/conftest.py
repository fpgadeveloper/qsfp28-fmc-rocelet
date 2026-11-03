# SPDX-License-Identifier: MIT
# pytest option --module-dir for test_module.py (default: ./build/lib/hololink/modules)
import os


def pytest_addoption(parser):
    parser.addoption("--module-dir", default=None, help="directory holding hololink_<uuid>_2603.so")


def pytest_configure(config):
    d = config.getoption("--module-dir")
    if d:
        import test_module
        test_module._module_dir = os.path.abspath(d)

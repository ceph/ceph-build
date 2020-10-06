import pytest


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "code_test: mark test to run against code related changes"
    )


def pytest_addoption(parser):
    parser.addoption("--skip-code-test", action="store_true",
                     help="skip code tests")


def pytest_runtest_setup(item):
    if "code_test" in item.keywords and item.config.getoption("--skip-code-test"):
        pytest.skip("skipping due to --skip-code-test")

"""Phase 1, criterion 2: bin/4lm_helpers.py exposes a non-empty __version__ string."""


def test_module_has_version(helpers):
    assert hasattr(helpers, "__version__")
    assert isinstance(helpers.__version__, str)
    assert len(helpers.__version__) > 0

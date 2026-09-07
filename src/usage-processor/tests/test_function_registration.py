"""Regression tests for function registration and worker-compatible annotations.

The azure-functions-worker validates binding parameter annotations before indexing
functions.  It accepts ``typing._GenericAlias`` (e.g. ``typing.List[X]``) but
rejects ``types.GenericAlias`` (PEP 585 built-in generics, e.g. ``list[X]``),
raising:

    FunctionLoadError: binding <param> has invalid non-type annotation list[X]

This causes the worker to exit and *all* functions to report as unloaded, even
those whose own annotations are correct.  These tests catch the regression before
deployment.
"""
import types
import typing
import unittest

import bootstrap  # noqa: F401 - adds processor root to sys.path

import function_app

_EXPECTED_FUNCTIONS = {
    "ProcessAIUsage",
    "MonitorEventHubCheckpoints",
    "AllocateFocusCost",
    "RecordClaudeCcuContext",
}


def _registered_builders():
    """Return (function_name, callable) pairs from the FunctionApp registry.

    In azure-functions SDK 1.x the FunctionApp stores FunctionBuilder objects
    in _function_builders.  Each builder holds a Function object whose _func
    attribute is the actual Python callable.
    """
    builders = getattr(function_app.app, "_function_builders", None)
    if builders is None:
        return None
    result = []
    for b in builders:
        fn_obj = b._function
        name = fn_obj.get_function_name()
        fn = fn_obj._func
        result.append((name, fn))
    return result


class TestBindingAnnotationCompatibility(unittest.TestCase):
    """All binding parameter annotations must survive azure-functions-worker validation."""

    def _iter_registered_functions(self):
        pairs = _registered_builders()
        if pairs is None:
            self.skipTest("_function_builders not available in this SDK version")
        return pairs

    def test_no_pep585_generic_alias_in_binding_parameters(self):
        """PEP 585 built-in generic aliases (list[X]) must not appear as binding
        parameter annotations.

        The worker checks isinstance(annotation, type) or
        isinstance(annotation, typing._GenericAlias) and raises FunctionLoadError
        on types.GenericAlias.  Use typing.List etc. instead.
        """
        for func_name, fn in self._iter_registered_functions():
            with self.subTest(function=func_name):
                hints = typing.get_type_hints(fn)
                for param_name, annotation in hints.items():
                    self.assertNotIsInstance(
                        annotation,
                        types.GenericAlias,
                        msg=(
                            f"{func_name}: parameter '{param_name}' uses a "
                            f"PEP 585 built-in generic alias ({annotation!r}). "
                            f"Replace with typing.List / typing.Optional etc. so "
                            f"the azure-functions-worker can index the function."
                        ),
                    )

    def test_function_app_module_imports_without_error(self):
        """function_app must be importable; the app object must exist."""
        self.assertIsNotNone(function_app.app)

    def test_all_expected_functions_are_registered(self):
        """All four processor functions must be registered on the FunctionApp."""
        pairs = _registered_builders()
        if pairs is None:
            self.skipTest("_function_builders not available in this SDK version")
        registered = {name for name, _ in pairs}
        self.assertEqual(
            registered,
            _EXPECTED_FUNCTIONS,
            f"Registered functions differ from expected.\n"
            f"  Expected : {sorted(_EXPECTED_FUNCTIONS)}\n"
            f"  Got      : {sorted(registered)}",
        )


if __name__ == "__main__":
    unittest.main()
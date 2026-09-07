"""Regression tests for function registration and worker-compatible annotations.

The Python 3.12 azure-functions-worker rejects types.GenericAlias (PEP 585
built-in list[X]) binding annotations with FunctionLoadError, which crashes
the worker process and prevents all functions from loading.  Use typing.List[X]
etc. to produce typing._GenericAlias instances, which the worker accepts.

FunctionApp.get_functions() calls validate_function_names(), which accumulates
function names into app.functions_bindings as a side effect.  Calling it a
second time in the same process raises ValueError.  setUpClass calls it once.
"""
import types
import typing
import unittest

import bootstrap  # noqa: F401

import function_app

_EXPECTED_FUNCTIONS = {
    "ProcessAIUsage",
    "MonitorEventHubCheckpoints",
    "AllocateFocusCost",
    "RecordClaudeCcuContext",
}


class TestFunctionApp(unittest.TestCase):
    """Registration and binding annotation tests for the usage Function App.

    If setUpClass raises (e.g. AttributeError from a missing public API),
    every test in this class fails rather than skipping registration coverage.
    """

    _functions: list = []

    @classmethod
    def setUpClass(cls):
        cls._functions = function_app.app.get_functions()

    def test_function_app_imports_without_error(self):
        """function_app must be importable and the FunctionApp object must exist."""
        self.assertIsNotNone(function_app.app)

    def test_all_expected_functions_are_registered(self):
        """All four processor functions must be registered on the FunctionApp."""
        registered = {f.get_function_name() for f in self._functions}
        self.assertEqual(
            registered,
            _EXPECTED_FUNCTIONS,
            "Registered functions differ from expected.\n"
            f"  Expected : {sorted(_EXPECTED_FUNCTIONS)}\n"
            f"  Got      : {sorted(registered)}",
        )

    def test_no_pep585_generic_alias_in_binding_parameters(self):
        """No binding parameter may use a PEP 585 types.GenericAlias annotation.

        The Python 3.12 azure-functions-worker rejects types.GenericAlias (e.g.
        list[X]) with FunctionLoadError and exits, so all functions appear
        unregistered even if only one parameter is affected.  Use typing.List
        etc. instead.
        """
        for func_obj in self._functions:
            with self.subTest(function=func_obj.get_function_name()):
                hints = typing.get_type_hints(func_obj.get_user_function())
                for param_name, annotation in hints.items():
                    with self.subTest(parameter=param_name):
                        self.assertNotIsInstance(
                            annotation,
                            types.GenericAlias,
                            f"{func_obj.get_function_name()}: parameter "
                            f"'{param_name}' uses a PEP 585 built-in generic "
                            f"alias ({annotation!r}).  Replace with typing.List "
                            f"/ typing.Optional etc. for Python 3.12 worker "
                            f"compatibility.",
                        )


if __name__ == "__main__":
    unittest.main()

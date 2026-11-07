extends RefCounted
## Minimal assertion base for headless tests run by tests/run_tests.gd.

var failures: Array[String] = []
## Substrings of engine errors this test deliberately provokes; the runner ignores them.
var expected_errors: Array[String] = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func expect_error(substring: String) -> void:
	expected_errors.append(substring)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		failures.append("%s: expected <%s>, got <%s>" % [message, expected, actual])

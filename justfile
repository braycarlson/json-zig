set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact for Linux and Windows')]
check:
    zig build check

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci

[doc('Run JSONTestSuite, json-patch-tests, and yyjson test/data: just conformance <suite> <patch> <yyjson>')]
conformance json_test_suite json_patch_tests yyjson_data:
    zig build conformance -- {{ json_test_suite }} {{ json_patch_tests }} {{ yyjson_data }}

[doc('Build and run every example')]
example:
    zig build example

[doc('Format every Zig source file and every Python file')]
fmt:
    zig fmt bench/build.zig bench/drivers/zig bindings/python/build.zig bindings/python/src build.zig examples src
    uvx ruff format bench bindings/python

[doc('Run a fuzzer: just fuzz <fuzzer> [seed]')]
fuzz *arguments:
    zig build fuzz -- {{ arguments }}

[doc('Lint every Zig and Python file with tigerstyle-lsp, and the Python files with ruff')]
lint:
    tigerstyle-lsp check bench build.zig examples src tools --format concise
    tigerstyle-lsp check --config bindings/python/tigerstyle.toml bindings/python/build.zig bindings/python/src bindings/python/tests --format concise
    uvx ruff check bench bindings/python
    uvx ruff format --check bench bindings/python

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just test-unit [filter]')]
test-unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

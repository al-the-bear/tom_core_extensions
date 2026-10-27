#!/usr/bin/env python3
"""Validates OpenAPI 3.1 documents against the official meta-schema.

Usage: validate_openapi.py <schemas-dir> <document.json> [<document.json> ...]

Prints one JSON object on stdout:
  {"documents": [{"path": ..., "errors": [{"at": ..., "message": ...}]}]}
and exits 0 when every document is valid, 1 when one is not, 2 when the
validation could not run (a missing module, an unreadable file).

The schema is the *schema-base* variant of the 2022-10-07 OpenAPI 3.1 schema,
which also validates every embedded schema object against the OpenAPI dialect
(JSON Schema 2020-12 plus the OpenAPI vocabulary). The four schema files are
vendored beside this script so validation needs no network.

It is Python because the reference JSON Schema 2020-12 implementation is: the
Dart `json_schema` package cannot load the OpenAPI schema (it fails on
`dependentSchemas`), and `jsonschema` is already part of every fleet host's
toolchain (the todo-guard suite depends on it).
"""
import json
import sys
from pathlib import Path


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        import jsonschema
        import referencing
        from referencing.jsonschema import DRAFT202012
    except ImportError as missing:
        print(json.dumps({"error": f"not measured: {missing}"}))
        return 2
    schemas_dir = Path(argv[1])
    try:
        resources = [json.loads(p.read_text()) for p in sorted(schemas_dir.glob("*.json"))]
    except (OSError, ValueError) as broken:
        print(json.dumps({"error": f"not measured: {broken}"}))
        return 2
    by_id = {r["$id"]: r for r in resources}
    root = by_id.get("https://spec.openapis.org/oas/3.1/schema-base/2022-10-07")
    if root is None:
        print(json.dumps({"error": "not measured: the schema-base meta-schema is missing"}))
        return 2
    registry = referencing.Registry().with_resources(
        [(i, DRAFT202012.create_resource(r)) for i, r in by_id.items()]
    )
    validator = jsonschema.Draft202012Validator(root, registry=registry)
    results = []
    invalid = False
    for name in argv[2:]:
        try:
            document = json.loads(Path(name).read_text())
        except (OSError, ValueError) as broken:
            print(json.dumps({"error": f"not measured: {name}: {broken}"}))
            return 2
        errors = [
            {"at": "/" + "/".join(str(p) for p in e.absolute_path), "message": e.message}
            for e in sorted(validator.iter_errors(document), key=lambda e: list(map(str, e.absolute_path)))
        ]
        invalid = invalid or bool(errors)
        results.append({"path": name, "errors": errors})
    print(json.dumps({"documents": results}))
    return 1 if invalid else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

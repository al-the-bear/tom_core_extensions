# Tom Core Agentic — Refactoring Plan

Project-specific workflow for refactoring, testing, documenting, and creating
examples for **tom_core_agentic**. The **reference target state** is
`tom_core_kernel` (clean code, full dartdoc, per-module documentation,
executable examples, comprehensive tests, generated `api.dart`). See
`tom_core_kernel/_copilot_guidelines/refactor_test_example_document_all.md`.

**Project type:** Dart library (`publish_to: none`)
**Source location:** `lib/src/`
**Description:** Generic building blocks for agentic systems — cooperative
cancellation, lifecycle close-guards, dedup-by-id, text previews, HTTP-date
parsing, typed YAML config reading, and the sha256 content-hash convention.
No domain dependencies beyond `tom_basics`.

---

## Target Modules

Located in `lib/src/` (keep in sync with the folder):

| Module | Description |
| ------ | ----------- |
| `isolate_streaming/` | Cooperative cancellation, request guards, close signals, backpressure tracking, exception registry for isolate streaming |
| `mcp_auth/` | Bearer-auth contract and MCP auth helpers |
| `placeholders/` | Placeholder resolver, expressions, stack, and error types |

Barrel: `lib/tom_core_agentic.dart`.

---

## Concrete Step List

Iterate in order. Each step states its **done** condition.

1. **Meta files.** Ensure `README.md` (summary + overview), `CHANGELOG.md`
   (short, pre-publish), and `LICENSE` exist at the project root. `LICENSE` is
   **missing** — create it using the BSD 3-Clause wording from a sibling project
   (e.g. `tom_core_kernel/LICENSE`). *Done when all three exist and the README
   describes the package accurately.*
2. **Per-module pass — `isolate_streaming/`.** Run the Per-Module Workflow below.
3. **Per-module pass — `mcp_auth/`.**
4. **Per-module pass — `placeholders/`.**
5. **Barrel exports & dead code.** Verify every public symbol is exported from
   `lib/tom_core_agentic.dart`; remove unused declarations. *Done when
   `dart analyze` is clean.*
6. **Whole-package QA.** Run `dart analyze` (zero warnings) and `testkit :test`
   (all green; baseline lives in `doc/`). *Done when analyzer and tests are
   clean.*
7. **Final review.** Re-read each module doc and `api.dart`; confirm docs only
   describe features that exist and cover all public API. Update `CHANGELOG.md`.

---

## Per-Module Workflow

For each module step, perform these sub-steps (do not change public behavior;
private additions allowed):

1. Read all files in the module; identify the public API surface.
2. Refactor and document per
   [`dart/coding_guidelines.md`](../../../../_copilot_guidelines/dart/coding_guidelines.md).
3. Quality check: no public API change; `dart analyze` clean.
4. Create module documentation in `doc/{module}.md` per
   [`documentation_guidelines.md`](../../../../_copilot_guidelines/documentation_guidelines.md).
5. Create **executable** examples per
   [`dart/examples.md`](../../../../_copilot_guidelines/dart/examples.md) under `example/`.
6. Create / extend tests per
   [`dart/unit_tests.md`](../../../../_copilot_guidelines/dart/unit_tests.md); cover
   cancellation, close-guards, and error paths.
7. Create / regenerate `api.dart` (or `doc/api/api_summary_{module}.md`) and
   verify it matches the code.
8. Verify documentation covers all public API and describes nothing that does
   not exist.

---

## Guidelines References

| Guideline | Location |
| --------- | -------- |
| Coding Guidelines | [`dart/coding_guidelines.md`](../../../../_copilot_guidelines/dart/coding_guidelines.md) |
| Clean Code | [`dart/clean_code_principles.md`](../../../../_copilot_guidelines/dart/clean_code_principles.md) |
| Documentation | [`documentation_guidelines.md`](../../../../_copilot_guidelines/documentation_guidelines.md) |
| Unit Tests | [`dart/unit_tests.md`](../../../../_copilot_guidelines/dart/unit_tests.md) |
| Examples | [`dart/examples.md`](../../../../_copilot_guidelines/dart/examples.md) |

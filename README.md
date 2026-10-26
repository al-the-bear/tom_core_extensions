# Tom Core Extensions

Non-essential services for Tom applications. `tom_core` holds what makes an
application a Tom application — the services every enterprise application
needs, provided in one consistent way. The packages here are services an
application may use or leave out, and each of them builds on `tom_core`.

## What belongs here

| Repository | Holds | Depends on |
| --- | --- | --- |
| `tom_basics` (`tom_ai/basics`) | Generic libraries usable in any Dart application, and the base libraries for a class of tools | other basics packages only |
| `tom_core` (`tom_ai/core`) | The essential services of a Tom application | basics |
| **`tom_core_extensions`** (`tom_ai/core_extension`) | **Optional services built on the core** | basics, core |
| `tom_modules` (`tom_ai/modules`) | Application-level libraries for Tom-internal reuse: models, model utilities, reusable UI components | basics, core, core extensions, other modules |

A package belongs here when an application can do without it and it needs
`tom_core` to work. A package that needs nothing from the workspace beyond
`tom_basics` belongs in `tom_basics`; a model or a UI component for Tom
applications belongs in `tom_modules`.

## Packages

None yet.

## License

BSD 3-Clause. See [LICENSE](LICENSE). A package that has to be released under
another licence — one that links GPL code, for example — lives in a repository
of its own.

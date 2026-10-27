// Shared placeholder system barrel.
//
// The single placeholder resolver for the whole brain stack: the scope
// stack, the typed failures, the `${{ … }}` expression seam, and the
// resolver itself. The d4rt-backed implementation of the expression seam
// lives in `tom_brain_procedure` (which owns the d4rt dependency).

export 'placeholder_errors.dart';
export 'placeholder_expressions.dart';
export 'placeholder_resolver.dart';
export 'placeholder_stack.dart';

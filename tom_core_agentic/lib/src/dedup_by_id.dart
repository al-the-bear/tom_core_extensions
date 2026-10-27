// Build an id-keyed map, rejecting duplicates.
//
// Registries across the framework share one need: take a list of
// items, key them by a stable id, and refuse to silently pick a winner
// when two items claim the same id. This is that operation, with one
// definition and a customisable error message.

/// Builds an unmodifiable `id → item` map from [items], using [idOf]
/// to extract each item's id.
///
/// Throws [ArgumentError] on the first duplicate id so the caller can
/// never silently pick a winner. [itemLabel] (e.g. `'role'`,
/// `'provider'`) is used in the default error message; [onDuplicate],
/// when supplied, builds a domain-specific message for the duplicate
/// id instead.
///
/// The returned map is wrapped in [Map.unmodifiable] so a holder of
/// the source list cannot mutate the registry's view by accident.
Map<String, T> buildUniqueById<T>(
  Iterable<T> items,
  String Function(T item) idOf, {
  String itemLabel = 'item',
  String Function(String id)? onDuplicate,
}) {
  final byId = <String, T>{};
  for (final item in items) {
    final id = idOf(item);
    if (byId.containsKey(id)) {
      throw ArgumentError.value(
        id,
        itemLabel,
        onDuplicate?.call(id) ?? 'duplicate $itemLabel id "$id"',
      );
    }
    byId[id] = item;
  }
  return Map<String, T>.unmodifiable(byId);
}

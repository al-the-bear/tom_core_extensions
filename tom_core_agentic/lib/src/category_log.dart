// Category-tagged logging facade.
//
// Components that group their log output under named categories repeat
// the same shape: an enum of category identifiers, a thin value type
// pairing a category with the nine `tomLog` levels, and a `_tag` helper
// that prepends `'[<category>] '` while preserving the lazy
// `() => Object` contract. That shape has shipped four times across the
// brain stack (engine, dispatcher, memory, substrate); the forwarding
// and tagging live here once so each component keeps only its own enum
// and category names.

import 'package:tom_basics/tom_basics.dart';

/// A category-tagged facade over the global [tomLog] instance.
///
/// Subclass it, expose [categoryName], and offer the component's category
/// constants as `const` statics:
///
/// ```dart
/// final class EngineLog extends CategoryLog {
///   const EngineLog._(this.category);
///   final EngineLogCategory category;
///   @override
///   String get categoryName => category.name;
///   static const EngineLog host = EngineLog._(EngineLogCategory.host);
/// }
/// ```
///
/// Each level method prepends `'[<categoryName>] '` to the message before
/// forwarding to the matching `tomLog` method. The prefix is attached
/// lazily for `() => Object` messages so the expensive-message contract
/// `tomLog` honours is preserved.
abstract base class CategoryLog {
  /// Const so subclasses can offer `const` category instances.
  const CategoryLog();

  /// The category identifier used as the log-line prefix (without the
  /// surrounding brackets), e.g. `'tom_brain.engine.host'`.
  String get categoryName;

  /// Most-verbose level. Use for entering / leaving inner methods.
  void trace(Object message) => tomLog.trace(_tagged(message));

  /// Detailed debugging information. Filtered out at production level.
  void debug(Object message) => tomLog.debug(_tagged(message));

  /// Network / data-flow logging.
  void traffic(Object message) => tomLog.traffic(_tagged(message));

  /// General runtime information.
  void info(Object message) => tomLog.info(_tagged(message));

  /// Potentially problematic situation that did not prevent operation.
  void warn(Object message) => tomLog.warn(_tagged(message));

  /// Important lifecycle event. Visible even under the `silent` filter.
  void status(Object message) => tomLog.status(_tagged(message));

  /// Error condition (recoverable). Use for failed-but-handled paths.
  void error(Object message) => tomLog.error(_tagged(message));

  /// Serious error that may require attention.
  void severe(Object message) => tomLog.severe(_tagged(message));

  /// Unrecoverable error. Use for paths that immediately precede an exit.
  void fatal(Object message) => tomLog.fatal(_tagged(message));

  Object _tagged(Object message) => tagMessage(categoryName, message);

  /// Prefixes [message] with `'[<category>] '`.
  ///
  /// When [message] is a zero-argument function (the lazy
  /// `() => Object` form `tomLog` supports), the returned value is a
  /// function that prepends the tag only when the message is finally
  /// evaluated — otherwise the tag is attached eagerly to the rendered
  /// message. Exposed as a static so the formatting can be unit-tested
  /// without driving the global logger.
  static Object tagMessage(String category, Object message) {
    if (message is Object Function()) {
      return () => '[$category] ${message()}';
    }
    return '[$category] $message';
  }
}

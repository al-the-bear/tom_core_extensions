// Global agent settings (the `Options` surface + bridge host/port).
//
// A single editor-configuration value (not a list): the bridge connection
// target and the global Agent SDK option defaults that overlay a profile when
// the profile leaves a field unset. Held in the spec workspace as a YAML file,
// out of the document `*.docspecs.yaml` pass.
library;

import 'agent_profile.dart';
import 'agent_yaml.dart';
import 'bridge_connection.dart';

/// Global agent settings: bridge target + the defaults a profile overlays.
///
/// `AgentSendConfig.fromProfile` applies the overlay for what a send carries:
/// for [maxRounds] and [toolApprovalMode], a field the active [AgentProfile]
/// sets wins, and otherwise the value here applies — and likewise for
/// [thinkingEnabled], sent as the SDK's thinking configuration.
/// [maxTokens] and [promptCachingEnabled] are stored and edited but not sent —
/// the Agent SDK's `Options` has no field for them — and are kept for the
/// providers that will take them. [defaultProfileId] names the profile
/// selected on launch.
final class AgentSettings {
  const AgentSettings({
    this.bridgeHost = defaultBridgeHost,
    this.portScanStart = bridgeScanMinPort,
    this.portScanEnd = bridgeScanMaxPort,
    this.defaultProfileId,
    this.maxTokens,
    this.maxRounds,
    this.thinkingEnabled,
    this.promptCachingEnabled,
    this.toolApprovalMode,
  });

  /// Host the bridge port-scan connects to.
  final String bridgeHost;

  /// First port of the bridge scan range (inclusive).
  final int portScanStart;

  /// Last port of the bridge scan range (inclusive).
  final int portScanEnd;

  /// Profile selected on launch; null = first available.
  final String? defaultProfileId;

  /// Global default for the response token cap. Not sent: the Agent SDK's
  /// `Options` has no token cap.
  final int? maxTokens;

  /// Global default for the agent's max tool rounds, sent as the turn cap
  /// when the profile sets none.
  final int? maxRounds;

  /// Global default for extended thinking, sent as the SDK's thinking
  /// configuration when the profile sets none (see `thinkingConfigFor`);
  /// `null` leaves the SDK default.
  final bool? thinkingEnabled;

  /// Global default for prompt caching. Not sent: the Agent SDK's `Options` has
  /// no caching flag.
  final bool? promptCachingEnabled;

  /// Global default tool-approval mode, sent as the SDK permission mode when
  /// the profile sets none (see `permissionModeForApproval`).
  final ToolApprovalMode? toolApprovalMode;

  factory AgentSettings.fromYaml(Map<String, dynamic> yaml) => AgentSettings(
    bridgeHost: yamlValue<String>(yaml, 'bridgeHost') ?? defaultBridgeHost,
    portScanStart: yamlValue<int>(yaml, 'portScanStart') ?? bridgeScanMinPort,
    portScanEnd: yamlValue<int>(yaml, 'portScanEnd') ?? bridgeScanMaxPort,
    defaultProfileId: yamlValue<String>(yaml, 'defaultProfileId'),
    maxTokens: yamlValue<int>(yaml, 'maxTokens'),
    maxRounds: yamlValue<int>(yaml, 'maxRounds'),
    thinkingEnabled: yamlValue<bool>(yaml, 'thinkingEnabled'),
    promptCachingEnabled: yamlValue<bool>(yaml, 'promptCachingEnabled'),
    toolApprovalMode: yamlEnum(
      yaml,
      'toolApprovalMode',
      ToolApprovalMode.fromValue,
    ),
  );

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'bridgeHost': bridgeHost,
    'portScanStart': portScanStart,
    'portScanEnd': portScanEnd,
    if (defaultProfileId != null) 'defaultProfileId': defaultProfileId,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxRounds != null) 'maxRounds': maxRounds,
    if (thinkingEnabled != null) 'thinkingEnabled': thinkingEnabled,
    if (promptCachingEnabled != null)
      'promptCachingEnabled': promptCachingEnabled,
    if (toolApprovalMode != null) 'toolApprovalMode': toolApprovalMode!.value,
  };

  AgentSettings copyWith({
    String? bridgeHost,
    int? portScanStart,
    int? portScanEnd,
    String? defaultProfileId,
    int? maxTokens,
    int? maxRounds,
    bool? thinkingEnabled,
    bool? promptCachingEnabled,
    ToolApprovalMode? toolApprovalMode,
  }) => AgentSettings(
    bridgeHost: bridgeHost ?? this.bridgeHost,
    portScanStart: portScanStart ?? this.portScanStart,
    portScanEnd: portScanEnd ?? this.portScanEnd,
    defaultProfileId: defaultProfileId ?? this.defaultProfileId,
    maxTokens: maxTokens ?? this.maxTokens,
    maxRounds: maxRounds ?? this.maxRounds,
    thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
    promptCachingEnabled: promptCachingEnabled ?? this.promptCachingEnabled,
    toolApprovalMode: toolApprovalMode ?? this.toolApprovalMode,
  );

  /// Whether the port-scan range is well-formed (start ≤ end, both positive).
  bool get hasValidPortRange =>
      portScanStart > 0 && portScanEnd > 0 && portScanStart <= portScanEnd;
}

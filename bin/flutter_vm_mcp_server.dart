import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _findExtension = 'ext.flutter_vm_mcp.find';
const _inspectorRootExtension = 'ext.flutter.inspector.getRootWidget';
const _inspectorChildrenExtension =
    'ext.flutter.inspector.getChildrenSummaryTree';
const _objectGroup = 'flutter_vm_mcp';

void main(List<String> args) {
  String? initialUri;
  for (final arg in args) {
    if (arg.startsWith('--vm-service-uri=')) {
      initialUri = arg.substring('--vm-service-uri='.length);
    }
  }
  FlutterVmMcpServer(
    stdioChannel(input: io.stdin, output: io.stdout),
    initialUri: initialUri,
  );
}

base class FlutterVmMcpServer extends MCPServer with ToolsSupport {
  VmService? _vmService;

  FlutterVmMcpServer(super.channel, {String? initialUri})
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'flutter_vm_mcp',
          version: '0.1.0',
        ),
        instructions:
            'Inspects a running Flutter app (debug/profile) over the Dart '
            'VM Service. Start with flutter_connect (the URI printed by '
            '`flutter run` or `--print-dtd`), then use flutter_find to get '
            'the real on-screen rect of a widget so you can click it '
            'accurately, or flutter_tree to explore the widget tree.',
      ) {
    registerTool(connectTool, _connect);
    registerTool(findTool, _find);
    registerTool(treeTool, _tree);
    if (initialUri != null) {
      unawaited(_connectTo(initialUri));
    }
  }

  final connectTool = Tool(
    name: 'flutter_connect',
    description:
        'Connects to the Dart VM Service of a running Flutter app. Use the '
        'ws://... URI printed by `flutter run` (or '
        '`flutter run -d web-server --print-dtd`) on startup.',
    inputSchema: Schema.object(
      properties: {
        'vmServiceUri': Schema.string(
          description: 'e.g. ws://127.0.0.1:PORT/TOKEN=/ws',
        ),
      },
      required: ['vmServiceUri'],
    ),
  );

  final findTool = Tool(
    name: 'flutter_find',
    description:
        'Finds a widget in the connected app by visible text, type, or key, '
        'and returns its real on-screen rect in page pixels (x, y, width, '
        'height), ready to click. Requires the app to have imported '
        'flutter_vm_mcp and called registerFlutterVmMcpExtension() in '
        'main().',
    inputSchema: Schema.object(
      properties: {
        'text': Schema.string(description: 'Exact visible text to search for'),
        'textContains': Schema.string(
          description:
              'Case-insensitive substring of the visible text. Prefer this '
              'over `text` when the label might be styled (e.g. rendered '
              'in all caps) or split across spans.',
        ),
        'type': Schema.string(
          description:
              "Widget type name, e.g. 'ElevatedButton'. Try this if neither "
              '`text` nor `textContains` match a widget you can clearly '
              'see on screen — the app likely renders that label through a '
              "custom design-system widget rather than a raw Text.",
        ),
        'key': Schema.string(description: "Substring of the widget's Key"),
        'maxResults': Schema.int(description: 'Defaults to 5'),
      },
    ),
  );

  final treeTool = Tool(
    name: 'flutter_tree',
    description:
        "Dumps the connected app's widget tree (type, text, "
        'creationLocation), using the standard Flutter widget inspector '
        'service extensions.',
    inputSchema: Schema.object(
      properties: {'maxDepth': Schema.int(description: 'Defaults to 4')},
    ),
  );

  Future<CallToolResult> _connect(CallToolRequest request) async {
    final uri = request.arguments!['vmServiceUri'] as String;
    try {
      await _connectTo(uri);
      return CallToolResult(content: [TextContent(text: 'Connected to $uri')]);
    } catch (e) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: 'Could not connect to $uri: $e')],
      );
    }
  }

  Future<void> _connectTo(String uri) async {
    await _vmService?.dispose();
    _vmService = await vmServiceConnectUri(uri);
  }

  Future<CallToolResult> _find(CallToolRequest request) async {
    final vmService = _vmService;
    if (vmService == null) {
      return _notConnected();
    }

    final args = request.arguments ?? const {};
    try {
      final isolateId = await _findIsolateWith(vmService, _findExtension);
      final response = await vmService.callServiceExtension(
        _findExtension,
        isolateId: isolateId,
        args: {
          if (args['text'] case final text?) 'text': text,
          if (args['textContains'] case final t?) 'textContains': t,
          if (args['type'] case final type?) 'type': type,
          if (args['key'] case final key?) 'key': key,
          if (args['maxResults'] case final n?) 'maxResults': '$n',
        },
      );
      return CallToolResult(
        content: [TextContent(text: jsonEncode(response.json))],
      );
    } catch (e) {
      return CallToolResult(isError: true, content: [TextContent(text: '$e')]);
    }
  }

  Future<CallToolResult> _tree(CallToolRequest request) async {
    final vmService = _vmService;
    if (vmService == null) {
      return _notConnected();
    }

    final maxDepth = (request.arguments?['maxDepth'] as int?) ?? 4;
    try {
      final isolateId = await _findIsolateWith(
        vmService,
        _inspectorRootExtension,
      );
      final rootResponse = await vmService.callServiceExtension(
        _inspectorRootExtension,
        isolateId: isolateId,
        args: {'objectGroup': _objectGroup},
      );
      final root =
          (rootResponse.json?['result'] ?? rootResponse.json)
              as Map<String, dynamic>?;
      if (root == null) {
        return CallToolResult(
          isError: true,
          content: [
            TextContent(text: 'Empty response from $_inspectorRootExtension'),
          ],
        );
      }
      final tree = await _expand(vmService, isolateId, root, maxDepth, 0);
      return CallToolResult(content: [TextContent(text: jsonEncode(tree))]);
    } catch (e) {
      return CallToolResult(isError: true, content: [TextContent(text: '$e')]);
    }
  }

  /// Recursively fills in children via [_inspectorChildrenExtension], since
  /// `getRootWidget` alone doesn't nest the full tree in every Flutter
  /// version.
  Future<Map<String, Object?>> _expand(
    VmService vmService,
    String isolateId,
    Map<String, dynamic> node,
    int maxDepth,
    int depth,
  ) async {
    final result = <String, Object?>{
      'description': node['description'],
      'type': node['type'],
      'creationLocation': node['creationLocation'],
    };

    final valueId = node['valueId'] as String?;
    if (depth >= maxDepth || valueId == null) {
      return result;
    }

    final childrenResponse = await vmService.callServiceExtension(
      _inspectorChildrenExtension,
      isolateId: isolateId,
      args: {'arg': valueId, 'objectGroup': _objectGroup},
    );
    final children =
        (childrenResponse.json?['result'] ?? childrenResponse.json)
            as List<dynamic>?;
    if (children == null || children.isEmpty) {
      return result;
    }

    result['children'] = await Future.wait(
      children.cast<Map<String, dynamic>>().map(
        (child) => _expand(vmService, isolateId, child, maxDepth, depth + 1),
      ),
    );
    return result;
  }

  Future<String> _findIsolateWith(
    VmService vmService,
    String extensionName,
  ) async {
    final vm = await vmService.getVM();
    for (final isolateRef in vm.isolates ?? const <IsolateRef>[]) {
      final id = isolateRef.id;
      if (id == null) continue;
      final isolate = await vmService.getIsolate(id);
      if (isolate.extensionRPCs?.contains(extensionName) ?? false) {
        return id;
      }
    }
    throw StateError(
      'No isolate exposes $extensionName yet. If this is '
      '$_findExtension: check that the app imports flutter_vm_mcp and '
      'calls registerFlutterVmMcpExtension() in main(). If this is a '
      'standard Flutter extension: check that the app is still running in '
      'debug/profile mode.',
    );
  }

  CallToolResult _notConnected() => CallToolResult(
    isError: true,
    content: [
      TextContent(
        text:
            'No active connection. Call flutter_connect first with the '
            'VM Service URI.',
      ),
    ],
  );
}

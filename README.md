# flutter_vm_mcp

An MCP server that inspects a running Flutter app (debug/profile) over the
**Dart VM Service**, so an AI coding agent (Claude Code, etc.) can find the
real on-screen geometry of a widget — instead of guessing coordinates from a
screenshot.

## The problem this solves

Automating a Flutter Web app (CanvasKit renderer) with a browser-control
harness (e.g. `claude-in-chrome`) is painful because:

- Flutter paints everything into a single `<canvas>`; there's no real DOM
  underneath, so `document.elementFromPoint()` and accessibility-tree-based
  tools don't see anything useful.
- The image size returned by a screenshot doesn't always match the real CSS
  viewport 1:1, so coordinates eyeballed from that screenshot often miss.

Flutter in debug mode exposes the VM Service, with the widget inspector's
service extensions (`ext.flutter.inspector.*`) — the same mechanism
`flutter_driver`, `integration_test`, and DevTools already use. This package
adds the missing piece: **a custom extension that turns "I found widget X"
into a real rect in page pixels**, plus an MCP server exposing it as tools.

See [`dart-lang/ai#356`](https://github.com/dart-lang/ai/issues/356) for the
context on the gap in the official `dart mcp-server` with Flutter Web + a
browser that isn't the one Flutter launches on its own.

## How it works

1. **In the app** (`lib/flutter_vm_mcp.dart`): `registerFlutterVmMcpExtension()`
   registers `ext.flutter_vm_mcp.find`, which walks the live `Element` tree
   and returns the rect (`RenderBox.localToGlobal` + `size`) of widgets
   matching by text, type, or key.
2. **The MCP server** (`bin/flutter_vm_mcp_server.dart`) connects to the VM
   Service over WebSocket and exposes three tools:
   - `flutter_connect(vmServiceUri)`
   - `flutter_find(text?, type?, key?, maxResults?)` → real rects
   - `flutter_tree(maxDepth?)` → widget tree via the inspector's standard
     extensions (no custom code needed)

## Usage

### 1. In your Flutter app

```yaml
# pubspec.yaml
dev_dependencies:
  flutter_vm_mcp: ^0.1.0
```

```dart
import 'package:flutter_vm_mcp/flutter_vm_mcp.dart';

void main() {
  registerFlutterVmMcpExtension(); // before runApp; no-op in release
  runApp(const MyApp());
}
```

### 2. Run the app served on your own Chrome

```bash
flutter run -d web-server --print-dtd
```

Copy the `ws://127.0.0.1:PORT/TOKEN=/ws` URI printed to the console (the VM
Service one, not necessarily the DTD one). You don't need the "Dart Debug
Chrome" extension — that's only for hot-reload convenience, it doesn't gate
the VM Service connection itself.

### 3. Configure the MCP server

```json
{
  "mcpServers": {
    "flutter_vm_mcp": {
      "command": "dart",
      "args": ["run", "bin/flutter_vm_mcp_server.dart"]
    }
  }
}
```

Or pass the startup URI directly:
`dart run bin/flutter_vm_mcp_server.dart --vm-service-uri=ws://127.0.0.1:PORT/TOKEN=/ws`.

Use it alongside `claude-in-chrome`: `flutter_find` gives you the real rect,
and the actual click still goes through `claude-in-chrome`'s `computer` tool
at that coordinate.

## Status

Initial MVP. `flutter_find` and the geometry extension are original, direct
code (no dependency on Flutter's internal wire format). `flutter_tree` uses
the inspector's standard extensions (`getRootWidget` +
`getChildrenSummaryTree`) — the parameter names (`arg`, `objectGroup`)
follow the usual `WidgetInspectorService` convention, but haven't been
smoke-tested end to end against a real app yet; if `flutter_tree` comes back
empty, check with a raw JSON-RPC call first before assuming the bug is
elsewhere.

## License

MIT — see [LICENSE](LICENSE).

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
   - `flutter_find(text?, textContains?, type?, key?, maxResults?)` → real
     rects
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

Smoke-tested against a real Flutter Web app (Onda-app): `flutter_find` and
`flutter_tree` both worked out of the box, no code changes needed —
including confirming `arg`/`objectGroup` as the right parameter names for
`getChildrenSummaryTree`.

### Tips

- If `text`/`textContains` don't match a widget you can clearly see on
  screen, the app most likely renders that label through a custom
  design-system widget rather than a raw `Text`/`EditableText`. Fall back to
  `type` with the concrete widget class name (e.g. `ElevatedButton`) — use
  `flutter_tree` to find it if you're not sure what it's called.
- `flutter_find`'s rect is in real CSS page pixels. `claude-in-chrome`'s
  `computer` tool clicks in the pixel space of its (possibly downscaled)
  screenshot instead — its result reports that screenshot's own width and
  height (e.g. `"1568x777"`), which is deterministic per call, not a
  per-session constant to calibrate by hand. Before clicking a
  `flutter_find` rect with it:
  1. Read `window.innerWidth`/`innerHeight` (e.g. via
     `claude-in-chrome`'s `javascript_tool`).
  2. `scale = screenshotWidth / innerWidth` (same ratio for both axes).
  3. Click at `(rect.x * scale, rect.y * scale)`.

## License

MIT — see [LICENSE](LICENSE).

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const _extensionName = 'ext.flutter_vm_mcp.find';

bool _registered = false;

/// Registers the `ext.flutter_vm_mcp.find` VM Service extension so an
/// external MCP server can ask "where is the widget matching this query on
/// screen right now", in real page pixels, instead of a coordinate guessed
/// from a screenshot.
///
/// Call this once, as early as possible in `main()`, before `runApp`. It is a
/// no-op in release builds, where VM Service extensions aren't available.
void registerFlutterVmMcpExtension() {
  if (_registered || kReleaseMode) return;
  _registered = true;

  developer.registerExtension(_extensionName, (
    String method,
    Map<String, String> parameters,
  ) async {
    final text = parameters['text'];
    final textContains = parameters['textContains'];
    final type = parameters['type'];
    final key = parameters['key'];
    final maxResults = int.tryParse(parameters['maxResults'] ?? '') ?? 5;

    if (text == null && textContains == null && type == null && key == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        'Pass at least one of: text, textContains, type, key.',
      );
    }

    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        'No root element yet — has runApp() been called?',
      );
    }

    final matches = <Map<String, Object?>>[];

    void visit(Element element) {
      if (matches.length >= maxResults) return;

      if (_matches(
        element,
        text: text,
        textContains: textContains,
        type: type,
        key: key,
      )) {
        final rect = _globalRect(element);
        if (rect != null) {
          matches.add({
            'widgetType': element.widget.runtimeType.toString(),
            'key': element.widget.key?.toString(),
            'text': _textOf(element.widget),
            'rect': {
              'x': rect.left,
              'y': rect.top,
              'width': rect.width,
              'height': rect.height,
            },
          });
        }
      }

      element.visitChildElements(visit);
    }

    visit(rootElement);

    return developer.ServiceExtensionResponse.result(
      jsonEncode({'matches': matches}),
    );
  });
}

bool _matches(
  Element element, {
  String? text,
  String? textContains,
  String? type,
  String? key,
}) {
  if (type != null && element.widget.runtimeType.toString() != type) {
    return false;
  }
  if (key != null) {
    final widgetKey = element.widget.key;
    if (widgetKey == null || !widgetKey.toString().contains(key)) {
      return false;
    }
  }
  if (text != null && _textOf(element.widget) != text) {
    return false;
  }
  if (textContains != null) {
    final widgetText = _textOf(element.widget)?.toLowerCase();
    if (widgetText == null ||
        !widgetText.contains(textContains.toLowerCase())) {
      return false;
    }
  }
  return true;
}

/// Best-effort visible text of a widget, for matching and for reporting back
/// what was found. Covers the common cases (`Text`, `EditableText`); widgets
/// that render text some other way just won't match on `text`.
String? _textOf(Widget widget) {
  if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
  if (widget is EditableText) return widget.controller.text;
  return null;
}

/// The widget's on-screen rect in logical (CSS) pixels, in the coordinate
/// space of the root view — the same space browser page coordinates use for
/// Flutter web, regardless of devicePixelRatio.
Rect? _globalRect(Element element) {
  final renderObject = element.renderObject;
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  final topLeft = renderObject.localToGlobal(Offset.zero);
  return topLeft & renderObject.size;
}

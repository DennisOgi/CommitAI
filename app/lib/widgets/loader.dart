import 'package:flutter/material.dart';

import '../data/backend.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Loads data from the backend, re-loads when the app's data version or mode
/// changes, and supports pull-to-refresh via the reload callback.
class Loader<T> extends StatefulWidget {
  const Loader({super.key, required this.load, required this.builder, this.empty});
  final Future<T> Function(Backend backend) load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  final Widget? empty;

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  Future<T>? _future;
  int _version = -1;
  Object? _mode;

  Future<void> _reload() async {
    final f = widget.load(AppScope.read(context).backend!);
    setState(() {
      _future = f;
    });
    try {
      await f;
    } catch (_) {
      // Shown by the FutureBuilder.
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (_future == null || app.dataVersion != _version || app.mode != _mode) {
      _version = app.dataVersion;
      _mode = app.mode;
      _future = widget.load(app.backend!);
    }
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Couldn’t load this',
              body: '${snap.error}',
              action: OutlinedButton(onPressed: _reload, child: const Text('Try again')),
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        return widget.builder(context, snap.data as T, _reload);
      },
    );
  }
}

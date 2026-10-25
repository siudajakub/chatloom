// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/network_login/network_login_api.dart';
import 'package:flutter/foundation.dart';

/// Where a sign-in stands.
enum NetworkLoginPhase {
  /// Loading the bridge's sign-in options.
  loadingFlows,

  /// Choosing how to sign in.
  flows,

  /// Waiting for the first step.
  starting,

  /// Showing [NetworkLoginSession.step]; [NetworkLoginSession.busy] while a
  /// submit or a long poll is running.
  step,

  /// The bridge asked for something ChatLoom can't do (passkey, client-side
  /// HTTP); the bridge chat is the way forward.
  unsupported,

  /// Signed in.
  complete,

  /// A request failed; [NetworkLoginSession.error] says why.
  failed,

  /// The user stopped the sign-in.
  cancelled,
}

/// Called after a sign-in completes (refresh whoami and network health).
typedef NetworkLoginCompleted =
    Future<String?> Function(BridgeEndpoint bridge, String? loginId);

/// One sign-in to one bridge, as a state machine the wizard renders.
///
/// Results of requests that were overtaken (the user cancelled, went back or
/// started again) are dropped by generation. Long polls of
/// `display_and_wait` steps are repeated while the step is shown; transient
/// failures (no answer, proxy timeout) are retried [maxWaitRetries] times in
/// a row before the sign-in fails.
class NetworkLoginSession extends ChangeNotifier {
  NetworkLoginSession({
    required this.api,
    required this.bridge,
    this.onComplete,
    this.relogin,
    this.maxWaitRetries = 4,
    this.retryDelay = const Duration(seconds: 2),
  });

  final NetworkLoginApi api;
  final BridgeEndpoint bridge;
  final NetworkLoginCompleted? onComplete;

  /// An existing login to re-authenticate (`login_id` on start).
  final String? relogin;
  final int maxWaitRetries;
  final Duration retryDelay;

  NetworkLoginPhase _phase = NetworkLoginPhase.loadingFlows;
  List<NetworkLoginFlow> _flows = const [];
  NetworkLoginFlow? _flow;
  NetworkLoginStep? _step;
  NetworkLoginException? _error;
  String? _processId;
  String? _loginId;
  String? _accountName;
  bool _busy = false;
  bool _disposed = false;
  int _generation = 0;

  NetworkLoginPhase get phase => _phase;
  List<NetworkLoginFlow> get flows => _flows;
  NetworkLoginFlow? get flow => _flow;
  NetworkLoginStep? get step => _step;
  NetworkLoginException? get error => _error;
  bool get busy => _busy;

  /// The remote login the bridge created ([NetworkLoginPhase.complete]).
  String? get loginId => _loginId;

  /// The account name whoami reported after completion, if any.
  String? get accountName => _accountName;

  /// Whether a process is open on the bridge (cancel must tell it).
  bool get running => _processId != null;

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// Loads the sign-in options; [known] (from whoami's `login_flows`) skips
  /// the request. One option starts at once.
  Future<void> loadFlows({List<NetworkLoginFlow>? known}) async {
    final generation = ++_generation;
    _set(() {
      _phase = NetworkLoginPhase.loadingFlows;
      _error = null;
    });
    try {
      final flows = known != null && known.isNotEmpty
          ? known
          : await api.flows(bridge);
      if (generation != _generation) return;
      if (flows.isEmpty) {
        _fail(
          const NetworkLoginException(NetworkLoginErrorKind.unsupported),
          generation,
        );
        return;
      }
      _set(() {
        _flows = flows;
        _phase = NetworkLoginPhase.flows;
      });
      if (flows.length == 1) await start(flows.single);
    } on NetworkLoginException catch (error) {
      _fail(error, generation);
    }
  }

  /// Starts signing in with [flow].
  Future<void> start(NetworkLoginFlow flow) async {
    final generation = ++_generation;
    _set(() {
      _flow = flow;
      _phase = NetworkLoginPhase.starting;
      _step = null;
      _error = null;
      _busy = true;
    });
    try {
      final progress = await api.start(bridge, flow.id, relogin: relogin);
      if (generation != _generation) {
        // Overtaken (cancelled while starting): close what was opened.
        unawaited(_cancelRemote(progress.processId));
        return;
      }
      _processId = progress.processId;
      await _apply(progress, generation);
    } on NetworkLoginException catch (error) {
      _fail(error, generation);
    }
  }

  /// Sends the current `user_input` or `cookies` step's values. The caller
  /// clears its fields afterwards; nothing here keeps them. A network that
  /// wants a value again answers with a new step; an error ends the process.
  Future<void> submit(Map<String, String> values) async {
    final step = _step;
    final process = _processId;
    if (step == null || process == null || _busy) return;
    final generation = ++_generation;
    _set(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = switch (step.type) {
        NetworkLoginStepType.userInput => await api.submitInput(
          bridge,
          process,
          step,
          values,
        ),
        NetworkLoginStepType.cookies => await api.submitCookies(
          bridge,
          process,
          step,
          values,
        ),
        _ => null,
      };
      if (progress == null || generation != _generation) return;
      await _apply(progress, generation);
    } on NetworkLoginException catch (error) {
      // bridgev2 deletes the process on any step error (`executeStep` →
      // `deleteLogin`), even a wrong code: the sign-in starts over.
      _fail(error, generation);
    }
  }

  /// Goes back from a step that allows it; otherwise stops this sign-in and
  /// returns to the options (or reports cancelled when there is only one).
  Future<void> back() async {
    final step = _step;
    final process = _processId;
    if (step != null && process != null && step.canCancel) {
      final generation = ++_generation;
      _set(() {
        _busy = true;
        _error = null;
      });
      try {
        final progress = await api.cancelStep(bridge, process, step);
        if (generation != _generation) return;
        await _apply(progress, generation);
      } on NetworkLoginException catch (error) {
        _fail(error, generation);
      }
      return;
    }
    if (_flows.length < 2) return cancel();
    final stopped = _stop();
    _set(() {
      _phase = NetworkLoginPhase.flows;
      _step = null;
      _busy = false;
      _error = null;
    });
    await stopped;
  }

  /// Stops the sign-in: in-flight answers are dropped and the bridge is told.
  Future<void> cancel() async {
    final stopped = _stop();
    if (_phase != NetworkLoginPhase.complete) {
      _set(() {
        _phase = NetworkLoginPhase.cancelled;
        _busy = false;
        _step = null;
      });
    }
    await stopped;
  }

  /// Drops in-flight answers and closes the bridge's process, if any.
  Future<void> _stop() async {
    ++_generation;
    final process = _processId;
    _processId = null;
    if (process != null) await _cancelRemote(process);
  }

  /// After a failure: start the same option again (a fresh process), or
  /// reload the options when none was chosen.
  Future<void> retry() async {
    final process = _processId;
    _processId = null;
    if (process != null) unawaited(_cancelRemote(process));
    final flow = _flow;
    if (flow != null) {
      await start(flow);
    } else {
      await loadFlows();
    }
  }

  Future<void> _cancelRemote(String process) async {
    try {
      await api.cancel(bridge, process);
    } catch (error) {
      // Already gone (expired, finished) is fine; log the type only.
      logBackgroundError('network_login_cancel', error);
    }
  }

  void _fail(NetworkLoginException error, int generation) {
    if (generation != _generation) return;
    logBackgroundError('network_login', error.cause ?? error);
    final process = _processId;
    _processId = null;
    // A failed process is over on the bridge, except after a transient
    // error: then it may still run, so tell it to stop.
    if (process != null && error.kind == NetworkLoginErrorKind.unreachable) {
      unawaited(_cancelRemote(process));
    }
    _set(() {
      _phase = NetworkLoginPhase.failed;
      _busy = false;
      _error = error;
    });
  }

  Future<void> _apply(NetworkLoginProgress progress, int generation) async {
    if (generation != _generation) return;
    _processId = progress.processId;
    final step = progress.step;
    switch (step.type) {
      case NetworkLoginStepType.complete:
        _processId = null;
        _set(() {
          _step = step;
          _loginId = step.userLoginId;
          _phase = NetworkLoginPhase.complete;
          _busy = false;
        });
        final done = onComplete;
        if (done != null) {
          try {
            final name = await done(bridge, step.userLoginId);
            if (name != null && name.isNotEmpty) {
              _set(() => _accountName = name);
            }
          } catch (error) {
            logBackgroundError('network_login_refresh', error);
          }
        }
      case NetworkLoginStepType.unsupported:
        final process = _processId;
        _processId = null;
        _set(() {
          _step = step;
          _phase = NetworkLoginPhase.unsupported;
          _busy = false;
        });
        if (process != null) unawaited(_cancelRemote(process));
      case NetworkLoginStepType.displayAndWait:
        _set(() {
          _step = step;
          _phase = NetworkLoginPhase.step;
          _busy = true;
        });
        await _waitLoop(generation);
      case NetworkLoginStepType.userInput:
      case NetworkLoginStepType.cookies:
        _set(() {
          _step = step;
          _phase = NetworkLoginPhase.step;
          _busy = false;
        });
    }
  }

  /// Long-polls the shown `display_and_wait` step until the bridge moves on.
  Future<void> _waitLoop(int generation) async {
    var failures = 0;
    while (generation == _generation && !_disposed) {
      final step = _step;
      final process = _processId;
      if (step == null ||
          process == null ||
          step.type != NetworkLoginStepType.displayAndWait) {
        return;
      }
      try {
        final progress = await api.wait(bridge, process, step);
        if (generation != _generation) return;
        failures = 0;
        if (progress.step.type == NetworkLoginStepType.displayAndWait) {
          // A refreshed QR or code: show it and keep waiting.
          _processId = progress.processId;
          _set(() => _step = progress.step);
          continue;
        }
        await _apply(progress, generation);
        return;
      } on NetworkLoginException catch (error) {
        if (generation != _generation) return;
        if (error.kind == NetworkLoginErrorKind.unreachable &&
            ++failures <= maxWaitRetries) {
          // The proxy or the network dropped the long poll; the bridge keeps
          // the step, and asking again joins it.
          if (retryDelay > Duration.zero) await Future.delayed(retryDelay);
          continue;
        }
        _fail(error, generation);
        return;
      }
    }
  }

  @override
  void dispose() {
    final process = _processId;
    _processId = null;
    ++_generation;
    if (process != null) unawaited(_cancelRemote(process));
    _disposed = true;
    super.dispose();
  }
}

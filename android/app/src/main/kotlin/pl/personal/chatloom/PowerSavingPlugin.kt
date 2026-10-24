// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reports Android Battery Saver to Dart (`lib/utils/power_saving.dart`, BP-08):
 * `isPowerSaving` answers the current state and `powerSaving` is sent on every
 * change. The receiver lives exactly as long as the engine.
 */
class PowerSavingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val appContext = binding.applicationContext
        context = appContext
        val methods = MethodChannel(binding.binaryMessenger, CHANNEL)
        methods.setMethodCallHandler(this)
        channel = methods
        val changes = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                channel?.invokeMethod("powerSaving", isPowerSaving())
            }
        }
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        try {
            // A protected system broadcast: delivered to a non-exported receiver.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(changes, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                appContext.registerReceiver(changes, filter)
            }
            receiver = changes
        } catch (_: Exception) {
            // Without updates Dart still reads the state at start.
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        receiver?.let { registered ->
            try {
                context?.unregisterReceiver(registered)
            } catch (_: Exception) {
            }
        }
        receiver = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isPowerSaving" -> result.success(isPowerSaving())
            else -> result.notImplemented()
        }
    }

    private fun isPowerSaving(): Boolean {
        val power = context?.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isPowerSaveMode == true
    }

    companion object {
        const val CHANNEL = "pl.personal.chat/power"
    }
}

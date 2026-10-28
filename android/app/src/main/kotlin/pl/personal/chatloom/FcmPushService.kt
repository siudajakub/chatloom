package pl.personal.chatloom

import com.famedly.fcm_shared_isolate.FcmSharedIsolatePlugin
import com.famedly.fcm_shared_isolate.FcmSharedIsolateService

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import android.content.Context
import android.os.Handler
import android.os.Looper

class FcmPushService : FcmSharedIsolateService() {
    override fun getEngine(): FlutterEngine {
        return provideEngine(getApplicationContext())
    }

    /**
     * FCM deleted pushes queued for this phone (more than 100 pending, or
     * offline for too long) without delivering them. The plugin does not pass
     * this callback on, so a content-free wake ({"personal_wake": "resync"})
     * goes the same way as a received push: the Dart side runs one catch-up
     * sync that alerts for the unread backlog (BackgroundPush._resync).
     */
    override fun onDeletedMessages() {
        Handler(Looper.getMainLooper()).post {
            val registry = getEngine().getPlugins()
            var plugin = registry.get(FcmSharedIsolatePlugin::class.java)
                as? FcmSharedIsolatePlugin
            if (plugin == null) {
                plugin = FcmSharedIsolatePlugin()
                registry.add(plugin)
            }
            plugin.message(mapOf(WAKE_KEY to RESYNC_WAKE))
        }
    }

    companion object {
        /** Same key and value as `pushKindOf` in push_diagnostics.dart. */
        private const val WAKE_KEY = "personal_wake"
        private const val RESYNC_WAKE = "resync"

        fun provideEngine(context: Context): FlutterEngine {
            var engine = MainActivity.engine
            if (engine == null) {
                engine = MainActivity.provideEngine(context)
                engine.getLocalizationPlugin().sendLocalesToFlutter(
                    context.getResources().getConfiguration())
                engine.getDartExecutor().executeDartEntrypoint(
                    DartEntrypoint.createDefault())
            }
            return engine
        }
    }
}

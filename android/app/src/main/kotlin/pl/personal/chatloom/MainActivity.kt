package pl.personal.chatloom

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

import android.content.Context
import pl.personal.chatloom.media.MediaStorePlugin
import pl.personal.chatloom.round.TelegramRoundPlugin

class MainActivity : FlutterFragmentActivity() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // do nothing, because the engine was been configured in provideEngine
    }

    companion object {
        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false)
            if (!eng.plugins.has(TelegramRoundPlugin::class.java)) {
                eng.plugins.add(TelegramRoundPlugin())
            }
            // battery-lifecycle (BP-08): Battery Saver -> lite mode.
            if (!eng.plugins.has(PowerSavingPlugin::class.java)) {
                eng.plugins.add(PowerSavingPlugin())
            }
            if (!eng.plugins.has(MediaStorePlugin::class.java)) {
                eng.plugins.add(MediaStorePlugin())
            }
            engine = eng
            return eng
        }
    }
}

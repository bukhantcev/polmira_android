package ru.polmira.listener;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.util.Log;

public class ConfigReceiver extends BroadcastReceiver {
    private static final String TAG = "PolmiraListener";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !"ru.polmira.listener.CONFIGURE".equals(intent.getAction())) {
            return;
        }

        SharedPreferences.Editor editor = SettingsStore.prefs(context).edit();
        putIfPresent(editor, SettingsStore.KEY_WEBHOOK_URL, intent.getStringExtra("webhook_url"));
        putIfPresent(editor, SettingsStore.KEY_SECRET, intent.getStringExtra("secret"));
        putIfPresent(editor, SettingsStore.KEY_PHONE, intent.getStringExtra("phone"));
        putIfPresent(editor, SettingsStore.KEY_TARGET_PACKAGE, intent.getStringExtra("target_package"));
        editor.apply();

        Log.d(TAG, "Configured from adb broadcast");
    }

    private static void putIfPresent(SharedPreferences.Editor editor, String key, String value) {
        if (value != null && !value.trim().isEmpty()) {
            editor.putString(key, value.trim());
        }
    }
}

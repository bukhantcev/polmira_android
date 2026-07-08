package ru.polmira.listener;

import android.content.Context;
import android.content.SharedPreferences;

final class SettingsStore {
    static final String PREFS = "polmira_listener";
    static final String KEY_WEBHOOK_URL = "webhook_url";
    static final String KEY_SECRET = "secret";
    static final String KEY_PHONE = "phone";
    static final String KEY_TARGET_PACKAGE = "target_package";
    static final String KEY_LAST_EVENT = "last_event";

    private SettingsStore() {
    }

    static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static String get(SharedPreferences prefs, String key, String fallback) {
        String value = prefs.getString(key, fallback);
        if (value == null || value.trim().isEmpty()) {
            return fallback;
        }
        return value.trim();
    }
}

package ru.polmira.listener;

import android.app.Notification;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Parcelable;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.text.TextUtils;
import android.util.Log;

import java.util.LinkedHashMap;
import java.util.Map;

public class MaxNotificationListener extends NotificationListenerService {
    private static final String TAG = "PolmiraListener";

    @Override
    public void onListenerConnected() {
        clearTargetNotifications();
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        SharedPreferences prefs = SettingsStore.prefs(this);
        String targetPackage = SettingsStore.get(prefs, SettingsStore.KEY_TARGET_PACKAGE, "ru.oneme.app");
        if (!targetPackage.equals(sbn.getPackageName())) {
            return;
        }

        String webhook = SettingsStore.get(prefs, SettingsStore.KEY_WEBHOOK_URL, "");
        if (webhook.isEmpty()) {
            Log.d(TAG, "Skip notification: webhook is empty");
            return;
        }

        String fingerprint = sbn.getKey() + ":" + sbn.getPostTime();
        String last = prefs.getString(SettingsStore.KEY_LAST_EVENT, "");
        if (fingerprint.equals(last)) {
            return;
        }

        Notification notification = sbn.getNotification();
        Bundle extras = notification == null ? null : notification.extras;
        String title = charSeq(extras, Notification.EXTRA_TITLE);
        String text = bestText(extras);
        String conversation = charSeq(extras, Notification.EXTRA_CONVERSATION_TITLE);
        String subText = charSeq(extras, Notification.EXTRA_SUB_TEXT);
        String ticker = notification == null || notification.tickerText == null ? "" : notification.tickerText.toString();

        if (title.isEmpty() && text.isEmpty() && ticker.isEmpty()) {
            Log.d(TAG, "Skip notification: no readable text");
            return;
        }

        Map<String, String> event = new LinkedHashMap<>();
        event.put("source", "polmira-listener");
        event.put("event", "notification");
        event.put("phone", SettingsStore.get(prefs, SettingsStore.KEY_PHONE, ""));
        event.put("package", sbn.getPackageName());
        event.put("key", sbn.getKey());
        event.put("title", title);
        event.put("text", text);
        event.put("conversation", conversation);
        event.put("sub_text", subText);
        event.put("ticker", ticker);
        event.put("time", String.valueOf(sbn.getPostTime()));

        prefs.edit().putString(SettingsStore.KEY_LAST_EVENT, fingerprint).apply();
        WebhookClient.postAsync(webhook, SettingsStore.get(prefs, SettingsStore.KEY_SECRET, ""), event,
                (ok, message) -> {
                    Log.d(TAG, "Webhook result: " + ok + " " + message);
                    if (ok) {
                        cancelNotification(sbn.getKey());
                    }
                });
    }

    private void clearTargetNotifications() {
        SharedPreferences prefs = SettingsStore.prefs(this);
        String targetPackage = SettingsStore.get(prefs, SettingsStore.KEY_TARGET_PACKAGE, "ru.oneme.app");
        try {
            StatusBarNotification[] notifications = getActiveNotifications();
            if (notifications == null) {
                return;
            }
            for (StatusBarNotification notification : notifications) {
                if (notification != null && targetPackage.equals(notification.getPackageName())) {
                    cancelNotification(notification.getKey());
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to clear existing notifications", e);
        }
    }

    private static String bestText(Bundle extras) {
        if (extras == null) {
            return "";
        }

        String text = charSeq(extras, Notification.EXTRA_TEXT);
        if (!text.isEmpty()) {
            return text;
        }

        String latestMessage = latestMessage(extras);
        if (!latestMessage.isEmpty()) {
            return latestMessage;
        }

        String latestLine = latestLine(extras);
        if (!latestLine.isEmpty()) {
            return latestLine;
        }

        return charSeq(extras, Notification.EXTRA_BIG_TEXT);
    }

    private static String charSeq(Bundle extras, String key) {
        if (extras == null) {
            return "";
        }
        CharSequence value = extras.getCharSequence(key);
        return value == null ? "" : value.toString();
    }

    private static String latestLine(Bundle extras) {
        CharSequence[] lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES);
        if (lines == null || lines.length == 0) {
            return "";
        }
        for (int i = lines.length - 1; i >= 0; i--) {
            CharSequence line = lines[i];
            if (line != null && !TextUtils.isEmpty(line)) {
                return line.toString();
            }
        }
        return "";
    }

    private static String latestMessage(Bundle extras) {
        Parcelable[] parcelables = extras.getParcelableArray(Notification.EXTRA_MESSAGES);
        if (parcelables == null || parcelables.length == 0) {
            return "";
        }
        for (int i = parcelables.length - 1; i >= 0; i--) {
            Parcelable parcelable = parcelables[i];
            if (!(parcelable instanceof Bundle)) {
                continue;
            }
            Bundle message = (Bundle) parcelable;
            CharSequence text = message.getCharSequence("text");
            if (text == null || TextUtils.isEmpty(text)) {
                continue;
            }
            CharSequence sender = message.getCharSequence("sender");
            if (sender != null && !TextUtils.isEmpty(sender)) {
                return sender + ": " + text;
            }
            return text.toString();
        }
        return "";
    }
}

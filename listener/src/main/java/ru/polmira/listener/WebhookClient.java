package ru.polmira.listener;

import android.util.Log;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class WebhookClient {
    private static final String TAG = "PolmiraListener";
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    interface Callback {
        void onDone(boolean ok, String message);
    }

    private WebhookClient() {
    }

    static void postAsync(String webhookUrl, String secret, Map<String, String> payload, Callback callback) {
        EXECUTOR.execute(() -> {
            try {
                String response = post(webhookUrl, secret, payload);
                if (callback != null) {
                    callback.onDone(true, response);
                }
            } catch (Exception e) {
                Log.w(TAG, "Webhook failed", e);
                if (callback != null) {
                    callback.onDone(false, e.getClass().getSimpleName() + ": " + e.getMessage());
                }
            }
        });
    }

    private static String post(String webhookUrl, String secret, Map<String, String> payload) throws Exception {
        URL url = new URL(webhookUrl);
        byte[] body = JsonUtil.object(payload).getBytes(StandardCharsets.UTF_8);
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(15000);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        connection.setRequestProperty("Accept", "application/json, text/plain, */*");
        if (secret != null && !secret.isEmpty()) {
            connection.setRequestProperty("X-Polmira-Secret", secret);
        }
        try (OutputStream output = connection.getOutputStream()) {
            output.write(body);
        }
        int code = connection.getResponseCode();
        connection.disconnect();
        if (code < 200 || code >= 300) {
            throw new IllegalStateException("HTTP " + code);
        }
        return "HTTP " + code;
    }
}

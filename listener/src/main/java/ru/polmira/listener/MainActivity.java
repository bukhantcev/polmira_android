package ru.polmira.listener;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.LinkedHashMap;
import java.util.Map;

public class MainActivity extends Activity {
    private SharedPreferences prefs;
    private EditText webhookInput;
    private EditText secretInput;
    private EditText phoneInput;
    private EditText packageInput;
    private TextView statusView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = SettingsStore.prefs(this);
        setContentView(createContent());
        loadValues();
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateStatus();
    }

    private View createContent() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(20), dp(20), dp(20), dp(20));
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Polmira Listener");
        title.setTextSize(24);
        title.setGravity(Gravity.START);
        title.setPadding(0, 0, 0, dp(12));
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("Слушает уведомления MAX и отправляет видимый текст в Polmira webhook.");
        hint.setTextSize(15);
        hint.setPadding(0, 0, 0, dp(16));
        root.addView(hint);

        webhookInput = addInput(root, "Webhook URL", "https://example.com/adminpanel/api/listener/event");
        secretInput = addInput(root, "Secret", "");
        phoneInput = addInput(root, "Phone name", "me");
        packageInput = addInput(root, "Target package", "ru.oneme.app");

        Button save = addButton(root, "Сохранить настройки");
        save.setOnClickListener(v -> {
            saveValues();
            updateStatus();
            showMessage("Готово", "Настройки сохранены.");
        });

        Button access = addButton(root, "Открыть доступ к уведомлениям");
        access.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)));

        Button test = addButton(root, "Отправить тест");
        test.setOnClickListener(v -> sendTest());

        statusView = new TextView(this);
        statusView.setTextSize(14);
        statusView.setPadding(0, dp(16), 0, 0);
        root.addView(statusView);

        return scroll;
    }

    private EditText addInput(LinearLayout root, String label, String hint) {
        TextView view = new TextView(this);
        view.setText(label);
        view.setTextSize(13);
        view.setPadding(0, dp(10), 0, dp(4));
        root.addView(view);

        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint(hint);
        input.setTextSize(15);
        root.addView(input, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        return input;
    }

    private Button addButton(LinearLayout root, String text) {
        Button button = new Button(this);
        button.setText(text);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(10);
        root.addView(button, params);
        return button;
    }

    private void loadValues() {
        webhookInput.setText(SettingsStore.get(prefs, SettingsStore.KEY_WEBHOOK_URL, ""));
        secretInput.setText(SettingsStore.get(prefs, SettingsStore.KEY_SECRET, ""));
        phoneInput.setText(SettingsStore.get(prefs, SettingsStore.KEY_PHONE, "me"));
        packageInput.setText(SettingsStore.get(prefs, SettingsStore.KEY_TARGET_PACKAGE, "ru.oneme.app"));
    }

    private void saveValues() {
        prefs.edit()
                .putString(SettingsStore.KEY_WEBHOOK_URL, webhookInput.getText().toString().trim())
                .putString(SettingsStore.KEY_SECRET, secretInput.getText().toString().trim())
                .putString(SettingsStore.KEY_PHONE, phoneInput.getText().toString().trim())
                .putString(SettingsStore.KEY_TARGET_PACKAGE, packageInput.getText().toString().trim())
                .apply();
    }

    private void updateStatus() {
        String enabled = isNotificationAccessEnabled() ? "да" : "нет";
        String last = SettingsStore.get(prefs, SettingsStore.KEY_LAST_EVENT, "пока нет");
        statusView.setText("Доступ к уведомлениям: " + enabled + "\nПоследнее событие: " + last);
    }

    private boolean isNotificationAccessEnabled() {
        String enabled = Settings.Secure.getString(getContentResolver(), "enabled_notification_listeners");
        return enabled != null && enabled.contains(getPackageName());
    }

    private void sendTest() {
        saveValues();
        String webhook = webhookInput.getText().toString().trim();
        if (webhook.isEmpty()) {
            showMessage("Webhook пустой", "Укажи URL, куда отправлять события.");
            return;
        }
        Map<String, String> event = new LinkedHashMap<>();
        event.put("source", "polmira-listener");
        event.put("event", "test");
        event.put("phone", phoneInput.getText().toString().trim());
        event.put("package", getPackageName());
        event.put("title", "Polmira Listener");
        event.put("text", "Тестовое сообщение");
        event.put("time", String.valueOf(System.currentTimeMillis()));
        WebhookClient.postAsync(webhook, secretInput.getText().toString().trim(), event, (ok, message) ->
                runOnUiThread(() -> showMessage(ok ? "Отправлено" : "Ошибка", message)));
    }

    private void showMessage(String title, String message) {
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}

package io.github.wgga.push_kit;

import android.content.Context;

import com.vivo.push.model.UPSNotificationMessage;
import com.vivo.push.sdk.OpenClientPushMessageReceiver;

import java.util.HashMap;
import java.util.Map;

/** Receives vivo callbacks without retaining the Flutter plugin instance. */
public final class VivoMessageReceiver extends OpenClientPushMessageReceiver {
    private void send(UPSNotificationMessage message, String event) {
        final Map<String, Object> data = new HashMap<>();
        if (message != null) {
            data.put("msgId", message.getMsgId());
            data.put("content", message.getContent());
            data.put("skipContent", message.getSkipContent());
            data.put("title", message.getTitle());
            data.put("targetType", message.getTargetType());
            data.put("targetContent", message.getTargetContent());
            if (message.getParams() != null) {
                data.put("params", new HashMap<>(message.getParams()));
            }
        }
        PushKitPlugin.emit(event, data);
    }

    @Override
    public void onNotificationMessageClicked(Context context,
                                             UPSNotificationMessage message) {
        send(message, "push.openNotification");
    }

    @Override
    public void onForegroundMessageArrived(UPSNotificationMessage message) {
        send(message, "push.receiveNotification");
    }

    @Override
    public void onReceiveRegId(Context context, String regId) {
        if (regId != null && !regId.trim().isEmpty()) {
            PushKitPlugin.emit("vivopush.receiveRegisterResult",
                    PushKitPlugin.map("regId", regId));
        }
    }
}

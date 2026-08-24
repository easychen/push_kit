package io.github.wgga.push_kit;

import com.vivo.push.model.UPSNotificationMessage;
import com.vivo.push.sdk.OpenClientPushMessageReceiver;
import android.content.Context;
import java.util.HashMap;
import java.util.Map;

public final class VivoMessageReceiver extends OpenClientPushMessageReceiver {
    private void send(UPSNotificationMessage message, String event) {
        Map<String, Object> data = new HashMap<>();
        data.put("msgId", message.getMsgId());
        data.put("content", message.getSkipContent());
        PushKitPlugin.emit(event, data);
    }
    @Override public void onNotificationMessageClicked(Context context, UPSNotificationMessage message) { send(message, "push.openNotification"); }
    @Override public void onForegroundMessageArrived(UPSNotificationMessage message) { send(message, "push.receiveNotification"); }
    @Override public void onReceiveRegId(Context context, String regId) { PushKitPlugin.emit("vivopush.receiveRegisterResult", PushKitPlugin.map("regId", regId)); }
}

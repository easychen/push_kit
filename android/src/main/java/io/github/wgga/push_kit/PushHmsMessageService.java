package io.github.wgga.push_kit;

import com.huawei.hms.push.HmsMessageService;
import com.huawei.hms.push.RemoteMessage;

import java.util.HashMap;
import java.util.Map;

/** Receives Huawei messages and forwards only codec-safe primitive data. */
public final class PushHmsMessageService extends HmsMessageService {
    @Override
    public void onMessageReceived(RemoteMessage message) {
        final Map<String, Object> data = new HashMap<>();
        data.put("messageType", "data");
        if (message != null && message.getDataOfMap() != null) {
            data.putAll(message.getDataOfMap());
        }
        PushKitPlugin.emit("push.receiveNotification", data);
    }

    @Override
    public void onNewToken(String token) {
        if (token != null && !token.trim().isEmpty()) {
            PushKitPlugin.emit("hms.token", PushKitPlugin.map("token", token));
        }
    }
}

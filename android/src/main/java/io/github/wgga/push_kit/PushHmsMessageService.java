package io.github.wgga.push_kit;

import com.huawei.hms.push.HmsMessageService;
import com.huawei.hms.push.RemoteMessage;
import java.util.HashMap;
import java.util.Map;

public final class PushHmsMessageService extends HmsMessageService {
    @Override public void onMessageReceived(RemoteMessage message) {
        Map<String, Object> data = new HashMap<>();
        data.put("messageType", "data");
        data.putAll(message.getDataOfMap());
        PushKitPlugin.emit("push.receiveNotification", data);
    }
    @Override public void onNewToken(String token) {
        PushKitPlugin.emit("hms.token", PushKitPlugin.map("token", token));
    }
}

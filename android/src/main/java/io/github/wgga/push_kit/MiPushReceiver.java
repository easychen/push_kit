package io.github.wgga.push_kit;

import android.content.Context;
import com.xiaomi.mipush.sdk.ErrorCode;
import com.xiaomi.mipush.sdk.MiPushClient;
import com.xiaomi.mipush.sdk.MiPushCommandMessage;
import com.xiaomi.mipush.sdk.MiPushMessage;
import com.xiaomi.mipush.sdk.PushMessageReceiver;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class MiPushReceiver extends PushMessageReceiver {
    private Map<String, Object> data(MiPushMessage message) {
        Map<String, Object> value = new HashMap<>();
        value.put("content", message.getContent()); value.put("messageId", message.getMessageId());
        value.put("passThrough", message.getPassThrough()); value.put("messageType", message.getMessageType());
        value.put("title", message.getTitle()); value.put("description", message.getDescription());
        value.put("alias", message.getAlias()); value.put("topic", message.getTopic()); value.put("notifyId", message.getNotifyId());
        return value;
    }
    @Override public void onNotificationMessageArrived(Context context, MiPushMessage message) { PushKitPlugin.emit("push.receiveNotification", data(message)); }
    @Override public void onNotificationMessageClicked(Context context, MiPushMessage message) { PushKitPlugin.emit("push.openNotification", data(message)); }
    @Override public void onReceiveRegisterResult(Context context, MiPushCommandMessage message) {
        List<String> args = message.getCommandArguments();
        if (MiPushClient.COMMAND_REGISTER.equals(message.getCommand()) && message.getResultCode() == ErrorCode.SUCCESS && args != null && !args.isEmpty()) PushKitPlugin.emit("mipush.receiveRegisterResult", PushKitPlugin.map("regId", args.get(0)));
    }
}

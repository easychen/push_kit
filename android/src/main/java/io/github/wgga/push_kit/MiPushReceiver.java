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

/** Receives Xiaomi callbacks and forwards codec-safe payloads to Flutter. */
public final class MiPushReceiver extends PushMessageReceiver {
    private Map<String, Object> data(MiPushMessage message) {
        final Map<String, Object> value = new HashMap<>();
        if (message == null) {
            return value;
        }
        value.put("content", message.getContent());
        value.put("messageId", message.getMessageId());
        value.put("passThrough", message.getPassThrough());
        value.put("messageType", message.getMessageType());
        value.put("title", message.getTitle());
        value.put("description", message.getDescription());
        value.put("alias", message.getAlias());
        value.put("topic", message.getTopic());
        value.put("notifyId", message.getNotifyId());
        value.put("userAccount", message.getUserAccount());
        if (message.getExtra() != null) {
            value.put("extra", new HashMap<>(message.getExtra()));
        }
        return value;
    }

    @Override
    public void onNotificationMessageArrived(Context context, MiPushMessage message) {
        PushKitPlugin.emit("push.receiveNotification", data(message));
    }

    @Override
    public void onNotificationMessageClicked(Context context, MiPushMessage message) {
        PushKitPlugin.emit("push.openNotification", data(message));
    }

    @Override
    public void onReceivePassThroughMessage(Context context, MiPushMessage message) {
        final Map<String, Object> payload = data(message);
        payload.put("messageType", "passThrough");
        PushKitPlugin.emit("push.receiveNotification", payload);
    }

    @Override
    public void onReceiveRegisterResult(Context context, MiPushCommandMessage message) {
        if (message == null
                || !MiPushClient.COMMAND_REGISTER.equals(message.getCommand())
                || message.getResultCode() != ErrorCode.SUCCESS) {
            return;
        }
        final List<String> arguments = message.getCommandArguments();
        if (arguments != null && !arguments.isEmpty()
                && arguments.get(0) != null && !arguments.get(0).trim().isEmpty()) {
            PushKitPlugin.emit("mipush.receiveRegisterResult",
                    PushKitPlugin.map("regId", arguments.get(0)));
        }
    }
}

package app.viska.viska

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * Serviço em primeiro plano do tipo `connectedDevice`, ativo só enquanto o
 * seletor de arquivos está aberto ou há transferência em curso.
 *
 * Sem ele o Android congela o app quando o seletor o manda para segundo plano
 * e derruba os sockets TCP (LAN e WebRTC). A notificação é genérica de
 * propósito: sem contato, arquivo ou progresso, e secreta na tela de bloqueio,
 * porque ela fica registrada no histórico de notificações do sistema.
 */
class TransferForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        // Se o sistema matar o processo, não há transferência a retomar: o
        // envio vive só em memória.
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Transferências",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            },
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Viska")
            .setContentText("Transferência em andamento")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "viska_transfer"
        private const val NOTIFICATION_ID = 0x5654
    }
}

# Jellyfin Media Backup 插件（适用于 Jellyfin 12.4）

用于接收 Finamp 手机端上传的照片和视频文件备份，直接复用 Jellyfin 原生用户鉴权，无需额外端口或登录。

## Windows 安装步骤（以 `D:\App\jellyfin` 为例）

1. 从 GitHub Release 下载 `Jellyfin.Plugin.MediaBackup-v1.0.0-jf12.4.zip`。
2. 解压后将其中的 `Jellyfin.Plugin.MediaBackup.dll` 和 `meta.json` 放入 Jellyfin 插件目录（通常为 `D:\App\jellyfin\data\plugins\MediaBackup\` 或 `D:\App\jellyfin\plugins\MediaBackup\`，视您的 Jellyfin 数据目录配置而定）。
3. 重启 Jellyfin 服务。
4. 打开 Jellyfin 网页端 → **控制台（Dashboard）→ 插件（Plugins）→ Media Backup**：
   - 填写 **备份保存根目录**（例如 `D:\Media\PhoneBackup`）。
   - 根据需要勾选 **保留所选相册文件夹名称**（开启后直接保存为 `根目录\所选文件夹名\原文件名`，不增加多余目录层级）和 **上传完成后自动触发媒体库扫描**。
   - 点击 **保存（Save）**。
5. 打开手机上的 Finamp → 侧边栏 → **照片与视频备份**，选择文件夹并点击 **开始备份** 即可。

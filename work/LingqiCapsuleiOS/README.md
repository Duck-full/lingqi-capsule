# 灵栖胶囊 Capsule iOS

首个 iPhone 原生 SwiftUI 工程，与现有 macOS 工程并行维护。

## 首版能力

- 今日胶囊：快速记录灵感、关键词、心情和今日行动摘要。
- 历史胶囊：按日期组成时间轴，查看每日灵感与事项。
- 今日行动：新增、编辑、删除、完成事项，并使用系统通知提醒。
- 私人 CloudKit：使用用户 Apple ID 的私人数据库同步，不需要注册账号。
- Mac 数据迁移：设置页可导入一次性 JSON 迁移包，写入 SwiftData 后自动进入 CloudKit 同步。

## 系统与工程

- iPhone only
- Deployment Target: iOS 26.0，兼容 iOS 26.5
- SwiftUI + SwiftData + CloudKit
- Bundle ID: `com.duckfull.lingqicapsule.ios`
- CloudKit Container: `iCloud.com.duckfull.lingqicapsule`

## 首次运行前

1. 安装支持 iOS 26 SDK 的完整 Xcode。
2. 打开 `LingqiCapsuleiOS.xcodeproj`。
3. 在 Signing & Capabilities 中选择 Apple Developer Team。
4. 在开发者后台创建并绑定 `iCloud.com.duckfull.lingqicapsule`。
5. 保留 iCloud/CloudKit capability，确认容器选择正确。
6. 选择 iPhone 模拟器或真机运行。

## Mac 迁移包

迁移包为 UTF-8 JSON，日期使用 ISO 8601：

```json
{
  "version": 1,
  "exportedAt": "2026-06-20T08:00:00Z",
  "notes": [
    {
      "date": "2026-06-20",
      "text": "今天的灵感"
    }
  ],
  "reminders": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "title": "整理想法",
      "notes": "",
      "date": "2026-06-20T00:00:00Z",
      "remindAt": "2026-06-20T09:30:00Z",
      "frequency": "once",
      "customInterval": 30,
      "isDone": false,
      "createdAt": "2026-06-20T08:00:00Z"
    }
  ]
}
```

后续跨端联调阶段需要给 macOS 工程补充一次性导出/上传入口，并让两个平台使用相同 CloudKit schema。

当前仓库已提供不改动 Mac 数据的导出工具：

```bash
python3 Tools/export_mac_migration.py \
  --output ~/Desktop/lingqi-capsule-migration.json
```

将生成的 JSON 通过 AirDrop、iCloud Drive 或文件 App 发送到 iPhone，再从“我的 → 导入 Mac 一次性迁移包”导入。

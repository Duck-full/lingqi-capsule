# 灵栖胶囊Capsule

灵栖胶囊Capsule 是一款面向 macOS 与 iPhone 的每日灵感和行动记录工具。macOS 版本支持日历事项、系统通知、今日灵感胶囊、主题换肤、天气提醒和自定义 Dock 图标；iPhone 原生 SwiftUI 首版正在独立分支开发。

## 功能

- 日历按天查看和添加提醒事项。
- 支持 macOS 系统通知提醒。
- 支持仅一次、每天、工作日、每周、每月、自定义分钟、自定义小时等提醒频率。
- 支持今日灵感胶囊，文本输入体验接近系统备忘录。
- 新增今日总结卡片，自动汇总当天灵感、事项完成度、心情和天气，并支持一键复制。
- 新增历史胶囊视图，可按日期回看每日灵感、提醒事项、关键词、心情和总结。
- 支持将完整日期胶囊导出为可编辑 Word `.docx` 和 PDF。
- 日历日期状态区分：事项和灵感胶囊会显示不同状态点。
- 内置多套视觉主题，包含霓虹、未来科技感、卡通、古风等风格。
- 新增 iOS27 毛玻璃质感风格，融合清透玻璃卡片、柔和背景和系统感图标。
- 新增四款动漫氛围主题：天气之子、你的名字、鬼灭之刃、夏目友人帐，包含主题化背景、图标语义和动效。
- 新增沉浸风景玻璃主题，支持多张压缩风景背景随机切换，并供休鼾模式复用。
- 设置弹窗支持调节功能卡片透明度与高斯模糊值，定制玻璃质感。
- 今日灵感胶囊支持 300 字灵感进度目标、2000 字输入上限、4 个自动关键词胶囊和今日心情判断。
- 今日灵感胶囊关键词提取会优先保留完整短语，避免粗暴截断。
- 菜单栏快捷输入采用临时草稿，保存后追加到当天灵感胶囊，避免覆盖主页面长文本。
- 优化文本输入、后台保存、通知调度和 Intel 架构动效负载。
- 默认主题为沉浸风景玻璃风格。
- 顶部显示今日天气，基于当前网络城市位置获取天气数据，常见城市名称优先中文展示，并按天气切换沉浸背景。
- 支持用户自定义运行时 Dock 图标。
- 支持 Intel 与 Apple Silicon，最低系统版本 macOS 13.1。

## 项目结构

```text
work/DailyReminderWidget/
├── Assets/
│   └── AppIcon.png
├── Sources/
│   └── DailyReminderWidget.swift
├── build.sh
└── make_icon.swift

work/LingqiCapsuleiOS/
├── LingqiCapsuleiOS.xcodeproj/
├── LingqiCapsuleiOS/
│   ├── App/
│   ├── Models/
│   ├── Services/
│   ├── Design/
│   └── Features/
└── Tools/
    └── export_mac_migration.py
```

iOS 产品与数据架构见 `docs/IOS_PRODUCT_ARCHITECTURE.md`。

## 本地构建

在仓库根目录执行：

```bash
cd work/DailyReminderWidget
./build.sh
```

构建完成后会在根目录的 `outputs/` 中生成：

- `灵栖胶囊Capsule.app`
- `灵栖胶囊Capsule.dmg`

如果需要把应用分发到另一台 Mac，建议使用 Apple Developer ID 签名和公证。详细流程见：

```text
docs/MAC_DISTRIBUTION.md
```

## 图标规范

默认应用图标位于：

```text
work/DailyReminderWidget/Assets/AppIcon.png
```

建议图标规格：

- PNG 格式。
- 1024 x 1024 像素。
- 透明背景。
- 主体居中。
- 四周保留 8%-12% 安全边距。
- 避免过小文字和细节。

应用内右下角齿轮入口也支持用户自定义运行时 Dock 图标。
默认图标会生成 macOS 多尺寸图标资源，并用于应用启动图标和系统通知附件图标。

## 天气说明

天气组件会请求网络定位城市并获取天气：

- 城市定位：`ipapi.co`
- 天气数据：`open-meteo.com`

如果网络不可用，天气卡片会显示重试状态，不影响事项提醒和今日灵感胶囊功能。

## 隐私说明

macOS 当前版本将事项、灵感、主题和自定义图标保存在本机应用支持目录中。iPhone 版本使用用户 Apple ID 对应的私人 CloudKit 数据库实现跨设备同步，不建立额外账号，也不接入广告系统。天气功能会访问第三方天气服务以获取当前城市天气。更详细说明见 `PRIVACY.md`。

## 许可证

本项目使用 MIT License。

# 小Ding助手

小Ding助手是一款本地 macOS 每日事项提醒小组件，支持日历事项、系统通知、当天记事、主题换肤、天气提醒和自定义 Dock 图标。

## 功能

- 日历按天查看和添加提醒事项。
- 支持 macOS 系统通知提醒。
- 支持仅一次、每天、工作日、每周、每月、自定义分钟、自定义小时等提醒频率。
- 支持当天记事，文本输入体验接近系统备忘录。
- 支持将某天记事导出为可编辑 Word `.docx` 和 PDF。
- 日历日期状态区分：事项和记事会显示不同状态点。
- 内置多套视觉主题，包含霓虹、未来科技感、卡通、古风等风格。
- 默认主题为古风风格。
- 顶部显示今日天气，基于当前网络城市位置获取天气数据。
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
```

## 本地构建

在仓库根目录执行：

```bash
cd work/DailyReminderWidget
./build.sh
```

构建完成后会在根目录的 `outputs/` 中生成：

- `小Ding助手.app`
- `小Ding助手.dmg`

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

## 天气说明

天气组件会请求网络定位城市并获取天气：

- 城市定位：`ipapi.co`
- 天气数据：`open-meteo.com`

如果网络不可用，天气卡片会显示重试状态，不影响事项提醒和记事本功能。

## 隐私说明

事项和记事数据保存在本机应用支持目录中，不会上传到服务器。天气功能会访问第三方天气服务以获取当前城市天气。

## 许可证

本项目使用 MIT License。

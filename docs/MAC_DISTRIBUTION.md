# macOS 分发与 Gatekeeper 说明

## 问题原因

如果把本地构建的 `灵栖胶囊Capsule.app` 复制到另一台 Mac，系统可能提示：

> Apple 无法验证是否包含可能危害 Mac 安全或泄漏隐私的恶意软件。

这是 Gatekeeper 对“未使用 Apple Developer ID 签名并公证”的应用进行拦截。当前本地测试包默认使用 ad-hoc 签名，只适合自己开发验证，不适合直接公开分发。

## 正式分发方案

正式对外发布需要：

1. Apple Developer Program 账号。
2. `Developer ID Application` 证书。
3. App 使用 Hardened Runtime 签名。
4. DMG 提交 Apple notarization。
5. 对 DMG staple 公证票据。

构建命令：

```bash
cd work/DailyReminderWidget
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="lingqi-notary" \
./build.sh
```

`NOTARY_PROFILE` 需要提前创建：

```bash
xcrun notarytool store-credentials lingqi-notary \
  --apple-id "your-apple-id@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

验证：

```bash
spctl -a -vvv -t exec outputs/灵栖胶囊Capsule.app
spctl -a -vvv -t open --context context:primary-signature outputs/灵栖胶囊Capsule.dmg
```

通过时应看到 `accepted`。

## 本地测试包方案

没有 Developer ID 时，`build.sh` 会继续生成本地测试包，并在 DMG 内附带：

- `首次打开修复.command`
- `首次打开说明.txt`

在新 Mac 上测试：

1. 打开 DMG。
2. 将 `灵栖胶囊Capsule.app` 拖到“应用程序”。
3. 双击 `首次打开修复.command`。

脚本只执行：

```bash
xattr -dr com.apple.quarantine "/Applications/灵栖胶囊Capsule.app"
open "/Applications/灵栖胶囊Capsule.app"
```

这只适合个人测试，不等同于正式签名公证。

# App 發佈（TestFlight）

```
git tag v1.1.0 && git push origin v1.1.0
        │
        ▼  .github/workflows/ios-testflight.yml（macOS runner，public repo 免費）
flutter analyze / test ──► xcodebuild archive（API key 自動簽章）──► export .ipa ──► altool 上傳 TestFlight
```

- **版本號**：tag `v1.1.0` → CFBundleShortVersionString `1.1.0`；build number = workflow run number（每次遞增，TestFlight 要求）。`pubspec.yaml` 的 `version:` 只是本機開發用的預設。
- 手動觸發：Actions → iOS TestFlight → Run workflow（可填 build name）。
- 產出的 `.ipa` 也會留在 run 的 artifacts。

## 一次性設定（GitHub Secrets）

1. App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → Generate**
   - Name：`github-actions`
   - Access：**Admin**（雲端管理的 Apple Distribution 憑證需要；若之後改用自己的 .p12，App Manager 即可）
   - 下載 `AuthKey_XXXXXXXXXX.p8`（只能下載一次）
2. 在 repo Settings → Secrets and variables → Actions 新增：

   | Secret | 值 |
   |---|---|
   | `APP_STORE_CONNECT_KEY_ID` | Key ID（檔名裡的 `XXXXXXXXXX`） |
   | `APP_STORE_CONNECT_ISSUER_ID` | 同頁面的 Issuer ID |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | `.p8` 檔全文（含 BEGIN/END 行） |
   | `IOS_DIST_P12_BASE64`（選用） | `base64 -i dist.p12`，Apple Distribution 憑證 + 私鑰 |
   | `IOS_DIST_P12_PASSWORD`（選用） | 上面的密碼 |

   用 gh CLI：
   ```bash
   gh secret set APP_STORE_CONNECT_KEY_ID --body XXXXXXXXXX
   gh secret set APP_STORE_CONNECT_ISSUER_ID --body 12345678-aaaa-bbbb-cccc-1234567890ab
   gh secret set APP_STORE_CONNECT_PRIVATE_KEY < ~/Downloads/AuthKey_XXXXXXXXXX.p8
   ```
3. App Store Connect 裡要先有這個 App（Bundle ID `com.edwards.mower`），TestFlight 才收得到 build。

## 與機器人版本的關係

App 不需要和機器人同一天更新。連線後 App 讀 `/robot/info` 的 `api_version`，和 `lib/models/robot_info.dart` 的 `kMinRobotApiVersion..kMaxRobotApiVersion` 比對：

- 在範圍內 → 正常
- 機器人太舊 → 首頁提示「更新機器人」（`/system/update`），地圖 / 手動控制擋住
- App 太舊 → 提示更新 App

機器人 API 有變更時（見 `mower_path_planning/docs/ROBOT_API.md`），改這兩個常數並記在 changelog；發佈順序建議 **App 先、機器人後**（App 向下相容舊機器人）。

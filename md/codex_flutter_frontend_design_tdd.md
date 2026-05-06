# Codex Flutter Frontend Design And TDD Notes

本文件是 Codex 依照 `md/flutter_frontend_function_spec.md` 與目前 Flutter 專案架構整理出的實作設計、TDD 切分與 Git 工作流。這份文件是工作筆記與開發契約，後續功能會依這裡拆 commit。

## 1. 目前架構觀察

目前 App 是一個輕量 Flutter prototype：

- `lib/main.dart`
  - 使用 `Provider<RosService>` 與 `ChangeNotifierProvider<MowerStatusProvider>`。
  - 入口畫面是 `HomeScreen`。
- `lib/services/ros_service.dart`
  - 現在是 mock facade，所有資料由 `MockDataProvider` 回傳。
  - 尚未接 REST、WebSocket 或 rosbridge。
- `lib/providers/mower_status_provider.dart`
  - 使用 timer polling 取得 mower status 與 coverage path。
  - 目前只處理 demo 狀態，還沒有 mission state machine。
- `lib/screens/home_screen.dart`
  - 單頁 map overlay 設計。
  - 目前只有 Start / Pause、Return to Base、Settings、Mower Config。
- `lib/models/*`
  - 現有模型偏 GPS mower demo。
  - 尚未對齊 ROS service/topic DTO，例如 service result、zone summary、map layer、coverage settings、operation log。
- `test/widget_test.dart`
  - 仍是 Flutter counter template，需要替換成符合本 App 的測試。

結論：現有架構可以保留 `Provider + service facade`，但需要先補一層可測的 mission domain/controller，再慢慢替換 UI。

## 2. MVP 決策暫定

尚未和使用者確認細節前，Codex 先採用保守 MVP：

1. 保留目前 App 可啟動，不做一次性大重寫。
2. 優先完成已保存區域流程：
   - Load Saved Zones
   - Create Free Space
   - Create Risk Map
   - Generate Coverage
   - Execute Zone
   - Cancel Navigation
3. Adapter 先設計成 interface，實作 mock adapter。
4. 真實 ROS adapter 先以 REST/WebSocket 都可替換的形式保留邊界。
5. UI 先做三頁式 MVP：
   - `Map + Record`
   - `Planning`
   - `Execution + Logs`

如果之後確認使用 rosbridge，adapter 只替換 service/topic transport，不影響 controller tests。

## 3. 建議新增目錄

```text
lib/
  models/
    mission_state.dart
    operation_log_entry.dart
    ros_service_result.dart
    coverage_settings.dart
    map_layer.dart
    marker_layer.dart
    zone_summary.dart
  services/
    ros_adapter.dart
    mock_ros_adapter.dart
  controllers/
    mission_controller.dart
  screens/
    mission_home_screen.dart
    map_record_screen.dart
    planning_screen.dart
    execution_screen.dart
  widgets/
    service_action_button.dart
    operation_log_panel.dart
    layer_toggle_panel.dart
    zone_selector.dart
    coverage_settings_form.dart
    execution_status_panel.dart
test/
  models/
  services/
  controllers/
  widgets/
```

命名原則：

- `RosAdapter` 是抽象邊界，Flutter UI 不直接知道 ROS API transport。
- `MissionController` 管 service call 流程、mission state、operation log、button enable/disable。
- `MowerStatusProvider` 先保留，之後可改為 facade 或拆成 `TelemetryProvider`。

## 4. Mission State Model

前端需要獨立狀態機，不只依賴後端回應。

```dart
enum MissionState {
  disconnected,
  idle,
  recordingZone,
  recordingRisk,
  recordingChannel,
  zonesLoaded,
  freeSpaceReady,
  riskMapReady,
  coverageReady,
  executing,
  failed,
}
```

狀態轉移由 `MissionController` 負責：

- `loadZones()` success -> `zonesLoaded`
- topic `/free_space` updated -> `freeSpaceReady`
- topic `/risk_map_inflated` updated -> `riskMapReady`
- `generateCoverage()` success -> `coverageReady`
- `executeZone(zoneId)` success -> `executing`
- service failure / adapter timeout -> `failed`

Recording 狀態互斥：

- `recordingZone`
- `recordingRisk`
- `recordingChannel`

Flutter 端必須先擋掉並行記錄，不依賴後端防呆。

## 5. Adapter Design

```dart
abstract class RosAdapter {
  Stream<RosConnectionStatus> get connectionStatus;
  Stream<MapLayer> get mapLayers;
  Stream<MarkerLayer> get markerLayers;
  Stream<List<ZoneSummary>> get zoneSummaries;

  Future<RosServiceResult> callTrigger(String serviceName);
  Future<RosServiceResult> setParameters(String nodeName, Map<String, Object?> values);
  Future<RosServiceResult> executeZone(int zoneId);
  Future<List<ZoneSummary>> getZoneSummaries();
}
```

第一階段只實作 `MockRosAdapter`：

- 固定回傳成功/失敗資料。
- 可在 tests 中注入 delay、timeout、failure。
- 模擬 topic update，讓 controller 能用 TDD 驗證非同步流程。

第二階段再補真實 transport：

- `RestRosAdapter`
- 或 `RosbridgeAdapter`
- 或 `WebSocketRosAdapter`

## 6. Controller Responsibilities

`MissionController extends ChangeNotifier`：

- 保留目前 mission state。
- 管理 service loading 狀態，避免同 service 重複送出。
- 寫入 operation log。
- 提供 UI button enable/disable getter。
- 包裝 coverage settings validation。
- 訂閱 adapter streams，收到 topic update 後推進 state。

重要 getter：

```dart
bool get canLoadZones;
bool get canCreateFreeSpace;
bool get canCreateRiskMap;
bool get canGenerateCoverage;
bool get canExecuteZone;
bool get canCancelNavigation;
bool isServiceBusy(String serviceName);
```

## 7. UI Integration Plan

先不推翻 `HomeScreen`，而是逐步改：

1. 新增 `MissionHomeScreen`
   - 使用 `NavigationRail` 或底部 navigation。
   - desktop/tablet 偏 sidebar，phone 偏 bottom navigation。
2. 新增 `MapRecordScreen`
   - 放 map、layer toggles、record controls。
3. 新增 `PlanningScreen`
   - 放 map generation buttons、coverage settings、coverage result。
4. 新增 `ExecutionScreen`
   - 放 zone selector、start/cancel、operation log、Nav2 error panel。
5. 最後再由 `main.dart` 切入口。

UI 第一版重點是功能清楚與狀態正確，不做過度裝飾。

## 8. TDD Plan

### Phase 1: Domain Models

先寫 tests：

- `MissionState` 初始值與互斥狀態。
- `RosServiceResult` success/failure 建構。
- `OperationLogEntry` 時間、level、message 格式。
- `CoverageSettings` default、range validation。
- `ZoneSummary` 使用 int zone id。

再實作 models。

### Phase 2: Mock Adapter

先寫 tests：

- `callTrigger('/load_zone_list')` 回傳 success。
- 可以設定下一次 service failure。
- 可以設定 timeout。
- 可以 emit map layer / marker layer stream。
- `executeZone(1)` 使用 int zone id。

再實作 `RosAdapter` 與 `MockRosAdapter`。

### Phase 3: Mission Controller

先寫 tests：

- 初始 state 是 `idle` 或 adapter disconnected 時為 `disconnected`。
- `loadZones()` 成功後 state -> `zonesLoaded`。
- `createFreeSpace()` service success 後不立即進入 `freeSpaceReady`，必須等 `/free_space` topic update。
- `createRiskMap()` 必須在 `freeSpaceReady` 後才 enable。
- `generateCoverage()` 必須在 `riskMapReady` 後才 enable。
- 同一 service loading 時第二次 call 不會送出。
- service failure 會寫 error log 並 state -> `failed`。
- recording zone/risk/channel 互斥。
- `executeZone()` request 必須是 int zone id。

再實作 controller。

### Phase 4: Widgets

先寫 widget tests：

- `ServiceActionButton` busy 時 disabled 並顯示 loading。
- `OperationLogPanel` 顯示最近 log。
- `CoverageSettingsForm` 修改值後送出 valid settings。
- `ZoneSelector` 回傳 int zone id。
- `ExecutionScreen` 在 `coverageReady` 才 enable start。

再實作 widgets/screens。

### Phase 5: App Integration

先寫 integration-style widget tests：

- App 顯示 mission navigation。
- Mock success flow 可以走到 `coverageReady`。
- service failure 顯示錯誤訊息。
- cancel navigation 按鈕只在 executing 時 enable。

再把 `main.dart` 切到新的 screen/provider。

## 9. Git Workflow

使用者要求 Codex 自己具備 Git 工作流並自行 commit。Codex 後續遵守：

1. 每次開始修改前先看 `git status --short`。
2. 不 stage 使用者未要求的檔案。
3. 不 revert 使用者或 IDE 產生的變更。
4. 每個 phase 做小 commit。
5. commit 前跑相關測試。
6. 測試失敗時先修，不把失敗狀態 commit。
7. 若測試因環境問題不能跑，commit message 或回覆要明確標註。

建議 commit 切分：

```text
docs: add Flutter frontend TDD implementation plan
test: add mission domain model tests
feat: add mission domain models
test: add ROS adapter contract tests
feat: add mock ROS adapter
test: add mission controller tests
feat: add mission controller
feat: add MVP mission screens
test: replace default widget smoke test
```

Commit 原則：

- 文件 commit 只 stage Codex 新增或修改的 md。
- 功能 commit 只 stage 同一 phase 相關檔案。
- 若 `md/flutter_frontend_function_spec.md` 還是 untracked，除非使用者明確要求，不會放進 Codex commit。

## 10. 第一個實作建議

下一步應先做 Phase 1：

1. 移除或替換 counter template test。
2. 新增 mission domain model tests。
3. 實作 mission domain models。
4. 跑 `flutter test`。
5. Codex 自行 commit。

這樣後面接 adapter/controller/UI 時，狀態規則會先被 tests 固定住。

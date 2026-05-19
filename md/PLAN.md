# 手動遙控 Overlay 設計

## Summary
- 將目前「手動控制 bottom sheet」改成地圖主畫面上的全螢幕遙控 overlay。
- 進入方式沿用右側手把按鈕：點一下進入遙控模式，再用退出/停止回一般地圖。
- 遙控模式主畫面顯示前鏡頭，右上角縮小顯示正方形地圖；可用按鈕切換前/後鏡頭。
- 兩個搖桿控制 `/joy_cmd`，沿用目前 rosbridge publish `geometry_msgs/msg/TwistStamped`。

## Key Changes
- UI 佈局：
  - 一般模式維持目前全螢幕地圖 + 底部 panel。
  - 手動模式時隱藏底部 panel，主畫面改成 camera feed。
  - 右上角放固定正方形 mini map，內容沿用 `MissionMapCanvas`，但用較小 inset/尺寸。
  - 左下放線速度搖桿，右下放角速度搖桿；中央或底部放停止鍵。
  - 右上/上方放「前/後鏡頭切換」與「退出手動」按鈕。

- Camera data：
  - 透過 rosbridge 訂閱 ROS image topics。
  - 預設前鏡頭：`/front_depth_camera/image_raw`
  - 預設後鏡頭：`/back_camera/image_raw`
  - type：`sensor_msgs/msg/Image`
  - 前鏡頭為預設顯示；按切換後改顯示後鏡頭。
  - v1 解碼支援 `rgb8`、`bgr8`、`rgba8`、`bgra8`、`mono8`；不支援格式時顯示「影像格式未支援」狀態。

- Joystick behavior：
  - 左搖桿只取 Y 軸：上推 `linear.x > 0`，下拉 `linear.x < 0`。
  - 右搖桿只取 X 軸：左推 `angular.z > 0`，右推 `angular.z < 0`。
  - 最大值沿用目前安全值：`linear.x = ±0.22`、`angular.z = ±0.75`。
  - 搖桿釋放、退出手動模式、widget dispose 時都送一次 zero TwistStamped。
  - 發送頻率沿用目前 `100ms` interval。

- State/API：
  - `HomeScreen` 增加手動 overlay 狀態與目前鏡頭方向狀態。
  - `MissionMockProvider` 增加 camera frame 狀態：front/rear 最新影像、影像連線/錯誤狀態。
  - `RosbridgeService` 現有 subscribe/publish 能沿用；必要時只補 image data decode helper，不改既有 service call API。
  - 移除或停用 `_ManualControlSheet` 入口，避免再開頁/開 sheet。

## Test Plan
- `flutter analyze`
- `flutter test`
- 手動驗證：
  - 點右側手把進入手動模式，底部 panel 消失，主畫面是前鏡頭，右上角是正方形地圖。
  - 前/後鏡頭切換可切到 `/back_camera/image_raw`。
  - rosbridge 未連線時搖桿不可送或顯示連線提示。
  - rosbridge 已連線時左/右搖桿持續 publish `/joy_cmd`，放開立即送 zero。
  - 退出手動模式一定停止車體命令。

## Assumptions
- 前鏡頭 topic 使用 `/front_depth_camera/image_raw`，後鏡頭 topic 使用 `/back_camera/image_raw`。
- 控制輸出維持目前 `/joy_cmd` + `geometry_msgs/msg/TwistStamped`，不改後端 twist_mux。
- 手動模式是 overlay，不新增獨立頁面，也不新增底部 mode tab。

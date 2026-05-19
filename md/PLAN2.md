# 首頁儀表板與天氣概況

## Summary
- 將自檢後的主畫面改成截圖風格的 Home dashboard，底部加入「首頁 / 地圖 / 手動控制 / 排程 / 更多」導覽。
- 現有地圖控制台保留，移到「地圖」tab。
- 天氣使用割草機 GPS 座標串 Open-Meteo。官方文件支援 current temperature、relative humidity、weather code 等欄位，且基本用法不需 API key：[Open-Meteo Docs](https://open-meteo.com/en/docs)、[Open-Meteo](https://open-meteo.com/)。

## Key Changes
- 新增天氣資料層：
  - `WeatherSnapshot`：氣溫、體感、濕度、天氣代碼、狀態文字、風速、更新時間。
  - `WeatherService`：呼叫 `https://api.open-meteo.com/v1/forecast`，參數使用 `latitude`、`longitude`、`current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m`、`timezone=auto`。
  - `WeatherProvider`：由 `MowerStatusProvider.status.latitude/longitude` 更新位置；首次載入、每 15 分鐘、或位置明顯改變時刷新。失敗時保留最後成功資料，沒有快取時顯示「天氣暫不可用」。
- 重構首頁：
  - `HomeScreen` 保留目前自檢流程；完成後顯示新的 tab shell。
  - 將目前的 map-first 內容抽成 `MissionMapScreen`，放到「地圖」tab。
  - 「手動控制」tab 復用現有手動控制 UI；「排程」和「更多」先做輕量頁面，顯示排程卡與設定/狀態入口。
- 新 Home dashboard 視覺：
  - Header：`我的割草機`、`GM-3000`、通知 icon。
  - 卡片依序為：連線狀態、天氣概況、電量、目前任務、下次排程、充電座狀態。
  - 任務卡使用現有 `MissionMockProvider` 的 selected zone、`coverageProgress`、`navStatusLabel()`；面積先用 dashboard mock total `1200 m²`，完成/剩餘由進度換算。
  - 天氣卡顯示氣溫、狀態、濕度、風速與更新時間，並以小字標示 Open-Meteo attribution。

## Test Plan
- 更新 widget test：自檢完成後看到 `我的割草機`、底部五個 tab、天氣卡 loading/fallback 狀態。
- 新增天氣 service/provider 測試：解析 Open-Meteo JSON、weather code 轉中文狀態、API 失敗保留快取。
- 驗證「地圖」tab 仍顯示原本任務模式列：物件、記錄、規劃、執行、日誌。
- 執行 `flutter test` 與 `flutter analyze`。

## Assumptions
- 保留現有「任務自檢」入口，只是自檢完成後進入新 dashboard，不再直接進地圖。
- 天氣位置使用割草機 GPS；若 status 尚未載入，先用專案預設台北座標。
- 這次不新增手機定位權限、不加入需要 API key 的服務。
- 面積與排程先做前端 mock 呈現；未來若 ROS/backend 提供實際 `area_m2` 或 schedule topic，再替換資料來源。

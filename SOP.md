# Azure AI Speech Container 完全離線部署 SOP

本 SOP 說明如何使用 `build-speech-offline-package.ps1` 在有網路的機器上建立 Azure AI Speech disconnected container package，並在 Windows 或 Linux 完全離線環境中部署、更新與 rollback。

查閱日期：2026-07-06。

## 目錄

1. [適用範圍與限制](#1-適用範圍與限制)
2. [Azure 與授權前置作業](#2-azure-與授權前置作業)
3. [線上打包機前置需求](#3-線上打包機前置需求)
4. [執行 build-speech-offline-package.ps1](#4-執行-build-speech-offline-packageps1)
5. [Windows 離線部署](#5-windows-離線部署)
6. [Linux 離線部署](#6-linux-離線部署)
7. [更新與 rollback](#7-更新與-rollback)
8. [應用程式串接方式](#8-應用程式串接方式)
9. [Usage records 與維運注意事項](#9-usage-records-與維運注意事項)
10. [常見問題排除](#10-常見問題排除)
11. [參考文件](#11-參考文件)

---

# 1. 適用範圍與限制

## 1.1 支援的 Speech containers

本 repo 的 script 支援下列 Microsoft Speech disconnected containers：

- `speech-to-text`
- `custom-speech-to-text`
- `neural-text-to-speech`

對應 image repository：

```text
mcr.microsoft.com/azure-cognitive-services/speechservices/speech-to-text
mcr.microsoft.com/azure-cognitive-services/speechservices/custom-speech-to-text
mcr.microsoft.com/azure-cognitive-services/speechservices/neural-text-to-speech
```

## 1.2 不支援的 Speech container

`speech language identification` 不納入本 SOP。Microsoft 官方 Speech containers overview 註明 Speech language identification preview container `Not available as a disconnected container`。

## 1.3 完全離線不等於免授權

Speech disconnected container 仍需要 Microsoft 核准、disconnected commitment tier、license file 與 usage records。離線執行時 container 不連 Azure，但必須把 license 掛載到 `/license`，並把 usage records 寫到 `/output`。

## 1.4 image tag 與 locale/voice

Speech container 的 locale 或 voice 通常由 image tag 決定：

- `speech-to-text:latest` 依官方文件會拉 `en-US` locale。
- `neural-text-to-speech:latest` 依官方文件會拉 `en-US` / `en-US-AriaNeural`。
- `custom-speech-to-text` 的 locale 由下載到 container 的 custom/base model 決定。

正式交付建議使用明確 tag，不建議長期使用 `latest`，避免不同時間打包出來的內容不一致。

---

# 2. Azure 與授權前置作業

## 2.1 申請 disconnected containers access

在嘗試離線執行前，必須先向 Microsoft 提交 disconnected containers request form，並等待核准。官方文件說明審核通常會由 Microsoft 團隊透過 email 回覆。

申請時請注意：

- 使用與 Azure subscription ID 綁定的 email。
- 執行 container 的 Azure resource 必須建立在核准的 subscription 下。
- 核准後才會看到 disconnected commitment tier 相關選項。

## 2.2 建立 disconnected commitment tier Speech resource

Speech container license/runtime 使用的 resource 必須是 disconnected commitment tier。SOP 與 script 中稱為：

```text
SPEECH_LICENSE_KEY
SPEECH_LICENSE_ENDPOINT_URI
```

這組 key/endpoint 用於下載 disconnected license。離線 runtime compose 不會把 key/endpoint 放進 package。

## 2.3 Custom Speech to text 額外需求

`custom-speech-to-text` 比一般 STT / NTTS 多一個 model 下載步驟。Microsoft 文件要求 Custom STT disconnected 準備流程使用兩個 Speech resource：

- Regular Speech resource：S0 或 Speech to Text Custom commitment tier，用於下載 custom/base model。
- Disconnected commitment Speech resource：用於下載 disconnected license 與離線 runtime。

script 中對應名稱：

```text
SPEECH_MODEL_KEY
SPEECH_MODEL_ENDPOINT_URI
MODEL_ID
SPEECH_LICENSE_KEY
SPEECH_LICENSE_ENDPOINT_URI
```

### 2.3.1 查詢 `SPEECH_MODEL_KEY`

`SPEECH_MODEL_KEY` 必須來自存放 custom/base model 的 **Regular Speech resource**（S0 或 Speech to Text Custom commitment tier），不能使用 DC0 disconnected resource 的 key。

1. 登入 [Azure Portal](https://portal.azure.com)。
2. 開啟存放模型的專用 Speech resource。
3. 確認 resource type/kind 是 `SpeechServices`，pricing tier 是 `S0` 或 Speech to Text Custom commitment tier。
4. 在左側選單開啟 **Keys and Endpoint**。
5. 複製 `KEY 1` 或 `KEY 2`，作為 `SPEECH_MODEL_KEY`。

請勿將 key 寫入 SOP、Git、截圖或一般 log。互動執行 script 時，key 不會顯示在 console。

### 2.3.2 查詢 `SPEECH_MODEL_ENDPOINT_URI`

在同一個 Speech resource 的 **Keys and Endpoint** 頁面，複製 `Endpoint` 欄位的完整 URL，作為 `SPEECH_MODEL_ENDPOINT_URI`，例如：

```text
https://<speech-resource-name>.cognitiveservices.azure.com/
```

實際格式可能是區域 endpoint；請以 Azure Portal 顯示的值為準，不要自行猜測或手動改成其他 region。這個 endpoint 必須與 `SPEECH_MODEL_KEY` 來自同一個 Speech resource，也不是 Custom Speech **Deploy models** 頁面顯示的 REST/WebSocket endpoint。

### 2.3.3 查詢 `MODEL_ID`

1. 登入 [Speech Studio](https://speech.microsoft.com/portal)。
2. 在右上角選擇 subscription 與存放模型的專用 Speech resource。
3. 進入 **Custom speech**，開啟對應 locale 的 project。
4. 進入 **Train custom models**。
5. 開啟狀態為 `Succeeded` 的模型，在 model detail 複製 **Model ID**，作為 `MODEL_ID`。

`MODEL_ID` 是 custom/base model 的 ID，不是下列值：

- Custom Speech project ID。
- **Deploy models** 頁面的 Endpoint ID。
- **Calling the custom endpoint** 中 REST/WebSocket URL 的 `cid`。

若模型是從舊 resource 複製到新的專用 Speech resource，請使用複製後模型的新 `MODEL_ID`，並搭配目標 Speech resource 的 key 與 endpoint。

### 2.3.4 執行前核對

三個 model 參數必須指向同一個 Regular Speech resource：

```text
SPEECH_MODEL_KEY          = 專用 S0 Speech resource 的 KEY 1 或 KEY 2
SPEECH_MODEL_ENDPOINT_URI = 同一個專用 S0 Speech resource 的 Endpoint
MODEL_ID                  = 同一個專用 S0 Speech resource 內的模型 ID
```

下載 disconnected license 則使用另一組 DC0 resource 參數：

```text
SPEECH_LICENSE_KEY
SPEECH_LICENSE_ENDPOINT_URI
```

不要交叉混用 model resource 與 license resource 的 key/endpoint。

---

# 3. 線上打包機前置需求

線上打包機需要：

- Windows 10/11 或可執行 PowerShell 與 Docker 的環境。
- Docker Desktop 或 Docker Engine。
- Docker 已啟動，且可 pull `mcr.microsoft.com`。
- 可連到 Azure Speech resource endpoint。
- 可使用 `tar` 指令。
- 有足夠磁碟空間保存 Docker image tar 與 package。

檢查 Docker：

```powershell
docker version
```

檢查 Docker Compose plugin，離線端會用到：

```powershell
docker compose version
```

檢查 MCR 連線：

```powershell
Test-NetConnection mcr.microsoft.com -Port 443
```

檢查 AVX2。Microsoft Speech containers 要求 host CPU 支援 AVX2；Linux 可用官方建議指令檢查：

```bash
grep -q avx2 /proc/cpuinfo && echo AVX2 supported || echo No AVX2 support detected
```

Windows 可用下列方式初步確認 CPU 型號，再依 CPU spec 核對 AVX2：

```powershell
Get-CimInstance Win32_Processor | Select-Object Name
```

---

# 4. 執行 build-speech-offline-package.ps1

## 4.1 進入 repo

```powershell
cd D:\CodexProject\speech-container-offline-package
```

若 PowerShell execution policy 阻擋本次執行，可只對目前程序開放：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## 4.2 互動模式

```powershell
.\build-speech-offline-package.ps1
```

script 會要求選擇：

```text
1) speech-to-text
2) custom-speech-to-text
3) neural-text-to-speech
```

接著輸入 image tag、離線 runtime host port、resource key、endpoint 等資訊。未透過 `-Port` 指定時，script 會在下載前詢問：

```text
OFFLINE_RUNTIME_HOST_PORT [5000]:
```

直接按 Enter 會使用 host port `5000`。例如輸入 `5001`，產出的 Compose 會設定 `"5001:5000"`，也就是 host `5001` 對應 container 內固定的 `5000`。這個設定只影響產出的 `run-disconnected-container-docker-compose.yaml`；model/license 下載 container 會使用獨立的臨時 port。非互動執行可直接加上 `-Port 5001`。

選擇 `speech-to-text` 時，script 會向 MCR 即時查詢並顯示 `zh-TW` 與 `en-US` 各自最新的 stable amd64 tag：

```text
Querying Microsoft Container Registry for Speech to text tags...
Latest stable amd64 tags:
  1) zh-TW  5.4.0-amd64-zh-tw
  2) en-US  5.4.0-amd64-en-us
  3) Enter an image tag manually
```

每次執行只會打包一個 locale。若中文與英文都需要，請分別選擇後執行兩次。選單中的實際版本以執行當下 MCR 回傳為準；若已透過 `-Tag` 指定 tag，script 會略過 MCR 選單。

## 4.3 非互動範例：Speech to text

```powershell
.\build-speech-offline-package.ps1 `
  -Container speech-to-text `
  -Tag latest `
  -Memory 8g `
  -Cpus 4 `
  -Port 5000
```

依提示輸入 disconnected Speech resource：

```text
SPEECH_LICENSE_KEY
SPEECH_LICENSE_ENDPOINT_URI
```

若要避免互動輸入 endpoint，可先設定環境變數：

```powershell
$env:SPEECH_LICENSE_ENDPOINT_URI = "https://<resource-name>.cognitiveservices.azure.com"
```

key 也可放環境變數，但不建議長期保存：

```powershell
$env:SPEECH_LICENSE_KEY = "<key>"
```

## 4.4 非互動範例：Neural text to speech

```powershell
.\build-speech-offline-package.ps1 `
  -Container neural-text-to-speech `
  -Tag latest `
  -Memory 16g `
  -Cpus 8 `
  -Port 5000
```

正式環境建議改用明確 voice tag，例如依 MCR tags 選定特定 locale/voice。

## 4.5 非互動範例：Custom speech to text

```powershell
.\build-speech-offline-package.ps1 `
  -Container custom-speech-to-text `
  -Tag latest `
  -ModelId "<custom-or-base-model-id>" `
  -Memory 8g `
  -Cpus 4 `
  -Port 5000
```

script 會先使用 regular Speech resource 下載 model，再使用 disconnected commitment Speech resource 下載 license。

依提示輸入：

```text
SPEECH_MODEL_KEY
SPEECH_MODEL_ENDPOINT_URI
SPEECH_LICENSE_KEY
SPEECH_LICENSE_ENDPOINT_URI
```

若 model 已經預先下載到 `azure-ai-speech\models`，可使用：

```powershell
.\build-speech-offline-package.ps1 `
  -Container custom-speech-to-text `
  -SkipCustomModelDownload
```

## 4.6 預期輸出

成功後只保留：

```text
archive\package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz
archive\package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.log
archive\package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.sha256
```

Speech-to-text 的 `<language-code>` 會依所選 image tag 自動填入 `zh-tw` 或 `en-us`；build log 與 checksum 一律使用完整 package 檔名加上 `.log` 與 `.sha256`。

package 內容大致如下：

```text
archive\
  oci-azure-ai-speech-to-text-<language-code>.tar
  run-disconnected-container-docker-compose.yaml
  package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.log
azure-ai-speech\
  license\
  output\
  models\                  # custom-speech-to-text 才會有
package-manifest.txt
```

檢查 SHA256：

```powershell
$languageCode = "zh-tw" # Change to en-us when verifying that package.
$pkg = Get-ChildItem ".\archive\package-azure-ai-speech-to-text-$languageCode-container-*.tar.gz" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$shaFile = Get-Item "$($pkg.FullName).sha256"

Get-Content $shaFile.FullName
Get-FileHash $pkg.FullName -Algorithm SHA256
```

---

# 5. Windows 離線部署

## 5.1 建議目錄結構

離線 Windows server 建議用 release 目錄管理版本：

```text
C:\AzureAISpeechOffline
  releases\
    20260706_150000\
```

建立 release 目錄：

```powershell
$ReleaseDir = "C:\AzureAISpeechOffline\releases\20260706_150000"
New-Item -ItemType Directory -Path $ReleaseDir -Force
```

將下列檔案複製到 release 目錄：

```text
package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz
package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.log
package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.sha256

package-azure-ai-<other-speech-container>-container-<timestamp>.tar.gz
package-azure-ai-<other-speech-container>-container-<timestamp>.tar.gz.log
package-azure-ai-<other-speech-container>-container-<timestamp>.tar.gz.sha256
```

切換目錄：

```powershell
cd $ReleaseDir
```

## 5.2 驗證 package

```powershell
$languageCode = "zh-tw" # Change to en-us when verifying that package.
$pkg = Get-ChildItem ".\package-azure-ai-speech-to-text-$languageCode-container-*.tar.gz" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$shaFile = Get-Item "$($pkg.FullName).sha256"

Get-Content $shaFile.FullName
Get-FileHash $pkg.FullName -Algorithm SHA256
```

確認 `Get-FileHash` 的值與 `$shaFile` 指定的 checksum 檔一致。

## 5.3 解壓 package

```powershell
tar -xzf $pkg.FullName -C .
```

確認必要檔案：

```powershell
Test-Path .\archive\run-disconnected-container-docker-compose.yaml
Test-Path .\azure-ai-speech\license
Test-Path .\azure-ai-speech\output
```

Custom STT 另需確認：

```powershell
Test-Path .\azure-ai-speech\models
```

## 5.4 載入 Docker image

```powershell
$imageTar = Get-ChildItem .\archive\oci-azure-ai-*.tar |
  Select-Object -First 1

docker load -i $imageTar.FullName
```

確認 image：

```powershell
docker images | Select-String "azure-cognitive-services/speechservices"
```

## 5.5 啟動 container

重要：請在 package 解壓根目錄執行，並加上 `--project-directory .`，確保 compose 裡的相對 volume path 指到目前 release 目錄。

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  up -d
```

確認 container：

```powershell
docker ps --filter "name=azure-ai-speech"
```

查看 log：

```powershell
docker logs azure-ai-speech-stt
docker logs azure-ai-speech-custom-stt
docker logs azure-ai-speech-ntts
```

三個指令只會有一個符合本次部署的 container。

## 5.6 驗證服務

通用 ready check：

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:5000/ready
```

通用 status check：

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:5000/status
```

查看 Swagger：

```powershell
Start-Process http://localhost:5000/swagger
```

離線 server 若不能開瀏覽器，可只保留 `/ready` 與 container log 驗證。

## 5.7 停止 container

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  down
```

---

# 6. Linux 離線部署

## 6.1 前置需求

Linux 離線 server 需要：

- Docker Engine。
- Docker Compose plugin。
- `tar`。
- CPU 支援 AVX2。
- 可綁定打包時選擇的 host port；未指定時預設為 `5000`。

確認：

```bash
docker version
docker compose version
grep -q avx2 /proc/cpuinfo && echo AVX2 supported || echo No AVX2 support detected
```

## 6.2 建議目錄結構

```text
/opt/azure-ai-speech-offline
  releases/
    20260706_150000/
```

建立 release 目錄：

```bash
sudo mkdir -p /opt/azure-ai-speech-offline/releases/20260706_150000
sudo chown -R "$USER":"$USER" /opt/azure-ai-speech-offline
cd /opt/azure-ai-speech-offline/releases/20260706_150000
```

將 package、同名的 `.log` build log 與 `.sha256` checksum 檔放進此目錄；兩個 sidecar 檔名都會完整保留 package 名稱。

## 6.3 驗證 package

```bash
LANGUAGE_CODE="zh-tw" # Change to en-us when verifying that package.
PACKAGE="$(ls -t package-azure-ai-speech-to-text-${LANGUAGE_CODE}-container-*.tar.gz | head -n 1)"
SHA_FILE="${PACKAGE}.sha256"
sha256sum -c "$SHA_FILE"
```

若 package 檔名被修改，改用手動比對：

```bash
sha256sum "$PACKAGE"
cat "$SHA_FILE"
```

## 6.4 解壓 package

```bash
PKG="$(ls -t package-azure-ai-*-container-*.tar.gz | head -n 1)"
tar -xzf "$PKG" -C .
```

確認必要檔案：

```bash
test -f ./archive/run-disconnected-container-docker-compose.yaml
test -d ./azure-ai-speech/license
test -d ./azure-ai-speech/output
```

Custom STT 另需確認：

```bash
test -d ./azure-ai-speech/models
```

## 6.5 權限注意事項

Microsoft 文件提醒，Speech container 掛載 `/license` 與 `/output` 時，host 端目錄要能讓 container 內的 nonroot user 寫入。

若 container log 顯示 license/output permission denied，請依客戶 Linux 權限政策調整。常見處理方式：

```bash
sudo chown -R nonroot:nonroot ./azure-ai-speech/license ./azure-ai-speech/output
```

若 host 沒有 `nonroot` user/group，請依實際 container runtime policy 設定可寫 UID/GID，或由平台管理員提供對應 mapping。

## 6.6 載入 Docker image

```bash
IMAGE_TAR="$(ls ./archive/oci-azure-ai-*.tar | head -n 1)"
docker load -i "$IMAGE_TAR"
```

確認 image：

```bash
docker images | grep 'azure-cognitive-services/speechservices'
```

## 6.7 啟動 container

請在 package 解壓根目錄執行：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  up -d
```

確認 container：

```bash
docker ps --filter "name=azure-ai-speech"
```

查看 log：

```bash
docker logs azure-ai-speech-stt
docker logs azure-ai-speech-custom-stt
docker logs azure-ai-speech-ntts
```

三個指令只會有一個符合本次部署的 container。

## 6.8 驗證服務

```bash
curl -fsS http://localhost:5000/ready
curl -fsS http://localhost:5000/status
```

若離線環境允許，可從瀏覽器開：

```text
http://localhost:5000/swagger
```

## 6.9 停止 container

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

---

# 7. 更新與 rollback

## 7.1 更新原則

不要把新版 package 直接解壓覆蓋舊版目錄。請使用 release 目錄保留 rollback 能力。

Windows：

```text
C:\AzureAISpeechOffline
  releases\
    20260701_120000\   # 舊版
    20260706_150000\   # 新版
```

Linux：

```text
/opt/azure-ai-speech-offline
  releases/
    20260701_120000/   # 舊版
    20260706_150000/   # 新版
```

## 7.2 更新流程

1. 在新版 release 目錄驗證 SHA256。
2. 解壓新版 package。
3. 停止舊版 container。
4. 在新版 release 目錄 `docker load` 新 image。
5. 使用新版 compose 啟動 container。
6. 驗證 `/ready`、`/status`、應用程式測試案例。

Windows 停止舊版：

```powershell
cd C:\AzureAISpeechOffline\releases\20260701_120000
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml down
```

Windows 啟動新版：

```powershell
cd C:\AzureAISpeechOffline\releases\20260706_150000
$imageTar = Get-ChildItem .\archive\oci-azure-ai-*.tar | Select-Object -First 1
docker load -i $imageTar.FullName
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml up -d
```

Linux 停止舊版：

```bash
cd /opt/azure-ai-speech-offline/releases/20260701_120000
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml down
```

Linux 啟動新版：

```bash
cd /opt/azure-ai-speech-offline/releases/20260706_150000
docker load -i "$(ls ./archive/oci-azure-ai-*.tar | head -n 1)"
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml up -d
```

## 7.3 Rollback

若新版驗證失敗：

1. 停止新版 container。
2. 切回舊版 release 目錄。
3. 重新 `docker load` 舊版 image。
4. 使用舊版 compose 啟動。

Windows：

```powershell
cd C:\AzureAISpeechOffline\releases\20260706_150000
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml down

cd C:\AzureAISpeechOffline\releases\20260701_120000
$imageTar = Get-ChildItem .\archive\oci-azure-ai-*.tar | Select-Object -First 1
docker load -i $imageTar.FullName
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml up -d
```

Linux：

```bash
cd /opt/azure-ai-speech-offline/releases/20260706_150000
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml down

cd /opt/azure-ai-speech-offline/releases/20260701_120000
docker load -i "$(ls ./archive/oci-azure-ai-*.tar | head -n 1)"
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml up -d
```

---

# 8. 應用程式串接方式

## 8.1 Speech to text / Custom speech to text

STT 與 Custom STT 使用 WebSocket host URL：

```text
ws://localhost:5000
```

應用程式必須使用 host authentication。不要使用 subscription key + region 初始化，否則 SDK 會連到 public Speech service；在完全離線環境會失敗。

C# 範例：

```csharp
var config = SpeechConfig.FromHost(new Uri("ws://localhost:5000"));
```

Python 範例：

```python
speech_config = speechsdk.SpeechConfig(host="ws://localhost:5000")
```

Speech CLI 範例：

```powershell
spx recognize --host ws://localhost:5000/ --key none --file sample.wav
```

## 8.2 Neural text to speech

NTTS 使用 HTTP host URL：

```text
http://localhost:5000
```

C# 範例：

```csharp
var config = SpeechConfig.FromHost(new Uri("http://localhost:5000"));
```

Python 範例：

```python
speech_config = speechsdk.SpeechConfig(host="http://localhost:5000")
```

Speech CLI 範例：

```powershell
spx synthesize --host http://localhost:5000/ --key none --text "Hello"
```

NTTS 的 SSML `voice name` 必須與 container image 的 locale/voice 對應。例如 en-US AriaNeural：

```xml
<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">
  <voice name="en-US-AriaNeural">Hello</voice>
</speak>
```

---

# 9. Usage records 與維運注意事項

## 9.1 Usage records 位置

離線 runtime compose 會掛載：

```yaml
volumes:
  - ./azure-ai-speech/output:/output
```

container 會把 usage records 寫到 `azure-ai-speech/output`。請將此目錄納入維運備份與稽核流程，不要在更新或清理時誤刪。

## 9.2 查詢 usage records

可查詢全部 usage summary：

```powershell
Invoke-RestMethod http://localhost:5000/records/usage-logs/
```

Linux：

```bash
curl -sS http://localhost:5000/records/usage-logs/
```

也可查詢指定月份與年份：

```text
http://localhost:5000/records/usage-logs/{MONTH}/{YEAR}
```

## 9.3 license 更新

Microsoft 文件提醒，license file 會用來解密 container image 中的特定檔案；如果更新 image，舊 license 可能不適用。每次更新 image version 或 custom model 時，建議重新下載 license 並重新打包。

---

# 10. 常見問題排除

## 問題 1：license 下載失敗

常見原因：

- Subscription 尚未通過 disconnected container approval。
- Speech resource 不是 disconnected commitment tier。
- key 或 endpoint 錯誤。
- 使用了不對應的 container 或 model。
- Azure resource 建立在未核准的 subscription。

處理：

```powershell
Test-NetConnection mcr.microsoft.com -Port 443
```

確認 Azure Portal 中 Speech resource 的 pricing tier 與 Keys and Endpoint。

## 問題 2：Custom STT model 下載失敗

常見原因：

- 使用 disconnected resource 下載 model，而不是 regular Speech resource。
- `MODEL_ID` 錯誤。
- custom model 未完成訓練或未在該 resource/subscription 下。
- port `5000` 被占用，model download container 無法啟動。

處理：

```powershell
docker ps -a --filter "name=speech-model-download"
docker logs <container-name>
```

## 問題 3：container 啟動後立刻退出

檢查 log：

```powershell
docker ps -a --filter "name=azure-ai-speech"
docker logs azure-ai-speech-stt
docker logs azure-ai-speech-custom-stt
docker logs azure-ai-speech-ntts
```

確認掛載目錄：

```powershell
Test-Path .\azure-ai-speech\license
Test-Path .\azure-ai-speech\output
```

Custom STT 另確認：

```powershell
Test-Path .\azure-ai-speech\models
```

## 問題 4：`/ready` 失敗

可能原因：

- model 載入時間較長。
- host CPU 不支援 AVX2。
- memory/cpu 限制太小。
- license 過期或不對應 image/model。

處理：

```powershell
docker logs <container-name>
```

必要時調整 `archive\run-disconnected-container-docker-compose.yaml`：

```yaml
mem_limit: 16g
cpus: "8"
```

## 問題 5：應用程式仍嘗試連 Azure

請確認 SDK 初始化方式。離線環境必須使用 host：

```csharp
SpeechConfig.FromHost(new Uri("ws://localhost:5000"));
SpeechConfig.FromHost(new Uri("http://localhost:5000"));
```

不要使用：

```csharp
SpeechConfig.FromSubscription(...);
```

Speech CLI 必須加：

```text
--key none
```

## 問題 6：port 5000 被占用

Windows：

```powershell
Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, State, OwningProcess
```

Linux：

```bash
sudo ss -ltnp | grep ':5000'
```

建議重新打包並指定 `-Port 5001`；若 package 已交付，也可以直接修改 compose：

```yaml
ports:
  - "5001:5000"
```

STT / Custom STT host 改為：

```text
ws://localhost:5001
```

NTTS host 改為：

```text
http://localhost:5001
```

---

# 11. 參考文件

- [Speech containers overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-overview)
- [Install and run Speech containers with Docker](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-howto)
- [Use Docker containers in disconnected environments](https://learn.microsoft.com/en-us/azure/ai-services/containers/disconnected-containers)
- [Speech to text containers with Docker](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-stt)
- [Custom speech to text containers with Docker](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-cstt)
- [Neural text to speech containers with Docker](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-ntts)
- [Microsoft Container Registry: Speech to text tags](https://mcr.microsoft.com/v2/azure-cognitive-services/speechservices/speech-to-text/tags/list)
- [Microsoft Container Registry: Custom speech to text tags](https://mcr.microsoft.com/v2/azure-cognitive-services/speechservices/custom-speech-to-text/tags/list)
- [Microsoft Container Registry: Neural text to speech tags](https://mcr.microsoft.com/v2/azure-cognitive-services/speechservices/neural-text-to-speech/tags/list)

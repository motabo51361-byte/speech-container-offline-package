# Azure AI Speech Offline Package Builder

本 repo 提供 `build-speech-offline-package.ps1`，用於在有網路的 Windows + Docker 環境中下載 Azure AI Speech disconnected container 所需的 image、license，以及 Custom Speech model，並打包成可帶到完全離線環境執行的交付檔。

支援的 container：

- `speech-to-text`
- `custom-speech-to-text`
- `neural-text-to-speech`

不支援：

- `speech language identification`，Microsoft 官方 Speech containers overview 註明此 container 不提供 disconnected container。

## 快速使用

```powershell
cd D:\CodexProject\speech-container-offline-package
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\build-speech-offline-package.ps1
```

選擇 `speech-to-text` 時，script 會直接向 MCR 查詢並顯示 `zh-TW` 與 `en-US` 各自最新的 stable tag。每次執行打包一個 locale；若兩種都需要，分別選擇後執行兩次。使用 `-Tag` 時不會顯示選單，而是直接使用指定 tag。

成功後會留下：

```text
archive\log-build-speech-offline-package_<language-code>_<timestamp>.log
archive\package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz
archive\oci-azure-ai-speech-to-text-<language-code>.tar
archive\package-azure-ai-speech-to-text-<language-code>-container-<timestamp>.tar.gz.sha256
```

Speech-to-text 的 `<language-code>` 會是 `zh-tw` 或 `en-us`；checksum 檔一律在對應 package 的完整檔名後加上 `.sha256`。

完整線上打包、Windows/Linux 離線部署、更新與 rollback 流程請看 [SOP.md](SOP.md)。

## 重要限制

- 完全離線執行前，必須先向 Microsoft 申請 disconnected containers access，並建立 disconnected commitment tier 的 Speech resource。
- Speech container license 不是通用檔案；不同 container、model、image version 可能需要重新下載 license。
- 離線執行仍會產生 usage records，請保留 `azure-ai-speech/output`。
- SDK/CLI 必須使用 container host authentication，不要使用 subscription key + region 初始化，否則會打到雲端 Speech service。

## 官方文件

- [Speech containers overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-overview)
- [Install and run Speech containers with Docker](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-howto)
- [Use Docker containers in disconnected environments](https://learn.microsoft.com/en-us/azure/ai-services/containers/disconnected-containers)
- [Speech to text containers](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-stt)
- [Custom speech to text containers](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-cstt)
- [Neural text to speech containers](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-container-ntts)

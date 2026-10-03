#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "claude_launcher/native",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Окно не показываем при запуске: лаунчер живёт в трее, окно открывается из меню.
  // Первый кадр всё равно нужен, чтобы Dart-часть инициализировалась.
  flutter_controller_->ForceRedraw();

  return true;
}

// Просит Dart быстро и корректно выйти (`endSession`) и ждёт ответа до 4
// секунд, разбирая сообщения: ответ Dart приходит через очередь окна. Windows
// убьёт процесс, как только мы вернём управление.
void FlutterWindow::EndSession() {
  auto done = std::make_shared<bool>(false);
  native_channel_->InvokeMethod(
      "endSession", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [done](const flutter::EncodableValue*) { *done = true; },
          [done](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { *done = true; },
          [done]() { *done = true; }));
  const ULONGLONG deadline = ::GetTickCount64() + 4000;
  MSG msg;
  while (!*done && ::GetTickCount64() < deadline) {
    if (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    } else {
      ::Sleep(10);
    }
  }
}

void FlutterWindow::OnDestroy() {
  native_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Лаунчер запустили ещё раз (ярлык в «Пуске», автозапуск) — окно вперёд,
  // как на macOS: Dart покажет его тем же методом, что и пункт меню.
  if (message == ReopenMessage()) {
    if (native_channel_) native_channel_->InvokeMethod("reopen", nullptr);
    return 0;
  }
  // Ссылка `claude://` от второго запуска (Windows открыл её лаунчером как
  // обработчиком) — Dart отдаст её нужному профилю.
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data != nullptr && data->dwData == kOpenLinkData &&
        data->lpData != nullptr && native_channel_) {
      const std::wstring link(static_cast<const wchar_t*>(data->lpData),
                              data->cbData / sizeof(wchar_t));
      native_channel_->InvokeMethod(
          "openUrl",
          std::make_unique<flutter::EncodableValue>(Utf8FromUtf16(link.c_str())));
      return TRUE;
    }
  }
  if (message == QuitMessage()) {
    if (native_channel_) native_channel_->InvokeMethod("quit", nullptr);
    return 0;
  }
  // Windows завершает сеанс (выход, перезагрузка) или установщик закрывает
  // лаунчер (Restart Manager): иначе процесс просто убьют, без выхода.
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION) {
    if (wparam && native_channel_) EndSession();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

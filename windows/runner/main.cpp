#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Один лаунчер на пользователя: второй экземпляр дал бы вторую иконку в трее.
  // Кроме запуска с --cleanup от деинсталлятора и наблюдателя, который после
  // выхода из лаунчера возвращает Claude уведомления: они окна и трея не
  // создают, а лаунчер должен запускаться и при работающем наблюдателе.
  // Имя мьютекса знает и установщик (AppMutex), чтобы попросить закрыть лаунчер.
  const bool headless =
      wcsstr(command_line, L"--cleanup") != nullptr ||
      wcsstr(command_line, L"--return-claude-notifications") != nullptr;
  if (!headless) {
    ::CreateMutexW(nullptr, TRUE, L"Local\\ClaudeLauncher.SingleInstance");
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      // Будим уже запущенный лаунчер: он покажет окно. Право вывести окно
      // вперёд отдаём ему — у этого процесса оно есть, его запустил пользователь.
      ::AllowSetForegroundWindow(ASFW_ANY);
      ::PostMessageW(HWND_BROADCAST, ReopenMessage(), 0, 0);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(560, 640);
  if (!window.Create(L"ClaudeLauncher", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

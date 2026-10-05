#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// Ссылка после `--open-url` (Windows запускает так лаунчер как обработчик
// `claude://` и своей `claudelauncher://` — ярлыков профилей): от `claude` до
// кавычки или конца строки. Пусто — флага нет.
static std::wstring OpenUrlArgument(const wchar_t* command_line) {
  const wchar_t* flag = wcsstr(command_line, L"--open-url");
  if (flag == nullptr) return L"";
  const wchar_t* start = wcsstr(flag, L"claude");
  if (start == nullptr) return L"";
  const wchar_t* end = start;
  while (*end != L'\0' && *end != L'"') ++end;
  return std::wstring(start, end);
}

// Передать ссылку уже работающему лаунчеру. Его окно скрыто, но FindWindow
// находит и скрытые. false — окна нет (лаунчер ещё не создал его).
static bool ForwardLink(const std::wstring& link) {
  HWND target = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ClaudeLauncher");
  if (target == nullptr) return false;
  COPYDATASTRUCT data{};
  data.dwData = kOpenLinkData;
  data.cbData = static_cast<DWORD>((link.size() + 1) * sizeof(wchar_t));
  data.lpData = const_cast<wchar_t*>(link.c_str());
  DWORD_PTR result = 0;
  return ::SendMessageTimeoutW(target, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                               5000, &result) != 0;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Один лаунчер на пользователя: второй экземпляр дал бы вторую иконку в трее.
  // Кроме запуска с --cleanup от деинсталлятора и наблюдателя, который после
  // выхода из лаунчера возвращает Claude уведомления: они окна и трея не
  // создают, а лаунчер должен запускаться и при работающем наблюдателе.
  // Имя мьютекса знает и установщик (AppMutex), чтобы попросить закрыть лаунчер.
  // `--quit` — попросить запущенный лаунчер выйти, как из меню, и дождаться
  // его (до 10 секунд). Так его закрывает команда установки (install.ps1).
  // Код выхода 1 — не вышел.
  if (wcsstr(command_line, L"--quit") != nullptr) {
    HANDLE running = ::OpenMutexW(SYNCHRONIZE, FALSE,
                                  L"Local\\ClaudeLauncher.SingleInstance");
    if (running == nullptr) return EXIT_SUCCESS;  // Не запущен.
    ::PostMessageW(HWND_BROADCAST, QuitMessage(), 0, 0);
    // Лаунчер держит мьютекс до выхода: при выходе он «брошен» — дождались.
    const DWORD waited = ::WaitForSingleObject(running, 10000);
    if (waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED) {
      ::ReleaseMutex(running);
    }
    ::CloseHandle(running);
    return waited == WAIT_TIMEOUT ? 1 : EXIT_SUCCESS;
  }

  const bool headless =
      wcsstr(command_line, L"--cleanup") != nullptr ||
      wcsstr(command_line, L"--return-claude-notifications") != nullptr ||
      wcsstr(command_line, L"--kill-switch-guard") != nullptr;
  // Охранник Kill Switch держит свой мьютекс: по нему установщик видит, что
  // он работает, и просит закрыть, а не завершает его молча.
  if (wcsstr(command_line, L"--kill-switch-guard") != nullptr) {
    ::CreateMutexW(nullptr, TRUE, L"Local\\ClaudeLauncher.KillSwitchGuard");
  }
  if (!headless) {
    ::CreateMutexW(nullptr, TRUE, L"Local\\ClaudeLauncher.SingleInstance");
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      // Будим уже запущенный лаунчер: он покажет окно. Право вывести окно
      // вперёд отдаём ему — у этого процесса оно есть, его запустил пользователь.
      ::AllowSetForegroundWindow(ASFW_ANY);
      const std::wstring link = OpenUrlArgument(command_line);
      if (link.empty() || !ForwardLink(link)) {
        ::PostMessageW(HWND_BROADCAST, ReopenMessage(), 0, 0);
      }
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

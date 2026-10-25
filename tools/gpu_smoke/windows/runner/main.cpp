#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_enable_flutter_gpu(true);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // A test tool runs unattended (as the player's --background=on): a small
  // window in the work area's bottom-right corner that never activates or
  // takes focus. --show shows a normal window.
  bool show = false;
  for (const auto& a : command_line_arguments) {
    if (a == "--show") show = true;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!show) {
    const unsigned w = 160, h = 90;
    RECT work{};
    SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
    HMONITOR monitor = MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
    const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    const double right = work.right / scale, bottom = work.bottom / scale;
    size = Win32Window::Size(w, h);
    origin = Win32Window::Point(
        static_cast<unsigned>(right > w + 12 ? right - w - 12 : 0),
        static_cast<unsigned>(bottom > h + 12 ? bottom - h - 12 : 0));
  }
  window.SetBackground(!show);
  if (!window.Create(L"gpu_smoke", origin, size)) {
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

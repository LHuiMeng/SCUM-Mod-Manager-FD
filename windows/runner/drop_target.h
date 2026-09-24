#pragma warning(disable:4819)
#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <windows.h>
#include <shobjidl.h>

#include <string>
#include <vector>

// Forward declare to avoid pulling in flutter headers in this lightweight header.
namespace flutter { class BinaryMessenger; }

// OLE IDropTarget implementation for the main Flutter window.
//
// Why OLE instead of DragAcceptFiles / WM_DROPFILES?
//   - WM_DROPFILES only fires AFTER the user releases the mouse. We need
//     the "drag is hovering" state to show a DropZoneOverlay animation
//     while the user is still holding the file.
//   - IDropTarget::DragEnter fires the moment a draggable enters our HWND
//     bounds; DragLeave fires on exit; Drop fires on release.
//   - This lets us push real-time enter/leave events to Dart via
//     WindowService MethodChannel.
//
// Threading:
//   - IDropTarget callbacks run on the UI thread (the same thread that
//     pumps window messages), so calling Flutter engine methods is safe.

class DropTarget : public IDropTarget {
 public:
  DropTarget();
  virtual ~DropTarget();

  // IDropTarget -----
  HRESULT __stdcall QueryInterface(REFIID riid, void** ppv) override;
  ULONG __stdcall AddRef() override;
  ULONG __stdcall Release() override;
  HRESULT __stdcall DragEnter(IDataObject* pDataObj, DWORD grfKeyState,
                              POINTL pt, DWORD* pdwEffect) override;
  HRESULT __stdcall DragOver(DWORD grfKeyState, POINTL pt,
                             DWORD* pdwEffect) override;
  HRESULT __stdcall DragLeave() override;
  HRESULT __stdcall Drop(IDataObject* pDataObj, DWORD grfKeyState,
                         POINTL pt, DWORD* pdwEffect) override;

  // Public: registers this drop target with the main window's HWND.
  // Must be called from the UI thread.
  // Returns true if registration succeeded.
  static bool RegisterForWindow(HWND hwnd, IDropTarget** out_target);

 private:
  ULONG ref_count_;

  // True between DragEnter and DragLeave/Drop.
  bool drag_active_;

  // Helper: pulls CF_HDROP file paths from an IDataObject.
  static std::vector<std::string> ExtractFilePaths(IDataObject* pDataObj);

  // Helper: pushes an enter/leave/drop event to Dart via window_service.
  static void NotifyDartDragEnter();
  static void NotifyDartDragLeave();
  static void NotifyDartDroppedFiles(const std::vector<std::string>& paths);
};

// Public: called by FlutterWindow::OnCreate after the engine messenger is up.
// Wire the messenger so DropTarget can push events back to Dart.
void SetDragChannelMessenger(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_DROP_TARGET_H_
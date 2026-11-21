/* imgui-filebrowser (C++) as two calls. Index 0 picks an existing .smm, 1 names a new one. */
#include "imfilebrowser.h"
#include <string>

static ImGui::FileBrowser &fbGet(bool save) {
  static ImGui::FileBrowser b[2] = {
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc),
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc | ImGuiFileBrowserFlags_EnterNewFilename |
                       ImGuiFileBrowserFlags_CreateNewDir)};
  static bool init = false;
  if (!init) {
    for (auto &x : b) x.SetTypeFilters({".smm"});
    init = true;
  }
  return b[save];
}

static void fbOpen(bool save) { fbGet(save).Open(); }

/* Draws the browser (call every frame); the chosen path once, else nullptr. */
static const char *fbPick(bool save) {
  static std::string path;
  auto &b = fbGet(save);
  b.Display();
  if (!b.HasSelected()) return nullptr;
  path = b.GetSelected().string();
  b.ClearSelected();
  return path.c_str();
}

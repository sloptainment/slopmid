/* imgui-filebrowser (C++) as two calls. Index 0 picks an existing .smm, 1 names a new one, 2 names a .mid to export, 3 a .wav. */
#include "imgui.h"
#include "imfilebrowser.h"
#include <string>

static ImGui::FileBrowser &fbGet(int i) {
  static ImGui::FileBrowser b[4] = {
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc),
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc | ImGuiFileBrowserFlags_EnterNewFilename |
                       ImGuiFileBrowserFlags_CreateNewDir),
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc | ImGuiFileBrowserFlags_EnterNewFilename |
                       ImGuiFileBrowserFlags_CreateNewDir),
    ImGui::FileBrowser(ImGuiFileBrowserFlags_CloseOnEsc | ImGuiFileBrowserFlags_EnterNewFilename |
                       ImGuiFileBrowserFlags_CreateNewDir)};
  static bool init = false;
  if (!init) {
    for (auto &x : b) x.SetTypeFilters({".smm"});
    b[2].SetTypeFilters({".mid"});
    b[3].SetTypeFilters({".wav"});
    init = true;
  }
  return b[i];
}

static void fbOpen(int i) { fbGet(i).Open(); }

/* Draws the browser (call every frame); the chosen path once, else nullptr. */
static const char *fbPick(int i) {
  static std::string path;
  auto &b = fbGet(i);
  b.Display();
  if (!b.HasSelected()) return nullptr;
  path = b.GetSelected().string();
  b.ClearSelected();
  return path.c_str();
}

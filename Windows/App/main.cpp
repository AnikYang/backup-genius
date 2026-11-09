#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <microsoft.ui.xaml.window.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

#include "../Core/Engine.h"
#include <algorithm>
#include <condition_variable>
#include <ctime>
#include <deque>
#include <mutex>
#include <thread>

namespace {
using namespace winrt;
using namespace winrt::Microsoft::UI::Dispatching;
using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;
using namespace winrt::Windows::Foundation;
using winrt::Microsoft::UI::Xaml::Automation::AutomationProperties;
using namespace std::chrono_literals;

constexpr UINT trayMessage = WM_APP + 17;
constexpr UINT showMessage = WM_APP + 18;
constexpr wchar_t windowName[] = L"Backup Genius";
constexpr wchar_t startupPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

std::wstring wide(std::string_view text) {
    try { return std::wstring(winrt::to_hstring(text)); }
    catch (...) { return L"无法显示此文本"; }
}
std::wstring quantity(int64_t bytes) {
    if (bytes < 1024) return std::to_wstring(bytes) + L" B";
    constexpr std::wstring_view units[]{L"KiB", L"MiB", L"GiB", L"TiB"};
    auto amount = static_cast<double>(bytes);
    for (auto unit : units) {
        amount /= 1024.0;
        if (amount < 1024 || unit == units[3]) {
            wchar_t result[96]{};
            swprintf_s(result, L"%.1f %s", amount, unit.data());
            return result;
        }
    }
    return {};
}
std::wstring timestamp(const bg::Json& date) {
    auto time = bg::eventTime(date);
    std::time_t seconds = static_cast<std::time_t>(time.seconds);
    std::tm local{};
    if (localtime_s(&local, &seconds) != 0) return L"";
    wchar_t result[64]{};
    wcsftime(result, std::size(result), L"%Y-%m-%d %H:%M", &local);
    return result;
}
std::wstring_view title(bg::SyncState state) {
    using S = bg::SyncState;
    switch (state) {
    case S::unconfigured: return L"尚未设置备份";
    case S::disconnected: return L"等待硬盘";
    case S::ready: return L"硬盘已连接";
    case S::checking: return L"正在检查变化";
    case S::syncing: return L"正在同步";
    case S::recovering: return L"正在恢复或对齐文件";
    case S::verifying: return L"正在校验备份";
    case S::upToDate: return L"已同步";
    case S::paused: return L"备份已暂停";
    case S::needsAttention: return L"需要处理";
    case S::takeoverRequired: return L"等待接管";
    }
    return L"备份";
}
std::wstring_view kind(std::string_view kind) {
    if (kind == "added") return L"新增";
    if (kind == "updated") return L"修改";
    if (kind == "deleted") return L"移入历史";
    if (kind == "moved") return L"移动";
    if (kind == "verified") return L"已校验";
    if (kind == "recovered") return L"已恢复";
    return L"需处理";
}
bool busy(bg::SyncState state) {
    using S = bg::SyncState;
    return state == S::checking || state == S::verifying || state == S::syncing || state == S::recovering;
}
TextBlock label(std::wstring_view value, double size = 14) {
    TextBlock text;
    text.Text(hstring(value));
    text.FontSize(size);
    text.TextWrapping(TextWrapping::Wrap);
    return text;
}
Button button(std::wstring_view text, const std::function<void()>& click) {
    Button result;
    result.Content(box_value(hstring(text)));
    result.Click([click](auto&&, auto&&) { click(); });
    return result;
}
bg::fs::path localData() {
    PWSTR directory{};
    check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &directory));
    bg::fs::path path(directory);
    CoTaskMemFree(directory);
    return path / L"Backup Genius";
}
bg::fs::path selectFolder(HWND hwnd, std::wstring_view title) {
    auto picker = create_instance<IFileOpenDialog>(CLSID_FileOpenDialog);
    check_hresult(picker->SetTitle(hstring(title).c_str()));
    DWORD options{};
    check_hresult(picker->GetOptions(&options));
    check_hresult(picker->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST));
    auto result = picker->Show(hwnd);
    if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return {};
    check_hresult(result);
    com_ptr<IShellItem> item;
    check_hresult(picker->GetResult(item.put()));
    PWSTR text{};
    check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH, &text));
    bg::fs::path path(text);
    CoTaskMemFree(text);
    return path;
}
bool startupEnabled() {
    return RegGetValueW(HKEY_CURRENT_USER, startupPath, windowName, RRF_RT_REG_SZ, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
}
void startup(bool value) {
    HKEY key{};
    auto result = RegCreateKeyExW(HKEY_CURRENT_USER, startupPath, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
    if (result != ERROR_SUCCESS) throw hresult_error(HRESULT_FROM_WIN32(result), L"无法更改登录启动");
    if (value) {
        std::wstring exe(32768, L'\0');
        auto length = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
        if (length == 0 || length >= exe.size()) { RegCloseKey(key); throw hresult_error(E_FAIL, L"找不到应用程序"); }
        exe.resize(length);
        auto command = L"\"" + exe + L"\" --startup";
        result = RegSetValueExW(key, windowName, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()),
                                static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    } else {
        result = RegDeleteValueW(key, windowName);
        if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    if (result != ERROR_SUCCESS) throw hresult_error(HRESULT_FROM_WIN32(result), L"无法更改登录启动");
}

class Worker {
public:
    using Task = std::function<void(bg::SyncEngine&)>;
    Worker(bg::fs::path storage, std::function<void(std::string)> error)
        : error_(std::move(error)), engine_(std::move(storage), [this](const bg::Presentation& value) {
              std::lock_guard lock(mutex_);
              latest_ = value;
          }),
          thread_([this](std::stop_token stop) {
              while (!stop.stop_requested()) {
                  Task work;
                  {
                      std::unique_lock lock(mutex_);
                      wake_.wait_for(lock, 500ms, [&] { return stop.stop_requested() || !tasks_.empty(); });
                      if (stop.stop_requested()) break;
                      if (!tasks_.empty()) { work = std::move(tasks_.front()); tasks_.pop_front(); }
                  }
                  try { if (work) work(engine_); else engine_.poll(); }
                  catch (const std::exception& e) { error_(e.what()); }
              }
          }) {}
    ~Worker() {
        engine_.requestPause();
        thread_.request_stop();
        wake_.notify_all();
    }
    void submit(Task task) {
        { std::lock_guard lock(mutex_); tasks_.push_back(std::move(task)); }
        wake_.notify_one();
    }
    void interrupt() { engine_.requestPause(); }
    std::optional<bg::Presentation> take() {
        std::lock_guard lock(mutex_);
        return std::exchange(latest_, {});
    }
private:
    std::function<void(std::string)> error_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Task> tasks_;
    std::optional<bg::Presentation> latest_;
    bg::SyncEngine engine_;
    std::jthread thread_;
};

class BackupWindow {
public:
    explicit BackupWindow(bool atLogin) {
        window_.Title(windowName);
        auto native = window_.as<IWindowNative>();
        check_hresult(native->get_WindowHandle(&hwnd_));
        dispatcher_ = window_.DispatcherQueue();
        root_ = Grid{};
        window_.Content(root_);
        window_.SystemBackdrop(Media::MicaBackdrop());
        auto dpi = GetDpiForWindow(hwnd_);
        window_.AppWindow().Resize({MulDiv(1000, dpi, 96), MulDiv(680, dpi, 96)});
        build();
        taskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated");
        check_bool(SetWindowSubclass(hwnd_, windowProc, 1, reinterpret_cast<DWORD_PTR>(this)));
        addTray();
        worker_ = std::make_unique<Worker>(localData(), [this](std::string message) {
            dispatcher_.TryEnqueue([this, message = std::move(message)] { error(wide(message)); });
        });
        worker_->submit([](bg::SyncEngine& engine) { engine.start(); });
        timer_ = dispatcher_.CreateTimer();
        timer_.Interval(200ms);
        timer_.Tick([this](auto&&, auto&&) { if (auto value = worker_->take()) render(*value); });
        timer_.Start();
        render({});
        window_.Activate();
        if (atLogin && trayReady_) ShowWindow(hwnd_, SW_HIDE);
    }
    ~BackupWindow() {
        if (timer_) timer_.Stop();
        if (hwnd_) {
            auto data = trayData();
            Shell_NotifyIconW(NIM_DELETE, &data);
            RemoveWindowSubclass(hwnd_, windowProc, 1);
        }
        worker_.reset();
    }
private:
    static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR ref) {
        auto self = reinterpret_cast<BackupWindow*>(ref);
        try {
            if (message == WM_CLOSE && !self->exiting_) {
                if (self->trayReady_) ShowWindow(hwnd, SW_HIDE); else self->quit();
                return 0;
            }
            if (message == trayMessage) {
                if (LOWORD(l) == WM_CONTEXTMENU || LOWORD(l) == WM_RBUTTONUP) self->trayMenu();
                else if (LOWORD(l) == NIN_SELECT || LOWORD(l) == NIN_KEYSELECT || LOWORD(l) == WM_LBUTTONDBLCLK) self->show();
                return 0;
            }
            if (message == showMessage) { self->show(); return 0; }
            if (message == self->taskbarCreated_) self->addTray();
            if (message == WM_DEVICECHANGE && self->worker_) self->worker_->submit([](bg::SyncEngine& engine) { engine.poll(); });
            if (message == WM_QUERYENDSESSION && self->worker_) self->worker_->interrupt();
            if (message == WM_GETMINMAXINFO) {
                auto limits = reinterpret_cast<MINMAXINFO*>(l);
                auto dpi = GetDpiForWindow(hwnd);
                limits->ptMinTrackSize = {MulDiv(660, dpi, 96), MulDiv(500, dpi, 96)};
            }
        } catch (...) {}
        return DefSubclassProc(hwnd, message, w, l);
    }
    NOTIFYICONDATAW trayData() const {
        NOTIFYICONDATAW data{};
        data.cbSize = sizeof(data);
        data.hWnd = hwnd_;
        data.uID = 1;
        data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        data.uCallbackMessage = trayMessage;
        data.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
        auto tip = std::wstring(windowName) + L" · " + std::wstring(title(view_.progress.state));
        wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
        return data;
    }
    void addTray() {
        auto data = trayData();
        trayReady_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
        data.uVersion = NOTIFYICON_VERSION_4;
        if (trayReady_) Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
    void show() {
        ShowWindow(hwnd_, SW_RESTORE);
        window_.Activate();
        SetForegroundWindow(hwnd_);
    }
    void trayMenu() {
        auto menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, 1, L"打开 Backup Genius");
        AppendMenuW(menu, MF_STRING | (view_.job.id.empty() || view_.job.restoreOnly ? MF_GRAYED : 0), 2,
                    view_.progress.state == bg::SyncState::paused ? L"继续备份" : L"暂停备份");
        AppendMenuW(menu, MF_STRING | (view_.volume ? 0 : MF_GRAYED), 3, L"安全推出");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, 4, L"退出");
        POINT cursor{};
        GetCursorPos(&cursor);
        SetForegroundWindow(hwnd_);
        auto result = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd_, nullptr);
        DestroyMenu(menu);
        PostMessageW(hwnd_, WM_NULL, 0, 0);
        if (result == 1) show();
        if (result == 2) pause();
        if (result == 3) eject();
        if (result == 4) quit();
    }
    void error(std::wstring_view message) {
        alert_.Title(L"需要处理");
        alert_.Severity(InfoBarSeverity::Warning);
        alert_.Message(hstring(message));
        alert_.IsOpen(true);
    }
    void build() {
        NavigationView nav;
        nav.PaneDisplayMode(NavigationViewPaneDisplayMode::Auto);
        nav.ExpandedModeThresholdWidth(830);
        nav.CompactModeThresholdWidth(620);
        nav.OpenPaneLength(218);
        nav.IsSettingsVisible(false);
        nav.IsBackButtonVisible(NavigationViewBackButtonVisible::Collapsed);
        for (const auto& [name, icon] : std::vector<std::pair<const wchar_t*, Symbol>>{
            {L"备份", Symbol::Save}, {L"活动记录", Symbol::List}, {L"历史版本", Symbol::Clock}}) {
            NavigationViewItem item;
            item.Content(box_value(hstring(name)));
            item.Icon(SymbolIcon(icon));
            nav.MenuItems().Append(item);
        }
        StackPanel footer;
        footer.Margin({16, 10, 16, 16});
        footer.Spacing(5);
        disk_ = label(L"尚未选择硬盘", 13);
        free_ = label(L"", 12);
        capacity_ = ProgressBar();
        capacity_.Maximum(100);
        AutomationProperties::SetName(capacity_, L"硬盘已使用空间");
        footer.Children().Append(disk_);
        footer.Children().Append(capacity_);
        footer.Children().Append(free_);
        nav.PaneFooter(footer);
        root_.Children().Append(nav);
        auto page = Grid();
        for (auto height : {GridLength{1, GridUnitType::Auto}, GridLength{1, GridUnitType::Auto},
                            GridLength{1, GridUnitType::Star}}) {
            RowDefinition row;
            row.Height(height);
            page.RowDefinitions().Append(row);
        }
        nav.Content(page);
        CommandBar commands;
        commands.DefaultLabelPosition(CommandBarDefaultLabelPosition::Right);
        commands.IsDynamicOverflowEnabled(true);
        auto command = [&](const wchar_t* name, Symbol symbol, const std::function<void()>& action, bool secondary = false) {
            AppBarButton b;
            b.Label(name);
            b.Icon(SymbolIcon(symbol));
            b.Click([action](auto&&, auto&&) { action(); });
            if (secondary) commands.SecondaryCommands().Append(b);
            else commands.PrimaryCommands().Append(b);
            return b;
        };
        sync_ = command(L"立即同步", Symbol::Sync, [this] { worker_->submit([](auto& e) { e.sync(); }); });
        pause_ = command(L"暂停", Symbol::Pause, [this] { pause(); });
        eject_ = command(L"安全推出", Symbol::Upload, [this] { eject(); });
        setup_ = command(L"设置备份…", Symbol::Setting, [this] { setup(false); }, true);
        open_ = command(L"打开已有备份…", Symbol::OpenFile, [this] { setup(true); }, true);
        verify_ = command(L"完整校验", Symbol::Find, [this] { worker_->submit([](auto& e) { e.sync(true); }); }, true);
        takeover_ = command(L"预览接管…", Symbol::Switch, [this] { takeover(); }, true);
        command(L"退出", Symbol::Cancel, [this] { quit(); }, true);
        page.Children().Append(commands);
        alert_ = InfoBar();
        alert_.IsClosable(true);
        alert_.Margin({24, 0, 24, 0});
        Grid::SetRow(alert_, 1);
        page.Children().Append(alert_);
        content_ = Grid();
        Grid::SetRow(content_, 2);
        page.Children().Append(content_);
        makeOverview();
        makeRecords();
        nav.SelectedItem(nav.MenuItems().GetAt(0));
        nav.SelectionChanged([this](NavigationView const&, NavigationViewSelectionChangedEventArgs const& args) {
            if (auto item = args.SelectedItem().try_as<NavigationViewItem>()) {
                auto name = unbox_value<hstring>(item.Content());
                page_ = name == L"活动记录" ? 1 : name == L"历史版本" ? 2 : 0;
                overview_.Visibility(page_ == 0 ? Visibility::Visible : Visibility::Collapsed);
                records_.Visibility(page_ == 0 ? Visibility::Collapsed : Visibility::Visible);
                recordTitle_.Text(page_ == 2 ? L"历史版本" : L"活动记录");
                restoreSelected_.Visibility(page_ == 2 ? Visibility::Visible : Visibility::Collapsed);
                restoreCurrent_.Visibility(page_ == 2 ? Visibility::Visible : Visibility::Collapsed);
                if (page_) loadRows();
            }
        });
    }
    void makeOverview() {
        overview_ = ScrollViewer();
        auto content = StackPanel();
        content.Margin({30, 20, 30, 28});
        content.Spacing(18);
        overview_.Content(content);
        content_.Children().Append(overview_);
        status_ = label(L"尚未设置备份", 32);
        AutomationProperties::SetAutomationId(status_, L"BackupStatus");
        detail_ = label(L"选择一个文件夹及外置硬盘上的备份位置。");
        statusProgress_ = ProgressBar();
        statusProgress_.Maximum(100);
        AutomationProperties::SetName(statusProgress_, L"同步进度");
        route_ = label(L"", 16);
        metrics_ = label(L"");
        content.Children().Append(status_);
        content.Children().Append(detail_);
        content.Children().Append(statusProgress_);
        content.Children().Append(route_);
        content.Children().Append(metrics_);
        StackPanel actions;
        actions.Orientation(Orientation::Horizontal);
        actions.Spacing(10);
        configureButton_ = button(L"设置备份…", [this] { setup(false); });
        existingButton_ = button(L"打开已有备份…", [this] { setup(true); });
        takeoverButton_ = button(L"预览接管…", [this] { takeover(); });
        explorer_ = button(L"在文件资源管理器中打开", [this] { explore(view_.job.target); });
        actions.Children().Append(configureButton_);
        actions.Children().Append(existingButton_);
        actions.Children().Append(takeoverButton_);
        actions.Children().Append(explorer_);
        content.Children().Append(actions);
        content.Children().Append(label(L"旧版保留 30 天"));
        automatic_ = ToggleSwitch();
        automatic_.Header(box_value(L"连接后自动同步"));
        automatic_.Toggled([this](auto&&, auto&&) {
            if (rendering_) return;
            const auto on = automatic_.IsOn();
            worker_->submit([on](auto& engine) { engine.setAutomatic(on); });
        });
        content.Children().Append(automatic_);
        auto login = ToggleSwitch();
        login.Header(box_value(L"登录时启动"));
        login.IsOn(startupEnabled());
        login.Toggled([this](IInspectable const& sender, auto&&) {
            try { startup(sender.as<ToggleSwitch>().IsOn()); }
            catch (const hresult_error& e) { error(e.message()); }
        });
        content.Children().Append(login);
    }
    void makeRecords() {
        records_ = Grid();
        records_.Margin({30, 20, 30, 24});
        records_.Visibility(Visibility::Collapsed);
        for (auto height : {GridLength{1, GridUnitType::Auto}, GridLength{1, GridUnitType::Star}}) {
            RowDefinition row;
            row.Height(height);
            records_.RowDefinitions().Append(row);
        }
        StackPanel header;
        header.Spacing(10);
        recordTitle_ = label(L"活动记录", 28);
        header.Children().Append(recordTitle_);
        search_ = TextBox();
        search_.PlaceholderText(L"按路径搜索");
        AutomationProperties::SetName(search_, L"搜索记录");
        search_.TextChanged([this](auto&&, auto&&) { renderRows(); });
        header.Children().Append(search_);
        StackPanel controls;
        controls.Orientation(Orientation::Horizontal);
        controls.Spacing(10);
        restoreSelected_ = button(L"恢复所选版本…", [this] {
            auto i = list_.SelectedIndex();
            if (i >= 0 && static_cast<size_t>(i) < visibleIDs_.size()) restore(visibleIDs_[i]);
        });
        restoreCurrent_ = button(L"恢复当前备份…", [this] { restore({}); });
        controls.Children().Append(restoreSelected_);
        controls.Children().Append(restoreCurrent_);
        header.Children().Append(controls);
        records_.Children().Append(header);
        list_ = ListView();
        list_.SelectionMode(ListViewSelectionMode::Single);
        list_.SelectionChanged([this](auto&&, auto&&) { restoreSelected_.IsEnabled(list_.SelectedIndex() >= 0 && view_.volume && !busy(view_.progress.state)); });
        Grid::SetRow(list_, 1);
        records_.Children().Append(list_);
        content_.Children().Append(records_);
    }
    void render(const bg::Presentation& presentation) {
        const auto previous = view_.progress.state;
        view_ = presentation;
        const auto& p = view_.progress;
        const bool active = busy(p.state);
        const bool configured = !view_.job.id.empty();
        const bool connected = view_.volume.has_value();
        using S = bg::SyncState;
        status_.Text(hstring(title(p.state)));
        std::wstring text = wide(p.message);
        if (!configured) text = L"选择要备份的文件夹和外置硬盘。";
        else if (text.empty() && p.state == S::disconnected) text = L"连接登记过的备份硬盘后继续。";
        else if (text.empty() && p.state == S::takeoverRequired) text = L"先预览并对齐本机文件夹，再接管自动同步。";
        else if (text.empty() && p.state == S::checking) text = L"已检查 " + std::to_wstring(p.examined) + L" 项";
        else if (text.empty() && p.state == S::syncing) text = L"剩余 " + std::to_wstring(p.planned - p.processed) + L" 项";
        else if (text.empty() && p.state == S::upToDate) text = L"最新备份可用。";
        if (p.unmanaged) text += L"  硬盘有 " + std::to_wstring(p.unmanaged) + L" 个未管理项目。";
        detail_.Text(text);
        statusProgress_.Visibility(active ? Visibility::Visible : Visibility::Collapsed);
        const bool determinate = p.state == S::syncing && p.planned > 0;
        statusProgress_.IsIndeterminate(active && !determinate);
        if (determinate) statusProgress_.Value(100.0 * p.processed / p.planned);
        route_.Text(configured ? (view_.job.restoreOnly ? L"已有备份" : view_.job.source.wstring()) + L"\n↓\n" + view_.job.target.wstring() : L"");
        metrics_.Text(configured ? L"已管理 " + std::to_wstring(p.tracked) + L" 项  ·  最新副本写入 " +
            quantity(p.latestWritten) + L"  ·  历史写入 " + quantity(p.historyWritten) : L"");
        if (connected) {
            auto disk = *view_.volume;
            disk_.Text(wide(disk.label.empty() ? bg::utf8(disk.mount) : disk.label) + L" · " + wide(view_.job.format));
            free_.Text(L"可用 " + quantity(static_cast<int64_t>(disk.free)));
            capacity_.Value(disk.total ? 100.0 * (disk.total - disk.free) / disk.total : 0);
        } else { disk_.Text(configured ? L"硬盘未连接" : L"尚未选择硬盘"); free_.Text(L""); }
        capacity_.Visibility(connected ? Visibility::Visible : Visibility::Collapsed);
        sync_.IsEnabled(connected && !active && !view_.job.restoreOnly && p.state != S::paused && p.state != S::takeoverRequired);
        verify_.IsEnabled(sync_.IsEnabled());
        pause_.IsEnabled(connected && !view_.job.restoreOnly && p.state != S::takeoverRequired);
        pause_.Label(p.state == S::paused ? L"继续" : L"暂停");
        pause_.Icon(SymbolIcon(p.state == S::paused ? Symbol::Play : Symbol::Pause));
        eject_.IsEnabled(connected);
        setup_.IsEnabled(!active);
        open_.IsEnabled(!active);
        takeover_.IsEnabled(connected && !active);
        configureButton_.Visibility(!configured ? Visibility::Visible : Visibility::Collapsed);
        existingButton_.Visibility(!configured ? Visibility::Visible : Visibility::Collapsed);
        takeoverButton_.Visibility(connected && (p.state == S::takeoverRequired || view_.job.restoreOnly) ? Visibility::Visible : Visibility::Collapsed);
        explorer_.Visibility(connected ? Visibility::Visible : Visibility::Collapsed);
        restoreCurrent_.IsEnabled(connected && !active);
        restoreSelected_.IsEnabled(connected && !active && list_.SelectedIndex() >= 0);
        automatic_.Visibility(configured && !view_.job.restoreOnly ? Visibility::Visible : Visibility::Collapsed);
        rendering_ = true;
        automatic_.IsOn(configured && view_.job.automatic);
        rendering_ = false;
        auto tray = trayData();
        if (trayReady_) Shell_NotifyIconW(NIM_MODIFY, &tray);
        if (page_ && previous != p.state && !active) loadRows();
    }
    void loadRows() {
        if (!worker_) return;
        const auto page = page_;
        worker_->submit([this, page](auto& engine) {
            auto rows = page == 2 ? engine.history() : engine.activities();
            dispatcher_.TryEnqueue([this, page, rows = std::move(rows)] {
                if (page_ != page) return;
                rows_ = rows;
                renderRows();
            });
        });
    }
    void renderRows() {
        if (!list_) return;
        visibleIDs_.clear();
        std::vector<IInspectable> items;
        auto query = bg::folded(to_string(search_.Text()));
        for (const auto& row : rows_) {
            auto path = row.value("path", "");
            if (!query.empty() && bg::folded(path).find(query) == std::string::npos) continue;
            auto category = kind(row.value(page_ == 2 ? "reason" : "kind", ""));
            auto text = timestamp(row.at("date")) + L"   " + std::wstring(category) + L"   " + wide(path);
            if (page_ == 2) text += L"   " + quantity(row.value("size", int64_t{}));
            if (row.contains("detail")) text += L"\n" + wide(row.at("detail").get<std::string>());
            visibleIDs_.push_back(row.value("id", ""));
            items.push_back(box_value(hstring(text)));
        }
        list_.ItemsSource(single_threaded_observable_vector<IInspectable>(std::move(items)));
    }
    fire_and_forget setup(bool existing) {
        if (dialogOpen_) co_return;
        dialogOpen_ = true;
        try {
            ContentDialog dialog;
            dialog.XamlRoot(root_.XamlRoot());
            dialog.Title(box_value(existing ? L"打开已有备份" : L"设置备份"));
            dialog.PrimaryButtonText(existing ? L"打开" : L"保存任务");
            dialog.CloseButtonText(L"取消");
            dialog.DefaultButton(ContentDialogButton::Primary);
            dialog.IsPrimaryButtonEnabled(false);
            bg::fs::path source, target;
            StackPanel form;
            form.Spacing(11);
            auto sourceText = label(L"尚未选择源文件夹");
            auto targetText = label(L"尚未选择硬盘目标文件夹");
            if (!existing) {
                form.Children().Append(button(L"选择源文件夹…", [&] {
                    try {
                        auto chosen = selectFolder(hwnd_, L"选择源文件夹");
                        if (chosen.empty()) return;
                        source = std::move(chosen);
                        sourceText.Text(source.wstring());
                        dialog.IsPrimaryButtonEnabled(!target.empty());
                    } catch (const hresult_error& e) { error(e.message()); }
                }));
                form.Children().Append(sourceText);
            }
            form.Children().Append(button(L"选择硬盘目标文件夹…", [&] {
                try {
                    auto chosen = selectFolder(hwnd_, L"选择外置硬盘上的目标文件夹");
                    if (chosen.empty()) return;
                    target = std::move(chosen);
                    targetText.Text(target.wstring());
                    dialog.IsPrimaryButtonEnabled(existing || !source.empty());
                } catch (const hresult_error& e) { error(e.message()); }
            }));
            form.Children().Append(targetText);
            ToggleSwitch automatic;
            if (!existing) {
                form.Children().Append(label(L"Windows → 外置硬盘 · 旧版保留 30 天"));
                automatic.Header(box_value(L"连接后自动同步"));
                automatic.IsOn(true);
                form.Children().Append(automatic);
            }
            dialog.Content(form);
            if (co_await dialog.ShowAsync() == ContentDialogResult::Primary) {
                auto autoSync = automatic.IsOn();
                worker_->submit([existing, source, target, autoSync](auto& engine) {
                    if (existing) engine.openExisting(target); else engine.configure(source, target, autoSync);
                });
            }
        } catch (const hresult_error& e) { error(e.message()); }
        dialogOpen_ = false;
    }
    void takeover() {
        try {
            auto source = selectFolder(hwnd_, L"选择接管后的源文件夹。首次接管请选择空文件夹");
            if (source.empty()) return;
            worker_->submit([this, source](auto& engine) {
                auto preview = engine.previewTakeover(source);
                dispatcher_.TryEnqueue([this, preview = std::move(preview)] { review(preview); });
            });
        } catch (const hresult_error& e) { error(e.message()); }
    }
    fire_and_forget review(bg::TakeoverPreview preview) {
        if (dialogOpen_) co_return;
        dialogOpen_ = true;
        try {
            ContentDialog dialog;
            dialog.XamlRoot(root_.XamlRoot());
            dialog.Title(box_value(L"对齐并接管"));
            dialog.PrimaryButtonText(preview.resuming ? L"继续接管" : L"确认接管");
            dialog.CloseButtonText(L"取消");
            StackPanel content;
            content.Spacing(10);
            content.Children().Append(label(preview.resuming ? L"继续上次确认的对齐操作。" :
                L"检查将要写入本机或硬盘的文件。选择有冲突的行以决定保留哪一份。"));
            ListView list;
            list.MaxHeight(270);
            std::vector<IInspectable> items;
            for (const auto& row : preview.changes) {
                using K = bg::AlignmentKind;
                auto prefix = row.kind == K::receive ? L"按硬盘对齐本机" : row.kind == K::send ? L"保留本机变化" :
                    row.kind == K::conflict ? L"冲突" : L"需处理";
                items.push_back(box_value(hstring(std::wstring(prefix) + L"   " + wide(row.path))));
            }
            list.ItemsSource(single_threaded_observable_vector<IInspectable>(std::move(items)));
            if (!preview.changes.empty()) content.Children().Append(list);
            else if (!preview.resuming) content.Children().Append(label(L"两端内容一致。"));
            ComboBox choice;
            choice.Header(box_value(L"处理所选冲突"));
            choice.IsEnabled(false);
            choice.Items().Append(box_value(L"保留本机"));
            choice.Items().Append(box_value(L"保留硬盘"));
            choice.Items().Append(box_value(L"保留两份"));
            content.Children().Append(choice);
            std::map<std::string, bg::AlignmentChoice> choices;
            const auto conflicts = static_cast<size_t>(std::count_if(preview.changes.begin(), preview.changes.end(),
                [](const auto& row) { return row.kind == bg::AlignmentKind::conflict; }));
            dialog.IsPrimaryButtonEnabled(conflicts == 0);
            bool updating = false;
            auto listToken = list.SelectionChanged([&](auto&&, auto&&) {
                updating = true;
                const auto index = list.SelectedIndex();
                const bool active = index >= 0 && preview.changes[index].kind == bg::AlignmentKind::conflict;
                choice.IsEnabled(active);
                if (active) {
                    const auto& row = preview.changes[index];
                    if (choice.Items().Size() == 2 && row.canKeepBoth) choice.Items().Append(box_value(L"保留两份"));
                    if (choice.Items().Size() == 3 && !row.canKeepBoth) choice.Items().RemoveAtEnd();
                    auto picked = choices.find(row.path);
                    choice.SelectedIndex(picked == choices.end() ? -1 : static_cast<int>(picked->second));
                } else choice.SelectedIndex(-1);
                updating = false;
            });
            auto choiceToken = choice.SelectionChanged([&](auto&&, auto&&) {
                if (updating || list.SelectedIndex() < 0 || choice.SelectedIndex() < 0) return;
                const auto& row = preview.changes[list.SelectedIndex()];
                choices[row.path] = static_cast<bg::AlignmentChoice>(choice.SelectedIndex());
                dialog.IsPrimaryButtonEnabled(choices.size() == conflicts);
            });
            dialog.Content(content);
            auto result = co_await dialog.ShowAsync();
            list.SelectionChanged(listToken);
            choice.SelectionChanged(choiceToken);
            if (result == ContentDialogResult::Primary) {
                worker_->submit([id = preview.id, choices = std::move(choices)](auto& engine) { engine.confirmTakeover(id, choices); });
            }
        } catch (const hresult_error& e) { error(e.message()); }
        dialogOpen_ = false;
    }
    void explore(const bg::fs::path& folder) {
        if (!folder.empty()) ShellExecuteW(hwnd_, L"open", folder.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
    void restore(std::string version) {
        try {
            auto folder = selectFolder(hwnd_, L"选择恢复位置");
            if (folder.empty()) return;
            worker_->submit([this, folder, version = std::move(version)](auto& engine) {
                auto result = engine.restore(folder, version);
                dispatcher_.TryEnqueue([this, result = std::move(result)] { explore(result); });
            });
        } catch (const hresult_error& e) { error(e.message()); }
    }
    void pause() {
        if (view_.progress.state == bg::SyncState::paused) {
            worker_->submit([](auto& engine) { engine.resume(); });
        } else {
            worker_->interrupt();
            worker_->submit([](auto& engine) { engine.pause(); });
        }
    }
    void eject() {
        worker_->interrupt();
        worker_->submit([](auto& engine) { engine.safeEject(); });
    }
    void quit() {
        if (quitting_) return;
        quitting_ = true;
        worker_->interrupt();
        worker_->submit([this](auto& engine) {
            try {
                engine.pause();
                dispatcher_.TryEnqueue([this] {
                    exiting_ = true;
                    window_.Close();
                    Application::Current().Exit();
                });
            } catch (const std::exception& e) {
                dispatcher_.TryEnqueue([this, message = std::string(e.what())] {
                    quitting_ = false;
                    error(wide(message));
                });
            }
        });
    }
    Window window_;
    HWND hwnd_{};
    UINT taskbarCreated_{};
    DispatcherQueue dispatcher_{nullptr};
    DispatcherQueueTimer timer_{nullptr};
    Grid root_{nullptr}, content_{nullptr}, records_{nullptr};
    ScrollViewer overview_{nullptr};
    TextBlock disk_{nullptr}, free_{nullptr}, status_{nullptr}, detail_{nullptr}, route_{nullptr}, metrics_{nullptr}, recordTitle_{nullptr};
    ProgressBar capacity_{nullptr}, statusProgress_{nullptr};
    AppBarButton sync_{nullptr}, pause_{nullptr}, eject_{nullptr}, setup_{nullptr}, open_{nullptr}, verify_{nullptr}, takeover_{nullptr};
    Button configureButton_{nullptr}, existingButton_{nullptr}, takeoverButton_{nullptr}, explorer_{nullptr};
    Button restoreCurrent_{nullptr}, restoreSelected_{nullptr};
    ToggleSwitch automatic_{nullptr};
    InfoBar alert_{nullptr};
    ListView list_{nullptr};
    TextBox search_{nullptr};
    std::unique_ptr<Worker> worker_;
    bg::Presentation view_;
    bg::Json rows_ = bg::Json::array();
    std::vector<std::string> visibleIDs_;
    int page_{};
    bool trayReady_{}, rendering_{}, dialogOpen_{}, quitting_{}, exiting_{};
};

struct Program : ApplicationT<Program> {
    explicit Program(bool startup) : startup_(startup) {}
    void OnLaunched(LaunchActivatedEventArgs const&) {
        Resources().MergedDictionaries().Append(XamlControlsResources());
        window_ = std::make_unique<BackupWindow>(startup_);
    }
    bool startup_{};
    std::unique_ptr<BackupWindow> window_;
};
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR command, int) {
    try {
        auto mutex = CreateMutexW(nullptr, FALSE, L"Local\\BackupGenius.WinUI.SingleInstance");
        if (!mutex) return 1;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            if (auto window = FindWindowW(nullptr, windowName)) PostMessageW(window, showMessage, 0, 0);
            CloseHandle(mutex);
            return 0;
        }
        init_apartment(apartment_type::single_threaded);
        winrt::com_ptr<Program> app;
        const bool startup = std::wstring_view(command).find(L"--startup") != std::wstring_view::npos;
        Application::Start([&](auto&&) { app = make_self<Program>(startup); });
        app = nullptr;
        CloseHandle(mutex);
        return 0;
    } catch (const hresult_error& error) {
        MessageBoxW(nullptr, error.message().c_str(), windowName, MB_OK | MB_ICONERROR);
    } catch (const std::exception& error) {
        MessageBoxW(nullptr, wide(error.what()).c_str(), windowName, MB_OK | MB_ICONERROR);
    }
    return 1;
}

// platform_ui_ios.mm - the SDL host on iOS/iPadOS: one fullscreen Metal window, the
// game in Documents/game (imported by the launcher, from the bundle of a
// developer build or from files the player chose), the launcher's platform,
// and the app lifecycle mapped onto audio and presentation.
#include "platform_ui.h"

#include "../../platform/os.h"
#include "../../runtime/layout.h"
#include "../audio.h"
#include "../launcher/launcher_sdl.h"
#include "../present.h"
#include "../../mods/display_settings.h"
#include "../../mods/settings_menu.h"
#include "game_config.h"

#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <stdio.h>
#include <string>

namespace fs = std::filesystem;

#include <mutex>
#include <chrono>
#include <atomic>
#include <csignal>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <thread>
#include <execinfo.h>


namespace {
std::mutex g_diag_mutex;
void ios_diagnostic(const char *event);

std::atomic<bool> g_crash_monitor_started{false};
std::atomic<unsigned long long> g_peak_footprint{0};
int g_crash_fd = -1;

// The signal handler only uses async-signal-safe operations. The native .ips
// report and matching dSYM are still needed for full symbolicated stacks.
void ios_fatal_signal(int signo, siginfo_t *info, void *) {
    static const char prefix[] = "fatal signal ";
    static const char suffix[] = "\n";
    char number[24];
    unsigned int n = signo < 0 ? 0u : static_cast<unsigned int>(signo);
    int pos = 0;
    do { number[pos++] = char('0' + n % 10); n /= 10; } while (n && pos < 20);
    if (g_crash_fd >= 0) {
        (void)write(g_crash_fd, prefix, sizeof(prefix) - 1);
        while (pos) { --pos; (void)write(g_crash_fd, &number[pos], 1); }
        (void)write(g_crash_fd, suffix, sizeof(suffix) - 1);
    }
    // Re-raise with the default disposition to preserve the iOS crash report.
    struct sigaction def = {};
    def.sa_handler = SIG_DFL;
    sigemptyset(&def.sa_mask);
    sigaction(signo, &def, nullptr);
    kill(getpid(), signo);
    _exit(128 + signo);
}

void ios_uncaught_exception(NSException *exception) {
    NSString *folder = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"diagnostics"];
    NSString *path = [folder stringByAppendingPathComponent:@"exception.log"];
    NSString *message = [NSString stringWithFormat:
        @"Exception: %@\nReason: %@\nStack:\n%@\n",
        exception.name, exception.reason,
        [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    [message writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void ios_start_crash_monitor() {
    if (g_crash_monitor_started.exchange(true)) return;
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (!dirs.count) return;
        NSString *folder = [dirs[0] stringByAppendingPathComponent:@"diagnostics"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                    withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *crash = [folder stringByAppendingPathComponent:@"fatal-signal.log"];
        g_crash_fd = open(crash.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0600);
    }
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil queue:nil usingBlock:^(NSNotification *) {
            ios_diagnostic("memory_warning UIApplicationDidReceiveMemoryWarningNotification");
        }];
    NSSetUncaughtExceptionHandler(&ios_uncaught_exception);
    for (int signo : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE}) {
        struct sigaction action = {};
        action.sa_sigaction = ios_fatal_signal;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_SIGINFO;
        sigaction(signo, &action, nullptr);
    }
    std::thread([] {
        while (true) {
            task_vm_info_data_t vm = {};
            mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
            kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                         reinterpret_cast<task_info_t>(&vm), &count);
            if (kr == KERN_SUCCESS) {
                const unsigned long long footprint = (unsigned long long)vm.phys_footprint;
                unsigned long long previous = g_peak_footprint.load(std::memory_order_relaxed);
                while (footprint > previous &&
                       !g_peak_footprint.compare_exchange_weak(previous, footprint,
                                                               std::memory_order_relaxed)) {}
                const size_t available = os_proc_available_memory();
                char line[256];
                snprintf(line, sizeof(line),
                         "memory physical_footprint=%llu resident=%llu peak_footprint=%llu available=%llu",
                         footprint, (unsigned long long)vm.resident_size,
                         g_peak_footprint.load(std::memory_order_relaxed),
                         (unsigned long long)available);
                ios_diagnostic(line);
            }
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }).detach();
}

void ios_diagnostic(const char *event) {
    std::lock_guard<std::mutex> lock(g_diag_mutex);
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (!dirs.count) return;
        NSString *folder = [dirs[0] stringByAppendingPathComponent:@"diagnostics"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *file = [folder stringByAppendingPathComponent:@"session.log"];
        FILE *out = fopen(file.fileSystemRepresentation, "a");
        if (!out) return;
        const auto now = std::chrono::system_clock::now().time_since_epoch();
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
        fprintf(out, "%lld %s\n", (long long)ms, event);
        fflush(out);
        fclose(out);
    }
}
}


namespace {

std::string bundle_dir() {
    char path[4096];
    if (os_exe_path(path, sizeof path) != 0)
        return "";
    return fs::path(path).parent_path().string();
}

std::string documents_dir() {
    NSArray *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.count ? std::string([paths[0] fileSystemRepresentation]) : "";
}

} // namespace

void platform_ui_init_hints() {
    // NFS Most Wanted is a landscape game on both iPhone and iPad.
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    // The mapper turns fingers into mouse and key events itself.
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
    SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0");
    SDL_SetHint(SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "0");
    // RECOMP_* switches for a device with no shell: Documents/switches.txt,
    // put there with devicectl (see tools/ios_logs.py for the container).
    recomp_env_apply_file((documents_dir() + "/switches.txt").c_str());
    ios_start_crash_monitor();
    ios_diagnostic("platform init; diagnostics v3 footprint peak available memory_warning interval=1s");
}

// Documents/game when it is ready. Anything else - no game yet, a bundled copy
// still to import, a wrong or partial import - is the launcher's to show.
GamePath platform_ui_resolve_game(const char *, std::string *error) {
    GamePath g;
    if (error)
        error->clear();
    const std::string docs = documents_dir() + "/game";
    const launcher::Status st = launcher::check(launcher::spec_from_config(), docs);
    if (st.state == launcher::State::Ready) {
        g.exe = st.exe;
        g.source = GamePathSource::Saved;
    }
    return g;
}

// ---------------------------------------------------------------------------
// The launcher's iPadOS platform: the document picker for a folder or a ZIP,
// imports into Documents/game (kept out of iCloud backups), the Files app and
// Finder as another way in, and a share sheet for exported saves.
// ---------------------------------------------------------------------------
@interface RecompPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property(nonatomic) launcher::PickDone done;
@property(nonatomic) bool scoped;
@end

namespace {
NSMutableArray<NSURL *> *g_scoped; // strongly retain security-scoped URLs until release
NSMutableArray *g_delegates;   // picker delegates alive until they answer
UIBackgroundTaskIdentifier g_background = UIBackgroundTaskInvalid;
} // namespace

@implementation RecompPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    std::vector<launcher::Picked> picked;
    for (NSURL *url in urls) {
        if (self.scoped && [url startAccessingSecurityScopedResource]) {
            if (!g_scoped)
                g_scoped = [NSMutableArray new];
            [g_scoped addObject:url]; // retain across the asynchronous import
        }
        launcher::Picked p;
        p.path = url.fileSystemRepresentation;
        p.name = url.lastPathComponent.UTF8String;
        picked.push_back(p);
    }
    if (self.done)
        self.done(picked, "");
    [g_delegates removeObject:self];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.done)
        self.done({}, "");
    [g_delegates removeObject:self];
}
@end

namespace {

UIViewController *top_controller(SDL_Window *window) {
    UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    UIViewController *vc = uiwindow.rootViewController;
    while (vc.presentedViewController)
        vc = vc.presentedViewController;
    return vc;
}

class IosPlatform final : public launcher::Platform {
  public:
    explicit IosPlatform(SDL_Window *window) : window_(window) {}

    launcher::PlatformInfo info() override {
        launcher::PlatformInfo i;
        i.plays_in_place = false;
        i.can_pick_folder = true;
        i.can_pick_zip = true;
        i.can_open_folder = false;
        i.touch = true;
        i.import_root = documents_dir() + "/game";
        i.profile_dir = host_layout().profile_dir;
        i.drop_hint =
            "Or copy the game folder into this app's files with Finder (iPad connected to a Mac) "
            "or the Files app, then open the app again.";
        const fs::path bundled = fs::path(bundle_dir()) / "game";
        std::error_code ec;
        if (fs::is_regular_file(bundled / RECOMP_EXECUTABLE, ec))
            i.auto_import = bundled.string();
        return i;
    }
    void present(UIDocumentPickerViewController *picker, launcher::PickDone done, bool scoped) {
        RecompPickerDelegate *delegate = [RecompPickerDelegate new];
        delegate.done = std::move(done);
        delegate.scoped = scoped;
        if (!g_delegates)
            g_delegates = [NSMutableArray new];
        [g_delegates addObject:delegate];
        picker.delegate = delegate;
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        [top_controller(window_) presentViewController:picker animated:YES completion:nil];
    }
    void pick_folder(launcher::PickDone done) override {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
        present(picker, std::move(done), true);
    }
    void pick_zip(launcher::PickDone done) override {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP ]];
        present(picker, std::move(done), true);
    }
    void pick_saves(launcher::PickDone done) override {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP ]
                                                                        asCopy:YES];
        present(picker, std::move(done), false);
    }
    // Written to a temporary file first; export_ready offers it to the player.
    void pick_export(const std::string &suggested, launcher::PickDone done) override {
        launcher::Picked p;
        p.path = std::string(NSTemporaryDirectory().fileSystemRepresentation) + "/" + suggested;
        p.name = suggested;
        done({p}, "");
    }
    void export_ready(const launcher::Picked &p) override {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:p.path.c_str()]];
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ url ] asCopy:YES];
        present(picker, nullptr, false);
    }
    std::vector<std::string> candidates(const launcher::Spec &spec) override {
        // A game folder the player copied into Documents under any name.
        std::vector<std::string> out;
        const std::string docs = documents_dir();
        std::error_code ec;
        for (const auto &entry : fs::directory_iterator(docs, ec)) {
            const std::string name = entry.path().filename().string();
            if (!entry.is_directory(ec) || name == "game" || name[0] == '.')
                continue;
            // The folder itself, so a move can remove all of it afterwards.
            if (!launcher::find_root(spec, entry.path().string()).empty())
                out.push_back(entry.path().string());
        }
        return out;
    }
    // A folder the player copied into Documents is moved into Documents/game.
    bool movable(const launcher::Picked &p) override {
        const std::string docs = documents_dir() + "/";
        return !p.path.empty() && p.path.compare(0, docs.size(), docs) == 0 &&
               p.path.find('/', docs.size()) == std::string::npos && p.path != docs + "game";
    }
    void open_url(const std::string &url) override {
        NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (u)
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
    void import_activity(bool active, const launcher::Progress *progress) override {
        if (progress)
            return;
        dispatch_block_t update = ^{
          [UIApplication sharedApplication].idleTimerDisabled = active;
          if (active && g_background == UIBackgroundTaskInvalid)
              g_background = [[UIApplication sharedApplication]
                  beginBackgroundTaskWithName:@"Import game"
                            expirationHandler:^{
                              [[UIApplication sharedApplication] endBackgroundTask:g_background];
                              g_background = UIBackgroundTaskInvalid;
                            }];
          else if (!active && g_background != UIBackgroundTaskInvalid) {
              [[UIApplication sharedApplication] endBackgroundTask:g_background];
              g_background = UIBackgroundTaskInvalid;
          }
        };
        if ([NSThread isMainThread])
            update();
        else
            dispatch_async(dispatch_get_main_queue(), update);
    }
    void protect_import(const std::string &root) override {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:root.c_str()]
                                isDirectory:YES];
        NSError *err = nil;
        if (![url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&err])
            fprintf(stderr, "[ios] could not exclude %s from backup: %s\n", root.c_str(),
                    err.localizedDescription.UTF8String);
    }
    void release(const launcher::Picked &p) override {
        ios_diagnostic("picker release requested");
        // Security-scoped URL access is a UIKit/Foundation operation. Serialize
        // it with the document-picker callback, which normally runs on the main thread.
        auto work = ^{
            const NSUInteger count = g_scoped.count;
            fprintf(stderr, "[ios][picker] release requested; active scopes=%lu\n",
                    (unsigned long)count);
            for (NSUInteger i = 0; i < count; ++i) {
                NSURL *url = g_scoped[i];
                const char *rawPath = url.fileSystemRepresentation;
                if (rawPath && p.path == rawPath) {
                    [url stopAccessingSecurityScopedResource];
                    [g_scoped removeObjectAtIndex:i];
                    fprintf(stderr, "[ios][picker] released scope\n");
                    ios_diagnostic("picker scope released");
                    return;
                }
            }
            fprintf(stderr, "[ios][picker] no matching active scope\n");
            ios_diagnostic("picker release had no matching scope");
        };
        if ([NSThread isMainThread])
            work();
        else
            dispatch_sync(dispatch_get_main_queue(), work);
    }

  private:
    SDL_Window *window_;
};

} // namespace

namespace launcher {
std::unique_ptr<Platform> make_platform(SDL_Window *window) {
    return std::make_unique<IosPlatform>(window);
}
} // namespace launcher

namespace {
// SDL3 does not queue the app lifecycle events; it hands them to event
// watchers on the UIKit callstack that raised them (SDL_SendAppEvent). The
// host's event loop therefore never sees them, and this watcher is the only
// place the background transition can be acted on before iOS freezes the
// process.
bool lifecycle_watch(void *, SDL_Event *e) {
    platform_ui_handle_lifecycle(*e);
    return true;
}
} // namespace

// A tiny native toggle that remains available when touch controls are in use.
// The actual FPS/frametime overlay is already drawn by present_thread.cpp from
// real presentation samples; this button only changes its saved display mode.
@interface RecompFpsToggle : UIButton
@end
@implementation RecompFpsToggle
- (void)refreshTitle {
    const BOOL on = mods_display_value(DISPLAY_OVERLAY) != 0;
    [self setTitle:(on ? @"FPS ON" : @"FPS OFF") forState:UIControlStateNormal];
    self.backgroundColor = on ? [[UIColor colorWithRed:0.05 green:0.24 blue:0.17 alpha:0.80] colorWithAlphaComponent:0.80]
                              : [UIColor colorWithWhite:0.05 alpha:0.65];
}
- (void)toggleFps:(id)sender {
    (void)sender;
    const int next = mods_display_value(DISPLAY_OVERLAY) ? 0 : 1;
    mods_menu_main_thread_call([next] { mods_display_set(DISPLAY_OVERLAY, next); });
    // The setting is queued onto the game thread; update the title on the
    // following tap, and schedule a visual refresh after the frame hook.
    [self setTitle:(next ? @"FPS ON" : @"FPS OFF") forState:UIControlStateNormal];
}
@end

static void install_fps_toggle(SDL_Window *window) {
    UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    if (!uiwindow)
        return;
    RecompFpsToggle *button = [[RecompFpsToggle alloc] initWithFrame:CGRectMake(10, 10, 76, 34)];
    button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 8;
    button.clipsToBounds = YES;
    button.accessibilityLabel = @"Toggle performance overlay";
    [button refreshTitle];
    [button addTarget:button action:@selector(toggleFps:) forControlEvents:UIControlEventTouchUpInside];
    [uiwindow addSubview:button];
}

SDL_Window *platform_ui_create_window(const char *title, int, int, int, int,
                                      SDL_WindowFlags surface_flag, int *window_mode) {
    static bool watching = false;
    if (!watching) {
        SDL_AddEventWatch(lifecycle_watch, nullptr);
        watching = true;
    }
    SDL_Window *w = SDL_CreateWindow(
        title, 0, 0, surface_flag | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window_mode)
        *window_mode = 2;
    if (w)
        install_fps_toggle(w);
    return w;
}

bool platform_ui_handle_lifecycle(const SDL_Event &e) {
    switch (e.type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
        ios_diagnostic("lifecycle will enter background");
        fprintf(stderr, "[ios] will enter background: suspending presentation and audio\n");
        host_present_suspend(true);
        host_audio_pause(true);
        return true;
    case SDL_EVENT_DID_ENTER_BACKGROUND:
        ios_diagnostic("lifecycle did enter background");
        fprintf(stderr, "[ios] did enter background\n");
        host_present_suspend(true);
        host_audio_pause(true);
        return true;
    case SDL_EVENT_WILL_ENTER_FOREGROUND:
        ios_diagnostic("lifecycle will enter foreground");
        fprintf(stderr, "[ios] will enter foreground\n");
        return true;
    case SDL_EVENT_DID_ENTER_FOREGROUND:
        ios_diagnostic("lifecycle did enter foreground");
        fprintf(stderr, "[ios] did enter foreground: resuming audio and presentation\n");
        host_audio_pause(false);
        host_present_suspend(false);
        return true;
    case SDL_EVENT_TERMINATING:
        ios_diagnostic("lifecycle terminating");
        fprintf(stderr, "[ios] terminating\n");
        host_present_suspend(true);
        host_audio_pause(true);
        return true;
    default:
        return false;
    }
}

bool platform_ui_keypad_wanted() {
    return !SDL_HasKeyboard();
}

bool platform_ui_touch_device() {
    return true;
}

bool platform_ui_pointer_capture_supported() {
    return false;
}

int platform_ui_default_overlay() {
    return 0;
}

void platform_ui_process_exit(int code) {
    char exit_event[80];
    snprintf(exit_event, sizeof(exit_event), "platform process exit code=%d", code);
    ios_diagnostic(exit_event);
    // UIApplicationMain never returns, so the game's own Exit would leave its
    // last frame on the screen; the game asked to end, and this ends it.
    fprintf(stderr, "[ios] the game exited (%d); ending the app\n", code);
    fflush(stderr);
    exit(code);
}

// ---------------------------------------------------------------------------
// Haptics: a light impact tick for on-screen control presses, and a Core
// Haptics continuous player standing in for game rumble on a device with no
// controller. Both must run on the main thread.
// ---------------------------------------------------------------------------
namespace {
UIImpactFeedbackGenerator *g_tap_generator;        // prepared once, reused for every tap
CHHapticEngine *g_haptic_engine;                   // created once, started lazily
id<CHHapticAdvancedPatternPlayer> g_rumble_player; // the current 30 s rumble, or nil

bool device_supports_haptics() {
    static const bool supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
    return supported;
}

// The engine, created on first use. A stop or reset (background, audio
// session interruption) drops the player, since it dies with the engine.
CHHapticEngine *haptic_engine() {
    if (!g_haptic_engine) {
        NSError *error = nil;
        g_haptic_engine = [[CHHapticEngine alloc] initAndReturnError:&error];
        if (error) {
            fprintf(stderr, "[ios] CHHapticEngine init failed: %s\n",
                    error.localizedDescription.UTF8String);
            return nil;
        }
        // Core Haptics calls both handlers on its own background queue; every
        // other read/write of g_rumble_player runs on the main queue (the
        // functions below), so hop there before touching it.
        g_haptic_engine.stoppedHandler = ^(CHHapticEngineStoppedReason) {
          dispatch_async(dispatch_get_main_queue(), ^{
            g_rumble_player = nil;
          });
        };
        g_haptic_engine.resetHandler = ^{
          dispatch_async(dispatch_get_main_queue(), ^{
            g_rumble_player = nil;
          });
        };
    }
    return g_haptic_engine;
}
} // namespace

void platform_ui_haptic_tap() {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_tap_generator) {
          g_tap_generator =
              [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
          [g_tap_generator prepare];
      }
      [g_tap_generator impactOccurred];
    });
}

void platform_ui_device_rumble(uint16_t low, uint16_t high) {
    const float intensity = std::max(low, high) / 65535.0f;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!device_supports_haptics())
          return;
      if (intensity <= 0.0f) {
          [g_rumble_player cancelAndReturnError:nil];
          g_rumble_player = nil;
          return;
      }
      NSError *error = nil;
      if (g_rumble_player) {
          // Already rumbling: retune it in place rather than restart it.
          CHHapticDynamicParameter *param = [[CHHapticDynamicParameter alloc]
              initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                            value:intensity
                     relativeTime:0];
          [g_rumble_player sendParameters:@[ param ] atTime:CHHapticTimeImmediate error:&error];
          if (!error)
              return;
          g_rumble_player = nil; // the player died under us; fall through and rebuild it
      }
      CHHapticEngine *engine = haptic_engine();
      if (!engine)
          return;
      [engine startAndReturnError:&error];
      if (error)
          return;
      CHHapticEventParameter *intensity_param = [[CHHapticEventParameter alloc]
          initWithParameterID:CHHapticEventParameterIDHapticIntensity
                        value:intensity];
      CHHapticEventParameter *sharpness_param = [[CHHapticEventParameter alloc]
          initWithParameterID:CHHapticEventParameterIDHapticSharpness
                        value:0.3f];
      CHHapticEvent *event =
          [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[ intensity_param, sharpness_param ]
                                      relativeTime:0
                                          duration:30.0];
      CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                              parameters:@[]
                                                                   error:&error];
      if (error)
          return;
      id<CHHapticAdvancedPatternPlayer> player = [engine createAdvancedPlayerWithPattern:pattern
                                                                                   error:&error];
      if (error || !player)
          return;
      [player startAtTime:CHHapticTimeImmediate error:&error];
      if (!error)
          g_rumble_player = player;
    });
}

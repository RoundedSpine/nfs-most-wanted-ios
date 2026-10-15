// platform_ui_ios.mm - the SDL host on iOS/iPadOS: one fullscreen Metal window, the
// game in Documents/game (imported by the launcher, from the bundle of a
// developer build or from files the player chose), the launcher's platform,
// and the app lifecycle mapped onto audio and presentation.
#include "platform_ui.h"

#include "../../platform/os.h"
#include "../../runtime/layout.h"
#include "../audio.h"
#include "../controls/rumble_pulses.h"
#include "../controls/rumble_mailbox.h"
#include "../launcher/launcher_sdl.h"
#include "../present.h"
#include "game_config.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <stdio.h>
#include <string>

namespace fs = std::filesystem;

namespace {

void haptics_lifecycle(bool active, bool terminating = false);
std::atomic<bool> g_shutdown_prepared{false};
std::atomic<bool> g_lifecycle_watching{false};

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
std::vector<NSURL *> g_scoped; // security-scoped URLs held for an import
NSMutableArray *g_delegates;   // picker delegates alive until they answer
UIBackgroundTaskIdentifier g_background = UIBackgroundTaskInvalid;
} // namespace

@implementation RecompPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    std::vector<launcher::Picked> picked;
    for (NSURL *url in urls) {
        if (self.scoped && [url startAccessingSecurityScopedResource])
            g_scoped.push_back(url);
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
        for (auto it = g_scoped.begin(); it != g_scoped.end(); ++it)
            if (p.path == (*it).fileSystemRepresentation) {
                [*it stopAccessingSecurityScopedResource];
                g_scoped.erase(it);
                return;
            }
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
    if (g_shutdown_prepared.load(std::memory_order_acquire))
        return true;
    platform_ui_handle_lifecycle(*e);
    return true;
}
} // namespace

SDL_Window *platform_ui_create_window(const char *title, int, int, int, int,
                                      SDL_WindowFlags surface_flag, int *window_mode) {
    // Startup switches override the default, including an empty value to opt out.
    // Keep generated shader records outside the signed bundle and game assets.
    if (!recomp_env("D3D9_SHADER_WARM_DIR")) {
        const fs::path cache = fs::path(host_layout().profile_dir) / "ShaderWarm";
        std::error_code error;
        fs::create_directories(cache, error);
        if (!error)
            os_setenv("RECOMP_D3D9_SHADER_WARM_DIR", cache.string().c_str());
    }
    if (!g_lifecycle_watching.exchange(true, std::memory_order_acq_rel)) {
        SDL_AddEventWatch(lifecycle_watch, nullptr);
    }
    SDL_Window *w = SDL_CreateWindow(
        title, 0, 0, surface_flag | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window_mode)
        *window_mode = 2;
    return w;
}

bool platform_ui_handle_lifecycle(const SDL_Event &e) {
    switch (e.type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
        haptics_lifecycle(false);
        fprintf(stderr, "[ios] will enter background: suspending presentation and audio\n");
        host_present_suspend(true);
        host_audio_pause(true);
        return true;
    case SDL_EVENT_DID_ENTER_BACKGROUND:
        haptics_lifecycle(false);
        fprintf(stderr, "[ios] did enter background\n");
        host_present_suspend(true);
        host_audio_pause(true);
        return true;
    case SDL_EVENT_WILL_ENTER_FOREGROUND:
        fprintf(stderr, "[ios] will enter foreground\n");
        return true;
    case SDL_EVENT_DID_ENTER_FOREGROUND:
        haptics_lifecycle(true);
        fprintf(stderr, "[ios] did enter foreground: resuming audio and presentation\n");
        host_audio_pause(false);
        host_present_suspend(false);
        return true;
    case SDL_EVENT_TERMINATING:
        platform_ui_prepare_shutdown();
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
    platform_ui_prepare_shutdown();
    // UIApplicationMain never returns, so the game's own Exit would leave its
    // last frame on the screen; the game asked to end, and this ends it.
    fprintf(stderr, "[ios] the game exited (%d); ending the app\n", code);
    fflush(stderr);
    exit(code);
}

// ---------------------------------------------------------------------------
// UIKit device feedback. The game still supplies strength and stop requests;
// paced impacts replace the app-owned Core Haptics engine and looping player.
// UIKit owns each short impact; stopping cancels future pulses, not an impact
// already issued. Generator objects and the pulse scheduler are main-queue owned.
// ---------------------------------------------------------------------------
namespace {
UIImpactFeedbackGenerator *g_tap_generator;
UIImpactFeedbackGenerator *g_rumble_generator;
controls::RumbleMailbox g_rumble_mailbox;
controls::RumblePulses g_rumble_pulses;
bool g_feedback_failed = false;
uint64_t g_impact_count = 0;
const char *g_feedback_stage = "idle";
void apply_latest_device_rumble();

// Keep a bounded, flushed app log for device-only failures. The header names
// the backend so an old Core Haptics trace cannot be mistaken for this build.
void haptic_trace(const char *stage, const char *detail = "") {
    static FILE *journal = [] {
        const std::string path = documents_dir() + "/haptics.log";
        rename(path.c_str(), (documents_dir() + "/haptics.previous.log").c_str());
        FILE *file = fopen(path.c_str(), "w");
        if (file)
            fprintf(file, "UIKit device feedback v1: iPhone/iPad iOS %s; interval=50ms\n",
                    UIDevice.currentDevice.systemVersion.UTF8String);
        return file;
    }();
    fprintf(stderr, "[ios] UIKit feedback %s %s\n", stage, detail);
    const long offset = journal ? ftell(journal) : -1;
    if (offset >= 0 && offset < 256 * 1024) {
        fprintf(journal, "%.3f %s %s\n", NSDate.date.timeIntervalSince1970, stage, detail);
        fflush(journal);
    }
}

void stop_device_feedback() {
    const bool was_active = g_rumble_pulses.active();
    g_rumble_pulses.stop();
    if (was_active)
        haptic_trace("future impacts cancelled");
    // Keep the reusable generator alive across game stop requests. There is no
    // framework player-stop call or generator teardown on the zero-strength path.
}

void feedback_exception(NSException *exception) {
    haptic_trace(g_feedback_stage, exception.description.UTF8String);
    g_feedback_failed = true;
    stop_device_feedback();
}

void apply_latest_device_rumble() {
    const auto request = g_rumble_mailbox.latest();
    if (!request.active || g_shutdown_prepared.load(std::memory_order_acquire) ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        !request.strength || g_feedback_failed) {
        stop_device_feedback();
        return;
    }
    const auto step = g_rumble_pulses.request(request.strength, os_monotonic_ns());
    @try {
        if (step.impact) {
            if (!g_rumble_generator) {
                g_feedback_stage = "rumble generator creation";
                haptic_trace(g_feedback_stage);
                g_rumble_generator =
                    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                if (!g_rumble_generator) {
                    g_feedback_failed = true;
                    stop_device_feedback();
                    return;
                }
                g_feedback_stage = "rumble prepare";
                [g_rumble_generator prepare];
            }
            char detail[96];
            const uint64_t impact = ++g_impact_count;
            const CGFloat intensity = request.strength / 65535.0;
            snprintf(detail, sizeof detail, "impact=%llu strength=%u intensity=%.6f",
                     (unsigned long long)impact, (unsigned)request.strength, (double)intensity);
            g_feedback_stage = "rumble impact request";
            if (impact <= 64)
                haptic_trace(g_feedback_stage, detail);
            [g_rumble_generator impactOccurredWithIntensity:intensity];
            g_feedback_stage = "rumble impact returned";
            if (impact <= 64)
                haptic_trace(g_feedback_stage, detail);
        }
    } @catch (NSException *exception) {
        feedback_exception(exception);
        return;
    }
    if (step.schedule) {
        const uint64_t generation = step.generation;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)step.delay_ns), dispatch_get_main_queue(), ^{
              if (g_rumble_pulses.consume_timer(generation))
                  apply_latest_device_rumble(); // current strength, stop or lifecycle state
            });
    }
}

// Coalesce producer bursts into one queued drain. The independently paced timer
// re-reads the mailbox; it never replays a captured, stale nonzero strength.
void drain_device_rumble() {
    const auto request = g_rumble_mailbox.latest();
    apply_latest_device_rumble();
    if (g_rumble_mailbox.finish(request.sequence))
        dispatch_async(dispatch_get_main_queue(), ^{
          drain_device_rumble();
        });
}

void haptics_lifecycle(bool active, bool terminating) {
    if (terminating)
        g_rumble_mailbox.terminate();
    else
        g_rumble_mailbox.set_active(active);
    void (^update)(void) = ^{
      stop_device_feedback();
      if (active && !g_shutdown_prepared.load(std::memory_order_acquire))
          g_feedback_failed = false;
    };
    if (NSThread.isMainThread)
        update();
    else
        dispatch_async(dispatch_get_main_queue(), update);
}
} // namespace

void platform_ui_prepare_shutdown() {
    if (g_shutdown_prepared.exchange(true, std::memory_order_acq_rel))
        return;
    g_rumble_mailbox.terminate();
    if (g_lifecycle_watching.exchange(false, std::memory_order_acq_rel))
        SDL_RemoveEventWatch(lifecycle_watch, nullptr);
    void (^cleanup)(void) = ^{
      stop_device_feedback();
      g_rumble_generator = nil;
      g_tap_generator = nil;
    };
    if (NSThread.isMainThread) {
        cleanup();
    } else {
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
          cleanup();
          dispatch_semaphore_signal(ready);
        });
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) {
            fprintf(stderr, "[ios] main queue did not acknowledge shutdown; ending safely\n");
            fflush(stderr);
            _Exit(6);
        }
    }
}

void platform_ui_haptic_tap() {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_rumble_mailbox.latest().active || g_feedback_failed ||
          UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
          return;
      @try {
          if (!g_tap_generator) {
              g_feedback_stage = "touch generator creation";
              g_tap_generator =
                  [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
              [g_tap_generator prepare];
          }
          g_feedback_stage = "touch impact";
          [g_tap_generator impactOccurred];
      } @catch (NSException *exception) {
          feedback_exception(exception);
      }
    });
}

void platform_ui_device_rumble(uint16_t low, uint16_t high) {
#if defined(NFSMW_DISABLE_DEVICE_HAPTICS) && NFSMW_DISABLE_DEVICE_HAPTICS
    (void)low;
    (void)high;
#else
    if (g_rumble_mailbox.publish(std::max(low, high)))
        dispatch_async(dispatch_get_main_queue(), ^{
          drain_device_rumble();
        });
#endif
}

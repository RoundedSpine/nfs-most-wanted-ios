// platform_ui_ios.mm - the SDL host on iOS/iPadOS: one fullscreen Metal window, the
// game in Documents/game (imported by the launcher, from the bundle of a
// developer build or from files the player chose), the launcher's platform,
// and the app lifecycle mapped onto audio and presentation.
#include "platform_ui.h"

#include "../../platform/os.h"
#include "../../runtime/layout.h"
#include "../audio.h"
#include "../controls/haptic_startup.h"
#include "../controls/haptic_intensity.h"
#include "../controls/haptic_player_state.h"
#include "../controls/rumble_mailbox.h"
#include "../launcher/launcher_sdl.h"
#include "../present.h"
#include "game_config.h"

#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
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
// Core Haptics device rumble. Player/engine objects belong to the main queue;
// callback threads publish invalidation epochs, never clear a newer player.
// ---------------------------------------------------------------------------
namespace {
UIImpactFeedbackGenerator *g_tap_generator;
CHHapticEngine *g_haptic_engine;
id<CHHapticAdvancedPatternPlayer> g_rumble_player;
std::shared_ptr<controls::HapticPlayerState> g_player_state;
controls::RumbleMailbox g_rumble_mailbox;
std::atomic<uint64_t> g_engine_epoch{0};
std::atomic<uint64_t> g_engine_reset_epoch{0};
uint64_t g_seen_engine_epoch = 0;
uint64_t g_seen_engine_reset_epoch = 0;
uint64_t g_player_generation = 0;
controls::HapticStartup g_engine_startup;
controls::HapticIntensity g_haptic_intensity;
bool g_intensity_update_pending = false;
uint64_t g_intensity_update_count = 0;
bool g_engine_running = false;
bool g_engine_stopping = false;
bool g_haptic_failed = false;
const char *g_haptic_stage = "idle";
void apply_latest_device_rumble();

// Keep the first-vibration path in an accessible, bounded log even when iOS
// terminates us before stderr can be collected. Flush BEFORE framework calls.
void haptic_trace(const char *stage, const char *detail = "") {
    static FILE *journal = [] {
        const std::string path = documents_dir() + "/haptics.log";
        rename(path.c_str(), (documents_dir() + "/haptics.previous.log").c_str());
        FILE *file = fopen(path.c_str(), "w");
        if (file)
            fprintf(file, "Core Haptics startup trace: %s iOS %s\n",
                    UIDevice.currentDevice.model.UTF8String,
                    UIDevice.currentDevice.systemVersion.UTF8String);
        return file;
    }();
    fprintf(stderr, "[ios] Core Haptics %s %s\n", stage, detail);
    if (journal && ftell(journal) < 256 * 1024) {
        fprintf(journal, "%.3f %s %s\n", NSDate.date.timeIntervalSince1970, stage, detail);
        fflush(journal);
    }
}

void haptic_stage(const char *stage) {
    // Do not write a line for every intensity update during sustained rumble.
    if (strcmp(g_haptic_stage, stage) != 0)
        haptic_trace(stage);
    g_haptic_stage = stage;
}

void forget_rumble_player() {
    g_rumble_player = nil;
    g_player_state.reset();
    g_intensity_update_pending = false;
    ++g_player_generation;
}

// May be called by a queued callback after a newer player has started. Only
// invalidate when its engine epoch is actually newer than the observed epoch.
void reconcile_haptic_engine() {
    const uint64_t epoch = g_engine_epoch.load(std::memory_order_acquire);
    if (epoch == g_seen_engine_epoch)
        return;
    g_engine_startup.invalidate();
    g_seen_engine_epoch = epoch;
    g_engine_running = false;
    const uint64_t reset = g_engine_reset_epoch.load(std::memory_order_acquire);
    if (reset != g_seen_engine_reset_epoch) {
        g_seen_engine_reset_epoch = reset;
        g_haptic_failed = false;
    }
    forget_rumble_player();
}

void haptic_error(const char *operation, NSError *error) {
    haptic_trace(operation, error ? error.description.UTF8String : "no NSError supplied");
    fprintf(stderr, "[ios] Core Haptics %s failed: %s (%ld)\n", operation,
            error ? error.localizedDescription.UTF8String : "no error details",
            error ? (long)error.code : 0L);
}

// An update failure must not leave a looping effect buzzing after the player
// reference is discarded. Don't restart until this asynchronous stop finishes.
void shutdown_haptic_engine() {
    if (!g_haptic_engine || g_engine_stopping)
        return;
    g_engine_startup.invalidate();
    g_engine_stopping = true;
    @try {
        [g_haptic_engine stopWithCompletionHandler:^(NSError *error) {
          if (g_shutdown_prepared.load(std::memory_order_acquire))
              return;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (g_shutdown_prepared.load(std::memory_order_acquire))
                return;
            g_engine_stopping = false;
            if (error)
                haptic_error("engine shutdown", error);
          });
        }];
    } @catch (NSException *exception) {
        g_engine_stopping = false;
        fprintf(stderr, "[ios] Core Haptics shutdown exception: %s\n", exception.reason.UTF8String);
    }
}

// Do not repeatedly call a failed framework object on every guest frame.
// An engine reset or foreground transition permits a fresh attempt.
void fail_haptic_session(const char *operation, NSError *error) {
    haptic_error(operation, error);
    g_haptic_failed = true;
    g_engine_startup.invalidate();
    g_engine_running = false;
    forget_rumble_player();
    shutdown_haptic_engine();
}

bool device_supports_haptics() {
    static const bool supported = [] {
        haptic_stage("hardware capabilities");
        return CHHapticEngine.capabilitiesForHardware.supportsHaptics;
    }();
    return supported;
}

CHHapticEngine *haptic_engine() {
    if (g_haptic_engine)
        return g_haptic_engine;
    haptic_stage("engine initialization");
    NSError *error = nil;
    CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!engine || error) {
        fail_haptic_session(g_haptic_stage, error);
        return nil;
    }
    // These patterns contain no audio. Set before startup to avoid bringing
    // up the engine's audio event path and reduce haptic startup latency.
    haptic_stage("engine configuration");
    engine.playsHapticsOnly = YES;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
      if (g_shutdown_prepared.load(std::memory_order_acquire))
          return;
      g_engine_epoch.fetch_add(1, std::memory_order_acq_rel);
      fprintf(stderr, "[ios] Core Haptics engine stopped: %ld\n", (long)reason);
      dispatch_async(dispatch_get_main_queue(), ^{
        reconcile_haptic_engine();
      });
    };
    engine.resetHandler = ^{
      if (g_shutdown_prepared.load(std::memory_order_acquire))
          return;
      g_engine_reset_epoch.fetch_add(1, std::memory_order_acq_rel);
      g_engine_epoch.fetch_add(1, std::memory_order_acq_rel);
      fprintf(stderr, "[ios] Core Haptics engine reset\n");
      dispatch_async(dispatch_get_main_queue(), ^{
        reconcile_haptic_engine();
      });
    };
    g_haptic_engine = engine;
    return engine;
}

void stop_rumble_player() {
    // Keep a strong local reference until stop completes; clear ownership
    // first so a delayed completion cannot discard the next player.
    id<CHHapticAdvancedPatternPlayer> player = g_rumble_player;
    const auto state = g_player_state;
    forget_rumble_player();
    if (!player || !g_engine_running || !state ||
        !state->usable(g_engine_epoch.load(std::memory_order_acquire)))
        return;
    NSError *error = nil;
    haptic_stage("player stop");
    if (![player stopAtTime:CHHapticTimeImmediate error:&error] || error)
        fail_haptic_session(g_haptic_stage, error);
}

// Preserve continuous Core Haptics rumble rather than substitute tap feedback.
// Framework calls are serialized here and every result is checked.
void apply_device_rumble(uint16_t strength) {
    reconcile_haptic_engine();
    if (!strength) {
        stop_rumble_player();
        return;
    }
    if (g_haptic_failed || g_engine_stopping || g_engine_startup.pending())
        return;
    if (!device_supports_haptics())
        return;
    NSError *error = nil;
    const float intensity = strength / 65535.0f;
    if (g_rumble_player) {
        const auto state = g_player_state;
        if (!state || !state->usable(g_engine_epoch.load(std::memory_order_acquire))) {
            haptic_trace("intensity update skipped",
                         "player completion or engine invalidation pending");
            return; // completion/reset is known; owner cleanup may still be queued
        }
        // The pattern already carries its initial intensity. Avoid sending the
        // same value back to a player just milliseconds after startAtTime.
        if (g_haptic_intensity.unchanged(strength))
            return;
        static const bool dynamic_updates = [] {
            const char *value = recomp_env("HAPTICS_DYNAMIC_UPDATES");
            const bool enabled = !value || strcmp(value, "0") != 0;
            haptic_trace("dynamic intensity updates",
                         enabled ? "enabled" : "bypassed for diagnosis");
            return enabled;
        }();
        if (!dynamic_updates)
            return;
        const uint64_t delay = g_haptic_intensity.delay_ns(os_monotonic_ns());
        if (delay) {
            if (!g_intensity_update_pending) {
                g_intensity_update_pending = true;
                const uint64_t generation = g_player_generation;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay),
                               dispatch_get_main_queue(), ^{
                                 // A stop, reset or replacement cancels the old player's work.
                                 // Never clear ownership of a newer player's pending update.
                                 if (generation != g_player_generation ||
                                     g_shutdown_prepared.load(std::memory_order_acquire))
                                     return;
                                 g_intensity_update_pending = false;
                                 apply_latest_device_rumble();
                               });
            }
            return;
        }
        // Keep ownership through the call, even if the framework invalidates
        // its player internally. Callback processing stays on the main queue.
        id<CHHapticAdvancedPatternPlayer> player = g_rumble_player;
        CHHapticDynamicParameter *parameter = [[CHHapticDynamicParameter alloc]
            initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                          value:intensity
                   relativeTime:0];
        char detail[96];
        const uint64_t update = ++g_intensity_update_count;
        snprintf(detail, sizeof detail, "update=%llu strength=%u value=%.6f",
                 (unsigned long long)update, (unsigned)strength, intensity);
        // Detailed before/after breadcrumbs for the first second of updates;
        // later framework errors are always recorded without per-frame I/O.
        g_haptic_stage = "player intensity update";
        if (update <= 64)
            haptic_trace(g_haptic_stage, detail);
        // The callback can run during parameter construction and tracing too.
        if (!state->usable(g_engine_epoch.load(std::memory_order_acquire))) {
            haptic_trace("intensity update skipped", "player completed or engine invalidated");
            return;
        }
        const BOOL updated = [player sendParameters:@[ parameter ]
                                             atTime:CHHapticTimeImmediate
                                              error:&error];
        if (!updated || error) {
            fail_haptic_session(g_haptic_stage, error);
            return;
        }
        g_haptic_intensity.applied(strength, os_monotonic_ns());
        g_haptic_stage = "player intensity update returned";
        if (update <= 64)
            haptic_trace(g_haptic_stage, detail);
        return;
    }

    CHHapticEngine *engine = haptic_engine();
    if (!engine)
        return;
    const uint64_t epoch = g_engine_epoch.load(std::memory_order_acquire);
    if (!g_engine_running) {
        haptic_stage("engine start requested");
        const uint64_t ticket = g_engine_startup.begin();
        // First startup can talk to the haptics/audio service. Never block the
        // UIKit run loop waiting for that service; resume from its completion.
        [engine startWithCompletionHandler:^(NSError *start_error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (g_shutdown_prepared.load(std::memory_order_acquire) ||
                !g_engine_startup.complete(ticket))
                return;
            haptic_trace("engine start completed");
            if (epoch != g_engine_epoch.load(std::memory_order_acquire)) {
                reconcile_haptic_engine();
                return;
            }
            if (start_error) {
                fail_haptic_session("engine start", start_error);
                return;
            }
            g_engine_running = true;
            // Read the CURRENT request, not the strength that started us. A
            // stop or background transition while starting must stay stopped.
            apply_latest_device_rumble();
          });
        }];
        return;
    }
    haptic_stage("event creation");
    CHHapticEventParameter *base_intensity =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                      value:1.0f];
    CHHapticEventParameter *sharpness =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                      value:0.3f];
    constexpr NSTimeInterval duration = 30.0;
    CHHapticEvent *event =
        [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                      parameters:@[ base_intensity, sharpness ]
                                    relativeTime:0
                                        duration:duration];
    // The base intensity is 1; initial and later controls use the same scale.
    CHHapticDynamicParameter *initial_intensity = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                      value:intensity
               relativeTime:0];
    haptic_stage("pattern creation");
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                            parameters:@[ initial_intensity ]
                                                                 error:&error];
    if (!pattern || error) {
        fail_haptic_session(g_haptic_stage, error);
        return;
    }
    haptic_stage("player creation");
    id<CHHapticAdvancedPatternPlayer> player = [engine createAdvancedPlayerWithPattern:pattern
                                                                                 error:&error];
    if (!player || error) {
        fail_haptic_session(g_haptic_stage, error);
        return;
    }
    // Loop while the guest requests rumble, instead of messaging a cached
    // player after its 30-second event has finished.
    haptic_stage("player loop configuration");
    player.loopEnd = duration;
    player.loopEnabled = YES;
    const uint64_t generation = ++g_player_generation;
    const auto state = std::make_shared<controls::HapticPlayerState>(epoch);
    player.completionHandler = ^(NSError *completion_error) {
      // Publish immediately on the callback thread. A queued main-thread update
      // must not treat this player as live while its cleanup is waiting below.
      state->complete();
      if (g_shutdown_prepared.load(std::memory_order_acquire))
          return;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != g_player_generation)
            return;
        haptic_trace("player completion callback",
                     completion_error ? completion_error.description.UTF8String : "no error");
        forget_rumble_player();
        if (completion_error)
            fail_haptic_session("player completion", completion_error);
      });
    };
    if (!state->usable(g_engine_epoch.load(std::memory_order_acquire))) {
        reconcile_haptic_engine();
        return;
    }
    haptic_stage("player start");
    if (![player startAtTime:CHHapticTimeImmediate error:&error] || error) {
        fail_haptic_session(g_haptic_stage, error);
        return;
    }
    if (epoch != g_engine_epoch.load(std::memory_order_acquire)) {
        reconcile_haptic_engine();
        return;
    }
    g_rumble_player = player;
    g_player_state = state;
    g_haptic_intensity.applied(strength, os_monotonic_ns());
    haptic_stage("player started");
}

// Both the mailbox drain and asynchronous startup resume through this guard.
void apply_latest_device_rumble() {
    const auto request = g_rumble_mailbox.latest();
    if (request.active &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        @try {
            apply_device_rumble(request.strength);
        } @catch (NSException *exception) {
            fprintf(stderr, "[ios] Core Haptics exception during %s: %s: %s\n", g_haptic_stage,
                    exception.name.UTF8String, exception.reason.UTF8String);
            haptic_trace(g_haptic_stage, exception.description.UTF8String);
            g_haptic_failed = true;
            g_engine_startup.invalidate();
            g_engine_running = false;
            forget_rumble_player();
            shutdown_haptic_engine();
        }
    }
}

void drain_device_rumble() {
    const auto request = g_rumble_mailbox.latest();
    apply_latest_device_rumble();
    if (g_rumble_mailbox.finish(request.sequence))
        dispatch_async(dispatch_get_main_queue(), ^{
          drain_device_rumble();
        });
}

// The watcher can invalidate requests immediately; UIKit objects remain main
// queue owned. Old requests cannot resume after returning from the background.
void haptics_lifecycle(bool active, bool terminating) {
    if (terminating)
        g_rumble_mailbox.terminate();
    else
        g_rumble_mailbox.set_active(active);
    void (^update)(void) = ^{
      @try {
          reconcile_haptic_engine();
          if (!active) {
              stop_rumble_player();
              g_tap_generator = nil;
          } else {
              g_haptic_failed = false;
          }
      } @catch (NSException *exception) {
          fprintf(stderr, "[ios] Core Haptics lifecycle exception: %s\n",
                  exception.reason.UTF8String);
          g_haptic_failed = true;
          forget_rumble_player();
          shutdown_haptic_engine();
      }
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
      @try {
          // Remove future engine notifications before initiating stop. Already
          // queued drains see a permanently terminated mailbox.
          g_engine_startup.invalidate();
          g_haptic_engine.stoppedHandler = nil;
          g_haptic_engine.resetHandler = nil;
          g_rumble_player.completionHandler = nil;
          stop_rumble_player();
          shutdown_haptic_engine();
          g_tap_generator = nil;
      } @catch (NSException *exception) {
          fprintf(stderr, "[ios] Core Haptics shutdown exception: %s\n",
                  exception.reason.UTF8String);
          forget_rumble_player();
          shutdown_haptic_engine();
      }
    };
    if (NSThread.isMainThread) {
        cleanup();
    } else {
        // Do not free SDL/UI resources ahead of main-queue cleanup. A bound
        // avoids deadlocking if the main queue cannot service this request.
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
      if (!g_rumble_mailbox.latest().active ||
          UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
          return;
      if (!g_tap_generator) {
          g_tap_generator =
              [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
          [g_tap_generator prepare];
      }
      [g_tap_generator impactOccurred];
    });
}

void platform_ui_device_rumble(uint16_t low, uint16_t high) {
#if defined(NFSMW_DISABLE_DEVICE_CORE_HAPTICS) && NFSMW_DISABLE_DEVICE_CORE_HAPTICS
    (void)low;
    (void)high;
#else
    if (g_rumble_mailbox.publish(std::max(low, high)))
        dispatch_async(dispatch_get_main_queue(), ^{
          drain_device_rumble();
        });
#endif
}

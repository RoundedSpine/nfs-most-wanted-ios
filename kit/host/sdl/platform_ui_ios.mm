// platform_ui_ios.mm - the SDL host on iOS/iPadOS: one fullscreen Metal window, the
// game in Documents/game (imported by the launcher, from the bundle of a
// developer build or from files the player chose), the launcher's platform,
// and the app lifecycle mapped onto audio and presentation.
#include "platform_ui.h"
#include "haptic_drain_scheduler.h"

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
#include <inttypes.h>
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <limits.h>
#include <cstring>
#include <sys/ucontext.h>
#include <time.h>


namespace {
std::mutex g_diag_mutex;
void ios_diagnostic(const char *event);

std::atomic<bool> g_crash_monitor_started{false};
std::atomic<unsigned long long> g_peak_footprint{0};
int g_crash_fd = -1;
std::atomic<uintptr_t> g_haptic_receiver{0};
std::atomic<uint64_t> g_haptic_generation{0};
std::atomic<unsigned int> g_haptic_phase{0}; // 1 stop, 2 update, 3 start
std::atomic<uint64_t> g_haptic_operation_serial{0};
std::atomic<uint64_t> g_haptic_engine_epoch_snapshot{0};
std::atomic<uintptr_t> g_haptic_engine_pointer{0};
std::atomic<uint64_t> g_haptic_main_thread{0};
std::atomic<uint64_t> g_haptic_stop_begin_ns{0};
std::atomic<uint64_t> g_haptic_last_start_ns{0};
std::atomic<uint64_t> g_haptic_last_stop_ns{0};
std::atomic<uintptr_t> g_haptic_stop_selector{0};
std::atomic<uint64_t> g_haptic_stop_thread_id{0};
std::atomic<uintptr_t> g_haptic_stop_player_at_entry{0};

void crash_hex(const char *label, uintptr_t value) {
    if (g_crash_fd < 0) return;
    size_t n = 0;
    while (label[n]) ++n;
    (void)write(g_crash_fd, label, n);
    char digits_out[2 * sizeof(uintptr_t)];
    const char digits[] = "0123456789abcdef";
    for (unsigned int i = 0; i < sizeof(digits_out); ++i) {
        digits_out[sizeof(digits_out) - i - 1] = digits[value & 15u];
        value >>= 4;
    }
    (void)write(g_crash_fd, digits_out, sizeof(digits_out));
}


// The signal handler only uses async-signal-safe operations. The native .ips
// report and matching dSYM are still needed for full symbolicated stacks.
void ios_fatal_signal(int signo, siginfo_t *info, void *context) {
    // Identify the process and time before register capture.
    crash_hex("pid=0x", static_cast<uintptr_t>(getpid()));
    struct timespec ts = {};
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0) {
        crash_hex(" epoch_sec=0x", static_cast<uintptr_t>(ts.tv_sec));
        crash_hex(" epoch_nsec=0x", static_cast<uintptr_t>(ts.tv_nsec));
    }
    static const char prefix[] = "fatal signal ";
    // Include the fault address in the async-signal-safe log as hexadecimal.
    static const char addr_prefix[] = " address=0x";
    static const char suffix[] = "\n";
    char number[24];
    unsigned int n = signo < 0 ? 0u : static_cast<unsigned int>(signo);
    int pos = 0;
    do { number[pos++] = char('0' + n % 10); n /= 10; } while (n && pos < 20);
    if (g_crash_fd >= 0) {
        (void)write(g_crash_fd, prefix, sizeof(prefix) - 1);
        while (pos) { --pos; (void)write(g_crash_fd, &number[pos], 1); }
        (void)write(g_crash_fd, addr_prefix, sizeof(addr_prefix) - 1);
        uintptr_t address = info ? reinterpret_cast<uintptr_t>(info->si_addr) : 0;
        char hex[2 * sizeof(uintptr_t)];
        const char digits[] = "0123456789abcdef";
        for (unsigned int i = 0; i < sizeof(hex); ++i) {
            hex[sizeof(hex) - i - 1] = digits[address & 15u];
            address >>= 4;
        }
        (void)write(g_crash_fd, hex, sizeof(hex));
        (void)write(g_crash_fd, suffix, sizeof(suffix) - 1);
        crash_hex("haptic phase=0x", g_haptic_phase.load(std::memory_order_relaxed));
        crash_hex(" receiver=0x", g_haptic_receiver.load(std::memory_order_relaxed));
        crash_hex(" generation=0x", g_haptic_generation.load(std::memory_order_relaxed));
        crash_hex(" operation_serial=0x", g_haptic_operation_serial.load(std::memory_order_relaxed));
        crash_hex(" engine_epoch=0x", g_haptic_engine_epoch_snapshot.load(std::memory_order_relaxed));
        crash_hex(" engine_ptr=0x", g_haptic_engine_pointer.load(std::memory_order_relaxed));
        crash_hex(" main_thread=0x", g_haptic_main_thread.load(std::memory_order_relaxed));
        crash_hex(" stop_begin_ns=0x", g_haptic_stop_begin_ns.load(std::memory_order_relaxed));
        crash_hex(" last_start_ns=0x", g_haptic_last_start_ns.load(std::memory_order_relaxed));
        crash_hex(" last_stop_ns=0x", g_haptic_last_stop_ns.load(std::memory_order_relaxed));
        crash_hex(" stop_selector=0x", g_haptic_stop_selector.load(std::memory_order_relaxed));
        crash_hex(" stop_thread_id=0x", g_haptic_stop_thread_id.load(std::memory_order_relaxed));
        crash_hex(" stop_player_at_entry=0x", g_haptic_stop_player_at_entry.load(std::memory_order_relaxed));

        crash_hex(" signal_code=0x", static_cast<uintptr_t>(info ? info->si_code : 0));
#if defined(__aarch64__) || defined(__arm64__)
        const auto *uc = static_cast<const ucontext_t *>(context);
        if (uc && uc->uc_mcontext) {
            const auto &state = uc->uc_mcontext->__ss;
            crash_hex(" pc=0x", state.__pc);
            crash_hex(" lr=0x", state.__lr);
            crash_hex(" far=0x", uc->uc_mcontext->__es.__far);
            crash_hex(" x0=0x", state.__x[0]);
            crash_hex(" x1=0x", state.__x[1]);
            crash_hex(" x2=0x", state.__x[2]);
            crash_hex(" x19=0x", state.__x[19]);
            crash_hex(" x20=0x", state.__x[20]);
            crash_hex(" x21=0x", state.__x[21]);
            crash_hex(" fp=0x", state.__fp);
            crash_hex(" sp=0x", state.__sp);
            crash_hex(" cpsr=0x", state.__cpsr);
            crash_hex(" x22=0x", state.__x[22]);
            crash_hex(" x23=0x", state.__x[23]);
            crash_hex(" x24=0x", state.__x[24]);
            crash_hex(" x25=0x", state.__x[25]);
            crash_hex(" x26=0x", state.__x[26]);
            crash_hex(" x27=0x", state.__x[27]);
            crash_hex(" x28=0x", state.__x[28]);
            for (unsigned int reg = 3; reg <= 18; ++reg) {
                static const char *labels[] = {" x3=0x", " x4=0x", " x5=0x", " x6=0x", " x7=0x", " x8=0x", " x9=0x", " x10=0x", " x11=0x", " x12=0x", " x13=0x", " x14=0x", " x15=0x", " x16=0x", " x17=0x", " x18=0x"};
                crash_hex(labels[reg - 3], state.__x[reg]);
            }
        }
#endif
        (void)write(g_crash_fd, suffix, sizeof(suffix) - 1);
    }
    // Re-raise with the default disposition to preserve the iOS crash report.
    struct sigaction def = {};
    def.sa_handler = SIG_DFL;
    sigemptyset(&def.sa_mask);
    sigaction(signo, &def, nullptr);
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, signo);
    sigprocmask(SIG_UNBLOCK, &unblock, nullptr);
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


 // Capture executable Mach-O segments individually. A min/max union across
// all segments can cover unmapped gaps and incorrectly attribute a fault PC.
// Do not call dyld or Objective-C APIs from the fatal signal handler.
void ios_capture_loaded_images(const char *reason) {
    static std::mutex image_mutex;
    static auto last_capture = std::chrono::steady_clock::time_point::min();
    std::lock_guard<std::mutex> guard(image_mutex);
    const auto now = std::chrono::steady_clock::now();
    if (last_capture != std::chrono::steady_clock::time_point::min() &&
        now - last_capture < std::chrono::seconds(1)) return;
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (!dirs.count) return;
        NSString *folder = [dirs[0] stringByAppendingPathComponent:@"diagnostics"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                        withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [folder stringByAppendingPathComponent:@"loaded-images.log"];
        FILE *out = fopen(path.fileSystemRepresentation, "a");
        if (!out) return;
        last_capture = now;
        const uint32_t count = _dyld_image_count();
        fprintf(out, "SNAPSHOT_BEGIN version=2 pid=%d reason=%s count=%u\n",
                (int)getpid(), reason, count);
        for (uint32_t i = 0; i < count; ++i) {
            const mach_header *header = _dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) continue;
            const auto *h = reinterpret_cast<const mach_header_64 *>(header);
            const intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            const char *name = _dyld_get_image_name(i);
            unsigned char uuid[16] = {};
            bool has_uuid = false;
            const uint8_t *cursor = reinterpret_cast<const uint8_t *>(h + 1);
            const uint8_t *end = cursor + h->sizeofcmds;
            // First pass: UUID for the image header. Second pass: exact
            // executable ranges, which may be discontiguous.
            for (uint32_t c = 0; c < h->ncmds; ++c) {
                if (cursor > end || static_cast<size_t>(end - cursor) < sizeof(load_command)) break;
                const auto *cmd = reinterpret_cast<const load_command *>(cursor);
                if (cmd->cmdsize < sizeof(load_command) ||
                    static_cast<size_t>(end - cursor) < cmd->cmdsize) break;
                if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(uuid_command)) {
                    std::memcpy(uuid, reinterpret_cast<const uuid_command *>(cmd)->uuid, 16);
                    has_uuid = true;
                }
                cursor += cmd->cmdsize;
            }
            fprintf(out, "IMAGE index=%u header=%p slide=%lld uuid=",
                    i, (const void *)header, (long long)slide);
            if (has_uuid) {
                for (unsigned char b : uuid) fprintf(out, "%02x", b);
            } else fputs("unknown", out);
            fprintf(out, " path=%s\n", name ? name : "(unknown)");
            cursor = reinterpret_cast<const uint8_t *>(h + 1);
            for (uint32_t c = 0; c < h->ncmds; ++c) {
                if (cursor > end || static_cast<size_t>(end - cursor) < sizeof(load_command)) break;
                const auto *cmd = reinterpret_cast<const load_command *>(cursor);
                if (cmd->cmdsize < sizeof(load_command) ||
                    static_cast<size_t>(end - cursor) < cmd->cmdsize) break;
                if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(segment_command_64)) {
                    const auto *seg = reinterpret_cast<const segment_command_64 *>(cmd);
                    if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmsize) {
                        const __int128 first = static_cast<__int128>(seg->vmaddr) + slide;
                        const __int128 last = first + seg->vmsize;
                        if (first >= 0 && last > first &&
                            last <= static_cast<__int128>(UINTPTR_MAX)) {
                            fprintf(out, "EXEC index=%u start=0x%llx end=0x%llx segment=%.*s\n",
                                    i, (unsigned long long)first, (unsigned long long)last,
                                    (int)sizeof(seg->segname), seg->segname);
                        }
                    }
                }
                cursor += cmd->cmdsize;
            }
        }
        fputs("SNAPSHOT_END\n", out);
        fflush(out);
        fclose(out);
    }
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
    ios_diagnostic("platform init; diagnostics v4 loaded image mapping footprint peak available memory_warning interval=1s");
    ios_capture_loaded_images("startup");
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
UIImpactFeedbackGenerator *g_tap_generator;
CHHapticEngine *g_haptic_engine;
id<CHHapticAdvancedPatternPlayer> g_rumble_player;
bool g_rumble_active = false;
// Serialized on the main queue; generations identify distinct player lifetimes.
uint64_t g_rumble_generation = 0;
uint64_t g_rumble_next_generation = 0;
uint64_t g_rumble_sequence = 0;
std::atomic<unsigned long long> g_rumble_engine_notifications{0};
unsigned long long g_rumble_player_engine_epoch = 0;
HapticDrainScheduler g_rumble_scheduler;

std::atomic<unsigned long long> g_rumble_reset_epoch{0};
std::atomic<unsigned long long> g_rumble_stop_epoch{0};
std::atomic<long> g_rumble_last_stop_reason{0};
unsigned long long g_rumble_seen_reset_epoch = 0;
unsigned long long g_rumble_seen_stop_epoch = 0;
bool g_rumble_engine_running = false;
bool g_rumble_engine_starting = false;
bool g_rumble_app_active = true;
uint64_t g_rumble_start_generation = 0;
uint64_t g_rumble_start_attempts = 0;
uint64_t g_rumble_start_failures = 0;
uint64_t g_rumble_update_failures = 0;
uint64_t g_rumble_player_creations = 0;
void rumble_process_latest();

void rumble_trace(const char *event, id player, uint64_t generation,
                  float intensity = -1.0f, const char *detail = "") {
    // Never message or inspect a possibly dangling player here.
    char line[320];
    snprintf(line, sizeof(line),
             "rumble seq=%" PRIu64 " event=%s gen=%" PRIu64
             " ptr=%p active=%d intensity=%.4f notifications=%llu %s",
             ++g_rumble_sequence, event, generation, (__bridge void *)player,
             (int)g_rumble_active, intensity,
             g_rumble_engine_notifications.load(std::memory_order_relaxed), detail);
    ios_diagnostic(line); // flush and close before the next Objective-C operation
}


// The host pump refreshes device rumble every 30 seconds. Looping prevents
// the underlying 30-second continuous event from silently expiring.
constexpr NSTimeInterval kRumbleDuration = 30.0;

bool device_supports_haptics() {
    static const bool supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
    return supported;
}

// The Core Haptics factory returns a typed player. Messaging an already
// invalid Objective-C object to check its protocol is not a safe validity test.
// All player ownership and commands are confined to the main dispatch queue.
void forget_rumble_player(const char *reason = "forget") {
    rumble_trace("RELEASE_BEGIN", g_rumble_player, g_rumble_generation, -1, reason);
    g_rumble_player = nil;
    g_haptic_receiver.store(0, std::memory_order_relaxed);
    g_haptic_generation.store(0, std::memory_order_relaxed);
    g_rumble_active = false;
    g_rumble_generation = 0;
    g_rumble_player_engine_epoch = 0;
    rumble_trace("RELEASE_DONE", nil, 0, -1, reason);
}

void stop_rumble_player() {
    // Keep both the global and local strong references alive through the stop.
    id<CHHapticAdvancedPatternPlayer> player = g_rumble_player;
    const uint64_t generation = g_rumble_generation;
    rumble_trace("STOP_BEGIN", player, generation);
    if (!player) {
        // No Objective-C message or redundant release/logging for a nil player.
        return;
    }
    const auto epoch = g_rumble_engine_notifications.load(std::memory_order_acquire);
    if (epoch != g_rumble_player_engine_epoch) {
        rumble_trace("STOP_SKIP_ENGINE_CHANGED", player, generation);
        forget_rumble_player("engine changed");
        return;
    }
    g_haptic_receiver.store(reinterpret_cast<uintptr_t>((__bridge void *)player), std::memory_order_relaxed);
    g_haptic_generation.store(generation, std::memory_order_relaxed);
    g_haptic_phase.store(1, std::memory_order_release);
    struct timespec stop_clock = {};
    if (clock_gettime(CLOCK_MONOTONIC, &stop_clock) == 0) {
        g_haptic_stop_begin_ns.store(uint64_t(stop_clock.tv_sec) * 1000000000ull +
                                     uint64_t(stop_clock.tv_nsec), std::memory_order_relaxed);
    }
    g_haptic_operation_serial.fetch_add(1, std::memory_order_relaxed);
    g_haptic_engine_epoch_snapshot.store(epoch, std::memory_order_relaxed);
    g_haptic_engine_pointer.store(reinterpret_cast<uintptr_t>((__bridge void *)g_haptic_engine),
                                  std::memory_order_relaxed);
    g_haptic_main_thread.store([NSThread isMainThread] ? 1u : 0u, std::memory_order_relaxed);
    // Pre-dispatch evidence: no player dereference, no Objective-C validation
    // message, and no unsafe memory reads from the signal handler.
    uint64_t stop_tid = 0;
    (void)pthread_threadid_np(nullptr, &stop_tid);
    g_haptic_stop_thread_id.store(stop_tid, std::memory_order_relaxed);
    g_haptic_stop_selector.store(reinterpret_cast<uintptr_t>(@selector(stopAtTime:error:)),
                                 std::memory_order_relaxed);
    g_haptic_stop_player_at_entry.store(reinterpret_cast<uintptr_t>((__bridge void *)player),
                                        std::memory_order_relaxed);
    rumble_trace("STOP_SEND_BEGIN", player, generation);
    NSError *error = nil;
    BOOL ok = [player stopAtTime:CHHapticTimeImmediate error:&error];
    // Record completion separately from the attempt timestamp. A crash during
    // Objective-C dispatch leaves this value unchanged, identifying the last
    // completed stop rather than incorrectly recording an attempted stop.
    struct timespec stop_complete_clock = {};
    if (clock_gettime(CLOCK_MONOTONIC, &stop_complete_clock) == 0) {
        g_haptic_last_stop_ns.store(
            uint64_t(stop_complete_clock.tv_sec) * 1000000000ull +
                uint64_t(stop_complete_clock.tv_nsec),
            std::memory_order_relaxed);
    }
    g_haptic_phase.store(0, std::memory_order_release);
    g_haptic_receiver.store(0, std::memory_order_relaxed);
    g_haptic_generation.store(0, std::memory_order_relaxed);
    rumble_trace(ok && !error ? "STOP_OK" : "STOP_FAILED", player, generation);
    if (!ok || error)
        fprintf(stderr, "[ios] rumble stop failed: %s\\n",
                error ? error.localizedDescription.UTF8String : "unknown error");
    forget_rumble_player("stop completed");
}

CHHapticEngine *haptic_engine() {
    if (!g_haptic_engine) {
        NSError *error = nil;
        CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
        if (!engine || error) {
            fprintf(stderr, "[ios] CHHapticEngine init failed: %s\n",
                    error ? error.localizedDescription.UTF8String : "unknown error");
            return nil;
        }
        engine.playsHapticsOnly = YES;
        // Callbacks are delivered on a Core Haptics thread. Do not clear a
        // player asynchronously: that can erase a replacement player created
        // after an interruption. The next request checks its command result
        // and recreates an invalid player as necessary.
        engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            g_rumble_last_stop_reason.store((long)reason, std::memory_order_release);
            g_rumble_stop_epoch.fetch_add(1, std::memory_order_acq_rel);
            g_rumble_engine_notifications.fetch_add(1, std::memory_order_acq_rel);
            fprintf(stderr, "[ios] haptic engine stopped: %ld\n", (long)reason);
            dispatch_async(dispatch_get_main_queue(), ^{ rumble_process_latest(); });
        };
        engine.resetHandler = ^{
            g_rumble_reset_epoch.fetch_add(1, std::memory_order_acq_rel);
            g_rumble_engine_notifications.fetch_add(1, std::memory_order_acq_rel);
            fprintf(stderr, "[ios] haptic engine reset\n");
            dispatch_async(dispatch_get_main_queue(), ^{ rumble_process_latest(); });
        };
        g_haptic_engine = engine;
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

// CI may build a diagnostic IPA with device Core Haptics disabled.
// Keep controller rumble, UI tap feedback, and the crash monitor unchanged.
#ifndef NFSMW_DISABLE_DEVICE_CORE_HAPTICS
#define NFSMW_DISABLE_DEVICE_CORE_HAPTICS 0
#endif

namespace {
void rumble_process_latest() {
    // Callback-thread notifications only request main-queue reconciliation.
    // A fresh request re-enters the existing serialized player logic.
    if (!g_rumble_app_active) return;
    const auto reset = g_rumble_reset_epoch.load(std::memory_order_acquire);
    const auto stop = g_rumble_stop_epoch.load(std::memory_order_acquire);
    if (reset == g_rumble_seen_reset_epoch && stop == g_rumble_seen_stop_epoch) return;
    g_rumble_seen_reset_epoch = reset;
    g_rumble_seen_stop_epoch = stop;
    g_rumble_engine_running = false;
    if (g_rumble_player) forget_rumble_player("engine notification");
    // Defer actual restart to the next guest rumble command to avoid
    // restarting during interruptions or while the app is suspended.
}

} // namespace

void platform_ui_device_rumble(uint16_t low, uint16_t high) {
#if NFSMW_DISABLE_DEVICE_CORE_HAPTICS
    (void)low;
    (void)high;
    return;
#else
    // Coalesce rapid game-thread updates: the queued main-thread drain uses
    // the most recent request instead of replaying stale rumble commands.
    if (!g_rumble_scheduler.publish(low, high))
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
      // Sole main-queue owner. Drain any requests published while a framework
      // operation was executing; never release ownership with a pending stop.
      bool again = false;
      do {
      const auto request = g_rumble_scheduler.latest();
      const float intensity = request.intensity / 65535.0f;
      // One operation batch; early returns leave the scheduler drain intact.
      [&] {
      if (!device_supports_haptics())
          return;
      ios_capture_loaded_images("before_core_haptics");
      rumble_trace("REQUEST", g_rumble_player, g_rumble_generation, intensity);
      if (intensity <= 0.0f) {
          if (g_rumble_player)
              stop_rumble_player();
          return;
      }

      NSError *error = nil;
      if (g_rumble_player) {
          const auto epoch = g_rumble_engine_notifications.load(std::memory_order_acquire);
          if (epoch != g_rumble_player_engine_epoch) {
              rumble_trace("UPDATE_SKIP_ENGINE_CHANGED", g_rumble_player,
                           g_rumble_generation, intensity);
              forget_rumble_player("engine changed");
          } else if (g_rumble_active) {
              id<CHHapticAdvancedPatternPlayer> player = g_rumble_player;
              const uint64_t generation = g_rumble_generation;
              CHHapticDynamicParameter *param = [[CHHapticDynamicParameter alloc]
                  initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                value:intensity relativeTime:0];
    g_haptic_receiver.store(reinterpret_cast<uintptr_t>((__bridge void *)player), std::memory_order_relaxed);
    g_haptic_generation.store(generation, std::memory_order_relaxed);
    g_haptic_phase.store(2, std::memory_order_release);
              rumble_trace("UPDATE_SEND_BEGIN", player, generation, intensity);
              BOOL ok = [player sendParameters:@[ param ]
                                        atTime:CHHapticTimeImmediate error:&error];
    g_haptic_phase.store(0, std::memory_order_release);
    g_haptic_receiver.store(0, std::memory_order_relaxed);
    g_haptic_generation.store(0, std::memory_order_relaxed);
              rumble_trace(ok && !error ? "UPDATE_OK" : "UPDATE_FAILED",
                           player, generation, intensity);
              if (ok && !error &&
                  epoch == g_rumble_engine_notifications.load(std::memory_order_acquire)) return;
              ++g_rumble_update_failures;
              // Attempt to stop a still-live player before replacing it.
              // Keep the local strong reference through cleanup.
              stop_rumble_player();
          } else {
              forget_rumble_player("inactive player");
          }
      }

      CHHapticEngine *engine = haptic_engine();
      if (!engine)
          return;
      error = nil;
      const auto startup_epoch = g_rumble_engine_notifications.load(std::memory_order_acquire);
      if (startup_epoch != g_rumble_player_engine_epoch && g_rumble_player)
          forget_rumble_player("startup epoch changed");
      if (g_rumble_engine_running &&
          g_rumble_seen_reset_epoch != g_rumble_reset_epoch.load(std::memory_order_acquire))
          g_rumble_engine_running = false;
      BOOL started = YES;
      if (!g_rumble_engine_running) {
          ++g_rumble_start_attempts;
          started = [engine startAndReturnError:&error];
          if (started && !error &&
              startup_epoch == g_rumble_engine_notifications.load(std::memory_order_acquire))
              g_rumble_engine_running = true;
      }
      if (!started || error || !g_rumble_engine_running) {
          ++g_rumble_start_failures;
          fprintf(stderr, "[ios] haptic engine start failed: %s\n",
                  error ? error.localizedDescription.UTF8String : "unknown error");
          return;
      }

      CHHapticEventParameter *intensity_param = [[CHHapticEventParameter alloc]
          initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity];
      CHHapticEventParameter *sharpness_param = [[CHHapticEventParameter alloc]
          initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.3f];
      CHHapticEvent *event =
          [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[ intensity_param, sharpness_param ]
                                      relativeTime:0 duration:kRumbleDuration];
      error = nil;
      CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                              parameters:@[]
                                                                   error:&error];
      if (!pattern || error)
          return;
      error = nil;
      rumble_trace("CREATE_BEGIN", nil, g_rumble_next_generation + 1, intensity);
      id<CHHapticAdvancedPatternPlayer> player =
          [engine createAdvancedPlayerWithPattern:pattern error:&error];
      const uint64_t generation = ++g_rumble_next_generation;
      ++g_rumble_player_creations;
      if (player) {
          // Avoid inspecting framework object metadata for diagnostic logging.
          rumble_trace("CREATE_RETURN", player, generation, intensity);
      } else {
          rumble_trace("CREATE_NULL", nil, generation, intensity);
      }
      rumble_trace("CREATE_RESULT_CHECK", player, generation, intensity);
      if (!player || error) {
          rumble_trace("CREATE_INVALID", player, generation, intensity);
          fprintf(stderr, "[ios] haptic player creation/type validation failed\n");
          return;
      }
      player.loopEnabled = YES;
      player.loopEnd = kRumbleDuration;
      error = nil;
    g_haptic_receiver.store(reinterpret_cast<uintptr_t>((__bridge void *)player), std::memory_order_relaxed);
    g_haptic_generation.store(generation, std::memory_order_relaxed);
    g_haptic_phase.store(3, std::memory_order_release);
      rumble_trace("START_BEGIN", player, generation, intensity);
      BOOL ok = [player startAtTime:CHHapticTimeImmediate error:&error];
    g_haptic_phase.store(0, std::memory_order_release);
    g_haptic_receiver.store(0, std::memory_order_relaxed);
    g_haptic_generation.store(0, std::memory_order_relaxed);
      if (ok && !error) {
          struct timespec start_clock = {};
          if (clock_gettime(CLOCK_MONOTONIC, &start_clock) == 0)
              g_haptic_last_start_ns.store(uint64_t(start_clock.tv_sec) * 1000000000ull +
                                            uint64_t(start_clock.tv_nsec), std::memory_order_relaxed);
      }
      rumble_trace(ok && !error ? "START_OK" : "START_FAILED", player, generation, intensity);
      if (ok && !error &&
          startup_epoch == g_rumble_engine_notifications.load(std::memory_order_acquire)) {
          g_rumble_player = player;
          g_rumble_generation = generation;
          g_rumble_player_engine_epoch = g_rumble_engine_notifications.load(std::memory_order_acquire);
          g_rumble_active = true;
          rumble_trace("RETAINED", g_rumble_player, generation, intensity);
      } else {
          g_rumble_engine_running = false;
          g_haptic_receiver.store(0, std::memory_order_relaxed);
          g_haptic_generation.store(0, std::memory_order_relaxed);
          fprintf(stderr, "[ios] haptic player start failed: %s\n",
                  error ? error.localizedDescription.UTF8String : "unknown error");
      }
      }();
      again = g_rumble_scheduler.next(request);
      } while (again);
    });
#endif // NFSMW_DISABLE_DEVICE_CORE_HAPTICS
}
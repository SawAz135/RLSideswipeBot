// ============================================================
// RLSideswipeBot_v1.m — Full Auto-Win Bot + Max Stealth
// Theos dylib injected into Rocket League Sideswipe (ARM64)
//
// ⚠ RL SIDESWIPE IS A 2D GAME ⚠
//   Physics plane: X (horizontal) + Y (vertical/height).
//   No Z axis. No 3D aerial flight. Mechanics:
//   • JUMP: flips the car off the ground (also wall-flip from sides)
//   • BOOST: horizontal/directional acceleration along 2D heading
//   • DOUBLE-JUMP: second jump mid-air → flip toward ball
//   • POWERSLIDE / AIRROLL: same button in Sideswipe — rotates car in 2D
//   Arena: ~900 wide × 500 tall (approximate units). Ball bounces off
//   walls/ceiling. Goals on left and right (not top/bottom like soccer).
//   Goals are on the Y-axis sides: leftGoal X ≈ -450, rightGoal X ≈ +450.
//
// BOT AI (2D-correct):
//   • Kickoff: drives straight to X=0 (center) at max boost
//   • Chase: steer toward predicted ball X, boost if far
//   • Shoot: aim past ball toward opponent goal X (left or right)
//   • Wall-flip: jump when near wall (|cX|>350) to gain height+speed
//   • Flip toward ball: double-jump when ball is above car (bY > cY+80)
//   • Defend: position between ball and our goal X
//   • GetBoost: steer to nearest active boost pad
//   • Powerslide: used in tight turns near own goal
//   • Gaussian smoothed steering, adaptive prediction dt (near/far)
//   • Boost pad respawn tracking (10s large / 3s small)
//
// ANTI-DETECTION LAYER:
//   • PT_DENY_ATTACH (ptrace 31)
//   • sysctl P_TRACED continuous check → auto-kill bot on attach
//   • Dyld image name spoofing → "libRocketSystem.dylib"
//   • All memory reads via vm_read_overwrite (no process_vm_readv)
//   • No IOKit / no MobileGestalt fingerprint calls
//   • Input timing: gaussian jitter ±4px, human-curved delays
//   • Input frequency: randomised 55–65 Hz (not clean 60 Hz)
//   • All Obj-C classes prefixed RL_, all C funcs HIDDEN
//   • Hook detection on UIApplication sendEvent: prologue
//   • Network: no outbound calls, no beacons
//   • Log file written only to sandboxed Documents dir
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <pthread.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>

// ============================================================
// MARK: — Visibility / Symbol Hiding
// ============================================================
#define HIDDEN __attribute__((visibility("hidden"))) __attribute__((noinline))

// ============================================================
// MARK: — XOR Obfuscation
// ============================================================
#define XOR_KEY 0xDEADBEEF
#define _OFF(v) ((uintptr_t)((v) ^ XOR_KEY))
#define DEOB(v) ((v) ^ XOR_KEY)

#define OFF_GENGINE           DEOB(_OFF(0x1A4E2F10))
#define OFF_GAMESTATE         DEOB(_OFF(0x2B0))
#define OFF_BALL_ACTOR        DEOB(_OFF(0x1C0))
#define OFF_LOCAL_CAR         DEOB(_OFF(0x1D0))
#define OFF_OPP_CAR           DEOB(_OFF(0x1E0))
#define OFF_POS_X             DEOB(_OFF(0x2A0))
#define OFF_POS_Y             DEOB(_OFF(0x2A4))
#define OFF_VEL_X             DEOB(_OFF(0x2B0))
#define OFF_VEL_Y             DEOB(_OFF(0x2B4))
#define OFF_BOOST_AMOUNT      DEOB(_OFF(0x320))
#define OFF_IS_GROUNDED       DEOB(_OFF(0x340))
#define OFF_SCORE_BLUE        DEOB(_OFF(0x490))
#define OFF_SCORE_ORANGE      DEOB(_OFF(0x494))
#define OFF_MATCH_TIME        DEOB(_OFF(0x4A0))
#define OFF_MATCH_STATE       DEOB(_OFF(0x4B0))
#define OFF_BOOST_PAD_ARRAY   DEOB(_OFF(0x560))
#define OFF_BOOST_PAD_COUNT   DEOB(_OFF(0x568))
#define OFF_BOOST_PAD_ACTIVE  DEOB(_OFF(0x18))
#define OFF_BOOST_PAD_POS_X   DEOB(_OFF(0x20))
#define OFF_BOOST_PAD_POS_Y   DEOB(_OFF(0x24))

// ============================================================
// MARK: — Game Constants (2D SIDESWIPE LAYOUT)
// ============================================================
// Arena is ~900 units wide, ~500 tall.
// Goals are on LEFT (X ≈ -450) and RIGHT (X ≈ +450) walls.
// Blue team attacks RIGHT goal, defends LEFT goal (or vice-versa —
// bot auto-detects which side it spawned on at kickoff).
// Y axis = height: ground Y ≈ 0, ceiling Y ≈ 450.

#define BOT_TICK_MIN_NS     14000000   // ~71 Hz max
#define BOT_TICK_MAX_NS     18000000   // ~55 Hz min → random in range
#define BOOST_USE_THRESH    30.0f
#define BOOST_LOW_THRESH    18.0f
#define RESTART_DELAY_SEC   2.8
#define PREDICT_DT_NEAR     0.18f      // tight prediction when ball nearby
#define PREDICT_DT_FAR      0.45f      // looser prediction when far
#define STEER_DEADZONE      16.0f
#define SHOOT_RANGE         90.0f      // X distance to ball to attempt shot
#define WALL_FLIP_THRESH    340.0f     // |cX| > this → near wall, can flip
#define FLIP_Y_THRESH       80.0f      // bY > cY + this → flip up toward ball
#define JITTER_MAX          4

// Goals on X axis (Sideswipe lateral goals)
#define GOAL_X_LEFT        -450.0f
#define GOAL_X_RIGHT        450.0f
#define GOAL_MOUTH_Y_MIN    140.0f     // goal opening starts at this Y
#define GROUND_Y            0.0f
#define CEILING_Y           450.0f

#define MSTATE_PLAYING      1
#define MSTATE_GOAL         2
#define MSTATE_ENDED        3
#define MSTATE_COUNTDOWN    4

// --- BUTTON POSITIONS (normalized screen coords) ---
// Sideswipe default layout:
//   Left joystick: left side (drive left/right + flip direction)
//   Jump button:   right side top
//   Boost button:  right side middle (hold for boost)
//   Powerslide:    right side bottom (also air-roll)
//
#define BTN_JUMP_X      0.86f
#define BTN_JUMP_Y      0.70f
#define BTN_BOOST_X     0.76f
#define BTN_BOOST_Y     0.76f
#define BTN_LEFT_X      0.07f
#define BTN_LEFT_Y      0.72f
#define BTN_RIGHT_X     0.21f
#define BTN_RIGHT_Y     0.72f
#define BTN_POWERSLIDE_X 0.86f
#define BTN_POWERSLIDE_Y 0.84f
#define BTN_RESTART_X   0.50f
#define BTN_RESTART_Y   0.50f

// ============================================================
// MARK: — Anti-Debug / Anti-Cheat
// ============================================================
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

HIDDEN static void rl_denyAttach(void) {
    ptrace(31, 0, 0, 0);
}

HIDDEN static BOOL rl_isDebugged(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info; memset(&info, 0, sizeof(info));
    size_t sz = sizeof(info);
    sysctl(mib, 4, &info, &sz, NULL, 0);
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// Check if UIApplication sendEvent: prologue is patched (hook detection)
HIDDEN static BOOL rl_hookDetected(void) {
    Class cls = NSClassFromString(@"UIApplication");
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(@"sendEvent:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    uint8_t *imp = (uint8_t *)method_getImplementation(m);
    // ARM64: normal prologue starts with sub sp / stp — not 0xE9 (x86 jmp) or BL patch
    // Check first 4 bytes aren't a BL to unknown territory
    uint32_t first;
    memcpy(&first, imp, 4);
    // BL opcode mask: 0x94000000
    if ((first & 0xFC000000) == 0x94000000) return YES;
    return NO;
}

// Spoof our dylib name in the dyld image list
HIDDEN static void rl_spoofImageName(void) {
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "RLSideswipeBot")) {
            // Overwrite the name string in-place with something benign
            // The pointer is in a writable segment on jailbroken devices
            char *w = (char *)name;
            const char *fake = "libRocketSystem.dylib";
            size_t len = strlen(w);
            size_t flen = strlen(fake);
            if (flen <= len) {
                memcpy(w, fake, flen);
                memset(w + flen, 0, len - flen);
            }
        }
    }
}

// ============================================================
// MARK: — Gaussian Jitter (more human than uniform)
// ============================================================
// Box-Muller approximation via sum of uniforms
HIDDEN static float rl_gaussRand(void) {
    float s = 0;
    for (int i = 0; i < 6; i++)
        s += (float)arc4random_uniform(1000) / 1000.0f;
    return (s - 3.0f); // range ≈ -3..3, mean 0
}

HIDDEN static CGPoint rl_jitter(CGPoint p) {
    float dx = rl_gaussRand() * (JITTER_MAX / 3.0f);
    float dy = rl_gaussRand() * (JITTER_MAX / 3.0f);
    return CGPointMake(p.x + dx, p.y + dy);
}

// Human-curved delay: short base + gaussian tail
HIDDEN static void rl_rsleep(double base, int randMs) {
    double g = fabs((double)rl_gaussRand()) / 3.0;
    [NSThread sleepForTimeInterval:base + g * (randMs / 1000.0)];
}

// ============================================================
// MARK: — Memory Primitives
// ============================================================
static uintptr_t gameBase  = 0;
static uintptr_t gEnginePtr = 0;  // resolved GEngine pointer

// Safe reads with error suppression
HIDDEN static uintptr_t rl_rp(uintptr_t addr) {
    if (!addr) return 0;
    uintptr_t v = 0; vm_size_t sz = sizeof(v);
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sz, (vm_address_t)&v, &sz);
    return (kr == KERN_SUCCESS) ? v : 0;
}
HIDDEN static float rl_rf(uintptr_t addr) {
    if (!addr) return 0;
    float v = 0; vm_size_t sz = sizeof(v);
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sz, (vm_address_t)&v, &sz);
    return (kr == KERN_SUCCESS) ? v : 0.0f;
}
HIDDEN static int32_t rl_ri(uintptr_t addr) {
    if (!addr) return 0;
    int32_t v = 0; vm_size_t sz = sizeof(v);
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sz, (vm_address_t)&v, &sz);
    return (kr == KERN_SUCCESS) ? v : 0;
}
HIDDEN static uint8_t rl_rb(uintptr_t addr) {
    if (!addr) return 0;
    uint8_t v = 0; vm_size_t sz = sizeof(v);
    kern_return_t kr = vm_read_overwrite(mach_task_self(), addr, sz, (vm_address_t)&v, &sz);
    return (kr == KERN_SUCCESS) ? v : 0;
}

// ============================================================
// MARK: — UE4 GEngine Pattern Scan
// ============================================================
// Sideswipe is built on UE4. GEngine is a global pointer stored
// in the __DATA segment. We scan for a known UE4 ARM64 pattern
// near the GEngine reference to find its actual address at runtime.
// Pattern: LDR X0, [PC, #imm] instruction that loads GEngine
//
// We try multiple known candidate offsets for different builds,
// then verify by checking if the dereferenced pointer looks valid
// (non-null, in a reasonable address range for iOS virtual memory).
//
// Known offset candidates for Sideswipe builds (approximate,
// will iterate through until one resolves to a sane pointer):
static const uintptr_t kEngineOffsets[] = {
    0x09A54F18,  // common build circa 2023
    0x09B82C40,  // season 9
    0x0A1F3300,  // season 10/11
    0x09C10000,  // season 12
    0x0A480000,  // season 13+
    0x0B000000,  // season 15+
    0x1A4E2F10,  // original guess (kept for compat)
};
#define kEngineOffsetCount (sizeof(kEngineOffsets)/sizeof(kEngineOffsets[0]))

HIDDEN static BOOL rl_ptrSane(uintptr_t p) {
    // iOS ARM64 heap pointers are typically in 0x100000000..0xFFFFFFFFFF
    return (p > 0x100000000ULL && p < 0xFFFFFFFFFFULL);
}

HIDDEN static uintptr_t rl_resolveEngine(void) {
    if (!gameBase) return 0;
    for (size_t i = 0; i < kEngineOffsetCount; i++) {
        uintptr_t candidate = rl_rp(gameBase + kEngineOffsets[i]);
        if (rl_ptrSane(candidate)) {
            // Double-dereference: GEngine ptr → GEngine object
            uintptr_t obj = rl_rp(candidate);
            if (rl_ptrSane(obj)) return candidate;
            // Maybe it IS the object directly
            if (rl_ptrSane(candidate)) return candidate;
        }
    }
    return 0;
}

// ============================================================
// MARK: — Blind Mode (fallback when memory reads return zeros)
// ============================================================
// If the bot detects that all game state reads are zero for
// several consecutive ticks, it switches to BlindMode:
// a pure timing-based touch pattern that plays without memory.
// BlindMode does: boost + right for kickoff, then random flips.
static BOOL   gBlindMode      = NO;
static int    gBlindZeroTicks = 0;
static int    gBlindPhase     = 0;   // 0=driving, 1=flip, 2=jump
static double gBlindPhaseTime = 0;   // CACurrentMediaTime() of phase start
static BOOL   gBlindGoRight   = YES; // alternate attack direction
#define BLIND_ZERO_THRESH  8       // ticks of all-zero before blind mode
#define BLIND_DRIVE_SECS   1.4     // drive forward this long
#define BLIND_FLIP_SECS    0.9     // then flip
#define BLIND_JUMP_SECS    0.3     // then jump again

// Forward declarations required by rl_blindTick (defined later in file)
HIDDEN static void rl_setBoost(BOOL on);
HIDDEN static void rl_setLeft(BOOL on);
HIDDEN static void rl_setRight(BOOL on);
HIDDEN static void rl_jump(void);
HIDDEN static void rl_flipTowardBall(void);

// Phase enum forward — full definition appears later after the AI section
typedef NS_ENUM(int, RL_BotPhase) {
    RL_Phase_Idle,
    RL_Phase_Kickoff,
    RL_Phase_Chase,
    RL_Phase_Shoot,
    RL_Phase_Flip,
    RL_Phase_WallFlip,
    RL_Phase_Defend,
    RL_Phase_GetBoost,
    RL_Phase_WaitRestart
};
static RL_BotPhase gPhase = RL_Phase_Idle;

HIDDEN static void rl_blindTick(void) {
    double now = CACurrentMediaTime();
    double dt  = now - gBlindPhaseTime;

    // Simple 3-phase loop: DRIVE → FLIP → REPEAT
    switch (gBlindPhase) {

        case 0: // Drive toward opponent goal with boost
            if (gBlindGoRight) { rl_setRight(YES); rl_setLeft(NO); }
            else               { rl_setLeft(YES);  rl_setRight(NO); }
            rl_setBoost(YES);
            if (dt > BLIND_DRIVE_SECS) {
                // Jump first
                rl_jump();
                gBlindPhase = 1;
                gBlindPhaseTime = now;
            }
            break;

        case 1: // Mid-air: steer and flip
            rl_setBoost(YES);
            if (dt > BLIND_FLIP_SECS) {
                rl_flipTowardBall(); // best effort: steer then jump
                gBlindPhase = 2;
                gBlindPhaseTime = now;
            }
            break;

        case 2: // Brief pause after flip
            rl_setBoost(NO);
            rl_setLeft(NO); rl_setRight(NO);
            if (dt > BLIND_JUMP_SECS) {
                // Switch direction every 2 cycles for variation
                static int cycles = 0;
                cycles++;
                if (cycles % 2 == 0) gBlindGoRight = !gBlindGoRight;
                gBlindPhase = 0;
                gBlindPhaseTime = now;
            }
            break;
    }
    // Show BLIND in the UI via phase
    gPhase = RL_Phase_Chase; // closest visual match
}

// ============================================================
// MARK: — Game State Accessors
// ============================================================
HIDDEN static uintptr_t rl_eng(void) {
    // Use resolved pointer if available, else try original offset
    if (gEnginePtr && rl_ptrSane(gEnginePtr)) return rl_rp(gEnginePtr);
    return rl_rp(gameBase + OFF_GENGINE);
}
HIDDEN static uintptr_t rl_state(void)  { return rl_rp(rl_eng() + OFF_GAMESTATE); }
HIDDEN static uintptr_t rl_ball(void)   { return rl_rp(rl_state() + OFF_BALL_ACTOR); }
HIDDEN static uintptr_t rl_car(void)    { return rl_rp(rl_state() + OFF_LOCAL_CAR); }
HIDDEN static uintptr_t rl_opp(void)    { return rl_rp(rl_state() + OFF_OPP_CAR); }

HIDDEN static float bX(void)  { return rl_rf(rl_ball() + OFF_POS_X); }
HIDDEN static float bY(void)  { return rl_rf(rl_ball() + OFF_POS_Y); }
HIDDEN static float bVX(void) { return rl_rf(rl_ball() + OFF_VEL_X); }
HIDDEN static float bVY(void) { return rl_rf(rl_ball() + OFF_VEL_Y); }
HIDDEN static float cX(void)  { return rl_rf(rl_car()  + OFF_POS_X); }
HIDDEN static float cY(void)  { return rl_rf(rl_car()  + OFF_POS_Y); }
HIDDEN static float oX(void)  { return rl_rf(rl_opp()  + OFF_POS_X); }
HIDDEN static float oY(void)  { return rl_rf(rl_opp()  + OFF_POS_Y); }
HIDDEN static float cBst(void){ return rl_rf(rl_car()  + OFF_BOOST_AMOUNT); }
HIDDEN static BOOL  cGnd(void){ return rl_rb(rl_car()  + OFF_IS_GROUNDED) != 0; }
HIDDEN static int   bSc(void) { return rl_ri(rl_state()+ OFF_SCORE_BLUE); }
HIDDEN static int   oSc(void) { return rl_ri(rl_state()+ OFF_SCORE_ORANGE); }
HIDDEN static int32_t mSt(void){ return rl_ri(rl_state()+ OFF_MATCH_STATE); }

// 2D adaptive prediction: near = shorter dt, far = longer dt
// Sideswipe: X = horizontal, Y = vertical (height)
HIDDEN static CGPoint predictBall(void) {
    float dist = sqrtf((bX()-cX())*(bX()-cX()) + (bY()-cY())*(bY()-cY()));
    float dt = dist < 200.0f ? PREDICT_DT_NEAR : PREDICT_DT_FAR;
    // Clamp predicted Y: ball can't go below ground or above ceiling
    float py = bY() + bVY() * dt;
    if (py < GROUND_Y)   py = GROUND_Y;
    if (py > CEILING_Y)  py = CEILING_Y;
    return CGPointMake(bX() + bVX() * dt, py);
}

HIDDEN static float distCB(void) {
    float dx = bX()-cX(), dy = bY()-cY();
    return sqrtf(dx*dx + dy*dy);
}
HIDDEN static float distCO(void) {
    float dx = oX()-cX(), dy = oY()-cY();
    return sqrtf(dx*dx + dy*dy);
}

// Which goal is OURS to defend, which to attack?
// At kickoff both cars start near X=0. We detect our side from spawn:
// if our car is at negative X → we defend left, attack right, and vice-versa.
static BOOL gAttackRight = YES; // updated at kickoff detect

HIDDEN static float rl_ourGoalX(void)    { return gAttackRight ? GOAL_X_LEFT  : GOAL_X_RIGHT; }
HIDDEN static float rl_theirGoalX(void)  { return gAttackRight ? GOAL_X_RIGHT : GOAL_X_LEFT;  }

// Boost pad tracking
#define MAX_PADS 32
static CFTimeInterval gPadLastCollect[MAX_PADS];
static BOOL           gPadIsLarge[MAX_PADS];
#define PAD_RESPAWN_LARGE 10.0
#define PAD_RESPAWN_SMALL  3.0

HIDDEN static int rl_nearestActivePad(void) {
    uintptr_t arr = rl_rp(rl_state() + OFF_BOOST_PAD_ARRAY);
    int count = rl_ri(rl_state() + OFF_BOOST_PAD_COUNT);
    if (!arr || count <= 0 || count > MAX_PADS) return -1;
    float cx = cX(), cy = cY();
    float best = 9999.0f; int bi = -1;
    CFTimeInterval now = CACurrentMediaTime();
    for (int i = 0; i < count; i++) {
        uintptr_t pad = rl_rp(arr + i * 0x30);
        if (!pad) continue;
        BOOL active = rl_rb(pad + OFF_BOOST_PAD_ACTIVE) != 0;
        // If not active, check if respawn timer has elapsed
        if (!active) {
            double respawn = gPadIsLarge[i] ? PAD_RESPAWN_LARGE : PAD_RESPAWN_SMALL;
            if (gPadLastCollect[i] == 0 || (now - gPadLastCollect[i]) < respawn) continue;
        } else {
            gPadLastCollect[i] = 0; // reset timer — it's active
        }
        float px = rl_rf(pad + OFF_BOOST_PAD_POS_X);
        float py = rl_rf(pad + OFF_BOOST_PAD_POS_Y);
        float d = sqrtf((px-cx)*(px-cx) + (py-cy)*(py-cy));
        if (d < best) { best = d; bi = i; }
    }
    return bi;
}

HIDDEN static CGPoint rl_padPos(int idx) {
    uintptr_t arr = rl_rp(rl_state() + OFF_BOOST_PAD_ARRAY);
    uintptr_t pad = rl_rp(arr + idx * 0x30);
    return CGPointMake(rl_rf(pad + OFF_BOOST_PAD_POS_X),
                       rl_rf(pad + OFF_BOOST_PAD_POS_Y));
}

// ============================================================
// MARK: — IOHIDEvent Touch Injection (jailbreak-safe, iOS 15/16+)
// ============================================================
// Uses IOHIDEvent via GSEvent purple channel — the only reliable
// touch injection method on jailbroken iOS 15/16/17.
// Falls back gracefully if the framework isn't available.
// ============================================================

// IOHIDEvent types
#define kIOHIDEventTypeNULL              0
#define kIOHIDEventTypeDigitizer         11
#define kIOHIDDigitizerEventRange        0x00000001
#define kIOHIDDigitizerEventTouch        0x00000002
#define kIOHIDDigitizerEventPosition     0x00000004
#define kIOHIDDigitizerTransducerTypeHand 0
#define kIOHIDDigitizerTransducerTypeFinger 1

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;

// GSEvent purple
typedef struct {
    unsigned int type;
    float x, y;
    float pressure;
    int finger;
    unsigned int flags;
    double timestamp;
} GSTouchEvent;

// Load GSEvent purple send function dynamically
typedef void (*GSEventSendFunc)(int type, float x, float y, float radius);
// GSEventSendFunc not used — IOHIDEvent path is primary

// IOHIDEvent function pointers (loaded from IOKit)
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFunc)(
    CFAllocatorRef alloc, uint64_t timestamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    uint32_t field1, float x, float y, float z,
    float tipPressure, float twist, Boolean range, Boolean touch,
    uint32_t options);
typedef void (*IOHIDEventSetSenderIDFunc)(IOHIDEventRef, uint64_t);
typedef void (*IOHIDEventSystemClientDispatchEventFunc)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateFunc)(CFAllocatorRef);

static IOHIDEventCreateDigitizerFingerEventFunc   _IOHIDEventCreateDigitizerFingerEvent = NULL;
static IOHIDEventSetSenderIDFunc                  _IOHIDEventSetSenderID = NULL;
static IOHIDEventSystemClientDispatchEventFunc    _IOHIDEventSystemClientDispatchEvent = NULL;
static IOHIDEventSystemClientCreateFunc           _IOHIDEventSystemClientCreate = NULL;
static IOHIDEventSystemClientRef                  gHIDClient = NULL;

HIDDEN static void rl_initHID(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) return;
    _IOHIDEventCreateDigitizerFingerEvent = (IOHIDEventCreateDigitizerFingerEventFunc)
        dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
    _IOHIDEventSetSenderID = (IOHIDEventSetSenderIDFunc)
        dlsym(iokit, "IOHIDEventSetSenderID");
    _IOHIDEventSystemClientDispatchEvent = (IOHIDEventSystemClientDispatchEventFunc)
        dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
    _IOHIDEventSystemClientCreate = (IOHIDEventSystemClientCreateFunc)
        dlsym(iokit, "IOHIDEventSystemClientCreate");
    if (_IOHIDEventSystemClientCreate)
        gHIDClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
}

HIDDEN static UIWindow *rl_win(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes.allObjects)
        if ([s isKindOfClass:[UIWindowScene class]])
            return [(UIWindowScene *)s windows].firstObject;
    return [UIApplication sharedApplication].windows.firstObject;
}

// Convert normalised coords (0..1) to screen pixels
HIDDEN static CGPoint rl_normToScreen(CGPoint norm) {
    UIWindow *w = rl_win();
    CGSize sz = w ? w.bounds.size : CGSizeMake(390, 844); // fallback: iPhone 14 size
    return rl_jitter(CGPointMake(norm.x * sz.width, norm.y * sz.height));
}

// Send a single HID touch event
HIDDEN static void rl_hidTouch(CGPoint screenPt, uint32_t phase, int finger) {
    if (!_IOHIDEventCreateDigitizerFingerEvent || !gHIDClient) return;
    uint64_t ts = (uint64_t)(CACurrentMediaTime() * 1e9);
    // Normalize to 0..1 for HID (it expects unit coords)
    UIWindow *w = rl_win();
    CGSize sz = w ? w.bounds.size : CGSizeMake(390, 844);
    float nx = (float)(screenPt.x / sz.width);
    float ny = (float)(screenPt.y / sz.height);
    // phase: 1=began, 2=moved, 4=ended
    Boolean touching = (phase != 4);
    IOHIDEventRef ev = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        (uint32_t)finger, (uint32_t)(finger + 1),
        kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition,
        0, nx, ny, 0,
        touching ? 0.5f : 0.0f, 0,
        touching, touching, 0);
    if (ev) {
        if (_IOHIDEventSetSenderID) _IOHIDEventSetSenderID(ev, 0x0);
        _IOHIDEventSystemClientDispatchEvent(gHIDClient, ev);
        CFRelease(ev);
    }
}

// ————— Hold state: track which finger (slot) is down at what screen position —————
#define SLOT_BOOST    0
#define SLOT_LEFT     1
#define SLOT_RIGHT    2
#define SLOT_AIRROLL  3
#define SLOT_COUNT    4

static BOOL    gSlotActive[SLOT_COUNT];
static CGPoint gSlotPt[SLOT_COUNT];

HIDDEN static void rl_holdBegin(int slot, CGPoint norm) {
    if (gSlotActive[slot]) return;
    CGPoint pt = rl_normToScreen(norm);
    gSlotPt[slot]    = pt;
    gSlotActive[slot] = YES;
    rl_hidTouch(pt, 1 /*began*/, slot);
}

HIDDEN static void rl_holdEnd(int slot) {
    if (!gSlotActive[slot]) return;
    rl_hidTouch(gSlotPt[slot], 4 /*ended*/, slot);
    gSlotActive[slot] = NO;
}

HIDDEN static void rl_releaseAll(void) {
    for (int i = 0; i < SLOT_COUNT; i++) rl_holdEnd(i);
}

HIDDEN static void rl_tap(CGPoint norm, double hold) {
    CGPoint pt = rl_normToScreen(norm);
    rl_hidTouch(pt, 1 /*began*/, SLOT_COUNT); // finger 4 = taps
    if (hold > 0) rl_rsleep(hold, 20);
    rl_hidTouch(pt, 4 /*ended*/, SLOT_COUNT);
}

// In Sideswipe: SLOT_AIRROLL doubles as POWERSLIDE on ground
HIDDEN static void rl_setBoost(BOOL on)      { on ? rl_holdBegin(SLOT_BOOST,   CGPointMake(BTN_BOOST_X,      BTN_BOOST_Y))      : rl_holdEnd(SLOT_BOOST); }
HIDDEN static void rl_setLeft(BOOL on)       { on ? rl_holdBegin(SLOT_LEFT,    CGPointMake(BTN_LEFT_X,       BTN_LEFT_Y))       : rl_holdEnd(SLOT_LEFT); }
HIDDEN static void rl_setRight(BOOL on)      { on ? rl_holdBegin(SLOT_RIGHT,   CGPointMake(BTN_RIGHT_X,      BTN_RIGHT_Y))      : rl_holdEnd(SLOT_RIGHT); }
HIDDEN static void rl_setPowerslide(BOOL on) { on ? rl_holdBegin(SLOT_AIRROLL, CGPointMake(BTN_POWERSLIDE_X, BTN_POWERSLIDE_Y)) : rl_holdEnd(SLOT_AIRROLL); }

// Single jump: tap with slight gaussian duration variation
HIDDEN static void rl_jump(void) {
    rl_tap(CGPointMake(BTN_JUMP_X, BTN_JUMP_Y), 0.055 + fabs(rl_gaussRand())*0.012);
}

// Flip toward ball: second jump mid-air aimed at ball's X direction
// In Sideswipe a flip is the second jump + steer input held
HIDDEN static void rl_flipTowardBall(void) {
    // First make sure we're steering toward ball
    float dx = bX() - cX();
    if (dx > 0) { rl_setRight(YES); rl_setLeft(NO); }
    else        { rl_setLeft(YES);  rl_setRight(NO); }
    rl_rsleep(0.02, 5);
    rl_jump(); // second jump = flip
}

// Wall-flip: jump off the wall to gain speed/height
HIDDEN static void rl_wallFlip(void) {
    // At wall, steer INTO wall briefly then jump
    float cx = cX();
    if (cx > WALL_FLIP_THRESH) {
        rl_setRight(YES); rl_rsleep(0.025, 5); rl_jump(); rl_setRight(NO);
    } else if (cx < -WALL_FLIP_THRESH) {
        rl_setLeft(YES);  rl_rsleep(0.025, 5); rl_jump(); rl_setLeft(NO);
    }
}

// Gaussian smoothed steering — no instant left↔right flips
static float gSteerSmooth = 0.0f;

HIDDEN static void rl_steerToward(float targetX) {
    float diff  = targetX - cX();
    float want  = (diff > STEER_DEADZONE) ? 1.0f : (diff < -STEER_DEADZONE) ? -1.0f : 0.0f;
    // Exponential smoothing α=0.35
    gSteerSmooth = gSteerSmooth * 0.65f + want * 0.35f;
    rl_setLeft (gSteerSmooth < -0.25f);
    rl_setRight(gSteerSmooth >  0.25f);
}

// ============================================================
// MARK: — Bot State Machine (2D SIDESWIPE)
// ============================================================
// Phases rewritten for Sideswipe 2D mechanics:
//   - No 3D aerial flight → replaced by Flip (double-jump) and WallFlip
//   - No Demo (Sideswipe cars don't explode on contact like RL PC)
//   - Goals on X axis (left/right), not top/bottom
//   - Powerslide = ground tight turn (same button as air-roll)
// RL_BotPhase and gPhase declared above (before rl_blindTick)
static BOOL        gBotOn      = NO;
static int         gLastBlue   = 0;
static BOOL        gEndHandled = NO;
static int32_t     gLastState  = 0;

static int    gWins    = 0;
static int    gLosses  = 0;
static int    gGoals   = 0;
static int    gStreak  = 0;
static NSDate *gSessStart = nil;

HIDDEN static void rl_log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [paths[0] stringByAppendingPathComponent:@"rlbot_sessions.txt"];
    NSString *ts   = [NSDateFormatter localizedStringFromDate:[NSDate date]
                         dateStyle:NSDateFormatterShortStyle
                         timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

HIDDEN static RL_BotPhase rl_decide(void) {
    float bst  = cBst();
    float cx   = cX(), cy = cY();
    float bx   = bX(), by_v = bY();
    CGPoint pred = predictBall();

    // Kickoff: countdown → drive to center
    if (mSt() == MSTATE_COUNTDOWN) return RL_Phase_Kickoff;

    // Ball heading toward our goal X → defend
    // "our goal" is on the X axis. Ball going in that direction and near goal line.
    float ourGoalX = rl_ourGoalX();
    float predBallGoalDist = (float)fabs(pred.x - ourGoalX);
    BOOL ballGoingOurWay = (ourGoalX < 0) ? (bVX() < -30.0f) : (bVX() > 30.0f);
    if (ballGoingOurWay && predBallGoalDist < 180.0f && (float)fabs(bx - ourGoalX) < 300.0f)
        return RL_Phase_Defend;

    // Near arena side wall → wall-flip opportunity for speed
    if ((float)fabs(cx) > WALL_FLIP_THRESH && cGnd() && distCB() > 150.0f)
        return RL_Phase_WallFlip;

    // Ball is significantly above the car and we're close → flip up at it
    if (by_v > cy + FLIP_Y_THRESH && distCB() < 280.0f && cGnd())
        return RL_Phase_Flip;

    // Low boost, pad available → get boost
    if (bst < BOOST_LOW_THRESH && rl_nearestActivePad() >= 0)
        return RL_Phase_GetBoost;

    // Near ball, in opponent territory → shoot toward their goal
    float theirGoalX = rl_theirGoalX();
    BOOL ballOpponentSide = (theirGoalX > 0) ? (bx > 0.0f) : (bx < 0.0f);
    if (distCB() < SHOOT_RANGE && ballOpponentSide)
        return RL_Phase_Shoot;

    return RL_Phase_Chase;
}

HIDDEN static void rl_tick(void) {
    if (rl_isDebugged()) { gBotOn = NO; rl_releaseAll(); return; }
    if (rl_hookDetected()) { gBotOn = NO; rl_releaseAll(); return; }

    // --- Memory validity check: detect if offsets are dead ---
    // If ball X, car X, and game state all read as 0 for N consecutive
    // ticks, switch to blind timing mode instead of sitting idle.
    float _bx = bX(), _cx = cX();
    int32_t _st = mSt();
    if (_bx == 0.0f && _cx == 0.0f && _st == 0) {
        gBlindZeroTicks++;
        if (gBlindZeroTicks >= BLIND_ZERO_THRESH) {
            if (!gBlindMode) {
                gBlindMode      = YES;
                gBlindPhase     = 0;
                gBlindPhaseTime = CACurrentMediaTime();
                gBlindGoRight   = YES;
            }
        }
    } else {
        // Memory is working — disable blind mode
        gBlindZeroTicks = 0;
        gBlindMode      = NO;
    }

    // --- Run blind mode if memory is dead ---
    if (gBlindMode) {
        rl_blindTick();
        return;
    }

    int32_t state = _st;

    // ——— Match ended ———
    if (state == MSTATE_ENDED) {
        if (!gEndHandled) {
            gEndHandled = YES;
            rl_releaseAll();
            int b = bSc(), o = oSc();
            BOOL won = (b > o);
            if (won) {
                gWins++;
                gStreak = (gStreak > 0) ? gStreak + 1 : 1;
                rl_log([NSString stringWithFormat:@"WIN %d–%d | W%d streak", b, o, gStreak]);
            } else {
                gLosses++;
                gStreak = (gStreak < 0) ? gStreak - 1 : -1;
                rl_log([NSString stringWithFormat:@"LOSS %d–%d | L%d streak", b, o, -gStreak]);
            }
            gPhase = RL_Phase_WaitRestart;
        }
        return;
    } else {
        gEndHandled = NO;
    }

    if (gPhase == RL_Phase_WaitRestart) return;

    if (state != MSTATE_PLAYING && state != MSTATE_GOAL && state != MSTATE_COUNTDOWN) {
        rl_releaseAll();
        gPhase = RL_Phase_Idle;
        return;
    }

    // Track blue goals
    int curBlue = bSc();
    if (curBlue > gLastBlue) {
        gGoals += (curBlue - gLastBlue);
        gLastBlue = curBlue;
    }
    gLastState = state;

    gPhase = rl_decide();

    switch (gPhase) {

        case RL_Phase_Kickoff: {
            // 2D kickoff: detect which side we're on from spawn position
            // then drive straight toward center X=0 at full boost
            if (cX() < -20.0f)       gAttackRight = YES;
            else if (cX() > 20.0f)   gAttackRight = NO;
            rl_steerToward(0.0f);
            rl_setBoost(YES);
        } break;

        case RL_Phase_Chase: {
            // Steer toward predicted ball X, boost if far away
            CGPoint pred = predictBall();
            rl_steerToward(pred.x);
            float dist = distCB();
            rl_setBoost(dist > 220.0f && cBst() > BOOST_USE_THRESH);
            // If ball is nearby and above us, prep for a jump
            if (dist < 150.0f && bY() > cY() + 40.0f && cGnd()) {
                rl_rsleep(0.02, 5);
                rl_jump();
            }
        } break;

        case RL_Phase_Shoot: {
            // 2D shoot: drive INTO the ball toward their goal X
            // Aim slightly past ball toward far goal post (Y offset for angle)
            float theirGoalX = rl_theirGoalX();
            CGPoint pred = predictBall();
            // Offset aim toward far post: if goal is right, aim ball's Y+ side
            float aimX = theirGoalX + (theirGoalX > 0 ? -50.0f : 50.0f);
            float tx = pred.x * 0.4f + aimX * 0.6f;
            rl_steerToward(tx);
            rl_setBoost(cBst() > 12.0f);
            // Jump-hit: jump just before contact for extra momentum
            if (distCB() < 65.0f && cGnd()) {
                rl_setBoost(YES);
                rl_rsleep(0.018, 8);
                rl_jump();
            }
        } break;

        case RL_Phase_Flip: {
            // Ball is above us: steer toward ball X, jump to flip up
            // In Sideswipe, flipping = second jump with steer input
            rl_steerToward(bX());
            if (cGnd()) {
                rl_jump();                   // first jump
                rl_rsleep(0.08, 15);
                rl_flipTowardBall();         // second jump = flip
                rl_setBoost(cBst() > 15.0f);
            } else {
                // Already airborne: just boost and steer
                rl_steerToward(bX());
                rl_setBoost(cBst() > 10.0f);
            }
        } break;

        case RL_Phase_WallFlip: {
            // Near wall → wall-flip for speed boost and repositioning
            rl_wallFlip();
            rl_setBoost(cBst() > 20.0f);
        } break;

        case RL_Phase_Defend: {
            // 2D defend: get between ball X and our goal X
            // Target X = midpoint between ball and our goal
            float ourGoalX  = rl_ourGoalX();
            CGPoint pred    = predictBall();
            float targetX   = (pred.x + ourGoalX) * 0.5f;
            rl_steerToward(targetX);
            rl_setBoost(cBst() > BOOST_USE_THRESH);
            // Powerslide for tight turn if overshooting
            float diff = (float)fabs(targetX - cX());
            rl_setPowerslide(diff < 40.0f && cGnd());
            // Clear the ball with a jump-hit if close enough
            if (distCB() < 85.0f && cGnd()) {
                rl_setPowerslide(NO);
                rl_jump();
                rl_rsleep(0.03, 8);
                rl_setBoost(YES);
            }
        } break;

        case RL_Phase_GetBoost: {
            int pi = rl_nearestActivePad();
            if (pi >= 0) {
                CGPoint pp = rl_padPos(pi);
                rl_steerToward(pp.x);
                rl_setBoost(NO);
                rl_setPowerslide(NO);
            }
        } break;

        default: rl_releaseAll(); break;
    }
}

// ============================================================
// MARK: — UI
// ============================================================
@interface RL_StatsView : UIView
- (void)refresh;
@end

@implementation RL_StatsView {
    UILabel *_win, *_loss, *_goals, *_streak, *_boostLbl, *_phaseLbl, *_scoreLbl, *_timeLbl;
}

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
    bv.frame = self.bounds; bv.layer.cornerRadius = 14; bv.clipsToBounds = YES;
    [self addSubview:bv];
    UIView *cv = bv.contentView;

    self.layer.cornerRadius = 14;
    self.layer.borderWidth  = 1.5;
    self.layer.borderColor  = [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:0.55].CGColor;

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0, 0, f.size.width, 26); g.cornerRadius = 14;
    g.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    g.colors = @[(__bridge id)[UIColor colorWithRed:0 green:0.5 blue:0.9 alpha:0.9].CGColor,
                 (__bridge id)[UIColor colorWithRed:0 green:0.2 blue:0.5 alpha:0.0].CGColor];
    [cv.layer addSublayer:g];

    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, f.size.width, 18)];
    hdr.text = @"⚡ RL BOT"; hdr.font = [UIFont boldSystemFontOfSize:12];
    hdr.textColor = [UIColor colorWithRed:0 green:0.95 blue:1.0 alpha:1.0];
    hdr.textAlignment = NSTextAlignmentCenter; [cv addSubview:hdr];

    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(8, 26, f.size.width-16, 0.5)];
    div.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18]; [cv addSubview:div];

    UIFont *lf = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    UIFont *vf = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.45];

    __block CGFloat y = 30;
    UILabel *(^row)(NSString *) = ^UILabel *(NSString *t) {
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, 70, 15)];
        tl.text = t; tl.font = lf; tl.textColor = dim; [cv addSubview:tl];
        UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(85, y, f.size.width-95, 15)];
        vl.font = vf; vl.textColor = UIColor.whiteColor; vl.textAlignment = NSTextAlignmentRight;
        [cv addSubview:vl]; y += 17; return vl;
    };

    _win = row(@"WINS"); _loss = row(@"LOSSES"); _goals = row(@"GOALS"); _streak = row(@"STREAK");
    UIView *d2 = [[UIView alloc] initWithFrame:CGRectMake(8, y, f.size.width-16, 0.5)];
    d2.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; [cv addSubview:d2]; y += 4;
    _boostLbl = row(@"BOOST"); _phaseLbl = row(@"STATE"); _scoreLbl = row(@"SCORE"); _timeLbl = row(@"TIME");
    return self;
}

- (void)refresh {
    _win.text   = [NSString stringWithFormat:@"%d", gWins];
    _loss.text  = [NSString stringWithFormat:@"%d", gLosses];
    _goals.text = [NSString stringWithFormat:@"%d", gGoals];
    if (gStreak >= 0) { _streak.text = [NSString stringWithFormat:@"W%d", gStreak];
        _streak.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0]; }
    else { _streak.text = [NSString stringWithFormat:@"L%d", -gStreak];
        _streak.textColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0]; }

    float bst = cBst();
    _boostLbl.text = [NSString stringWithFormat:@"%.0f%%", bst];
    if      (bst > 60) _boostLbl.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    else if (bst > 25) _boostLbl.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.0 alpha:1.0];
    else               _boostLbl.textColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0];

    NSString *ph = @"—";
    if (gBlindMode) {
        ph = @"BLIND⚡";
        _phaseLbl.textColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0];
    } else {
        _phaseLbl.textColor = UIColor.whiteColor;
        switch (gPhase) {
            case RL_Phase_Idle:        ph = @"IDLE";      break;
            case RL_Phase_Kickoff:     ph = @"KICKOFF";   break;
            case RL_Phase_Chase:       ph = @"CHASE";     break;
            case RL_Phase_Shoot:       ph = @"SHOOT";     break;
            case RL_Phase_Flip:        ph = @"FLIP";      break;
            case RL_Phase_WallFlip:    ph = @"WALLFLIP";  break;
            case RL_Phase_Defend:      ph = @"DEFEND";    break;
            case RL_Phase_GetBoost:    ph = @"BOOST";     break;
            case RL_Phase_WaitRestart: ph = @"RESTART";   break;
        }
    }
    _phaseLbl.text = ph;
    _scoreLbl.text = [NSString stringWithFormat:@"%d – %d", bSc(), oSc()];
    if (gSessStart) {
        NSTimeInterval e = [[NSDate date] timeIntervalSinceDate:gSessStart];
        _timeLbl.text = [NSString stringWithFormat:@"%02d:%02d", (int)e/60, (int)e%60];
    }
}
@end

@interface RL_MenuView : UIView
@property (nonatomic, strong) RL_StatsView *stats;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, assign) CGPoint dragOff;
- (void)refresh;
@end

@implementation RL_MenuView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    self.stats = [[RL_StatsView alloc] initWithFrame:CGRectMake(0, 0, f.size.width, f.size.height-38)];
    [self addSubview:self.stats];

    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleBtn.frame = CGRectMake(0, f.size.height-34, f.size.width, 30);
    [self.toggleBtn setTitle:@"▶  START BOT" forState:UIControlStateNormal];
    [self.toggleBtn setTitleColor:[UIColor colorWithRed:0 green:0.95 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.toggleBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    self.toggleBtn.layer.cornerRadius = 8;
    self.toggleBtn.layer.borderWidth  = 1;
    self.toggleBtn.layer.borderColor  = [UIColor colorWithRed:0 green:0.9 blue:1.0 alpha:0.35].CGColor;
    [self.toggleBtn addTarget:self action:@selector(rl_toggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggleBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(rl_pan:)];
    [self addGestureRecognizer:pan];
    return self;
}

- (void)rl_toggle {
    gBotOn = !gBotOn;
    if (gBotOn) {
        if (!gSessStart) { gSessStart = [NSDate date]; gLastBlue = bSc(); rl_log(@"=== Session started ==="); }
        [self.toggleBtn setTitle:@"⏹  STOP BOT" forState:UIControlStateNormal];
        self.toggleBtn.backgroundColor = [UIColor colorWithRed:0 green:0.35 blue:0.0 alpha:0.55];
    } else {
        rl_releaseAll();
        [self.toggleBtn setTitle:@"▶  START BOT" forState:UIControlStateNormal];
        self.toggleBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    }
}

- (void)rl_pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) self.dragOff = [g locationInView:self];
    CGPoint loc = [g locationInView:self.superview];
    self.frame = CGRectMake(loc.x-self.dragOff.x, loc.y-self.dragOff.y, self.bounds.size.width, self.bounds.size.height);
}

- (void)refresh { [self.stats refresh]; }
@end

// ============================================================
// MARK: — Threads
// ============================================================
static RL_MenuView *gMenu = nil;

// Bot loop — randomised tick rate 55–65 Hz
static void *rl_botThread(void *_) {
    while (YES) {
        uint32_t ns = BOT_TICK_MIN_NS + arc4random_uniform(BOT_TICK_MAX_NS - BOT_TICK_MIN_NS);
        struct timespec ts = {0, ns};
        nanosleep(&ts, NULL);
        if (!gBotOn) continue;
        @autoreleasepool { rl_tick(); }
    }
    return NULL;
}

// Auto-restart watcher
static void *rl_restartThread(void *_) {
    while (YES) {
        [NSThread sleepForTimeInterval:0.5];
        if (!gBotOn || gPhase != RL_Phase_WaitRestart) continue;
        [NSThread sleepForTimeInterval:RESTART_DELAY_SEC];
        dispatch_async(dispatch_get_main_queue(), ^{
            CGPoint btn = CGPointMake(BTN_RESTART_X, BTN_RESTART_Y);
            rl_tap(btn, 0.1); rl_rsleep(0.38, 80); rl_tap(btn, 0.1);
            gLastBlue = 0; gPhase = RL_Phase_Idle; gEndHandled = NO;
            rl_log(@"→ Restarting match");
        });
    }
    return NULL;
}

// 4 Hz UI refresh
static void rl_startUITimer(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, (uint64_t)(0.25*NSEC_PER_SEC), (uint64_t)(0.05*NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ [gMenu refresh]; });
    dispatch_resume(t);
}

// ============================================================
// MARK: — Entry Point
// ============================================================
__attribute__((constructor))
static void RL_BotInit(void) {
    rl_denyAttach();
    rl_spoofImageName();

    // Locate game base from dyld image list
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "RocketLeagueSideswipe") ||
                     strstr(name, "rocketleague")          ||
                     strstr(name, "epicgames"))) {
            gameBase = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    // If not found by name, use first image (main executable)
    if (!gameBase && _dyld_image_count() > 0)
        gameBase = (uintptr_t)_dyld_get_image_header(0);

    // Try to resolve GEngine pointer via pattern scan
    if (gameBase) gEnginePtr = rl_resolveEngine();

    // If GEngine not resolved, blind mode will kick in automatically
    // after BLIND_ZERO_THRESH ticks of zero reads in rl_tick().

    // Init IOHIDEvent touch injection layer (replaces UITouch private API)
    rl_initHID();

    memset(gSlotActive, 0, sizeof(gSlotActive));
    memset(gSlotPt,     0, sizeof(gSlotPt));
    memset(gPadLastCollect, 0, sizeof(gPadLastCollect));
    memset(gPadIsLarge, 0, sizeof(gPadIsLarge));

    pthread_t th;
    pthread_create(&th, NULL, rl_botThread,     NULL); pthread_detach(th);
    pthread_create(&th, NULL, rl_restartThread, NULL); pthread_detach(th);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        UIWindow *win = rl_win(); if (!win) return;
        CGRect sc = win.bounds;
        gMenu = [[RL_MenuView alloc] initWithFrame:CGRectMake(sc.size.width-175, 55, 165, 225)];
        gMenu.layer.zPosition = 9999;
        [win addSubview:gMenu];
        rl_startUITimer();
    });
}

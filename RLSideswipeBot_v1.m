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

// ============================================================
// GOD-MODE CONSTANTS — absolute maximum, every knob pinned
// ============================================================
#define BOT_TICK_MIN_NS     5500000    // ~182 Hz — near display-sync speed
#define BOT_TICK_MAX_NS     7000000    // ~143 Hz min
#define BOOST_USE_THRESH    3.0f       // boost unless truly 0
#define BOOST_LOW_THRESH    2.0f       // only chase pad if sub-2%
#define RESTART_DELAY_SEC   1.2        // instant restart
#define PREDICT_DT_NEAR     0.35f      // deep look-ahead even when close
#define PREDICT_DT_FAR      0.90f      // 900ms prediction on far ball
#define STEER_DEADZONE      4.0f       // razor-tight steering
#define SHOOT_RANGE         180.0f     // attack from 180 units out
#define WALL_FLIP_THRESH    300.0f     // wall-flip very early
#define FLIP_Y_THRESH       35.0f      // go aerial at slightest height diff
#define JITTER_MAX          1          // minimal noise = max precision
// Shot aiming — corner offset from goal post
#define SHOT_CORNER_OFFSET  25.0f
// Demo/ram: try to hit opponent if ball unreachable and opp close
#define DEMO_RANGE          80.0f
// Shadow defend: how far back to shadow relative to ball/goal midpoint
#define SHADOW_RATIO        0.38f
// Speed flip interval: every N seconds during chase
#define SPEEDFLIP_INTERVAL  1.1
// Max car speed in Sideswipe (boost cap)
#define CAR_MAX_SPEED       1410.0f
// Sideswipe gravity approximation (units/s²)
#define SIDESWIPE_GRAVITY   720.0f

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

// Car velocity — same VEL offsets as ball, applied to car struct
HIDDEN static float cVX(void) { return rl_rf(rl_car() + OFF_VEL_X); }
HIDDEN static float cVY(void) { return rl_rf(rl_car() + OFF_VEL_Y); }

// Opponent velocity
HIDDEN static float oVX(void) { return rl_rf(rl_opp() + OFF_VEL_X); }
HIDDEN static float oVY(void) { return rl_rf(rl_opp() + OFF_VEL_Y); }

// Distance from opponent to ball
HIDDEN static float distOppBall(void) {
    float dx = bX()-oX(), dy = bY()-oY();
    return sqrtf(dx*dx + dy*dy);
}

// Opponent speed
HIDDEN static float oppSpeed(void) {
    float vx = oVX(), vy = oVY();
    return sqrtf(vx*vx + vy*vy);
}

// Is opponent already committed to the ball (heading toward it fast)?
HIDDEN static BOOL rl_oppCommitted(void) {
    float oDist = distOppBall();
    float oSpd  = oppSpeed();
    // Opponent within 200 and moving toward ball at > 400 u/s → committed
    if (oDist > 200.0f) return NO;
    float dx = bX() - oX();
    // dot product of opp velocity with direction to ball
    float dot = oVX() * dx; // positive = moving toward ball
    return (oSpd > 400.0f && dot > 0.0f);
}

// Score delta: positive = we're winning, negative = losing
HIDDEN static int rl_scoreDelta(void) { return bSc() - oSc(); }

// Score-aware aggression: 1.0 = neutral, >1 = more aggressive, <1 = more cautious
HIDDEN static float rl_aggressionMult(void) {
    int delta = rl_scoreDelta();
    if (delta >= 2)  return 0.70f;  // 2+ up: play very safe
    if (delta == 1)  return 0.85f;  // 1 up: slightly conservative
    if (delta == 0)  return 1.00f;  // tied: standard
    if (delta == -1) return 1.20f;  // 1 down: push harder
    return 1.45f;                   // 2+ down: desperate aggression
}

// Legacy simple prediction — superseded by predictBallAdvanced; kept for reference
HIDDEN __attribute__((unused)) static CGPoint predictBall(void) {
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
HIDDEN __attribute__((unused)) static float distCO(void) {
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
// MARK: — Touch Injection (Unreal Engine IOSView, no jailbreak)
// ============================================================
// Unreal Engine on iOS receives all touches through its own UIView
// subclass (IOSView / FIOSView). It hooks touchesBegan:withEvent:
// directly on that view — UIApplication sendEvent: never reaches UE.
//
// Fix: find the Unreal main view, build a minimal synthetic UITouch
// using private-ivar KVC (no banned selectors), then call
// touchesBegan:/Moved:/Ended: directly on that view on the main thread.
// This is the only method that reaches FIOSInputInterface on non-JB iOS.
// ============================================================

// ——— Unreal view cache ———
static UIView *gUEView = nil;

// Find Unreal's IOSView (the view that owns all game touches)
HIDDEN static UIView *rl_ueView(void) {
    if (gUEView) return gUEView;
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes.allObjects)
        if ([s isKindOfClass:[UIWindowScene class]]) {
            win = [(UIWindowScene *)s windows].firstObject;
            break;
        }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    if (!win) return nil;

    // Unreal's view is typically the root view controller's view,
    // or a subview named "IOSView" / class containing "IOS"
    UIView *root = win.rootViewController.view;
    if (!root) root = win;

    // Walk subviews looking for the deepest full-screen view (UE renders to it)
    // Iterative BFS — no recursive block to avoid retain cycle
    __block UIView *best = root;
    CGFloat screenArea = win.bounds.size.width * win.bounds.size.height;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *v = queue[0]; [queue removeObjectAtIndex:0];
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        if (area >= screenArea * 0.9f) best = v;
        [queue addObjectsFromArray:v.subviews];
    }
    gUEView = best;
    return gUEView;
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
    CGSize sz = w ? w.bounds.size : CGSizeMake(430, 932); // iPhone 15 Plus
    return rl_jitter(CGPointMake(norm.x * sz.width, norm.y * sz.height));
}

// Build synthetic UITouch via KVC (no private selectors — safe iOS 15-17)
HIDDEN static UITouch *rl_makeTouch(CGPoint screenPt, UITouchPhase phase,
                                     UIView *view, UIWindow *win) {
    UITouch *t = [[UITouch alloc] init];
    @try { [t setValue:[NSValue valueWithCGPoint:screenPt] forKey:@"locationInWindow"]; }         @catch (...) {}
    @try { [t setValue:[NSValue valueWithCGPoint:screenPt] forKey:@"previousLocationInWindow"]; } @catch (...) {}
    @try { [t setValue:@((NSInteger)phase)  forKey:@"phase"]; }     @catch (...) {}
    @try { [t setValue:@(1)                 forKey:@"tapCount"]; }  @catch (...) {}
    @try { [t setValue:@(0)                 forKey:@"touchType"]; } @catch (...) {} // UITouchTypeDirect
    @try { [t setValue:win                  forKey:@"window"]; }    @catch (...) {}
    @try { [t setValue:view                 forKey:@"view"]; }      @catch (...) {}
    @try { [t setValue:[NSArray array]      forKey:@"gestureRecognizers"]; } @catch (...) {}
    @try { [t setValue:@(CACurrentMediaTime()) forKey:@"timestamp"]; } @catch (...) {}
    return t;
}

// Deliver touches by calling touchesBegan:/Moved:/Ended: directly on UE view
HIDDEN static void rl_sendPhase(CGPoint screenPt, UITouchPhase phase, UIView *view) {
    if (!view) return;
    UIWindow *win = rl_win();
    UITouch *t = rl_makeTouch(screenPt, phase, view, win);
    NSSet *set = [NSSet setWithObject:t];

    // Create a bare UIEvent (just a container — UE reads the touch set)
    UIEvent *ev = [[UIEvent alloc] init];

    dispatch_async(dispatch_get_main_queue(), ^{
        switch (phase) {
            case UITouchPhaseBegan:
                [view touchesBegan:set withEvent:ev];
                break;
            case UITouchPhaseMoved:
                [view touchesMoved:set withEvent:ev];
                break;
            case UITouchPhaseEnded:
                [view touchesEnded:set withEvent:ev];
                break;
            case UITouchPhaseCancelled:
                [view touchesCancelled:set withEvent:ev];
                break;
            default:
                break;
        }
    });
}

HIDDEN static void rl_initHID(void) {
    // No-op for non-jailbreak path — touch injection via UIKit sendEvent:
    // gSlotActive and gSlotPt zeroed in constructor
}

// ————— Hold state: track which finger (slot) is down at what screen position —————
// Touch slot indices — one finger per action
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
    gSlotPt[slot]     = pt;
    gSlotActive[slot] = YES;
    rl_sendPhase(pt, UITouchPhaseBegan, rl_ueView());
}

HIDDEN static void rl_holdEnd(int slot) {
    if (!gSlotActive[slot]) return;
    rl_sendPhase(gSlotPt[slot], UITouchPhaseEnded, rl_ueView());
    gSlotActive[slot] = NO;
}

HIDDEN static void rl_releaseAll(void) {
    for (int i = 0; i < SLOT_COUNT; i++) rl_holdEnd(i);
}

HIDDEN static void rl_tap(CGPoint norm, double hold) {
    UIView *v = rl_ueView();
    CGPoint pt = rl_normToScreen(norm);
    rl_sendPhase(pt, UITouchPhaseBegan, v);
    if (hold > 0) rl_rsleep(hold, 20);
    rl_sendPhase(pt, UITouchPhaseEnded, v);
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

// Gaussian smoothed steering — velocity-aware, α=0.55 for ultra-fast response
static float gSteerSmooth = 0.0f;

HIDDEN static void rl_steerToward(float targetX) {
    float diff  = targetX - cX();
    // Velocity compensation: lead the steer if we're moving away from target
    float vComp = cVX() * 0.06f; // compensate for car velocity
    diff -= vComp;
    float want  = (diff > STEER_DEADZONE) ? 1.0f : (diff < -STEER_DEADZONE) ? -1.0f : 0.0f;
    // Faster smoothing α=0.55
    gSteerSmooth = gSteerSmooth * 0.45f + want * 0.55f;
    rl_setLeft (gSteerSmooth < -0.18f);
    rl_setRight(gSteerSmooth >  0.18f);
}

// Hard steer — immediate, no smoothing (used for flips and urgent corrections)
HIDDEN static void rl_steerHard(float targetX) {
    float diff = targetX - cX();
    rl_setLeft (diff < -STEER_DEADZONE);
    rl_setRight(diff >  STEER_DEADZONE);
}

// Flip forward toward ball — full commitment double-jump
HIDDEN static void rl_doFlipForward(void) {
    float dx = bX() - cX();
    if (dx > 0) { rl_setRight(YES); rl_setLeft(NO); }
    else        { rl_setLeft(YES);  rl_setRight(NO); }
    rl_rsleep(0.015, 4);
    rl_jump(); // second jump = directional flip
    rl_rsleep(0.015, 4);
    rl_setBoost(YES); // boost through the flip for max speed
}

// ============================================================
// UPGRADE 1 & 2: SLIP RESET + CHAINED GROUND FLIP
// In Sideswipe, powersliding while steering = slip reset
// (like a powerslide drift cancel for tight cornering)
// Use it to redirect instantly without losing speed.
// Then chain: land → steer → flip again = max ground speed.
// ============================================================
static CFTimeInterval gLastSlipTime = 0;
static CFTimeInterval gLastChainFlip = 0;

// Slip reset: powerslide + steer input to snap direction without braking
HIDDEN static void rl_slipReset(float targetX) {
    float dx   = targetX - cX();
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastSlipTime < 0.18) return; // cooldown — don't spam
    gLastSlipTime = now;
    // Apply steer in target direction
    if (dx > 0) { rl_setRight(YES); rl_setLeft(NO); }
    else        { rl_setLeft(YES);  rl_setRight(NO); }
    rl_setPowerslide(YES);             // slide into the direction change
    rl_rsleep(0.055, 12);              // hold slide just enough to redirect
    rl_setPowerslide(NO);              // release — now moving in new direction
}

// Chained flip: on the ground, flip forward for speed boost
// Called after a slip reset or landing to maintain max velocity
HIDDEN static void rl_chainFlip(float targetX) {
    if (!cGnd()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastChainFlip < SPEEDFLIP_INTERVAL) return;
    float spd = sqrtf(cVX()*cVX() + cVY()*cVY());
    if (spd >= CAR_MAX_SPEED * 0.90f) return; // already near max, skip
    gLastChainFlip = now;
    // Steer toward target, jump, then directional flip
    float dx = targetX - cX();
    if (dx > 0) { rl_setRight(YES); rl_setLeft(NO); }
    else        { rl_setLeft(YES);  rl_setRight(NO); }
    rl_rsleep(0.010, 3);
    rl_jump();
    rl_rsleep(0.045, 10);
    rl_doFlipForward();
}

// ============================================================
// UPGRADE 3: DIAGONAL APPROACH ANGLE
// Don't go straight at ball — approach from the side that
// lets you redirect toward their goal in one motion.
// Returns the ideal X intercept point to approach FROM.
// ============================================================
HIDDEN static float rl_approachX(void) {
    float bx       = bX();
    float theirGoalX = rl_theirGoalX();
    float cx       = cX();

    // Desired outgoing direction: ball → their goal
    float shotDirSign = (theirGoalX > bx) ? 1.0f : -1.0f;

    // Ideal approach: come from the OPPOSITE side of shot direction
    // so our car's momentum flows ball → goal naturally
    float offset = shotDirSign * -80.0f; // 80 units behind the shot line
    float approachX = bx + offset;

    // If that puts us past our own position, just go direct
    float directDist  = (float)fabs(bx - cx);
    float diagDist    = (float)fabs(approachX - cx);
    if (diagDist > directDist * 1.6f) return bx; // too far, go direct

    return approachX;
}

// ============================================================
// UPGRADE 4: DEFENSE RESET — after clear, flip back instantly
// ============================================================
static BOOL gJustCleared = NO;
static CFTimeInterval gClearTime = 0;
// Dynamic shadow ratio set by rl_decide each tick (upgrade 5)
float gShadowRatioDynamic = SHADOW_RATIO;

HIDDEN static void rl_markCleared(void) {
    gJustCleared = YES;
    gClearTime   = CACurrentMediaTime();
}

HIDDEN static void rl_defenseReset(void) {
    if (!gJustCleared) return;
    CFTimeInterval now = CACurrentMediaTime();
    // Execute reset only in the 0.1–0.4s window after a clear
    if (now - gClearTime < 0.10 || now - gClearTime > 0.45) {
        if (now - gClearTime > 0.45) gJustCleared = NO;
        return;
    }
    // Flip back toward our goal to recover position instantly
    float ourGoalX = rl_ourGoalX();
    float dx = ourGoalX - cX();
    if (dx > 0) { rl_setRight(YES); rl_setLeft(NO); }
    else        { rl_setLeft(YES);  rl_setRight(NO); }
    rl_setBoost(YES);
    if (cGnd()) {
        rl_jump();
        rl_rsleep(0.045, 10);
        rl_doFlipForward(); // flip back toward our goal
    }
    gJustCleared = NO;
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

// ============================================================
// GOD-MODE BALL PREDICTION — 2nd-order kinematic with bounce
// Simulates up to 2 ground bounces within dt window
// ============================================================
HIDDEN static CGPoint predictBallAdvanced(float dt) {
    float px  = bX(), py = bY();
    float vx  = bVX(), vy = bVY();
    float grav = -SIDESWIPE_GRAVITY;
    float rem  = dt;
    // Arena walls X — ball bounces off left/right walls too
    float wallL = GOAL_X_LEFT  - 20.0f;
    float wallR = GOAL_X_RIGHT + 20.0f;

    // Step simulation with up to 3 bounce iterations
    for (int bounce = 0; bounce < 3 && rem > 0.001f; bounce++) {
        // Time to hit ground from current py with velocity vy
        float tGround = 9999.0f;
        if (vy < 0.0f || (py > GROUND_Y && vy < 0.0f)) {
            // y(t) = py + vy*t + 0.5*g*t² = 0 → 0.5*g*t² + vy*t + py = 0
            float a = 0.5f * grav, b2 = vy, c = py;
            float disc = b2*b2 - 4.0f*a*c;
            if (disc >= 0.0f) {
                float sq = sqrtf(disc);
                float t1 = (-b2 - sq) / (2.0f * a);
                float t2 = (-b2 + sq) / (2.0f * a);
                float tb = (t1 > 0.001f) ? t1 : (t2 > 0.001f ? t2 : 9999.0f);
                if (tb < tGround) tGround = tb;
            }
        }
        // Time to hit ceiling
        float tCeil = 9999.0f;
        if (vy > 0.0f) {
            // y(t) = CEILING_Y → same quadratic
            float a = 0.5f * grav, b2 = vy, c = py - CEILING_Y;
            float disc = b2*b2 - 4.0f*a*c;
            if (disc >= 0.0f) {
                float sq = sqrtf(disc);
                float t1 = (-b2 - sq) / (2.0f * a);
                float t2 = (-b2 + sq) / (2.0f * a);
                float tb = (t1 > 0.001f) ? t1 : (t2 > 0.001f ? t2 : 9999.0f);
                if (tb < tCeil) tCeil = tb;
            }
        }
        float tStep = fminf(rem, fminf(tGround, tCeil));
        // Advance position
        px += vx * tStep;
        py += vy * tStep + 0.5f * grav * tStep * tStep;
        vy += grav * tStep;
        rem -= tStep;
        // Ground bounce: dampen vy, keep vx
        if (tStep >= tGround - 0.001f && py <= GROUND_Y + 1.0f) {
            py = GROUND_Y;
            vy = (float)fabs(vy) * 0.60f; // 60% restitution
            vx *= 0.92f;
        }
        // Ceiling bounce
        if (tStep >= tCeil - 0.001f && py >= CEILING_Y - 1.0f) {
            py = CEILING_Y;
            vy = -(float)fabs(vy) * 0.55f;
        }
        // Wall bounce
        if (px < wallL) { px = wallL; vx = (float)fabs(vx) * 0.85f; }
        if (px > wallR) { px = wallR; vx = -(float)fabs(vx) * 0.85f; }
    }
    return CGPointMake(px, py);
}

// ============================================================
// SHOT ANGLE OPTIMIZER — returns ideal aim X to score
// Picks the larger angle (far post) based on relative ball/car pos
// ============================================================
HIDDEN static float rl_shotAimX(float ballX, float ballY) {
    float goalX = rl_theirGoalX();
    // Direction to goal
    float dx = goalX - ballX;
    // Pick far post corner: harder angle for keeper
    float cornerSign = (goalX > 0.0f) ? -1.0f : 1.0f;
    float farPost = goalX + cornerSign * SHOT_CORNER_OFFSET;
    // Blend: 80% far post, 20% ball current X — stay on target
    (void)dx; (void)ballY;
    return farPost * 0.80f + ballX * 0.20f;
}

// Time-to-intercept estimate: how long to reach a point at max speed
HIDDEN static float rl_tti(CGPoint target) {
    float dx = target.x - cX();
    float dy = target.y - cY();
    float dist = sqrtf(dx*dx + dy*dy);
    float speed = sqrtf(cVX()*cVX() + cVY()*cVY());
    if (speed < 10.0f) speed = 10.0f;
    // Max boosted speed ~1400 units/s in Sideswipe
    float maxSpd = 1400.0f;
    float eff = (speed > maxSpd * 0.5f) ? speed : maxSpd * 0.6f;
    return dist / eff;
}

// Is the opponent closer to the ball than us?
HIDDEN __attribute__((unused)) static BOOL rl_opponentCloserToBall(void) {
    float myDist  = distCB();
    float oDist   = distOppBall();
    return oDist < myDist * 0.85f;
}

HIDDEN static RL_BotPhase rl_decide(void) {
    float bst     = cBst();
    float cx      = cX(), cy = cY();
    float bx      = bX(), by_v = bY();
    float mySpd   = sqrtf(cVX()*cVX() + cVY()*cVY());
    float distToBall = distCB();

    // ---- P0: Kickoff — always charge ----
    if (mSt() == MSTATE_COUNTDOWN) return RL_Phase_Kickoff;

    float ourGoalX   = rl_ourGoalX();
    float theirGoalX = rl_theirGoalX();
    (void)theirGoalX;

    // ---- UPGRADE 5: Score-aware thresholds ----
    float aggMult    = rl_aggressionMult();   // 0.70 (safe) → 1.45 (desperate)
    float shootRange = SHOOT_RANGE  * aggMult; // wider kill zone when losing
    float shadowRatio= SHADOW_RATIO * (2.0f - aggMult); // tighter shadow when safe

    // ---- PRIORITY 1: Existential defense (deep 0.9s prediction) ----
    CGPoint pred09 = predictBallAdvanced(0.9f);
    float predGoalDist09 = (float)fabs(pred09.x - ourGoalX);
    BOOL ballGoingOurWay = (ourGoalX < 0.0f) ? (bVX() < -12.0f) : (bVX() > 12.0f);
    // Aggression mult: defend wider window when aggressive, tighter when safe
    float defendWindow = 160.0f * (2.0f - aggMult);
    if (ballGoingOurWay && predGoalDist09 < defendWindow)
        return RL_Phase_Defend;

    // ---- PRIORITY 2: Shoot — ball within kill range (aggression-scaled) ----
    if (distToBall < shootRange)
        return RL_Phase_Shoot;

    // ---- PRIORITY 3: Aerial attack — ball above us ----
    if (by_v > cy + FLIP_Y_THRESH && distToBall < 340.0f && cGnd())
        return RL_Phase_Flip;

    // ---- PRIORITY 4: Get boost only if critical AND pad directly in path ----
    if (bst < BOOST_LOW_THRESH) {
        int pi = rl_nearestActivePad();
        if (pi >= 0) {
            CGPoint pp = rl_padPos(pi);
            float padBallDist = (float)fabs(pp.x - bx);
            float myBallDist  = (float)fabs(cx  - bx);
            if (padBallDist < myBallDist + 80.0f)
                return RL_Phase_GetBoost;
        }
    }

    // ---- PRIORITY 5: Wall-flip only if truly slow ----
    if ((float)fabs(cx) > WALL_FLIP_THRESH && cGnd() && mySpd < 750.0f && distToBall > 180.0f)
        return RL_Phase_WallFlip;

    // Store shadow ratio for Defend phase (upgrade 5)
    gShadowRatioDynamic = shadowRatio;

    (void)cy;
    (void)mySpd;
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

        // ============================================================
        // GOD KICKOFF — diagonal charge + early flip + full boost
        // ============================================================
        case RL_Phase_Kickoff: {
            float cx = cX();
            if      (cx < -20.0f) gAttackRight = YES;
            else if (cx >  20.0f) gAttackRight = NO;

            rl_setBoost(YES);
            rl_setPowerslide(NO);

            float distToCenter = (float)fabs(cx);
            if (distToCenter > 80.0f) {
                // Full speed diagonal to center
                rl_steerHard(0.0f);
            } else if (distToCenter <= 80.0f && distToCenter > 30.0f && cGnd()) {
                // Mid-approach: steer at ball, pre-jump flip for momentum
                rl_steerHard(bX());
                rl_jump();
                rl_rsleep(0.045, 10);
                rl_doFlipForward();
            } else {
                // Final: smash directly into ball
                rl_steerHard(bX());
                rl_setBoost(YES);
            }
        } break;

        // ============================================================
        // GOD CHASE — slip reset + chain flip + diagonal approach
        // UPGRADE 1: opponent cut — if opp committed, go behind ball
        // UPGRADE 2: slip reset for instant direction change
        // UPGRADE 2b: chain flip for sustained max speed
        // UPGRADE 3: diagonal approach — come from the side for redirect
        // ============================================================
        case RL_Phase_Chase: {
            float bst  = cBst();
            float dist = distCB();
            float tti  = rl_tti(CGPointMake(bX(), bY()));

            // Predict ball at half TTI
            CGPoint pred = predictBallAdvanced(tti * 0.55f);

            // UPGRADE 1: If opponent is already committed to ball,
            // cut BEHIND the ball (between opp's path and their goal)
            // — set up a 50/50 or steal the shot.
            float chaseTargetX;
            if (rl_oppCommitted()) {
                // Position ourselves between ball and OUR goal to intercept
                // If opponent is heading for ball from their side, cut to the
                // ball's projected position from the OPPOSITE angle
                float interceptX = pred.x + (rl_ourGoalX() < 0.0f ? -40.0f : 40.0f);
                chaseTargetX = interceptX;
            } else {
                // UPGRADE 3: Diagonal approach — come from the side that
                // sets up a natural redirect toward their goal
                chaseTargetX = rl_approachX();
                // If still far, aim at prediction; if close, use diagonal
                if (dist > 180.0f) chaseTargetX = pred.x;
            }

            // UPGRADE 2: Slip reset if direction changes sharply
            float dirChange = (float)fabs(chaseTargetX - cX());
            if (dirChange > 120.0f && cGnd() && bst > 5.0f) {
                rl_slipReset(chaseTargetX);
            }

            rl_steerToward(chaseTargetX);
            rl_setBoost(bst > BOOST_USE_THRESH);
            rl_setPowerslide(NO);

            // Aerial intercept: ball high and near
            if (dist < 230.0f && bY() > cY() + 40.0f && cGnd() && bst > 5.0f) {
                rl_steerHard(bX());
                rl_jump();
                rl_rsleep(0.060, 13);
                rl_doFlipForward();
            }
            // UPGRADE 2b: Chain flip — maintain max velocity on ground
            else if (dist > 180.0f && cGnd() && bst > 10.0f) {
                rl_chainFlip(chaseTargetX);
            }
        } break;

        // ============================================================
        // GOD SHOOT — 3-window hit: approach / jump-hit / musty flip
        // UPGRADE 3: diagonal approach — if head-on, shift to angle
        // ============================================================
        case RL_Phase_Shoot: {
            float bst  = cBst();
            float dist = distCB();
            float tti  = rl_tti(CGPointMake(bX(), bY()));
            CGPoint pred = predictBallAdvanced(tti * 0.30f);

            // Optimal aim X using corner optimizer
            float aimX = rl_shotAimX(pred.x, pred.y);

            // UPGRADE 3: When far enough to redirect, use diagonal approach
            // so our car's momentum already points toward their goal at contact
            float approachTargetX;
            if (dist > 80.0f && cGnd()) {
                float diagX = rl_approachX(); // approach from the angle side
                // Blend: weight diagonal more as we get closer to 80 units
                float blend = (dist - 80.0f) / 100.0f; // 0=close, 1=far
                if (blend > 1.0f) blend = 1.0f;
                approachTargetX = diagX * (1.0f - blend) + aimX * blend;
            } else {
                approachTargetX = aimX;
            }

            rl_steerHard(approachTargetX);
            rl_setBoost(bst > BOOST_USE_THRESH);
            rl_setPowerslide(NO);

            if (!cGnd()) {
                // Airborne: track predicted ball, full boost
                rl_steerHard(pred.x);
                rl_setBoost(bst > BOOST_USE_THRESH);
                // Aerial flip into ball if aligned
                if ((float)fabs(bY() - cY()) < 40.0f && dist < 80.0f) {
                    rl_doFlipForward();
                }
            } else if (dist < 50.0f) {
                // MUSTY / ultra-close: jump + immediate flip into ball
                rl_setBoost(YES);
                rl_jump();
                rl_rsleep(0.038, 9);
                rl_doFlipForward();
            } else if (dist < 100.0f) {
                // Jump-hit window: elevate into ball
                rl_setBoost(YES);
                rl_rsleep(0.010, 3);
                rl_jump();
            }
            // else: approach at diagonal angle, steer already set above
        } break;

        // ============================================================
        // GOD FLIP — instant aerial launch, track ball in air
        // ============================================================
        case RL_Phase_Flip: {
            rl_setPowerslide(NO);
            rl_setBoost(cBst() > BOOST_USE_THRESH);

            if (cGnd()) {
                // Launch immediately
                rl_steerHard(bX());
                rl_jump();
                rl_rsleep(0.058, 13);
                rl_doFlipForward();
            } else {
                // Track in air
                rl_steerHard(bX());
                rl_setBoost(cBst() > BOOST_USE_THRESH);
                // If height aligned: second jump to extend reach
                float dy = bY() - cY();
                if ((float)fabs(dy) < 45.0f && distCB() < 90.0f) {
                    rl_jump();
                    rl_rsleep(0.018, 5);
                    rl_doFlipForward();
                }
            }
        } break;

        // ============================================================
        // GOD WALL-FLIP — snap off wall, immediate boost + steer
        // ============================================================
        case RL_Phase_WallFlip: {
            rl_wallFlip();
            rl_setBoost(YES); // always boost through wall flip
            rl_setPowerslide(NO);
            // After flip, immediately steer toward ball
            rl_rsleep(0.055, 12);
            rl_steerHard(bX());
        } break;

        // ============================================================
        // GOD DEFEND — shadow position + hard clear with corner shot
        // UPGRADE 4: defense reset — after clear, immediately flip back
        // UPGRADE 5: dynamic shadow ratio from aggression multiplier
        // ============================================================
        case RL_Phase_Defend: {
            float ourGoalX   = rl_ourGoalX();
            float theirGoalX = rl_theirGoalX();
            float cx         = cX();
            float bst        = cBst();

            // UPGRADE 4: If we just cleared, execute the defense reset flip
            // back toward shadow position before doing anything else
            rl_defenseReset();

            // UPGRADE 5: Use dynamic shadow ratio set by rl_decide
            float dynShadow = gShadowRatioDynamic;

            // Shadow position: between ball prediction and our goal
            CGPoint pred04 = predictBallAdvanced(0.4f);
            float shadowX  = pred04.x * (1.0f - dynShadow) + ourGoalX * dynShadow;

            rl_steerToward(shadowX);
            rl_setBoost(bst > BOOST_USE_THRESH);

            // Powerslide for rapid direction change in tight defense
            float diff = (float)fabs(shadowX - cx);
            rl_setPowerslide(diff < 30.0f && cGnd());

            float dist = distCB();

            if (dist < 110.0f && cGnd()) {
                // HARD CLEAR: flip toward their goal to send ball up-field
                rl_setPowerslide(NO);
                rl_setBoost(YES);
                float dx = theirGoalX - cx;
                if (dx > 0.0f) { rl_setRight(YES); rl_setLeft(NO); }
                else            { rl_setLeft(YES);  rl_setRight(NO); }
                rl_rsleep(0.012, 3);
                rl_jump();
                rl_rsleep(0.040, 9);
                rl_jump(); // directional flip through ball
                // UPGRADE 4: Mark the clear so we flip back next tick
                rl_markCleared();
            } else if (dist < 160.0f && !cGnd()) {
                // Aerial clear: same logic in the air
                rl_setBoost(YES);
                rl_steerHard(theirGoalX);
                rl_markCleared(); // aerial clear also triggers defense reset
            }
        } break;

        // ============================================================
        // GOD BOOST — speed-flip onto pad, instant return to chase
        // ============================================================
        case RL_Phase_GetBoost: {
            int pi = rl_nearestActivePad();
            if (pi < 0) { gPhase = RL_Phase_Chase; break; }

            CGPoint pp  = rl_padPos(pi);
            float dPad  = (float)fabs(pp.x - cX());

            rl_steerHard(pp.x);
            rl_setBoost(NO);  // don't waste what we have
            rl_setPowerslide(NO);

            // Speed-flip onto pad when close enough
            if (dPad < 80.0f && cGnd()) {
                rl_jump();
                rl_rsleep(0.045, 10);
                rl_doFlipForward();
            }
            // On pad — back to ball immediately
            if (dPad < 20.0f) gPhase = RL_Phase_Chase;
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

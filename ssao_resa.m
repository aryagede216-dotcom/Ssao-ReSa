// ssao_resa.m  -- v0.1 (iOS arm64, OpenGL ES)
//
// Tahap 1 (versi ini): HANYA diagnostik. Tidak mengubah gambar.
//   * Mengganti method -[EAGLContext presentRenderbuffer:] lewat runtime ObjC
//     (tanpa JIT, tanpa jailbreak). Hook berjalan di thread render game.
//   * Pada present pertama, membaca state GL (hanya baca, lalu dipulihkan) dan menulis
//     ringkasannya ke Documents/ssao_resa.log: versi GL, API EAGL, FBO yang terikat,
//     ukuran viewport, serta jenis/ukuran attachment depth, stencil, dan warna.
//   * Mengekspor fungsi C yang bisa dipanggil dari Lua lewat FFI (ssao_ctl.lua).
//
// Tahap berikutnya (belum ada): salin depth, pass AO, blur, komposit.
//
// Build:  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 -dynamiclib \
//           -fobjc-arc -O2 -DGLES_SILENCE_DEPRECATION -framework Foundation -framework OpenGLES \
//           -install_name @rpath/ssao_resa.dylib -o ssao_resa.dylib ssao_resa.m

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

#define SSAO_VERSION "0.1"

// ----------------------------------------------------------------------
// State (ditulis dari thread Lua, dibaca dari thread render; int sederhana cukup)
// ----------------------------------------------------------------------
static volatile int g_enabled   = 0;
static volatile int g_stage     = 1;
static volatile int g_probe     = 1;   // 1 = jalankan probe pada present berikutnya
static volatile int g_frames    = 0;

static char g_log_path[1024] = {0};

// ----------------------------------------------------------------------
// Log: NSLog + file Documents/ssao_resa.log
// ----------------------------------------------------------------------
static void log_line(const char *fmt, ...) {
    char buf[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[ssao_resa] %s", buf);
    if (g_log_path[0]) {
        FILE *f = fopen(g_log_path, "a");
        if (f) { fputs(buf, f); fputc('\n', f); fclose(f); }
    }
}

// ----------------------------------------------------------------------
// Probe state GL (hanya membaca; binding renderbuffer dipulihkan)
// ----------------------------------------------------------------------
static void describe_attachment(const char *name, GLenum att) {
    GLint type = 0, obj = 0;
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, att,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    if (type == GL_NONE) { log_line("  %s: tidak ada attachment", name); return; }
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, att,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &obj);
    if (type == GL_RENDERBUFFER) {
        GLint prev = 0, w = 0, h = 0, fmt = 0, ds = 0, ss = 0;
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &prev);
        glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)obj);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_INTERNAL_FORMAT, &fmt);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_DEPTH_SIZE, &ds);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_STENCIL_SIZE, &ss);
        glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)prev);
        log_line("  %s: renderbuffer #%d | %dx%d | format=0x%X | depth=%d stencil=%d bit",
                 name, obj, w, h, (unsigned)fmt, ds, ss);
    } else if (type == GL_TEXTURE) {
        log_line("  %s: tekstur #%d", name, obj);
    } else {
        log_line("  %s: tipe attachment tidak dikenal 0x%X", name, (unsigned)type);
    }
}

static void run_probe(EAGLContext *ctx, NSUInteger target) {
    log_line("---- probe (ssao_resa %s) ----", SSAO_VERSION);
    log_line("hook present aktif | main_thread=%d | EAGL API=%d | sharegroup=%p",
             (int)[NSThread isMainThread], (int)[ctx API], (__bridge void *)[ctx sharegroup]);
    const GLubyte *ver  = glGetString(GL_VERSION);
    const GLubyte *rend = glGetString(GL_RENDERER);
    log_line("GL_VERSION=%s", ver ? (const char *)ver : "(null)");
    log_line("GL_RENDERER=%s", rend ? (const char *)rend : "(null)");

    GLint fb = 0, rb = 0, vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    glGetIntegerv(GL_VIEWPORT, vp);
    log_line("present target=0x%lX | FBO terikat=%d | RB terikat=%d | viewport=%d,%d,%d,%d",
             (unsigned long)target, fb, rb, vp[0], vp[1], vp[2], vp[3]);

    if (fb != 0) {
        describe_attachment("COLOR0 ", GL_COLOR_ATTACHMENT0);
        describe_attachment("DEPTH  ", GL_DEPTH_ATTACHMENT);
        describe_attachment("STENCIL", GL_STENCIL_ATTACHMENT);
    } else {
        log_line("  FBO 0 terikat (framebuffer sistem); attachment tidak bisa ditanyakan");
    }
    // Bersihkan error GL yang mungkin muncul dari query kita sendiri.
    int guard = 0;
    while (glGetError() != GL_NO_ERROR && guard++ < 16) {}
    log_line("---- selesai probe ----");
}

// ----------------------------------------------------------------------
// Pekerjaan per frame (dijalankan tepat sebelum present, di thread render)
// ----------------------------------------------------------------------
static void ssao_frame(EAGLContext *ctx, NSUInteger target) {
    g_frames++;
    if (g_probe) { g_probe = 0; run_probe(ctx, target); }
    if (!g_enabled) return;
    // Stage >= 2 (shader, depth blit, pass AO, blur, komposit) belum diimplementasi di v0.1.
}

// ----------------------------------------------------------------------
// Hook method
// ----------------------------------------------------------------------
typedef BOOL (*PresentFn)(id, SEL, NSUInteger);
static PresentFn orig_present = NULL;

static BOOL hooked_present(id self, SEL _cmd, NSUInteger target) {
    @autoreleasepool {
        ssao_frame((EAGLContext *)self, target);
    }
    return orig_present(self, _cmd, target);
}

__attribute__((constructor))
static void ssao_init(void) {
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            NSString *p = [dirs[0] stringByAppendingPathComponent:@"ssao_resa.log"];
            strlcpy(g_log_path, p.UTF8String, sizeof(g_log_path));
        }
        log_line("dylib dimuat (v%s)", SSAO_VERSION);

        Class cls = objc_getClass("EAGLContext");
        if (!cls) { log_line("GAGAL: kelas EAGLContext tidak ditemukan"); return; }
        Method m = class_getInstanceMethod(cls, @selector(presentRenderbuffer:));
        if (!m)  { log_line("GAGAL: method presentRenderbuffer: tidak ditemukan"); return; }
        orig_present = (PresentFn)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_present);
        log_line("hook terpasang pada -[EAGLContext presentRenderbuffer:]");
    }
}

// ----------------------------------------------------------------------
// API C untuk Lua (FFI)
// ----------------------------------------------------------------------
EXPORT const char *ssao_version(void)     { return SSAO_VERSION; }
EXPORT void ssao_set_enabled(int v)       { g_enabled = v ? 1 : 0; log_line("enabled=%d", g_enabled); }
EXPORT int  ssao_get_enabled(void)        { return g_enabled; }
EXPORT void ssao_set_stage(int v)         { g_stage = v < 1 ? 1 : (v > 6 ? 6 : v); log_line("stage=%d", g_stage); }
EXPORT int  ssao_get_stage(void)          { return g_stage; }
EXPORT int  ssao_get_frames(void)         { return g_frames; }
EXPORT void ssao_probe_next(void)         { g_probe = 1; }

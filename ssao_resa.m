// ssao_resa.m  -- v0.2 (iOS arm64, OpenGL ES 3.0)
//
// Dasar temuan dari perangkat (probe v0.1):
//   * GL = OpenGL ES 3.0 (Apple A15), render di thread non-main, viewport 2532x1170.
//   * Scene digambar ke FBO #1: color = renderbuffer RGBA8, depth/stencil = renderbuffer D24S8.
//   * Hook -[EAGLContext presentRenderbuffer:] hanya terpanggil sekali -> game kemungkinan
//     memakai varian present lain. v0.2 memasang hook ke ketiga varian dan mencatat mana yang aktif.
//
// Yang dilakukan v0.2:
//   1. Hook presentRenderbuffer:, presentRenderbuffer:atTime:, presentRenderbuffer:afterMinimumDuration:
//      (re-entrancy dijaga agar satu frame hanya diproses sekali). Catat nama class + jumlah panggilan.
//   2. SSAO berjenjang, aktif hanya setelah ssao_set_enabled(1) dari Lua:
//        stage 1 = tidak menyentuh GL     stage 2 = buat shader + VAO
//        stage 3 = buat tekstur/FBO       stage 4 = salin depth + pass AO
//        stage 5 = + blur                 stage 6 = + komposit ke layar
//      Naik otomatis tiap 180 frame lancar.
//   3. Penjaga crash: Documents/ssao_guard.txt ditulis sebelum tiap stage. Jika app crash,
//      saat dimuat lagi dylib menurunkan batas aman (ssao_limit.txt).
//
// Build:  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 -dynamiclib \
//           -fobjc-arc -O2 -DGLES_SILENCE_DEPRECATION -framework Foundation -framework OpenGLES \
//           -install_name @rpath/ssao_resa.dylib -o ssao_resa.dylib ssao_resa.m

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifndef GL_VERTEX_ARRAY_BINDING
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#endif

#define EXPORT __attribute__((visibility("default")))
#define SSAO_VERSION "0.2"
#define OK_FRAMES_PER_STAGE 180

// ----------------------------------------------------------------------
// Konfigurasi & state (ditulis dari thread Lua, dibaca dari thread render)
// ----------------------------------------------------------------------
static volatile float g_radius    = 0.8f;
static volatile float g_intensity = 1.0f;
static volatile float g_bias      = 0.03f;
static volatile float g_near      = 0.3f;
static volatile float g_far       = 300.0f;
static volatile float g_hfov      = 70.0f;
static volatile int   g_res_mode  = 0;      // 0 = 1/2, 1 = 3/4
static volatile int   g_debug     = 0;      // 0 mati, 1 pratinjau pojok, 2 layar penuh

static volatile int g_active    = 0;        // diaktifkan dari Lua
static volatile int g_target    = 6;        // stage tertinggi yang diminta
static volatile int g_limit     = 6;        // batas aman (turun otomatis setelah crash)
static volatile int g_probe     = 1;        // 1 = jalankan probe pada frame berikutnya
static volatile int g_frames    = 0;        // frame yang diproses (satu per present)
static int g_cur_stage = 0;
static int g_ok_frames = 0;

static volatile int g_variant_calls[3] = {0, 0, 0};
static const char *k_variant_names[3] = {
    "presentRenderbuffer:", "presentRenderbuffer:atTime:", "presentRenderbuffer:afterMinimumDuration:"
};

static char g_log_path[1024]   = {0};
static char g_guard_path[1024] = {0};
static char g_limit_path[1024] = {0};

// ----------------------------------------------------------------------
// Log + file kecil
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

static int read_int_file(const char *path, int *out) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int v = 0;
    int ok = (fscanf(f, "%d", &v) == 1);
    fclose(f);
    if (ok) *out = v;
    return ok;
}
static void write_int_file(const char *path, int v) {
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%d", v); fclose(f); }
}
static void guard_write(int stage) { write_int_file(g_guard_path, stage); }
static void guard_clear(void)      { remove(g_guard_path); }

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

static void log_eagl_subclasses(void) {
    Class base = objc_getClass("EAGLContext");
    unsigned int n = 0;
    __unsafe_unretained Class *list = objc_copyClassList(&n);
    int found = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        if (c == base) continue;
        for (Class s = class_getSuperclass(c); s; s = class_getSuperclass(s)) {
            if (s == base) { log_line("  subclass EAGLContext: %s", class_getName(c)); found++; break; }
        }
    }
    free(list);
    if (!found) log_line("  tidak ada subclass EAGLContext");
}

static void run_probe(EAGLContext *ctx, NSUInteger target, int variant) {
    log_line("---- probe (ssao_resa %s) ----", SSAO_VERSION);
    log_line("present pertama lewat: %s | class context: %s", k_variant_names[variant], object_getClassName(ctx));
    log_line("main_thread=%d | EAGL API=%d | sharegroup=%p",
             (int)[NSThread isMainThread], (int)[ctx API], (__bridge void *)[ctx sharegroup]);
    const GLubyte *ver  = glGetString(GL_VERSION);
    const GLubyte *rend = glGetString(GL_RENDERER);
    log_line("GL_VERSION=%s", ver ? (const char *)ver : "(null)");
    log_line("GL_RENDERER=%s", rend ? (const char *)rend : "(null)");
    GLint fb = 0, rb = 0, vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    glGetIntegerv(GL_VIEWPORT, vp);
    log_line("target=0x%lX | FBO=%d | RB=%d | viewport=%d,%d,%d,%d",
             (unsigned long)target, fb, rb, vp[0], vp[1], vp[2], vp[3]);
    if (fb != 0) {
        describe_attachment("COLOR0 ", GL_COLOR_ATTACHMENT0);
        describe_attachment("DEPTH  ", GL_DEPTH_ATTACHMENT);
        describe_attachment("STENCIL", GL_STENCIL_ATTACHMENT);
    } else {
        log_line("  FBO 0 terikat (framebuffer sistem)");
    }
    log_eagl_subclasses();
    int guard = 0;
    while (glGetError() != GL_NO_ERROR && guard++ < 16) {}
    log_line("---- selesai probe ----");
}

// ----------------------------------------------------------------------
// Simpan / pulihkan state GL milik game
// ----------------------------------------------------------------------
typedef struct {
    GLint prog, draw_fb, read_fb, rb, vao, abuf, active_tex;
    GLint tex[3];
    GLint vp[4];
    GLboolean cmask[4];
    GLboolean dmask;
    GLint bsrgb, bdrgb, bsa, bda;
    GLboolean caps[5];
} GLState;

static const GLenum k_caps[5] = { GL_BLEND, GL_DEPTH_TEST, GL_CULL_FACE, GL_SCISSOR_TEST, GL_STENCIL_TEST };

static void save_state(GLState *s) {
    glGetIntegerv(GL_CURRENT_PROGRAM, &s->prog);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &s->draw_fb);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &s->read_fb);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &s->rb);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &s->vao);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &s->abuf);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &s->active_tex);
    glGetIntegerv(GL_VIEWPORT, s->vp);
    glGetBooleanv(GL_COLOR_WRITEMASK, s->cmask);
    glGetBooleanv(GL_DEPTH_WRITEMASK, &s->dmask);
    glGetIntegerv(GL_BLEND_SRC_RGB, &s->bsrgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &s->bdrgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &s->bsa);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &s->bda);
    for (int i = 0; i < 5; i++) s->caps[i] = glIsEnabled(k_caps[i]);
    for (int u = 0; u < 3; u++) {
        glActiveTexture(GL_TEXTURE0 + u);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &s->tex[u]);
    }
}

static void restore_state(const GLState *s) {
    for (int u = 0; u < 3; u++) {
        glActiveTexture(GL_TEXTURE0 + u);
        glBindTexture(GL_TEXTURE_2D, (GLuint)s->tex[u]);
    }
    glActiveTexture((GLenum)s->active_tex);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)s->read_fb);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)s->draw_fb);
    glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)s->rb);
    glBindVertexArray((GLuint)s->vao);
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)s->abuf);
    glUseProgram((GLuint)s->prog);
    glViewport(s->vp[0], s->vp[1], s->vp[2], s->vp[3]);
    glColorMask(s->cmask[0], s->cmask[1], s->cmask[2], s->cmask[3]);
    glDepthMask(s->dmask);
    glBlendFuncSeparate((GLenum)s->bsrgb, (GLenum)s->bdrgb, (GLenum)s->bsa, (GLenum)s->bda);
    for (int i = 0; i < 5; i++) {
        if (s->caps[i]) glEnable(k_caps[i]); else glDisable(k_caps[i]);
    }
}

// ----------------------------------------------------------------------
// Shader (GLSL ES 3.00). 'precision highp sampler2D' wajib agar nilai depth tidak lowp.
// ----------------------------------------------------------------------
static const char *VS_SRC =
"#version 300 es\n"
"layout(location=0) in vec2 aPos;\n"
"out vec2 vUV;\n"
"void main(){ vUV = aPos*0.5+0.5; gl_Position = vec4(aPos, 0.0, 1.0); }\n";

#define LINZ_SRC \
"uniform vec2 uNearFar;\n" \
"float linZ(sampler2D t, vec2 uv){\n" \
"  float d = texture(t, uv).r;\n" \
"  float n = uNearFar.x, f = uNearFar.y;\n" \
"  return (2.0*n*f) / (f + n - (d*2.0 - 1.0)*(f - n));\n" \
"}\n"

static const char *AO_SRC =
"#version 300 es\n"
"precision highp float;\n"
"precision highp sampler2D;\n"
"#define SAMPLES 12\n"
"uniform sampler2D uDepth;\n"
"uniform vec2 uProj;\n"
"uniform float uRadius;\n"
"uniform float uIntensity;\n"
"uniform float uBias;\n"
"in vec2 vUV;\n"
"out vec4 oColor;\n"
LINZ_SRC
"vec3 viewPos(vec2 uv, float z){ return vec3((uv*2.0-1.0)*uProj*z, -z); }\n"
"float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }\n"
"void main(){\n"
"  if (texture(uDepth, vUV).r >= 0.9999) { oColor = vec4(1.0); return; }\n"
"  float z = linZ(uDepth, vUV);\n"
"  vec3 P = viewPos(vUV, z);\n"
"  vec3 N = normalize(cross(dFdx(P), dFdy(P)));\n"
"  if (N.z < 0.0) N = -N;\n"
"  float ang = hash(gl_FragCoord.xy) * 6.2831853;\n"
"  vec3 T = normalize(abs(N.y) < 0.99 ? cross(N, vec3(0.0,1.0,0.0)) : cross(N, vec3(1.0,0.0,0.0)));\n"
"  vec3 B = cross(N, T);\n"
"  float occ = 0.0;\n"
"  for (int i = 0; i < SAMPLES; i++){\n"
"    float fi = (float(i) + 0.5) / float(SAMPLES);\n"
"    float a  = ang + float(i) * 2.399963;\n"
"    float r  = sqrt(fi);\n"
"    float h  = sqrt(1.0 - fi);\n"
"    vec3 dir = T*cos(a)*r + B*sin(a)*r + N*h;\n"
"    vec3 S   = P + dir * uRadius * mix(0.1, 1.0, fi*fi);\n"
"    if (-S.z <= 0.0) continue;\n"
"    vec2 suv = (S.xy / (-S.z)) / uProj * 0.5 + 0.5;\n"
"    if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;\n"
"    float sz = linZ(uDepth, suv);\n"
"    float range = smoothstep(0.0, 1.0, uRadius / max(abs(z - sz), 0.0001));\n"
"    occ += (sz < (-S.z) - uBias ? 1.0 : 0.0) * range;\n"
"  }\n"
"  float ao = clamp(1.0 - (occ / float(SAMPLES)) * uIntensity, 0.0, 1.0);\n"
"  oColor = vec4(vec3(ao), 1.0);\n"
"}\n";

static const char *BLUR_SRC =
"#version 300 es\n"
"precision highp float;\n"
"precision highp sampler2D;\n"
"uniform sampler2D uAO;\n"
"uniform sampler2D uDepth;\n"
"uniform vec2 uTexel;\n"
"in vec2 vUV;\n"
"out vec4 oColor;\n"
LINZ_SRC
"void main(){\n"
"  float cz = linZ(uDepth, vUV);\n"
"  float sum = 0.0, wsum = 0.0;\n"
"  for (int x = -2; x < 2; x++){\n"
"    for (int y = -2; y < 2; y++){\n"
"      vec2 uv = vUV + (vec2(float(x), float(y)) + 0.5) * uTexel;\n"
"      float z = linZ(uDepth, uv);\n"
"      float w = max(0.0, 1.0 - abs(z - cz) / (0.05 * cz + 0.05));\n"
"      sum  += texture(uAO, uv).r * w;\n"
"      wsum += w;\n"
"    }\n"
"  }\n"
"  float ao = wsum > 0.0001 ? sum / wsum : texture(uAO, vUV).r;\n"
"  oColor = vec4(vec3(ao), 1.0);\n"
"}\n";

static const char *COMP_SRC =
"#version 300 es\n"
"precision mediump float;\n"
"precision mediump sampler2D;\n"
"uniform sampler2D uAO;\n"
"in vec2 vUV;\n"
"out vec4 oColor;\n"
"void main(){ oColor = vec4(vec3(texture(uAO, vUV).r), 1.0); }\n";

// ----------------------------------------------------------------------
// Objek GL milik kita
// ----------------------------------------------------------------------
static int    g_init = 0;
static GLuint g_p_ao = 0, g_p_blur = 0, g_p_comp = 0;
static GLint  u_ao_depth, u_ao_nf, u_ao_proj, u_ao_radius, u_ao_inten, u_ao_bias;
static GLint  u_bl_ao, u_bl_depth, u_bl_nf, u_bl_texel;
static GLint  u_co_ao;
static GLuint g_vao = 0, g_vbo = 0;
static GLuint t_depth = 0, t_ao = 0, t_blur = 0;
static GLuint f_depth = 0, f_ao = 0, f_blur = 0;
static GLint  g_w = 0, g_h = 0, g_aw = 0, g_ah = 0;

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, (const GLchar *const *)&src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[600];
        glGetShaderInfoLog(s, sizeof(buf), NULL, buf);
        log_line("shader gagal: %s", buf);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint make_program(const char *fs_src) {
    GLuint v = compile_shader(GL_VERTEX_SHADER, VS_SRC);
    if (!v) return 0;
    GLuint f = compile_shader(GL_FRAGMENT_SHADER, fs_src);
    if (!f) { glDeleteShader(v); return 0; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    glDeleteShader(v);
    glDeleteShader(f);
    if (!ok) {
        char buf[600];
        glGetProgramInfoLog(p, sizeof(buf), NULL, buf);
        log_line("link gagal: %s", buf);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

static int init_static(void) {
    g_p_ao   = make_program(AO_SRC);
    g_p_blur = make_program(BLUR_SRC);
    g_p_comp = make_program(COMP_SRC);
    if (!g_p_ao || !g_p_blur || !g_p_comp) return 0;

    u_ao_depth  = glGetUniformLocation(g_p_ao, "uDepth");
    u_ao_nf     = glGetUniformLocation(g_p_ao, "uNearFar");
    u_ao_proj   = glGetUniformLocation(g_p_ao, "uProj");
    u_ao_radius = glGetUniformLocation(g_p_ao, "uRadius");
    u_ao_inten  = glGetUniformLocation(g_p_ao, "uIntensity");
    u_ao_bias   = glGetUniformLocation(g_p_ao, "uBias");
    u_bl_ao     = glGetUniformLocation(g_p_blur, "uAO");
    u_bl_depth  = glGetUniformLocation(g_p_blur, "uDepth");
    u_bl_nf     = glGetUniformLocation(g_p_blur, "uNearFar");
    u_bl_texel  = glGetUniformLocation(g_p_blur, "uTexel");
    u_co_ao     = glGetUniformLocation(g_p_comp, "uAO");

    static const GLfloat quad[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
    glGenVertexArrays(1, &g_vao);
    glBindVertexArray(g_vao);
    glGenBuffers(1, &g_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, (const void *)0);
    g_init = 1;
    log_line("stage 2: shader + VAO siap");
    return 1;
}

static void free_targets(void) {
    if (f_depth) glDeleteFramebuffers(1, &f_depth);
    if (f_ao)    glDeleteFramebuffers(1, &f_ao);
    if (f_blur)  glDeleteFramebuffers(1, &f_blur);
    if (t_depth) glDeleteTextures(1, &t_depth);
    if (t_ao)    glDeleteTextures(1, &t_ao);
    if (t_blur)  glDeleteTextures(1, &t_blur);
    f_depth = f_ao = f_blur = t_depth = t_ao = t_blur = 0;
    g_w = g_h = g_aw = g_ah = 0;
}

static GLuint make_color_target(GLint w, GLint h, GLuint *fbo_out) {
    GLuint tex = 0, fbo = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    *fbo_out = fbo;
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return 0;
    return tex;
}

static int ensure_targets(GLint w, GLint h) {
    float scale = (g_res_mode == 1) ? 0.75f : 0.5f;
    GLint aw = (GLint)(w * scale); if (aw < 1) aw = 1;
    GLint ah = (GLint)(h * scale); if (ah < 1) ah = 1;
    if (g_w == w && g_h == h && g_aw == aw && g_ah == ah && t_depth) return 1;
    free_targets();

    // tekstur depth+stencil, format sama dengan renderbuffer game (D24S8) agar blit valid
    glGenTextures(1, &t_depth);
    glBindTexture(GL_TEXTURE_2D, t_depth);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, w, h, 0,
                 GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &f_depth);
    glBindFramebuffer(GL_FRAMEBUFFER, f_depth);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, t_depth, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        log_line("FBO depth tidak lengkap"); free_targets(); return 0;
    }
    t_ao = make_color_target(aw, ah, &f_ao);
    if (!t_ao)   { log_line("FBO AO tidak lengkap");   free_targets(); return 0; }
    t_blur = make_color_target(aw, ah, &f_blur);
    if (!t_blur) { log_line("FBO blur tidak lengkap"); free_targets(); return 0; }

    g_w = w; g_h = h; g_aw = aw; g_ah = ah;
    log_line("stage 3: target siap | layar %dx%d | AO %dx%d", w, h, aw, ah);
    return 1;
}

static void draw_quad(void) { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }

static void bind_tex(int unit, GLuint tex) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, tex);
}

// ----------------------------------------------------------------------
// Satu frame SSAO. Mengembalikan 0 bila ada kegagalan (pesan di *why).
// ----------------------------------------------------------------------
static int run_ssao(int stage, const char **why) {
    GLState st;
    save_state(&st);
    GLint w = st.vp[2], h = st.vp[3];
    int ok = 1;
    int guard = 0;
    while (glGetError() != GL_NO_ERROR && guard++ < 16) {}   // buang error lama milik game

    if (w < 16 || h < 16) { *why = "viewport tidak valid"; ok = 0; goto done; }

    if (stage >= 2 && !g_init) {
        if (!init_static()) { *why = "kompilasi shader gagal"; ok = 0; goto done; }
    }
    if (stage >= 3) {
        if (!ensure_targets(w, h)) { *why = "pembuatan target gagal"; ok = 0; goto done; }
    }
    if (stage >= 4) {
        // salin depth scene -> tekstur depth
        glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)st.draw_fb);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, f_depth);
        glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_DEPTH_BUFFER_BIT, GL_NEAREST);

        glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE);
        glDisable(GL_SCISSOR_TEST); glDisable(GL_STENCIL_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glDepthMask(GL_FALSE);
        glBindVertexArray(g_vao);

        float tanx = tanf(g_hfov * (float)M_PI / 180.0f * 0.5f);
        float tany = tanx * (float)h / (float)w;

        glBindFramebuffer(GL_FRAMEBUFFER, f_ao);
        glViewport(0, 0, g_aw, g_ah);
        glUseProgram(g_p_ao);
        bind_tex(0, t_depth);
        glUniform1i(u_ao_depth, 0);
        glUniform2f(u_ao_nf, g_near, g_far);
        glUniform2f(u_ao_proj, tanx, tany);
        glUniform1f(u_ao_radius, g_radius);
        glUniform1f(u_ao_inten, g_intensity);
        glUniform1f(u_ao_bias, g_bias);
        draw_quad();
    }
    if (stage >= 5) {
        glBindFramebuffer(GL_FRAMEBUFFER, f_blur);
        glUseProgram(g_p_blur);
        bind_tex(0, t_ao);    glUniform1i(u_bl_ao, 0);
        bind_tex(1, t_depth); glUniform1i(u_bl_depth, 1);
        glUniform2f(u_bl_nf, g_near, g_far);
        glUniform2f(u_bl_texel, 1.0f / (float)g_aw, 1.0f / (float)g_ah);
        draw_quad();
    }
    if (stage >= 6) {
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)st.draw_fb);
        glUseProgram(g_p_comp);
        bind_tex(0, t_blur);
        glUniform1i(u_co_ao, 0);
        glViewport(0, 0, w, h);
        if (g_debug == 2) {
            draw_quad();
        } else {
            glEnable(GL_BLEND);
            glBlendFunc(GL_ZERO, GL_SRC_COLOR);          // layar = layar * AO
            draw_quad();
            if (g_debug == 1) {
                glDisable(GL_BLEND);
                GLint pw = w * 22 / 100, ph = h * 22 / 100;
                glViewport(8, h - ph - 8, pw, ph);
                draw_quad();
            }
        }
    }
    if (stage >= 3) {
        GLenum e = glGetError();
        if (e != GL_NO_ERROR) {
            static char msg[64];
            snprintf(msg, sizeof(msg), "GL error 0x%X", (unsigned)e);
            *why = msg; ok = 0;
        }
    }

done:
    restore_state(&st);
    return ok;
}

// ----------------------------------------------------------------------
// Pekerjaan per frame (dijalankan tepat sebelum present, di thread render)
// ----------------------------------------------------------------------
static void ssao_stop(const char *reason) {
    g_active = 0;
    guard_clear();
    log_line("SSAO dihentikan di stage %d: %s", g_cur_stage, reason);
}

static void ssao_frame(EAGLContext *ctx, NSUInteger target, int variant) {
    g_frames++;
    if (g_probe) { g_probe = 0; run_probe(ctx, target, variant); }
    if (!g_active) return;

    const char *why = "";
    if (!run_ssao(g_cur_stage, &why)) { ssao_stop(why); return; }

    g_ok_frames++;
    if (g_ok_frames >= OK_FRAMES_PER_STAGE) {
        guard_clear();
        int cap = g_target < g_limit ? g_target : g_limit;
        if (g_cur_stage < cap) {
            g_cur_stage++;
            g_ok_frames = 0;
            guard_write(g_cur_stage);
            log_line("stage %d lancar -> mencoba stage %d", g_cur_stage - 1, g_cur_stage);
        } else if (g_ok_frames == OK_FRAMES_PER_STAGE) {
            log_line("stage %d stabil (%d frame lancar)", g_cur_stage, OK_FRAMES_PER_STAGE);
        }
    }
}

// ----------------------------------------------------------------------
// Hook tiga varian present
// ----------------------------------------------------------------------
typedef BOOL (*Present0Fn)(id, SEL, NSUInteger);
typedef BOOL (*Present1Fn)(id, SEL, NSUInteger, double);
static Present0Fn orig_p0 = NULL;
static Present1Fn orig_p1 = NULL;
static Present1Fn orig_p2 = NULL;
static __thread int t_depth_guard = 0;

static void note_call(int v, id self) {
    int n = ++g_variant_calls[v];
    if (n <= 2) log_line("panggilan #%d: %s | class=%s | main_thread=%d",
                         n, k_variant_names[v], object_getClassName(self), (int)[NSThread isMainThread]);
}

static BOOL hooked_p0(id self, SEL _cmd, NSUInteger target) {
    note_call(0, self);
    int top = (t_depth_guard++ == 0);
    if (top) { @autoreleasepool { ssao_frame((EAGLContext *)self, target, 0); } }
    BOOL r = orig_p0(self, _cmd, target);
    t_depth_guard--;
    return r;
}
static BOOL hooked_p1(id self, SEL _cmd, NSUInteger target, double t) {
    note_call(1, self);
    int top = (t_depth_guard++ == 0);
    if (top) { @autoreleasepool { ssao_frame((EAGLContext *)self, target, 1); } }
    BOOL r = orig_p1(self, _cmd, target, t);
    t_depth_guard--;
    return r;
}
static BOOL hooked_p2(id self, SEL _cmd, NSUInteger target, double t) {
    note_call(2, self);
    int top = (t_depth_guard++ == 0);
    if (top) { @autoreleasepool { ssao_frame((EAGLContext *)self, target, 2); } }
    BOOL r = orig_p2(self, _cmd, target, t);
    t_depth_guard--;
    return r;
}

static void install_one(Class cls, const char *selname, IMP hook, void **orig) {
    Method m = class_getInstanceMethod(cls, sel_registerName(selname));
    if (!m) { log_line("method tidak ditemukan: %s", selname); return; }
    *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, hook);
    log_line("hook terpasang: -[EAGLContext %s]", selname);
}

__attribute__((constructor))
static void ssao_init(void) {
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            const char *d = [dirs[0] UTF8String];
            snprintf(g_log_path,   sizeof(g_log_path),   "%s/ssao_resa.log",   d);
            snprintf(g_guard_path, sizeof(g_guard_path), "%s/ssao_guard.txt",  d);
            snprintf(g_limit_path, sizeof(g_limit_path), "%s/ssao_limit.txt",  d);
        }
        log_line("==== dylib dimuat (v%s) ====", SSAO_VERSION);

        // penjaga crash: jika guard masih ada, sesi sebelumnya crash saat stage itu
        int k = 0;
        if (read_int_file(g_guard_path, &k)) {
            g_limit = k - 1 < 0 ? 0 : k - 1;
            write_int_file(g_limit_path, g_limit);
            guard_clear();
            log_line("CRASH terdeteksi pada stage %d di sesi sebelumnya; batas aman = stage %d", k, g_limit);
        } else {
            int l = 0;
            if (read_int_file(g_limit_path, &l)) g_limit = l;
        }

        Class cls = objc_getClass("EAGLContext");
        if (!cls) { log_line("GAGAL: kelas EAGLContext tidak ditemukan"); return; }
        install_one(cls, "presentRenderbuffer:", (IMP)hooked_p0, (void **)&orig_p0);
        install_one(cls, "presentRenderbuffer:atTime:", (IMP)hooked_p1, (void **)&orig_p1);
        install_one(cls, "presentRenderbuffer:afterMinimumDuration:", (IMP)hooked_p2, (void **)&orig_p2);
    }
}

// ----------------------------------------------------------------------
// API C untuk Lua (FFI)
// ----------------------------------------------------------------------
EXPORT const char *ssao_version(void) { return SSAO_VERSION; }

EXPORT void ssao_set_enabled(int v) {
    if (v) {
        if (g_limit < 1) { log_line("tidak aman: batas = 0 (crash di stage 1 sebelumnya)"); return; }
        g_cur_stage = 1; g_ok_frames = 0;
        guard_write(1);
        g_active = 1;
        log_line("SSAO dimulai dari stage 1 | target=%d | batas aman=%d", g_target, g_limit);
    } else {
        g_active = 0;
        guard_clear();
        log_line("SSAO dimatikan");
    }
}
EXPORT int  ssao_get_enabled(void) { return g_active; }
EXPORT void ssao_set_stage(int v)  { g_target = v < 1 ? 1 : (v > 6 ? 6 : v); log_line("target stage=%d", g_target); }
EXPORT int  ssao_get_stage(void)   { return g_cur_stage; }
EXPORT int  ssao_get_target(void)  { return g_target; }
EXPORT int  ssao_get_limit(void)   { return g_limit; }
EXPORT int  ssao_get_frames(void)  { return g_frames; }
EXPORT int  ssao_get_variant_calls(int i) { return (i >= 0 && i < 3) ? g_variant_calls[i] : -1; }
EXPORT void ssao_probe_next(void)  { g_probe = 1; }
EXPORT void ssao_reset_limit(void) { g_limit = 6; remove(g_limit_path); log_line("batas aman direset"); }

EXPORT int ssao_set_param(const char *name, float v) {
    if (!name) return 0;
    if      (!strcmp(name, "radius"))    g_radius = v;
    else if (!strcmp(name, "intensity")) g_intensity = v;
    else if (!strcmp(name, "bias"))      g_bias = v;
    else if (!strcmp(name, "near"))      g_near = v;
    else if (!strcmp(name, "far"))       g_far = v;
    else if (!strcmp(name, "hfov"))      g_hfov = v;
    else if (!strcmp(name, "res"))       g_res_mode = (v >= 0.75f) ? 1 : 0;
    else if (!strcmp(name, "debug"))     g_debug = (int)(v < 0 ? 0 : (v > 2 ? 2 : v));
    else return 0;
    return 1;
}

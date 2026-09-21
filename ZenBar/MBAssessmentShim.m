#import "MBAssessmentShim.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static Class _configClass;
static Class _assertionClass;
static BOOL _loaded;
static id _retainedAssertion;
static id _retainedConfig;

// Birleşik günlük (unified logging). Eskiden her satır ayrıca /tmp/zenbar.log'a
// ekleniyordu: sınırsız büyüyordu (216 KB'a ulaşmıştı), rotasyonu yoktu ve çalışan
// üçüncü parti uygulamaların tam bundle listesini paylaşılan bir dizine yazıyordu.
// Artık os_log kullanılıyor; okumak için:
//   /usr/bin/log show --last 5m --predicate 'subsystem == "com.erenkirkil.ZenBar"' --info
static os_log_t zenbar_logHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.erenkirkil.ZenBar", "assessment");
    });
    return handle;
}

static void zenbar_internalLog(NSString *msg) {
    // Ayrıntılı iz yalnızca hata ayıklama derlemelerinde; Release'te teşhis için
    // yalnızca hata yolları os_log_error ile kalıcı olarak kaydedilir.
    //
    // Gizlilik: bu mesajlar kullanıcının çalışan üçüncü parti uygulamalarının bundle
    // listesini taşıyabiliyor. Geliştirici kendi makinesinde okuyabilsin diye DEBUG'da
    // açık, son kullanıcının sistem günlüğüne düşmesin diye Release'te %{private}.
#if DEBUG
    os_log_info(zenbar_logHandle(), "%{public}@", msg);
#else
    os_log_debug(zenbar_logHandle(), "%{private}@", msg);
#endif
}

static void zenbar_internalLogError(NSString *msg) {
    os_log_error(zenbar_logHandle(), "%{public}@", msg);
}

void zenbar_logMessage(NSString *message) {
    zenbar_internalLog(message);
}

static void zenbar_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    zenbar_internalLog(msg);
}

/// Gerçek hata yolları. Release derlemesinde de kaydedilir — özel framework
/// kaybolduğunda ya da assertion reddedildiğinde teşhisin tek kaynağı budur.
static void zenbar_logError(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    zenbar_internalLogError(msg);
}

static void zenbar_load(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_LAZY);
        if (handle == NULL) {
            zenbar_logError(@"dlopen failed: %s", dlerror());
            return;
        }
        _configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        _assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        _loaded = (_configClass != Nil && _assertionClass != Nil);
        zenbar_log(@"MenuBarClientCore loaded: %d (configClass=%@, assertionClass=%@)",
                   _loaded, _configClass, _assertionClass);
    });
}

BOOL zenbar_assessmentModeAvailable(void) {
    zenbar_load();
    return _loaded;
}

#if DEBUG
// Yalnızca hata ayıklama aracı: Apple özel framework'ün sınıf yüzeyini değiştirdiğinde
// yeni selector'ları keşfetmek için. Release binary'sine girmez.
static void zenbar_appendMethods(NSMutableString *out, Class cls, BOOL classMethods) {
    unsigned int count = 0;
    Class target = classMethods ? object_getClass(cls) : cls;
    Method *methods = class_copyMethodList(target, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        [out appendFormat:@"  %@%@  [%s]\n", classMethods ? @"+" : @"-",
                          NSStringFromSelector(sel), types ?: "?"];
    }
    free(methods);
}

NSString *zenbar_describeAssessmentClasses(void) {
    zenbar_load();
    NSMutableString *out = [NSMutableString string];
    if (!_loaded) {
        [out appendString:@"MenuBarClientCore: classes NOT resolved\n"];
        return out;
    }
    for (Class cls in @[ _configClass, _assertionClass ]) {
        [out appendFormat:@"%@ (superclass %@)\n", NSStringFromClass(cls),
                          NSStringFromClass(class_getSuperclass(cls))];
        zenbar_appendMethods(out, cls, YES);
        zenbar_appendMethods(out, cls, NO);
        unsigned int pcount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pcount);
        for (unsigned int i = 0; i < pcount; i++) {
            [out appendFormat:@"  @property %s  [%s]\n",
                              property_getName(props[i]),
                              property_getAttributes(props[i]) ?: "?"];
        }
        free(props);
        [out appendString:@"\n"];
    }
    return out;
}
#else
NSString *zenbar_describeAssessmentClasses(void) {
    return @"(yalnızca DEBUG derlemesinde kullanılabilir)";
}
#endif

id zenbar_makeConfiguration(NSArray<NSNumber *> *allowedSystemItems,
                            NSArray<NSString *> *allowedBundleIDs) {
    zenbar_load();
    if (!_loaded) {
        zenbar_logError(@"makeConfiguration: framework not loaded");
        return nil;
    }
    @try {
        SEL initSel = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
        if (![_configClass instancesRespondToSelector:initSel]) {
            zenbar_logError(@"makeConfiguration: configClass does not respond to %@", NSStringFromSelector(initSel));
            return nil;
        }

        // Bundle ID'leri doğrula ve temizle (sadece ters DNS biçiminde geçerli paket kimlikleri)
        NSMutableArray<NSString *> *cleanBundles = [NSMutableArray arrayWithCapacity:allowedBundleIDs.count];
        for (NSString *b in allowedBundleIDs) {
            if ([b isKindOfClass:[NSString class]] && [b containsString:@"."] && ![b containsString:@" "]) {
                [cleanBundles addObject:b];
            }
        }

        zenbar_log(@"makeConfiguration with %lu system items (%@), %lu clean bundles",
                   (unsigned long)allowedSystemItems.count, allowedSystemItems, (unsigned long)cleanBundles.count);

        id alloced = [_configClass alloc];
        id (*initMsg)(id, SEL, NSArray *, NSArray *) = (void *)objc_msgSend;
        id config = initMsg(alloced, initSel, allowedSystemItems, cleanBundles);
        zenbar_log(@"makeConfiguration created config: %@", config);
        return config;
    } @catch (NSException *e) {
        zenbar_logError(@"makeConfiguration EXCEPTION: %@", e);
        return nil;
    }
}

id zenbar_activateAssertion(id configuration, void (^completion)(NSError *_Nullable)) {
    zenbar_load();
    zenbar_log(@"zenbar_activateAssertion called, config=%@", configuration);
    if (!_loaded || configuration == nil) {
        zenbar_logError(@"zenbar_activateAssertion: aborting (loaded=%d, config=%@)", _loaded, configuration);
        return nil;
    }
    @try {
        SEL activateSel = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
        if ([_assertionClass instancesRespondToSelector:activateSel]) {
            id assertion = [[_assertionClass alloc] init];
            if (assertion == nil) {
                zenbar_log(@"zenbar_activateAssertion: alloc/init returned nil");
                return nil;
            }

            // Statik olarak da güçlü referans tutuyoruz ki ARC veya blok ömrü nesneyi erken yok etmesin
            _retainedAssertion = assertion;
            _retainedConfig = configuration;

            void (^copiedCompletion)(NSError *) = [completion copy];
            void (^wrappedCompletion)(NSError *) = ^(NSError *error) {
                if (error != nil) {
                    zenbar_logError(@"MBAssessmentModeAssertion completion ERROR: domain=%@, code=%ld, description=%@, userInfo=%@",
                               error.domain, (long)error.code, error.localizedDescription, error.userInfo);
                } else {
                    zenbar_log(@"*** MBAssessmentModeAssertion completion SUCCESS: error is nil! Active in MenuBarAgent. ***");
                }
                if (copiedCompletion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        copiedCompletion(error);
                    });
                }
            };

            void (*activateMsg)(id, SEL, id, id) = (void *)objc_msgSend;
            zenbar_log(@"Sending activateWithConfiguration:completionHandler: to assertion %@...", assertion);
            activateMsg(assertion, activateSel, configuration, wrappedCompletion);
            zenbar_log(@"activateMsg completed. Returning assertion %@", assertion);
            return assertion;
        }
        zenbar_logError(@"zenbar_activateAssertion: no known activation selector on %@", _assertionClass);
        return nil;
    } @catch (NSException *e) {
        zenbar_logError(@"zenbar_activateAssertion EXCEPTION: %@", e);
        return nil;
    }
}

void zenbar_invalidateAssertion(id assertion) {
    id target = assertion ?: _retainedAssertion;
    zenbar_log(@"zenbar_invalidateAssertion called for target: %@", target);
    if (target == nil) return;
    @try {
        SEL invalidateSel = NSSelectorFromString(@"invalidate");
        if ([target respondsToSelector:invalidateSel]) {
            void (*invalidateMsg)(id, SEL) = (void *)objc_msgSend;
            invalidateMsg(target, invalidateSel);
            zenbar_log(@"zenbar_invalidateAssertion: invalidate executed successfully on %@", target);
        }
    } @catch (NSException *e) {
        zenbar_logError(@"zenbar_invalidateAssertion EXCEPTION: %@", e);
    }
    if (target == _retainedAssertion) {
        _retainedAssertion = nil;
        _retainedConfig = nil;
    }
}

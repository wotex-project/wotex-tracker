// Device-only iOS Keychain storage for the WoTEx mobile host.
// Statically linked by Mob's plugin build; no dynamic library is loaded.
#include "erl_nif.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <string.h>

static const NSUInteger WOTEX_MAX_KEY_BYTES = 64;
static const NSUInteger WOTEX_MAX_VALUE_BYTES = 4096;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  return enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static NSString *service(void) {
  return @"org.wotex.tracker.mobile.secure-store.v1";
}

static NSString *account(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary binary;
  if (!enif_inspect_binary(env, term, &binary) &&
      !enif_inspect_iolist_as_binary(env, term, &binary))
    return nil;
  if (binary.size == 0 || binary.size > WOTEX_MAX_KEY_BYTES)
    return nil;
  return [[NSString alloc] initWithBytes:binary.data
                                  length:binary.size
                                encoding:NSUTF8StringEncoding];
}

static NSMutableDictionary *query(NSString *key) {
  return [@{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : service(),
    (__bridge id)kSecAttrAccount : key,
    (__bridge id)kSecAttrSynchronizable : @NO
  } mutableCopy];
}

static ERL_NIF_TERM status_error(ErlNifEnv *env, OSStatus status) {
  if (status == errSecItemNotFound)
    return error(env, "not_found");
  return error(env, "unavailable");
}

static ERL_NIF_TERM nif_fetch(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  if (argc != 1)
    return enif_make_badarg(env);

  @autoreleasepool {
    NSString *key = account(env, argv[0]);
    if (!key)
      return enif_make_badarg(env);

    NSMutableDictionary *attributes = query(key);
    attributes[(__bridge id)kSecReturnData] = @YES;
    attributes[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)attributes,
                                          &result);
    if (status != errSecSuccess)
      return status_error(env, status);

    CFDataRef data = (CFDataRef)result;
    CFIndex length = CFDataGetLength(data);
    if (length <= 0 || length > WOTEX_MAX_VALUE_BYTES) {
      CFRelease(result);
      return error(env, "unavailable");
    }

    ERL_NIF_TERM value;
    unsigned char *target = enif_make_new_binary(env, (size_t)length, &value);
    memcpy(target, CFDataGetBytePtr(data), (size_t)length);
    CFRelease(result);
    return enif_make_tuple2(env, atom(env, "ok"), value);
  }
}

static ERL_NIF_TERM nif_put(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  if (argc != 2)
    return enif_make_badarg(env);

  ErlNifBinary binary;
  if (!enif_inspect_binary(env, argv[1], &binary) &&
      !enif_inspect_iolist_as_binary(env, argv[1], &binary))
    return enif_make_badarg(env);
  if (binary.size == 0 || binary.size > WOTEX_MAX_VALUE_BYTES)
    return enif_make_badarg(env);

  @autoreleasepool {
    NSString *key = account(env, argv[0]);
    if (!key)
      return enif_make_badarg(env);

    NSData *value = [NSData dataWithBytes:binary.data length:binary.size];
    NSMutableDictionary *attributes = query(key);
    attributes[(__bridge id)kSecValueData] = value;
    attributes[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    if (status == errSecDuplicateItem) {
      NSDictionary *updates = @{
        (__bridge id)kSecValueData : value,
        (__bridge id)kSecAttrAccessible :
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      };
      status = SecItemUpdate((__bridge CFDictionaryRef)query(key),
                             (__bridge CFDictionaryRef)updates);
    }

    return status == errSecSuccess ? atom(env, "ok")
                                   : status_error(env, status);
  }
}

static ERL_NIF_TERM nif_delete(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  if (argc != 1)
    return enif_make_badarg(env);

  @autoreleasepool {
    NSString *key = account(env, argv[0]);
    if (!key)
      return enif_make_badarg(env);

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query(key));
    if (status == errSecSuccess || status == errSecItemNotFound)
      return atom(env, "ok");
    return status_error(env, status);
  }
}

static ErlNifFunc nif_funcs[] = {
    {"fetch", 1, nif_fetch, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"put", 2, nif_put, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"delete", 1, nif_delete, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(wotex_secure_store_nif, nif_funcs, NULL, NULL, NULL, NULL)

// Bounded CoreBluetooth central bridge for the WoTEx mobile host.
// Statically linked by Mob's plugin build; no dynamic library is loaded.
#include "erl_nif.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

static const NSUInteger WOTEX_MAX_SERVICES = 8;
static const NSUInteger WOTEX_MAX_DISCOVERED_SERVICES = 32;
static const NSUInteger WOTEX_MAX_CHARACTERISTICS = 64;
static const NSUInteger WOTEX_MAX_PERIPHERALS = 64;
static const NSUInteger WOTEX_MAX_NAME_BYTES = 128;
static const NSUInteger WOTEX_MAX_VALUE_BYTES = 512;
static const int64_t WOTEX_OPERATION_TIMEOUT_MS = 30000;

@interface WotexBLEOperation : NSObject
@property(nonatomic, assign) ErlNifPid pid;
@property(nonatomic, copy) NSString *request;
@end

@implementation WotexBLEOperation
@end

@interface WotexBLEDiscovery : NSObject
@property(nonatomic, strong) WotexBLEOperation *operation;
@property(nonatomic, assign) NSUInteger remaining;
@end

@implementation WotexBLEDiscovery
@end

@interface WotexBLECentral : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *peripherals;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEOperation *> *connections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEOperation *> *owners;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEOperation *> *disconnections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEDiscovery *> *discoveries;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEOperation *> *reads;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WotexBLEOperation *> *writes;
@property(nonatomic, strong) WotexBLEOperation *scanOperation;
@property(nonatomic, strong) NSArray<CBUUID *> *pendingScanServices;
@property(nonatomic, assign) NSInteger pendingScanTimeout;
@end

static WotexBLECentral *g_central;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  return enif_make_atom(env, name);
}

static ERL_NIF_TERM binary(ErlNifEnv *env, NSString *value) {
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  ERL_NIF_TERM term;
  unsigned char *target = enif_make_new_binary(env, data.length, &term);
  if (data.length > 0)
    memcpy(target, data.bytes, data.length);
  return term;
}

static ERL_NIF_TERM binary_data(ErlNifEnv *env, NSData *value) {
  ERL_NIF_TERM term;
  unsigned char *target = enif_make_new_binary(env, value.length, &term);
  if (value.length > 0)
    memcpy(target, value.bytes, value.length);
  return term;
}

static ERL_NIF_TERM list_strings(ErlNifEnv *env, NSArray<NSString *> *values) {
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (NSString *value in [values reverseObjectEnumerator])
    list = enif_make_list_cell(env, binary(env, value), list);
  return list;
}

static ERL_NIF_TERM properties(ErlNifEnv *env, CBCharacteristicProperties value) {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  if (value & CBCharacteristicPropertyAuthenticatedSignedWrites)
    [names addObject:@"authenticated_signed_writes"];
  if (value & CBCharacteristicPropertyBroadcast)
    [names addObject:@"broadcast"];
  if (value & CBCharacteristicPropertyExtendedProperties)
    [names addObject:@"extended_properties"];
  if (value & CBCharacteristicPropertyIndicate)
    [names addObject:@"indicate"];
  if (value & CBCharacteristicPropertyIndicateEncryptionRequired)
    [names addObject:@"indicate_encryption_required"];
  if (value & CBCharacteristicPropertyNotify)
    [names addObject:@"notify"];
  if (value & CBCharacteristicPropertyNotifyEncryptionRequired)
    [names addObject:@"notify_encryption_required"];
  if (value & CBCharacteristicPropertyRead)
    [names addObject:@"read"];
  if (value & CBCharacteristicPropertyWrite)
    [names addObject:@"write"];
  if (value & CBCharacteristicPropertyWriteWithoutResponse)
    [names addObject:@"write_without_response"];

  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (NSString *name in [names reverseObjectEnumerator])
    list = enif_make_list_cell(env, atom(env, name.UTF8String), list);
  return list;
}

static NSString *uuid_string(CBUUID *uuid) {
  return uuid.UUIDString.lowercaseString;
}

static NSString *peripheral_id(CBPeripheral *peripheral) {
  return peripheral.identifier.UUIDString.lowercaseString;
}

static void send_event(WotexBLEOperation *operation, const char *event,
                       ERL_NIF_TERM (^payload)(ErlNifEnv *)) {
  if (!operation)
    return;

  ErlNifEnv *env = enif_alloc_env();
  ERL_NIF_TERM message =
      enif_make_tuple4(env, atom(env, "ble_central"), binary(env, operation.request),
                       atom(env, event), payload(env));
  ErlNifPid pid = operation.pid;
  enif_send(NULL, &pid, env, message);
  enif_free_env(env);
}

static void send_nil(WotexBLEOperation *operation, const char *event) {
  send_event(operation, event, ^ERL_NIF_TERM(ErlNifEnv *env) {
    return atom(env, "nil");
  });
}

static void send_reason(WotexBLEOperation *operation, const char *event,
                        const char *reason) {
  send_event(operation, event, ^ERL_NIF_TERM(ErlNifEnv *env) {
    return atom(env, reason);
  });
}

static const char *manager_reason(CBManagerState state) {
  switch (state) {
  case CBManagerStateUnsupported:
    return "unsupported";
  case CBManagerStateUnauthorized:
    return "unauthorized";
  case CBManagerStatePoweredOff:
    return "powered_off";
  case CBManagerStateResetting:
    return "resetting";
  default:
    return "unavailable";
  }
}

static const char *operation_reason(NSError *error) {
  if (!error)
    return "unavailable";
  if ([error.domain isEqualToString:CBErrorDomain] && error.code == CBErrorNotConnected)
    return "not_connected";
  return "unavailable";
}

static NSString *operation_key(NSString *peripheral, NSString *service,
                               NSString *characteristic) {
  return [NSString stringWithFormat:@"%@|%@|%@", peripheral, service, characteristic];
}

static CBCharacteristic *find_characteristic(CBPeripheral *peripheral,
                                             NSString *serviceUUID,
                                             NSString *characteristicUUID) {
  for (CBService *service in peripheral.services) {
    if (![uuid_string(service.UUID) isEqualToString:serviceUUID])
      continue;
    for (CBCharacteristic *characteristic in service.characteristics) {
      if ([uuid_string(characteristic.UUID) isEqualToString:characteristicUUID])
        return characteristic;
    }
  }
  return nil;
}

static void after_operation_timeout(dispatch_block_t block) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, WOTEX_OPERATION_TIMEOUT_MS * NSEC_PER_MSEC),
      dispatch_get_main_queue(), block);
}

@implementation WotexBLECentral

- (instancetype)init {
  self = [super init];
  if (self) {
    _peripherals = [NSMutableDictionary dictionary];
    _connections = [NSMutableDictionary dictionary];
    _owners = [NSMutableDictionary dictionary];
    _disconnections = [NSMutableDictionary dictionary];
    _discoveries = [NSMutableDictionary dictionary];
    _reads = [NSMutableDictionary dictionary];
    _writes = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)ensureManager {
  if (!self.manager)
    self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
}

- (BOOL)poweredOn:(WotexBLEOperation *)operation {
  [self ensureManager];
  if (self.manager.state == CBManagerStatePoweredOn)
    return YES;
  send_reason(operation, "rejected", manager_reason(self.manager.state));
  return NO;
}

- (void)startScan:(WotexBLEOperation *)operation services:(NSArray<CBUUID *> *)services
          timeout:(NSInteger)timeout {
  if (self.scanOperation) {
    send_reason(operation, "rejected", "busy");
    return;
  }

  [self ensureManager];
  self.scanOperation = operation;
  self.pendingScanServices = services;
  self.pendingScanTimeout = timeout;

  if (self.manager.state == CBManagerStateUnknown ||
      self.manager.state == CBManagerStateResetting)
    return;

  [self beginPendingScan];
}

- (void)beginPendingScan {
  WotexBLEOperation *operation = self.scanOperation;
  if (!operation)
    return;

  if (self.manager.state != CBManagerStatePoweredOn) {
    send_reason(operation, "rejected", manager_reason(self.manager.state));
    [self clearScan];
    return;
  }

  NSArray<CBUUID *> *services = self.pendingScanServices;
  NSInteger timeout = self.pendingScanTimeout;
  [self.manager scanForPeripheralsWithServices:services
                                       options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @NO}];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   if (self.scanOperation == operation) {
                     [self.manager stopScan];
                     send_nil(operation, "scan_complete");
                     [self clearScan];
                   }
                 });
}

- (void)clearScan {
  self.scanOperation = nil;
  self.pendingScanServices = nil;
  self.pendingScanTimeout = 0;
}

- (void)stopScan:(WotexBLEOperation *)operation {
  WotexBLEOperation *active = self.scanOperation;
  if (!active) {
    send_reason(operation, "rejected", "not_found");
    return;
  }
  [self.manager stopScan];
  send_nil(active, "scan_stopped");
  if (active != operation)
    send_nil(operation, "scan_stopped");
  [self clearScan];
}

- (void)connect:(WotexBLEOperation *)operation peripheralID:(NSString *)identifier {
  if (![self poweredOn:operation])
    return;
  CBPeripheral *peripheral = self.peripherals[identifier];
  if (!peripheral) {
    send_reason(operation, "rejected", "not_found");
    return;
  }
  if (peripheral.state == CBPeripheralStateConnected) {
    self.owners[identifier] = operation;
    send_event(operation, "connected", ^ERL_NIF_TERM(ErlNifEnv *env) {
      return binary(env, identifier);
    });
    return;
  }
  if (self.connections[identifier]) {
    send_reason(operation, "rejected", "busy");
    return;
  }
  self.connections[identifier] = operation;
  [self.manager connectPeripheral:peripheral options:nil];
  after_operation_timeout(^{
    if (self.connections[identifier] == operation) {
      [self.connections removeObjectForKey:identifier];
      [self.manager cancelPeripheralConnection:peripheral];
      send_reason(operation, "connect_failed", "unavailable");
    }
  });
}

- (void)disconnect:(WotexBLEOperation *)operation peripheralID:(NSString *)identifier {
  if (![self poweredOn:operation])
    return;
  CBPeripheral *peripheral = self.peripherals[identifier];
  if (!peripheral || peripheral.state == CBPeripheralStateDisconnected) {
    send_reason(operation, "rejected", "not_connected");
    return;
  }
  if (self.disconnections[identifier]) {
    send_reason(operation, "rejected", "busy");
    return;
  }
  self.disconnections[identifier] = operation;
  [self.manager cancelPeripheralConnection:peripheral];
  after_operation_timeout(^{
    if (self.disconnections[identifier] == operation) {
      [self.disconnections removeObjectForKey:identifier];
      send_reason(operation, "operation_failed", "unavailable");
    }
  });
}

- (void)discover:(WotexBLEOperation *)operation peripheralID:(NSString *)identifier
         services:(NSArray<CBUUID *> *)services {
  if (![self poweredOn:operation])
    return;
  CBPeripheral *peripheral = self.peripherals[identifier];
  if (!peripheral || peripheral.state != CBPeripheralStateConnected) {
    send_reason(operation, "rejected", "not_connected");
    return;
  }
  if (self.discoveries[identifier]) {
    send_reason(operation, "rejected", "busy");
    return;
  }
  WotexBLEDiscovery *discovery = [WotexBLEDiscovery new];
  discovery.operation = operation;
  self.discoveries[identifier] = discovery;
  peripheral.delegate = self;
  [peripheral discoverServices:services];
  after_operation_timeout(^{
    if (self.discoveries[identifier] == discovery) {
      [self.discoveries removeObjectForKey:identifier];
      send_reason(operation, "operation_failed", "unavailable");
    }
  });
}

- (void)read:(WotexBLEOperation *)operation peripheralID:(NSString *)identifier
      service:(NSString *)serviceUUID characteristic:(NSString *)characteristicUUID {
  CBPeripheral *peripheral = self.peripherals[identifier];
  if (!peripheral || peripheral.state != CBPeripheralStateConnected) {
    send_reason(operation, "rejected", "not_connected");
    return;
  }
  CBCharacteristic *characteristic =
      find_characteristic(peripheral, serviceUUID, characteristicUUID);
  if (!characteristic || !(characteristic.properties & CBCharacteristicPropertyRead)) {
    send_reason(operation, "rejected", "not_found");
    return;
  }
  NSString *key = operation_key(identifier, serviceUUID, characteristicUUID);
  if (self.reads[key]) {
    send_reason(operation, "rejected", "busy");
    return;
  }
  self.reads[key] = operation;
  [peripheral readValueForCharacteristic:characteristic];
  after_operation_timeout(^{
    if (self.reads[key] == operation) {
      [self.reads removeObjectForKey:key];
      send_reason(operation, "operation_failed", "unavailable");
    }
  });
}

- (void)write:(WotexBLEOperation *)operation peripheralID:(NSString *)identifier
       service:(NSString *)serviceUUID characteristic:(NSString *)characteristicUUID
         value:(NSData *)value {
  CBPeripheral *peripheral = self.peripherals[identifier];
  if (!peripheral || peripheral.state != CBPeripheralStateConnected) {
    send_reason(operation, "rejected", "not_connected");
    return;
  }
  CBCharacteristic *characteristic =
      find_characteristic(peripheral, serviceUUID, characteristicUUID);
  if (!characteristic || !(characteristic.properties & CBCharacteristicPropertyWrite)) {
    send_reason(operation, "rejected", "not_found");
    return;
  }
  NSUInteger maximum = [peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse];
  if (value.length == 0 || value.length > WOTEX_MAX_VALUE_BYTES || value.length > maximum) {
    send_reason(operation, "rejected", "invalid_data");
    return;
  }
  NSString *key = operation_key(identifier, serviceUUID, characteristicUUID);
  if (self.writes[key]) {
    send_reason(operation, "rejected", "busy");
    return;
  }
  self.writes[key] = operation;
  [peripheral writeValue:value
       forCharacteristic:characteristic
                    type:CBCharacteristicWriteWithResponse];
  after_operation_timeout(^{
    if (self.writes[key] == operation) {
      [self.writes removeObjectForKey:key];
      send_reason(operation, "operation_failed", "unavailable");
    }
  });
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  (void)central;
  if (self.scanOperation)
    [self beginPendingScan];
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
  (void)central;
  WotexBLEOperation *operation = self.scanOperation;
  if (!operation || RSSI.integerValue < -127 || RSSI.integerValue > 20)
    return;

  NSString *identifier = peripheral_id(peripheral);
  if (!self.peripherals[identifier] && self.peripherals.count >= WOTEX_MAX_PERIPHERALS)
    return;
  self.peripherals[identifier] = peripheral;

  NSString *name = peripheral.name;
  if ([name dataUsingEncoding:NSUTF8StringEncoding].length > WOTEX_MAX_NAME_BYTES)
    name = nil;

  NSArray<CBUUID *> *advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey];
  NSMutableSet<NSString *> *unique = [NSMutableSet set];
  for (CBUUID *uuid in advertised.count > 0 ? advertised : self.pendingScanServices) {
    if (unique.count == 16)
      break;
    [unique addObject:uuid_string(uuid)];
  }
  NSArray<NSString *> *services = [[unique allObjects] sortedArrayUsingSelector:@selector(compare:)];

  send_event(operation, "scan_result", ^ERL_NIF_TERM(ErlNifEnv *env) {
    ERL_NIF_TERM nameTerm = name ? binary(env, name) : atom(env, "nil");
    return enif_make_tuple4(env, binary(env, identifier), nameTerm,
                            enif_make_int(env, RSSI.intValue), list_strings(env, services));
  });
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
  NSString *identifier = peripheral_id(peripheral);
  WotexBLEOperation *operation = self.connections[identifier];
  [self.connections removeObjectForKey:identifier];
  self.owners[identifier] = operation;
  peripheral.delegate = self;
  send_event(operation, "connected", ^ERL_NIF_TERM(ErlNifEnv *env) {
    return binary(env, identifier);
  });
}

- (void)centralManager:(CBCentralManager *)central
 didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
  (void)central;
  NSString *identifier = peripheral_id(peripheral);
  WotexBLEOperation *operation = self.connections[identifier];
  [self.connections removeObjectForKey:identifier];
  send_reason(operation, "connect_failed", operation_reason(error));
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral
              timestamp:(CFAbsoluteTime)timestamp
               isReconnecting:(BOOL)isReconnecting
                  error:(NSError *)error API_AVAILABLE(ios(17.0)) {
  (void)central;
  (void)timestamp;
  (void)isReconnecting;
  [self disconnected:peripheral error:error];
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral
                  error:(NSError *)error {
  (void)central;
  [self disconnected:peripheral error:error];
}

- (void)disconnected:(CBPeripheral *)peripheral error:(NSError *)error {
  NSString *identifier = peripheral_id(peripheral);
  WotexBLEOperation *operation = self.disconnections[identifier] ?: self.owners[identifier];
  [self.disconnections removeObjectForKey:identifier];
  [self.owners removeObjectForKey:identifier];
  if (operation) {
    send_event(operation, "disconnected", ^ERL_NIF_TERM(ErlNifEnv *env) {
      return binary(env, identifier);
    });
  }
  [self failOperationsForPeripheral:identifier reason:operation_reason(error)];
}

- (void)failOperationsForPeripheral:(NSString *)identifier reason:(const char *)reason {
  WotexBLEDiscovery *discovery = self.discoveries[identifier];
  if (discovery) {
    send_reason(discovery.operation, "operation_failed", reason);
    [self.discoveries removeObjectForKey:identifier];
  }
  NSString *prefix = [identifier stringByAppendingString:@"|"];
  for (NSMutableDictionary<NSString *, WotexBLEOperation *> *operations in
       @[ self.reads, self.writes ]) {
    for (NSString *key in [operations.allKeys copy]) {
      if ([key hasPrefix:prefix]) {
        send_reason(operations[key], "operation_failed", reason);
        [operations removeObjectForKey:key];
      }
    }
  }
}

- (void)peripheral:(CBPeripheral *)peripheral
 didDiscoverServices:(NSError *)error {
  NSString *identifier = peripheral_id(peripheral);
  WotexBLEDiscovery *discovery = self.discoveries[identifier];
  if (!discovery)
    return;
  if (error) {
    send_reason(discovery.operation, "operation_failed", operation_reason(error));
    [self.discoveries removeObjectForKey:identifier];
    return;
  }

  NSArray<CBService *> *services = peripheral.services ?: @[];
  if (services.count == 0 || services.count > WOTEX_MAX_DISCOVERED_SERVICES) {
    send_reason(discovery.operation, "operation_failed", "not_found");
    [self.discoveries removeObjectForKey:identifier];
    return;
  }
  NSMutableArray<NSString *> *uuids = [NSMutableArray arrayWithCapacity:services.count];
  for (CBService *service in services)
    [uuids addObject:uuid_string(service.UUID)];
  [uuids sortUsingSelector:@selector(compare:)];

  send_event(discovery.operation, "services", ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple2(env, binary(env, identifier), list_strings(env, uuids));
  });

  discovery.remaining = services.count;
  for (CBService *service in services)
    [peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didDiscoverCharacteristicsForService:(CBService *)service
              error:(NSError *)error {
  NSString *identifier = peripheral_id(peripheral);
  WotexBLEDiscovery *discovery = self.discoveries[identifier];
  if (!discovery)
    return;
  if (error || service.characteristics.count > WOTEX_MAX_CHARACTERISTICS) {
    send_reason(discovery.operation, "operation_failed", operation_reason(error));
    [self.discoveries removeObjectForKey:identifier];
    return;
  }

  NSArray<CBCharacteristic *> *characteristics =
      [service.characteristics sortedArrayUsingComparator:^NSComparisonResult(
                                   CBCharacteristic *left, CBCharacteristic *right) {
        return [uuid_string(left.UUID) compare:uuid_string(right.UUID)];
      }];

  send_event(discovery.operation, "characteristics", ^ERL_NIF_TERM(ErlNifEnv *env) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (CBCharacteristic *characteristic in [characteristics reverseObjectEnumerator]) {
      ERL_NIF_TERM item =
          enif_make_tuple2(env, binary(env, uuid_string(characteristic.UUID)),
                           properties(env, characteristic.properties));
      list = enif_make_list_cell(env, item, list);
    }
    return enif_make_tuple3(env, binary(env, identifier), binary(env, uuid_string(service.UUID)),
                            list);
  });

  if (discovery.remaining > 0)
    discovery.remaining -= 1;
  if (discovery.remaining == 0) {
    send_nil(discovery.operation, "discovery_complete");
    [self.discoveries removeObjectForKey:identifier];
  }
}

- (void)peripheral:(CBPeripheral *)peripheral
 didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
              error:(NSError *)error {
  NSString *identifier = peripheral_id(peripheral);
  NSString *service = uuid_string(characteristic.service.UUID);
  NSString *uuid = uuid_string(characteristic.UUID);
  NSString *key = operation_key(identifier, service, uuid);
  WotexBLEOperation *operation = self.reads[key];
  [self.reads removeObjectForKey:key];
  if (!operation)
    return;
  NSData *value = characteristic.value;
  if (error || !value || value.length > WOTEX_MAX_VALUE_BYTES) {
    send_reason(operation, "operation_failed", error ? operation_reason(error) : "invalid");
    return;
  }
  send_event(operation, "value", ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple4(env, binary(env, identifier), binary(env, service), binary(env, uuid),
                            binary_data(env, value));
  });
}

- (void)peripheral:(CBPeripheral *)peripheral
 didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
              error:(NSError *)error {
  NSString *identifier = peripheral_id(peripheral);
  NSString *service = uuid_string(characteristic.service.UUID);
  NSString *uuid = uuid_string(characteristic.UUID);
  NSString *key = operation_key(identifier, service, uuid);
  WotexBLEOperation *operation = self.writes[key];
  [self.writes removeObjectForKey:key];
  if (!operation)
    return;
  if (error) {
    send_reason(operation, "operation_failed", operation_reason(error));
    return;
  }
  send_event(operation, "written", ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple4(env, binary(env, identifier), binary(env, service), binary(env, uuid),
                            binary_data(env, [NSData data]));
  });
}

@end

static BOOL ascii_hex(unichar character) {
  return (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
}

static BOOL canonical_uuid(NSString *value) {
  NSUInteger length = value.length;
  if (length == 4 || length == 8) {
    for (NSUInteger index = 0; index < length; index++)
      if (!ascii_hex([value characterAtIndex:index]))
        return NO;
    return YES;
  }
  if (length != 36)
    return NO;
  for (NSUInteger index = 0; index < length; index++) {
    unichar character = [value characterAtIndex:index];
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (character != '-')
        return NO;
    } else if (!ascii_hex(character)) {
      return NO;
    }
  }
  return YES;
}

static BOOL operation_id(NSString *value) {
  if (!canonical_uuid(value) || value.length != 36 || [value characterAtIndex:14] != '4')
    return NO;
  unichar variant = [value characterAtIndex:19];
  return variant == '8' || variant == '9' || variant == 'a' || variant == 'b';
}

static NSString *string_term(ErlNifEnv *env, ERL_NIF_TERM term, NSUInteger maximum) {
  ErlNifBinary value;
  if (!enif_inspect_binary(env, term, &value) && !enif_inspect_iolist_as_binary(env, term, &value))
    return nil;
  if (value.size == 0 || value.size > maximum)
    return nil;
  return [[NSString alloc] initWithBytes:value.data
                                  length:value.size
                                encoding:NSUTF8StringEncoding];
}

static WotexBLEOperation *operation_term(ErlNifEnv *env, ERL_NIF_TERM term) {
  NSString *request = string_term(env, term, 36);
  ErlNifPid pid;
  if (!request || !operation_id(request) || !enif_self(env, &pid))
    return nil;
  WotexBLEOperation *operation = [WotexBLEOperation new];
  operation.request = request;
  operation.pid = pid;
  return operation;
}

static NSString *peripheral_term(ErlNifEnv *env, ERL_NIF_TERM term) {
  NSString *value = string_term(env, term, 36);
  return value && value.length == 36 && canonical_uuid(value) ? value : nil;
}

static NSString *uuid_term(ErlNifEnv *env, ERL_NIF_TERM term) {
  NSString *value = string_term(env, term, 36);
  return value && canonical_uuid(value) ? value : nil;
}

static NSArray<CBUUID *> *uuid_list_term(ErlNifEnv *env, ERL_NIF_TERM term) {
  unsigned int length = 0;
  if (!enif_get_list_length(env, term, &length) || length == 0 || length > WOTEX_MAX_SERVICES)
    return nil;
  NSMutableArray<CBUUID *> *values = [NSMutableArray arrayWithCapacity:length];
  ERL_NIF_TERM head;
  ERL_NIF_TERM tail = term;
  NSString *previous = nil;
  while (enif_get_list_cell(env, tail, &head, &tail)) {
    NSString *uuid = uuid_term(env, head);
    if (!uuid || (previous && [previous compare:uuid] != NSOrderedAscending))
      return nil;
    [values addObject:[CBUUID UUIDWithString:uuid]];
    previous = uuid;
  }
  return values;
}

static void on_main(dispatch_block_t block) {
  dispatch_async(dispatch_get_main_queue(), block);
}

static WotexBLECentral *central(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_central = [WotexBLECentral new];
  });
  return g_central;
}

static ERL_NIF_TERM nif_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 3 ? operation_term(env, argv[0]) : nil;
  NSArray<CBUUID *> *services = operation ? uuid_list_term(env, argv[1]) : nil;
  int timeout = 0;
  if (!operation || !services || !enif_get_int(env, argv[2], &timeout) || timeout < 1000 ||
      timeout > 30000)
    return enif_make_badarg(env);
  on_main(^{ [central() startScan:operation services:services timeout:timeout]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_stop_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 1 ? operation_term(env, argv[0]) : nil;
  if (!operation)
    return enif_make_badarg(env);
  on_main(^{ [central() stopScan:operation]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_connect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 2 ? operation_term(env, argv[0]) : nil;
  NSString *peripheral = operation ? peripheral_term(env, argv[1]) : nil;
  if (!operation || !peripheral)
    return enif_make_badarg(env);
  on_main(^{ [central() connect:operation peripheralID:peripheral]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_disconnect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 2 ? operation_term(env, argv[0]) : nil;
  NSString *peripheral = operation ? peripheral_term(env, argv[1]) : nil;
  if (!operation || !peripheral)
    return enif_make_badarg(env);
  on_main(^{ [central() disconnect:operation peripheralID:peripheral]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_discover(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 3 ? operation_term(env, argv[0]) : nil;
  NSString *peripheral = operation ? peripheral_term(env, argv[1]) : nil;
  NSArray<CBUUID *> *services = peripheral ? uuid_list_term(env, argv[2]) : nil;
  if (!operation || !peripheral || !services)
    return enif_make_badarg(env);
  on_main(^{ [central() discover:operation peripheralID:peripheral services:services]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 4 ? operation_term(env, argv[0]) : nil;
  NSString *peripheral = operation ? peripheral_term(env, argv[1]) : nil;
  NSString *service = peripheral ? uuid_term(env, argv[2]) : nil;
  NSString *characteristic = service ? uuid_term(env, argv[3]) : nil;
  if (!operation || !peripheral || !service || !characteristic)
    return enif_make_badarg(env);
  on_main(^{ [central() read:operation peripheralID:peripheral service:service characteristic:characteristic]; });
  return atom(env, "ok");
}

static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  WotexBLEOperation *operation = argc == 5 ? operation_term(env, argv[0]) : nil;
  NSString *peripheral = operation ? peripheral_term(env, argv[1]) : nil;
  NSString *service = peripheral ? uuid_term(env, argv[2]) : nil;
  NSString *characteristic = service ? uuid_term(env, argv[3]) : nil;
  ErlNifBinary value;
  if (!operation || !peripheral || !service || !characteristic ||
      !enif_inspect_binary(env, argv[4], &value) || value.size == 0 ||
      value.size > WOTEX_MAX_VALUE_BYTES)
    return enif_make_badarg(env);
  NSData *data = [NSData dataWithBytes:value.data length:value.size];
  on_main(^{ [central() write:operation peripheralID:peripheral service:service characteristic:characteristic value:data]; });
  return atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"scan", 3, nif_scan, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop_scan", 1, nif_stop_scan, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"connect", 2, nif_connect, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"disconnect", 2, nif_disconnect, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"discover", 3, nif_discover, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read", 4, nif_read, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write", 5, nif_write, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(wotex_ble_central_nif, nif_funcs, NULL, NULL, NULL, NULL)

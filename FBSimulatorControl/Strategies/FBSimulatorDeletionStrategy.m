/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorDeletionStrategy.h"

#import <FBControlCore/FBControlCore.h>

#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceSet.h>

#import "FBSimulator.h"
#import "FBSimulatorError.h"
#import "FBSimulatorSet.h"
#import "FBSimulator+Helpers.h"

@interface FBSimulatorDeletionStrategy ()

@property (nonatomic, weak, readonly) FBSimulatorSet *set;
@property (nonatomic, nullable, strong, readonly) id<FBControlCoreLogger> logger;

@end

@implementation FBSimulatorDeletionStrategy

#pragma mark Initializers

+ (instancetype)strategyFromSet:(FBSimulatorSet *)set logger:(id<FBControlCoreLogger>)logger
{
  return [[self alloc] initWithSet:set logger:logger];
}

- (instancetype)initWithSet:(FBSimulatorSet *)set logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _set = set;
  _logger = logger;

  return self;
}

#pragma mark Public Methods

- (nullable NSArray<NSString *> *)deleteSimulators:(NSArray<FBSimulator *> *)simulators error:(NSError **)error
{
   // Confirm that the Simulators belong to the set
  for (FBSimulator *simulator in simulators) {
    if (simulator.set != self.set) {
      return [[[FBSimulatorError
        describeFormat:@"Simulator's set %@ is not %@, cannot delete", simulator.set, self]
        inSimulator:simulator]
        fail:error];
    }
  }

  // Keep the UDIDs around for confirmation
  NSSet *deletedDeviceUDIDs = [NSSet setWithArray:[simulators valueForKey:@"udid"]];

  // Kill the Simulators before deleting them.
  for (FBSimulator *simulator in simulators) {
    // Erasing the Simulator will also ensure that the Simulator is shutdown.
    // In addition it will ensure that the files in ~/Library/Logs/CoreSimulator/<UDID>
    // are also erased.
    // Deleting a Simulator will not delete it's logs unless it is erased first.
    [self.logger logFormat:@"Erasing Simulator, in preparation for deletion %@", simulator];
    NSError *innerError = nil;
    if (![self.set eraseSimulator:simulator error:&innerError]) {
      return [[[[[FBSimulatorError
        describe:@"Failed to erase simulator."]
        inSimulator:simulator]
        causedBy:innerError]
        logger:self.logger]
        fail:error];
    }

    // Then follow through with the actual deletion of the Simulator, which will remove it from the set.
    [self.logger logFormat:@"Deleting Simulator %@", simulator];
    if (![simulator.device.deviceSet deleteDevice:simulator.device error:&innerError]) {
      return [[[[[FBSimulatorError
        describe:@"Failed to delete simulator."]
        inSimulator:simulator]
        causedBy:innerError]
        logger:self.logger]
        fail:error];
    }
    [self.logger logFormat:@"Simulator Deleted Successfully %@", simulator];
  }

  // Deleting the device from the set can still leave it around for a few seconds.
  // This could race with methods that may reallocate the newly-deleted device.
  // So we should wait for the device to no longer be present in the underlying set.
  __block NSMutableSet *remainderSet = nil;
  BOOL allRemovedFromSet = [NSRunLoop.currentRunLoop spinRunLoopWithTimeout:FBControlCoreGlobalConfiguration.regularTimeout untilTrue:^ BOOL {
    remainderSet = [NSMutableSet setWithSet:deletedDeviceUDIDs];
    [remainderSet intersectSet:[NSSet setWithArray:[self.set.allSimulators valueForKey:@"udid"]]];
    return remainderSet.count == 0;
  }];

  if (!allRemovedFromSet) {
    return [[[FBSimulatorError
      describeFormat:@"Timed out waiting for Simulators %@ to dissapear from set.", [FBCollectionInformation oneLineDescriptionFromArray:remainderSet.allObjects]]
      logger:self.logger]
      fail:error];
  }

  return deletedDeviceUDIDs.allObjects;
}

@end
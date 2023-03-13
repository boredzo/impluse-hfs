//
//  ImpVolumeProbe.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-02-28.
//

#import <Foundation/Foundation.h>

@class ImpHFSVolume;
@class ImpHFSPlusVolume;

@interface ImpVolumeProbe : NSObject

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD;

@property(nonatomic, readonly) NSUInteger numberOfInterestingVolumes;
@property(readonly) NSError *_Nullable error;

@property bool verbose;

///Call this block with each volume found in the backing device/image. For bare, single-volume storages, this will call the block once. For partitioned storages, this will call the block exactly once per interesting volume. volumeClass, if not Nil, may be ImpHFSVolume or ImpHFSPlusVolume.
- (void) findVolumes:(void (^_Nonnull const)(u_int64_t const startOffsetInBytes, u_int64_t const lengthInBytes, Class _Nullable const volumeClass))block;

@end
